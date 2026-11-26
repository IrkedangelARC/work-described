//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

//
//  ARCDeckLinkBridge.mm
//  Implementation notes:
//  - Uses the official SDK 12.x headers (vendored from Blackmagic via the OBS
//    project). COM interface IIDs are stable across driver releases, so these
//    headers work against newer installed drivers (16.x verified).
//  - CreateDeckLinkIteratorInstance() comes from DeckLinkAPIDispatch.cpp and
//    returns NULL when Desktop Video is not installed — never crashes.
//

#import "ARCDeckLinkBridge.h"

#include "DeckLinkAPI.h"

#include <cmath>
#include <cstring>

NSErrorDomain const ARCDeckLinkErrorDomain = @"com.arc.decklink";

// ---------------------------------------------------------------------------
// Small COM helpers
// ---------------------------------------------------------------------------

namespace {

template <typename T>
void safeRelease(T *&ptr)
{
    if (ptr) {
        ptr->Release();
        ptr = nullptr;
    }
}

NSString *stringFromAttr(IDeckLinkProfileAttributes *attrs, BMDDeckLinkAttributeID attrID)
{
    CFStringRef value = nullptr;
    if (attrs->GetString(attrID, &value) == S_OK && value) {
        NSString *result = (__bridge_transfer NSString *)value;
        return result;
    }
    return @"";
}

NSError *makeError(ARCDeckLinkError code, NSString *message)
{
    return [NSError errorWithDomain:ARCDeckLinkErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

} // namespace

// ---------------------------------------------------------------------------
// ARCDLDeviceInfo
// ---------------------------------------------------------------------------

@interface ARCDLDeviceInfo ()
- (instancetype)initWithName:(NSString *)name
                persistentID:(int64_t)persistentID
            supportsPlayback:(BOOL)playback
             internalKeying:(BOOL)internalKeying
             externalKeying:(BOOL)externalKeying;
@end

@implementation ARCDLDeviceInfo

- (instancetype)initWithName:(NSString *)name
                persistentID:(int64_t)persistentID
            supportsPlayback:(BOOL)playback
             internalKeying:(BOOL)internalKeying
             externalKeying:(BOOL)externalKeying
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _persistentID = persistentID;
        _supportsPlayback = playback;
        _supportsInternalKeying = internalKeying;
        _supportsExternalKeying = externalKeying;
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<ARCDLDeviceInfo %@ id=%lld playback=%d intKey=%d extKey=%d>",
                                      self.name, self.persistentID, self.supportsPlayback,
                                      self.supportsInternalKeying, self.supportsExternalKeying];
}

@end

// ---------------------------------------------------------------------------
// ARCDLFillKeyOutput
// ---------------------------------------------------------------------------

@implementation ARCDLFillKeyOutput {
    IDeckLink *_device;
    IDeckLinkOutput *_output;
    IDeckLinkKeyer *_keyer;
    // Two-frame ring so we never mutate the frame the hardware is scanning out.
    IDeckLinkMutableVideoFrame *_frames[2];
    int _nextFrame;
    BOOL _running;
    int32_t _width;
    int32_t _height;
    NSString *_lastErrorMessage;
}

+ (BOOL)driverInstalled
{
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return NO;
    }
    iterator->Release();
    return YES;
}

+ (NSArray<ARCDLDeviceInfo *> *)outputDevices
{
    NSMutableArray<ARCDLDeviceInfo *> *devices = [NSMutableArray array];
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        return devices;
    }

    IDeckLink *deckLink = nullptr;
    while (iterator->Next(&deckLink) == S_OK && deckLink) {
        IDeckLinkProfileAttributes *attrs = nullptr;
        if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attrs) == S_OK && attrs) {
            int64_t persistentID = 0;
            int64_t ioSupport = 0;
            bool internalKeying = false;
            bool externalKeying = false;
            attrs->GetInt(BMDDeckLinkPersistentID, &persistentID);
            attrs->GetInt(BMDDeckLinkVideoIOSupport, &ioSupport);
            attrs->GetFlag(BMDDeckLinkSupportsInternalKeying, &internalKeying);
            attrs->GetFlag(BMDDeckLinkSupportsExternalKeying, &externalKeying);
            NSString *name = stringFromAttr(attrs, BMDDeckLinkDisplayName);
            if (name.length == 0) {
                name = stringFromAttr(attrs, BMDDeckLinkModelName);
            }

            BOOL playback = (ioSupport & bmdDeviceSupportsPlayback) != 0;
            if (playback) {
                [devices addObject:[[ARCDLDeviceInfo alloc] initWithName:name
                                                            persistentID:persistentID
                                                        supportsPlayback:playback
                                                          internalKeying:internalKeying
                                                          externalKeying:externalKeying]];
            }
            attrs->Release();
        }
        deckLink->Release();
        deckLink = nullptr;
    }
    iterator->Release();
    return devices;
}

- (BOOL)isRunning
{
    return _running;
}

- (int32_t)frameWidth
{
    return _width;
}

- (int32_t)frameHeight
{
    return _height;
}

- (NSString *)lastErrorMessage
{
    return _lastErrorMessage;
}

- (BOOL)startWithPersistentID:(int64_t)persistentID
                        width:(int32_t)width
                       height:(int32_t)height
                     fpsNumer:(int32_t)fpsNumer
                     fpsDenom:(int32_t)fpsDenom
                    keyerMode:(ARCDLKeyerMode)keyerMode
                        error:(NSError **)error
{
    if (_running) {
        [self stop];
    }

    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        if (error) *error = makeError(ARCDeckLinkErrorDriverNotInstalled,
                                      @"Blackmagic Desktop Video driver is not installed.");
        return NO;
    }

    // --- Locate the requested device -------------------------------------
    IDeckLink *deckLink = nullptr;
    while (iterator->Next(&deckLink) == S_OK && deckLink) {
        IDeckLinkProfileAttributes *attrs = nullptr;
        int64_t thisID = 0;
        int64_t ioSupport = 0;
        if (deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, (void **)&attrs) == S_OK && attrs) {
            attrs->GetInt(BMDDeckLinkPersistentID, &thisID);
            attrs->GetInt(BMDDeckLinkVideoIOSupport, &ioSupport);
            attrs->Release();
        }
        BOOL playback = (ioSupport & bmdDeviceSupportsPlayback) != 0;
        if (playback && (persistentID == 0 || thisID == persistentID)) {
            break; // keep this reference
        }
        deckLink->Release();
        deckLink = nullptr;
    }
    iterator->Release();

    if (!deckLink) {
        if (error) *error = makeError(ARCDeckLinkErrorDeviceNotFound,
                                      [NSString stringWithFormat:@"No playback-capable DeckLink device found (persistentID %lld).", persistentID]);
        return NO;
    }
    _device = deckLink;

    if (_device->QueryInterface(IID_IDeckLinkOutput, (void **)&_output) != S_OK || !_output) {
        [self teardown];
        if (error) *error = makeError(ARCDeckLinkErrorNoOutputInterface,
                                      @"Device does not expose an output interface.");
        return NO;
    }

    // --- Find a display mode matching width/height/fps -------------------
    BMDDisplayMode chosenMode = bmdModeUnknown;
    IDeckLinkDisplayModeIterator *modeIterator = nullptr;
    if (_output->GetDisplayModeIterator(&modeIterator) == S_OK && modeIterator) {
        IDeckLinkDisplayMode *mode = nullptr;
        double wantFPS = (double)fpsNumer / (double)fpsDenom;
        while (modeIterator->Next(&mode) == S_OK && mode) {
            BMDTimeValue duration = 0;
            BMDTimeScale scale = 0;
            if (mode->GetWidth() == width && mode->GetHeight() == height &&
                mode->GetFrameRate(&duration, &scale) == S_OK && duration > 0 &&
                mode->GetFieldDominance() != bmdLowerFieldFirst &&
                mode->GetFieldDominance() != bmdUpperFieldFirst) {
                double fps = (double)scale / (double)duration;
                if (fabs(fps - wantFPS) < 0.02) {
                    chosenMode = mode->GetDisplayMode();
                    mode->Release();
                    break;
                }
            }
            mode->Release();
            mode = nullptr;
        }
        modeIterator->Release();
    }

    if (chosenMode == bmdModeUnknown) {
        [self teardown];
        if (error) *error = makeError(ARCDeckLinkErrorModeUnsupported,
                                      [NSString stringWithFormat:@"Device has no %dx%d progressive mode near %.2f fps.",
                                                                 width, height, (double)fpsNumer / (double)fpsDenom]);
        return NO;
    }

    bool supported = false;
    BMDDisplayMode actualMode = bmdModeUnknown;
    HRESULT hr = _output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, chosenMode,
                                               bmdFormat8BitBGRA, bmdNoVideoOutputConversion,
                                               bmdSupportedVideoModeDefault, &actualMode, &supported);
    if (hr != S_OK || !supported) {
        [self teardown];
        if (error) *error = makeError(ARCDeckLinkErrorModeUnsupported,
                                      @"Device does not support 8-bit BGRA output in the requested mode (required for keying).");
        return NO;
    }

    // --- Keyer ------------------------------------------------------------
    if (keyerMode != ARCDLKeyerModeNone) {
        if (_device->QueryInterface(IID_IDeckLinkKeyer, (void **)&_keyer) != S_OK || !_keyer) {
            [self teardown];
            if (error) *error = makeError(ARCDeckLinkErrorKeyerUnsupported,
                                          @"Device does not expose a keyer interface.");
            return NO;
        }
        if (_keyer->Enable(keyerMode == ARCDLKeyerModeExternal) != S_OK) {
            [self teardown];
            if (error) *error = makeError(ARCDeckLinkErrorKeyerUnsupported,
                                          keyerMode == ARCDLKeyerModeExternal
                                              ? @"Device rejected external keying mode."
                                              : @"Device rejected internal keying mode.");
            return NO;
        }
        _keyer->SetLevel(255);
    }

    if (_output->EnableVideoOutput(chosenMode, bmdVideoOutputFlagDefault) != S_OK) {
        [self teardown];
        if (error) *error = makeError(ARCDeckLinkErrorOutputFailed, @"EnableVideoOutput failed.");
        return NO;
    }

    for (int i = 0; i < 2; i++) {
        if (_output->CreateVideoFrame(width, height, width * 4, bmdFormat8BitBGRA,
                                      bmdFrameFlagDefault, &_frames[i]) != S_OK) {
            [self teardown];
            if (error) *error = makeError(ARCDeckLinkErrorOutputFailed, @"CreateVideoFrame failed.");
            return NO;
        }
    }

    _width = width;
    _height = height;
    _nextFrame = 0;
    _lastErrorMessage = nil;
    _running = YES;
    return YES;
}

- (BOOL)sendFrameWithFill:(CVPixelBufferRef)fill key:(CVPixelBufferRef)key
{
    if (!_running || !fill) {
        return NO;
    }
    if (CVPixelBufferGetPixelFormatType(fill) != kCVPixelFormatType_32BGRA ||
        (int32_t)CVPixelBufferGetWidth(fill) != _width ||
        (int32_t)CVPixelBufferGetHeight(fill) != _height) {
        _lastErrorMessage = [NSString stringWithFormat:@"Fill buffer must be 32BGRA %dx%d.", _width, _height];
        return NO;
    }

    IDeckLinkMutableVideoFrame *frame = _frames[_nextFrame];
    _nextFrame = (_nextFrame + 1) % 2;

    void *dstBase = nullptr;
    if (frame->GetBytes(&dstBase) != S_OK || !dstBase) {
        _lastErrorMessage = @"GetBytes failed on output frame.";
        return NO;
    }
    const long dstRowBytes = frame->GetRowBytes();

    CVPixelBufferLockBaseAddress(fill, kCVPixelBufferLock_ReadOnly);
    const uint8_t *srcBase = (const uint8_t *)CVPixelBufferGetBaseAddress(fill);
    const size_t srcRowBytes = CVPixelBufferGetBytesPerRow(fill);
    const size_t copyBytes = (size_t)_width * 4;
    uint8_t *dst = (uint8_t *)dstBase;
    for (int32_t y = 0; y < _height; y++) {
        memcpy(dst + (size_t)y * dstRowBytes, srcBase + (size_t)y * srcRowBytes, copyBytes);
    }
    CVPixelBufferUnlockBaseAddress(fill, kCVPixelBufferLock_ReadOnly);

    if (key) {
        if (CVPixelBufferGetPixelFormatType(key) != kCVPixelFormatType_32BGRA ||
            (int32_t)CVPixelBufferGetWidth(key) != _width ||
            (int32_t)CVPixelBufferGetHeight(key) != _height) {
            _lastErrorMessage = [NSString stringWithFormat:@"Key buffer must be 32BGRA %dx%d.", _width, _height];
            return NO;
        }
        // White-on-black matte: blue channel of the key becomes output alpha.
        CVPixelBufferLockBaseAddress(key, kCVPixelBufferLock_ReadOnly);
        const uint8_t *keyBase = (const uint8_t *)CVPixelBufferGetBaseAddress(key);
        const size_t keyRowBytes = CVPixelBufferGetBytesPerRow(key);
        for (int32_t y = 0; y < _height; y++) {
            const uint8_t *keyRow = keyBase + (size_t)y * keyRowBytes;
            uint8_t *dstRow = dst + (size_t)y * dstRowBytes;
            for (int32_t x = 0; x < _width; x++) {
                dstRow[x * 4 + 3] = keyRow[x * 4];
            }
        }
        CVPixelBufferUnlockBaseAddress(key, kCVPixelBufferLock_ReadOnly);
    }

    if (_output->DisplayVideoFrameSync(frame) != S_OK) {
        _lastErrorMessage = @"DisplayVideoFrameSync failed.";
        return NO;
    }
    return YES;
}

- (void)stop
{
    if (_output && _running) {
        _output->DisableVideoOutput();
    }
    [self teardown];
}

- (void)teardown
{
    _running = NO;
    // Always disable the keyer here, not just in stop: a start that fails
    // after Enable() (e.g. EnableVideoOutput rejected) must not leave the
    // device keying.
    if (_keyer) {
        _keyer->Disable();
    }
    for (int i = 0; i < 2; i++) {
        safeRelease(_frames[i]);
    }
    safeRelease(_keyer);
    safeRelease(_output);
    safeRelease(_device);
    _width = 0;
    _height = 0;
}

- (void)dealloc
{
    [self stop];
}

@end

//  ArcQuadMic.c
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//  "ARC QUAD Mic": a virtual microphone any app can pick (Zoom, Teams, OBS), the sound that
//  goes with the "ARC QUAD" virtual camera. A camera extension cannot carry audio, so the
//  sound needs a device of its own (2026-11-06: "make that an option").
//
//  HOW IT WORKS. One device with two sides, joined by a ring of samples:
//    the FEED side (an output): ARC Camera OP plays a camera's sound into it;
//    the MIC side (an input):   Zoom and the rest read the same samples back out.
//  Nothing here reaches the network, a file or another process. It is a pipe with a clock.
//
//  48 kHz, stereo, 32 bit float, and nothing else: the console's camera audio is 48 kHz stereo.
//
//  The plan: docs/plans/PLAN_quad_virtual_camera.md, section "ARC QUAD Mic".

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// ------------------------------------------------------------------ the fixed facts

enum {
    kObj_PlugIn    = kAudioObjectPlugInObject,   // 1
    kObj_Device    = 2,
    kObj_StreamIn  = 3,                          // the MIC side, what apps record from
    kObj_StreamOut = 4,                          // the FEED side, what the console plays into
};

#define kDeviceName        "ARC QUAD Mic"
#define kManufacturer      "ARC Event Productions"
#define kDeviceUID         "ArcQuadMic_UID"
#define kDeviceModelUID    "ArcQuadMic_ModelUID"
#define kSampleRate        48000.0
#define kChannels          2u
#define kBytesPerFrame     (kChannels * (UInt32)sizeof(Float32))
#define kZeroStampPeriod   16384u                // frames between the clock's zero time stamps
#define kRingFrames        65536u                // 1.37 s of samples between the two sides

// ------------------------------------------------------------------ state

static AudioServerPlugInHostRef gHost = NULL;
static _Atomic UInt32  gRefCount = 0;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32   gIOCount = 0;                    // clients doing IO
static Float64  gHostTicksPerFrame = 0.0;
static UInt64   gAnchorHostTime = 0;
static UInt64   gNumberTimeStamps = 0;
static bool     gStreamInActive = true;
static bool     gStreamOutActive = true;

static Float32  gRing[kRingFrames * kChannels];
static _Atomic UInt64 gLastWriteEnd = 0;         // sample time one past the newest sample written

// ------------------------------------------------------------------ forward declarations

static HRESULT  Mic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    Mic_AddRef(void* inDriver);
static ULONG    Mic_Release(void* inDriver);
static OSStatus Mic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Mic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus Mic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Mic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Mic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Mic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus Mic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  Mic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus Mic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus Mic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus Mic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus Mic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus Mic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Mic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Mic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus Mic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus Mic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Mic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus Mic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Mic_QueryInterface, Mic_AddRef, Mic_Release,
    Mic_Initialize, Mic_CreateDevice, Mic_DestroyDevice,
    Mic_AddDeviceClient, Mic_RemoveDeviceClient,
    Mic_PerformDeviceConfigurationChange, Mic_AbortDeviceConfigurationChange,
    Mic_HasProperty, Mic_IsPropertySettable, Mic_GetPropertyDataSize, Mic_GetPropertyData, Mic_SetPropertyData,
    Mic_StartIO, Mic_StopIO, Mic_GetZeroTimeStamp,
    Mic_WillDoIOOperation, Mic_BeginIOOperation, Mic_DoIOOperation, Mic_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// ------------------------------------------------------------------ the factory (named in Info.plist)

void* ArcQuadMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* ArcQuadMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

// ------------------------------------------------------------------ COM plumbing

static HRESULT Mic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef asked = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (asked == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(asked, IUnknownUUID) || CFEqual(asked, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        r = S_OK;
    }
    CFRelease(asked);
    return r;
}

static ULONG Mic_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Mic_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    UInt32 now = atomic_load(&gRefCount);
    while (now > 0 && !atomic_compare_exchange_weak(&gRefCount, &now, now - 1)) { }
    return now > 0 ? now - 1 : 0;
}

// ------------------------------------------------------------------ basic operations

static OSStatus Mic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostTicksPerSecond / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus Mic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Mic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Mic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus Mic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

// One format, one rate: the device never asks for a configuration change.
static OSStatus Mic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus Mic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

// ------------------------------------------------------------------ properties

static AudioStreamBasicDescription TheFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static bool FormatIsOurs(const AudioStreamBasicDescription* f) {
    return f->mSampleRate == kSampleRate && f->mFormatID == kAudioFormatLinearPCM &&
           f->mChannelsPerFrame == kChannels && f->mBitsPerChannel == 32 &&
           (f->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

/** The streams a scope asks about: both for global, one for input or output. */
static UInt32 StreamsForScope(AudioObjectPropertyScope scope, AudioObjectID out[2]) {
    UInt32 n = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) out[n++] = kObj_StreamIn;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) out[n++] = kObj_StreamOut;
    return n;
}

#define kLayoutSize ((UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription)))

/**
 * THE ONE TABLE. Every property of every object: whether it exists, whether it can be set,
 * and its size in bytes. HasProperty, IsPropertySettable and GetPropertyDataSize read it, so
 * the three can never disagree. Returns false for a property the object does not have.
 */
static bool Describe(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32* outSize, bool* outSettable) {
    UInt32 size = 0; bool settable = false; bool has = true;
    AudioObjectID tmp[2];
    switch (obj) {
    case kObj_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:             size = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:             size = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyManufacturer:      size = sizeof(CFStringRef); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:        size = sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyBoxList:           size = 0; break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox: size = sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyResourceBundle:    size = sizeof(CFStringRef); break;
        default: has = false;
        }
        break;
    case kObj_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:             size = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:             size = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:          size = sizeof(CFStringRef); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:           size = StreamsForScope(a->mScope, tmp) * (UInt32)sizeof(AudioObjectID); break;
        case kAudioObjectPropertyControlList:       size = 0; break;
        case kAudioDevicePropertyRelatedDevices:    size = sizeof(AudioObjectID); break;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: size = sizeof(UInt32); break;
        case kAudioDevicePropertyNominalSampleRate: size = sizeof(Float64); settable = true; break;
        case kAudioDevicePropertyAvailableNominalSampleRates: size = sizeof(AudioValueRange); break;
        case kAudioDevicePropertyPreferredChannelsForStereo: size = 2 * sizeof(UInt32); break;
        case kAudioDevicePropertyPreferredChannelLayout: size = kLayoutSize; break;
        default: has = false;
        }
        break;
    case kObj_StreamIn:
    case kObj_StreamOut:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:             size = sizeof(AudioClassID); break;
        case kAudioObjectPropertyOwner:             size = sizeof(AudioObjectID); break;
        case kAudioObjectPropertyOwnedObjects:      size = 0; break;
        case kAudioObjectPropertyName:              size = sizeof(CFStringRef); break;
        case kAudioStreamPropertyIsActive:          size = sizeof(UInt32); settable = true; break;
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:           size = sizeof(UInt32); break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:    size = sizeof(AudioStreamBasicDescription); settable = true; break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: size = sizeof(AudioStreamRangedDescription); break;
        default: has = false;
        }
        break;
    default:
        has = false;
    }
    if (outSize) *outSize = size;
    if (outSettable) *outSettable = settable;
    return has;
}

static Boolean Mic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    return Describe(inObjectID, inAddress, NULL, NULL);
}

static OSStatus Mic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    bool settable = false;
    if (!Describe(inObjectID, inAddress, NULL, &settable)) return kAudioHardwareUnknownPropertyError;
    *outIsSettable = settable;
    return kAudioHardwareNoError;
}

static OSStatus Mic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!Describe(inObjectID, inAddress, outDataSize, NULL)) return kAudioHardwareUnknownPropertyError;
    return kAudioHardwareNoError;
}

#define PUT(type, value) do { \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *((type*)outData) = (value); *outDataSize = sizeof(type); \
    } while (0)

/** A list of object IDs, as many as the caller's buffer holds. */
static void PutList(const AudioObjectID* list, UInt32 n, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    UInt32 room = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (n > room) n = room;
    if (n > 0) memcpy(outData, list, n * sizeof(AudioObjectID));
    *outDataSize = n * (UInt32)sizeof(AudioObjectID);
}

static OSStatus Mic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!Describe(inObjectID, inAddress, NULL, NULL)) return kAudioHardwareUnknownPropertyError;
    AudioObjectID ids[2];

    if (inObjectID == kObj_PlugIn) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:  PUT(AudioClassID, kAudioObjectClassID); break;
        case kAudioObjectPropertyClass:      PUT(AudioClassID, kAudioPlugInClassID); break;
        case kAudioObjectPropertyOwner:      PUT(AudioObjectID, kAudioObjectUnknown); break;
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(kManufacturer)); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            ids[0] = kObj_Device; PutList(ids, 1, inDataSize, outDataSize, outData); break;
        case kAudioPlugInPropertyBoxList:    *outDataSize = 0; break;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef*)inQualifierData);
            AudioObjectID found = (uid != NULL && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) ? kObj_Device : kAudioObjectUnknown;
            PUT(AudioObjectID, found);
            break;
        }
        case kAudioPlugInPropertyTranslateUIDToBox: PUT(AudioObjectID, kAudioObjectUnknown); break;
        case kAudioPlugInPropertyResourceBundle:    PUT(CFStringRef, CFSTR("")); break;
        default: return kAudioHardwareUnknownPropertyError;
        }
        return kAudioHardwareNoError;
    }

    if (inObjectID == kObj_Device) {
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:  PUT(AudioClassID, kAudioObjectClassID); break;
        case kAudioObjectPropertyClass:      PUT(AudioClassID, kAudioDeviceClassID); break;
        case kAudioObjectPropertyOwner:      PUT(AudioObjectID, kObj_PlugIn); break;
        case kAudioObjectPropertyName:       PUT(CFStringRef, CFSTR(kDeviceName)); break;
        case kAudioObjectPropertyManufacturer: PUT(CFStringRef, CFSTR(kManufacturer)); break;
        case kAudioDevicePropertyDeviceUID:  PUT(CFStringRef, CFSTR(kDeviceUID)); break;
        case kAudioDevicePropertyModelUID:   PUT(CFStringRef, CFSTR(kDeviceModelUID)); break;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            UInt32 n = StreamsForScope(inAddress->mScope, ids);
            PutList(ids, n, inDataSize, outDataSize, outData);
            break;
        }
        case kAudioObjectPropertyControlList: *outDataSize = 0; break;
        case kAudioDevicePropertyRelatedDevices:
            ids[0] = kObj_Device; PutList(ids, 1, inDataSize, outDataSize, outData); break;
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual); break;
        case kAudioDevicePropertyClockDomain:   PUT(UInt32, 0); break;
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1); break;
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0 ? 1 : 0;
            pthread_mutex_unlock(&gStateMutex);
            PUT(UInt32, running);
            break;
        }
        // THE MIC SIDE may be picked as the Mac's default input. THE FEED SIDE may not be the
        // default output and never plays the system's alert sounds: Mac sound sent into it
        // would come out of the microphone.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            PUT(UInt32, inAddress->mScope == kAudioObjectPropertyScopeInput ? 1 : 0); break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 0); break;
        case kAudioDevicePropertyLatency:        PUT(UInt32, 0); break;
        case kAudioDevicePropertySafetyOffset:   PUT(UInt32, 0); break;
        case kAudioDevicePropertyIsHidden:       PUT(UInt32, 0); break;
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kZeroStampPeriod); break;
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate); break;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; break; }
            AudioValueRange r = { kSampleRate, kSampleRate };
            *((AudioValueRange*)outData) = r; *outDataSize = sizeof(AudioValueRange);
            break;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            break;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            if (inDataSize < kLayoutSize) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            memset(l, 0, kLayoutSize);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = kLayoutSize;
            break;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
        return kAudioHardwareNoError;
    }

    // the two streams
    bool isIn = (inObjectID == kObj_StreamIn);
    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:  PUT(AudioClassID, kAudioObjectClassID); break;
    case kAudioObjectPropertyClass:      PUT(AudioClassID, kAudioStreamClassID); break;
    case kAudioObjectPropertyOwner:      PUT(AudioObjectID, kObj_Device); break;
    case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; break;
    case kAudioObjectPropertyName:
        PUT(CFStringRef, isIn ? CFSTR("ARC QUAD Mic") : CFSTR("ARC QUAD Mic feed (ARC Camera OP plays into this)")); break;
    case kAudioStreamPropertyIsActive: {
        pthread_mutex_lock(&gStateMutex);
        UInt32 active = (isIn ? gStreamInActive : gStreamOutActive) ? 1 : 0;
        pthread_mutex_unlock(&gStateMutex);
        PUT(UInt32, active);
        break;
    }
    case kAudioStreamPropertyDirection:       PUT(UInt32, isIn ? 1 : 0); break;
    case kAudioStreamPropertyTerminalType:    PUT(UInt32, isIn ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine); break;
    case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1); break;
    case kAudioStreamPropertyLatency:         PUT(UInt32, 0); break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:  PUT(AudioStreamBasicDescription, TheFormat()); break;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; break; }
        AudioStreamRangedDescription d;
        memset(&d, 0, sizeof(d));
        d.mFormat = TheFormat();
        d.mSampleRateRange.mMinimum = kSampleRate;
        d.mSampleRateRange.mMaximum = kSampleRate;
        *((AudioStreamRangedDescription*)outData) = d; *outDataSize = sizeof(d);
        break;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareNoError;
}

static OSStatus Mic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    bool settable = false;
    if (!Describe(inObjectID, inAddress, NULL, &settable)) return kAudioHardwareUnknownPropertyError;
    if (!settable) return kAudioHardwareUnsupportedOperationError;

    if (inObjectID == kObj_Device) {   // the sample rate: 48 kHz or nothing
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *((const Float64*)inData) == kSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }

    bool isIn = (inObjectID == kObj_StreamIn);
    if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        bool want = *((const UInt32*)inData) != 0;
        pthread_mutex_lock(&gStateMutex);
        bool was = isIn ? gStreamInActive : gStreamOutActive;
        if (isIn) gStreamInActive = want; else gStreamOutActive = want;
        pthread_mutex_unlock(&gStateMutex);
        if (was != want && gHost != NULL) {
            AudioObjectPropertyAddress changed = { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            gHost->PropertiesChanged(gHost, inObjectID, 1, &changed);
        }
        return kAudioHardwareNoError;
    }
    // a format: the one we have, or nothing
    if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
    return FormatIsOurs((const AudioStreamBasicDescription*)inData) ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
}

// ------------------------------------------------------------------ IO

static OSStatus Mic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == UINT32_MAX) { pthread_mutex_unlock(&gStateMutex); return kAudioHardwareIllegalOperationError; }
    if (gIOCount == 0) {
        // The clock starts from zero with the first client, so the ring starts empty: the
        // last run's sound must not come out of the microphone at the start of this one.
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        atomic_store(&gLastWriteEnd, 0);
        memset(gRing, 0, sizeof(gRing));
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) { pthread_mutex_unlock(&gStateMutex); return kAudioHardwareIllegalOperationError; }
    gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

/** The device's clock: the Mac's own clock, stamped once every kZeroStampPeriod frames. */
static OSStatus Mic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroStampPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Mic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    bool will = (inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Mic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

/** Copy [start, start+frames) between a client's buffer and the ring, wrapping at the ring's end. */
static void RingCopy(UInt64 start, UInt32 frames, Float32* client, bool toRing) {
    UInt32 at = (UInt32)(start % kRingFrames);
    UInt32 first = kRingFrames - at;
    if (first > frames) first = frames;
    if (toRing) {
        memcpy(&gRing[at * kChannels], client, first * kBytesPerFrame);
        if (frames > first) memcpy(gRing, client + first * kChannels, (frames - first) * kBytesPerFrame);
    } else {
        memcpy(client, &gRing[at * kChannels], first * kBytesPerFrame);
        if (frames > first) memcpy(client + first * kChannels, gRing, (frames - first) * kBytesPerFrame);
    }
}

static void RingZero(UInt64 start, UInt64 frames) {
    if (frames >= kRingFrames) { memset(gRing, 0, sizeof(gRing)); return; }
    UInt32 at = (UInt32)(start % kRingFrames);
    UInt32 n = (UInt32)frames;
    UInt32 first = kRingFrames - at;
    if (first > n) first = n;
    memset(&gRing[at * kChannels], 0, first * kBytesPerFrame);
    if (n > first) memset(gRing, 0, (n - first) * kBytesPerFrame);
}

/**
 * THE PIPE.
 * WriteMix: what the console played, placed in the ring at the sample time it is due.
 * ReadInput: what an app records, taken from the ring at the sample time it asks for.
 * A reader never gets stale sound: samples past the newest write, or older than the ring
 * holds, come out as silence. A gap between two writes is filled with silence too, so the
 * ring between (newest write - ring length) and (newest write) is always sound or silence.
 */
static OSStatus Mic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObj_Device) return kAudioHardwareBadObjectError;
    if (inStreamObjectID != kObj_StreamIn && inStreamObjectID != kObj_StreamOut) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL || inIOBufferFrameSize == 0) return kAudioHardwareNoError;
    UInt32 frames = inIOBufferFrameSize;
    Float32* buf = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObj_StreamOut) {
        if (frames > kRingFrames) { buf += (frames - kRingFrames) * kChannels; frames = kRingFrames; }
        Float64 t = inIOCycleInfo->mOutputTime.mSampleTime;
        UInt64 start = t > 0.0 ? (UInt64)t : 0;
        UInt64 last = atomic_load(&gLastWriteEnd);
        if (start > last) RingZero(last, start - last);     // a gap since the last write: silence
        RingCopy(start, frames, buf, true);
        atomic_store(&gLastWriteEnd, start + frames);
        return kAudioHardwareNoError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObj_StreamIn) {
        memset(buf, 0, (size_t)frames * kBytesPerFrame);
        Float64 t = inIOCycleInfo->mInputTime.mSampleTime;
        UInt64 start = t > 0.0 ? (UInt64)t : 0;
        UInt64 end = start + frames;
        UInt64 last = atomic_load(&gLastWriteEnd);
        UInt64 oldest = last > kRingFrames ? last - kRingFrames : 0;
        UInt64 from = start > oldest ? start : oldest;
        UInt64 to = end < last ? end : last;
        if (from < to && (to - from) <= kRingFrames) {
            RingCopy(from, (UInt32)(to - from), buf + (from - start) * kChannels, false);
        }
        return kAudioHardwareNoError;
    }
    return kAudioHardwareNoError;
}

static OSStatus Mic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

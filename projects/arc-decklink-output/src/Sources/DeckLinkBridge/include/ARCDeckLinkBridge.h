//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

//
//  ARCDeckLinkBridge.h
//  Objective-C facade over the Blackmagic DeckLink COM API.
//
//  The DeckLink driver is loaded at runtime via CFBundle (DeckLinkAPIDispatch.cpp),
//  so this module has no link-time dependency on DeckLinkAPI.framework and is safe
//  to ship on machines without Desktop Video installed.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ARCDLKeyerMode) {
    ARCDLKeyerModeNone = 0,
    /// Device keys graphics over its own input passthrough.
    ARCDLKeyerModeInternal = 1,
    /// Device emits a fill + key pair for a downstream switcher keyer
    /// (ATEM Mini Extreme ISO G2 over Thunderbolt uses this mode).
    ARCDLKeyerModeExternal = 2,
};

extern NSErrorDomain const ARCDeckLinkErrorDomain;

typedef NS_ERROR_ENUM(ARCDeckLinkErrorDomain, ARCDeckLinkError) {
    ARCDeckLinkErrorDriverNotInstalled = 1,
    ARCDeckLinkErrorDeviceNotFound = 2,
    ARCDeckLinkErrorNoOutputInterface = 3,
    ARCDeckLinkErrorModeUnsupported = 4,
    ARCDeckLinkErrorKeyerUnsupported = 5,
    ARCDeckLinkErrorOutputFailed = 6,
};

/// Snapshot of one DeckLink-capable device (includes ATEM switchers exposed
/// over Thunderbolt by Desktop Video).
@interface ARCDLDeviceInfo : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int64_t persistentID;
@property (nonatomic, readonly) BOOL supportsPlayback;
@property (nonatomic, readonly) BOOL supportsInternalKeying;
@property (nonatomic, readonly) BOOL supportsExternalKeying;
@end

/// Synchronous BGRA fill+key playout to one DeckLink output device.
/// Not thread-safe; callers must serialize start/send/stop on one queue.
@interface ARCDLFillKeyOutput : NSObject

/// YES when /Library/Frameworks/DeckLinkAPI.framework is present and loadable.
@property (class, nonatomic, readonly) BOOL driverInstalled;

/// All playback-capable devices currently visible to the driver.
+ (NSArray<ARCDLDeviceInfo *> *)outputDevices;

/// Open the device, select a BGRA display mode matching width/height/fps,
/// and enable the requested keyer mode. Pass persistentID 0 to take the
/// first playback-capable device.
- (BOOL)startWithPersistentID:(int64_t)persistentID
                        width:(int32_t)width
                       height:(int32_t)height
                     fpsNumer:(int32_t)fpsNumer
                     fpsDenom:(int32_t)fpsDenom
                    keyerMode:(ARCDLKeyerMode)keyerMode
                        error:(NSError **)error;

/// Display one frame. `fill` must be 32BGRA at the started dimensions.
/// If `key` is non-NULL its blue channel is written into the output alpha
/// (white-on-black matte convention); otherwise `fill`'s own alpha is used.
- (BOOL)sendFrameWithFill:(CVPixelBufferRef)fill
                      key:(nullable CVPixelBufferRef)key;

- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) int32_t frameWidth;
@property (nonatomic, readonly) int32_t frameHeight;
@property (nonatomic, readonly, nullable, copy) NSString *lastErrorMessage;

@end

NS_ASSUME_NONNULL_END

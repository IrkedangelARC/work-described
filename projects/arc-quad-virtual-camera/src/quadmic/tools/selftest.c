//  selftest.c
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//  Loads the built ArcQuadMic.driver the way the Mac's audio server does (through its
//  Info.plist and its factory) and exercises it without installing it: every property of
//  every object, the clock, and the pipe between the feed side and the mic side.
//  Needs no root and touches no audio device. Run by tools/build.sh.
//
//  usage: selftest /path/to/ArcQuadMic.driver

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int gPass = 0, gFail = 0;
#define CHECK(cond, ...) do { if (cond) { gPass++; } else { gFail++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ---- a host that does nothing
static OSStatus H_PropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) { (void)h; (void)o; (void)n; (void)a; return 0; }
static OSStatus H_CopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* d) { (void)h; (void)k; if (d) *d = NULL; return 0; }
static OSStatus H_WriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h; (void)k; (void)d; return 0; }
static OSStatus H_DeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus H_RequestDeviceConfigurationChange(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 a, void* i) { (void)h; (void)o; (void)a; (void)i; return 0; }
static AudioServerPlugInHostInterface gHost = { H_PropertiesChanged, H_CopyFromStorage, H_WriteToStorage, H_DeleteFromStorage, H_RequestDeviceConfigurationChange };

static AudioServerPlugInDriverRef D = NULL;
#define DRV (*D)

static OSStatus get(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, void* out, UInt32 room, UInt32* got) {
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    return DRV->GetPropertyData(D, obj, 0, &a, 0, NULL, room, got, out);
}

static UInt32 u32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    UInt32 v = 0xDEADBEEF, got = 0;
    OSStatus e = get(obj, sel, scope, &v, sizeof(v), &got);
    CHECK(e == 0 && got == sizeof(UInt32), "u32 property %08x of object %u: err %d size %u", (unsigned)sel, (unsigned)obj, (int)e, (unsigned)got);
    return v;
}

static void str(AudioObjectID obj, AudioObjectPropertySelector sel, char* out, size_t room) {
    CFStringRef s = NULL; UInt32 got = 0;
    OSStatus e = get(obj, sel, kAudioObjectPropertyScopeGlobal, &s, sizeof(s), &got);
    out[0] = 0;
    if (e == 0 && s != NULL) CFStringGetCString(s, out, (CFIndex)room, kCFStringEncodingUTF8);
    CHECK(e == 0 && got == sizeof(CFStringRef) && out[0] != 0, "string property %08x of object %u: err %d", (unsigned)sel, (unsigned)obj, (int)e);
}

/** Every property an object says it has: the size it reports is the size it returns. */
static void sweep(AudioObjectID obj, const AudioObjectPropertySelector* sels, int n, const char* what) {
    for (int i = 0; i < n; i++) {
        AudioObjectPropertyAddress a = { sels[i], kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Boolean has = DRV->HasProperty(D, obj, 0, &a);
        CHECK(has, "%s has no property %08x", what, (unsigned)sels[i]);
        if (!has) continue;
        UInt32 size = 0xFFFFFFFF;
        OSStatus e = DRV->GetPropertyDataSize(D, obj, 0, &a, 0, NULL, &size);
        CHECK(e == 0 && size < 4096, "%s size of %08x: err %d size %u", what, (unsigned)sels[i], (int)e, (unsigned)size);
        char buf[4096]; memset(buf, 0, sizeof(buf));
        UInt32 got = 0xFFFFFFFF;
        CFStringRef q = CFSTR("ArcQuadMic_UID");
        UInt32 qs = (sels[i] == kAudioPlugInPropertyTranslateUIDToDevice || sels[i] == kAudioPlugInPropertyTranslateUIDToBox) ? sizeof(q) : 0;
        e = DRV->GetPropertyData(D, obj, 0, &a, qs, qs ? &q : NULL, size, &got, buf);
        CHECK(e == 0 && got == size, "%s get of %08x: err %d, said %u bytes, gave %u", what, (unsigned)sels[i], (int)e, (unsigned)size, (unsigned)got);
        Boolean settable = 2;
        e = DRV->IsPropertySettable(D, obj, 0, &a, &settable);
        CHECK(e == 0 && settable <= 1, "%s settable of %08x: err %d", what, (unsigned)sels[i], (int)e);
    }
    AudioObjectPropertyAddress bogus = { 'zzzz', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CHECK(!DRV->HasProperty(D, obj, 0, &bogus), "%s claims a property that does not exist", what);
    UInt32 size = 0;
    CHECK(DRV->GetPropertyDataSize(D, obj, 0, &bogus, 0, NULL, &size) == kAudioHardwareUnknownPropertyError, "%s sizes a property that does not exist", what);
}

// ---- the pipe
#define CH 2
static AudioServerPlugInIOCycleInfo cycle(Float64 inTime, Float64 outTime) {
    AudioServerPlugInIOCycleInfo c; memset(&c, 0, sizeof(c));
    c.mInputTime.mSampleTime = inTime; c.mOutputTime.mSampleTime = outTime;
    return c;
}
/** A sample that names its own place: frame f, channel c. Never zero. */
static Float32 tone(UInt64 f, int c) { return (Float32)(((f * 2 + (UInt64)c) % 20011) + 1) / 20012.0f; }

static void writeAt(UInt64 start, UInt32 frames) {
    Float32* b = malloc(frames * CH * sizeof(Float32));
    for (UInt32 i = 0; i < frames; i++) for (int c = 0; c < CH; c++) b[i * CH + c] = tone(start + i, c);
    AudioServerPlugInIOCycleInfo ci = cycle(0, (Float64)start);
    OSStatus e = DRV->DoIOOperation(D, 2, 4, 1, kAudioServerPlugInIOOperationWriteMix, frames, &ci, b, NULL);
    CHECK(e == 0, "write at %llu: err %d", (unsigned long long)start, (int)e);
    free(b);
}

/** Read [start, start+frames) and count frames that are the tone, silence, or neither. */
static void readAt(UInt64 start, UInt32 frames, UInt32* tones, UInt32* silent, UInt32* wrong) {
    Float32* b = malloc(frames * CH * sizeof(Float32));
    for (UInt32 i = 0; i < frames * CH; i++) b[i] = 9.0f;   // must be overwritten
    AudioServerPlugInIOCycleInfo ci = cycle((Float64)start, 0);
    OSStatus e = DRV->DoIOOperation(D, 2, 3, 2, kAudioServerPlugInIOOperationReadInput, frames, &ci, b, NULL);
    CHECK(e == 0, "read at %llu: err %d", (unsigned long long)start, (int)e);
    *tones = *silent = *wrong = 0;
    for (UInt32 i = 0; i < frames; i++) {
        Float32 l = b[i * CH], r = b[i * CH + 1];
        if (l == tone(start + i, 0) && r == tone(start + i, 1)) (*tones)++;
        else if (l == 0.0f && r == 0.0f) (*silent)++;
        else (*wrong)++;
    }
    free(b);
}

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: selftest /path/to/ArcQuadMic.driver\n"); return 2; }
    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, true);
    CFPlugInRef plug = CFPlugInCreate(NULL, url);
    if (plug == NULL) { printf("FAIL: the bundle would not load: %s\n", argv[1]); return 1; }

    // 1. found through Info.plist, as the audio server finds it
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plug);
    CHECK(factories != NULL && CFArrayGetCount(factories) == 1, "Info.plist names no factory for the audio server plug-in type");
    if (factories == NULL || CFArrayGetCount(factories) < 1) { printf("selftest: %d passed, %d FAILED\n", gPass, gFail); return 1; }
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    IUnknownVTbl** unknown = (IUnknownVTbl**)CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    CHECK(unknown != NULL, "the factory made nothing");
    if (unknown == NULL) { printf("selftest: %d passed, %d FAILED\n", gPass, gFail); return 1; }
    HRESULT qr = (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), (LPVOID*)&D);
    CHECK(qr == S_OK && D != NULL, "QueryInterface for the driver interface: %d", (int)qr);
    if (D == NULL) { printf("selftest: %d passed, %d FAILED\n", gPass, gFail); return 1; }
    void* none = (void*)1;
    CHECK((*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(kAudioServerPlugInTypeUUID), &none) != S_OK, "QueryInterface answers for an interface it does not have");
    CHECK(DRV->Initialize(D, &gHost) == 0, "Initialize");

    // 2. every property of every object
    const AudioObjectPropertySelector plugSel[] = { kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioObjectPropertyManufacturer, kAudioObjectPropertyOwnedObjects, kAudioPlugInPropertyDeviceList, kAudioPlugInPropertyBoxList, kAudioPlugInPropertyTranslateUIDToDevice, kAudioPlugInPropertyTranslateUIDToBox, kAudioPlugInPropertyResourceBundle };
    const AudioObjectPropertySelector devSel[] = { kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioObjectPropertyName, kAudioObjectPropertyManufacturer, kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID, kAudioObjectPropertyOwnedObjects, kAudioDevicePropertyStreams, kAudioObjectPropertyControlList, kAudioDevicePropertyRelatedDevices, kAudioDevicePropertyTransportType, kAudioDevicePropertyClockDomain, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyIsHidden, kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyPreferredChannelLayout };
    const AudioObjectPropertySelector strSel[] = { kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyName, kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection, kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel, kAudioStreamPropertyLatency, kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat, kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats };
    sweep(1, plugSel, (int)(sizeof(plugSel) / sizeof(plugSel[0])), "plug-in");
    sweep(2, devSel, (int)(sizeof(devSel) / sizeof(devSel[0])), "device");
    sweep(3, strSel, (int)(sizeof(strSel) / sizeof(strSel[0])), "mic stream");
    sweep(4, strSel, (int)(sizeof(strSel) / sizeof(strSel[0])), "feed stream");
    AudioObjectPropertyAddress any = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CHECK(!DRV->HasProperty(D, 99, 0, &any), "an object that does not exist has a name");

    // 3. the values an app sees
    char s[256];
    str(2, kAudioObjectPropertyName, s, sizeof(s));        CHECK(strcmp(s, "ARC QUAD Mic") == 0, "device name is '%s'", s);
    str(2, kAudioObjectPropertyManufacturer, s, sizeof(s)); CHECK(strcmp(s, "ARC Event Productions") == 0, "manufacturer is '%s'", s);
    str(2, kAudioDevicePropertyDeviceUID, s, sizeof(s));   CHECK(strcmp(s, "ArcQuadMic_UID") == 0, "device UID is '%s'", s);
    CHECK(u32(2, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal) == kAudioDeviceClassID, "device class");
    CHECK(u32(2, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual, "transport type");
    CHECK(u32(2, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1, "the mic side cannot be the default input");
    CHECK(u32(2, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "the feed side can be the default OUTPUT (Mac sound would reach the mic)");
    CHECK(u32(2, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput) == 0, "the feed side can take system alert sounds");
    CHECK(u32(2, kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal) == 16384, "zero time stamp period");
    AudioObjectID ids[4]; UInt32 got = 0;
    CHECK(get(2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal, ids, sizeof(ids), &got) == 0 && got == 2 * sizeof(AudioObjectID) && ids[0] == 3 && ids[1] == 4, "streams, global scope");
    CHECK(get(2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, ids, sizeof(ids), &got) == 0 && got == sizeof(AudioObjectID) && ids[0] == 3, "streams, input scope");
    CHECK(get(2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, ids, sizeof(ids), &got) == 0 && got == sizeof(AudioObjectID) && ids[0] == 4, "streams, output scope");
    CHECK(get(1, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, sizeof(ids), &got) == 0 && got == sizeof(AudioObjectID) && ids[0] == 2, "plug-in device list");
    CHECK(u32(3, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1, "mic stream is not an input");
    CHECK(u32(4, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 0, "feed stream is not an output");
    CHECK(u32(3, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal) == kAudioStreamTerminalTypeMicrophone, "mic stream terminal type");
    AudioStreamBasicDescription f; memset(&f, 0, sizeof(f));
    CHECK(get(3, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &f, sizeof(f), &got) == 0 && f.mSampleRate == 48000.0 && f.mChannelsPerFrame == 2 && f.mBitsPerChannel == 32 && f.mBytesPerFrame == 8 && (f.mFormatFlags & kAudioFormatFlagIsFloat), "mic stream format");
    Float64 rate = 0;
    CHECK(get(2, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate), &got) == 0 && rate == 48000.0, "sample rate");
    AudioObjectPropertyAddress rateAddr = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 r48 = 48000.0, r44 = 44100.0;
    CHECK(DRV->SetPropertyData(D, 2, 0, &rateAddr, 0, NULL, sizeof(r48), &r48) == 0, "setting 48 kHz is refused");
    CHECK(DRV->SetPropertyData(D, 2, 0, &rateAddr, 0, NULL, sizeof(r44), &r44) != 0, "setting 44.1 kHz is accepted");
    AudioObjectPropertyAddress nameAddr = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef other = CFSTR("x");
    CHECK(DRV->SetPropertyData(D, 2, 0, &nameAddr, 0, NULL, sizeof(other), &other) != 0, "the device name can be set");
    UInt32 small = 0;
    CHECK(get(2, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &small, sizeof(small), &got) == kAudioHardwareBadPropertySizeError, "a buffer too small for the sample rate is accepted");

    // 4. the pipe
    Boolean will = false, inPlace = false;
    CHECK(DRV->WillDoIOOperation(D, 2, 1, kAudioServerPlugInIOOperationReadInput, &will, &inPlace) == 0 && will, "will not read input");
    CHECK(DRV->WillDoIOOperation(D, 2, 1, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace) == 0 && will, "will not write the mix");
    CHECK(DRV->WillDoIOOperation(D, 2, 1, kAudioServerPlugInIOOperationMixOutput, &will, &inPlace) == 0 && !will, "claims an operation it does not do");
    CHECK(u32(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "running before any client started");
    CHECK(DRV->StopIO(D, 2, 1) != 0, "StopIO with nothing running is accepted");
    CHECK(DRV->StartIO(D, 2, 1) == 0, "StartIO");
    CHECK(u32(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1, "not running after StartIO");

    UInt32 t, z, w;
    readAt(0, 512, &t, &z, &w);                     CHECK(z == 512 && w == 0, "an empty ring is not silent: %u tone %u silent %u wrong", t, z, w);
    writeAt(1024, 512); writeAt(1536, 512);
    readAt(1024, 512, &t, &z, &w);                  CHECK(t == 512, "what was written does not come back: %u tone %u silent %u wrong", t, z, w);
    readAt(1280, 512, &t, &z, &w);                  CHECK(t == 512, "a read across two writes: %u tone %u silent %u wrong", t, z, w);
    readAt(1800, 512, &t, &z, &w);                  CHECK(t == 248 && z == 264 && w == 0, "a read past the newest write: %u tone %u silent %u wrong", t, z, w);
    readAt(900, 256, &t, &z, &w);                   CHECK(z == 124 && t == 132 && w == 0, "a read that starts before the first write: %u tone %u silent %u wrong", t, z, w);
    writeAt(4096, 512);                             // a gap of 2048 frames since 2048
    readAt(2048, 2048, &t, &z, &w);                 CHECK(z == 2048 && w == 0, "the gap between two writes is not silent: %u tone %u silent %u wrong", t, z, w);
    readAt(4096, 512, &t, &z, &w);                  CHECK(t == 512, "the write after a gap: %u tone %u silent %u wrong", t, z, w);
    writeAt(65536 - 200, 512);                      // across the end of the ring
    readAt(65536 - 200, 512, &t, &z, &w);           CHECK(t == 512, "a write across the ring's end: %u tone %u silent %u wrong", t, z, w);
    readAt(4096, 512, &t, &z, &w);                  CHECK(t == 512 && w == 0, "sound still inside the ring was lost: %u tone %u silent %u wrong", t, z, w);
    writeAt(200000, 512);                           // far ahead: everything older than the ring is gone
    readAt(4096, 512, &t, &z, &w);                  CHECK(z == 512 && w == 0, "sound older than the ring holds came back: %u tone %u silent %u wrong", t, z, w);
    readAt(200000 - 512, 1024, &t, &z, &w);         CHECK(t == 512 && z == 512 && w == 0, "silence before a far write: %u tone %u silent %u wrong", t, z, w);
    for (UInt64 at = 300000; at < 300000 + 48000 * 3; at += 480) writeAt(at, 480);   // three seconds, 10 ms blocks
    UInt32 bad = 0;
    for (UInt64 at = 300000 + 48000 * 2; at < 300000 + 48000 * 3; at += 512) { readAt(at, 256, &t, &z, &w); if (t != 256) bad++; }
    CHECK(bad == 0, "three seconds of blocks: %u reads of the last second were not whole", bad);
    readAt(300000, 512, &t, &z, &w);                CHECK(z == 512 && w == 0, "the first of three seconds should be past the ring: %u tone %u silent %u wrong", t, z, w);

    // 5. the clock: 16384 frames is 341 ms
    Float64 s0 = -1, s1 = -1; UInt64 h0 = 0, h1 = 0, seed = 0;
    CHECK(DRV->GetZeroTimeStamp(D, 2, 1, &s0, &h0, &seed) == 0 && s0 >= 0, "zero time stamp");
    usleep(400000);
    CHECK(DRV->GetZeroTimeStamp(D, 2, 1, &s1, &h1, &seed) == 0, "zero time stamp, second");
    CHECK(s1 - s0 == 16384.0, "the clock moved %.0f frames in 400 ms, not one period of 16384", s1 - s0);
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    double ms = (double)(h1 - h0) * tb.numer / tb.denom / 1e6;
    CHECK(fabs(ms - 16384.0 / 48.0) < 0.01, "one period of the clock is %.4f ms, not %.4f", ms, 16384.0 / 48.0);

    // 6. a second client, then everyone leaves and the next start is clean
    CHECK(DRV->StartIO(D, 2, 2) == 0, "second StartIO");
    CHECK(DRV->StopIO(D, 2, 1) == 0, "StopIO");
    readAt(300000 + 48000 * 2 + 512, 256, &t, &z, &w); CHECK(t == 256, "one client leaving emptied the ring for the other");
    CHECK(DRV->StopIO(D, 2, 2) == 0, "second StopIO");
    CHECK(u32(2, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "still running after everyone stopped");
    CHECK(DRV->StartIO(D, 2, 1) == 0, "StartIO again");
    readAt(300000 + 48000 * 2 + 512, 256, &t, &z, &w); CHECK(z == 256 && w == 0, "the last run's sound came out of the microphone after a restart");
    readAt(0, 4096, &t, &z, &w);                    CHECK(z == 4096 && w == 0, "the ring was not emptied by a restart");
    CHECK(DRV->StopIO(D, 2, 1) == 0, "last StopIO");

    printf("selftest: %d passed, %d FAILED\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}

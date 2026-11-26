//  looptest.c
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//  The proof AFTER the install: plays a quiet 1 kHz tone into the feed side of the installed
//  "ARC QUAD Mic" and records its mic side for three seconds, through the Mac's real audio
//  server. PASS means an app that picks ARC QUAD Mic will hear what the console plays.
//  The tone goes nowhere else: not to the speakers, not to a file.
//
//  macOS asks once for microphone access for the terminal that runs this (it records from a
//  microphone). Without it the Mac hands back silence and this reports so.
//
//  usage: looptest

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

#define RATE 48000.0
#define TONE_HZ 1000.0
#define TONE_AMP 0.1            // -20 dBFS peak, -23 dB RMS

static _Atomic unsigned long gOutFrames = 0, gInFrames = 0, gCrossings = 0, gCycles = 0;
static double gSumSq = 0.0, gDelayFrames = 0.0;
static float gLast = 0.0f;
static unsigned long gPhase = 0;

static OSStatus io(AudioObjectID dev, const AudioTimeStamp* now, const AudioBufferList* in, const AudioTimeStamp* inTime,
                   AudioBufferList* out, const AudioTimeStamp* outTime, void* ctx) {
    (void)dev; (void)now; (void)ctx;
    if (out != NULL && out->mNumberBuffers > 0 && out->mBuffers[0].mData != NULL) {
        UInt32 ch = out->mBuffers[0].mNumberChannels ? out->mBuffers[0].mNumberChannels : 2;
        UInt32 frames = out->mBuffers[0].mDataByteSize / (ch * sizeof(Float32));
        Float32* o = (Float32*)out->mBuffers[0].mData;
        for (UInt32 i = 0; i < frames; i++, gPhase++) {
            Float32 v = (Float32)(TONE_AMP * sin(2.0 * M_PI * TONE_HZ * (double)gPhase / RATE));
            for (UInt32 c = 0; c < ch; c++) o[i * ch + c] = v;
        }
        atomic_fetch_add(&gOutFrames, frames);
    }
    if (in != NULL && in->mNumberBuffers > 0 && in->mBuffers[0].mData != NULL) {
        UInt32 ch = in->mBuffers[0].mNumberChannels ? in->mBuffers[0].mNumberChannels : 2;
        UInt32 frames = in->mBuffers[0].mDataByteSize / (ch * sizeof(Float32));
        const Float32* s = (const Float32*)in->mBuffers[0].mData;
        unsigned long cycle = atomic_fetch_add(&gCycles, 1);
        if (cycle > 50) {       // the first cycles are the pipe filling: not measured
            for (UInt32 i = 0; i < frames; i++) {
                float v = s[i * ch];
                gSumSq += (double)v * v;
                if (gLast <= 0.0f && v > 0.0f) atomic_fetch_add(&gCrossings, 1);
                gLast = v;
            }
            atomic_fetch_add(&gInFrames, frames);
            if (inTime != NULL && outTime != NULL) gDelayFrames = outTime->mSampleTime - inTime->mSampleTime;
        }
    }
    return 0;
}

int main(void) {
    CFStringRef uid = CFSTR("ArcQuadMic_UID");
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    OSStatus e = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &size, &dev);
    if (e != 0 || dev == kAudioObjectUnknown) {
        printf("NOT INSTALLED: this Mac has no ARC QUAD Mic device. Run quadmic/tools/install.sh first.\n");
        return 2;
    }
    AudioDeviceIOProcID proc = NULL;
    e = AudioDeviceCreateIOProcID(dev, io, NULL, &proc);
    if (e != 0) { printf("FAIL: the device would not take an IO proc (error %d)\n", (int)e); return 1; }
    e = AudioDeviceStart(dev, proc);
    if (e != 0) { printf("FAIL: the device would not start (error %d)\n", (int)e); return 1; }
    usleep(3200000);
    AudioDeviceStop(dev, proc);
    AudioDeviceDestroyIOProcID(dev, proc);

    unsigned long outF = atomic_load(&gOutFrames), inF = atomic_load(&gInFrames), x = atomic_load(&gCrossings);
    if (outF == 0) { printf("FAIL: the feed side asked for no sound in 3 seconds\n"); return 1; }
    if (inF == 0) { printf("FAIL: the mic side gave no sound in 3 seconds\n"); return 1; }
    double rms = sqrt(gSumSq / (double)inF);
    double db = rms > 0 ? 20.0 * log10(rms) : -200.0;
    double hz = (double)x * RATE / (double)inF;
    double want = 20.0 * log10(TONE_AMP / sqrt(2.0));
    printf("played %lu frames, recorded %lu frames\n", outF, inF);
    printf("came back at %.1f dB RMS (sent %.1f), %.0f Hz (sent %.0f), %.0f ms through the device\n", db, want, hz, TONE_HZ, gDelayFrames / RATE * 1000.0);
    if (rms == 0.0) {
        printf("FAIL: silence. If macOS asked for microphone access for this terminal, allow it in System Settings, Privacy and Security, Microphone, then run this again.\n");
        return 1;
    }
    if (fabs(db - want) > 1.0 || fabs(hz - TONE_HZ) > 5.0) { printf("FAIL: what came back is not the tone that went in\n"); return 1; }
    printf("PASS: ARC QUAD Mic carries sound from its feed side to its mic side\n");
    return 0;
}

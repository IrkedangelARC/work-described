//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * The app plays these tones into a room nobody is standing in while it is being
 * built, so "an AudioTrack is started" proves nothing about what is coming out.
 * These tests check the actual samples.
 */
class SignalGeneratorTest {

    private val rate = 48_000

    private fun render(spec: AudioSpec, frames: Int): Pair<DoubleArray, DoubleArray> {
        val buf = ShortArray(frames * 2)
        fillBuffer(spec, GeneratorState(), buf, frames, rate)
        val l = DoubleArray(frames) { buf[it * 2] / 32767.0 }
        val r = DoubleArray(frames) { buf[it * 2 + 1] / 32767.0 }
        return l to r
    }

    private fun rms(x: DoubleArray) = sqrt(x.sumOf { it * it } / x.size)

    /** Count zero crossings to recover frequency without needing an FFT. */
    private fun freqOf(x: DoubleArray): Double {
        var crossings = 0
        for (i in 1 until x.size) if ((x[i - 1] < 0.0) != (x[i] < 0.0)) crossings++
        return crossings * rate / (2.0 * x.size)
    }

    @Test
    fun sineHasCorrectFrequencyAndLevel() {
        val (l, r) = render(AudioSpec(Waveform.SINE, Channels.BOTH, 1000.0), rate)
        assertEquals(1000.0, freqOf(l), 2.0)
        // -20 dBFS sine: peak 0.1, RMS = 0.1 / sqrt(2) = 0.0707
        assertEquals(0.0707, rms(l), 0.002)
        assertEquals(rms(l), rms(r), 1e-9)
    }

    @Test
    fun levelFollowsDbfs() {
        val (l, _) = render(AudioSpec(Waveform.SINE, Channels.BOTH, 1000.0, levelDbfs = -6.0), rate)
        // -6 dBFS: peak 0.501, RMS 0.354
        assertEquals(0.354, rms(l), 0.004)
    }

    @Test
    fun neverEmitsFullScale() {
        // A safety property, not a style preference: this feeds a PA.
        for (w in Waveform.entries) {
            val (l, r) = render(AudioSpec(w, Channels.BOTH), rate / 4)
            val peak = maxOf(l.maxOf { abs(it) }, r.maxOf { abs(it) })
            assertTrue("$w peaked at $peak, should stay well under full scale", peak < 0.2)
        }
    }

    @Test
    fun leftOnlySilencesRight() {
        val (l, r) = render(AudioSpec(Waveform.SINE, Channels.LEFT, 1000.0), 4800)
        assertTrue("left should carry signal", rms(l) > 0.05)
        assertEquals("right must be silent", 0.0, rms(r), 1e-12)
    }

    @Test
    fun rightOnlySilencesLeft() {
        val (l, r) = render(AudioSpec(Waveform.SINE, Channels.RIGHT, 1000.0), 4800)
        assertEquals("left must be silent", 0.0, rms(l), 1e-12)
        assertTrue("right should carry signal", rms(r) > 0.05)
    }

    @Test
    fun polarityInversionCancelsWhenSummed() {
        val (l, r) = render(
            AudioSpec(Waveform.SINE, Channels.BOTH, 1000.0, invertRight = true), 4800
        )
        val sum = DoubleArray(l.size) { l[it] + r[it] }
        assertTrue("each channel must carry signal", rms(l) > 0.05 && rms(r) > 0.05)
        // This is the whole point of the test pattern: mono-fold should null.
        assertTrue("mono sum should cancel, got ${rms(sum)}", rms(sum) < 1e-4)
    }

    @Test
    fun pinkNoiseIsBroadbandAndBounded() {
        val (l, _) = render(AudioSpec(Waveform.PINK, Channels.BOTH), rate)
        assertTrue("pink noise should have energy", rms(l) > 0.005)
        assertTrue("pink noise should not clip", l.maxOf { abs(it) } < 0.2)
        // Broadband, so far more zero crossings than a 1 kHz tone.
        assertTrue("should be broadband", freqOf(l) > 1500.0)
    }

    @Test
    fun sweepRisesInFrequency() {
        val spec = AudioSpec(Waveform.SWEEP, Channels.BOTH, sweepSeconds = 4.0)
        val frames = rate * 4
        val buf = ShortArray(frames * 2)
        fillBuffer(spec, GeneratorState(), buf, frames, rate)
        val ch = DoubleArray(frames) { buf[it * 2] / 32767.0 }
        val first = freqOf(ch.copyOfRange(0, rate / 2))
        val last = freqOf(ch.copyOfRange(frames - rate / 2, frames))
        assertTrue("sweep should start low, got $first Hz", first < 200.0)
        assertTrue("sweep should end high, got $last Hz", last > 8000.0)
        assertTrue("sweep should rise", last > first * 20)
    }

    @Test
    fun phaseIsContinuousAcrossBuffers() {
        // A reset per buffer would put a click every 1024 samples.
        val spec = AudioSpec(Waveform.SINE, Channels.BOTH, 1000.0)
        val st = GeneratorState()
        val a = ShortArray(2048); val b = ShortArray(2048)
        fillBuffer(spec, st, a, 1024, rate)
        fillBuffer(spec, st, b, 1024, rate)
        val lastOfA = a[2046] / 32767.0
        val firstOfB = b[0] / 32767.0
        // One sample of 1 kHz at 48 kHz moves at most ~0.014 in amplitude.
        assertTrue("discontinuity of ${abs(firstOfB - lastOfA)} between buffers",
            abs(firstOfB - lastOfA) < 0.02)
    }
}

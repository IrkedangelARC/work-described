//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/** Which channels carry signal. Polarity is separate so it can be combined. */
enum class Channels { BOTH, LEFT, RIGHT }

enum class Waveform { SINE, PINK, SWEEP }

/**
 * What to generate.
 *
 * LEVEL IS IN dBFS AND DEFAULTS TO -20. This feeds a PA on a load-in. A -20 dBFS
 * reference tone is the broadcast convention and leaves 20 dB of headroom; full
 * scale into a system with the gain already up can damage drivers and people.
 * Nothing in this app emits 0 dBFS.
 */
data class AudioSpec(
    val waveform: Waveform,
    val channels: Channels = Channels.BOTH,
    val frequencyHz: Double = 1000.0,
    val levelDbfs: Double = -20.0,
    /** Invert the RIGHT channel, for mono-fold and polarity checks. */
    val invertRight: Boolean = false,
    /** Log sweep endpoints and duration, used only by SWEEP. */
    val sweepStartHz: Double = 20.0,
    val sweepEndHz: Double = 20000.0,
    val sweepSeconds: Double = 10.0
) {
    val amplitude: Double get() = 10.0.pow(levelDbfs / 20.0)
}


/**
 * Mutable per-stream state, carried across buffers.
 * Phase continuity matters: resetting it every buffer would put a click at
 * 1024-sample intervals, which on a sweep or tone is exactly the kind of
 * artefact the operator would be hunting for.
 */
class GeneratorState(seed: Int = 1) {
    var phase = 0.0
    var sweepT = 0.0
    var b0 = 0.0; var b1 = 0.0; var b2 = 0.0
    val rnd = Random(seed)
}

/**
 * Fill one interleaved stereo buffer. Pure apart from [st], so it can be tested
 * on the JVM. There is no other way to verify a tone this app plays into a room
 * nobody is standing in.
 */
fun fillBuffer(spec: AudioSpec, st: GeneratorState, buf: ShortArray, frames: Int, rate: Int = 48_000) {
    val amp = spec.amplitude
    for (i in 0 until frames) {
        val sample: Double = when (spec.waveform) {
            Waveform.SINE -> {
                st.phase += 2.0 * PI * spec.frequencyHz / rate
                if (st.phase > 2 * PI) st.phase -= 2 * PI
                sin(st.phase)
            }
            Waveform.PINK -> {
                val white = st.rnd.nextDouble() * 2.0 - 1.0
                st.b0 = 0.99765 * st.b0 + white * 0.0990460
                st.b1 = 0.96300 * st.b1 + white * 0.2965164
                st.b2 = 0.57000 * st.b2 + white * 1.0526913
                (st.b0 + st.b1 + st.b2 + white * 0.1848) * 0.22
            }
            Waveform.SWEEP -> {
                // Logarithmic: constant octaves per second, so the ear hears an
                // even rise rather than a rush through the top two octaves.
                val f = spec.sweepStartHz *
                    (spec.sweepEndHz / spec.sweepStartHz).pow(st.sweepT / spec.sweepSeconds)
                st.phase += 2.0 * PI * f / rate
                if (st.phase > 2 * PI) st.phase -= 2 * PI
                st.sweepT += 1.0 / rate
                if (st.sweepT >= spec.sweepSeconds) { st.sweepT = 0.0; st.phase = 0.0 }
                sin(st.phase)
            }
        }
        val v = (sample * amp * Short.MAX_VALUE).toInt()
            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        val zero: Short = 0
        val left = if (spec.channels == Channels.RIGHT) zero else v
        val rawRight = if (spec.channels == Channels.LEFT) zero else v
        val right = if (spec.invertRight) (-rawRight).toShort() else rawRight
        buf[i * 2] = left
        buf[i * 2 + 1] = right
    }
}

/**
 * Continuous stereo generator on a background thread.
 *
 * Streams rather than looping a static buffer so the sweep can run
 * indefinitely and so a spec change takes effect immediately. AudioTrack.write
 * blocks, which paces the thread for us; there is no timing loop to get wrong.
 */
object SignalGenerator {

    private const val RATE = 48_000
    private var track: AudioTrack? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var spec: AudioSpec? = null

    val isRunning: Boolean get() = running

    @Synchronized
    fun start(newSpec: AudioSpec) {
        if (running && spec == newSpec) return
        stop()
        spec = newSpec

        val minBuf = AudioTrack.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(4096)

        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(minBuf * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        track = t
        running = true
        t.play()

        thread = Thread {
            val frames = 1024
            val buf = ShortArray(frames * 2)
            val st = GeneratorState()
            while (running) {
                val s = spec ?: break
                fillBuffer(s, st, buf, frames, RATE)
                val written = runCatching { t.write(buf, 0, buf.size) }.getOrDefault(-1)
                if (written < 0) break
            }
        }.apply { name = "arc-signal-audio"; start() }
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        track?.runCatching { pause(); flush(); stop(); release() }
        track = null
        spec = null
    }
}

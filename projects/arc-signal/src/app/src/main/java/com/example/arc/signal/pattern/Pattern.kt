//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.pattern

import com.example.arc.signal.audio.AudioSpec
import com.example.arc.signal.video.Clip
import com.example.arc.signal.audio.Channels
import com.example.arc.signal.audio.Waveform
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import kotlin.math.roundToInt

/**
 * A test pattern is a function that paints the full output surface.
 *
 * EVERYTHING IS DRAWN, NOT BLITTED. DrawScope coordinates here are DEVICE
 * PIXELS, and on the AYN Thor the 1920x1080 window is pixel-mapped 1:1 into the
 * sink (verified: logicalFrame 1920x1080 -> physicalFrame 1920x1080 at y=100 of
 * a 1280-tall panel, identical dimensions, so no scaling). That is what makes a
 * 1px feature meaningful. Never ship a 1920x1080 bitmap and scale it: a scaled
 * grid line or checkerboard is worse than useless because it looks plausible
 * while being wrong.
 */
class Pattern(
    val id: String,
    val name: String,
    val category: PatternCategory,
    /** Shown in the HUD. Say what the pattern PROVES, not what it looks like. */
    val note: String? = null,
    /** Non-null on audio tests. The host starts and stops the generator from this. */
    val audio: AudioSpec? = null,
    /** Non-null on frame-rate tests. The host renders video instead of a Canvas. */
    val clip: Clip? = null,
    val draw: DrawScope.() -> Unit
)

enum class PatternCategory(val label: String) {
    FIELD("FLAT FIELDS"),
    RAMP("RAMPS & WEDGES"),
    BARS("COLOUR BARS"),
    GEOMETRY("GEOMETRY"),
    CHART("CHARTS"),
    AUDIO("AUDIO"),
    VIDEO("FRAME RATE")
}

/** Exact 8-bit sRGB, written as levels so the intent is auditable. */
private fun lvl(v: Int): Color = Color(v, v, v)
private fun rgb(r: Int, g: Int, b: Int): Color = Color(r, g, b)

private fun DrawScope.fill(c: Color) = drawRect(color = c, topLeft = Offset.Zero, size = size)

/**
 * A true 8-bit ramp: one column (or row) per pixel, quantised to the nearest
 * code value. Deliberately NOT a smooth gradient brush. If the chain is
 * dithering, truncating, or crushing at either end, a real quantised ramp shows
 * it and an interpolated one hides it.
 */
private fun DrawScope.ramp(horizontal: Boolean) {
    val span = if (horizontal) size.width else size.height
    val n = span.roundToInt().coerceAtLeast(1)
    for (i in 0 until n) {
        val v = ((i.toFloat() / (n - 1).coerceAtLeast(1)) * 255f).roundToInt().coerceIn(0, 255)
        if (horizontal) {
            drawRect(lvl(v), topLeft = Offset(i.toFloat(), 0f), size = Size(1f, size.height))
        } else {
            drawRect(lvl(v), topLeft = Offset(0f, i.toFloat()), size = Size(size.width, 1f))
        }
    }
}

/** N equal steps across the full 0-255 range, endpoints included. */
private fun DrawScope.stepWedge(steps: Int) {
    val w = size.width / steps
    for (i in 0 until steps) {
        val v = ((i.toFloat() / (steps - 1)) * 255f).roundToInt().coerceIn(0, 255)
        // Round the right edge to the surface width so no seam is left at the end.
        val x0 = i * w
        val x1 = if (i == steps - 1) size.width else (i + 1) * w
        drawRect(lvl(v), topLeft = Offset(x0, 0f), size = Size(x1 - x0, size.height))
    }
}

/**
 * PLUGE: black surrounded by sub-black and above-black bars. Set brightness so
 * the -2% bar is just invisible and the +2% bar is just visible. Sub-black
 * cannot be represented in full-range 8-bit RGB, so these are 0 / 2% / 4%
 * relative to black; label honestly in the note.
 */
private fun DrawScope.pluge() {
    fill(lvl(0))
    val bw = size.width / 12f
    val h = size.height * 0.5f
    val y = (size.height - h) / 2f
    // 0%, 2%, 4% above black, then a 100% white reference at the far right.
    val levels = intArrayOf(0, 5, 10)
    levels.forEachIndexed { i, v ->
        drawRect(lvl(v), topLeft = Offset(bw * (3 + i), y), size = Size(bw, h))
    }
    drawRect(lvl(255), topLeft = Offset(bw * 8, y), size = Size(bw, h))
}

object PatternLibrary {

    private val base: List<Pattern> = listOf(
        // ---- flat fields ----
        Pattern("black", "Black 0%", PatternCategory.FIELD,
            "Black level and panel uniformity. Look for backlight bleed and stuck pixels.") { fill(lvl(0)) },
        Pattern("white", "White 100%", PatternCategory.FIELD,
            "Peak level, uniformity, and colour tint across the panel.") { fill(lvl(255)) },
        Pattern("grey50", "Grey 50%", PatternCategory.FIELD,
            "Mid grey. Any colour cast here is a white-balance or matrix error.") { fill(lvl(128)) },
        Pattern("grey75", "Grey 75%", PatternCategory.FIELD,
            "75% grey, the level the 75% bars are keyed to.") { fill(lvl(191)) },
        Pattern("red", "Red 100%", PatternCategory.FIELD,
            "Full red. Checks the R channel end to end.") { fill(rgb(255, 0, 0)) },
        Pattern("green", "Green 100%", PatternCategory.FIELD,
            "Full green. Also the harshest test of chroma subsampling.") { fill(rgb(0, 255, 0)) },
        Pattern("blue", "Blue 100%", PatternCategory.FIELD,
            "Full blue. Blue-only is the classic way to set chroma and phase.") { fill(rgb(0, 0, 255)) },
        Pattern("cyan", "Cyan 100%", PatternCategory.FIELD, null) { fill(rgb(0, 255, 255)) },
        Pattern("magenta", "Magenta 100%", PatternCategory.FIELD, null) { fill(rgb(255, 0, 255)) },
        Pattern("yellow", "Yellow 100%", PatternCategory.FIELD, null) { fill(rgb(255, 255, 0)) },

        // ---- ramps and wedges ----
        Pattern("ramp_h", "Ramp, horizontal", PatternCategory.RAMP,
            "True 8-bit quantised ramp. Banding here is real, not an artefact of the pattern.") { ramp(true) },
        Pattern("ramp_v", "Ramp, vertical", PatternCategory.RAMP,
            "Vertical ramp. Catches row-driver and scaler faults the horizontal one misses.") { ramp(false) },
        Pattern("wedge11", "Step wedge, 11", PatternCategory.RAMP,
            "0 to 100% in 10% steps. Every step must be distinct at both ends.") { stepWedge(11) },
        Pattern("wedge21", "Step wedge, 21", PatternCategory.RAMP,
            "0 to 100% in 5% steps, for finer gamma work.") { stepWedge(21) },
        Pattern("pluge", "PLUGE", PatternCategory.RAMP,
            "Set brightness so the 2% bar is just invisible and 4% is just visible.") { pluge() },

        // ---- colour bars ----
        Pattern("bars75", "SMPTE-style bars 75%", PatternCategory.BARS,
            "Bar order and levels. Kill red and green to check chroma on the reverse row.") { smpteBars() },
        Pattern("bars100", "Bars 100%", PatternCategory.BARS,
            "Full-amplitude bars. Clipping or bleeding here is a level or gamut fault.") { bars100() },
        Pattern("bars_ebu", "EBU bars 75%", PatternCategory.BARS,
            "Eight equal bars, white through blue plus black.") { barsEbu() },

        // ---- geometry ----
        Pattern("grid", "Grid + circle", PatternCategory.GEOMETRY,
            "16x9 crosshatch, centre cross, aspect circle. An ellipse means the chain is stretching.") { grid() },
        Pattern("safe", "Safe areas", PatternCategory.GEOMETRY,
            "Picture edge, 93% and 90%. Anything outside the amber box may be cropped.") { safeAreas() },
        Pattern("check1", "Checkerboard 1px", PatternCategory.GEOMETRY,
            "Harshest scaler test. Anything but a crisp dither means the chain is resampling.") { checker(1) },
        Pattern("check8", "Checkerboard 8px", PatternCategory.GEOMETRY,
            "Coarser checker for judging overshoot and ringing on edges.") { checker(8) },

        // ---- charts ----
        Pattern("colorchecker", "ColorChecker 24", PatternCategory.CHART,
            "X-Rite Classic patches, sampled from the ARC training deck.") { colorChecker() },
        Pattern("avsync_twitch", "AV sync, Twitch", PatternCategory.CHART,
            "1920x1080, 1:1. Read the marker against the scale for audio/video offset.") { assetChart("avsync_twitch.png") },
        Pattern("avsync_edyds", "AV sync, edyds", PatternCategory.CHART,
            "1920x1078, 1:1. Millisecond scale plus 25 and 50 fps rows.") { assetChart("avsync_edyds.png") },
        Pattern("pm5544", "Philips-style circle", PatternCategory.CHART,
            "3840x2160 source, resampled 2:1 to this output. Geometry is valid, finest detail is not.") { assetChart("pm5544.jpg") },
        Pattern("chart4k", "4K resolution chart", PatternCategory.CHART,
            "3840x2160 source, resampled 2:1. Wedges finer than 2px cannot be judged here.") { assetChart("chart4k.png") },

        // ---- audio, generated at runtime ----
        audioPattern("tone1k", "1 kHz tone",
            "Level reference. -20 dBFS is the broadcast convention, 20 dB of headroom.",
            AudioSpec(Waveform.SINE, Channels.BOTH, 1000.0)),
        audioPattern("tone1k_l", "1 kHz, LEFT only",
            "Proves channel mapping. Sound from the right means the cable is swapped.",
            AudioSpec(Waveform.SINE, Channels.LEFT, 1000.0)),
        audioPattern("tone1k_r", "1 kHz, RIGHT only",
            "Proves channel mapping. Sound from the left means the cable is swapped.",
            AudioSpec(Waveform.SINE, Channels.RIGHT, 1000.0)),
        audioPattern("tone_polarity", "Polarity check",
            "Right inverted. Summed to mono this should nearly cancel; if it does not, check polarity.",
            AudioSpec(Waveform.SINE, Channels.BOTH, 1000.0, invertRight = true)),
        audioPattern("pink", "Pink noise",
            "Equal energy per octave. Use for system response and to find rattles.",
            AudioSpec(Waveform.PINK, Channels.BOTH)),
        audioPattern("sweep", "Sweep 20 Hz - 20 kHz",
            "10 s log sweep, looping. Hunts buzzes, rattles and response holes.",
            AudioSpec(Waveform.SWEEP, Channels.BOTH))
    )

    /** Audio tests all share one visual, driven by their own spec. */
    private fun audioPattern(id: String, name: String, note: String, spec: AudioSpec) =
        Pattern(id, name, PatternCategory.AUDIO, note, spec) { audioVisual(spec) }

    /**
     * The live list. Video patterns are discovered off the microSD at startup,
     * so this is rebuilt once rather than being a compile-time constant.
     * Callers index into it, so rebuild BEFORE navigation starts.
     */
    var all: List<Pattern> = base
        private set

    fun setClips(clips: List<Clip>) {
        all = base + clips.map { c ->
            Pattern(
                id = "clip_${c.name}",
                name = c.name,
                category = PatternCategory.VIDEO,
                note = "Clip is ${c.label}. Tests the downstream chain's motion handling, " +
                    "not this device's output timing.",
                clip = c
            ) { /* rendered by VideoScreen, not the Canvas */ }
        }
    }


    val byCategory: List<Pair<PatternCategory, List<Pattern>>>
        get() = PatternCategory.entries.mapNotNull { cat ->
            all.filter { it.category == cat }.takeIf { it.isNotEmpty() }?.let { cat to it }
        }

    fun indexOf(id: String): Int = all.indexOfFirst { it.id == id }

    /** First index of each category, in library order. Follows `all`. */
    private val categoryStarts: List<Int>
        get() = byCategory.map { (_, items) -> all.indexOf(items.first()) }

    /** Wrapping step through the flat list. */
    fun step(current: Int, delta: Int): Int {
        if (all.isEmpty()) return -1
        val n = all.size
        return ((current + delta) % n + n) % n
    }

    /**
     * Jump to the first pattern of the previous/next category. Uses the
     * CURRENT pattern's category rather than the nearest start index, so
     * stepping down mid-category lands where the operator expects.
     */
    fun stepCategory(current: Int, delta: Int): Int {
        if (categoryStarts.isEmpty()) return current
        val cur = all.getOrNull(current) ?: return categoryStarts.first()
        val catIdx = byCategory.indexOfFirst { it.first == cur.category }.coerceAtLeast(0)
        val n = categoryStarts.size
        return categoryStarts[((catIdx + delta) % n + n) % n]
    }
}

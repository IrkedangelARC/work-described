//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.pattern

import android.graphics.Paint
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import com.example.arc.signal.audio.AudioSpec
import com.example.arc.signal.audio.Channels
import com.example.arc.signal.audio.Waveform

/**
 * An audio test still needs a picture: the operator is standing at the far end
 * of a room deciding whether the sound they hear is coming from the side the
 * screen says it should. Big, unambiguous, readable across a ballroom.
 */

private fun paint(sizePx: Float, argb: Int, bold: Boolean = false) = Paint().apply {
    color = argb
    textSize = sizePx
    isAntiAlias = true
    textAlign = Paint.Align.CENTER
    typeface = android.graphics.Typeface.create(
        android.graphics.Typeface.MONOSPACE,
        if (bold) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL
    )
}

internal fun DrawScope.audioVisual(spec: AudioSpec) {
    val w = size.width
    val h = size.height
    drawRect(Color(0xFF0A0A0A), topLeft = Offset.Zero, size = size)

    val active = Color(0xFF2E7D32)
    val idle = Color(0xFF202020)
    val ink = 0xFFE6E6E6.toInt()
    val dim = 0xFF8A8A8A.toInt()
    val accent = 0xFFC1272D.toInt()

    // Two big channel blocks. Lit = this channel should be audible.
    val boxW = w * 0.32f
    val boxH = h * 0.34f
    val boxY = h * 0.30f
    val leftOn = spec.channels != Channels.RIGHT
    val rightOn = spec.channels != Channels.LEFT
    drawRect(if (leftOn) active else idle, Offset(w * 0.09f, boxY), Size(boxW, boxH))
    drawRect(if (rightOn) active else idle, Offset(w * 0.59f, boxY), Size(boxW, boxH))

    drawContext.canvas.nativeCanvas.apply {
        drawText("LEFT", w * 0.09f + boxW / 2, boxY + boxH * 0.62f,
            paint(h * 0.14f, if (leftOn) ink else dim, bold = true))
        drawText("RIGHT", w * 0.59f + boxW / 2, boxY + boxH * 0.62f,
            paint(h * 0.14f, if (rightOn) ink else dim, bold = true))

        val title = when (spec.waveform) {
            Waveform.SINE -> "%.0f Hz TONE".format(spec.frequencyHz)
            Waveform.PINK -> "PINK NOISE"
            Waveform.SWEEP -> "SWEEP %.0f Hz - %.0f kHz".format(
                spec.sweepStartHz, spec.sweepEndHz / 1000.0)
        }
        drawText(title, w / 2f, h * 0.16f, paint(h * 0.09f, ink, bold = true))
        drawText("%.0f dBFS".format(spec.levelDbfs), w / 2f, h * 0.24f, paint(h * 0.045f, dim))

        if (spec.invertRight) {
            drawText("RIGHT CHANNEL INVERTED", w / 2f, h * 0.78f, paint(h * 0.055f, accent, bold = true))
            drawText("Sum to mono: this should nearly cancel.", w / 2f, h * 0.85f,
                paint(h * 0.038f, dim))
        } else if (spec.channels != Channels.BOTH) {
            val side = if (spec.channels == Channels.LEFT) "LEFT" else "RIGHT"
            drawText("Sound must come from $side only.", w / 2f, h * 0.80f, paint(h * 0.042f, dim))
        }
    }
}

//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.pattern

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Photographic and third-party charts that cannot sensibly be drawn.
 *
 * These live in assets/, NOT res/drawable. The resource system scales drawables
 * by display density and this device reports 369 dpi, which would resample every
 * chart before we ever saw it. assets/ plus inScaled=false is the only way to
 * get the pixels that are actually in the file.
 */
object AssetHolder {
    @Volatile var context: Context? = null
}

private class Loaded(val image: ImageBitmap, val srcW: Int, val srcH: Int, val decodedW: Int)

private val cache = HashMap<String, Loaded>()

/**
 * Decode sized to the surface.
 *
 * inSampleSize is chosen as the largest power of two that still leaves the
 * decoded bitmap at or above the target, so a 3840x2160 chart on a 1920x1080
 * surface decodes at exactly 1920x1080 and blits 1:1 with no second resample.
 * Decoding these at full size would also cost 33 MB each.
 */
private fun load(name: String, targetW: Int, targetH: Int): Loaded? {
    val ctx = AssetHolder.context ?: return null
    val key = "$name@$targetW x $targetH"
    cache[key]?.let { return it }

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    runCatching {
        ctx.assets.open("patterns/$name").use { BitmapFactory.decodeStream(it, null, bounds) }
    }.getOrNull()
    val sw = bounds.outWidth
    val sh = bounds.outHeight
    if (sw <= 0 || sh <= 0) return null

    var sample = 1
    while (sw / (sample * 2) >= targetW && sh / (sample * 2) >= targetH) sample *= 2

    val opts = BitmapFactory.Options().apply {
        inSampleSize = sample
        inScaled = false                 // never let density touch a test chart
        inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
    }
    val bmp = runCatching {
        ctx.assets.open("patterns/$name").use { BitmapFactory.decodeStream(it, null, opts) }
    }.getOrNull() ?: return null

    val out = Loaded(bmp.asImageBitmap(), sw, sh, bmp.width)
    cache[key] = out
    return out
}

/** Aspect-preserving fit, centred, letterboxed in black. Never stretches. */
internal fun DrawScope.assetChart(name: String) {
    val w = size.width
    val h = size.height
    drawRect(Color.Black, topLeft = Offset.Zero, size = size)
    val l = load(name, w.roundToInt(), h.roundToInt())
    if (l == null) {
        // Fail visibly rather than showing a plausible black screen.
        drawRect(Color(0xFF401010), topLeft = Offset(w * 0.1f, h * 0.45f),
            size = Size(w * 0.8f, h * 0.1f))
        return
    }
    val iw = l.image.width.toFloat()
    val ih = l.image.height.toFloat()
    val scale = min(w / iw, h / ih)
    val dw = (iw * scale).roundToInt()
    val dh = (ih * scale).roundToInt()
    val dx = ((w - dw) / 2f).roundToInt()
    val dy = ((h - dh) / 2f).roundToInt()
    drawImage(
        image = l.image,
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(l.image.width, l.image.height),
        dstOffset = IntOffset(dx, dy),
        dstSize = IntSize(dw, dh),
        filterQuality = FilterQuality.High
    )
}

/**
 * Decode every chart up front, off the draw thread.
 *
 * The first draw of a chart used to decode inline, which stuttered and produced
 * a visibly torn frame on the output. Charts are a fixed, small set, so warming
 * them at startup costs one background pass and removes the problem entirely.
 */
fun preloadCharts(targetW: Int, targetH: Int) {
    Thread {
        listOf("avsync_twitch.png", "avsync_edyds.png", "pm5544.jpg", "chart4k.png")
            .forEach { runCatching { load(it, targetW, targetH) } }
    }.apply { priority = Thread.MIN_PRIORITY }.start()
}

/** Source dimensions, for an honest note about whether the operator sees 1:1. */
internal fun assetSourceSize(name: String): Pair<Int, Int>? {
    val ctx = AssetHolder.context ?: return null
    val b = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    runCatching {
        ctx.assets.open("patterns/$name").use { BitmapFactory.decodeStream(it, null, b) }
    }.getOrNull()
    return if (b.outWidth > 0) b.outWidth to b.outHeight else null
}

//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.video

import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.MediaStore
import kotlin.math.abs
import androidx.core.content.ContextCompat

/**
 * Frame-rate test clips, read off the microSD rather than baked into the APK.
 *
 * WHY MEDIASTORE AND NOT A FILE PATH: an app cannot open arbitrary paths on
 * removable storage on Android 11+. Putting the clips in a standard media
 * folder (Movies/ARC_SIGNAL) means MediaStore indexes them and READ_MEDIA_VIDEO
 * is enough. The alternative, an app-scoped directory, is a documented trap on
 * this device: adb push into Android/data/<pkg> hands the file to `shell` and
 * the app can no longer read it.
 */
data class Clip(
    val name: String,
    val uri: Uri,
    val width: Int,
    val height: Int,
    /** Measured from frame count over duration, so 23.976 reads as 23.976. */
    val fps: Double,
    val durationMs: Long
) {
    /**
     * The canonical rate this clip matches, or null if it matches nothing.
     *
     * fps is derived from frame count over duration and duration is only
     * millisecond-accurate, so a 23.976 clip measures around 23.970. Reporting
     * the raw figure would be honest but unhelpful: 23.976 is the name of that
     * rate in this trade, and the distinction that matters on a load-in is
     * 23.976 versus 24, not the third decimal place.
     */
    val standardFps: Double?
        // NEAREST, not first-within-tolerance. 29.97 and 30 are only 0.1% apart,
        // so a first-match over an ascending list labelled every true 30 fps clip
        // as 29.97 and every 60 as 59.94. Nearest-match is the only correct rule
        // when the candidates are closer together than the tolerance.
        get() = nearestStandardRate(fps)

    /** Canonical name where one applies, with the measurement kept in view. */
    val label: String
        get() {
            val std = standardFps
            return if (std == null) "%dx%d @ %.3f fps".format(width, height, fps)
            else "%dx%d @ %s fps (measured %.3f)".format(width, height, fmt(std), fps)
        }

    private fun fmt(v: Double): String =
        if (abs(v - Math.round(v)) < 1e-6) "%.0f".format(v) else "%.3f".format(v)

    companion object {
        /**
         * Pure so it can be unit tested. It has already had one bug: a
         * first-within-tolerance match labelled every 30 fps clip as 29.97.
         */
        fun nearestStandardRate(fps: Double): Double? =
            STANDARD_RATES.minByOrNull { abs(it - fps) }?.takeIf { abs(it - fps) / it < 0.005 }

        private val STANDARD_RATES = doubleArrayOf(
            23.976, 24.0, 25.0, 29.97, 30.0, 47.952, 48.0, 50.0, 59.94, 60.0, 100.0, 119.88, 120.0
        ).toList()
    }
}

object ClipLibrary {

    const val FOLDER = "ARC_SIGNAL"

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.READ_MEDIA_VIDEO
        ) == PackageManager.PERMISSION_GRANTED

    fun scan(context: Context): List<Clip> {
        if (!hasPermission(context)) return emptyList()
        val out = mutableListOf<Clip>()
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.DURATION
        )
        runCatching {
            context.contentResolver.query(
                collection, projection,
                "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?", arrayOf("%$FOLDER%"),
                "${MediaStore.Video.Media.DISPLAY_NAME} ASC"
            )
        }.getOrNull()?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val wCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.WIDTH)
            val hCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)
            val dCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            while (c.moveToNext()) {
                val uri = android.content.ContentUris.withAppendedId(collection, c.getLong(idCol))
                val dur = c.getLong(dCol)
                out += Clip(
                    name = c.getString(nameCol).substringBeforeLast('.'),
                    uri = uri,
                    width = c.getInt(wCol),
                    height = c.getInt(hCol),
                    fps = measureFps(context, uri, dur),
                    durationMs = dur
                )
            }
        }
        return out
    }

    /**
     * Frame rate, measured from CONTAINER SAMPLE TIMESTAMPS.
     *
     * Two rejected approaches, both tried:
     *  - MediaStore.CAPTURE_FRAMERATE is essentially always null here.
     *  - Frame count over duration is only millisecond-accurate. On a 5.9 s
     *    clip that put a 29.97 source at 29.738, a 0.8% error. Widening the
     *    snap tolerance to absorb that is not an option, because 29.97 and 30
     *    are 0.1% apart and telling them apart is the entire point.
     * Presentation timestamps are microseconds on the container's own time
     * base, so the median inter-frame delta recovers 24000/1001 exactly.
     * The median, not the mean, because a B-frame reorder or a long final
     * sample would drag an average.
     */
    private fun measureFps(context: Context, uri: Uri, durationMs: Long): Double {
        val fromTimestamps = runCatching { fpsFromTimestamps(context, uri) }.getOrDefault(0.0)
        if (fromTimestamps > 0.0) return fromTimestamps
        // Fallback: coarse, but better than reporting nothing.
        if (durationMs <= 0) return 0.0
        val r = MediaMetadataRetriever()
        return runCatching {
            r.setDataSource(context, uri)
            val frames = r.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT
            )?.toIntOrNull() ?: return@runCatching 0.0
            frames * 1000.0 / durationMs
        }.getOrDefault(0.0).also { runCatching { r.release() } }
    }

    private fun fpsFromTimestamps(context: Context, uri: Uri): Double {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(context, uri, null)
            var track = -1
            for (i in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) { track = i; break }
            }
            if (track < 0) return 0.0
            ex.selectTrack(track)
            val times = ArrayList<Long>(240)
            while (times.size < 240) {
                val t = ex.sampleTime
                if (t < 0) break
                times += t
                if (!ex.advance()) break
            }
            if (times.size < 10) return 0.0
            times.sort()                      // presentation order, not decode order
            val deltas = LongArray(times.size - 1) { times[it + 1] - times[it] }
            deltas.sort()
            val median = deltas[deltas.size / 2]
            return if (median > 0) 1_000_000.0 / median else 0.0
        } finally {
            runCatching { ex.release() }
        }
    }
}

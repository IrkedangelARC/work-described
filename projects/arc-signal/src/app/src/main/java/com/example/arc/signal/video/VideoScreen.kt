//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.video

import android.media.MediaPlayer
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView

/**
 * Looping clip playback for the frame-rate tests.
 *
 * MediaPlayer + SurfaceView rather than Media3/ExoPlayer: these are local files
 * of known format, looping, with no seeking, transitions or adaptive streaming,
 * so the dependency would buy nothing and cost several MB in an APK that is
 * sideloaded onto field machines.
 *
 * SURFACE AND PLAYER LIFETIMES ARE DELIBERATELY SEPARATE, and this took two
 * wrong attempts to get right:
 *   1. Creating the player inside AndroidView's factory. factory runs ONCE, so
 *      stepping to the next clip reused the old SurfaceView whose callback still
 *      held the FIRST clip. Playback stalled after two switches.
 *   2. Wrapping AndroidView in key(clip.uri) to force a rebuild. Worse: the old
 *      player tore down ("mediaplayer went away with unhandled events") and the
 *      replacement SurfaceView never received a surface at all, so nothing
 *      played after the first step.
 * What works: ONE SurfaceView for the whole screen, its holder published into
 * Compose state, and the player created and released by a DisposableEffect
 * keyed on (holder, clip). The surface is never torn down mid-switch, and each
 * clip gets a clean player.
 *
 * WHAT THIS PROVES, and what the HUD must not overclaim: playing a 50 fps clip
 * does NOT make the port output 50 Hz. Output timing is the sink's native mode
 * and cannot be commanded on this device. These clips test the DOWNSTREAM
 * chain's motion handling, not our timing.
 */
@Composable
fun VideoScreen(clip: Clip, showHud: Boolean, outputInfo: String) {
    val context = LocalContext.current
    var holder by remember { mutableStateOf<SurfaceHolder?>(null) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    getHolder().addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(h: SurfaceHolder) { holder = h }
                        override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {
                            holder = h
                        }
                        override fun surfaceDestroyed(h: SurfaceHolder) { holder = null }
                    })
                }
            }
        )

        val h = holder
        DisposableEffect(h, clip.uri) {
            var player: MediaPlayer? = null
            if (h != null) {
                player = MediaPlayer().also { mp ->
                    runCatching {
                        mp.setDataSource(context, clip.uri)
                        mp.setDisplay(h)
                        mp.isLooping = true
                        mp.setOnPreparedListener { it.start() }
                        mp.prepareAsync()
                    }.onFailure { runCatching { mp.release() }; player = null }
                }
            }
            onDispose {
                player?.runCatching { if (isPlaying) stop(); release() }
            }
        }

        if (showHud) {
            Box(Modifier.align(Alignment.TopStart).padding(20.dp)
                .background(Color(0xC0000000)).padding(horizontal = 12.dp, vertical = 8.dp)) {
                Column {
                    Text("ARC  ${clip.name}", color = Color.White,
                        fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    Text("FRAME RATE", color = Color(0xFF8A8A8A),
                        fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                    Text("clip ${clip.label}", color = Color(0xFFB0B0B0),
                        fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                    Text(outputInfo, color = Color(0xFF8A8A8A),
                        fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                    Text("Tests the DOWNSTREAM chain's motion handling.\nThis does NOT change the output timing.",
                        color = Color(0xFF8A8A8A), fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp, modifier = Modifier.padding(top = 4.dp))
                }
            }
        }
    }
}

/** Shown when the folder is missing, empty, or the permission was never granted. */
@Composable
fun NoClipsScreen(permissionGranted: Boolean) {
    Box(Modifier.fillMaxSize().background(Color(0xFF0A0A0A))) {
        Column(Modifier.align(Alignment.Center)) {
            Text("NO FRAME-RATE CLIPS", color = Color(0xFFC1272D),
                fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 22.sp)
            Text(
                if (!permissionGranted)
                    "READ_MEDIA_VIDEO not granted.\n\nadb shell pm grant com.example.arc.signal \\\n  android.permission.READ_MEDIA_VIDEO"
                else
                    "Put .mp4 clips in Movies/${ClipLibrary.FOLDER}/ on the microSD,\nthen rescan the volume.",
                color = Color(0xFF8A8A8A), fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
    }
}

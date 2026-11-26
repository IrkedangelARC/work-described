//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal

import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.example.arc.signal.audio.SignalGenerator
import com.example.arc.signal.edid.SinkInfo
import com.example.arc.signal.pattern.AssetHolder
import com.example.arc.signal.pattern.MenuOverlay
import com.example.arc.signal.pattern.PatternLibrary
import com.example.arc.signal.pattern.PatternScreen
import com.example.arc.signal.pattern.preloadCharts
import com.example.arc.signal.ui.SinkScreen
import com.example.arc.signal.video.ClipLibrary
import com.example.arc.signal.video.NoClipsScreen
import com.example.arc.signal.video.VideoScreen

/**
 * Immersive fullscreen host.
 *
 * WHY IMMERSIVE IS NOT OPTIONAL: on the AYN Thor the internal panels blank when
 * HDMI is attached and display 0's content is what goes out the wire, status bar
 * and nav bar included. Any visible system UI contaminates every test pattern.
 * Verify with:
 *   adb exec-out screencap -d <physical-display-id> -p > dp.png
 */
class MainActivity : ComponentActivity() {

    private lateinit var displayManager: DisplayManager
    private var sink by mutableStateOf<SinkInfo?>(null)

    /** -1 means the sink/EDID screen; anything else indexes PatternLibrary.all. */
    private var patternIndex by mutableIntStateOf(-1)
    private var showHud by mutableStateOf(false)
    private var showFrame by mutableStateOf(false)
    private var hudCorner by mutableIntStateOf(0)

    /** The control screen. It cannot live on the handheld, so it lives on the output. */
    private var showMenu by mutableStateOf(false)

    private val handler = Handler(Looper.getMainLooper())

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = scheduleRefresh()
        override fun onDisplayRemoved(displayId: Int) = scheduleRefresh()
        override fun onDisplayChanged(displayId: Int) = scheduleRefresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AssetHolder.context = applicationContext
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        goImmersive()

        displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        refresh()
        // Rebuild the library BEFORE applyIntent, because navigation indexes
        // into PatternLibrary.all and the video entries must already exist.
        PatternLibrary.setClips(ClipLibrary.scan(this))
        applyIntent(intent)
        windowManager.currentWindowMetrics.bounds.let { preloadCharts(it.width(), it.height()) }

        setContent {
            val idx = patternIndex
            // Audio follows the selected pattern. Leaving a tone running after
            // the operator has moved on would be worse than useless in a room.
            LaunchedEffect(idx) {
                val spec = PatternLibrary.all.getOrNull(idx)?.audio
                if (spec != null) SignalGenerator.start(spec) else SignalGenerator.stop()
            }
            if (idx < 0 || idx >= PatternLibrary.all.size) {
                SinkScreen(sink = sink, onRefresh = ::refresh)
            } else {
                // Both in ONE Box on purpose. As root-level siblings the menu's
                // pixels were not repainted when it left the composition, so it
                // appeared to open and never close even though the state was
                // toggling correctly. A shared parent gives the removal
                // something to invalidate against.
                val p = PatternLibrary.all[idx]
                Box(Modifier.fillMaxSize()) {
                    val clip = p.clip
                    if (clip != null) {
                        VideoScreen(clip = clip, showHud = showHud, outputInfo = outputInfo())
                    } else {
                        PatternScreen(
                            pattern = p,
                            showHud = showHud,
                            showFrame = showFrame,
                            hudCorner = hudCorner,
                            outputInfo = outputInfo()
                        )
                    }
                    if (showMenu) MenuOverlay(selected = idx)
                }
            }
        }
    }


    /**
     * GAMEPAD IS THE PRIMARY INTERFACE, not a convenience.
     *
     * With HDMI attached the Thor's own panels are blank, so the operator is
     * watching the projector and working the handheld by feel. Every control
     * therefore has to be a physical button, and the mapping has to survive not
     * being able to see it.
     *
     * Verified against /system/usr/keylayout/Vendor_2020_Product_0111.kl, the
     * layout the "Odin Controller" actually loads. BACK is a separate key
     * (0x9e) on this pad, so B is free for app use and is given the
     * conventional "go back" meaning: return to the EDID page.
     *
     *   D-pad L/R    previous / next pattern
     *   D-pad U/D    previous / next category
     *   L1 / R1      previous / next category, for thumb comfort
     *   A            HUD on/off
     *   X            1px overscan frame on/off
     *   Y            move the HUD to the next corner
     *   B / START    back to the EDID page
     *   BACK         leaves the app, deliberately not intercepted
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val onPattern = patternIndex >= 0
        // Toggles must not auto-repeat; stepping should.
        val firstPress = event.repeatCount == 0

        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                patternIndex = if (onPattern) PatternLibrary.step(patternIndex, 1) else 0
                return true
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                patternIndex = if (onPattern) PatternLibrary.step(patternIndex, -1)
                                else PatternLibrary.all.lastIndex
                return true
            }
            KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_BUTTON_R1 -> {
                patternIndex = if (onPattern) PatternLibrary.stepCategory(patternIndex, 1) else 0
                return true
            }
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_BUTTON_L1 -> {
                patternIndex = if (onPattern) PatternLibrary.stepCategory(patternIndex, -1) else 0
                return true
            }
            KeyEvent.KEYCODE_BUTTON_SELECT -> {
                if (onPattern && firstPress) showMenu = !showMenu
                return true
            }
            KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> {
                if (!onPattern) { patternIndex = 0; return true }
                if (firstPress) {
                    // While the menu is up, A commits the highlighted pattern and
                    // closes rather than toggling the HUD underneath it.
                    if (showMenu) showMenu = false else showHud = !showHud
                }
                return true
            }
            KeyEvent.KEYCODE_BUTTON_X -> {
                if (onPattern && firstPress) showFrame = !showFrame
                return true
            }
            KeyEvent.KEYCODE_BUTTON_Y -> {
                if (onPattern && firstPress) hudCorner = (hudCorner + 1) and 3
                return true
            }
            KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_BUTTON_START -> {
                if (onPattern && firstPress) { showMenu = false; patternIndex = -1; return true }
                return onPattern
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyIntent(intent)
    }

    /**
     * adb-drivable selection, so every pattern can be verified by screenshot
     * without touching the device. Gamepad navigation lands in step 5; this hook
     * stays because it is also how the app gets driven from a Claude session.
     *   adb shell am start -n <pkg>/.MainActivity --es pattern ramp_h --ez hud true
     */
    private fun applyIntent(intent: Intent?) {
        intent ?: return
        intent.getStringExtra("pattern")?.let { id ->
            patternIndex = if (id.equals("sink", true) || id.isBlank()) -1
            else PatternLibrary.indexOf(id)
        }
        if (intent.hasExtra("hud")) showHud = intent.getBooleanExtra("hud", false)
        if (intent.hasExtra("frame")) showFrame = intent.getBooleanExtra("frame", false)
        if (intent.hasExtra("corner")) hudCorner = intent.getIntExtra("corner", 0)
    }

    /** What the operator needs to trust the pattern: our surface and the sink's mode. */
    private fun outputInfo(): String {
        val b = windowManager.currentWindowMetrics.bounds
        val surface = "${b.width()}x${b.height()}"
        val m = sink?.activeMode
        return if (m != null)
            "surface $surface   sink %dx%d @ %.3f Hz".format(m.width, m.height, m.refreshHz)
        else "surface $surface   no sink"
    }

    override fun onResume() {
        super.onResume()
        displayManager.registerDisplayListener(displayListener, handler)
        goImmersive()
        refresh()
        PatternLibrary.all.getOrNull(patternIndex)?.audio?.let { SignalGenerator.start(it) }
    }

    override fun onPause() {
        super.onPause()
        displayManager.unregisterDisplayListener(displayListener)
        SignalGenerator.stop()
    }

    override fun onDestroy() {
        super.onDestroy()
        SignalGenerator.stop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) goImmersive()
    }

    private fun scheduleRefresh() {
        refresh()
        handler.postDelayed(::refresh, 600)
    }

    private fun refresh() {
        sink = SinkInfo.resolve(this)
    }

    private fun goImmersive() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }
}

//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import kotlin.math.min
import kotlinx.coroutines.launch

// =================================================================== AUDIO
// The X AIR as a channel-strip row: every input channel with its meter,
// fader and ON button, the LR master at the right. First domain page after
// camera and switcher (2026-09-04: the app becomes the ARC control
// surface). Same module language as every other page: QVPanel headers,
// identical strip construction so the sixteen line up by design.

/**
 * THE PROGRAM AUDIO CONFIDENCE STRIP, on every page (2026-09-04:
 * the app is the show-floor surface, X AIR Edit is the deep tool). One
 * row: desk reachable, main LR post-fader L/R, the show mics by name with
 * ON/MUTED (click toggles), the USB recorder with elapsed time, mute
 * groups, the current snapshot, and OPEN X AIR EDIT. Which channels are
 * "show mics": `audio.show=1,2,3` in the properties; else every channel
 * with a name on the desk; else 1-4.
 */
@Composable
internal fun AudioConfidenceStrip(audio: XAirClient, pgm: Set<Int>, atemInputs: List<Int>, onOpenAudio: () -> Unit) {
    val connected by audio.connected.collectAsState()
    val channels by audio.channels.collectAsState()
    val post by audio.metersPost.collectAsState()
    val inputs by audio.meters.collectAsState()
    val lrOut by audio.lrOut.collectAsState()
    val lr by audio.lr.collectAsState()
    val tape by audio.tape.collectAsState()
    val groups by audio.muteGroups.collectAsState()
    val snapIdx by audio.snapshotIndex.collectAsState()
    val snapNames by audio.snapshotNames.collectAsState()
    val show = remember(channels) { showMics(channels) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 6.dp).background(ModuleBg, RoundedCornerShape(8.dp))
            .border(2.dp, (if (connected) SecGreen else AccentQ).copy(alpha = 0.8f), RoundedCornerShape(8.dp))
            .padding(horizontal = 6.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // desk + main LR on one green bed: "is program audio alive"
        StripBed(SecGreen) {
        Column(Modifier.width(80.dp)) {
            QLabel("AUDIO", SecGreen, FontWeight.Bold, 10, letterSpacing = 2, maxLines = 1)
            QLabel(if (connected) "LIVE" else "NO DESK", if (connected) LiveQ else AccentQ, FontWeight.Bold, 11, maxLines = 1)
        }
        // main LR, post-fader
        Column(Modifier.width(150.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                QLabel("LR", Text1, FontWeight.Bold, 9, maxLines = 1)
                QLabel(if (!lr.on) "MUTED" else "%.0f / %.0f dB".format(lrOut.first, lrOut.second), if (!lr.on) AccentQ else Text1, FontWeight.Bold, 9, maxLines = 1)
            }
            HMeter(lrOut.first); HMeter(lrOut.second)
        }
        }
        // show mics on a neutral bed
        StripBed(null, Modifier.weight(1f)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for (ch in show) {
                val c = channels[ch] ?: XAirClient.Channel(ch)
                val inDb = inputs.getOrNull(ch - 1) ?: -128f
                val postDb = post.getOrNull(ch - 1) ?: -128f
                val clip = inDb > -1f
                val silent = c.on && inDb < -70f
                // ON AIR: this mic's camera is on the switcher's program, the
                // one coupling X AIR Edit cannot show. A muted mic on air is
                // the loudest state the strip has.
                val onAir = micAtemInput(ch, atemInputs)?.let { it in pgm } == true
                // The mic tiles are the strip's elastic element: they share
                // the row's slack equally up to a cap, so four mics fill it
                // and twelve still fit, and there is no empty run to explain.
                Column(
                    Modifier.weight(1f).widthIn(min = STRIP_MIC_W, max = STRIP_MIC_MAX_W)
                        .background(if (onAir) AccentQ.copy(alpha = 0.22f) else if (!c.on) AccentQ.copy(alpha = 0.16f) else PanelBg, RoundedCornerShape(4.dp))
                        .border(if (onAir) 2.dp else 1.dp, if (onAir || clip) AccentQ else if (!c.on) AccentQ.copy(alpha = 0.7f) else Line, RoundedCornerShape(4.dp))
                        .clickable { audio.setOn(ch, !c.on) }
                        .padding(horizontal = 5.dp, vertical = 3.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        QLabel(c.name.ifBlank { "CH $ch" }.uppercase().take(8), Text0, FontWeight.Bold, 10, maxLines = 1)
                        QLabel(
                            when {
                                onAir && !c.on -> "ON AIR · MUTED"
                                clip -> "CLIP"
                                onAir -> "ON AIR"
                                !c.on -> "MUTED"
                                silent -> "NO SIG"
                                else -> "ON"
                            },
                            when { onAir || clip || !c.on -> AccentQ; silent -> SecOrange; else -> LiveQ }, FontWeight.Bold, 9, maxLines = 1,
                        )
                    }
                    HMeter(postDb)
                }
            }
        }
        }
        // recorder: red bed while recording, the one state that must be seen
        val rec = tape.state == 4
        StripBed(if (rec) AccentQ else null) {
        Column(Modifier.width(104.dp)) {
            QLabel("USB REC", if (rec) AccentQ else Text1, FontWeight.Bold, 9, letterSpacing = 1, maxLines = 1)
            QLabel(
                if (rec) "REC %02d:%02d:%02d".format(tape.elapsed / 3600, tape.elapsed / 60 % 60, tape.elapsed % 60) else audio.tapeLabel(tape.state),
                if (rec) AccentQ else Text1, FontWeight.Bold, 11, maxLines = 1,
            )
        }
        }
        // mute groups + snapshot: the show-flow controls, one orange bed
        StripBed(SecOrange) {
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
            QLabel("MUTE", SecOrange, FontWeight.Bold, 9, letterSpacing = 1, maxLines = 1)
            for (n in 1..4) {
                val on = groups[n] == true
                QButton("$n", accent = on, accentColor = AccentQ, modifier = Modifier.width(34.dp), height = 26.dp, fontSize = 10, hPad = 2.dp) {
                    audio.setMuteGroup(n, !on)
                }
            }
        }
        Column(Modifier.width(120.dp)) {
            QLabel("SNAPSHOT", SecOrange, FontWeight.Bold, 9, letterSpacing = 1, maxLines = 1)
            QLabel(
                if (snapIdx > 0) "$snapIdx ${snapNames[snapIdx].orEmpty()}".trim() else "\u00b7",
                Text0, FontWeight.Bold, 11, maxLines = 1,
            )
        }
        }
        // hand-offs
        StripBed(null) {
        QButton("AUDIO PAGE", modifier = Modifier.width(96.dp), height = 26.dp, fontSize = 9, hPad = 3.dp) { onOpenAudio() }
        QButton("OPEN X AIR EDIT", accent = true, accentColor = SecGreen, modifier = Modifier.width(126.dp), height = 26.dp, fontSize = 9, hPad = 3.dp) { openXAirEdit() }
        }
    }
}

/** A group's bed in the strip: faint tint of the group's colour, or the neutral panel grey. */
@Composable
internal fun StripBed(tint: Color?, modifier: Modifier = Modifier, content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Row(
        modifier
            .background(tint?.copy(alpha = 0.18f) ?: PanelBg, RoundedCornerShape(6.dp))
            .border(1.dp, tint?.copy(alpha = 0.55f) ?: Line, RoundedCornerShape(6.dp))
            .padding(horizontal = 6.dp, vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

internal val STRIP_MIC_W = 118.dp
internal val STRIP_MIC_MAX_W = 260.dp

/** Horizontal meter on the -60..0 scale, green / orange / red like the strips. */
@Composable
internal fun HMeter(db: Float) {
    Box(Modifier.fillMaxWidth().height(6.dp).background(Ink, RoundedCornerShape(2.dp))) {
        val frac = meterFrac(db)
        val col = when { db > -6f -> AccentQ; db > -18f -> SecOrange; else -> LiveQ }
        Box(Modifier.fillMaxHeight().fillMaxWidth(frac).background(col, RoundedCornerShape(2.dp)))
    }
}

/** The show mics: `audio.show`, else the first STRIP_MAX_MICS named channels, else 1-4. */
internal fun showMics(channels: Map<Int, XAirClient.Channel>): List<Int> {
    Config.get("audio.show")?.split(",")?.mapNotNull { it.trim().toIntOrNull() }?.filter { it in 1..XAirClient.CHANNELS }
        ?.takeIf { it.isNotEmpty() }?.let { return it.take(STRIP_MAX_MICS) }
    val named = channels.values.filter { it.name.isNotBlank() }.map { it.n }.sorted()
    return named.ifEmpty { listOf(1, 2, 3, 4) }.take(STRIP_MAX_MICS)
}

/** Eight mic tiles at their minimum width is what the strip has room for beside its other modules. */
internal const val STRIP_MAX_MICS = 8

/**
 * Which switcher input a mic belongs to: `audio.chN.atemInput=<n>` directly,
 * or `audio.chN.camera=<slot>` through the slot's `roomN.atemInput`. Null =
 * unmapped, and the tile never claims ON AIR.
 */
internal fun micAtemInput(ch: Int, atemInputs: List<Int>): Int? {
    Config.get("audio.ch$ch.atemInput")?.toIntOrNull()?.let { return it }
    val slot = Config.get("audio.ch$ch.camera")?.toIntOrNull() ?: return null
    return atemInputs.getOrNull(slot - 1) ?: slot
}

/** Hand-off to the deep tool. No API, no URL scheme: launch it, its own Auto Connect lands on the desk. */
internal fun openXAirEdit() {
    runCatching { ProcessBuilder("/usr/bin/open", "-a", "X-AIR-Edit").start() }
        .onFailure { Log.log("AUDIO: could not open X AIR Edit: ${it.message}") }
        .onSuccess { Log.log("AUDIO: opened X AIR Edit") }
}

internal val AUDIO_STRIP_W = 96.dp
internal val AUDIO_FADER_H = 260.dp
internal const val AUDIO_METER_FLOOR_DB = -60f

/** Meter dB -> 0..1 on a -60..0 scale, the one every strip uses. */
internal fun meterFrac(db: Float) = ((db - AUDIO_METER_FLOOR_DB) / -AUDIO_METER_FLOOR_DB).coerceIn(0f, 1f)

@Composable
internal fun AudioPage(audio: XAirClient) {
    val info by audio.info.collectAsState()
    val connected by audio.connected.collectAsState()
    val channels by audio.channels.collectAsState()
    val lr by audio.lr.collectAsState()
    val meters by audio.meters.collectAsState()
    Column(Modifier.fillMaxSize().background(AppGrey).padding(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        QVPanel("MIXER", SecGreen, compact = true) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                QLabel(info?.name ?: audio.host, Text0, FontWeight.Bold, 14, maxLines = 1)
                QLabel(info?.let { "${it.model} · fw ${it.firmware} · ${it.ip}" } ?: "waiting for /xinfo", Text1, size = 11, maxLines = 1)
                Spacer(Modifier.weight(1f))
                QLabel(
                    if (connected) "LIVE" else "NO REPLY — /xremote every ${XAirClient.KEEPALIVE_MS / 1000} s",
                    if (connected) LiveQ else AccentQ, FontWeight.Bold, 11, maxLines = 1,
                )
                QLabel("meters ${meters.size} slots", Text1, size = 10, maxLines = 1)
                QButton("OPEN X AIR EDIT", accent = true, accentColor = SecGreen, modifier = Modifier.width(150.dp), height = 26.dp, fontSize = 10) { openXAirEdit() }
            }
        }
        val post by audio.metersPost.collectAsState()
        QVPanel("CHANNELS · meter = post-fader (/meters/5) · fader in dB", SecGreen, compact = true, fill = true, modifier = Modifier.weight(1f)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                for (ch in 1..XAirClient.CHANNELS) {
                    val c = channels[ch] ?: XAirClient.Channel(ch)
                    AudioStrip(
                        title = c.name.ifBlank { "CH $ch" },
                        meterDb = post.getOrNull(ch - 1),
                        fader = c.fader, on = c.on,
                        accent = SecGreen,
                        onFader = { audio.setFader(ch, it) },
                        onToggle = { audio.setOn(ch, !c.on) },
                    )
                }
                Spacer(Modifier.width(8.dp))
                val lrOut by audio.lrOut.collectAsState()
                AudioStrip(
                    title = "LR",
                    meterDb = maxOf(lrOut.first, lrOut.second),
                    fader = lr.fader, on = lr.on,
                    accent = AccentQ,
                    onFader = { audio.setLrFader(it) },
                    onToggle = { audio.setLrOn(!lr.on) },
                )
            }
        }
    }
}

/** One strip: name, meter, fader with its dB readout, ON button. */
@Composable
internal fun AudioStrip(
    title: String, meterDb: Float?, fader: Float, on: Boolean, accent: Color,
    onFader: (Float) -> Unit, onToggle: () -> Unit,
) {
    Column(
        Modifier.width(AUDIO_STRIP_W).background(PanelBg, RoundedCornerShape(5.dp))
            .border(1.dp, if (on) Line else AccentQ.copy(alpha = 0.6f), RoundedCornerShape(5.dp))
            .padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        QLabel(title.uppercase().take(8), Text0, FontWeight.Bold, 11, maxLines = 1)
        Row(Modifier.height(AUDIO_FADER_H), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            // METER: a bar from the floor, green to -18, orange to -6, red above.
            Box(Modifier.width(14.dp).fillMaxHeight().background(Ink, RoundedCornerShape(2.dp))) {
                meterDb?.let { db ->
                    val frac = meterFrac(db)
                    val col = when {
                        db > -6f -> AccentQ
                        db > -18f -> SecOrange
                        else -> LiveQ
                    }
                    Box(
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().fillMaxHeight(frac)
                            .background(col, RoundedCornerShape(2.dp)),
                    )
                }
            }
            // FADER: drag anywhere on the track; the knob sits at the value.
            var drag by remember { mutableStateOf<Float?>(null) }
            val shown = drag ?: fader
            Box(
                Modifier.width(44.dp).fillMaxHeight().background(Ink, RoundedCornerShape(3.dp))
                    .pointerInput(Unit) {
                        detectDragGestures(
                            onDragStart = { drag = fader },
                            onDragEnd = { drag?.let(onFader); drag = null },
                            onDragCancel = { drag = null },
                        ) { change, delta ->
                            change.consume()
                            val v = ((drag ?: fader) - delta.y / size.height).coerceIn(0f, 1f)
                            drag = v
                            onFader(v)
                        }
                    },
            ) {
                // unity mark at 0.75 (from the bottom), knob travel = track minus knob height
                val knobH = 16.dp
                val travel = AUDIO_FADER_H - knobH
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().offset(y = -(travel * 0.75f) - knobH / 2).height(1.dp).background(Line))
                Box(
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().offset(y = -(travel * shown))
                        .height(knobH).background(accent, RoundedCornerShape(3.dp)),
                )
            }
        }
        QLabel(
            "%+.1f dB".format(XAirClient.faderToDb(shownOrFader(fader))),
            Text1, FontWeight.Bold, 10, maxLines = 1,
        )
        QButton(if (on) "ON" else "MUTED", accent = !on, accentColor = AccentQ, modifier = Modifier.fillMaxWidth(), height = 26.dp, fontSize = 10) {
            onToggle()
        }
    }
}

internal fun shownOrFader(f: Float) = f

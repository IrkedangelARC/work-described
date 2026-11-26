//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import com.example.arc.signal.edid.SinkInfo
import com.example.arc.signal.edid.SinkSource

// ARC industrial minimalism: near-black ground, monochrome data, one accent.
private val Ground = Color(0xFF0A0A0A)
private val Ink = Color(0xFFE6E6E6)
private val Dim = Color(0xFF8A8A8A)
private val Rule = Color(0xFF2A2A2A)
private val Accent = Color(0xFFC1272D)   // ARC red
private val Good = Color(0xFF4CAF50)
private val Warn = Color(0xFFE0A030)

@Composable
fun SinkScreen(sink: SinkInfo?, onRefresh: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Ground)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 28.dp, vertical = 20.dp)) {
            Header(sink)
            Spacer(Modifier.height(14.dp))

            if (sink == null || !sink.connected) {
                Text(
                    sink?.note ?: "No external display detected.",
                    color = Dim, fontFamily = FontFamily.Monospace, fontSize = 16.sp
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "Connect a USB-C to HDMI adapter. This screen updates on hotplug.",
                    color = Rule, fontFamily = FontFamily.Monospace, fontSize = 13.sp
                )
                return@Column
            }

            // Two columns: 16:9 has the width, and scrolling is useless when the
            // operator cannot see the handheld to scroll it.
            Row(Modifier.fillMaxWidth().weight(1f)) {
                Column(Modifier.weight(1.35f)) {
                    Section("IDENTITY")
                    Field("Monitor name", sink.displayName)
                    Field("Manufacturer", sink.manufacturerPnpId)
                    Field("Product code", sink.productCode?.let { "0x%04x  (%d)".format(it, it) })
                    Field("Manufactured", sink.manufactureYear?.let { y ->
                        sink.manufactureWeek?.let { w -> "week $w, $y" } ?: "$y"
                    })
                    Field("EDID version", sink.edidVersion)
                    Field("Panel size", sink.diagonalInches?.let { "%.1f in".format(it) })
                    Field("Connector", sink.connectorName)
                    sink.checksumValid?.let {
                        FieldColored("Checksum", if (it) "valid" else "INVALID", if (it) Good else Accent)
                    }
                    sink.supportsAudio?.let {
                        Field("CEA basic audio", if (it) "supported" else "not supported")
                    }

                    Spacer(Modifier.height(16.dp))
                    Section("PREFERRED TIMING")
                    val t = sink.preferredTiming
                    if (t != null) {
                        Field("Mode", t.summary)
                        Field("Pixel clock", "%.2f MHz".format(t.pixelClockMHz))
                        Field("H total", "${t.hTotal}  (act ${t.hActive}, blank ${t.hBlank})")
                        Field("V total", "${t.vTotal}  (act ${t.vActive}, blank ${t.vBlank})")
                    } else {
                        Field("Mode", sink.activeMode?.let {
                            "%dx%d @ %.3f Hz".format(it.width, it.height, it.refreshHz)
                        } ?: "unknown")
                        Text(
                            "Detailed timing needs the raw EDID.",
                            color = Rule, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }

                }

                Spacer(Modifier.width(24.dp))
                Box(Modifier.width(1.dp).fillMaxHeight().background(Rule))
                Spacer(Modifier.width(24.dp))

                Column(Modifier.weight(1f)) {
                    Section("MODES OFFERED  (${sink.modes.size})")
                    sink.modes.forEach { m ->
                        Row(Modifier.fillMaxWidth()) {
                            Text(
                                if (m.isActive) "\u25b6" else " ",
                                color = Accent, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                                modifier = Modifier.width(16.dp)
                            )
                            Text(
                                "%-11s @ %7.3f Hz".format("${m.width}x${m.height}", m.refreshHz),
                                color = if (m.isActive) Ink else Dim,
                                fontFamily = FontFamily.Monospace, fontSize = 12.sp
                            )
                        }
                    }
                    if (sink.source == SinkSource.RAW_EDID) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Modes via DisplayManager; identity from raw EDID.",
                            color = Rule, fontFamily = FontFamily.Monospace, fontSize = 10.sp
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    Section("SIGNAL INTEGRITY")
                    Field("Wide gamut", sink.wideColorGamut?.let { if (it) "yes" else "no" })
                    val note = sink.colorModeNote
                    if (note == null) {
                        FieldColored("Code values", "exact", Good)
                    } else {
                        // The full explanation lives in the docs, not on a
                        // load-in screen. Two labelled lines say enough.
                        FieldColored("Code values", "greyscale exact", Good)
                    }

                }
            }

            // Full-width footer. The mapping has to be discoverable, but it is
            // reference material, not data, so it gets one compact line rather
            // than seven rows competing with the readout.
            Box(Modifier.fillMaxWidth().height(1.dp).background(Rule))
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth()) {
                Text("CONTROLS", color = Accent, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = 12.sp,
                    modifier = Modifier.width(120.dp))
                Text(
                    "L/R pattern   U/D category   A HUD   X frame   Y corner   " +
                        "SELECT menu   B back",
                    color = Dim, fontFamily = FontFamily.Monospace, fontSize = 12.sp
                )
            }
        }
    }
}

@Composable
private fun Header(sink: SinkInfo?) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("ARC", color = Accent, fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold, fontSize = 26.sp)
            Spacer(Modifier.width(10.dp))
            Text("SIGNAL", color = Ink, fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold, fontSize = 26.sp)
            Spacer(Modifier.width(20.dp))
            SourceBadge(sink?.source ?: SinkSource.NONE)
        }
        Spacer(Modifier.height(6.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(Rule))
    }
}

/**
 * Never let DisplayManager data masquerade as a decoded EDID. The badge is the
 * whole point of having two paths.
 */
@Composable
private fun SourceBadge(source: SinkSource) {
    val (label, color) = when (source) {
        SinkSource.RAW_EDID -> "RAW EDID" to Good
        SinkSource.DISPLAY_MANAGER -> "API ONLY" to Warn
        SinkSource.NONE -> "NO SINK" to Dim
    }
    Box(Modifier.background(color.copy(alpha = 0.15f)).padding(horizontal = 8.dp, vertical = 3.dp)) {
        Text(label, color = color, fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold, fontSize = 12.sp)
    }
}

@Composable
private fun Section(title: String) {
    Text(title, color = Accent, fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold, fontSize = 13.sp,
        modifier = Modifier.padding(bottom = 6.dp))
}

@Composable
private fun Field(label: String, value: String?) {
    if (value.isNullOrBlank()) return
    FieldColored(label, value, Ink)
}

@Composable
private fun FieldColored(label: String, value: String, valueColor: Color) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.Start) {
        Text(label, color = Dim, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
            modifier = Modifier.width(180.dp))
        Text(value, color = valueColor, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
            maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}


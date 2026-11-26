//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.pattern

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val Ground = Color(0xF00A0A0A)
private val Ink = Color(0xFFE6E6E6)
private val Dim = Color(0xFF8A8A8A)
private val Rule = Color(0xFF2A2A2A)
private val Accent = Color(0xFFC1272D)

/**
 * The control screen.
 *
 * The Thor's own panels are hardware-blanked whenever HDMI is attached (the
 * backlight nodes are root-only, so nothing in userspace can light them), which
 * means a control surface CANNOT live on the handheld. It lives here instead,
 * on the output, because during setup the operator is looking at the projector
 * anyway. SELECT toggles it; it covers the pattern so nothing is being measured
 * while it is up.
 */
@Composable
fun MenuOverlay(selected: Int) {
    Box(Modifier.fillMaxSize().background(Ground)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 40.dp, vertical = 26.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("ARC", color = Accent, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = 22.sp)
                Text(" SIGNAL", color = Ink, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = 22.sp)
                Text("   PATTERNS", color = Dim, fontFamily = FontFamily.Monospace,
                    fontSize = 14.sp)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Rule).padding(top = 6.dp))

            // Three wide columns rather than one per category: five equal
            // columns wrapped the pattern names onto two lines while leaving
            // the bottom half of the screen empty. Categories are packed
            // greedily into the shortest column so the block stays balanced.
            Row(Modifier.fillMaxWidth().padding(top = 14.dp)) {
                val columns = List(3) { mutableListOf<Pair<PatternCategory, List<Pattern>>>() }
                val heights = IntArray(3)
                PatternLibrary.byCategory.forEach { entry ->
                    val target = heights.indices.minByOrNull { heights[it] } ?: 0
                    columns[target] += entry
                    heights[target] += entry.second.size + 2   // +2 for the header and its gap
                }
                columns.forEach { col ->
                    Column(Modifier.weight(1f).padding(end = 24.dp)) {
                        col.forEach { (cat, items) ->
                            Text(cat.label, color = Accent, fontFamily = FontFamily.Monospace,
                                fontWeight = FontWeight.Bold, fontSize = 12.sp,
                                modifier = Modifier.padding(bottom = 5.dp, top = 6.dp))
                            items.forEach { p ->
                                val idx = PatternLibrary.all.indexOf(p)
                                val on = idx == selected
                                Row(Modifier.fillMaxWidth()) {
                                    Text(if (on) "\u25b6" else " ", color = Accent,
                                        fontFamily = FontFamily.Monospace, fontSize = 14.sp,
                                        modifier = Modifier.width(18.dp))
                                    Text(p.name, color = if (on) Ink else Dim,
                                        fontFamily = FontFamily.Monospace,
                                        fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                                        fontSize = 14.sp, maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }

            Box(Modifier.weight(1f))
            Box(Modifier.fillMaxWidth().height(1.dp).background(Rule))
            Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Text("MENU", color = Accent, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = 12.sp,
                    modifier = Modifier.width(110.dp))
                Text("L/R move    U/D category    A or SELECT close    B EDID page",
                    color = Dim, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
        }
    }
}

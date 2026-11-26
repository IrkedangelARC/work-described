//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.pattern

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Full-surface pattern renderer.
 *
 * The Canvas fills the window and draws in device pixels, so what is painted is
 * what leaves the port. The HUD is a separate overlay that is OFF by default:
 * anything drawn on top of a test pattern contaminates the measurement, so it
 * has to be the operator's explicit choice to show it.
 */
@Composable
fun PatternScreen(
    pattern: Pattern,
    showHud: Boolean,
    showFrame: Boolean,
    hudCorner: Int,
    outputInfo: String
) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Canvas(Modifier.fillMaxSize()) {
            pattern.draw(this)
            if (showFrame) {
                // 1px inset outline. If any edge is missing, the sink is
                // overscanning and cropping the picture.
                val w = size.width
                val h = size.height
                drawRect(Color.White, topLeft = androidx.compose.ui.geometry.Offset(0f, 0f),
                    size = androidx.compose.ui.geometry.Size(w, 1f))
                drawRect(Color.White, topLeft = androidx.compose.ui.geometry.Offset(0f, h - 1f),
                    size = androidx.compose.ui.geometry.Size(w, 1f))
                drawRect(Color.White, topLeft = androidx.compose.ui.geometry.Offset(0f, 0f),
                    size = androidx.compose.ui.geometry.Size(1f, h))
                drawRect(Color.White, topLeft = androidx.compose.ui.geometry.Offset(w - 1f, 0f),
                    size = androidx.compose.ui.geometry.Size(1f, h))
            }
        }

        if (showHud) {
            val align = when (hudCorner and 3) {
                0 -> Alignment.TopStart
                1 -> Alignment.TopEnd
                2 -> Alignment.BottomEnd
                else -> Alignment.BottomStart
            }
            Hud(pattern, outputInfo, Modifier.align(align).padding(20.dp))
        }
    }
}

@Composable
private fun Hud(pattern: Pattern, outputInfo: String, modifier: Modifier = Modifier) {
    Box(modifier.background(Color(0xC0000000)).padding(horizontal = 12.dp, vertical = 8.dp)) {
        Column {
            Row {
                Text("ARC", color = Color(0xFFC1272D), fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = 13.sp)
                Text("  ${pattern.name}", color = Color.White, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold, fontSize = 13.sp)
            }
            Text(pattern.category.label, color = Color(0xFF8A8A8A),
                fontFamily = FontFamily.Monospace, fontSize = 11.sp)
            Text(outputInfo, color = Color(0xFF8A8A8A),
                fontFamily = FontFamily.Monospace, fontSize = 11.sp)
            pattern.note?.let {
                Text(it, color = Color(0xFFB0B0B0), fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp, modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

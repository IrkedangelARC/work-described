//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import kotlin.math.min

// ARC house style: colours, layout constants and the Q* primitives, copied
// from arc-ptz QuadTheme.kt / QuadWidgets.kt / QuadTile.kt on 2026-09-08 so
// this project builds alone. Keep them in step by hand.

internal val Ink = Color(0xFF0B0B0C)
internal val PanelBg = Color(0xFF161719)
internal val Line = Color(0xFF2C2E31)
internal val Text0 = Color(0xFFE8E8EA)
internal val Text1 = Color(0xFF8B8D92)
internal val AccentQ = Color(0xFFC8102E)
internal val LiveQ = Color(0xFF2FBF71)
/** "Adjusted since recall": the active preset no longer matches what is saved. */
internal val WarnYellow = Color(0xFFE6C229)
internal val Dim = Color(0xB0000000)

// Section palette, borrowed from the karaoke app's module language: each
// functional group is a rounded module with a coloured border + matching
// centred title on near-black. Colours sort the domains at a glance:
//   ORANGE  camera motion (PTZ/zoom/focus/OSD)
//   BLUE    AI / tracking
//   RED     record
//   CRIMSON imaging/exposure
//   GREEN   monitoring (scope, network)
internal val SecOrange = Color(0xFFE09143)
internal val SecBlue = Color(0xFF5B8DD9)
internal val SecRed = Color(0xFFDB4C4C)
internal val SecCrimson = Color(0xFFC24B5A)
internal val SecGreen = Color(0xFF57B368)
internal val ModuleBg = Color(0xFF101113)

/** The karaoke app's chrome grey: the ground the dark modules sit on. */
internal val AppGrey = Color(0xFF383838)

/**
 * Rail widths. The designed value is the MINIMUM; each rail also has a
 * MAXIMUM — the width at which its widest element is already full size.
 * Past that, extra width cannot be used and just becomes gutter: the PTZ
 * star hits its 46dp segment cap and floats in a huge grey bed. So the rail
 * stops growing there and the surplus stays with the video as centred
 * pillarbox — a declared remainder rather than an accidental one.
 *
 * RIGHT_RAIL_MAX comes from the star: 5 segments x (46 + 2) = 240dp, plus
 * bed, sub-box, station and module chrome.
 */
/**
 * Cameras per page. The grid is 2x2 and the tab bar holds one page's tabs, so
 * this is a LAYOUT constant, not a fleet limit — the fleet can be any size and
 * pages are added as slots fill.
 */
internal const val SLOTS_PER_PAGE = 4

/**
 * Default camera names (2026-09-03). The project began as one console
 * per ROOM; it now runs one show's whole camera plot, so a fresh slot is
 * named for its job, not its room. Every name stays editable.
 */
internal val DEFAULT_ROOM_NAMES = mapOf(1 to "HERO", 2 to "S WIDE", 3 to "S CUT", 4 to "AUD R", 5 to "AUD L")
internal fun defaultRoomName(slot: Int): String = DEFAULT_ROOM_NAMES[slot] ?: "CAM $slot"

/** The preset strip always pages far enough to reach this slot (12 = WB CORRECT). */
internal const val PRESET_MIN_REACH = 12

/**
 * THE INSTRUMENT LAW (2026-08-30): the tools are FIXED SIZE on every
 * machine, and the VIDEO absorbs the difference. Like a hardware panel — an
 * operator's hands learn one geometry, and it must be the same geometry on
 * the office workstation, the Air, and the FOH touchscreen. The first field run proved
 * the alternative wrong: rails that flexed between min and max rendered the
 * same controls three different ways on three screens.
 *
 * These are the widths at which every rail control renders at its designed
 * full size — the look approved on the office workstation. They do not clamp, scale, or
 * adapt. A smaller window means a smaller PICTURE, never smaller tools.
 */
internal val LEFT_RAIL_W = 250.dp
internal val RIGHT_RAIL_W = 350.dp

/** Width the preset tool cluster occupies, reserved when sizing cards. */
internal val CLUSTER_W = 124.dp

/**
 * FLOOR for the click guide, not its width. The guide is text and can take
 * whatever is left: the preset module is sized to exactly what its cards
 * need, and the guide absorbs the remainder. That is what removes the grey
 * gutters that SpaceEvenly used to spread around the cards.
 */
internal val GUIDE_MIN_W = 450.dp
/** The KEYS toggle at the end of the preset bar. */
internal val GUIDE_TOGGLE_W = 34.dp

/** Preset card geometry, shared by the bar-height solve and the strip. */
internal val PRESET_GUTTER = 6.dp
internal val PRESET_BED_PAD = 5.dp
internal val PRESET_CARD_PAD = 6.dp
/**
 * Card label strip. This is a real lever, not trim: a taller label eats into
 * the image, which shortens it, which narrows the 16:9 card — so raising it
 * fits MORE presets across at the same bar height.
 */
internal val PRESET_LABEL_H = 30.dp
/**
 * The ONE tunable for the preset bar. Everything else is derived from it:
 * card height, card width via 16:9, and how many fit. Raise it and the
 * thumbnails grow and the count drops; lower it and the reverse.
 */
internal val PRESET_BAR_H = 180.dp

/**
 * Module chrome above and below the grey box: padding, title, gap. SHARED by
 * the preset bar and the click guide so their grey boxes sit at the same top
 * and bottom — they were 3/5dp and 6dp apart and read as misaligned.
 */
internal val MODULE_PAD = 4.dp
internal val MODULE_GAP = 3.dp
internal val MODULE_TITLE_H = 13.dp

@Composable
internal fun QLabel(
    text: String,
    color: Color,
    weight: FontWeight = FontWeight.Normal,
    size: Int = 12,
    letterSpacing: Int = 0,
    maxLines: Int = Int.MAX_VALUE,
) {
    Text(
        text, color = color, fontSize = size.sp, fontWeight = weight,
        fontFamily = FontFamily.Monospace, letterSpacing = letterSpacing.sp,
        maxLines = maxLines, softWrap = maxLines > 1,
    )
}

@Composable
internal fun QButton(
    text: String,
    accent: Boolean = false,
    modifier: Modifier = Modifier,
    height: Dp = 35.dp,
    fontSize: Int = 12,
    // Accent is normally ARC crimson "this is the live one". A momentary
    // confirmation needs a DIFFERENT colour or it reads as selection.
    accentColor: Color = AccentQ,
    // 9dp is the slab default. A WEIGHTED button in a crowded row can end up
    // narrower than its own padding, at which point the glyph clips to zero
    // and the control reads as an empty slot - which is how the AF TUNING and
    // AI RESPONSE steppers shipped with invisible -/+ . Narrow rows pass a
    // smaller pad so the glyph survives.
    hPad: Dp = 9.dp,
    onLongPress: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val click = rememberUpdatedState(onClick)
    val longPress = rememberUpdatedState(onLongPress)
    Box(
        modifier.height(height)
            .background(if (accent) accentColor else PanelBg, RoundedCornerShape(4.dp))
            .border(1.dp, if (accent) accentColor else Line, RoundedCornerShape(4.dp))
            .pointerInput(text, accent, accentColor) {
                detectTapGestures(
                    onTap = { click.value() },
                    onLongPress = { longPress.value?.invoke() },
                )
            }
            .padding(horizontal = hPad),
        contentAlignment = Alignment.Center,
    ) {
        QLabel(text, if (accent) Color.White else Text0, FontWeight.Bold, fontSize, maxLines = 1)
    }
}

/** A titled control group with a domain tint and header colour. */
@Composable
internal fun QPanel(
    title: String,
    tint: Color,
    head: Color,
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit,
) {
    Column(
        modifier.fillMaxWidth().background(tint, RoundedCornerShape(4.dp))
            .border(1.dp, Line, RoundedCornerShape(4.dp)).padding(8.dp),
    ) {
        QLabel(title, head, FontWeight.Bold, 11)
        Spacer(Modifier.height(6.dp))
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

/**
 * A karaoke-style module: coloured border, centred coloured title, and the
 * controls sitting in a grey STATION box — same construction everywhere.
 */
@Composable
internal fun QVPanel(
    title: String,
    head: Color,
    compact: Boolean = false,
    modifier: Modifier = Modifier,
    // The panel is the ELASTIC one in its column: the caller gives the module
    // weight(1f) and sets fill, and the station stretches to the module's real
    // height so a BoxWithConstraints inside it gets a BOUNDED maxHeight to
    // solve against. Without this the station wraps its content, the module
    // keeps the slack as dead space, and anything sized from the width alone
    // overflows the rail instead.
    fill: Boolean = false,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val pad = if (compact) 4.dp else 7.dp
    val innerPad = if (compact) 4.dp else 6.dp
    val gap = if (compact) 3.dp else 4.dp
    Column(
        modifier.fillMaxWidth().background(ModuleBg, RoundedCornerShape(8.dp))
            .border(2.dp, head.copy(alpha = 0.8f), RoundedCornerShape(8.dp)).padding(pad),
        verticalArrangement = Arrangement.spacedBy(gap),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            QLabel(title, head, FontWeight.Bold, 10, letterSpacing = 2)
        }
        Column(
            (if (fill) Modifier.weight(1f) else Modifier).fillMaxWidth()
                .background(if (compact) PanelBg else AppGrey, RoundedCornerShape(6.dp))
                .border(1.dp, Line, RoundedCornerShape(6.dp))
                .padding(innerPad),
            verticalArrangement = Arrangement.spacedBy(gap),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            content()
        }
    }
}

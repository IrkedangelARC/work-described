//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.edid

import android.content.Context
import android.hardware.display.DisplayManager
import android.view.Display
import java.io.File

/**
 * Everything we can learn about what is plugged into the HDMI port.
 *
 * Two paths, tried in order:
 *   RAW_EDID        read and decode /sys/class/drm/<connector>/edid. Richest.
 *                   Verified working from an unprivileged app on the AYN Thor,
 *                   but stock AOSP normally denies untrusted_app sysfs reads,
 *                   so this is NOT portable and must never be assumed.
 *   DISPLAY_MANAGER public API. Always available, but thinner: it cannot tell
 *                   you the manufacture date, physical size, gamma, or the
 *                   detailed timing's pixel clock.
 *
 * The UI must show which path produced the data. Presenting DisplayManager
 * output as though it were a decoded EDID would be a lie on a load-in.
 */
enum class SinkSource { RAW_EDID, DISPLAY_MANAGER, NONE }

data class SinkMode(val width: Int, val height: Int, val refreshHz: Float, val isActive: Boolean)

data class SinkInfo(
    val source: SinkSource,
    val connected: Boolean,
    val connectorName: String?,          // e.g. "card0-DP-1", raw path only
    val displayName: String?,
    val manufacturerPnpId: String?,
    val productCode: Int?,
    val manufactureWeek: Int?,           // raw path only
    val manufactureYear: Int?,           // raw path only
    val edidVersion: String?,            // raw path only
    val diagonalInches: Double?,         // raw path only
    val preferredTiming: DetailedTiming?,// raw path only
    val modes: List<SinkMode>,
    val activeMode: SinkMode?,
    val supportsAudio: Boolean?,         // raw path only, from the CEA block
    val checksumValid: Boolean?,
    val edid: Edid?,
    /** Display.getColorMode() is not public API, so we use the two accessors that
     *  are. If the sink composites wide gamut, our sRGB code values get converted
     *  on the way out and the wire no longer carries what we drew. */
    val wideColorGamut: Boolean? = null,
    val compositionColorSpace: String? = null,
    val note: String? = null
) {
    /**
     * Not a fault. On a wide-gamut chain the compositor converts our sRGB
     * primaries, so the LIGHT is correct but the wire carries different code
     * values. Irrelevant when judging a projector by eye, which is what this
     * tool is for; it only matters if someone is reading a scope.
     */
    val colorModeNote: String?
        get() = when (wideColorGamut) {
            null, false -> null
            // Deliberately does NOT name the space. getPreferredWideGamutColorSpace()
            // reports the device's preferred space (Display P3 here) while
            // SurfaceFlinger was measured compositing the HDMI output in BT.2020.
            // The claim we can stand behind is that conversion happens, not which
            // matrix is used, so say only that.
            true -> "Colour is visually correct.\nWire code values differ for\nsaturated colours. Matters\nonly for scope work."
        }

    companion object {

        /**
         * The raw EDID gives the best IDENTITY and the exact preferred TIMING,
         * but its mode list is only the detailed timing descriptors, typically
         * one entry. The modes we can actually drive come from the system,
         * which has already merged the DTDs, established/standard timings and
         * the CEA short video descriptors. So: identity from EDID, mode list
         * from DisplayManager. The badge still reports RAW_EDID because the
         * identity and timing, which is what the badge is about, came from the
         * block itself.
         */
        fun resolve(context: Context): SinkInfo {
            val raw = fromSysfs()
            if (raw != null) {
                val dm = displayModes(context)
                val (wide, space) = externalColorSpace(context)
                return if (dm.isEmpty()) raw.copy(wideColorGamut = wide, compositionColorSpace = space)
                else raw.copy(
                    modes = dm,
                    activeMode = dm.firstOrNull { it.isActive },
                    wideColorGamut = wide,
                    compositionColorSpace = space
                )
            }
            return fromDisplayManager(context)
        }

        /** Modes the system will actually offer for the external display. */
        private fun displayModes(context: Context): List<SinkMode> {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val ext = externalDisplay(dm) ?: return emptyList()
            val active = ext.mode
            return ext.supportedModes.map {
                SinkMode(it.physicalWidth, it.physicalHeight, it.refreshRate, it.modeId == active.modeId)
            }
        }

        private fun externalColorSpace(context: Context): Pair<Boolean?, String?> {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val d = externalDisplay(dm) ?: return null to null
            return d.isWideColorGamut to d.preferredWideGamutColorSpace?.name
        }

        private fun externalDisplay(dm: DisplayManager): Display? =
            dm.displays.firstOrNull { d ->
                d.displayId != Display.DEFAULT_DISPLAY &&
                    (d.flags and Display.FLAG_PRESENTATION) != 0 &&
                    d.deviceProductInfo?.manufacturerPnpId?.let { it != "QCM" } == true
            }

        // ---------- path 1: raw EDID out of sysfs ----------

        /**
         * Find the connected external connector. Scan rather than hard-coding
         * card0-DP-1: the connector name is board-specific, and on this device
         * the internal panels are DSI while Virtual-* connectors always read
         * "connected" and carry no EDID.
         */
        private fun externalConnectors(): List<File> {
            val drm = File("/sys/class/drm")
            val kids = drm.listFiles() ?: return emptyList()
            return kids.filter { f ->
                val n = f.name
                n.contains('-') &&
                    !n.contains("DSI", ignoreCase = true) &&
                    !n.contains("Virtual", ignoreCase = true) &&
                    !n.contains("Writeback", ignoreCase = true)
            }.sortedBy { it.name }
        }

        private fun fromSysfs(): SinkInfo? {
            for (conn in externalConnectors()) {
                val status = runCatching { File(conn, "status").readText().trim() }.getOrNull() ?: continue
                if (!status.equals("connected", ignoreCase = true)) continue
                val bytes = runCatching { File(conn, "edid").readBytes() }.getOrNull() ?: continue
                if (bytes.size < 128) continue
                val e = Edid.parse(bytes) ?: continue
                val pref = e.preferredTiming
                val modes = e.detailedTimings.map {
                    SinkMode(it.hActive, it.vActive, it.refreshHz.toFloat(), it === pref)
                }
                return SinkInfo(
                    source = SinkSource.RAW_EDID,
                    connected = true,
                    connectorName = conn.name,
                    displayName = e.monitorName,
                    manufacturerPnpId = e.manufacturerPnpId,
                    productCode = e.productCode,
                    manufactureWeek = e.manufactureWeek,
                    manufactureYear = e.manufactureYear,
                    edidVersion = "${e.version}.${e.revision}",
                    diagonalInches = e.diagonalInches.takeIf { it > 0 },
                    preferredTiming = pref,
                    modes = modes,
                    activeMode = modes.firstOrNull { it.isActive },
                    supportsAudio = e.ceaBasicAudio,
                    checksumValid = e.checksumValid,
                    edid = e
                )
            }
            return null
        }

        // ---------- path 2: DisplayManager ----------

        private fun fromDisplayManager(context: Context): SinkInfo {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val external = externalDisplay(dm)
            if (external == null) {
                return SinkInfo(
                    source = SinkSource.NONE, connected = false, connectorName = null,
                    displayName = null, manufacturerPnpId = null, productCode = null,
                    manufactureWeek = null, manufactureYear = null, edidVersion = null,
                    diagonalInches = null, preferredTiming = null, modes = emptyList(),
                    activeMode = null, supportsAudio = null, checksumValid = null, edid = null,
                    note = "No external display detected."
                )
            }
            val active = external.mode
            val modes = external.supportedModes.map {
                SinkMode(it.physicalWidth, it.physicalHeight, it.refreshRate, it.modeId == active.modeId)
            }
            val info = external.deviceProductInfo
            return SinkInfo(
                source = SinkSource.DISPLAY_MANAGER,
                connected = true,
                connectorName = null,
                displayName = info?.name?.ifBlank { null } ?: external.name,
                manufacturerPnpId = info?.manufacturerPnpId,
                productCode = info?.productId?.toIntOrNull(),
                manufactureWeek = null,
                manufactureYear = null,
                edidVersion = null,
                diagonalInches = null,
                preferredTiming = null,
                modes = modes,
                activeMode = modes.firstOrNull { it.isActive },
                supportsAudio = null,
                checksumValid = null,
                edid = null,
                wideColorGamut = external.isWideColorGamut,
                compositionColorSpace = external.preferredWideGamutColorSpace?.name,
                note = "Raw EDID unreadable on this device; showing public API data only."
            )
        }
    }
}

//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.edid

/**
 * EDID 1.x base-block decoder, plus the parts of the CEA-861 extension that
 * matter on a load-in.
 *
 * Pure Kotlin, no Android dependencies, so it is unit-testable on the JVM
 * against a captured block. Known-good fixture: the RTK / SF10T 10" monitor,
 * see EdidTest.
 */

/** One 18-byte detailed timing descriptor, with the timing already worked out. */
data class DetailedTiming(
    val pixelClockMHz: Double,
    val hActive: Int,
    val hBlank: Int,
    val vActive: Int,
    val vBlank: Int,
    val hSyncOffset: Int,
    val hSyncWidth: Int,
    val vSyncOffset: Int,
    val vSyncWidth: Int,
    val hImageSizeMm: Int,
    val vImageSizeMm: Int,
    val interlaced: Boolean
) {
    val hTotal: Int get() = hActive + hBlank
    val vTotal: Int get() = vActive + vBlank

    /** Vertical refresh derived from the clock and the totals, not from a lookup. */
    val refreshHz: Double
        get() = if (hTotal > 0 && vTotal > 0) pixelClockMHz * 1_000_000.0 / (hTotal * vTotal) else 0.0

    val summary: String
        get() = "%dx%d%s @ %.3f Hz".format(hActive, vActive, if (interlaced) "i" else "p", refreshHz)
}

data class Edid(
    val raw: ByteArray,
    val manufacturerPnpId: String,
    val productCode: Int,
    val serialNumber: Long,
    val manufactureWeek: Int,
    val manufactureYear: Int,
    val version: Int,
    val revision: Int,
    val digital: Boolean,
    val bitDepth: Int?,           // null when analogue or "undefined"
    val hImageSizeCm: Int,
    val vImageSizeCm: Int,
    val gamma: Double?,
    val monitorName: String?,
    val serialString: String?,
    val detailedTimings: List<DetailedTiming>,
    val extensionBlocks: Int,
    val checksumValid: Boolean,
    val ceaBasicAudio: Boolean?,  // null when there is no CEA extension
    val ceaUnderscan: Boolean?,
    val ceaVics: List<Int>
) {
    /** Panel diagonal in inches, derived from the cm image size. 0 when not stated. */
    val diagonalInches: Double
        get() {
            if (hImageSizeCm <= 0 || vImageSizeCm <= 0) return 0.0
            val d = Math.sqrt((hImageSizeCm * hImageSizeCm + vImageSizeCm * vImageSizeCm).toDouble())
            return d / 2.54
        }

    /** The first detailed timing is the sink's preferred (native) mode. */
    val preferredTiming: DetailedTiming? get() = detailedTimings.firstOrNull()

    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)

    companion object {
        private val HEADER = byteArrayOf(0, -1, -1, -1, -1, -1, -1, 0)

        fun parse(bytes: ByteArray): Edid? {
            if (bytes.size < 128) return null
            for (i in 0 until 8) if (bytes[i] != HEADER[i]) return null

            fun u(i: Int) = bytes[i].toInt() and 0xFF

            val mfg = (u(8) shl 8) or u(9)
            val pnp = buildString {
                for (shift in intArrayOf(10, 5, 0)) {
                    val c = (mfg shr shift) and 0x1F
                    append(('A' - 1 + c))
                }
            }

            val vidInput = u(20)
            val isDigital = (vidInput and 0x80) != 0
            val depthCode = (vidInput shr 4) and 0x07
            val depth = if (isDigital && depthCode in 1..6) depthCode * 2 + 4 else null

            val gammaRaw = u(23)
            val gamma = if (gammaRaw == 0xFF) null else (gammaRaw + 100) / 100.0

            var monitorName: String? = null
            var serialString: String? = null
            val timings = mutableListOf<DetailedTiming>()

            for (d in 0 until 4) {
                val o = 54 + d * 18
                if (u(o) == 0 && u(o + 1) == 0 && u(o + 2) == 0) {
                    val text = String(bytes, o + 5, 13, Charsets.US_ASCII)
                        .substringBefore('\n').trim()
                    when (u(o + 3)) {
                        0xFC -> monitorName = text
                        0xFF -> serialString = text
                    }
                } else {
                    val clock = ((u(o + 1) shl 8) or u(o)) / 100.0
                    if (clock <= 0.0) continue
                    timings += DetailedTiming(
                        pixelClockMHz = clock,
                        hActive = u(o + 2) or ((u(o + 4) and 0xF0) shl 4),
                        hBlank = u(o + 3) or ((u(o + 4) and 0x0F) shl 8),
                        vActive = u(o + 5) or ((u(o + 7) and 0xF0) shl 4),
                        vBlank = u(o + 6) or ((u(o + 7) and 0x0F) shl 8),
                        hSyncOffset = u(o + 8) or ((u(o + 11) and 0xC0) shl 2),
                        hSyncWidth = u(o + 9) or ((u(o + 11) and 0x30) shl 4),
                        vSyncOffset = ((u(o + 10) and 0xF0) shr 4) or ((u(o + 11) and 0x0C) shl 2),
                        vSyncWidth = (u(o + 10) and 0x0F) or ((u(o + 11) and 0x03) shl 4),
                        hImageSizeMm = u(o + 12) or ((u(o + 14) and 0xF0) shl 4),
                        vImageSizeMm = u(o + 13) or ((u(o + 14) and 0x0F) shl 8),
                        interlaced = (u(o + 17) and 0x80) != 0
                    )
                }
            }

            var sum = 0
            for (i in 0 until 128) sum += u(i)
            val checksumOk = (sum and 0xFF) == 0

            // CEA-861 extension, if present and if we were given the whole thing.
            var basicAudio: Boolean? = null
            var underscan: Boolean? = null
            val vics = mutableListOf<Int>()
            if (bytes.size >= 256 && u(128) == 0x02) {
                val flags = u(131)
                underscan = (flags and 0x80) != 0
                basicAudio = (flags and 0x40) != 0
                val dtdOffset = u(130)
                var p = 132
                while (p < 128 + dtdOffset && p < bytes.size) {
                    val tag = (u(p) shr 5) and 0x07
                    val len = u(p) and 0x1F
                    if (len == 0) break
                    if (tag == 2) { // video data block: short video descriptors
                        for (k in 1..len) {
                            if (p + k >= bytes.size) break
                            vics += u(p + k) and 0x7F
                        }
                    }
                    p += len + 1
                }
            }

            return Edid(
                raw = bytes,
                manufacturerPnpId = pnp,
                productCode = (u(11) shl 8) or u(10),
                serialNumber = ((u(15).toLong() shl 24) or (u(14).toLong() shl 16) or
                        (u(13).toLong() shl 8) or u(12).toLong()),
                manufactureWeek = u(16),
                manufactureYear = u(17) + 1990,
                version = u(18),
                revision = u(19),
                digital = isDigital,
                bitDepth = depth,
                hImageSizeCm = u(21),
                vImageSizeCm = u(22),
                gamma = gamma,
                monitorName = monitorName?.ifBlank { null },
                serialString = serialString?.ifBlank { null },
                detailedTimings = timings,
                extensionBlocks = u(126),
                checksumValid = checksumOk,
                ceaBasicAudio = basicAudio,
                ceaUnderscan = underscan,
                ceaVics = vics
            )
        }
    }
}

//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.signal.edid

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixture: the real 256-byte EDID captured off a 10" RTK/SF10T monitor via the
 * AYN Thor's USB-C to HDMI adapter on 2026-08-27. Every expected value below was
 * decoded by hand from the hex dump before this decoder existed, so this test
 * checks the code against the block, not against itself.
 */
class EdidTest {

    private fun fixture(): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("sf10t.edid")!!.readBytes()

    @Test
    fun parsesIdentity() {
        val e = Edid.parse(fixture())
        assertNotNull("fixture failed to parse", e)
        e!!
        assertEquals("RTK", e.manufacturerPnpId)
        assertEquals(0xc247, e.productCode)
        assertEquals(16843009L, e.serialNumber)
        assertEquals(41, e.manufactureWeek)
        assertEquals(2025, e.manufactureYear)
        assertEquals(1, e.version)
        assertEquals(3, e.revision)
        assertEquals("SF10T", e.monitorName)
        assertEquals("demoset-1", e.serialString)
        assertEquals(1, e.extensionBlocks)
    }

    @Test
    fun parsesPhysicalSize() {
        val e = Edid.parse(fixture())!!
        assertEquals(23, e.hImageSizeCm)
        assertEquals(14, e.vImageSizeCm)
        // sqrt(23^2 + 14^2) / 2.54 = 10.63"
        assertEquals(10.63, e.diagonalInches, 0.05)
        assertTrue("should be a digital input", e.digital)
    }

    @Test
    fun derivesPreferredTimingFromClockAndTotals() {
        val e = Edid.parse(fixture())!!
        val t = e.preferredTiming
        assertNotNull("no detailed timing found", t)
        t!!
        assertEquals(1920, t.hActive)
        assertEquals(1280, t.vActive)
        assertEquals(164.82, t.pixelClockMHz, 0.005)
        assertEquals(2050, t.hTotal)
        assertEquals(1340, t.vTotal)
        // 164.82e6 / (2050 * 1340) = 60.000 Hz
        assertEquals(60.000, t.refreshHz, 0.002)
        assertTrue("should be progressive", !t.interlaced)
    }

    @Test
    fun checksumIsValid() {
        assertEquals(true, Edid.parse(fixture())!!.checksumValid)
    }

    @Test
    fun rejectsGarbage() {
        assertEquals(null, Edid.parse(ByteArray(128)))
        assertEquals(null, Edid.parse(ByteArray(4)))
    }
}

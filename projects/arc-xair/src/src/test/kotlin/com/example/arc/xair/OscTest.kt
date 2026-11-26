//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class OscTest {
    @Test
    fun `encode pads address and tags to 4 and writes big-endian args`() {
        val b = Osc.encode("/xinfo")
        // "/xinfo" + NUL + 1 pad = 8, "," + NUL + 2 pad = 4
        val expected = "/xinfo".toByteArray() + byteArrayOf(0, 0) + ",".toByteArray() + byteArrayOf(0, 0, 0)
        assertArrayEquals(expected, b)
        val f = Osc.encode("/ch/01/mix/fader", 0.5f)
        // 16 chars + NUL + 3 pad = 20, ",f" + NUL + 1 pad = 4, then 0x3f000000
        assertEquals(28, f.size)
        assertArrayEquals(byteArrayOf(0x3f, 0, 0, 0), f.copyOfRange(24, 28))
    }

    @Test
    fun `decode round-trips i f s and a blob`() {
        val blob = byteArrayOf(1, 2, 3)
        val m = Osc.decode(Osc.encode("/t", 7, 1.5f, "abc", blob))!!
        assertEquals("/t", m.address)
        assertEquals(7, m.args[0])
        assertEquals(1.5f, m.args[1])
        assertEquals("abc", m.args[2])
        assertArrayEquals(blob, m.args[3] as ByteArray)
    }

    @Test
    fun `xinfo reply as the XR16 sends it`() {
        val m = Osc.decode(Osc.encode("/xinfo", "192.0.2.31", "XR16-00-00-01", "XR16", "1.18"))!!
        assertEquals(listOf("192.0.2.31", "XR16-00-00-01", "XR16", "1.18"), m.args)
    }

    @Test
    fun `meters blob is little-endian int16 in 1 over 256 dB`() {
        // count=2, values -42.5 dB (-10880) and 0 dB
        val v = (-42.5 * 256).toInt()
        val b = byteArrayOf(2, 0, 0, 0, (v and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), 0, 0)
        val m = XAirClient.decodeMeters(b)
        assertEquals(2, m.size)
        assertEquals(-42.5f, m[0], 0.001f)
        assertEquals(0f, m[1], 0.001f)
    }

    @Test
    fun `fader taper pins at the documented points and inverts`() {
        assertEquals(0f, XAirClient.faderToDb(0.75f), 0.01f) // unity
        assertEquals(-10f, XAirClient.faderToDb(0.5f), 0.01f)
        assertEquals(-30f, XAirClient.faderToDb(0.25f), 0.01f)
        assertEquals(-60f, XAirClient.faderToDb(0.0625f), 0.01f)
        assertEquals(-90f, XAirClient.faderToDb(0f), 0.01f)
        for (f in listOf(0f, 0.03f, 0.1f, 0.25f, 0.4f, 0.7077f, 0.75f, 1f)) {
            assertEquals(f, XAirClient.dbToFader(XAirClient.faderToDb(f)), 0.002f)
        }
    }
}

package com.example.arc.ptz

import com.example.arc.ptz.follow.FollowConfig
import com.example.arc.ptz.follow.FollowDrive
import com.example.arc.ptz.follow.FollowLoop
import com.example.arc.ptz.follow.FollowState
import com.example.arc.ptz.follow.SubjectBox
import kotlin.math.abs
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/**
 * ARC Follow on a synthetic stage (plan section 5, Phase 0b). The plant is a camera with a
 * horizontal field of view [fovDeg] whose pan runs at drive * [maxDegPerS]; the subject is an
 * angle in the world. The loop sees the subject's box [latencyMs] late, like RTSP does.
 */
private class Stage(
    val fovDeg: Double = 40.0,
    val maxDegPerS: Double = 60.0,
    val latencyMs: Long = 300,
    val frameMs: Long = 33,
    cfg: FollowConfig = FollowConfig(latencyMs = 300.0),
) {
    val loop = FollowLoop(cfg)
    var camDeg = 0.0
    var subjectDeg = 0.0
    var t = 0L
    private val history = ArrayDeque<Pair<Long, Double>>()   // (time, subject frame x) as the camera saw it then
    var lastDrive = FollowDrive.STOP_IDLE
    val errors = mutableListOf<Double>()       // frame x error vs 0.5 per tick (true, not delayed)
    val reversals get() = run { var n = 0; var s = 0.0; for (d in drives) { val sg = kotlin.math.sign(d); if (sg != 0.0 && s != 0.0 && sg != s) n++; if (sg != 0.0) s = sg }; n }
    private val drives = mutableListOf<Double>()

    fun frameX(): Double = 0.5 + (subjectDeg - camDeg) / fovDeg
    fun start() { loop.start(t) }

    /** Advance one frame: move the camera on the last drive, move the subject by [subjectDegPerS], detect with latency. */
    fun tick(subjectDegPerS: Double = 0.0, visible: Boolean = true) {
        val dt = frameMs / 1000.0
        camDeg += lastDrive.pan * maxDegPerS * dt
        subjectDeg += subjectDegPerS * dt
        t += frameMs
        val x = frameX()
        errors += x - 0.5
        history.addLast(t to x)
        var seen: Double? = null
        while (history.isNotEmpty() && history.first().first <= t - latencyMs) seen = history.removeFirst().second
        val box = if (visible && seen != null && seen in 0.0..1.0) SubjectBox(seen - 0.04, 0.3, 0.08, 0.3) else null
        lastDrive = loop.update(box, t)
        drives += lastDrive.pan
    }

    fun run(seconds: Double, subjectDegPerS: Double = 0.0, visible: Boolean = true) {
        repeat((seconds * 1000 / frameMs).toInt()) { tick(subjectDegPerS, visible) }
    }
}

class FollowLoopTest {
    @Test fun `idle until armed, stop forgets`() {
        val l = FollowLoop()
        assertEquals(FollowDrive.STOP_IDLE, l.update(SubjectBox(0.8, 0.3, 0.1, 0.3), 0))
        l.start(0)
        assertTrue(l.update(SubjectBox(0.8, 0.3, 0.1, 0.3), 33).pan > 0.0)
        assertEquals(FollowDrive.STOP_IDLE, l.stop())
        assertEquals(FollowDrive.STOP_IDLE, l.update(SubjectBox(0.8, 0.3, 0.1, 0.3), 66))
    }

    @Test fun `a subject right of centre pans right, left pans left, above tilts up`() {
        val l = FollowLoop(); l.start(0)
        val r = l.update(SubjectBox(0.8, 0.37, 0.1, 0.1), 33)
        assertTrue("$r", r.pan > 0 && r.tilt == 0.0)
        l.stop(); l.start(0)
        val left = l.update(SubjectBox(0.1, 0.37, 0.1, 0.1), 33)
        assertTrue("$left", left.pan < 0)
        l.stop(); l.start(0)
        val up = l.update(SubjectBox(0.45, 0.05, 0.1, 0.1), 33)
        assertTrue("$up", up.tilt > 0 && up.pan == 0.0)
    }

    @Test fun `step offset settles inside the dead band with at most one reversal`() {
        val s = Stage(); s.start()
        s.subjectDeg = 12.0
        s.run(4.0)
        val tail = s.errors.takeLast(30)
        assertTrue("did not settle: ${tail.map { "%.3f".format(it) }}", tail.all { abs(it) < 0.06 })
        assertTrue("hunting: ${s.reversals} reversals", s.reversals <= 1)
        assertEquals("still driving when settled", 0.0, s.lastDrive.pan, 1e-12)
    }

    @Test fun `a walking subject is held within a tenth of the frame at 300 ms latency`() {
        val s = Stage(); s.start()
        s.run(1.0)                      // settle on a still subject
        s.run(6.0, subjectDegPerS = 8.0)   // walks the stage at 8 deg/s (a brisk walk at 6 m)
        val walk = s.errors.takeLast(150)
        val worst = walk.maxOf { abs(it) }
        assertTrue("worst error %.3f of the frame".format(worst), worst < 0.10)
    }

    @Test fun `a turnaround walk does not hunt`() {
        val s = Stage(); s.start()
        s.run(1.0)
        s.run(3.0, subjectDegPerS = 8.0)
        s.run(3.0, subjectDegPerS = -8.0)
        s.run(2.0)
        assertTrue("reversals ${s.reversals}", s.reversals <= 3)
        assertTrue(s.errors.takeLast(20).all { abs(it) < 0.06 })
    }

    @Test fun `loss coasts then stops and searches, a return reacquires`() {
        val s = Stage(); s.start()
        s.run(1.0, subjectDegPerS = 8.0)
        assertEquals(FollowState.TRACKING, s.loop.state)
        s.run(0.2, subjectDegPerS = 8.0, visible = false)
        assertEquals(FollowState.COASTING, s.loop.state)
        assertTrue("coast keeps the last direction", s.lastDrive.pan > 0.0)
        s.run(1.0, subjectDegPerS = 8.0, visible = false)
        assertEquals(FollowState.SEARCHING, s.loop.state)
        assertEquals(0.0, s.lastDrive.pan, 1e-12)
        s.run(3.0)
        assertEquals(FollowState.TRACKING, s.loop.state)
        assertTrue(s.errors.takeLast(10).all { abs(it) < 0.06 })
    }

    @Test fun `stale heartbeat and manual hold both stop the head`() {
        val l = FollowLoop(); l.start(0)
        assertTrue(l.update(SubjectBox(0.8, 0.37, 0.1, 0.1), 33).pan > 0)
        val st = l.stale(500)
        assertEquals(0.0, st.pan, 1e-12); assertEquals(FollowState.SEARCHING, st.state)
        l.manualHold(600)
        assertEquals(0.0, l.update(SubjectBox(0.9, 0.37, 0.1, 0.1), 700).pan, 1e-12)
        assertTrue("resumes after the hold", l.update(SubjectBox(0.9, 0.37, 0.1, 0.1), 2700).pan > 0)
    }

    @Test fun `zoom holds the box height inside its band`() {
        val l = FollowLoop(FollowConfig(zoomTargetHeight = 0.45)); l.start(0)
        var t = 0L
        var z = 0
        repeat(40) { t += 33; z = l.update(SubjectBox(0.45, 0.2, 0.1, 0.2), t).zoom }
        assertEquals("small subject zooms in", 1, z)
        repeat(80) { t += 33; z = l.update(SubjectBox(0.45, 0.1, 0.1, 0.8), t).zoom }
        assertEquals("large subject zooms out", -1, z)
        repeat(80) { t += 33; z = l.update(SubjectBox(0.45, 0.3, 0.1, 0.45), t).zoom }
        assertEquals("in band holds", 0, z)
    }

    @Test fun `drive never exceeds one and never speeds up faster than the slew`() {
        val s = Stage(cfg = FollowConfig(latencyMs = 300.0, slewPerSecond = 4.0)); s.start()
        s.subjectDeg = 18.0
        var prev = 0.0
        repeat(60) {
            s.tick()
            val p = s.lastDrive.pan
            assertTrue(abs(p) <= 1.0)
            val speedingUp = abs(p) > abs(prev) && (kotlin.math.sign(p) == kotlin.math.sign(prev) || prev == 0.0)
            if (speedingUp) assertTrue("jump ${abs(p - prev)}", abs(p - prev) <= 4.0 * 0.033 + 1e-9)
            prev = p
        }
    }
}

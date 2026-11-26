package com.example.arc.ptz.follow

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sign

/**
 * ARC Follow, the controller (docs/plans/PLAN_auto_tracking_module.txt section 3.3).
 * Pure: no camera, no clock, no detector. It is handed the subject's box (or null when lost)
 * with the frame time and answers a normalised drive for the head layer:
 * pan and tilt in -1..1 (positive = subject is right of / above the target, so pan right / tilt up),
 * zoom -1 out, 0 hold, +1 in, and the state. The head layer maps -1..1 onto its own speed table.
 *
 * Per tick: error from the target point, corrected for the picture's lag by the drives sent since that
 * frame was captured (a Smith style predictor, which is what makes a 300 to 800 ms RTSP picture usable),
 * dead band with hysteresis, one euro smoothing, PD with subject velocity feed forward, clamp, response
 * curve, slew limit.
 * Loss: coast on the last drive for [FollowConfig.coastMs], then stop and search.
 * Heartbeat: no update for [FollowConfig.staleMs] means stop, whatever the state.
 * The design follows the published shape of AutoPTZ's loop (AGPL, read for design only); this is ARC's code.
 */
data class SubjectBox(val x: Double, val y: Double, val w: Double, val h: Double, val confidence: Double = 1.0) {
    val cx get() = x + w / 2
    val cy get() = y + h / 2
}

data class FollowConfig(
    /** Where the subject's centre should sit, as frame fractions. */
    val targetX: Double = 0.5,
    val targetY: Double = 0.42,
    /** Dead band in half frame units (0.08 = 4% of the frame width either side). Hysteresis widens it once settled. */
    val deadBand: Double = 0.08,
    val hysteresis: Double = 0.04,
    val kp: Double = 1.2,
    val kd: Double = 0.15,
    /** Velocity feed forward: subject speed (half frames per second) added to the drive. */
    val feedForward: Double = 1.0,
    /** Subject speed (half frames per second) below which it counts as standing still. */
    val moveThreshold: Double = 0.15,
    /** Picture lag from the sensor to this loop, in ms. Measured on the bench with a flash in frame (plan Phase 1). */
    val latencyMs: Double = 300.0,
    /**
     * How fast the picture moves at full drive, in half frames per second: the head's top speed over half
     * the horizontal field of view. UE50 at Normal 60 deg/s on a 40 degree view = 60 / 20 = 3.0. The head
     * layer sets it from the speed table and the zoom's field of view (fovCal).
     */
    val gain: Double = 3.0,
    /** One euro filter: minCutoff Hz at rest, beta speeds it up with motion. */
    val euroMinCutoff: Double = 1.2,
    val euroBeta: Double = 0.4,
    /** Response curve exponent (1 = linear, >1 eases in near zero). */
    val power: Double = 1.2,
    /** Largest change of the drive per second. */
    val slewPerSecond: Double = 4.0,
    val coastMs: Long = 400,
    val staleMs: Long = 400,
    /** Zoom: hold the subject's box height near this fraction, with a band either side. 0 disables zoom. */
    val zoomTargetHeight: Double = 0.0,
    val zoomBand: Double = 0.15,
)

enum class FollowState { IDLE, TRACKING, COASTING, SEARCHING }

data class FollowDrive(val pan: Double, val tilt: Double, val zoom: Int, val state: FollowState) {
    val moving get() = pan != 0.0 || tilt != 0.0
    companion object {
        val STOP_IDLE = FollowDrive(0.0, 0.0, 0, FollowState.IDLE)
    }
}

/** One euro filter: low lag on fast motion, low jitter at rest. */
class OneEuro(private val minCutoff: Double, private val beta: Double, private val dCutoff: Double = 1.0) {
    private var xPrev: Double? = null
    private var rawPrev = 0.0
    private var dxPrev = 0.0
    private var tPrev = 0L
    private fun alpha(dtS: Double, cutoff: Double): Double {
        val tau = 1.0 / (2 * Math.PI * cutoff)
        return 1.0 / (1.0 + tau / dtS)
    }
    fun filter(x: Double, tMs: Long): Double {
        val prev = xPrev
        if (prev == null) { xPrev = x; rawPrev = x; tPrev = tMs; return x }
        val dt = ((tMs - tPrev).coerceAtLeast(1)) / 1000.0
        val dx = (x - rawPrev) / dt   // from the raw previous sample: the filtered one lags and would inflate the rate
        rawPrev = x
        val aD = alpha(dt, dCutoff)
        val dxHat = aD * dx + (1 - aD) * dxPrev
        val cutoff = minCutoff + beta * abs(dxHat)
        val a = alpha(dt, cutoff)
        val xHat = a * x + (1 - a) * prev
        xPrev = xHat; dxPrev = dxHat; tPrev = tMs
        return xHat
    }
    /** The filtered velocity, units per second. */
    val velocity get() = dxPrev
    fun reset() { xPrev = null; rawPrev = 0.0; dxPrev = 0.0 }
}

class FollowLoop(var cfg: FollowConfig = FollowConfig()) {
    var state: FollowState = FollowState.IDLE
        private set
    /** The last tick's internals, for the trace tests and the console's status line. */
    var debug: String = ""
        private set
    private val euroX = OneEuro(cfg.euroMinCutoff, cfg.euroBeta)
    private val euroY = OneEuro(cfg.euroMinCutoff, cfg.euroBeta)
    private var lastPan = 0.0
    private var lastTilt = 0.0
    private var lastTick = 0L
    private var lastSeen = 0L
    private var lostAt = 0L
    private var settledX = false
    private var settledY = false
    private var heightEma = 0.0
    private var armed = false
    private var holdUntil = 0L
    /** Where our own drives have taken the picture: (time, pan travel, tilt travel) in half frames, kept over the latency window. */
    private val path = ArrayDeque<Triple<Long, Double, Double>>()
    private var camPan = 0.0
    private var camTilt = 0.0

    /** Arm the follower (FOLLOW on). Nothing drives until the first box arrives. */
    fun start(tMs: Long) { armed = true; state = FollowState.SEARCHING; lastTick = tMs; lastSeen = tMs }

    /** FOLLOW off: everything stops and forgets. */
    fun stop(): FollowDrive {
        armed = false; state = FollowState.IDLE
        euroX.reset(); euroY.reset(); lastPan = 0.0; lastTilt = 0.0; settledX = false; settledY = false; heightEma = 0.0
        path.clear(); camPan = 0.0; camTilt = 0.0
        return FollowDrive.STOP_IDLE
    }

    /** The joystick moved: hold for [ms] after the last touch, driving nothing. */
    fun manualHold(tMs: Long, ms: Long = 2000) { holdUntil = tMs + ms; lastPan = 0.0; lastTilt = 0.0; euroX.reset(); euroY.reset() }

    /** Called when no detection arrived in time (heartbeat). Stops the head. */
    fun stale(tMs: Long): FollowDrive {
        lastPan = 0.0; lastTilt = 0.0
        if (armed && state == FollowState.TRACKING) { state = FollowState.SEARCHING }
        return FollowDrive(0.0, 0.0, 0, state)
    }

    /** One detection frame. [box] null means the subject was not seen this frame. */
    fun update(box: SubjectBox?, tMs: Long): FollowDrive {
        if (!armed) return FollowDrive.STOP_IDLE
        val dtS = ((tMs - lastTick).coerceIn(1, 1000)) / 1000.0
        // integrate the drive that has been acting since the last tick, then record the picture's position
        camPan += lastPan * cfg.gain * dtS; camTilt += lastTilt * cfg.gain * dtS
        path.addLast(Triple(tMs, camPan, camTilt))
        val keep = tMs - cfg.latencyMs.toLong() - 2000
        while (path.size > 2 && path.first().first < keep) path.removeFirst()
        lastTick = tMs
        if (tMs < holdUntil) return FollowDrive(0.0, 0.0, 0, state)
        if (box == null) return lost(tMs, dtS)
        if (tMs - lastSeen > cfg.staleMs) { euroX.reset(); euroY.reset() }
        lastSeen = tMs
        state = FollowState.TRACKING
        // error in half frame units, positive = subject right of / above target
        // The box describes the picture as it was latencyMs ago. Put the subject in a fixed frame of reference
        // (the picture's start) by adding where our drives had taken the picture at that moment, filter THAT,
        // and the filtered series gives the subject's own velocity with none of our motion in it.
        val tc = tMs - cfg.latencyMs.toLong()
        val (panAtCapture, tiltAtCapture) = positionAt(tc)
        val subjX = euroX.filter((box.cx - cfg.targetX) / 0.5 + panAtCapture, tMs)
        val subjY = euroY.filter((cfg.targetY - box.cy) / 0.5 + tiltAtCapture, tMs)
        val subjVx = euroX.velocity
        val subjVy = euroY.velocity
        // the error now: where the subject is (carried forward over the lag) against where the picture is now
        val lagS = cfg.latencyMs / 1000.0
        val ex = subjX + subjVx * lagS - camPan
        val ey = subjY + subjVy * lagS - camTilt
        debug = "subjX=%.3f vX=%.3f camPan=%.3f atCap=%.3f ex=%.3f".format(subjX, subjVx, camPan, panAtCapture, ex)
        val panCmd = axis(ex, subjVx - lastPan * cfg.gain, subjVx, settledX).also { settledX = it.second }.first
        val tiltCmd = axis(ey, subjVy - lastTilt * cfg.gain, subjVy, settledY).also { settledY = it.second }.first
        lastPan = slew(lastPan, panCmd, dtS)
        lastTilt = slew(lastTilt, tiltCmd, dtS)
        return FollowDrive(lastPan, lastTilt, zoomStep(box.h), state)
    }

    private fun lost(tMs: Long, dtS: Double): FollowDrive {
        when (state) {
            FollowState.TRACKING -> { state = FollowState.COASTING; lostAt = tMs }
            FollowState.COASTING -> if (tMs - lostAt >= cfg.coastMs) { state = FollowState.SEARCHING; lastPan = 0.0; lastTilt = 0.0 }
            else -> { lastPan = 0.0; lastTilt = 0.0 }
        }
        if (state == FollowState.COASTING) {
            // coast on the last drive, decaying, so a subject crossing behind a pillar is met on the other side
            lastPan *= exp(-dtS / (cfg.coastMs / 1000.0))
            lastTilt *= exp(-dtS / (cfg.coastMs / 1000.0))
        }
        return FollowDrive(lastPan, lastTilt, 0, state)
    }

    /** The picture's travel at time [t], interpolated from the path our drives have made. */
    private fun positionAt(t: Long): Pair<Double, Double> {
        if (path.isEmpty()) return 0.0 to 0.0
        if (t <= path.first().first) return path.first().second to path.first().third
        var prev = path.first()
        for (e in path) {
            if (e.first >= t) {
                val span = (e.first - prev.first).coerceAtLeast(1)
                val f = (t - prev.first).toDouble() / span
                return (prev.second + (e.second - prev.second) * f) to (prev.third + (e.third - prev.third) * f)
            }
            prev = e
        }
        return camPan to camTilt
    }

    /**
     * One axis: dead band with hysteresis, PD on the predicted error plus the subject's own speed as feed
     * forward (in drive units, so a walking subject is matched rather than chased), clamp, curve.
     * [e] predicted error, [v] its rate, [subjV] the subject's speed, all in half frames (per second).
     * Returns the drive and whether the axis counts as settled.
     */
    private fun axis(e: Double, v: Double, subjV: Double, settled: Boolean): Pair<Double, Boolean> {
        val band = if (settled) cfg.deadBand + cfg.hysteresis else cfg.deadBand
        val moving = abs(subjV) >= cfg.moveThreshold
        if (abs(e) < band && !moving) return 0.0 to true
        val ff = if (moving) cfg.feedForward * subjV / cfg.gain else 0.0
        // outside the band the loop aims at the target itself, so it crosses into the band and stops there
        // (deceleration is immediate, see slew); inside the band only a moving subject keeps it driving
        val eff = if (abs(e) < band && !moving) 0.0 else e   // a moving subject is trimmed continuously, no band
        var u = cfg.kp * eff + (if (eff != 0.0) cfg.kd * v else 0.0) + ff
        u = u.coerceIn(-1.0, 1.0)
        u = sign(u) * abs(u).pow(cfg.power)
        return u to false
    }

    /** Slew limits acceleration only: slowing down or stopping is immediate, so the head never overruns the band. */
    private fun slew(prev: Double, target: Double, dtS: Double): Double {
        val step = cfg.slewPerSecond * dtS
        val speedingUp = abs(target) > abs(prev) && sign(target) == sign(prev) || prev == 0.0
        return if (speedingUp) prev + (target - prev).coerceIn(-step, step) else target
    }

    private fun zoomStep(h: Double): Int {
        if (cfg.zoomTargetHeight <= 0.0) return 0
        heightEma = if (heightEma == 0.0) h else heightEma * 0.88 + h * 0.12
        return when {
            heightEma > cfg.zoomTargetHeight * (1 + cfg.zoomBand) -> -1
            heightEma < cfg.zoomTargetHeight * (1 - cfg.zoomBand) -> 1
            else -> 0
        }
    }
}

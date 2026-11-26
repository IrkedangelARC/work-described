//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

import kotlin.concurrent.Volatile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Behringer X AIR (XR12/16/18) over OSC, UDP 10024. The first AUDIO domain
 * client of the ARC control surface (arc-ptz docs/PLAN_arc_control_surface.md §3; moved to its own project 2026-09-08).
 *
 * Bench facts, XR16 fw 1.18 at 192.0.2.31, 2026-09-04:
 *  - /xinfo answers [ip, name, model, firmware].
 *  - The mixer only PUSHES parameter changes while an /xremote has been
 *    received in the last ~10 s; the /meters subscription expires on its
 *    own clock too. Both are re-sent every KEEPALIVE_MS.
 *  - Meter blobs: int32 count (little-endian) then count int16
 *    little-endian, in 1/256 dB. MAPPED BY MEASUREMENT (mute / fader /
 *    LR fader / pan on ch1, 2026-09-04 09:15):
 *      /meters/1 (40): 1-16 input channels PRE-fader (unmoved by mute),
 *                      27 follows ch1's post-fader send = bus 1 out,
 *                      37/38 = MAIN LR L/R POST-fader (die with the LR
 *                      fader, split with pan), 39/40 repeat them.
 *      /meters/5 (44): 1-16 channels POST-fader/mute, 25/26 = LR L/R
 *                      PRE-fader (do not move with the LR fader).
 *      /meters/9 (4):  1/2 = the same LR pre-fader pair.
 *      /meters/0 (8):  the selected channel's detail (1/2 input L/R).
 *    Unmapped: /meters/2 (36), /3 (56), /4 (100), /6 (39), /7 (16), /8 (4).
 *  - Fader floats are 0..1 on the X32 taper (faderToDb / dbToFader).
 *  - Sends are fire-and-forget UDP; the mixer echoes the new value through
 *    the /xremote subscription, and THAT echo is what updates state. An
 *    optimistic local update covers the ~50 ms until it lands.
 */
class XAirClient(val host: String, private val log: (String) -> Unit = {}) {
    data class Info(val ip: String, val name: String, val model: String, val firmware: String)
    data class Channel(
        val n: Int, val name: String = "", val color: Int = 0,
        val fader: Float = 0f, val on: Boolean = true, val gain: Float = 0f,
    )
    data class Bus(val fader: Float = 0f, val on: Boolean = true)

    val connected = MutableStateFlow(false)
    val info = MutableStateFlow<Info?>(null)
    val channels = MutableStateFlow<Map<Int, Channel>>((1..CHANNELS).associateWith { Channel(it) })
    val lr = MutableStateFlow(Bus())
    /** dB per /meters/1 slot, index 0 = slot 1. Empty until the first frame. */
    val meters = MutableStateFlow(FloatArray(0))
    /** dB per /meters/5 slot: channels POST-fader, index 0 = ch 1. */
    val metersPost = MutableStateFlow(FloatArray(0))
    /** Main LR output L/R dB, post-fader (/meters/1 slots 37/38). */
    val lrOut = MutableStateFlow(-128f to -128f)
    /** USB stereo recorder: state code as the desk reports it, elapsed seconds, file. */
    data class Tape(val state: Int = 0, val elapsed: Int = 0, val file: String = "")
    val tape = MutableStateFlow(Tape())
    /** Mute groups 1..4, true = muted. */
    val muteGroups = MutableStateFlow<Map<Int, Boolean>>(emptyMap())
    /** Snapshots: current index and the names the desk holds (index -> name). */
    val snapshotIndex = MutableStateFlow(0)
    val snapshotNames = MutableStateFlow<Map<Int, String>>(emptyMap())

    private val scope = CoroutineScope(SupervisorJob() + ioDispatcher)
    private var socket: UdpTransport? = null
    @Volatile private var lastRx = 0L

    fun start() {
        scope.launch {
            while (isActive) {
                runCatching { session() }.onFailure { log("session error: ${it.message}") }
                connected.value = false
                delay(3_000)
            }
        }
    }

    fun stop() { socket?.close(); scope.cancel() }

    // ------------------------------------------------------------ writes
    fun setFader(ch: Int, v: Float) {
        val c = v.coerceIn(0f, 1f)
        send("/ch/${two(ch)}/mix/fader", c)
        channels.value = channels.value + (ch to (channels.value[ch] ?: Channel(ch)).copy(fader = c))
    }

    fun setOn(ch: Int, on: Boolean) {
        send("/ch/${two(ch)}/mix/on", if (on) 1 else 0)
        channels.value = channels.value + (ch to (channels.value[ch] ?: Channel(ch)).copy(on = on))
    }

    fun setLrFader(v: Float) {
        val c = v.coerceIn(0f, 1f)
        send("/lr/mix/fader", c)
        lr.value = lr.value.copy(fader = c)
    }

    fun setLrOn(on: Boolean) {
        send("/lr/mix/on", if (on) 1 else 0)
        lr.value = lr.value.copy(on = on)
    }

    fun setName(ch: Int, name: String) = send("/ch/${two(ch)}/config/name", name)

    /** Snapshot recall, 1-based as on the mixer. */
    fun loadSnapshot(index: Int) = send("/-snap/load", index)

    fun setMuteGroup(n: Int, muted: Boolean) {
        send("/config/mute/$n", if (muted) 1 else 0)
        muteGroups.value = muteGroups.value + (n to muted)
    }

    /** Recorder state codes seen on the X32 family: 0 stop, 1 pause, 2 play, 3 pause-rec, 4 record. */
    fun tapeLabel(state: Int) = when (state) { 0 -> "STOP"; 1 -> "PAUSE"; 2 -> "PLAY"; 3 -> "REC PAUSE"; 4 -> "REC"; else -> "?$state" }

    private fun send(address: String, vararg args: Any) {
        val s = socket ?: return
        runCatching { s.send(Osc.encode(address, *args)) }.onFailure { log("send $address failed: ${it.message}") }
    }

    // ----------------------------------------------------------- session
    private suspend fun session() {
        val sock = openUdp(host, PORT)
        socket = sock
        log("connecting to $host:$PORT")
        var lastKeepalive = 0L
        var lastAsk = 0L
        while (scope.isActive) {
            val now = epochMillis()
            if (now - lastKeepalive > KEEPALIVE_MS) {
                lastKeepalive = now
                send("/xinfo")
                send("/xremote")
                send("/meters", "/meters/1")
                send("/meters", "/meters/5")
                send("/-stat/tape/state"); send("/-stat/tape/etime")
                if (now - lastAsk > REASK_MS || now - lastRx > 15_000) { lastAsk = now; askAll() }
            }
            val pkt = sock.receive(200)
            if (pkt == null) {
                if (connected.value && now - lastRx > 12_000) { connected.value = false; log("no reply for 12 s") }
                continue
            }
            lastRx = epochMillis()
            if (!connected.value) { connected.value = true; log("connected") }
            Osc.decode(pkt)?.let { handle(it) }
        }
        sock.close()
    }

    /**
     * PACED, not burst. 82 queries fired back to back lost the last two
     * (the LR pair) on the bench 2026-09-04: the desk answers a burst
     * partially and says nothing about the rest. A few ms between sends
     * and the master asked first; the whole set is re-asked every
     * REASK_MS so a dropped reply heals on its own.
     */
    private suspend fun askAll() {
        send("/lr/mix/fader"); delay(4); send("/lr/mix/on"); delay(4)
        for (n in 1..4) { send("/config/mute/$n"); delay(4) }
        send("/-snap/index"); delay(4); send("/-stat/tape/file"); delay(4)
        for (i in 1..SNAPSHOTS) { send("/-snap/${two(i)}/name"); delay(4) }
        for (ch in 1..CHANNELS) {
            val nn = two(ch)
            for (q in listOf("/ch/$nn/config/name", "/ch/$nn/config/color", "/ch/$nn/mix/fader", "/ch/$nn/mix/on", "/headamp/$nn/gain")) {
                send(q); delay(4)
            }
        }
    }

    private fun handle(m: Osc.Message) {
        val a = m.address
        when {
            a == "/xinfo" && m.args.size >= 4 ->
                info.value = Info(m.args[0].toString(), m.args[1].toString(), m.args[2].toString(), m.args[3].toString())
            a.startsWith("/meters/1") -> (m.args.firstOrNull() as? ByteArray)?.let {
                val v = decodeMeters(it)
                meters.value = v
                if (v.size >= 38) lrOut.value = v[36] to v[37]
            }
            a.startsWith("/meters/5") -> (m.args.firstOrNull() as? ByteArray)?.let { metersPost.value = decodeMeters(it) }
            a.startsWith("/config/mute/") -> a.substringAfterLast('/').toIntOrNull()?.let { n ->
                muteGroups.value = muteGroups.value + (n to (((m.args.firstOrNull() as? Int) ?: 0) != 0))
            }
            a == "/-snap/index" -> snapshotIndex.value = (m.args.firstOrNull() as? Int) ?: 0
            a.startsWith("/-snap/") && a.endsWith("/name") -> a.substring(7, 9).toIntOrNull()?.let { i ->
                snapshotNames.value = snapshotNames.value + (i to (m.args.firstOrNull()?.toString() ?: ""))
            }
            a == "/-stat/tape/state" -> tape.value = tape.value.copy(state = (m.args.firstOrNull() as? Int) ?: 0)
            a == "/-stat/tape/etime" -> tape.value = tape.value.copy(elapsed = (m.args.firstOrNull() as? Int) ?: 0)
            a == "/-stat/tape/file" -> tape.value = tape.value.copy(file = m.args.firstOrNull()?.toString() ?: "")
            a.startsWith("/ch/") && a.length > 6 -> {
                val ch = a.substring(4, 6).toIntOrNull() ?: return
                val rest = a.substring(6)
                val cur = channels.value[ch] ?: Channel(ch)
                val next = when (rest) {
                    "/config/name" -> cur.copy(name = m.args.firstOrNull()?.toString() ?: "")
                    "/config/color" -> cur.copy(color = (m.args.firstOrNull() as? Int) ?: 0)
                    "/mix/fader" -> cur.copy(fader = (m.args.firstOrNull() as? Float) ?: cur.fader)
                    "/mix/on" -> cur.copy(on = ((m.args.firstOrNull() as? Int) ?: 1) != 0)
                    else -> return
                }
                channels.value = channels.value + (ch to next)
            }
            a.startsWith("/headamp/") && a.endsWith("/gain") -> {
                val ch = a.substring(9, 11).toIntOrNull() ?: return
                val cur = channels.value[ch] ?: Channel(ch)
                channels.value = channels.value + (ch to cur.copy(gain = (m.args.firstOrNull() as? Float) ?: cur.gain))
            }
            a == "/lr/mix/fader" -> lr.value = lr.value.copy(fader = (m.args.firstOrNull() as? Float) ?: lr.value.fader)
            a == "/lr/mix/on" -> lr.value = lr.value.copy(on = ((m.args.firstOrNull() as? Int) ?: 1) != 0)
        }
    }

    companion object {
        const val PORT = 10024
        const val CHANNELS = 16
        const val SNAPSHOTS = 64
        const val KEEPALIVE_MS = 8_000L
        const val REASK_MS = 60_000L

        fun two(n: Int) = n.toString().padStart(2, '0')

        /** /meters blob: int32 LE count, then count int16 LE in 1/256 dB. */
        fun decodeMeters(b: ByteArray): FloatArray {
            if (b.size < 4) return FloatArray(0)
            val n = (b[0].toInt() and 0xff) or ((b[1].toInt() and 0xff) shl 8) or
                ((b[2].toInt() and 0xff) shl 16) or ((b[3].toInt() and 0xff) shl 24)
            val count = n.coerceIn(0, (b.size - 4) / 2)
            return FloatArray(count) { i ->
                val lo = b[4 + i * 2].toInt() and 0xff
                val hi = b[5 + i * 2].toInt()
                ((hi shl 8) or lo).toShort().toFloat() / 256f
            }
        }

        /** X32/X AIR fader taper, float 0..1 -> dB (-90 = -inf). */
        fun faderToDb(f: Float): Float = when {
            f >= 0.5f -> f * 40f - 30f
            f >= 0.25f -> f * 80f - 50f
            f >= 0.0625f -> f * 160f - 70f
            else -> f * 480f - 90f
        }

        fun dbToFader(db: Float): Float = when {
            db >= -10f -> (db + 30f) / 40f
            db >= -30f -> (db + 50f) / 80f
            db >= -60f -> (db + 70f) / 160f
            else -> (db + 90f) / 480f
        }.coerceIn(0f, 1f)
    }
}

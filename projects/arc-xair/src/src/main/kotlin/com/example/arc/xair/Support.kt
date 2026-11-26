//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.Properties
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

// The seams XAirClient used from arc-ptz :core, JVM-only here.

internal val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
internal fun epochMillis(): Long = System.currentTimeMillis()

interface UdpTransport {
    fun send(data: ByteArray)
    fun receive(timeoutMs: Int): ByteArray?
    fun close()
}

private class JvmUdp(host: String, port: Int) : UdpTransport {
    private val socket = DatagramSocket().apply { connect(InetAddress.getByName(host), port) }
    private val buf = ByteArray(4096)
    override fun send(data: ByteArray) = socket.send(DatagramPacket(data, data.size))
    override fun receive(timeoutMs: Int): ByteArray? {
        socket.soTimeout = timeoutMs
        return try {
            val p = DatagramPacket(buf, buf.size); socket.receive(p); buf.copyOf(p.length)
        } catch (_: SocketTimeoutException) { null }
    }
    override fun close() = socket.close()
}

fun openUdp(host: String, port: Int): UdpTransport = JvmUdp(host, port)

/** `~/.arc-xair.properties`, read once at start. */
object Config {
    private val props = Properties().also { p ->
        val f = File(System.getProperty("user.home"), ".arc-xair.properties")
        if (f.isFile) f.reader().use(p::load)
    }
    fun get(key: String): String? = props.getProperty(key)?.trim()?.takeIf { it.isNotEmpty() }
}

/** `~/Library/Logs/arc-xair.log` and stdout. */
object Log {
    private val file = File(System.getProperty("user.home"), "Library/Logs/arc-xair.log")
    @Synchronized fun log(msg: String) {
        val line = "${java.time.LocalDateTime.now().withNano(0).toString().replace('T', ' ')} $msg"
        println(line)
        runCatching { file.parentFile.mkdirs(); file.appendText(line + "\n") }
    }
}

/**
 * The switcher's program tally, borrowed from a running ARC PTZ QUAD over
 * its control API (`quad.url` + `quad.token`), polled twice a second. The
 * ON AIR marker on the strip is the only thing that needs it.
 */
object QuadTally {
    val program = MutableStateFlow<Set<Int>>(emptySet())
    private val scope = CoroutineScope(SupervisorJob() + ioDispatcher)
    private val re = Regex(""""program":\[([0-9,]*)\]""")

    fun start() {
        val url = Config.get("quad.url") ?: return
        val token = Config.get("quad.token") ?: return
        scope.launch {
            while (isActive) {
                runCatching {
                    val c = java.net.URI("$url/atem/state?token=$token").toURL().openConnection() as java.net.HttpURLConnection
                    c.connectTimeout = 800; c.readTimeout = 800
                    val body = c.inputStream.bufferedReader().readText()
                    program.value = re.find(body)?.groupValues?.get(1)?.split(",")?.mapNotNull { it.trim().toIntOrNull() }?.toSet() ?: emptySet()
                }.onFailure { program.value = emptySet() }
                delay(500)
            }
        }
    }
}

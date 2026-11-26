//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

/**
 * Open Sound Control 1.0, the four types the X AIR speaks: i f s b.
 * Big-endian, every field padded to 4 bytes, type tag string starts with ','.
 * A blob is (int32 length)(bytes)(pad). Pure functions, tested in jvmTest.
 */
object Osc {
    class Message(val address: String, val args: List<Any>) {
        override fun toString() =
            "$address " + args.joinToString(" ") { if (it is ByteArray) "blob[${it.size}]" else it.toString() }
    }

    fun encode(address: String, vararg args: Any): ByteArray {
        val out = ArrayList<Byte>(64)
        fun padTo4() { while (out.size % 4 != 0) out += 0 }
        fun str(s: String) { s.encodeToByteArray().forEach { out += it }; out += 0; padTo4() }
        fun int(v: Int) {
            out += (v ushr 24).toByte(); out += (v ushr 16).toByte(); out += (v ushr 8).toByte(); out += v.toByte()
        }
        str(address)
        val tags = StringBuilder(",")
        for (a in args) tags.append(
            when (a) {
                is Int -> 'i'
                is Float -> 'f'
                is String -> 's'
                is ByteArray -> 'b'
                else -> error("unsupported OSC arg ${a::class.simpleName}")
            },
        )
        str(tags.toString())
        for (a in args) when (a) {
            is Int -> int(a)
            is Float -> int(a.toRawBits())
            is String -> str(a)
            is ByteArray -> { int(a.size); a.forEach { out += it }; padTo4() }
        }
        return out.toByteArray()
    }

    fun decode(b: ByteArray): Message? {
        var i = 0
        fun str(): String? {
            val start = i
            while (i < b.size && b[i] != 0.toByte()) i++
            if (i >= b.size) return null
            val s = b.copyOfRange(start, i).decodeToString()
            i = ((i / 4) + 1) * 4
            return s
        }
        fun int(): Int? {
            if (i + 4 > b.size) return null
            val v = ((b[i].toInt() and 0xff) shl 24) or ((b[i + 1].toInt() and 0xff) shl 16) or
                ((b[i + 2].toInt() and 0xff) shl 8) or (b[i + 3].toInt() and 0xff)
            i += 4
            return v
        }
        val address = str() ?: return null
        if (!address.startsWith("/")) return null
        val tags = str() ?: return Message(address, emptyList())
        val args = ArrayList<Any>()
        for (t in tags.drop(1)) when (t) {
            'i' -> args += (int() ?: return null)
            'f' -> args += Float.fromBits(int() ?: return null)
            's' -> args += (str() ?: return null)
            'b' -> {
                val n = int() ?: return null
                if (i + n > b.size) return null
                args += b.copyOfRange(i, i + n)
                i += n
                i = ((i + 3) / 4) * 4
            }
            else -> return Message(address, args) // unknown tag: keep what we have
        }
        return Message(address, args)
    }
}

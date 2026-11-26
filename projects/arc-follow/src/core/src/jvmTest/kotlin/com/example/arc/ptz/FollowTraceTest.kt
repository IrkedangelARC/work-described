package com.example.arc.ptz
import com.example.arc.ptz.follow.*
import org.junit.Test
class FollowTraceTest {
    @Test fun trace() {
        val loop = FollowLoop(FollowConfig(latencyMs = 300.0)); loop.start(0)
        var cam = 0.0; var subj = 2.0; var t = 0L; var drive = 0.0
        val hist = ArrayDeque<Pair<Long, Double>>()
        val sb = StringBuilder()
        repeat(150) { i ->
            cam += drive * 60.0 * 0.033; t += 33; if (i > 40) subj += 8.0 * 0.033
            val x = 0.5 + (subj - cam) / 40.0
            hist.addLast(t to x)
            var seen: Double? = null
            while (hist.isNotEmpty() && hist.first().first <= t - 300) seen = hist.removeFirst().second
            val d = loop.update(seen?.let { SubjectBox(it - 0.04, 0.3, 0.08, 0.3) }, t)
            drive = d.pan
            sb.append("t=%4d true=%.3f seen=%s drive=%.3f %s\n".format(t, (x - 0.5) / 0.5, seen?.let { "%.3f".format((it - 0.5) / 0.5) } ?: "  -  ", drive, loop.debug))
        }
        System.err.println(sb)
    }
}

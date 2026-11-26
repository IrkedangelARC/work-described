//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

package com.example.arc.xair

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

/**
 * ARC XAIR — the Behringer X AIR show-floor surface, on its own.
 *
 * Split out of ARC PTZ QUAD on 2026-09-08 when the QUAD's AUDIO domain
 * became the ATEM's Fairlight mixer. Same client, same page, same
 * confidence strip; nothing here was redesigned. What the QUAD used to
 * supply is read from `~/.arc-xair.properties`:
 *
 *     audio.host=192.0.2.31        the desk (static on the flypack segment)
 *     audio.show=1,2,3,4              the show mics on the strip (else named channels, else 1-4)
 *     audio.ch1.atemInput=1           mic -> switcher input, for the ON AIR marker
 *     quad.url=http://127.0.0.1:8765  a running ARC PTZ QUAD, whose /atem/state gives the program tally
 *     quad.token=<its concert.token>
 *
 * Without `quad.url` the strip still runs; it just never says ON AIR.
 *
 *     java -cp arc-xair.jar com.example.arc.xair.MainKt
 */
fun main() = application {
    val host = Config.get("audio.host") ?: DEFAULT_HOST
    val audio = remember { XAirClient(host) { Log.log("[XAIR] $it") }.also(XAirClient::start) }
    remember { QuadTally.start() }
    Log.log("ARC XAIR start: desk $host, quad ${Config.get("quad.url") ?: "none"}")
    Window(
        onCloseRequest = { audio.stop(); exitApplication() },
        title = "ARC XAIR · $host",
        state = rememberWindowState(width = 1560.dp, height = 720.dp),
    ) {
        val pgm by QuadTally.program.collectAsState()
        Column(Modifier.fillMaxSize().background(AppGrey)) {
            Spacer(Modifier.height(8.dp))
            AudioConfidenceStrip(audio, pgm, emptyList()) { }
            Spacer(Modifier.height(6.dp))
            Box(Modifier.fillMaxWidth().padding(bottom = 6.dp)) { AudioPage(audio) }
        }
    }
}

const val DEFAULT_HOST = "192.0.2.31"

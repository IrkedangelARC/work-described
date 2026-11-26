//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import org.jetbrains.compose.desktop.application.dsl.TargetFormat

/**
 * ARC XAIR — Behringer X AIR show-floor surface. Split out of ARC PTZ QUAD
 * on 2026-09-08 (its AUDIO domain is now the ATEM's Fairlight). Same
 * toolchain versions as arc-ptz so the two stay buildable side by side.
 */
plugins {
    kotlin("jvm") version "2.3.20"
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20"
    id("org.jetbrains.compose") version "1.12.0"
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(compose.desktop.currentOs)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.10.2")
    testImplementation("junit:junit:4.13.2")
}

compose.desktop {
    application {
        mainClass = "com.example.arc.xair.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg)
            packageName = "ARC XAIR"
            packageVersion = "1.0.0"
            vendor = "ARC Event Productions"
            macOS {
                bundleID = "com.example.arc.xair"
                dockName = "ARC XAIR"
            }
        }
    }
}

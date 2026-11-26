//
//  Copyright (c) 2025-2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

/**
 * Release signing.
 *
 * The keystore lives OUTSIDE the repo at ~/.arc-signing/ and its password is in
 * the macOS login keychain, so neither is ever in a file this project tracks.
 * Resolution order:
 *   1. ARC_SIGNAL_KEYSTORE_PASSWORD in the environment, for CI or a headless run
 *   2. the login keychain, for an ordinary build on the operator's Mac
 * If neither resolves, the release build is left UNSIGNED rather than silently
 * falling back to the debug key, which would produce an artefact that installs
 * fine and then refuses every future update.
 */
val arcKeystore = File(System.getProperty("user.home"), ".arc-signing/arc-signal-release.jks")

/**
 * Resolved with providers.* so it is configuration-cache compatible. A plain
 * ProcessBuilder here fails the build outright under Gradle 9: external
 * processes at configuration time are unsupported.
 */
fun arcKeystorePassword(): String? {
    providers.environmentVariable("ARC_SIGNAL_KEYSTORE_PASSWORD").orNull
        ?.takeIf { it.isNotBlank() }?.let { return it }
    val exec = providers.exec {
        commandLine("security", "find-generic-password", "-a", "arc-signal", "-s", "ARC-Signal-Keystore", "-w")
        isIgnoreExitValue = true
    }
    // Missing keychain entry must not fail the build; it leaves the APK unsigned.
    if (exec.result.get().exitValue != 0) return null
    return exec.standardOutput.asText.get().trim().takeIf { it.isNotEmpty() }
}

plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.compose.compiler)
  alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.example.arc.signal"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.example.arc.signal"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }

    signingConfigs {
        create("release") {
            val pw = arcKeystorePassword()
            if (arcKeystore.exists() && pw != null) {
                storeFile = arcKeystore
                storePassword = pw
                keyAlias = "arc-signal"
                keyPassword = pw
                // minSdk is 33, so v1 JAR signing is dead weight. v3 is what
                // allows the signing key to be rotated later without orphaning
                // every install; without it a lost key means a new package name.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            val cfg = signingConfigs.getByName("release")
            signingConfig = if (cfg.storeFile != null) cfg else null
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
      compose = true
      aidl = false
      buildConfig = false
      shaders = false
    }

    packaging {
      resources {
        excludes += "/META-INF/{AL2.0,LGPL2.1}"
      }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
  val composeBom = platform(libs.androidx.compose.bom)
  implementation(composeBom)
  androidTestImplementation(composeBom)

  // Core Android dependencies
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.lifecycle.runtime.ktx)
  implementation(libs.androidx.activity.compose)

  // Arch Components
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.viewmodel.compose)

  // Compose
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.compose.material3)
  // Tooling
  debugImplementation(libs.androidx.compose.ui.tooling)
  // Instrumented tests
  androidTestImplementation(libs.androidx.compose.ui.test.junit4)
  debugImplementation(libs.androidx.compose.ui.test.manifest)

  // Local tests: jUnit, coroutines, Android runner
  testImplementation(libs.junit)
  testImplementation(libs.kotlinx.coroutines.test)

  // Instrumented tests: jUnit rules and runners
  androidTestImplementation(libs.androidx.test.core)
  androidTestImplementation(libs.androidx.test.ext.junit)
  androidTestImplementation(libs.androidx.test.runner)
  androidTestImplementation(libs.androidx.test.espresso.core)
}

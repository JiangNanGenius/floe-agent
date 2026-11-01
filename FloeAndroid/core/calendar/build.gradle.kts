// SPDX-License-Identifier: MPL-2.0
plugins { alias(libs.plugins.android.library) }

// C06 Android system-calendar provider access. This module owns only the real
// CalendarContract projection/write rules and the provider client. It does not
// own UI, scheduling, notifications, credentials or the Swift bridge. Every
// write requires an explicit writable calendar and is verified by an actual
// provider read-back; the App host decides when permission has been granted.
android {
    namespace = "com.floe.android.core.calendar"
    compileSdk = 37
    defaultConfig { minSdk = 28 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    testImplementation(libs.junit)
}

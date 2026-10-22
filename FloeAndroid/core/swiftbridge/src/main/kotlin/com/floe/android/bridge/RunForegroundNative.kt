// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Private native lifecycle readback; contains counts/epoch only. */
object RunForegroundNative {
    init { System.loadLibrary("floe_jni") }
    external fun snapshot(): String?
    external fun waitChange(after: Long, timeoutMillis: Int): Long
}

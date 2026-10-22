// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted runtime-component composition only; never a model-facing tool. */
object LinuxAuthorityNative {
    init {
        System.loadLibrary("FloeAndroidLinuxAuthority")
        System.loadLibrary("floe_linux_authority_jni")
    }
    external fun exchange(request: String): String
}

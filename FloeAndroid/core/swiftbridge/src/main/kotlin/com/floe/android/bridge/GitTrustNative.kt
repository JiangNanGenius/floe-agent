// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted Application ingress only. No generic bridge command or tool. */
object GitTrustNative {
    init { System.loadLibrary("floe_jni") }
    external fun install(epoch: Long, record: ByteArray): Int
    external fun retire(epoch: Long): Int
}

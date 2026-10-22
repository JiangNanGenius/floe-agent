// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

object JobsNative {
    init { System.loadLibrary("floe_jni") }
    /** 1 actual processor drain, 0 still owned, negative unavailable. */
    external fun drain(timeoutMillis: Int): Int
    external fun cancelJob(epoch: Long, jobID: String): Int
}

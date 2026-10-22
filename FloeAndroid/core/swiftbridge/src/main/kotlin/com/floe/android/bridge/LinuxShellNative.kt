// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Private owned host transport, never a model-facing command or a durable job store. */
object LinuxShellNative {
    init { System.loadLibrary("floe_jni") }
    external fun bindEpoch(epoch: Long): Int
    external fun fenceEpoch(epoch: Long): Int
    external fun suspendAdmission(epoch: Long): Int
    external fun drain(timeoutMillis: Int): Int
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    external fun payload(claim: Long): ByteArray?
    external fun isLive(claim: Long): Int
    external fun shouldStop(claim: Long): Int
    external fun complete(claim: Long, status: Int, value: ByteArray): Int
    external fun close(): Int
}

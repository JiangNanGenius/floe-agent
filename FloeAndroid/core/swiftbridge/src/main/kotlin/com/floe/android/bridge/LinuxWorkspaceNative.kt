// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Core-only scoped file authority; no path, credential or model command ingress. */
object LinuxWorkspaceNative {
    init { System.loadLibrary("floe_jni") }
    external fun binding(epoch: Long, runID: String, grantID: String): ByteArray?
    external fun bindingForCall(epoch: Long, runID: String, toolCallID: String, grantID: String): ByteArray?
    external fun bindingForOperation(epoch: Long, operationID: String, runID: String, grantID: String): ByteArray?
    external fun openSession(binding: ByteArray): ByteArray?
    external fun baselineBegin(sessionKey: String): ByteArray?
    external fun baselineHeader(sessionKey: String, index: Long): ByteArray?
    /** New owned descriptor. Caller must adopt/close it exactly once. */
    external fun baselineOpenData(sessionKey: String, index: Long): Int
    external fun baselineFinish(sessionKey: String, count: Long, bytes: Long): ByteArray?
    external fun exportBegin(sessionKey: String): ByteArray?
    /** Caller retains ownership of dataFd throughout this synchronous call. */
    external fun exportStage(sessionKey: String, header: ByteArray, dataFd: Int): ByteArray?
    external fun exportFinish(sessionKey: String): ByteArray?
    external fun abort(sessionKey: String, reason: String): ByteArray?
    external fun closeSession(sessionKey: String): Int
    external fun stats(): ByteArray?
    external fun sweep(nowSeconds: Long, graceSeconds: Long): ByteArray?
}

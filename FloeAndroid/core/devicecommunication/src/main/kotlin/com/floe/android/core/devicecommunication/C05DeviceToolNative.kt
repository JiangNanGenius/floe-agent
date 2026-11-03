// SPDX-License-Identifier: MPL-2.0
//
// JNI transport for the trusted C05 device model-tool mailbox.
//
// The Swift side owns every ticket, ownership decision, request bound and
// cancellation check. This object only ferries bounded bytes/integers; it has
// no model routing, no V3 command and no permission request. It is loaded by
// the App-owned device pump, never by a UI screen directly.

package com.floe.android.core.devicecommunication

object C05DeviceToolNative {
    init {
        System.loadLibrary("floe_jni")
    }

    /**
     * @return 0 on success; negative typed refusal from the Swift mailbox.
     */
    external fun bind(epoch: Long): Int

    external fun next(timeoutMillis: Int): Long

    external fun describe(claim: Long): ByteArray?

    external fun payload(claim: Long): ByteArray?

    external fun isLive(claim: Long): Int

    external fun shouldStop(claim: Long): Int

    external fun complete(claim: Long, status: Int, value: ByteArray?): Int

    external fun close(epoch: Long): Int

    external fun stats(): ByteArray?

    external fun readiness(): ByteArray?
}

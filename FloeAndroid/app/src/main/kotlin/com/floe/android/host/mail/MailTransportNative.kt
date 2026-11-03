// SPDX-License-Identifier: MPL-2.0
//
// JNI declarations for the C06 Swift-owned mail transport mailbox. This file
// is the ONLY place that loads the shared native library for mail; the
// production Application must touch it only from an off-main IO coroutine.
// No protocol byte, credential or server name is logged by this layer.

package com.floe.android.bridge

class MailTransportNativeException(val status: Int) :
    IllegalStateException("mail_transport_status_$status")

object MailTransportNative {
    init { System.loadLibrary("floe_jni") }

    /** Bind the mailbox to the exact accepted Root epoch. 0 = accepted. */
    external fun bind(epoch: Long): Int
    /** Report the App lane live for this epoch. 0 = accepted. */
    external fun laneReady(epoch: Long): Int
    /** Claim one ticket. 0 = timeout, -1 = mailbox closed. */
    external fun next(timeoutMillis: Int): Long
    /** Fill [buffer] with the ticket's UTF-8 JSON descriptor; returns bytes. */
    external fun describe(claim: Long, buffer: ByteArray): Int
    /** Copy the write payload into [buffer]; returns bytes copied. */
    external fun takeWrite(claim: Long, buffer: ByteArray): Int
    /** Settle exactly once. [data] is the read result, null otherwise. */
    external fun complete(claim: Long, status: Int, data: ByteArray?, length: Int): Int
    /** 1 when the session/mailbox has been cancelled or closed. */
    external fun shouldStop(claim: Long): Int
    external fun cancelSession(session: Long): Int
    external fun closeAll(timeoutMillis: Int): Int
    external fun laneClosed(epoch: Long): Int
    /** Debug/qualification counters only; no host, credential or content. */
    external fun stats(buffer: ByteArray): Int
}

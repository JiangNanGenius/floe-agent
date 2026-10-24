// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted App transport for the embedded terminal + LSP domain
 * (job-dda32d23d55e4460). Closed action grammar, bounded frames, epoch
 * fences. Not a model-facing command: no V3 key, no tool, no permission
 * flag, no host path. Raw PTY output rides [payload]; document text rides
 * the separate <=4 MiB raw channel with a byteCount+sha256 proof. */
object TerminalNative {
    init { System.loadLibrary("floe_jni") }
    external fun bindEpoch(epoch: Long): Int
    external fun submitAction(descriptor: ByteArray, payload: ByteArray?): Long
    external fun next(timeoutMillis: Int): Long
    external fun describe(event: Long): ByteArray?
    external fun payload(event: Long): ByteArray?
    external fun ack(event: Long): Int
    external fun close(epoch: Long): Int
    external fun stats(): ByteArray?
}

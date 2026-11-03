// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Trusted App transport for the G09-R2 media foundation authority/root-drain
 * lane (job-aa95dd9b26044ded). Declarations only — NO business logic lives
 * here.
 *
 * This is NOT a V3 command and NOT a model tool. It exposes the plain host
 * authority proofs and the aggregate Root-drain accounting the App adapter
 * needs for the platform media factory:
 *   prepare / verify(renderBinding|probeRoot|ticket) / retainBinding /
 *   releasePin / resolveRoot / status / rootStop / drainPending
 *
 * Every decision (bound epoch/root, lease record+file, owner/revision/digest,
 * claimed ticket identity, stable project owner proof) lives in
 * FloeAndroidCore/G09R2. Kotlin only marshals bounded JSON.
 *
 * Bounds: prepare/verify requests <= 16 KiB, status <= 4 KiB, replies <= 64
 * KiB; a too-small native buffer is refused, never truncated.
 */
object MediaFoundationNative {
    init { System.loadLibrary("floe_jni") }

    /** 0 = exact generation drained (safe to free Root); 1 = owned work
     * remains (imports/render claims/pins); negative = fenced/refused. */
    external fun rootStop(epoch: Long): Int

    /** Owned import/render/pin count for the exact generation (0 = drained). */
    external fun drainPending(epoch: Long): Int

    /** Bound-generation status JSON `{ok,epoch,live,baseRootPath?}`. */
    external fun status(epoch: Long): ByteArray?

    /** One bounded authority proof. [action] is one of `renderBinding`,
     * `probeRoot`, `ticket`, `retainBinding`, `releasePin`, `resolveRoot`.
     * Replies are bounded JSON objects; `ok:false` carries a typed error. */
    external fun verify(epoch: Long, action: String, request: ByteArray): ByteArray?

    /** Resolves the native canonical digest + immutable snapshot lease for
     * BOTH image and video projects in one call. Reply = a frozen
     * `G09R2MediaExportBindingDTO` object or a typed failure object. */
    external fun prepare(epoch: Long, request: ByteArray): ByteArray?
}

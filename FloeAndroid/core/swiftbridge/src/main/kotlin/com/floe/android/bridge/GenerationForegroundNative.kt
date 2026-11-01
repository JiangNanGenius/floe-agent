// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Private trusted-host bridge for G09-R2 cloud-generation foreground
 * ownership. All authority lives in FloeAndroidCore/G09R2; this object only
 * forwards the exact captured durable job UUID, generation epoch, project UUID
 * and opaque host token. It is not a V3 command, not a model tool and exposes
 * no root/path/credential.
 *
 * The App host calls [register] only after its non-exported `dataSync` service
 * reported a real `startForeground` success. A denied start must call [deny]
 * and no paid provider request is dispatched.
 */
object GenerationForegroundNative {
    init { System.loadLibrary("floe_jni") }

    /** 0 success, -101 invalid arguments, -102 stale/foreign job/epoch,
     * -103 lease table full. */
    external fun register(
        jobID: String,
        epoch: Long,
        projectID: String,
        token: String,
    ): Int

    /** Definite local admission denial (startDenied/notificationsBlocked). */
    external fun deny(jobID: String, epoch: Long, reason: String): Int

    /** Release the exact host lease; -107 when the token does not own it. */
    external fun release(jobID: String, epoch: Long, token: String): Int

    /** Request cancellation of the exact leased native job. */
    external fun cancel(jobID: String, epoch: Long, token: String): Int

    /** One bounded background pump step for the exact leased video job. */
    external fun poll(jobID: String, epoch: Long, token: String): Int

    /** `state=...;terminal=0/1;progress=...;task=...;epoch=...` or null. */
    external fun snapshot(jobID: String, epoch: Long, token: String): String?

    /** Leases still held for one generation (Root-drain diagnostics). */
    external fun count(epoch: Long): Int

    /** Host-confirmed release after the real service/notification stopped. */
    external fun releaseAll(epoch: Long): Int
}

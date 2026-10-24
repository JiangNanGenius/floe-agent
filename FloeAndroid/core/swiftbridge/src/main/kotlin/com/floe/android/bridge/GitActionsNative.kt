// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted Application lifecycle ingress for the durable GitHub Actions
 * engine ONLY (mirrors [GitTrustNative]'s discipline). There is no payload,
 * path or credential crossing this seam: it forwards the REAL scene identity
 * plus the foreground flag so the original engine scene rules can start the
 * bounded local poller with the first active scene and pause it when the last
 * one leaves. Pausing never claims the remote run stopped. All Actions DATA
 * rides the existing closed workspace.read/workspace.write grammar. */
object GitActionsNative {
    init { System.loadLibrary("floe_jni") }

    /** 0 = delivered to the live generation; -501 = no live root for this
     * epoch; -105 = malformed/oversized scene identity. */
    external fun scene(epoch: Long, active: Boolean, sceneID: String): Int
}

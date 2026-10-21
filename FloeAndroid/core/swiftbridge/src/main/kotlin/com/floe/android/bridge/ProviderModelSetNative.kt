// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * External declarations only (no logic) for the TRUSTED-HOST provider
 * MODEL-SET staging seam (large profiles). Loads the same libfloe_jni the
 * other bridge loaders pin (JVM loadLibrary is idempotent per class loader).
 *
 * This is NOT a bridge command and NOT reachable from the model/tool wire:
 * no command name, no payload vocabulary, no permission. The provider
 * editor freezes its complete selected-model body here in bounded,
 * ORDERED, IDEMPOTENT JSON chunks (the ORIGINAL closed ModelProfile
 * shapes) bound to its own live `rt:v1:` editor route plus the ACTUAL
 * provider id / base revision / create intent, seals it into an immutable
 * canonical set, and the save candidate then carries ONLY the small frozen
 * reference `ms:v1:<32hex>.<64hex>` (mutually exclusive with inline
 * selectedModels). The frozen 16,384-byte candidate/frame budgets and the
 * 512-model bound are UNCHANGED; chunk bytes ride the same bounded binary
 * JNI class as the vault secret ingress (max 61,440 per chunk — the
 * proven single-model `config.model.save` payload class), never the public
 * JSON ingress. Nothing here reads or writes any secret, and native
 * refuses stale/foreign/expired/tampered references before any effect.
 *
 * Statuses returned by the Int-result calls (0 = accepted; negative typed
 * refusals, mirroring ProviderModelSetStatus on the native side):
 *   -105 invalidArgument   -110 invalidChunk      -112 saturated
 *   -113 orderViolation    -114 countMismatch     -115 sealedStateViolation
 *   -116 chunkTooLarge     -117 stageUnavailable  -119 digestMismatch
 *   -120 bindingDivergence
 */
object ProviderModelSetNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Freeze a new stage bound to the caller's LIVE editor route. Returns
     * the canonical `msb:v1:<32hex>` stage id, or null when native refused
     * pre-mutation (retired route / invalid binding / saturation).
     */
    external fun beginModelSet(
        providerID: String,
        baseResourceID: String,
        baseVersion: String,
        createIntent: Boolean,
        routeToken: String,
    ): String?

    /** Ordered idempotent chunk append; 0 accepted, negative typed refusal. */
    external fun appendModelSetChunk(
        stageID: String,
        routeToken: String,
        index: Int,
        chunk: ByteArray,
    ): Int

    /**
     * Seal the stage into the immutable set with the exact total row count
     * and receive the frozen reference `ms:v1:<32hex>.<64hex>` the
     * candidate may carry. Null when native refused.
     */
    external fun sealModelSet(
        stageID: String,
        routeToken: String,
        expectedCount: Int,
    ): String?

    /** Exact-owner cancel of this editor's un-consumed stage; 0 or typed. */
    external fun cancelModelSet(stageID: String, routeToken: String): Int
}

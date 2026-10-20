// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * External declarations only (no logic) for the TRUSTED security-corpus
 * handoff. The class initializer is the ONE place this seam loads
 * libfloe_jni (the same library object the gateway/runtime/staging loaders
 * already pin; JVM loadLibrary is idempotent per class loader).
 *
 * This is NOT a bridge command and NOT reachable from the model/tool wire:
 * the App bootstrap reads the packaged, trusted
 * `security/catastrophic-patterns.json` asset and freezes those bytes into
 * the native Root BEFORE requesting the Root start. The Swift side validates
 * with the ORIGINAL loader (pinned SHA-256, <=1 MiB, same Codable schema,
 * non-empty pattern list, same regex compile path); a missing/tampered/empty
 * corpus never freezes and ordinary runs keep their truthful `corpusAbsent`
 * refusal before any model/store effect.
 *
 * Status space (owned by `G02SecurityCorpusStatus` in Swift; additive to the
 * frozen runtime-owner -2xx and staging -3xx spaces):
 *   0 ok, 1 idempotent, -105 invalidArguments,
 *   -421 empty, -422 oversized, -423 invalid, -426 conflict.
 */
object SecurityCorpusNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Validate + freeze the trusted corpus bytes for the process Root.
     * Returns the typed status; the caller treats anything but 0/1 as
     * "not frozen" (fail closed) and never fabricates a gate.
     */
    external fun securityCorpusFreeze(bytes: ByteArray): Int
}

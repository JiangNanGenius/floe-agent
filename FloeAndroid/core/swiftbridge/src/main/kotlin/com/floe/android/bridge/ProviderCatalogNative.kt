// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * External declarations only (no logic) for the TRUSTED official
 * provider-catalog handoff. The class initializer loads libfloe_jni (the same
 * library object the other bridge loaders pin; JVM loadLibrary is idempotent
 * per class loader).
 *
 * This is NOT a bridge command and NOT reachable from the model/tool wire:
 * the App bootstrap reads the packaged, reviewed
 * `provider/ProviderCatalog.json` asset and freezes those bytes into the
 * native Root BEFORE requesting the Root start. The Swift side validates with
 * the ORIGINAL decoder (`ProviderCatalogIndex` via `ConfigCatalogValidator`:
 * 2 MiB document bound, schemaVersion/providers/source, per-entry Codable) and
 * freezes once per process; a missing/tampered/oversized/invalid document
 * never freezes and the ordinary provider domain keeps its truthful typed
 * `needsConfiguration(catalogNotInjected)` refusal. The App's documented
 * Custom compatible-endpoint path is unaffected.
 *
 * Status space (owned by `G02HostCatalogStatus` in Swift; additive to the
 * frozen runtime-owner -2xx, staging -3xx and corpus -4xx spaces):
 *   0 ok, 1 idempotent, -105 invalidArguments,
 *   -431 empty, -432 oversized, -433 invalid, -436 conflict.
 */
object ProviderCatalogNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Validate + freeze the trusted official catalog bytes for the process
     * Root. Returns the typed status; the caller treats anything but 0/1 as
     * "not injected" (honest typed refusal later) and never fabricates a
     * catalog.
     */
    external fun providerCatalogFreeze(bytes: ByteArray): Int
}

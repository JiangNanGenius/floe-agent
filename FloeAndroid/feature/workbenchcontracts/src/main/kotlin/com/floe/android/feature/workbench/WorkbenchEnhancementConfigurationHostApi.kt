// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * Frozen App-supplied port for the super-resolution backend configuration
 * (job-418174da5d0c4a52; staged transactional credential mutation
 * job-c35cda51f6a94aa9; root-owned vault binding + immutable rotation
 * job-7951fc7bca9946bc; ONE sealed secure ingress save
 * job-e5e786c723244725).
 *
 * The feature module never persists the configuration and never sees the
 * credential bytes outside the save call arguments: the native side owns the
 * typed row in the original SettingsStore and owns the credential metadata
 * in the original vault (a root-owned `credential.<uuid>` record). When a
 * key is supplied, the App host routes the WHOLE credential exchange through
 * the ONE ORIGINAL sealed secure ingress — the same native route authority
 * and one-shot vault slot the provider/MCP/web-search editors use: it opens
 * the dedicated closed `enhancer` editor route, freezes the closed
 * `enhancerSave` intent core plus the key bytes into one bounded native
 * slot, and the native save consumes that lease to perform the single
 * original vault capture and commits the row pointing at the NEW immutable
 * owned reference LAST (previous credential retired through the original
 * vault delete) — a failed save leaves the previous configuration and
 * credential byte-identical, and an unknown/failed reply after an actual
 * native commit NEVER deletes the live key (the UI re-reads the
 * configuration instead of resubmitting key writes). The App host never
 * writes or deletes a credential directly. The whole exchange is pinned to
 * the epoch the configuration was loaded under. No ProviderProfile is
 * created: the enhancer backend must never appear as a general
 * video-generation provider.
 */
interface WorkbenchEnhancementConfigurationHostApi {
    /** Secret-free projection of the stored configuration. */
    suspend fun getConfiguration(): EnhancementBackendConfiguration

    /**
     * Opaque credential reference for [credentialAccount] (secret-free).
     * Pure derivation compatibility/read helper only: the bytes never cross
     * the bridge, and the reference grants no ownership.
     */
    suspend fun credentialReference(credentialAccount: String): String

    /**
     * Saves the configuration. When [apiKey] is non-null the App host first
     * opens the dedicated closed `enhancer` editor route and submits the key
     * bytes through the ONE sealed native secure ingress; the native save
     * consumes that one-shot lease to capture the credential inside the
     * runtime-owned mutation lifetime and persists the secret-free typed row
     * LAST — a failed save leaves the previous configuration and credential
     * byte-identical and the unreferenced new credential is durably retired
     * by the native restart drain. A null [apiKey] keeps the existing
     * credential (display-name-only edit). [credentialAccount] is advisory
     * only; the native side binds the sealed ingress or the current owned
     * row, never this raw value. The key travels only as this RAM argument —
     * never through JSON, logs, saved state or the wire payload.
     */
    suspend fun saveConfiguration(
        displayName: String?,
        endpointID: String,
        credentialAccount: String,
        apiKey: String?,
    ): EnhancementBackendConfiguration

    /**
     * Revokes the configuration and retires the credential reference through
     * the original vault delete. The native side reports an incomplete
     * cleanup truthfully (the durable queue row and the settings row stay
     * intact); the call only returns successfully when the retirement is
     * durably completed or already claimed by the native drain.
     */
    suspend fun clearConfiguration(): EnhancementBackendConfiguration
}

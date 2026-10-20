// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — minimal native-to-App readiness adapter.
//
// Authority (job-7cd349b4cd6d4b55): "Deliver the minimal real status
// snapshot/registry readback and Kotlin adapter linking existing
// RuntimeBootstrapCapability/RuntimeHost.onDomainAvailability using actual
// available native bridge functions." and MAIN_TEMP_ACK_NATIVE_EPOCH_
// DECISION_20261019 ("Production composition job7cd source adapter").
//
// This file is an ADDITIVE App delta candidate (fbd originals immutable).
// It consumes the narrow trusted-host native readback
// `floe_g02_domain_readiness` (per-domain state + missing dependencies, no
// root path/token) and publishes each domain through the EXISTING
// `RuntimeHost.onDomainAvailability(domain, available, missing)` seam —
// no new public wire command, no optimistic source/port-presence flag.
//
// The App wiring (small additive host delta, see app-deltas) constructs one
// adapter next to RuntimeHost, polls it after every bootstrap status
// refresh and on `OwnedStoreReady`, and stops it at `Stopped`.
package com.floe.android.host

import org.json.JSONObject

/**
 * Maps the REAL native domain-readiness snapshot onto the existing
 * [RuntimeHost.onDomainAvailability] seam.
 *
 * @param host the existing Application-owned host.
 * @param readReadiness narrow native readback; null/invalid -> no publish
 *        (never manufacture readiness).
 * @param readRootEpoch narrow native root-epoch readback; used to version
 *        every publish so a stale generation can never admit callbacks.
 */
internal class G02DomainReadinessAdapter(
    private val host: RuntimeHost,
    private val readReadiness: () -> String?,
    private val readRootEpoch: () -> Long,
) {
    private val lock = Any()
    private var publishedEpoch: Long = -1L
    private var publishedStates = HashMap<String, String>()

    /** Re-reads the native snapshot and publishes CHANGED domains only. */
    fun pollAndPublish() {
        val raw = readReadiness() ?: return
        val rootEpoch = readRootEpoch()
        if (rootEpoch <= 0) return
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val epoch = json.optLong("epoch", -1L)
        if (epoch <= 0) return
        val domains = json.optJSONArray("domains") ?: return
        val secureSubjects = mutableListOf<String>()
        json.optJSONArray("secureIngressSubjects")?.let { array ->
            for (s in 0 until array.length()) {
                array.optString(s)?.takeIf { it.isNotBlank() }?.let(secureSubjects::add)
            }
        }
        val updates = ArrayList<Triple<String, Boolean, List<String>>>()
        synchronized(lock) {
            if (epoch != publishedEpoch) {
                // Generation change: re-publish every domain so a rebind can
                // never inherit a stale Available/Blocked state.
                publishedStates.clear()
                publishedEpoch = epoch
            }
            for (index in 0 until domains.length()) {
                val entry = domains.optJSONObject(index) ?: continue
                val domain = entry.optString("domain")
                val state = entry.optString("state")
                if (domain.isBlank() || state.isBlank()) continue
                if (publishedStates[domain] == state) continue
                publishedStates[domain] = state
                val missing = mutableListOf<String>()
                entry.optJSONArray("missing")?.let { array ->
                    for (m in 0 until array.length()) {
                        array.optString(m)?.takeIf { it.isNotBlank() }?.let(missing::add)
                    }
                }
                updates.add(Triple(domain, state == "ready", missing))
            }
        }
        for ((domain, available, missing) in updates) {
            host.onDomainAvailability(domain, available, missing)
        }
        // Web-search capabilities follow the SAME truthful readback: the
        // secure subject binds only when the compiled native vocabulary
        // actually contains `webSearchSave` (the model-physical/websearch
        // successor), and get/save bind only over the REAL bound config
        // handler keys. A ready->blocked transition rebinds false.
        val configEntry = domains.let { list ->
            (0 until list.length())
                .mapNotNull { list.optJSONObject(it) }
                .firstOrNull { it.optString("domain") == "providerConfigurationDomain" }
        }
        if (configEntry != null &&
            (publishedStates["providerConfigurationDomain"] != null)
        ) {
            val keys = configEntry.optJSONArray("handlerKeys")
                ?.let { array -> (0 until array.length()).map { array.optString(it) } }
                .orEmpty()
            val configReady = configEntry.optString("state") == "ready"
            host.webSearch.bindHandlerCapability(
                get = configReady &&
                    keys.contains("v3.command.applicationConfiguration.config.websearch.get"),
                save = configReady &&
                    keys.contains("v3.command.applicationConfiguration.config.websearch.save"),
            )
            host.webSearch.bindSecureSaveCapability(
                "webSearchSave",
                configReady && secureSubjects.contains("webSearchSave"),
            )
        }
    }

    fun reset() {
        synchronized(lock) {
            publishedEpoch = -1L
            publishedStates.clear()
        }
    }
}

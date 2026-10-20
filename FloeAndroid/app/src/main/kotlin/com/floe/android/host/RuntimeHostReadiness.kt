// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

/**
 * Typed host readiness — three SEPARATE facts, never one bool:
 *
 *  * gateway — the product-UID credential gateway lifecycle (Loading/Ready/
 *    Failed) owned by [com.floe.android.SecretGatewayDispatcher];
 *  * store — the RB-1 owned original store bootstrap (Idle → OwnedStoreReady)
 *    owned by [com.floe.android.RuntimeBootstrapCoordinator];
 *  * domains — the individual business domains the App host binds
 *    (providerConfiguration, conversation, run, temporary, skillsMcp,
 *    settings.*, attachments). A domain is [DomainAvailable] only when the
 *    real native handler is registered for the CURRENT App instance and the
 *    generation matches; it is NEVER fabricated from source presence.
 *
 * Readiness policy (G02 binding rules):
 *  * Provider/model configuration and first-provider setup are admitted once
 *    the STORE is ready and the configuration domain handler exists — there
 *    is deliberately no circular requirement that "ordinary AI" be ready
 *    before the user can configure the first provider.
 *  * Run launch requires a real, usable selected model from the provider
 *    projection (truthful provider-configured check), not a synthetic flag.
 *  * Temporary chat requires the temporary domain plus the public-web tool
 *    ceiling from capability.tools.list.
 */
data class RuntimeHostReadiness(
    val gateway: GatewayReadiness = GatewayReadiness.Loading,
    val store: StoreReadiness = StoreReadiness.Idle,
    val domains: Map<String, DomainReadiness> = emptyMap(),
) {
    val storeReady: Boolean get() = store is StoreReadiness.OwnedStoreReady

    fun domainAvailable(name: String): Boolean =
        domains[name] is DomainReadiness.Available

    /** Provider configuration admission — store-level, not AI-ready-gated. */
    val providerConfigurationAdmitted: Boolean
        get() = storeReady && domainAvailable("providerConfigurationDomain")

    val conversationDomainAdmitted: Boolean
        get() = storeReady && domainAvailable("conversationDomain")

    val runDomainAdmitted: Boolean
        get() = storeReady && domainAvailable("runDomain")

    val temporaryDomainAdmitted: Boolean
        get() = storeReady && domainAvailable("temporaryDomain")

    val skillsMcpDomainAdmitted: Boolean
        get() = storeReady && domainAvailable("skillsMcpDiscovery")

    val attachmentStagingAdmitted: Boolean
        get() = storeReady && domainAvailable("hostAttachmentStaging")

    /**
     * Individual settings-domain admission, derived from the REAL native
     * readiness keys (G02DomainKey: settingsDefaults / settingsMemory /
     * settingsPersonalization / settingsUsage / settingsPrivacy — the
     * closed vocabulary carries NO dotted prefix). Mapped here to the
     * domain labels the settings controllers gate on; never fabricated.
     */
    val settingsDomainsAdmitted: Set<String>
        get() = domains.filterValues { it is DomainReadiness.Available }
            .keys.mapNotNull { nativeKey ->
                when (nativeKey) {
                    "settingsDefaults" -> "settings.defaults"
                    "settingsMemory" -> "settings.memory"
                    "settingsPersonalization" -> "settings.personalization"
                    "settingsUsage" -> "settings.usage"
                    "settingsPrivacy" -> "settings.privacy"
                    else -> null
                }
            }.toSet()

    sealed interface GatewayReadiness {
        data object Loading : GatewayReadiness
        data object Ready : GatewayReadiness
        data class Failed(val reason: String) : GatewayReadiness
    }

    sealed interface StoreReadiness {
        data object Idle : StoreReadiness
        data object WaitingGateway : StoreReadiness
        data class Starting(val receipt: String) : StoreReadiness
        data object OwnedStoreReady : StoreReadiness
        data class Failed(val reason: String) : StoreReadiness
        data object Stopped : StoreReadiness
    }

    sealed interface DomainReadiness {
        /** Truthful native readiness with registered required handlers. */
        data class Available(val generation: Long) : DomainReadiness

        /** Typed missing-bindings barrier; never advertised as ready. */
        data class Blocked(val missingBindings: List<String>) : DomainReadiness
    }
}

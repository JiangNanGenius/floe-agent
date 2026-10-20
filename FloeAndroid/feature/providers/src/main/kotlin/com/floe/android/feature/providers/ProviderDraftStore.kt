// SPDX-License-Identifier: MPL-2.0
//
// Caller-retained, RAM-only editor draft storage and the connection-identity
// rule. No SavedStateHandle, no Bundle, no rememberSaveable, no database, no
// settings file: a config-change recreation re-reads the SAME session object
// the host retained; process death restores nothing (and the credential text
// was never persisted anyway — the host re-seeds CONFIGURED/AWAITING state and
// the user re-enters a key when required).
//
// Honest boundary claims:
//  - Closing a slot DROPS ITS LAST REFERENCE to the typed secret. This is
//    reference release, NOT a claim of zeroization: Kotlin Strings are
//    immutable and un-zeroizable, so this module never claims bytes were
//    wiped (contract: no false zeroization claim).
//  - [ProviderDraftSlot.toString] masks everything credential-shaped so
//    accidental logging cannot leak the typed key.

package com.floe.android.feature.providers

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.net.URI

/**
 * ⇄ ProviderConfigurationValidation.ProviderConnectionIdentity.Key mirror for
 * the presentation-layer "connection changed" rule.
 *
 * Accepted steer `g02-source-secret-print-and-endpoint-epoch-fix`: this is a
 * DISPLAY COMPARISON ONLY and must not invent validation authority. It uses
 * the standard java.net.URI parser; unparseable input (including invalid or
 * overflowing ports) yields null = "unknown", and unknown never triggers a
 * secret clear. The original Swift backend revalidates the endpoint and
 * enforces credential compatibility at preflight — Kotlin does not.
 *
 * Identity fields mirror Swift: scheme + lowercase trailing-dot-stripped host
 * + port (explicit, else the scheme default) + provider routing family + auth
 * style. Same-host path/alias/query edits keep the same token (the key has no
 * path component), so a typed key survives them; scheme/host/port/family/auth
 * changes produce a new token.
 */
internal object ProviderConnectionIdentityToken {

    /** Returns the canonical display token, or null when the input is unknown. */
    fun key(routeFamily: String, authStyle: String, endpoint: String): String? {
        val trimmed = endpoint.trim()
        if (trimmed.isEmpty()) return null
        val uri = try {
            URI(trimmed)
        } catch (_: java.net.URISyntaxException) {
            return null
        } catch (_: IllegalArgumentException) {
            return null
        }
        val scheme = uri.scheme?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        val host = uri.host?.lowercase()?.trimEnd('.')?.takeIf { it.isNotEmpty() } ?: return null
        // java.net.URI already rejects overflowing/invalid ports at parse time.
        val port = if (uri.port >= 0) uri.port else defaultPort(scheme)
        return "$scheme://$host:$port/$routeFamily/$authStyle"
    }

    private fun defaultPort(scheme: String): Int = when (scheme) {
        "https" -> 443
        "http" -> 80
        else -> 0
    }
}

/** One open editor session: non-secret snapshot + RAM-only secret field. */
class ProviderDraftSlot internal constructor(val identity: ProviderEditorIdentity) {

    /** Editable snapshot of the non-secret form state (⇄ VM @Published fields). */
    val snapshot: MutableState<ProviderDraftSnapshot> =
        mutableStateOf(ProviderDraftSnapshot(role = identity.role))

    /**
     * The typed credential. Lives ONLY here while the editor is open; handed
     * verbatim to the host action that needs it (save / connection probe) and
     * dropped on [clearSecureInput]/close. Never part of [snapshot], so draft
     * copies and host payloads cannot carry it by accident.
     */
    val secureInput: MutableState<String?> = mutableStateOf(null)

    /** Local reveal toggle of the secure field (RAM-only UI state). */
    val revealSecureInput: MutableState<Boolean> = mutableStateOf(false)

    /** Search text of the nested panes is presentation-only; it survives
     * rotation with the slot but is never persisted. */
    val supplierQuery: MutableState<String> = mutableStateOf("")
    val modelSearchQuery: MutableState<String> = mutableStateOf("")

    /** True once a Save was dispatched for [identity] and no outcome has
     * arrived for this epoch. Duplicate-prevention gate (the host's own
     * in-flight projection is the authoritative second layer). Snapshot state
     * so the editor toolbar reacts (spinner → Save) when a failed attempt
     * releases the latch, instead of waiting for an unrelated projection. */
    var saveDispatched: Boolean by mutableStateOf(false)
        private set

    /** LAST VALID connection token (⇄ currentConnectionIdentity()). Null only
     * before any parseable endpoint was seen; typed edits keep the previous
     * valid value across unparseable intermediate input. */
    var connectionToken: String? = null
        private set

    val role: ProviderServiceRoleUi get() = snapshot.value.role

    fun update(transform: (ProviderDraftSnapshot) -> ProviderDraftSnapshot) {
        snapshot.value = transform(snapshot.value)
    }

    /**
     * Applies a supplier choice (preset or catalog entry) mirroring the iOS
     * ProviderSelectionFieldPolicy: the name is only replaced while it is
     * empty or equals the PREVIOUS supplier default (a typed custom name
     * survives switching suppliers/protocols); a connection-identity change
     * ALWAYS drops the typed secret and the reveal state — a stale key is
     * never silently reused on a new connection (contract).
     */
    fun applySupplierChoice(
        choice: SupplierChoice,
        newProtocol: WireProtocolUi,
        endpointOverride: String? = null,
    ) {
        val previous = snapshot.value
        val previousDefaultName = previous.supplier?.displayName
        val shouldReplaceName = previous.displayName.isBlank() ||
            (previousDefaultName != null && previous.displayName == previousDefaultName)
        val endpoint = endpointOverride ?: choice.absoluteEndpointDefault
        val newToken = ProviderConnectionIdentityToken.key(choice.routeFamily, choice.authStyle, endpoint)
        snapshot.value = previous.copy(
            supplier = choice,
            protocol = newProtocol,
            displayName = if (shouldReplaceName) choice.displayName else previous.displayName,
            baseUrl = endpoint,
            allowsPlainHttp = if (choice.supportsPlainHttpChoice) previous.allowsPlainHttp else false,
            toolNameCompatibility = previous.toolNameCompatibility || choice.suggestsToolNameCompatibility,
        )
        if (newToken != null) {
            if (connectionToken != null && newToken != connectionToken) {
                // Real connection boundary: typed key cannot move with it.
                clearSecureInput()
            }
            connectionToken = newToken
        }
    }

    /**
     * Endpoint field changed (user typing).
     *
     * Accepted steer fix: the previous implementation compared against the
     * last valid token but never committed the new one, so after A→B cleared
     * once, entering the B credential and editing the B path compared against
     * A again and wrongly cleared it. Now the last VALID identity is committed
     * after the comparison:
     *  - token unchanged (same scheme/host/port/family/auth, e.g. a path or
     *    alias edit) → nothing is cleared;
     *  - token changed (real boundary) → typed secret + reveal are released,
     *    then the new token becomes the current identity;
     *  - endpoint not parseable yet (invalid intermediate) → keep the last
     *    valid identity and clear nothing; the Swift backend validates later.
     */
    fun onEndpointEdited(newEndpoint: String) {
        val supplier = snapshot.value.supplier
        update { it.copy(baseUrl = newEndpoint) }
        if (supplier == null) return
        val token = ProviderConnectionIdentityToken.key(
            supplier.routeFamily,
            supplier.authStyle,
            newEndpoint,
        ) ?: return
        if (connectionToken != null && token != connectionToken) {
            if (!secureInput.value.isNullOrEmpty()) clearSecureInput()
        }
        connectionToken = token
    }

    fun setSecureInput(value: String?) {
        secureInput.value = value
    }

    fun clearSecureInput() {
        secureInput.value = null
        revealSecureInput.value = false
    }

    fun markSaveDispatched() {
        saveDispatched = true
    }

    fun resolveSaveDispatched() {
        saveDispatched = false
    }

    /** Sets the seed's connection token without touching other state. */
    internal fun seedConnectionToken() {
        val supplier = snapshot.value.supplier ?: return
        connectionToken = ProviderConnectionIdentityToken.key(
            supplier.routeFamily,
            supplier.authStyle,
            snapshot.value.baseUrl.ifBlank { supplier.absoluteEndpointDefault },
        )
    }

    /** Called on close/cancel: releases the secret reference (not wipe). */
    internal fun discard() {
        clearSecureInput()
    }

    override fun toString(): String =
        "ProviderDraftSlot(editorId=${identity.editorId}, epoch=${identity.epoch}, " +
            "secure=${if (secureInput.value.isNullOrEmpty()) "absent" else "<present:masked>"})"
}

/**
 * Registry of open editor slots keyed by editorId. The LATEST epoch wins:
 * opening an editor id whose slot has an older epoch replaces it, and the old
 * session's late results are rejected by [accepts].
 */
class ProviderDraftStore {

    private val slots = LinkedHashMap<String, ProviderDraftSlot>()

    val openCount: Int get() = slots.size

    fun open(identity: ProviderEditorIdentity, seed: ProviderEditorSeedUi): ProviderDraftSlot {
        val previous = slots.remove(identity.editorId)
        previous?.discard()
        val slot = ProviderDraftSlot(identity)
        slot.snapshot.value = seed.snapshot
        // Seeds NEVER place a stored secret into the field (honesty: the
        // credential store is not readable into UI).
        slot.seedConnectionToken()
        slots[identity.editorId] = slot
        return slot
    }

    fun slot(editorId: String): ProviderDraftSlot? = slots[editorId]

    /** True when [identity] is the CURRENT live session for its editorId. */
    fun accepts(identity: ProviderEditorIdentity): Boolean {
        val slot = slots[identity.editorId] ?: return false
        return slot.identity.epoch == identity.epoch
    }

    /** Close a session (cancel or after the host-confirmed success). */
    fun close(identity: ProviderEditorIdentity) {
        val slot = slots[identity.editorId] ?: return
        if (slot.identity.epoch == identity.epoch) {
            slot.discard()
            slots.remove(identity.editorId)
        }
    }

    /** Duplicate-save gate: dispatch only when neither the host nor this slot
     * has a save pending for the current epoch. */
    fun canDispatchSave(identity: ProviderEditorIdentity, hostInFlight: Boolean): Boolean {
        val slot = slots[identity.editorId] ?: return false
        if (slot.identity.epoch != identity.epoch) return false
        return !hostInFlight && !slot.saveDispatched
    }

    fun markSaveDispatched(identity: ProviderEditorIdentity) {
        slots[identity.editorId]?.takeIf { it.identity.epoch == identity.epoch }?.markSaveDispatched()
    }

    fun resolveSaveOutcome(identity: ProviderEditorIdentity) {
        slots[identity.editorId]?.takeIf { it.identity.epoch == identity.epoch }?.resolveSaveDispatched()
    }

    /** Drop everything (leaving settings): every slot releases its secret. */
    fun closeAll() {
        slots.values.forEach { it.discard() }
        slots.clear()
    }

    override fun toString(): String = "ProviderDraftStore(open=${slots.keys})"
}

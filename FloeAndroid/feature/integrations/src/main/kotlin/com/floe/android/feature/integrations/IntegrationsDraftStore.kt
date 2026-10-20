// SPDX-License-Identifier: MPL-2.0
//
// Caller-retained, RAM-only draft storage for the MCP editor (and the small
// transient skill forms). No SavedStateHandle, no Bundle, no rememberSaveable,
// no database, no settings file:
//  - the host retains the flow holder in RAM across configuration changes;
//  - process death restores NOTHING credential-related (the user re-enters a
//    key against the host's committed configuration);
//  - the typed secret lives ONLY in [McpEditorSlot.secureInput] and is passed
//    straight to the host save dispatch (never into the draft snapshot, never
//    into a result, never into any projection).
//
// Honest boundary claims (same contract the provider flow accepted):
//  - Closing a slot DROPS ITS LAST REFERENCE to the typed secret. This is
//    reference release, NOT a claim of zeroization: Kotlin Strings are
//    immutable and un-zeroizable, so this module never claims bytes were
//    wiped.
//  - [McpEditorSlot.toString] and [McpSaveRequest.toString] mask everything
//    credential-shaped so accidental logging cannot leak the typed key.

package com.floe.android.feature.integrations

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** One open MCP editor session: non-secret snapshot + RAM-only secret. */
class McpEditorSlot internal constructor(val identity: McpEditorIdentity) {

    /** ⇄ MCPServerEditor @State server: the editable NON-SECRET copy. */
    val snapshot: MutableState<McpDraftSnapshot> = mutableStateOf(McpDraftSnapshot())

    /** The seed the editor opened with (saved/wire identity + stored flags).
     * Kept so the credential intent can compare against the ORIGINAL origin
     * rather than the evolving text. */
    var seed: McpEditorSeedUi = McpEditorSeedUi(
        serverId = null,
        displayName = "",
        endpointText = "",
        enabled = true,
        allowInCanvas = false,
        allowInsecureHttp = false,
        authentication = McpAuthenticationUi.NONE,
        credentialHeaderName = "Authorization",
        credentialStored = false,
        timeoutSeconds = 30,
        transport = McpTransportUi.StreamableHttp,
        tools = emptyList(),
        networkActionsAvailable = false,
        networkActionsUnavailableReason = null,
    )
        private set

    /** Origin token captured at seed time (null = unparseable seed). */
    var seedOriginToken: String? = null
        private set

    /** LAST VALID origin token of the edited endpoint. Null while the typed
     * endpoint is unparseable; an unparseable intermediate never clears the
     * secret (provider-flow rule). */
    var currentOriginToken: String? = null
        private set

    /**
     * The typed credential. Lives ONLY here while the editor is open; handed
     * verbatim to the host save dispatch and dropped on origin change /
     * [clearSecureInput] / close. Never part of [snapshot].
     */
    val secureInput: MutableState<String?> = mutableStateOf(null)

    /** Local reveal toggle (RAM-only UI state). */
    val revealSecureInput: MutableState<Boolean> = mutableStateOf(false)

    /** True once a save was dispatched for this identity+epoch and no
     * outcome arrived. Duplicate-prevention latch; the host's own in-flight
     * projection is the authoritative second layer. */
    var saveDispatched: Boolean by mutableStateOf(false)
        private set

    /** Highest host Save-failure event already consumed for this session.
     * A repeated or older sequence is a projection poll, never a new attempt;
     * it must not release the latch of a later in-flight save. */
    var lastConsumedSaveFailureSequence: Long = 0L
        private set

    /** ⇄ revision observed at seed time; the save carries it as baseRevision
     * so a changed saved config is an explicit host-side conflict. */
    var baseRevision: Long? = null
        private set

    fun openWith(newSeed: McpEditorSeedUi, initial: McpDraftSnapshot) {
        seed = newSeed
        seedOriginToken = McpEndpointOrigin.parse(newSeed.endpointText)?.accountToken
        currentOriginToken = McpEndpointOrigin.parse(initial.endpointText)?.accountToken
        // ⇄ the saved row's revision (null for a NEW server): the save
        // carries it as baseRevision so the host can reject a blind overwrite
        // of a config that changed since the seed (explicit conflict).
        baseRevision = newSeed.savedRevision
        saveDispatched = false
        lastConsumedSaveFailureSequence = 0L
        snapshot.value = initial
    }

    fun update(transform: (McpDraftSnapshot) -> McpDraftSnapshot) {
        val before = snapshot.value
        val after = transform(before)
        snapshot.value = after
        if (after.endpointText != before.endpointText) {
            val parsed = McpEndpointOrigin.parse(after.endpointText)
            if (parsed != null) {
                val previousToken = currentOriginToken
                currentOriginToken = parsed.accountToken
                if (previousToken != null && previousToken != parsed.accountToken) {
                    // ⇄ credentialAccount binding: the stored secret belongs
                    // to the OLD origin. Drop the typed draft too — a stale
                    // key is never silently reused on a new destination.
                    secureInput.value = null
                    revealSecureInput.value = false
                }
            }
        }
        if (after.authentication != before.authentication) {
            // ⇄ upsert semantics: only a CURRENTLY typed secret may be
            // stored; reveal state follows the field.
            revealSecureInput.value = false
        }
    }

    fun setSecureInput(value: String?) {
        secureInput.value = value?.ifEmpty { null }
    }

    fun clearSecureInput() {
        secureInput.value = null
        revealSecureInput.value = false
    }

    /** The save dispatch payload; the secret is read HERE exactly once and
     * only travels with a SET intent. */
    fun buildSaveRequest(): McpSaveRequest {
        val draft = snapshot.value
        val intent = McpCredentialIntent.compute(
            draft = draft,
            typedSecret = secureInput.value,
            seed = seed,
            seedOriginToken = seedOriginToken,
            currentOriginToken = currentOriginToken,
        )
        return McpSaveRequest(
            identity = identity,
            serverId = seed.serverId,
            draft = draft,
            credentialIntent = intent,
            credentialDraft = if (intent == CredentialDraftIntent.SET) secureInput.value else null,
            baseRevision = baseRevision,
        )
    }

    fun markSaveDispatched() {
        saveDispatched = true
    }

    fun resolveSaveOutcome() {
        saveDispatched = false
    }

    /**
     * Consume one host Save-failure event for this editor session.
     *
     * Returns true only for a strictly NEW sequence; a repeated/older value
     * (recomposition, projection poll or a late replay) returns false and
     * leaves the current attempt's latch untouched. The event is recorded as
     * consumed even when no dispatch is latched, so it can never release a
     * LATER attempt. A consumed event releases the duplicate-save latch
     * because the host only publishes completed failures.
     */
    fun consumeSaveFailureEvent(failureSequence: Long): Boolean {
        if (failureSequence <= lastConsumedSaveFailureSequence) return false
        lastConsumedSaveFailureSequence = failureSequence
        resolveSaveOutcome()
        return true
    }

    /** Editor closed: throw the draft away (reference release only). */
    fun discard() {
        snapshot.value = McpDraftSnapshot()
        clearSecureInput()
        saveDispatched = false
        lastConsumedSaveFailureSequence = 0L
    }

    /** Redacted representation for accidental logging paths. */
    override fun toString(): String =
        "McpEditorSlot(editor=${identity.editorId}, epoch=${identity.epoch}, " +
            "name=${snapshot.value.displayName}, " +
            "credential=${if (secureInput.value.isNullOrEmpty()) "absent" else "<present:redacted>"})"
}

/**
 * RAM-only registry of open MCP editor slots keyed by editorId. Reopening an
 * editor creates a NEW editorId (monotonic open counter), so an outcome from
 * a previous open can never match — the same epoch-style fence the provider
 * flow uses ("rapid navigation/back/reopen and an old success cannot close
 * or update a newer editor").
 */
class McpEditorStore {

    private val slots = mutableMapOf<String, McpEditorSlot>()
    private var openCounter = 0L

    fun slot(editorId: String): McpEditorSlot? = slots[editorId]

    /** Opens a NEW editor session and returns its identity. */
    fun open(seed: McpEditorSeedUi, initialDraft: McpDraftSnapshot): McpEditorSlot {
        openCounter += 1
        val editorId = seed.serverId?.let { "$it-$openCounter" } ?: "new-$openCounter"
        val slot = McpEditorSlot(McpEditorIdentity(editorId = editorId, epoch = 1, serverId = seed.serverId))
        slot.openWith(seed, initialDraft)
        slots[editorId] = slot
        return slot
    }

    /**
     * Re-seed the SAME editor id with a fresh epoch (the host must hand a
     * different projection to an open editor, e.g. after an external cloud
     * change). Everything dispatched under older epochs is now stale.
     */
    fun reseed(identity: McpEditorIdentity, newSeed: McpEditorSeedUi, newDraft: McpDraftSnapshot): McpEditorIdentity {
        val next = identity.copy(epoch = identity.epoch + 1)
        slots.remove(identity.editorId)
        val slot = McpEditorSlot(next)
        slot.openWith(newSeed, newDraft)
        slots[next.editorId] = slot
        return next
    }

    /** True when [identity] is still the live session for its editor id. */
    fun accepts(identity: McpEditorIdentity): Boolean {
        val slot = slots[identity.editorId] ?: return false
        return slot.identity.isCurrentFor(identity)
    }

    fun canDispatchSave(identity: McpEditorIdentity, hostInFlight: Boolean): Boolean {
        val slot = slots[identity.editorId] ?: return false
        if (!slot.identity.isCurrentFor(identity)) return false
        return !slot.saveDispatched && !hostInFlight
    }

    fun close(identity: McpEditorIdentity) {
        slots[identity.editorId]?.takeIf { it.identity.sameEditor(identity) }?.discard()
        slots.remove(identity.editorId)
    }

    fun closeAll() {
        slots.values.forEach { it.discard() }
        slots.clear()
    }
}

/** One open transient skill form (creator / finder / folder import). */
class SkillFormSlot internal constructor(val formId: String, val pane: IntegrationsPane) {
    /** Creator fields (⇄ SkillCreatorSheet @State). */
    val creatorName: MutableState<String> = mutableStateOf("")
    val creatorDescription: MutableState<String> = mutableStateOf("")
    val creatorInstructions: MutableState<String> = mutableStateOf("")

    /** Finder fields (⇄ SkillFinderSheet @State url + rewriteModelID). */
    val finderUrl: MutableState<String> = mutableStateOf("")
    val finderModelId: MutableState<String?> = mutableStateOf(null)

    /** Folder import: only the opaque staged reference travels (no paths,
     * no binaries). */
    val stagedReference: MutableState<StagedPackageRefUi?> = mutableStateOf(null)

    /** Latch: a dispatch was accepted and no outcome arrived for this form. */
    var dispatchInFlight: Boolean by mutableStateOf(false)
        private set

    fun markDispatched() {
        dispatchInFlight = true
    }

    fun resolveOutcome() {
        dispatchInFlight = false
    }

    fun creatorDraft(): SkillCreatorDraftUi =
        SkillCreatorDraftUi(creatorName.value, creatorDescription.value, creatorInstructions.value)

    /** Redacted representation (staged reference prints metadata only). */
    override fun toString(): String = "SkillFormSlot(formId=$formId, pane=$pane)"
}

/** Registry for transient skill form slots, keyed by the module's form id. */
class SkillFormStore {
    private val slots = mutableMapOf<String, SkillFormSlot>()
    private var formCounter = 0L

    fun slot(formId: String): SkillFormSlot? = slots[formId]

    fun open(pane: IntegrationsPane): SkillFormSlot {
        formCounter += 1
        val id = "${pane.name.lowercase()}-$formCounter"
        return SkillFormSlot(id, pane).also { slots[id] = it }
    }

    fun close(formId: String) {
        slots.remove(formId)
    }

    fun closeAll() {
        slots.clear()
    }
}

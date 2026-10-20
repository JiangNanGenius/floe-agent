// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.bridge.SecretGatewayNative
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

private const val WEB_SEARCH_SAVE_SUBJECT_KIND = "webSearchSave"

/**
 * G02 web-search settings controller.
 *
 * Wire authority (frozen): `config.websearch.get` / `config.websearch.save`
 * under the existing `settings.websearch` configuration scope. The metadata
 * payload keeps the ORIGINAL `{configurations:[WebSearchProviderConfiguration]}`
 * shape. The Main secure-ingress decision adds ONE optional entry:
 *
 * ```
 * "credential": {
 *   "configurationID": "<exact config UUID>",
 *   "intent": "keep" | "set" | "clear",
 *   "saveIntentToken": "int:v1:..."   // set only
 * }
 * ```
 *
 * A SET is a single native `submitSaveIntent` call whose intent JSON freezes
 * `subject.kind = webSearchSave`, the exact UUID, the editor route/generation,
 * the base revision and the secret-free candidate. The value is the encoded
 * ORIGINAL `WebSearchCredential` JSON (`{"values":{...}}`). The token is an
 * opaque one-shot handle; the secret bytes are zeroed after the call. Neither
 * the credential values nor the encoded bytes ever enter a command, a
 * persisted state, a log or a diagnostic.
 *
 * The native `webSearchSave` subject + handler are ADDITIVE qualification
 * work owned by the model configuration qualifier. Until an authoritative
 * native readback binds that exact subject, [NativeCapability.secureSave] is
 * false: the full controller route and UI exist, but Set/Clear cannot
 * pretend a providerSave/mcpSave token would work.
 */
class WebSearchHostController internal constructor(
    private val host: RuntimeHost,
) {
    /** Exact native handler/ingress facts; never inferred from source presence. */
    data class NativeCapability(
        val getHandler: Boolean = false,
        val saveHandler: Boolean = false,
        val secureSubjectKind: String? = null,
    ) {
        val secureSave: Boolean
            get() = secureSubjectKind == WEB_SEARCH_SAVE_SUBJECT_KIND
    }

    enum class CredentialIntent(val raw: String) {
        KEEP("keep"),
        SET("set"),
        CLEAR("clear"),
    }

    /** One RAM editor draft; `credentialValues` is redacted from toString. */
    data class WebSearchEditorDraft(
        val id: String,
        val kind: WebSearchProviderKind,
        val displayName: String,
        val endpointText: String,
        val credentialAccount: String,
        val enabled: Boolean,
        val priorityText: String,
        val regionText: String,
        val options: Map<String, String>,
        val credentialValues: Map<String, String> = emptyMap(),
    ) {
        override fun toString(): String =
            "WebSearchEditorDraft(id=$id, kind=${kind.raw}, displayNameChars=${displayName.length}, " +
                "credentialFields=${credentialValues.size})"
    }

    data class WebSearchEditorState(
        val editorId: String,
        val routeToken: String,
        val routeGeneration: Long,
        val rootGeneration: Long,
        val configured: Boolean,
        val draft: WebSearchEditorDraft,
        val credentialIntent: CredentialIntent,
        val originalCredentialState: WebSearchCredentialState,
        val baseRevision: String,
        val saveInFlight: Boolean = false,
        val failure: String? = null,
        val failureSequence: Long = 0,
    ) {
        override fun toString(): String =
            "WebSearchEditorState(editorId=$editorId, intent=$credentialIntent, " +
                "saveInFlight=$saveInFlight, failure=$failure)"
    }

    data class WebSearchState(
        val configurations: List<WebSearchProviderConfiguration> = emptyList(),
        val rows: List<WebSearchProviderRow> = emptyList(),
        val credentialStates: Map<String, WebSearchCredentialState> = emptyMap(),
        val revision: String = "",
        val loading: Boolean = false,
        val loaded: Boolean = false,
        val error: String? = null,
        val native: NativeCapability = NativeCapability(),
        val listSaveInFlight: Boolean = false,
        val listSaveError: String? = null,
        val editor: WebSearchEditorState? = null,
        val lastSaved: Boolean = false,
    )

    /**
     * Typed one-shot ingress adapter; production is the frozen native host
     * seam (route-free intent CORE + this editor's own native route handle).
     */
    internal interface SaveIntentSubmitter {
        fun submit(
            intentCoreJson: String,
            routeToken: String,
            value: ByteArray,
        ): SaveIntentSubmission
    }

    internal sealed interface SaveIntentSubmission {
        data class Accepted(val token: String) : SaveIntentSubmission
        data class Rejected(val code: String) : SaveIntentSubmission
    }

    internal object NativeSaveIntentSubmitter : SaveIntentSubmitter {
        override fun submit(
            intentCoreJson: String,
            routeToken: String,
            value: ByteArray,
        ): SaveIntentSubmission = try {
            val token = SecretGatewayNative.submitHostSaveIntent(
                intentCoreJson, routeToken, value)
            if (token == null) SaveIntentSubmission.Rejected("intentRejected")
            else SaveIntentSubmission.Accepted(token)
        } catch (t: Throwable) {
            SaveIntentSubmission.Rejected("intentUnavailable")
        }
    }

    /** Test seam only; production never replaces this with a fake service. */
    internal var saveIntentSubmitter: SaveIntentSubmitter = NativeSaveIntentSubmitter

    /** Trusted native route authority (App-wide shared UI admission). */
    internal var routeAuthority: HostRouteAuthority = NativeHostRouteAuthority

    private val stateFlow = MutableStateFlow(WebSearchState())
    val state: StateFlow<WebSearchState> = stateFlow

    private val failureSequencer = SaveFailureSequencer()
    private val listSaveSource = AtomicLong(0)

    private data class FrozenEditorSave(
        val editorId: String,
        val routeToken: String,
        val routeGeneration: Long,
        val rootGeneration: Long,
        val baseRevision: String,
        val configuration: WebSearchProviderConfiguration,
        val configurations: List<WebSearchProviderConfiguration>,
        val credentialIntent: CredentialIntent,
        val credential: WebSearchCredential?,
        val intentJson: String?,
    ) {
        /** Written before command submission, read by its terminal callback. */
        @Volatile var saveIntentToken: String? = null
    }

    internal fun start() {
        if (host.readiness.value.storeReady) ensureLoaded()
    }

    internal fun stop() {
        forceCloseEditor()
        update { it.copy(loading = false) }
    }

    /** Load once; the page's Retry calls [refresh] explicitly. */
    fun ensureLoaded() {
        val current = stateFlow.value
        if (current.loaded || current.loading) return
        refresh()
    }

    fun refresh() {
        val current = stateFlow.value
        if (current.loading || current.listSaveInFlight || current.editor?.saveInFlight == true) return
        if (!host.readiness.value.storeReady) {
            update { it.copy(loading = false, error = "storeUnavailable") }
            return
        }
        // A refresh is NOT a save: never erase the previous save
        // acknowledgement here (a committed save whose immediate readback
        // failed still reports "saved, list not reloaded").
        update { it.copy(loading = true, error = null) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.websearch.get",
                scope = HostScope.ApplicationConfiguration("settings.websearch"),
                stateful = false,
                correlationID = host.commandClient.correlationID("wget"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val reply = decodeReply(outcome.value)
                    if (reply == null) {
                        update {
                            it.copy(
                                loading = false,
                                loaded = true,
                                error = "readbackUnavailable",
                                native = it.native.copy(getHandler = true),
                            )
                        }
                    } else {
                        applyReply(reply, getHandler = true)
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(loading = false, loaded = true, error = outcome.code)
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(loading = false, loaded = true, error = outcome.code)
                }
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded -> update {
                    it.copy(loading = false)
                }
            }
        }
    }

    /**
     * Bind the authoritative native readback. The subject kind must be the
     * exact additive `webSearchSave`; any other kind is ignored so a
     * providerSave/mcpSave token can never be re-labelled here.
     */
    fun bindSecureSaveCapability(subjectKind: String?, available: Boolean) {
        if (subjectKind != WEB_SEARCH_SAVE_SUBJECT_KIND) return
        update {
            it.copy(
                native = it.native.copy(
                    secureSubjectKind = if (available) WEB_SEARCH_SAVE_SUBJECT_KIND else null,
                ),
            )
        }
    }

    /** Bind the real get/save handler registry facts after qualification. */
    fun bindHandlerCapability(get: Boolean, save: Boolean) {
        update { it.copy(native = it.native.copy(getHandler = get, saveHandler = save)) }
    }

    /**
     * Explicit stale-revision recovery: reload the list WITHOUT discarding
     * the open draft, then adopt the fresh revision/credential presence if
     * the same configuration still exists. The user must still tap Save.
     */
    fun reloadEditorForRetry(): Boolean {
        val editor = stateFlow.value.editor ?: return false
        val state = stateFlow.value
        if (state.loading || state.listSaveInFlight || editor.saveInFlight) return false
        if (!host.readiness.value.storeReady) {
            failEditor("storeUnavailable")
            return false
        }
        update { it.copy(loading = true, listSaveError = null) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.websearch.get",
                scope = HostScope.ApplicationConfiguration("settings.websearch"),
                stateful = false,
                correlationID = host.commandClient.correlationID("wget"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val reply = decodeReply(outcome.value)
                    if (reply == null) {
                        update {
                            it.copy(
                                loading = false,
                                error = "readbackUnavailable",
                                native = it.native.copy(getHandler = true),
                            )
                        }
                        return@trackOperation
                    }
                    applyReply(reply, getHandler = true)
                    update { current ->
                        val active = current.editor
                        if (active == null ||
                            active.editorId != editor.editorId ||
                            active.routeToken != editor.routeToken
                        ) {
                            return@update current
                        }
                        val matching = reply.configurations.firstOrNull {
                            it.id == editor.editorId
                        }
                        if (matching == null) {
                            val sequence = failureSequencer.next(
                                active.editorId, active.routeGeneration)
                            current.copy(
                                editor = active.copy(
                                    failure = "configurationMissing",
                                    failureSequence = sequence,
                                ),
                            )
                        } else {
                            current.copy(
                                editor = active.copy(
                                    baseRevision = reply.revision,
                                    originalCredentialState =
                                        reply.credentialStates[editor.editorId]
                                            ?: active.originalCredentialState,
                                    failure = null,
                                ),
                            )
                        }
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(loading = false, error = outcome.code)
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(loading = false, error = outcome.code)
                }
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded -> update {
                    it.copy(loading = false)
                }
            }
        }
        return true
    }

    // ---------------------------------------------------------------- editor

    fun openEditor(configurationId: String): Boolean {
        val row = stateFlow.value.rows.firstOrNull {
            it.configuration.id == configurationId
        } ?: return false
        return openEditorFor(row.configuration, row.credentialState, row.configured)
    }

    fun openNewCustomProvider(): Boolean {
        val id = UUID.randomUUID().toString()
        val priority = (stateFlow.value.rows.maxOfOrNull {
            it.configuration.priority
        } ?: -1) + 1
        val configuration = WebSearchProviderConfiguration(
            id = id,
            kind = WebSearchProviderKind.CUSTOM,
            displayName = WebSearchProviderPresets.displayName(WebSearchProviderKind.CUSTOM),
            endpoint = null,
            credentialAccount = "web-search.custom.$id",
            enabled = false,
            priority = priority,
        )
        return openEditorFor(
            configuration = configuration,
            credentialState = WebSearchCredentialState.SECRET_MISSING,
            configured = false,
        )
    }

    private fun openEditorFor(
        configuration: WebSearchProviderConfiguration,
        credentialState: WebSearchCredentialState,
        configured: Boolean,
    ): Boolean {
        if (stateFlow.value.listSaveInFlight || stateFlow.value.editor?.saveInFlight == true) {
            return false
        }
        // ONE shared UI incarnation for this editor creation (monotonic
        // across provider/MCP/web-search), plus the ACTUAL accepted native
        // Root epoch captured now. The native admission refuses a stale
        // Root or an older/foreign UI incarnation instead of minting here.
        val routeGeneration = HostUiAdmission.nextGeneration()
        val nativeEpoch = host.nativeRootEpoch()
        val routeToken = if (nativeEpoch != null) {
            routeAuthority.open(
                HostEditorKind.WEB_SEARCH, configuration.id, routeGeneration, nativeEpoch)
        } else {
            null
        }.orEmpty()
        val intent = defaultIntent(configuration.kind, credentialState)
        val editor = WebSearchEditorState(
            editorId = configuration.id,
            routeToken = routeToken,
            routeGeneration = routeGeneration,
            rootGeneration = host.commandClient.generation(),
            configured = configured,
            draft = WebSearchEditorDraft(
                id = configuration.id,
                kind = configuration.kind,
                displayName = configuration.displayName,
                endpointText = configuration.endpoint ?: "",
                credentialAccount = configuration.credentialAccount,
                enabled = configuration.enabled,
                priorityText = configuration.priority.toString(),
                regionText = configuration.region ?: "",
                options = configuration.options,
            ),
            credentialIntent = intent,
            originalCredentialState = credentialState,
            baseRevision = stateFlow.value.revision,
        )
        update { it.copy(editor = editor, lastSaved = false) }
        return true
    }

    fun closeEditor() {
        val editor = stateFlow.value.editor ?: return
        // A save owns the one-shot ingress until its terminal. Canceling the
        // sheet here would hide (not undo) a committed write and could leave
        // transient fields behind without an owner.
        if (editor.saveInFlight) return
        failureSequencer.reset(editor.editorId, editor.routeGeneration)
        clearEditorRoute(editor)
        update { it.copy(editor = null) }
    }

    /** Exact-ownership native close; a stale handle never clears a newer route. */
    private fun clearEditorRoute(editor: WebSearchEditorState) {
        if (isOpaqueHostRouteToken(editor.routeToken)) {
            routeAuthority.clear(editor.routeToken)
        }
    }

    private fun forceCloseEditor() {
        val editor = stateFlow.value.editor ?: return
        failureSequencer.reset(editor.editorId, editor.routeGeneration)
        clearEditorRoute(editor)
        update { it.copy(editor = null) }
    }

    /**
     * Called from the editor sheet's disposal. Only the owning editor is
     * closed; a rotated/replaced sheet for a newer route never clears it.
     */
    fun disposeEditorIfOwned(editorId: String, routeToken: String) {
        val current = stateFlow.value.editor ?: return
        if (current.editorId == editorId && current.routeToken == routeToken) {
            closeEditor()
        }
    }

    fun updateDisplayName(value: String) = updateDraft { it.copy(displayName = value) }

    fun updateEndpoint(value: String) = updateDraft { it.copy(endpointText = value) }

    fun updatePriority(value: String) = updateDraft { it.copy(priorityText = value) }

    fun updateRegion(value: String) = updateDraft { it.copy(regionText = value) }

    fun updateEnabled(value: Boolean) = updateDraft { it.copy(enabled = value) }

    fun updateSummaryEnabled(value: Boolean) = updateDraft {
        it.copy(options = it.options + ("summaryEnabled" to value.toString()))
    }

    fun updateCredential(field: WebSearchCredentialField, value: String) = updateDraft {
        if (it.credentialValues[field.key] == value) it
        else it.copy(credentialValues = it.credentialValues + (field.key to value))
    }

    fun setCredentialIntent(intent: CredentialIntent) {
        val current = stateFlow.value.editor ?: return
        if (current.saveInFlight || current.credentialIntent == intent) return
        // Moving away from Set wipes the transient RAM fields immediately.
        update { state ->
            val editor = state.editor ?: return@update state
            if (editor.editorId != current.editorId || editor.routeToken != current.routeToken) {
                return@update state
            }
            state.copy(
                editor = editor.copy(
                    credentialIntent = intent,
                    failure = null,
                    draft = editor.draft.copy(credentialValues = emptyMap()),
                ),
            )
        }
    }

    private inline fun updateDraft(
        transform: (WebSearchEditorDraft) -> WebSearchEditorDraft,
    ) {
        update { state ->
            val editor = state.editor ?: return@update state
            if (editor.saveInFlight) return@update state
            state.copy(editor = editor.copy(draft = transform(editor.draft), failure = null))
        }
    }

    // -------------------------------------------------------------- list save

    /**
     * Persist one enabled toggle. This is the legacy metadata-only save (no
     * `credential` entry), which explicitly means Keep existing secrets.
     */
    fun setEnabled(configurationId: String, enabled: Boolean): Boolean {
        val current = stateFlow.value
        if (current.listSaveInFlight || current.editor?.saveInFlight == true) return false
        if (!host.readiness.value.storeReady) {
            update { it.copy(listSaveError = "storeUnavailable") }
            return false
        }
        val configuration = current.configurations.firstOrNull { it.id == configurationId }
            ?: current.rows.firstOrNull { it.configuration.id == configurationId }?.configuration
            ?: return false
        if (current.revision.isBlank()) {
            update { it.copy(listSaveError = "revisionUnavailable") }
            return false
        }
        val updated = configuration.copy(enabled = enabled)
        val configurations = replaceConfiguration(current.configurations, updated)
        if (configurations.size > MAX_PROVIDERS) {
            update { it.copy(listSaveError = "providerLimit") }
            return false
        }
        val previous = current
        val generation = listSaveSource.incrementAndGet()
        update {
            it.copy(
                configurations = configurations,
                rows = buildRows(configurations, it.credentialStates),
                listSaveInFlight = true,
                listSaveError = null,
                lastSaved = false,
            )
        }
        val request = HostCommandRequest(
            command = "config.websearch.save",
            scope = HostScope.ApplicationConfiguration("settings.websearch"),
            stateful = true,
            correlationID = host.commandClient.correlationID("wsave"),
            revision = HostRevision("settings.websearch", current.revision),
            payload = savePayload(configurations, credential = null),
        )
        host.trackOperation(request) { outcome ->
            if (listSaveSource.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val reply = decodeReply(outcome.value)
                    if (reply == null) {
                        // The save itself COMMITTED (the terminal accepted);
                        // only the refreshed list could not be read. Report
                        // both facts honestly ("saved, but the updated list
                        // could not be loaded").
                        update {
                            it.copy(
                                listSaveInFlight = false,
                                lastSaved = true,
                                listSaveError = "readbackUnavailable",
                                revision = "",
                                native = it.native.copy(saveHandler = true),
                            )
                        }
                        refresh()
                    } else {
                        applyReply(reply, saveHandler = true)
                        update { it.copy(listSaveInFlight = false, lastSaved = true) }
                    }
                }
                is HostOperationOutcome.Rejected ->
                    restoreListSave(previous, outcome.code)
                is HostOperationOutcome.Failed ->
                    restoreListSave(previous, outcome.code)
                HostOperationOutcome.Cancelled, HostOperationOutcome.Superseded ->
                    restoreListSave(previous, "cancelled")
            }
        }
        return true
    }

    private fun restoreListSave(previous: WebSearchState, code: String) {
        update { current ->
            previous.copy(
                listSaveInFlight = false,
                listSaveError = code,
                // Never drop an editor that a later tap opened while this
                // terminal was settling.
                editor = current.editor ?: previous.editor,
            )
        }
    }

    // ------------------------------------------------------------- editor save

    /**
     * Save the current editor. Returns false when the tap was not admitted
     * (already in flight, missing revision, validation failure); a true
     * return means one actual submit was launched.
     */
    fun saveEditor(): Boolean {
        val state = stateFlow.value
        val editor = state.editor ?: return false
        if (editor.saveInFlight || state.listSaveInFlight || state.loading) return false
        if (host.commandClient.generation() != editor.rootGeneration) {
            failEditor("generationChanged")
            return false
        }
        if (editor.baseRevision.isBlank()) {
            failEditor("revisionUnavailable")
            return false
        }
        val frozen = freezeSave(editor) ?: return false
        failureSequencer.reset(editor.editorId, editor.routeGeneration)
        update { current ->
            val active = current.editor ?: return@update current
            if (active.editorId != frozen.editorId || active.routeToken != frozen.routeToken) {
                return@update current
            }
            current.copy(editor = active.copy(saveInFlight = true, failure = null))
        }
        host.scope.launch(host.ioDispatcher) {
            var token: String? = null
            if (frozen.credentialIntent == CredentialIntent.SET) {
                val credential = frozen.credential
                val intentJson = frozen.intentJson
                if (credential == null || intentJson == null) {
                    failEditorIfCurrent(frozen, "credentialFieldsRequired")
                    return@launch
                }
                val bytes = credential.encoded()
                if (bytes.size > MAX_CREDENTIAL_BYTES) {
                    bytes.fill(0)
                    failEditorIfCurrent(frozen, "credentialTooLarge")
                    return@launch
                }
                val routeToken = frozen.routeToken
                if (!isOpaqueHostRouteToken(routeToken)) {
                    bytes.fill(0)
                    failEditorIfCurrent(frozen, "secureSaveUnavailable")
                    return@launch
                }
                try {
                    when (val submission = saveIntentSubmitter.submit(
                        intentJson, routeToken, bytes)) {
                        is SaveIntentSubmission.Rejected -> {
                            failEditorIfCurrent(frozen, submission.code)
                            return@launch
                        }
                        is SaveIntentSubmission.Accepted -> {
                            if (!isOpaqueSaveIntentToken(submission.token)) {
                                failEditorIfCurrent(frozen, "intentTokenInvalid")
                                return@launch
                            }
                            token = submission.token
                            frozen.saveIntentToken = submission.token
                        }
                    }
                } catch (t: Throwable) {
                    failEditorIfCurrent(frozen, "intentUnavailable")
                    return@launch
                } finally {
                    bytes.fill(0)
                }
            }
            if (host.commandClient.generation() != frozen.rootGeneration) {
                discardSaveIntentToken(frozen.saveIntentToken)
                failEditorIfCurrent(frozen, "generationChanged")
                return@launch
            }
            val credentialEntry = when (frozen.credentialIntent) {
                CredentialIntent.KEEP -> null
                CredentialIntent.SET -> JsonObject(
                    mapOf(
                        "configurationID" to JsonPrimitive(frozen.configuration.id),
                        "intent" to JsonPrimitive(CredentialIntent.SET.raw),
                        "saveIntentToken" to JsonPrimitive(token ?: ""),
                    ),
                )
                CredentialIntent.CLEAR -> JsonObject(
                    mapOf(
                        "configurationID" to JsonPrimitive(frozen.configuration.id),
                        "intent" to JsonPrimitive(CredentialIntent.CLEAR.raw),
                    ),
                )
            }
            val request = HostCommandRequest(
                command = "config.websearch.save",
                scope = HostScope.ApplicationConfiguration("settings.websearch"),
                stateful = true,
                correlationID = host.commandClient.correlationID("wsave"),
                revision = HostRevision("settings.websearch", frozen.baseRevision),
                payload = savePayload(frozen.configurations, credentialEntry),
            )
            host.trackOperation(request) { outcome -> settleEditor(frozen, outcome) }
        }
        return true
    }

    private fun freezeSave(editor: WebSearchEditorState): FrozenEditorSave? {
        val draft = editor.draft
        if (!isCanonicalUUID(draft.id)) {
            failEditor("invalidConfigurationID")
            return null
        }
        val displayName = draft.displayName.trim()
        if (displayName.isEmpty()) {
            failEditor("displayNameRequired")
            return null
        }
        if (displayName.toByteArray(Charsets.UTF_8).size > 256) {
            failEditor("displayNameTooLong")
            return null
        }
        val endpoint = normalizeWebSearchEndpoint(draft.endpointText).getOrElse {
            failEditor("endpointInvalid")
            return null
        }
        if (draft.kind.requiresEndpoint && endpoint == null) {
            failEditor("endpointRequired")
            return null
        }
        val priority = draft.priorityText.trim().toIntOrNull()
        if (priority == null || priority < 0) {
            failEditor("priorityInvalid")
            return null
        }
        val region = draft.regionText.trim().ifEmpty { null }
        if (region != null && region.toByteArray(Charsets.UTF_8).size > 128) {
            failEditor("regionTooLong")
            return null
        }
        if (!webSearchOptionsCarryNoSecrets(draft.options)) {
            failEditor("optionsNotAllowed")
            return null
        }
        val configuration = WebSearchProviderConfiguration(
            id = draft.id,
            kind = draft.kind,
            displayName = displayName,
            endpoint = endpoint,
            credentialAccount = draft.credentialAccount,
            enabled = draft.enabled,
            priority = priority,
            region = region,
            options = draft.options,
        )
        val configurations = replaceConfiguration(stateFlow.value.configurations, configuration)
        if (configurations.size > MAX_PROVIDERS) {
            failEditor("providerLimit")
            return null
        }
        if (configurations.groupBy { it.id }.any { it.value.size > 1 }) {
            failEditor("duplicateConfigurationID")
            return null
        }
        if (configurations.groupBy { it.credentialAccount }.any { it.value.size > 1 }) {
            failEditor("duplicateCredentialAccount")
            return null
        }
        if (editor.credentialIntent == CredentialIntent.CLEAR &&
            !stateFlow.value.native.secureSave
        ) {
            failEditor("secureSaveUnavailable")
            return null
        }
        val credential = when (editor.credentialIntent) {
            CredentialIntent.KEEP -> null
            CredentialIntent.CLEAR -> null
            CredentialIntent.SET -> {
                if (!stateFlow.value.native.secureSave) {
                    failEditor("secureSaveUnavailable")
                    return null
                }
                val candidate = WebSearchCredential.forKind(draft.kind, draft.credentialValues)
                if (!candidate.satisfies(draft.kind)) {
                    failEditor("credentialFieldsRequired")
                    return null
                }
                candidate
            }
        }
        val intentJson = if (editor.credentialIntent == CredentialIntent.SET && credential != null) {
            buildSetIntentJson(
                configuration = configuration,
                editor = editor,
                baseRevision = editor.baseRevision,
            )?.also { json ->
                if (json.toByteArray(Charsets.UTF_8).size > MAX_INTENT_BYTES) {
                    failEditor("intentTooLarge")
                    return null
                }
            } ?: return null
        } else {
            null
        }
        return FrozenEditorSave(
            editorId = editor.editorId,
            routeToken = editor.routeToken,
            routeGeneration = editor.routeGeneration,
            rootGeneration = editor.rootGeneration,
            baseRevision = editor.baseRevision,
            configuration = configuration,
            configurations = configurations,
            credentialIntent = editor.credentialIntent,
            credential = credential,
            intentJson = intentJson,
        )
    }

    private fun settleEditor(frozen: FrozenEditorSave, outcome: HostOperationOutcome) {
        if (host.commandClient.generation() != frozen.rootGeneration) {
            discardSaveIntentToken(frozen.saveIntentToken)
            failEditorIfCurrent(frozen, "generationChanged")
            return
        }
        when (outcome) {
            is HostOperationOutcome.Completed -> {
                discardSaveIntentToken(frozen.saveIntentToken)
                val reply = decodeReply(outcome.value)
                val current = stateFlow.value.editor
                val owns = current != null &&
                    current.editorId == frozen.editorId &&
                    current.routeToken == frozen.routeToken
                if (!owns) return
                failureSequencer.reset(frozen.editorId, frozen.routeGeneration)
                if (reply == null) {
                    // The command completed: the save may have committed even
                    // though the readback did not decode. Close the secret
                    // surface, invalidate the old revision and reconcile.
                    update {
                        it.copy(
                            editor = null,
                            lastSaved = true,
                            revision = "",
                            error = "readbackUnavailable",
                            native = it.native.copy(saveHandler = true),
                        )
                    }
                    refresh()
                } else {
                    applyReply(reply, saveHandler = true)
                    update {
                        it.copy(
                            editor = null,
                            listSaveInFlight = false,
                            lastSaved = true,
                            error = null,
                        )
                    }
                }
            }
            is HostOperationOutcome.Rejected -> {
                discardSaveIntentToken(frozen.saveIntentToken)
                failFrozenEditor(frozen, outcome.code)
            }
            is HostOperationOutcome.Failed -> {
                discardSaveIntentToken(frozen.saveIntentToken)
                failFrozenEditor(frozen, outcome.code)
            }
            HostOperationOutcome.Cancelled -> {
                discardSaveIntentToken(frozen.saveIntentToken)
                failFrozenEditor(frozen, "cancelled")
            }
            HostOperationOutcome.Superseded -> {
                discardSaveIntentToken(frozen.saveIntentToken)
                failFrozenEditor(frozen, "superseded")
            }
        }
    }

    private fun failFrozenEditor(frozen: FrozenEditorSave, code: String) {
        update { state ->
            val editor = state.editor ?: return@update state
            if (editor.editorId != frozen.editorId || editor.routeToken != frozen.routeToken) {
                return@update state
            }
            val sequence = failureSequencer.next(editor.editorId, editor.routeGeneration)
            state.copy(
                editor = editor.copy(
                    saveInFlight = false,
                    failure = code,
                    failureSequence = sequence,
                ),
                listSaveError = if (code == "readbackUnavailable") code else state.listSaveError,
            )
        }
    }

    private fun failEditorIfCurrent(frozen: FrozenEditorSave, code: String) {
        failFrozenEditor(frozen, code)
    }

    private fun failEditor(code: String) {
        update { state ->
            val editor = state.editor ?: return@update state
            val sequence = failureSequencer.next(editor.editorId, editor.routeGeneration)
            state.copy(
                editor = editor.copy(
                    saveInFlight = false,
                    failure = code,
                    failureSequence = sequence,
                ),
            )
        }
    }

    // ---------------------------------------------------------------- payload

    private fun savePayload(
        configurations: List<WebSearchProviderConfiguration>,
        credential: JsonObject?,
    ): JsonObject {
        val members = linkedMapOf<String, JsonElement>(
            "configurations" to JsonArray(configurations.map { it.toJson() }),
        )
        credential?.let { members["credential"] = it }
        return JsonObject(members)
    }

    private fun buildSetIntentJson(
        configuration: WebSearchProviderConfiguration,
        editor: WebSearchEditorState,
        baseRevision: String,
    ): String? {
        if (baseRevision.isBlank()) {
            failEditor("revisionUnavailable")
            return null
        }
        // Route authority is NATIVE: the intent core carries only the closed
        // subject/intent/baseRevision/candidate fields and the trusted native
        // seam injects the live route pair under its own admission lock.
        val root = linkedMapOf<String, JsonElement>(
            "subject" to JsonObject(
                mapOf(
                    "kind" to JsonPrimitive(WEB_SEARCH_SAVE_SUBJECT_KIND),
                    "id" to JsonPrimitive(configuration.id),
                ),
            ),
            "intent" to JsonPrimitive("set"),
            "baseRevision" to JsonObject(
                mapOf(
                    "resourceID" to JsonPrimitive("settings.websearch"),
                    "version" to JsonPrimitive(baseRevision),
                ),
            ),
            "candidate" to configuration.toJson(),
        )
        return JsonObject(root).toString()
    }

    // ---------------------------------------------------------------- replies

    private data class Reply(
        val configurations: List<WebSearchProviderConfiguration>,
        val credentialStates: Map<String, WebSearchCredentialState>,
        val revision: String,
    )

    private fun decodeReply(element: JsonElement?): Reply? {
        val root = unwrapReply(element) ?: return null
        val revisionObject = root["revision"] as? JsonObject ?: return null
        if (revisionObject.stringStrict("resourceID") != "settings.websearch") return null
        val revision = revisionObject.stringStrict("version") ?: return null
        if (revision.isBlank()) return null
        val providers = root["providers"] as? JsonArray ?: return null
        val configurations = ArrayList<WebSearchProviderConfiguration>(providers.size)
        val states = LinkedHashMap<String, WebSearchCredentialState>()
        for (item in providers) {
            val obj = item as? JsonObject ?: return null
            val configuration = WebSearchProviderConfiguration.fromJson(obj) ?: return null
            configurations += configuration
            states[configuration.id] =
                WebSearchCredentialState.fromRaw(obj.stringStrict("credential"))
        }
        return Reply(
            configurations = normalizeWebSearchConfigurations(configurations),
            credentialStates = states,
            revision = revision,
        )
    }

    private fun unwrapReply(element: JsonElement?): JsonObject? {
        val root = element as? JsonObject ?: return null
        val nested = (root["value"] as? JsonObject) ?: (root["page"] as? JsonObject)
        if (nested != null && (nested.containsKey("revision") || nested.containsKey("providers"))) {
            return nested
        }
        return root
    }

    private fun applyReply(reply: Reply, getHandler: Boolean = false, saveHandler: Boolean = false) {
        update { state ->
            state.copy(
                configurations = reply.configurations,
                credentialStates = reply.credentialStates,
                rows = buildRows(reply.configurations, reply.credentialStates),
                revision = reply.revision,
                loading = false,
                loaded = true,
                error = null,
                lastSaved = state.lastSaved,
                native = state.native.copy(
                    getHandler = state.native.getHandler || getHandler,
                    saveHandler = state.native.saveHandler || saveHandler,
                ),
            )
        }
    }

    private fun buildRows(
        configurations: List<WebSearchProviderConfiguration>,
        credentialStates: Map<String, WebSearchCredentialState>,
    ): List<WebSearchProviderRow> {
        val configuredKinds = configurations.map { it.kind }.toSet()
        val rows = ArrayList<WebSearchProviderRow>(configurations.size + WebSearchProviderPresets.kinds.size)
        configurations.forEach { configuration ->
            rows += WebSearchProviderRow(
                configuration = configuration,
                credentialState = credentialStates[configuration.id]
                    ?: defaultCredentialState(configuration.kind),
                configured = true,
            )
        }
        WebSearchProviderPresets.kinds.forEachIndexed { index, kind ->
            if (kind !in configuredKinds) {
                rows += WebSearchProviderRow(
                    configuration = WebSearchProviderPresets.configuration(kind, index),
                    credentialState = defaultCredentialState(kind),
                    configured = false,
                )
            }
        }
        return rows.sortedWith(
            compareBy<WebSearchProviderRow>(
                { it.configuration.priority },
                { it.configuration.displayName.lowercase() },
                { it.configuration.id },
            ),
        )
    }

    private fun defaultCredentialState(kind: WebSearchProviderKind): WebSearchCredentialState =
        if (kind.requiresCredential) {
            WebSearchCredentialState.SECRET_MISSING
        } else {
            WebSearchCredentialState.NO_CREDENTIAL_REQUIRED
        }

    private fun defaultIntent(
        kind: WebSearchProviderKind,
        state: WebSearchCredentialState,
    ): CredentialIntent {
        if (!kind.requiresCredential) return CredentialIntent.KEEP
        return when (state) {
            WebSearchCredentialState.SECRET_MISSING,
            WebSearchCredentialState.SECRET_INVALIDATED,
            -> CredentialIntent.SET
            else -> CredentialIntent.KEEP
        }
    }

    private fun replaceConfiguration(
        source: List<WebSearchProviderConfiguration>,
        updated: WebSearchProviderConfiguration,
    ): List<WebSearchProviderConfiguration> =
        normalizeWebSearchConfigurations(
            source.filter { it.id != updated.id } + updated,
        )

    /**
     * Best-effort cleanup of an UNCONSUMED native ingress token after a
     * failed/rejected/unknown save. A consumed token returns typed and is
     * ignored; no secret/candidate is ever read here. Fake/tests skip native.
     */
    private fun discardSaveIntentToken(token: String?) {
        if (token == null) return
        if (saveIntentSubmitter !== NativeSaveIntentSubmitter) return
        try {
            SecretGatewayNative.discardSaveIntent(token)
        } catch (t: Throwable) {
            // The one-shot LIVE slot still expires natively; no UI secret.
        }
    }

    private fun isOpaqueSaveIntentToken(token: String): Boolean {
        if (token.length != 39 || !token.startsWith("int:v1:")) return false
        return token.substring(7).all { it in '0'..'9' || it in 'a'..'f' }
    }

    private inline fun update(transform: (WebSearchState) -> WebSearchState) {
        stateFlow.update(transform)
    }

    private companion object {
        const val MAX_PROVIDERS = 32
        const val MAX_INTENT_BYTES = 16_384
        const val MAX_CREDENTIAL_BYTES = 65_536
    }
}

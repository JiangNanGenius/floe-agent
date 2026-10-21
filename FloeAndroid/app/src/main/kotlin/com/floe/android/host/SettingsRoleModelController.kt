// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.settings.ModelRolePolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * R4 — the FULL original model-role preferences surface.
 *
 * The persisted document is the original `ModelSelectionPreferences`
 * (FloeCore ModelSelectionPreferences.swift:11-137): eleven role slots,
 * the shared/separate media mode, the autonomous-image-routing flag and
 * the server-owned `syncRevision`. This controller reads and writes that
 * document WHOLE under its real revision CAS — every untouched field
 * (including `onboardingStatus` and any future field the strict native
 * decoder accepts) is copied verbatim; only the slot the user actually
 * changed is replaced. Reads NEVER autoassign defaults: a null or
 * currently-unavailable selection is preserved and rendered honestly
 * until a real user choice replaces or clears it.
 *
 * Choice candidates come from the REAL configured rows
 * (`config.models.list` + `config.providers.list`, both paged) filtered by
 * the ORIGINAL capability/use-surface rules (ModelProfile.swift:170-278) —
 * the user's saved capability decisions (`useSurfaces`) are respected over
 * the derived-from-capabilities fallback, media models never leak into
 * text/vision/approval pickers, and nothing is populated from a hardcoded
 * catalog or a first-usable fallback.
 *
 * This surface configures FUTURE routing only: it never mutates an active
 * run's frozen model route.
 */
class SettingsRoleModelController internal constructor(
    private val host: RuntimeHost,
) {
    /** One original role slot of the preferences document. */
    enum class RoleSlot(val wireKey: String) {
        /** Primary agent route; null = no durable default. */
        DEFAULT_AGENT("defaultAgentModelID"),

        /** Text-only background work; null explicitly inherits the default agent. */
        GENERAL_AUXILIARY_LLM("generalAuxiliaryLLMModelID"),

        /** Canvas assistant route; null inherits the ordinary agent default. */
        CANVAS_AGENT("canvasAgentModelID"),

        /** Dedicated visual-understanding route; null = not configured. */
        VISION("visionModelID"),

        /** Canvas visual route; null inherits the auxiliary vision route. */
        CANVAS_VISION("canvasVisionModelID"),

        /** Approval-review route (null = unconfigured; the original has no
         *  explicit inherit — the runtime resolves its own fallback). */
        APPROVAL("approvalModelID"),

        /** Tool-free package review route; null follows the general auxiliary. */
        PACKAGE_REVIEW("packageReviewModelID"),

        /** Shared media route (shared mode only). */
        SHARED_IMAGE("sharedImageModelID"),

        /** Image generation route (separate mode only). */
        IMAGE_GENERATION("imageGenerationModelID"),

        /** Image editing route (separate mode only). */
        IMAGE_EDITING("imageEditingModelID"),

        /** Agent-initiated video generation default. */
        DEFAULT_VIDEO("defaultVideoModelID"),
    }

    /** Honest display state of one slot's CURRENT (saved) selection. */
    enum class SelectionStatus { EMPTY, AVAILABLE, UNAVAILABLE }

    data class SlotState(
        val slot: RoleSlot,
        val selection: String?,
        val status: SelectionStatus,
        /** Model display label for the current selection (null when empty). */
        val selectionLabel: String?,
    )

    data class RoleChoice(
        val modelId: String,
        val displayName: String,
        val providerId: String,
        val providerName: String,
    )

    data class RoleModelState(
        val loading: Boolean = true,
        val error: String? = null,
        /** CAS revision (the preferences syncRevision string), null = no read yet. */
        val revision: String? = null,
        val auxiliaryImageMode: String = MODE_SHARED,
        val autonomousImageRouting: Boolean = false,
        val saved: Map<RoleSlot, String?> = emptyMap(),
        /** User draft; a slot present here differs from [saved]. */
        val draft: Map<RoleSlot, String?> = emptyMap(),
        val saving: Boolean = false,
        val saveError: String? = null,
        val choices: Map<RoleSlot, List<RoleChoice>> = emptyMap(),
        /** Working scalar differs from the last-read document (dirty intent). */
        val modeDirty: Boolean = false,
        val routingDirty: Boolean = false,
    ) {
        fun slotState(slot: RoleSlot): SlotState {
            // An explicit clear (draft holds null) wins over the saved value.
            val selection = if (draft.containsKey(slot)) draft[slot] else saved[slot]
            val status = when {
                selection == null -> SelectionStatus.EMPTY
                else -> if (choices[slot]?.any {
                        it.modelId.equals(selection, ignoreCase = true)
                    } == true) {
                    SelectionStatus.AVAILABLE
                } else {
                    SelectionStatus.UNAVAILABLE
                }
            }
            val label = selection?.let { id ->
                choices[slot]?.firstOrNull {
                    it.modelId.equals(id, ignoreCase = true)
                }?.let { "${it.displayName} · ${it.providerName}" }
                    ?: id
            }
            return SlotState(slot, selection, status, label)
        }

        /** True when any draft differs from the saved document. */
        val hasDraftChanges: Boolean get() = draft.isNotEmpty()
    }

    private val stateFlow = MutableStateFlow(RoleModelState())
    val state: StateFlow<RoleModelState> = stateFlow

    /** Fences async reads/saves: a newer refresh owns the surface. */
    private val refreshGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /** Reusable full-row reader for the REAL `config.models.list` command
     *  (job-7d4d4e41017f4391): a legally saved dense row larger than one
     *  page item no longer refuses the sweep — the reader drives the
     *  additive closed `modelRead` chunk continuation on this SAME command
     *  and only ever hands this consumer a full ORIGINAL logical page.
     *  Ordinary pages are byte-identical to the legacy reads. */
    private val modelRead = ModelPageReadController(host)

    private fun client() = host.commandClient
    private fun admitted(): Boolean = host.readiness.value.providerConfigurationAdmitted

    // Canonical policy lives in :feature:settings; the App supplies real
    // configured rows and owns only effects and presentation identities.
    internal fun effectiveSurfaces(capabilities: Int, useSurfaces: Int?): Int =
        ModelRolePolicy.effectiveSurfaces(capabilities, useSurfaces)

    internal fun eligibleFor(slot: RoleSlot, capabilities: Int, useSurfaces: Int?): Boolean =
        ModelRolePolicy.eligibleFor(
            ModelRolePolicy.RoleSlot.valueOf(slot.name), capabilities, useSurfaces,
        )

    // ---------------------------------------------------------------- reads

    /**
     * Refreshes the whole surface: the full preferences document (all role
     * slots, lossless), then the real provider + model rows both paged.
     * The draft is preserved across refreshes so an unrelated re-read can
     * never wipe the user's pending choices.
     */
    fun refresh() {
        if (!admitted()) return
        val generation = refreshGeneration.incrementAndGet()
        update { it.copy(loading = true, error = null) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.preferences.get",
                scope = HostScope.ApplicationConfiguration("preferences"),
                stateful = false,
                correlationID = client().correlationID("rolesget"),
            ),
        ) { outcome ->
            if (refreshGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val revision = (root?.get("revision") as? JsonObject)
                        ?.string("version")
                    val document = root?.get("preferences") as? JsonObject
                    if (revision == null || document == null) {
                        update { it.copy(loading = false, error = "preferences_unavailable") }
                        return@trackOperation
                    }
                    val saved = decodeSlots(document)
                    update { state ->
                        // Re-anchor from the document WITHOUT resetting newer
                        // user intent: a dirty scalar keeps its working value
                        // (and stays dirty) unless the arriving document
                        // already agrees, in which case the intent converged.
                        val docMode = document.string("auxiliaryImageMode") ?: MODE_SHARED
                        val docRouting = document.bool("autonomousImageRouting") ?: false
                        val mode = if (state.modeDirty) state.auxiliaryImageMode else docMode
                        val routing = if (state.routingDirty) {
                            state.autonomousImageRouting
                        } else {
                            docRouting
                        }
                        state.copy(
                            loading = false,
                            error = null,
                            revision = revision,
                            auxiliaryImageMode = mode,
                            autonomousImageRouting = routing,
                            modeDirty = state.modeDirty && mode != docMode,
                            routingDirty = state.routingDirty && routing != docRouting,
                            saved = saved,
                        )
                    }
                    fetchProviderPage(generation, cursor = null, pages = 0,
                        accumulated = ArrayList())
                }
                is HostOperationOutcome.Rejected ->
                    update { it.copy(loading = false, error = outcome.code) }
                is HostOperationOutcome.Failed ->
                    update { it.copy(loading = false, error = outcome.code) }
                else -> Unit
            }
        }
    }

    private fun fetchProviderPage(
        generation: Long,
        cursor: String?,
        pages: Int,
        accumulated: ArrayList<JsonElement>,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "config.providers.list",
                scope = HostScope.ApplicationConfiguration("providers"),
                stateful = false,
                correlationID = client().correlationID("rolesplist"),
                payload = providerListPayload(cursor),
            ),
        ) { outcome ->
            if (refreshGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val value = outcome.value
                    val rows = pageRows(value)
                    if (rows == null) {
                        update { it.copy(error = "providers_unavailable") }
                        return@trackOperation
                    }
                    accumulated.addAll(rows)
                    val meta = pageMeta(value)
                    if (meta?.hasMore == true) {
                        val next = meta.nextCursor
                        if (!pageProgressed(cursor, next) ||
                            pages + 1 >= MAX_PAGE_CHAIN ||
                            accumulated.size >= MAX_ROLE_PROVIDER_ROWS
                        ) {
                            update { it.copy(error = "providers_page_continuation") }
                            return@trackOperation
                        }
                        fetchProviderPage(generation, next, pages + 1, accumulated)
                        return@trackOperation
                    }
                    val providers = decodeProviderInfos(accumulated)
                    startModelSweep(generation, providers)
                }
                is HostOperationOutcome.Rejected ->
                    update { it.copy(error = outcome.code) }
                is HostOperationOutcome.Failed ->
                    update { it.copy(error = outcome.code) }
                else -> Unit
            }
        }
    }

    /**
     * Bounded INCREMENTAL model read for the role candidates
     * (MAIN_CONFIG_READ_PAGING_DECISION + Main's large-profile read
     * fidelity rule). The old single global chain capped accumulation at
     * 400 rows, so a VALID saved profile with up to the natively supported
     * 512 models per provider hit an accidental unsupported-tail refusal.
     * The sweep now walks the ENABLED providers one at a time through the
     * ACTUAL `config.models.list` provider-filtered continuation
     * ({"providerID"} + composer cursor), driven by the reusable
     * ModelPageReadController so a legally saved row that exceeds one page
     * item is streamed and reconstructed COMPLETE (the consumer only ever
     * sees full original rows; byte-identical pages otherwise):
     *  * per provider: the PROVED supported bound (512 rows — the exact
     *    native candidate/parser limit; more means persisted data outside
     *    the supported profile contract → typed refusal, not truncation);
     *  * model pages: at most the supported model-row count. The byte
     *    budget can fit only one legal row per page; 200 is a maximum
     *    item count, not a guaranteed page size. Cursor progress and the
     *    actual row/accumulation bounds remain mandatory;
     *  * global accumulation: a fixed proved readable ceiling (mirrors the
     *    conversation projection reader), never unbounded growth;
     *  * generation fencing unchanged — a newer refresh owns the surface
     *    and mid-chain refusals never publish a partial mix.
     * Disabled providers are not read (their rows can never become role
     * candidates), which is the honest lossless filter for this surface.
     */
    private fun startModelSweep(generation: Long, providers: Map<String, ProviderInfo>) {
        val targets = providers.values.filter { it.enabled }.sortedBy { it.id.uppercase() }
        accumulateModelSweep(generation, providers, targets, 0, ArrayList())
    }

    private fun accumulateModelSweep(
        generation: Long,
        providers: Map<String, ProviderInfo>,
        targets: List<ProviderInfo>,
        index: Int,
        accumulated: ArrayList<JsonElement>,
    ) {
        if (refreshGeneration.get() != generation) return
        if (index >= targets.size) {
            publishChoices(generation, providers, accumulated)
            return
        }
        if (accumulated.size >= MAX_ROLE_MODEL_ROWS) {
            update { it.copy(error = "models_accumulation_bound") }
            return
        }
        fetchProviderModels(generation, providers, targets, index, accumulated,
            target = targets[index], cursor = null, pages = 0, providerRows = 0)
    }

    private fun fetchProviderModels(
        generation: Long,
        providers: Map<String, ProviderInfo>,
        targets: List<ProviderInfo>,
        index: Int,
        accumulated: ArrayList<JsonElement>,
        target: ProviderInfo,
        cursor: String?,
        pages: Int,
        providerRows: Int,
    ) {
        modelRead.readPage(
            providerID = target.id,
            cursor = cursor,
            correlationTag = "rolesmlist",
            isCurrent = { refreshGeneration.get() == generation },
        ) { outcome ->
            if (refreshGeneration.get() != generation) return@readPage
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val value = outcome.value
                    val rows = pageRows(value)
                    if (rows == null) {
                        update { it.copy(error = "models_unavailable") }
                        return@readPage
                    }
                    // Keep ONLY this provider's rows (the native filtered
                    // read guarantees it; the defensive filter keeps a
                    // misrouted page from ever cross-accumulating). The
                    // reader guarantees every row here is a COMPLETE
                    // original row: a chunk marker never reaches a page
                    // consumer, and an oversized row is never skipped.
                    val mine = rows.filter {
                        rowProviderId(it)?.equals(target.id, ignoreCase = true) == true
                    }
                    val total = providerRows + mine.size
                    if (total > MODEL_ROWS_SUPPORTED) {
                        update { it.copy(error = "models_supported_bound") }
                        return@readPage
                    }
                    if (accumulated.size + mine.size > MAX_ROLE_MODEL_ROWS) {
                        update { it.copy(error = "models_accumulation_bound") }
                        return@readPage
                    }
                    accumulated.addAll(mine)
                    val meta = pageMeta(value)
                    if (meta?.hasMore == true) {
                        val next = meta.nextCursor
                        if (!pageProgressed(cursor, next) || pages + 1 >= MAX_MODEL_PAGE_CHAIN) {
                            update { it.copy(error = "models_page_continuation") }
                            return@readPage
                        }
                        fetchProviderModels(generation, providers, targets, index,
                            accumulated, target, next, pages + 1, total)
                        return@readPage
                    }
                    accumulateModelSweep(generation, providers, targets, index + 1,
                        accumulated)
                }
                is HostOperationOutcome.Rejected ->
                    update { it.copy(error = outcome.code) }
                is HostOperationOutcome.Failed ->
                    // Typed reader/protocol refusal: the LAST whole
                    // projection stays; the draft is untouched.
                    update { it.copy(error = outcome.code) }
                else -> Unit
            }
        }
    }

    /** The closed `providerID` member of one model row (null if unreadable). */
    private fun rowProviderId(row: JsonElement): String? =
        (row as? JsonObject)?.string("providerID")

    /**
     * Raw capability bits per model id, kept for the shared/separate mode
     * transition (the original derives the new media slots from the real
     * capabilities of the current media choice). RAM only.
     */
    private var modelsCaps: Map<String, Int> = emptyMap()

    private fun publishChoices(
        generation: Long,
        providers: Map<String, ProviderInfo>,
        rows: List<JsonElement>,
    ) {
        if (refreshGeneration.get() != generation) return
        val models = rows.mapNotNull { decodeModelRow(it as? JsonObject) }
        modelsCaps = models.associate { it.id.uppercase() to it.capabilities }
        val choices = RoleSlot.entries.associateWith { slot ->
            models.filter { model ->
                val provider = providers[model.providerId.uppercase()] ?: return@filter false
                provider.enabled && model.isEnabled && eligibleFor(
                    slot, model.capabilities, model.useSurfaces,
                ) && (slot != RoleSlot.DEFAULT_AGENT || !model.hiddenFromPrimaryPicker)
            }.sortedBy { it.displayName.lowercase() }
                .map { model ->
                    val provider = providers.getValue(model.providerId.uppercase())
                    RoleChoice(
                        modelId = model.id,
                        displayName = model.displayName,
                        providerId = model.providerId,
                        providerName = provider.displayName,
                    )
                }
        }
        update { it.copy(choices = choices) }
    }

    // ------------------------------------------------------------ user edits

    /**
     * Stage one slot change in the draft (null = clear/inherit), normalized
     * against the SAVED baseline with explicit-null/containsKey semantics:
     *  * selecting the SAVED value removes the draft entry (true revert);
     *  * re-selecting the CURRENT draft value is idempotent — with
     *    saved=A/draft=B, choosing B again keeps B (never collapses via
     *    `?:` back to A);
     *  * an explicit clear stays clear (never resurrected by `?:`).
     */
    fun select(slot: RoleSlot, modelId: String?) {
        update { state ->
            val hasDraft = state.draft.containsKey(slot)
            val draftValue = state.draft[slot]
            val savedValue = state.saved[slot]
            when {
                savedValue.equals(modelId, ignoreCase = true) ->
                    state.copy(draft = state.draft - slot, saveError = null)
                hasDraft && draftValue == null && modelId == null -> state
                else -> state.copy(draft = state.draft + (slot to modelId), saveError = null)
            }
        }
    }

    /** Discard every staged change (explicit user cancel). */
    fun discardDraft() {
        update { it.copy(draft = emptyMap(), saveError = null) }
    }

    /**
     * The original shared↔separate transition (switchAuxiliaryMode): the
     * media slots are recomputed from the CURRENT media choice and each
     * model's real capabilities — never guessed, and a media model that
     * lacks the required capability is cleared rather than forced.
     */
    fun setAuxiliaryMode(separate: Boolean) {
        val target = if (separate) MODE_SEPARATE else MODE_SHARED
        if (stateFlow.value.auxiliaryImageMode == target) return
        update { state ->
            val saved = state.saved
            val current = state.draft
            // containsKey distinguishes an explicit clear (draft null) from
            // "no draft" — a cleared slot must not resurrect the saved value.
            fun sel(slot: RoleSlot): String? =
                if (current.containsKey(slot)) current[slot] else saved[slot]
            val nextDraft = current.toMutableMap()
            ModelRolePolicy.transitionMediaMode(
                separate = separate,
                current = { slot -> sel(RoleSlot.valueOf(slot.name)) },
                capabilities = { id -> stateChoiceCapabilities(state, id) },
            ).forEach { (slot, modelId) ->
                nextDraft[RoleSlot.valueOf(slot.name)] = modelId
            }
            state.copy(
                auxiliaryImageMode = target,
                draft = nextDraft,
                saveError = null,
                modeDirty = true,
            )
        }
    }

    fun setAutonomousImageRouting(enabled: Boolean) {
        update { state ->
            if (state.autonomousImageRouting == enabled) {
                state
            } else {
                state.copy(
                    autonomousImageRouting = enabled,
                    saveError = null,
                    routingDirty = true,
                )
            }
        }
    }

    /**
     * Persists the draft under the REAL full-document CAS:
     * `config.preferences.get` supplies the current document + revision, the
     * payload copies it verbatim and replaces ONLY the drafted slots, echoing
     * `syncRevision` for the writer's full-snapshot gate. The mode/routing
     * scalars are written ONLY as dirty intents — untouched document fields
     * are never overwritten with stale snapshots, so another settings editor
     * (or a sync bump) cannot lose state to this surface.
     *
     * A stale revision is a typed refusal and the DRAFT IS PRESERVED — the
     * retry path re-reads and re-applies, never auto-replaying a destructive
     * write on an unknown outcome. On success, ONLY the draft entries whose
     * value STILL equals what this save carried are consumed; a newer
     * same-slot choice (re-select or explicit clear) made mid-flight
     * survives, as do mid-flight mode/routing changes this save did not
     * write. No success refresh runs: a newer user choice must never be
     * reset by an old callback, and the next save re-reads the document
     * fresh anyway. Settings for future resolution only: an active run's
     * frozen route is untouched.
     */
    fun save(onOutcome: ((HostOperationOutcome) -> Unit)? = null): Boolean {
        if (!admitted()) return false
        if (stateFlow.value.saving) return false
        val carriedDraft = stateFlow.value.draft
        val carriedMode = stateFlow.value.auxiliaryImageMode
        val carriedRouting = stateFlow.value.autonomousImageRouting
        val writeMode = stateFlow.value.modeDirty
        val writeRouting = stateFlow.value.routingDirty
        update { it.copy(saving = true, saveError = null) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.preferences.get",
                scope = HostScope.ApplicationConfiguration("preferences"),
                stateful = false,
                correlationID = client().correlationID("rolespre"),
            ),
        ) { read ->
            if (read !is HostOperationOutcome.Completed) {
                update { it.copy(saving = false, saveError = "preferences_unavailable") }
                onOutcome?.invoke(read)
                return@trackOperation
            }
            val root = read.value as? JsonObject
            val revision = (root?.get("revision") as? JsonObject)?.string("version")
            val document = root?.get("preferences") as? JsonObject
            if (revision == null || document == null) {
                update { it.copy(saving = false, saveError = "preferences_unavailable") }
                return@trackOperation
            }
            val payload = JsonObject(
                LinkedHashMap(document).apply {
                    for ((slot, value) in carriedDraft) {
                        put(slot.wireKey, value?.let { JsonPrimitive(it) } ?: JsonNull)
                    }
                    // Dirty intents only. UNTOUCHED scalars are copied from
                    // the FRESHLY-READ document (never from the working
                    // snapshot), so a concurrent change by another settings
                    // editor is preserved rather than clobbered. The original
                    // Codable requires `auxiliaryImageMode` (non-optional);
                    // `autonomousImageRouting` is optional, so a document
                    // that lacks it stays absent (nil preserved, not cleared).
                    if (writeMode) {
                        put("auxiliaryImageMode", JsonPrimitive(carriedMode))
                    } else {
                        put("auxiliaryImageMode", JsonPrimitive(
                            document.string("auxiliaryImageMode") ?: MODE_SHARED))
                    }
                    if (writeRouting) {
                        put("autonomousImageRouting", JsonPrimitive(carriedRouting))
                    } else {
                        document.bool("autonomousImageRouting")?.let {
                            put("autonomousImageRouting", JsonPrimitive(it))
                        }
                    }
                    (revision.toLongOrNull())?.let {
                        put("syncRevision", JsonPrimitive(it))
                    }
                },
            )
            host.trackOperation(
                HostCommandRequest(
                    command = "config.preferences.save",
                    scope = HostScope.ApplicationConfiguration("preferences"),
                    stateful = true,
                    correlationID = client().correlationID("rolessave"),
                    revision = HostRevision("preferences", revision),
                    payload = payload,
                ),
            ) { outcome ->
                onOutcome?.invoke(outcome)
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        update { state ->
                            // Consume only entries that still hold exactly
                            // what this save carried (containsKey semantics:
                            // an explicit-null carry matches an explicit-null
                            // current). Newer same-slot edits/clears stay.
                            val remaining = state.draft.toMutableMap()
                            val mergedSaved = state.saved.toMutableMap()
                            for ((slot, frozenValue) in carriedDraft) {
                                val stillPresent = remaining.containsKey(slot)
                                val currentValue = remaining[slot]
                                if (stillPresent && currentValue == frozenValue) {
                                    remaining.remove(slot)
                                }
                                mergedSaved[slot] = frozenValue
                            }
                            state.copy(
                                saving = false,
                                draft = remaining,
                                saved = mergedSaved,
                                revision = null,
                                // A scalar's dirty intent clears only when the
                                // working value still equals what this save
                                // persisted; a mid-flight scalar change keeps
                                // its intent for the next save.
                                modeDirty = if (writeMode) {
                                    state.auxiliaryImageMode != carriedMode
                                } else {
                                    state.modeDirty
                                },
                                routingDirty = if (writeRouting) {
                                    state.autonomousImageRouting != carriedRouting
                                } else {
                                    state.routingDirty
                                },
                            )
                        }
                    }
                    is HostOperationOutcome.Rejected -> update {
                        // staleRevision and friends surface typed; the draft
                        // survives for an explicit retry.
                        it.copy(saving = false, saveError = outcome.code)
                    }
                    is HostOperationOutcome.Failed -> update {
                        it.copy(saving = false, saveError = outcome.code)
                    }
                    else -> update { it.copy(saving = false) }
                }
            }
        }
        return true
    }

    // --------------------------------------------------------------- decodes

    private fun decodeSlots(document: JsonObject): Map<RoleSlot, String?> =
        RoleSlot.entries.associateWith { slot ->
            document.string(slot.wireKey)?.takeIf { it.isNotBlank() }
        }

    private data class ModelRowInfo(
        val id: String,
        val providerId: String,
        val displayName: String,
        val isEnabled: Boolean,
        val hiddenFromPrimaryPicker: Boolean,
        val capabilities: Int,
        val useSurfaces: Int?,
    )

    private data class ProviderInfo(
        val id: String,
        val displayName: String,
        val enabled: Boolean,
    )

    private fun decodeModelRow(obj: JsonObject?): ModelRowInfo? {
        obj ?: return null
        val capabilities = (obj["capabilities"] as? JsonObject)
            ?.long("rawValue")?.toInt()
            ?: (obj["capabilities"] as? JsonPrimitive)?.longOrNull?.toInt()
            ?: (obj["capabilities"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.longOrNull?.toInt() }
                ?.fold(0) { bits, bit -> bits or bit }
            ?: 0
        val useSurfaces = (obj["useSurfaces"] as? JsonObject)?.long("rawValue")?.toInt()
        return ModelRowInfo(
            id = obj.string("id") ?: return null,
            providerId = obj.string("providerID") ?: return null,
            displayName = obj.string("displayName")
                ?: obj.string("remoteModelID") ?: return null,
            isEnabled = obj.bool("isEnabled") ?: true,
            hiddenFromPrimaryPicker = obj.bool("isHiddenFromPrimaryPicker") ?: false,
            capabilities = capabilities,
            useSurfaces = useSurfaces,
        )
    }

    private fun decodeProviderInfos(rows: List<JsonElement>): Map<String, ProviderInfo> {
        val out = LinkedHashMap<String, ProviderInfo>()
        for (element in rows) {
            val obj = element as? JsonObject ?: continue
            val id = obj.string("providerID") ?: obj.string("id") ?: continue
            out[id.uppercase()] = ProviderInfo(
                id = id,
                displayName = obj.string("displayName") ?: id,
                enabled = obj.bool("enabled") ?: obj.bool("isEnabled") ?: true,
            )
        }
        return out
    }

    /** Capability lookup for the mode transition over the LAST choices. */
    private fun stateChoiceCapabilities(state: RoleModelState, modelId: String): Int? =
        modelsCaps[modelId.uppercase()]

    private fun update(transform: (RoleModelState) -> RoleModelState) {
        stateFlow.value = transform(stateFlow.value)
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun pageRows(value: JsonElement?): List<JsonElement>? =
        ((value as? JsonObject)?.get("rows") as? JsonArray)?.toList()
            ?: (value as? JsonArray)?.toList()

    private fun pageMeta(value: JsonElement?): PageMeta? {
        val obj = value as? JsonObject ?: return null
        val next = (obj["nextCursor"] as? JsonPrimitive)?.takeIf { it.isString }
            ?.contentOrNull
        val hasMore = (obj["hasMore"] as? JsonPrimitive)?.booleanOrNull ?: false
        return PageMeta(next, hasMore)
    }

    private data class PageMeta(val nextCursor: String?, val hasMore: Boolean)

    private fun pageProgressed(previous: String?, next: String?): Boolean {
        val nextValue = next?.toLongOrNull() ?: return false
        if (nextValue < 0) return false
        if (previous == null) return true
        val previousValue = previous.toLongOrNull() ?: return false
        return nextValue > previousValue
    }

    private fun providerListPayload(cursor: String?): JsonObject = JsonObject(buildMap {
        put("operation", JsonPrimitive("snapshot"))
        if (cursor != null) put("cursor", JsonPrimitive(cursor))
    })

    // The provider-filtered closed models-list payload (including the
    // additive full-row `modelRead` opt-in grammar) is owned by the
    // reusable ModelPageReadController — one reader, no second wire shape.

    companion object {
        const val MODE_SHARED = ModelRolePolicy.MODE_SHARED
        const val MODE_SEPARATE = ModelRolePolicy.MODE_SEPARATE
        /** One bounded continuation chain (composer page budget). */
        const val MAX_PAGE_CHAIN = 8
        /**
         * Proved readable provider-row ceiling for the 8-page chain: the
         * ORIGINAL composer emits AT MOST 200 rows per page
         * (ConfigPageBudget.maximumItemsPerPage), so 8 pages can never
         * legitimately carry more than 1_600 rows. The previous 400-row
         * guard was an accidental refusal BELOW the proved chain (an
         * unsupported tail); this value is NOT a budget raise — it is
         * exactly the maximum one legal chain can transport.
         */
        const val MAX_ROLE_PROVIDER_ROWS = 1_600
        /** The UNCHANGED native supported per-provider model bound
         *  (ProviderSaveCandidate.selectedModels ≤ 512). More persisted
         *  rows on one provider is outside the supported profile
         *  contract: a typed refusal, never a silent truncation. */
        const val MODEL_ROWS_SUPPORTED = 512
        /** At least one row must fit each progressing model page. */
        const val MAX_MODEL_PAGE_CHAIN = MODEL_ROWS_SUPPORTED
        /** Fixed readable-accumulation ceiling for this surface (mirrors
         *  the conversation projection reader bound; bounded buffers,
         *  never unbounded global growth). */
        const val MAX_ROLE_MODEL_ROWS = 4_096
    }
}

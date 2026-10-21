// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/**
 * App-host binding for the G02 Settings business surfaces: agent defaults,
 * memory & personalization, usage, privacy and provider/global preferences.
 * Every operation travels the accepted rev3 settings-domain wire contract
 * (labels settings.defaults / memory / personalization / usage / privacy)
 * with revision-CAS; failures and stale revisions surface typed — never a
 * silent overwrite.
 *
 * Privacy (Main decision 2026-10-19):
 *  * `remaining` renders null ONLY with a typed `remainingFailure` AND
 *    `partial=true` — never an inferred zero.
 *  * `preferencesFailure` is surfaced separately; there is no dummy provider.
 *  * Failure/deletionFailure details page through the SAME
 *    `privacy.summary.get` with `{report:{handle,cursor,maxItems}}` against
 *    the same-root process-lifetime report store — never through content.read
 *    with a foreign label.
 *  * A trusted clear confirmation is minted ONLY after the user taps the
 *    exact preview + action row for the CURRENT epoch; the digest alone is
 *    never consent. This task never clears real user data by itself.
 */
class SettingsHostController internal constructor(
    private val host: RuntimeHost,
) {
    /**
     * R4 — the full original role-slot preferences surface (all
     * ModelSelectionPreferences roles + capability-filtered choices +
     * lossless CAS saves). Owned here so the existing settings pages reach
     * it without any new shell wiring; the launchpad's existing
     * default-agent projection ([PreferencesSurface]) is unchanged.
     */
    val roles = SettingsRoleModelController(host)

    private val stateFlow = MutableStateFlow(SettingsHostState())
    private val stateMutationLock = Any()
    val state: StateFlow<SettingsHostState> = stateFlow

    /**
     * Monotonic personalization fence: kind switches, refresh, revision
     * reads, rollback and generate terminals each advance it. Every async
     * personalization callback captures the epoch at dispatch and applies
     * ONLY when the epoch is unchanged, so a late read/save/generate
     * result can never overwrite a newer document, another kind or a
     * replacement sheet.
     */
    private val personalizationEpoch = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Fences ONLY the active-document handle read. Unrelated revision reads
     * or generate terminals must not cancel an in-flight content load, while
     * a new refresh/kind switch/save (which starts a fresh document read)
     * always invalidates the older chain.
     */
    private val personalizationContentGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Monotonic owner token for the personalization document VIEW currently
     * shown. A full document read (kind switch, refresh/retry, a mutation
     * refresh) establishes a new view. A mutation terminal captures the
     * token at dispatch and publishes its refresh/error ONLY while that
     * same kind+view still owns the surface, so a late save/automatic/
     * rollback reply can never retarget a newer kind or write its typed
     * error into a newer view (including an ABA return to the same kind).
     * This is deliberately separate from [personalizationEpoch] and
     * [personalizationContentGeneration]: a stale mutation must not cancel
     * an unrelated revision read or active-document chunk chain.
     */
    private val personalizationViewGeneration =
        java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Orders the ownership check of a mutation-triggered document refresh
     * with the epoch/view bumps of any newer refresh. Without this, a kind
     * switch could land between the check and the bump and the older
     * mutation's read would win the epoch and retarget the new view.
     */
    private val personalizationRefreshLock = Any()

    /** In-flight flags per surface (loading/error/retry truth). */
    data class SurfaceStatus(
        val loading: Boolean = false,
        val error: String? = null,
    )

    data class SettingsHostState(
        val defaults: SettingsDefaultsSurface = SettingsDefaultsSurface(),
        val defaultsStatus: SurfaceStatus = SurfaceStatus(loading = true),
        val memory: MemorySurface = MemorySurface(),
        val memoryStatus: SurfaceStatus = SurfaceStatus(loading = true),
        val personalization: PersonalizationSurface = PersonalizationSurface(),
        val personalizationStatus: SurfaceStatus = SurfaceStatus(loading = true),
        val usage: UsageSurface = UsageSurface(),
        val usageStatus: SurfaceStatus = SurfaceStatus(loading = true),
        val privacy: PrivacySurface = PrivacySurface(),
        val privacyStatus: SurfaceStatus = SurfaceStatus(loading = true),
        /**
         * Owned terminal state of the last privacy-clear request (see
         * [PrivacyClearStatus]). Surfaced on the page so an actual failure
         * or partial report is never silently dropped.
         */
        val privacyClear: PrivacyClearStatus? = null,
        val preferences: PreferencesSurface = PreferencesSurface(),
        val preferencesStatus: SurfaceStatus = SurfaceStatus(loading = true),
        /**
         * ONE owned memory editor snapshot. The row is the FRESH
         * `memory.get` reply captured at open time (content AND full-row
         * digest frozen for the dialog's lifetime); a background list
         * refresh can update [memory] without changing this draft's base.
         */
        val memoryEditor: MemoryEditorProjection? = null,
        val memoryEditorLoading: Boolean = false,
        val memoryEditorError: String? = null,
        /**
         * Typed terminal of the LAST save/delete of the editor generation
         * named in [MemoryEditorMutation.generation]. A result for a
         * dismissed/replaced editor is dropped instead of closing or
         * writing its error into a newer one.
         */
        val memoryEditorMutation: MemoryEditorMutation? = null,
        /**
         * The ONE UI-owned add-memory dialog. [generation] fences the
         * `memory.add` terminal: after a cancel or a replacement dialog the
         * old result can neither close nor fill the newer dialog.
         */
        val memoryAdd: MemoryAddSurface = MemoryAddSurface(),
    )

    data class SettingsDefaultsSurface(
        val defaultAgentMode: String = "human",
        val runningInputMode: String = "queue",
        val verifyFinalAnswer: Boolean = false,
        val explicitDefaultAgentMode: Boolean = false,
        val explicitRunningInputMode: Boolean = false,
        val explicitVerifyFinalAnswer: Boolean = false,
        val revision: String = "",
    )

    data class MemorySurface(
        val entries: List<MemoryEntryProjection> = emptyList(),
        val nextCursor: String? = null,
        val loadingMore: Boolean = false,
        /**
         * True once the INITIAL (non-continuation) read settled in ANY
         * terminal class — a real page (even an empty inventory), a typed
         * refusal/failure, or a cancelled/superseded terminal. Until then a
         * page open may run the one-shot recovery read; afterwards the
         * surface is settled data (or a typed error with Retry) and is never
         * refreshed indiscriminately.
         */
        val loaded: Boolean = false,
        val searchItems: List<MemorySearchItemProjection> = emptyList(),
        val searchActive: Boolean = false,
        val searchQuery: String = "",
        /** ORIGINAL process-lifetime search handle for handle+cursor pages. */
        val searchHandle: String? = null,
        val searchNextCursor: String? = null,
        val searchHasMore: Boolean = false,
        val searchLoadingMore: Boolean = false,
        /** Honest count of recalled rows that vanished before the fresh read. */
        val searchChangedCount: Int = 0,
        val candidates: List<MemoryCandidateProjection> = emptyList(),
        val candidatesNextCursor: String? = null,
        val candidatesSweepApplied: Boolean = false,
        val candidatesLoadingMore: Boolean = false,
        val organize: OrganizeSurface? = null,
    )

    data class MemoryEntryProjection(
        val id: String,
        val content: String,
        val scopeKind: String,
        val status: String,
        val importance: Double,
        val isPinned: Boolean,
        val revision: String,
    )

    /**
     * The one memory row the editor owns. [generation] fences late
     * `memory.get` replies: only the newest open (or none after dismiss)
     * may publish, so clicking A then B can never leave two editors or a
     * stale A after B.
     */
    data class MemoryEditorProjection(
        val entry: MemoryEntryProjection,
        val generation: Long,
    )

    enum class MemoryEditorOperation { Save, Delete }

    /**
     * Typed result of one editor save/delete, bound to the generation that
     * dispatched it. The page renders it only while that SAME generation
     * still owns [memoryEditor]; a terminal for a dismissed or replaced
     * editor is never published (the real write and the global data
     * refresh are unaffected).
     */
    data class MemoryEditorMutation(
        val generation: Long,
        val operation: MemoryEditorOperation,
        val outcome: MemoryMutationOutcome,
    )

    /**
     * The ONE owned add-memory dialog. [failure] is a recoverable typed
     * refusal/unconfirmed result; [inFlight] gates double submits.
     */
    data class MemoryAddSurface(
        val open: Boolean = false,
        val generation: Long = 0L,
        val inFlight: Boolean = false,
        val failure: MemoryMutationOutcome? = null,
    )

    /**
     * One explicit bulk-delete UI interaction, issued by
     * [beginMemoryBulkInteraction]. Every new selection/edit/cancel starts
     * a new interaction: a terminal for an older one still refreshes the
     * real data, but is never delivered into the newer UI state (including
     * a re-entered selection or an ABA return to the same rows).
     */
    data class MemoryBulkInteraction(val generation: Long)

    /**
     * One explicit bulk-delete intent. [batchID] and [syncRevision] are
     * frozen when the user opens the confirmation and MUST be reused for a
     * retry of the same uncertain write — the native durable ledger is
     * idempotent only for the same batchID.
     */
    data class MemoryBulkDeleteIntent(
        val batchID: String,
        val syncRevision: Long,
        val entries: List<MemoryDeleteTarget>,
    )

    data class MemoryDeleteTarget(
        val id: String,
        val digest: String,
    )

    sealed interface MemoryBulkDeletePreparation {
        data class Ready(val intent: MemoryBulkDeleteIntent) :
            MemoryBulkDeletePreparation
        data class Invalid(val code: String) : MemoryBulkDeletePreparation
    }

    /**
     * Typed terminal meaning for one memory mutation. [Refused] is a
     * writer refusal that proves nothing changed; [Unconfirmed] covers
     * transport/ack loss where a commit may have happened and the UI must
     * not claim "nothing was changed".
     */
    sealed interface MemoryMutationOutcome {
        data object Applied : MemoryMutationOutcome
        data class Refused(val code: String) : MemoryMutationOutcome
        data class Unconfirmed(val code: String) : MemoryMutationOutcome
    }

    /**
     * One ORIGINAL `MemorySearchItem` (SettingsDomainV1): the live `current`
     * row (null when the row vanished between recall and the fresh page
     * read) plus the contract's single truthful change signal `deleted`.
     * There is NO producer "projected" snapshot; `changedDuringSearch` is
     * therefore exactly `deleted` — never a fabricated comparison.
     */
    data class MemorySearchItemProjection(
        val id: String,
        val current: MemoryEntryProjection?,
        val deleted: Boolean,
        val changedDuringSearch: Boolean,
    )

    data class MemoryCandidateProjection(
        val id: String,
        val content: String,
        val status: String,
        val revision: String,
    )

    /**
     * The organize proposal surface. [entries] are the proposal's paged
     * entry summaries (real current content) joined by id, so a review card
     * shows what a suggestion actually changes instead of a generic
     * checkbox. [startCorrelation]/[startReceipt] address the REAL accepted
     * start operation for `memory.organize.cancel` — never a UI-derived id.
     */
    data class OrganizeSurface(
        val proposalHandle: String,
        val scannedCount: Int,
        val suggestions: List<OrganizeSuggestionProjection>,
        val entries: List<OrganizeEntryProjection> = emptyList(),
        val stale: Boolean,
        val staleIDs: List<String> = emptyList(),
        val proposalID: String = "",
        val autoDelete: OrganizeAutoDeleteProjection? = null,
        val autoDeletedCount: Int = 0,
        val applying: Boolean = false,
        val applyError: String? = null,
        val startCorrelation: String? = null,
        val startReceipt: String? = null,
    )

    data class OrganizeAutoDeleteProjection(
        val status: String,
        val batchID: String?,
    )

    data class OrganizeEntryProjection(
        val id: String,
        val scopeKind: String,
        val status: String,
        val content: String,
        val updatedAt: String,
    )

    data class OrganizeSuggestionProjection(
        val id: String,
        val kind: String,
        val reason: String,
        val canApplyAutomatically: Boolean,
        val memoryIDs: List<String> = emptyList(),
        val preferredMemoryID: String? = null,
    )

    /**
     * Personalization document surface plus the REAL revision history page
     * (`revisionsMeta` from `personalization.get`, continued through
     * `revisionsNextCursor`) and the one open revision read. A revision row
     * is the original `PersonalizationRevisionMeta` — id/revision/source/
     * active flag/timestamp/size/digest; no App-side history store exists.
     * [generateCorrelation]/[generateReceipt] address the REAL accepted
     * generate operation for `personalization.generate.cancel`.
     */
    data class PersonalizationSurface(
        val kind: String = "soul",
        /**
         * True once the INITIAL document read settled in ANY terminal class
         * (see [MemorySurface.loaded]); the page-open recovery read uses it
         * exactly like the Privacy surface uses `summary != null`.
         */
        val loaded: Boolean = false,
        val activeRevision: Int? = null,
        val content: String = "",
        val contentHandle: String? = null,
        /** True while an over-budget active document streams via content.read. */
        val contentLoading: Boolean = false,
        val contentLoadFailed: Boolean = false,
        val automaticUpdatesEnabled: Boolean = false,
        val latestRevision: Int = 0,
        val revisionToken: String = "",
        val generating: Boolean = false,
        val generateError: String? = null,
        val generateCorrelation: String? = null,
        val generateReceipt: String? = null,
        /** Typed save/automatic-update failure; the draft stays recoverable. */
        val saveError: String? = null,
        /** Last REAL generate outcome: "active" or "storedAsDraft". */
        val lastGenerateOutcome: String? = null,
        /** Why it was stored as a draft: activeSlotChanged|sourceChanged|both. */
        val lastGenerateDraftReason: String? = null,
        val revisions: List<RevisionMetaProjection> = emptyList(),
        val revisionsNextCursor: String? = null,
        val revisionsLoadingMore: Boolean = false,
        val openRevision: RevisionReadProjection? = null,
        val revisionReadInFlight: Boolean = false,
        val revisionReadError: String? = null,
        val rollingBack: Boolean = false,
        val rollbackError: String? = null,
    )

    data class RevisionMetaProjection(
        val id: String,
        val revision: Int,
        val source: String,
        val isActive: Boolean,
        val createdAt: String,
        val contentBytes: Int,
        val contentDigest: String,
    )

    /** Result of one `personalization.revision.read` (bounded content). */
    data class RevisionReadProjection(
        val kind: String,
        val revision: Int,
        val source: String,
        val isActive: Boolean,
        val createdAt: String,
        val contentBytes: Int,
        val content: String,
        val digest: String,
    )

    data class UsageSurface(
        val totals: UsageTotalsProjection? = null,
        /**
         * True once the INITIAL read for the current settled dimension
         * settled in ANY terminal class (see [MemorySurface.loaded]).
         */
        val loaded: Boolean = false,
        val byDay: List<UsageDayProjection> = emptyList(),
        val rows: List<UsageBreakdownProjection> = emptyList(),
        val nextCursor: String? = null,
        val loadingMore: Boolean = false,
        /** total | conversation | model | provider (the frozen dimension set). */
        val dimension: String = "total",
    )

    data class UsageTotalsProjection(
        val inputTokens: Long,
        val outputTokens: Long,
        val totalTokens: Long,
        val runs: Long,
        /** Nullable metrics stay null ("not reported"), never an inferred 0. */
        val cacheReadTokens: Long? = null,
        val cacheWriteTokens: Long? = null,
        val reasoningTokens: Long? = null,
        val averageTokensPerSecond: Double? = null,
        val averageTimeToFirstTokenMs: Double? = null,
        val averageDurationMs: Double? = null,
    )

    data class UsageDayProjection(
        val date: String,
        val inputTokens: Long,
        val outputTokens: Long,
        val runs: Long,
    )

    data class UsageBreakdownProjection(
        val id: String,
        val label: String,
        val inputTokens: Long,
        val outputTokens: Long,
        val runs: Long,
        /** Nullable metrics stay null ("not reported"), never an inferred 0. */
        val totalTokens: Long? = null,
        val cacheReadTokens: Long? = null,
        val cacheWriteTokens: Long? = null,
        val reasoningTokens: Long? = null,
        val averageTokensPerSecond: Double? = null,
        val averageTimeToFirstTokenMs: Double? = null,
        val averageDurationMs: Double? = null,
    )

    data class PrivacySurface(
        val summary: PrivacySummaryProjection? = null,
        val historyFailures: List<PrivacyFailureProjection> = emptyList(),
        val modelConfigFailures: List<PrivacyFailureProjection> = emptyList(),
        /** Same-root report-store paging (never content.read). */
        val reportPage: PrivacyReportPage? = null,
        /**
         * The ACTUAL accepted native Root epoch this projection was read
         * under, captured off-main BEFORE the dispatch and re-checked after
         * the reply. Null when no generation is live; never a UI counter and
         * never a fabricated 0.
         */
        val rootEpoch: Long? = null,
        /**
         * The local preview generation this projection established. Bumped
         * on every ACCEPTED summary projection only; an immutable user
         * preview pins this value at tap time, so recomposition or a later
         * refresh can never silently rebind a visible dialog.
         */
        val previewGeneration: Long? = null,
    )

    data class PrivacySummaryProjection(
        val conversationCount: Long,
        val runCount: Long,
        val persistedGrantCount: Long,
        val inMemoryGrantCount: Long,
        val providerCount: Long,
        val modelCount: Long,
        val secretReferenceCount: Long,
        val preferencesSyncRevision: Long,
        /** Null ONLY with [remainingFailure] + partial=true. */
        val remaining: PrivacyRemainingProjection?,
        val remainingFailure: String?,
        val preferencesFailure: String?,
        val partial: Boolean,
        val historyRevision: String,
        val modelConfigRevision: String,
        /**
         * History-clear report truth only: REAL post-execution re-count of
         * the model-config resource family. Null until a model-config clear
         * report lands — never an inferred zero.
         */
        val modelRemaining: PrivacyModelRemainingProjection? = null,
        /**
         * Model-config clear report truth only: typed reason when the
         * post-execution model re-count was unavailable (surfaced ONLY with
         * partial=true). Null when the recount succeeded or no report has
         * settled yet.
         */
        val modelRemainingFailure: String? = null,
        /**
         * Model-config clear report truth only: whether the preference reset
         * actually committed (false = a newer save superseded it, which is
         * NOT a failure). Null until a model-config clear report lands.
         */
        val preferencesReset: Boolean? = null,
        /**
         * History-clear report truth only: REAL owned private-task workspace
         * directory effects from the accepted native lifecycle
         * (removed = actually deleted, absent = already gone — never
         * counted as removed —, deferred = typed refusal/failure kept in
         * `failures`). Null until a history-clear report lands; never
         * invented zeros.
         */
        val workspaceRemoved: Long? = null,
        val workspaceAbsent: Long? = null,
        val workspaceDeferred: Long? = null,
    )

    data class PrivacyRemainingProjection(
        val conversationCount: Long,
        val runCount: Long,
        val persistedGrantCount: Long,
        val inMemoryGrantCount: Long,
    )

    data class PrivacyModelRemainingProjection(
        val providerCount: Long,
        val modelCount: Long,
        val secretReferenceCount: Long,
    )

    data class PrivacyFailureProjection(
        val itemID: String?,
        /** Model-config failures carry the REAL provider id; never dummy. */
        val providerID: String? = null,
        val phase: String,
        val reason: String,
    )

    data class PrivacyReportPage(
        val handle: String,
        val kind: String,
        val items: List<PrivacyFailureProjection>,
        val nextCursor: String?,
        val total: Long,
        val done: Boolean,
    )

    /**
     * Immutable user preview, created ONCE at the first exact tap on a
     * previewed action row. Dialog rendering and recomposition cannot change
     * it; if the summary refresh or the Root changes underneath, the clear
     * is refused with a typed code and the user re-confirms a fresh preview.
     */
    data class PrivacyClearPreview(
        val action: PrivacyClearAction,
        /** `sha256:<hex>` digest the user was shown. */
        val digest: String,
        /** ACTUAL accepted native Root epoch captured with the summary. */
        val sourceNativeEpoch: Long,
        /** Local preview generation the digest belongs to. */
        val previewGeneration: Long,
    )

    /**
     * Owned terminal state of the LAST privacy-clear request, fenced by the
     * exact (action, previewGeneration, sourceNativeEpoch) identity. A late
     * terminal of an older request can neither clear nor rewrite a newer
     * request's status, and a page disposal never cancels the real
     * Application-owned service write.
     */
    data class PrivacyClearStatus(
        val action: PrivacyClearAction,
        val previewGeneration: Long,
        val sourceNativeEpoch: Long,
        val inFlight: Boolean = false,
        /** Typed failure code (never a secret/path/payload). */
        val error: String? = null,
    )

    data class PreferencesSurface(
        val selectedModelID: String? = null,
        val revision: String = "",
        val syncRevision: Long? = null,
    )

    /**
     * True once the one-shot Application-owner start ran. Domain transitions
     * that arrive before it are not replayed here: start() reads the current
     * admission snapshot itself, and replaying would only duplicate reads.
     */
    private val started = java.util.concurrent.atomic.AtomicBoolean(false)

    internal fun start() {
        if (!host.readiness.value.storeReady) return
        started.set(true)
        refreshDefaults()
        refreshPreferences()
        if (host.readiness.value.providerConfigurationAdmitted) {
            // Role choices need the real provider/model rows; load the full
            // role surface alongside the existing default-agent projection.
            roles.refresh()
        }
        // Each settings surface is owned by its OWN settings domain. The
        // old all-or-nothing bundle (any settings domain -> read all four)
        // both attempted commands whose native handler was not registered
        // and permanently skipped a surface that was admitted a moment
        // later.
        refreshAdmittedSettingsSurfaces()
    }

    internal fun stop() {}

    private fun client() = host.commandClient

    /**
     * A settings surface is admitted ONLY by its exact settings domain.
     * Provider-configuration admission is a separate domain fact and never
     * authorizes a settings-domain command: the native command key is
     * registered by the optional privacy/memory/usage extension, so
     * `providerConfigurationAdmitted` would dispatch into an unbound key and
     * leave the surface without data.
     */
    private fun admitted(label: String): Boolean =
        host.readiness.value.storeReady &&
            host.readiness.value.settingsDomainsAdmitted.contains(label)

    /**
     * Loads every settings surface whose own domain is currently admitted.
     * Surfaces that are not yet admitted stay untouched and are recovered by
     * [onSettingsDomainAvailable] when their domain really becomes ready (or
     * by the page-open ensure).
     */
    private fun refreshAdmittedSettingsSurfaces() {
        val admitted = host.readiness.value.settingsDomainsAdmitted
        if ("settings.memory" in admitted) refreshMemory()
        if ("settings.personalization" in admitted) refreshPersonalization()
        if ("settings.usage" in admitted) refreshUsage()
        if ("settings.privacy" in admitted) refreshPrivacySummary()
    }

    /**
     * Native settings-domain transition (transition-driven, not polled).
     * Only a domain that became AVAILABLE for the current generation runs a
     * read; a blocked/retired transition is not treated as usable and never
     * clears an existing projection. A new native epoch republishes every
     * domain, so each surface re-reads against the current root instead of
     * showing a previous generation's summary.
     */
    internal fun onSettingsDomainAvailable(nativeDomain: String) {
        if (!started.get()) return
        when (nativeDomain) {
            "settingsMemory" -> refreshMemory()
            "settingsPersonalization" -> refreshPersonalization()
            "settingsUsage" -> refreshUsage()
            "settingsPrivacy" -> refreshPrivacySummary()
        }
    }

    /**
     * One-shot Settings/Privacy page-open recovery (mirrors DefaultsPage).
     *
     * The host start is the normal first reader, but a page open must not
     * depend on that single process-lifetime attempt: admission can race the
     * first composition, and a lost terminal must be recoverable without a
     * process restart. If the privacy domain is not admitted yet, re-read the
     * REAL native readiness snapshot once and load when it becomes ready;
     * otherwise settle a typed, retryable unavailable state — never leave the
     * summary card silently "Loading…" forever.
     */
    fun ensurePrivacySummaryLoaded() {
        // A page open is a RECOVERY for a surface with no settled data, not a
        // blanket refresh-on-show: real counts already loaded for this
        // process are left alone. A missing surface starts a newer read;
        // readGeneration fences any older in-flight reply from winning.
        // The explicit Retry action also remains available for typed errors.
        if (stateFlow.value.privacy.summary != null) return
        if (admitted("settings.privacy")) {
            refreshPrivacySummary()
            return
        }
        host.scope.launch(host.ioDispatcher) {
            host.refreshDomainReadiness()
            if (admitted("settings.privacy")) {
                refreshPrivacySummary()
            } else {
                update { state ->
                    if (state.privacy.summary == null && state.privacyStatus.error == null) {
                        state.copy(privacyStatus = SurfaceStatus(error = "unavailable"))
                    } else {
                        state
                    }
                }
            }
        }
    }

    /**
     * One-shot Settings/Memory page-open recovery (mirrors
     * [ensurePrivacySummaryLoaded]): the surface `loaded` flag plays the
     * role of Privacy's `summary != null`. A real settled page — even an
     * empty inventory — is never re-read; a settled typed error keeps its
     * Retry; a still-unsettled surface re-reads once, refreshing the real
     * native readiness first when its own domain has not admitted yet.
     */
    fun ensureMemoryLoaded() {
        if (stateFlow.value.memory.loaded) return
        if (admitted("settings.memory")) {
            refreshMemory()
            return
        }
        host.scope.launch(host.ioDispatcher) {
            host.refreshDomainReadiness()
            if (admitted("settings.memory")) {
                refreshMemory()
            } else {
                update { state ->
                    if (!state.memory.loaded && state.memoryStatus.error == null) {
                        state.copy(memoryStatus = SurfaceStatus(error = "unavailable"))
                    } else {
                        state
                    }
                }
            }
        }
    }

    /**
     * One-shot Settings/Personalization page-open recovery (mirrors
     * [ensurePrivacySummaryLoaded]); see [ensureMemoryLoaded].
     */
    fun ensurePersonalizationLoaded() {
        if (stateFlow.value.personalization.loaded) return
        if (admitted("settings.personalization")) {
            refreshPersonalization(stateFlow.value.personalization.kind)
            return
        }
        host.scope.launch(host.ioDispatcher) {
            host.refreshDomainReadiness()
            if (admitted("settings.personalization")) {
                refreshPersonalization(stateFlow.value.personalization.kind)
            } else {
                update { state ->
                    if (!state.personalization.loaded &&
                        state.personalizationStatus.error == null
                    ) {
                        state.copy(personalizationStatus = SurfaceStatus(error = "unavailable"))
                    } else {
                        state
                    }
                }
            }
        }
    }

    /**
     * One-shot Settings/Usage page-open recovery (mirrors
     * [ensurePrivacySummaryLoaded]); see [ensureMemoryLoaded].
     */
    fun ensureUsageLoaded() {
        if (stateFlow.value.usage.loaded) return
        if (admitted("settings.usage")) {
            refreshUsage()
            return
        }
        host.scope.launch(host.ioDispatcher) {
            host.refreshDomainReadiness()
            if (admitted("settings.usage")) {
                refreshUsage()
            } else {
                update { state ->
                    if (!state.usage.loaded && state.usageStatus.error == null) {
                        state.copy(usageStatus = SurfaceStatus(error = "unavailable"))
                    } else {
                        state
                    }
                }
            }
        }
    }

    private inline fun update(transform: (SettingsHostState) -> SettingsHostState) {
        // Independent IO callbacks must not copy an old aggregate state over
        // another surface's settled result. Serialize the whole read/copy/write;
        // transforms are evaluated exactly once (some mint preview epochs).
        synchronized(stateMutationLock) {
            stateFlow.value = transform(stateFlow.value)
        }
    }

    // -------------------------------------------------------------- defaults

    fun refreshDefaults() {
        if (!host.readiness.value.storeReady) return
        update { it.copy(defaultsStatus = SurfaceStatus(loading = true)) }
        host.trackOperation(
            HostCommandRequest(
                command = "config.defaults.get",
                scope = HostScope.ApplicationConfiguration("settings.defaults"),
                stateful = false,
                correlationID = client().correlationID("dget"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    update {
                        it.copy(
                            defaultsStatus = SurfaceStatus(),
                            defaults = SettingsDefaultsSurface(
                                defaultAgentMode = root?.string("values", "defaultAgentMode")
                                    ?: "human",
                                runningInputMode = root?.string("values", "runningInputMode")
                                    ?: "queue",
                                verifyFinalAnswer = root?.obj("values")?.bool("verifyFinalAnswer")
                                    ?: false,
                                explicitDefaultAgentMode = root?.obj("explicit")
                                    ?.bool("defaultAgentMode") ?: false,
                                explicitRunningInputMode = root?.obj("explicit")
                                    ?.bool("runningInputMode") ?: false,
                                explicitVerifyFinalAnswer = root?.obj("explicit")
                                    ?.bool("verifyFinalAnswer") ?: false,
                                revision = root?.string("revision") ?: "",
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(defaultsStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(defaultsStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
    }

    /** Save agent defaults (used by the General page and the composer). */
    fun saveDefaults(
        defaultAgentMode: String? = null,
        runningInputMode: String? = null,
        verifyFinalAnswer: Boolean? = null,
        onOutcome: ((HostOperationOutcome) -> Unit)? = null,
    ): Boolean {
        if (!host.readiness.value.storeReady) return false
        val current = stateFlow.value.defaults
        val values = mutableMapOf<String, JsonElement>()
        defaultAgentMode?.let { values["defaultAgentMode"] = JsonPrimitive(it) }
        runningInputMode?.let { values["runningInputMode"] = JsonPrimitive(it) }
        verifyFinalAnswer?.let { values["verifyFinalAnswer"] = JsonPrimitive(it) }
        if (values.isEmpty()) return false
        host.trackOperation(
            HostCommandRequest(
                command = "config.defaults.save",
                scope = HostScope.ApplicationConfiguration("settings.defaults"),
                stateful = true,
                correlationID = client().correlationID("dsave"),
                revision = HostRevision("settings.defaults", current.revision),
                payload = JsonObject(mapOf("values" to JsonObject(values))),
            ),
        ) { outcome ->
            onOutcome?.invoke(outcome)
            when (outcome) {
                is HostOperationOutcome.Completed -> refreshDefaults()
                is HostOperationOutcome.Rejected -> update {
                    // Revision failures surface typed; no silent overwrite.
                    it.copy(defaultsStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(defaultsStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
        return true
    }

    // -------------------------------------------------------------- memory

    /**
     * Read generations fence every late memory callback. A list refresh, a
     * search query and a candidate page chain each own their generation, so
     * an older page can never append into a newer surface (or republish a
     * cleared search after navigation).
     */
    private val memoryGeneration = java.util.concurrent.atomic.AtomicLong(0)
    private val memorySearchGeneration = java.util.concurrent.atomic.AtomicLong(0)
    private val memoryCandidatesGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Fences ONLY the one owned memory-editor read. Dismissal, a newer row
     * tap and page exit advance it; a late `memory.get` for A can therefore
     * never open an editor after B (or after the page is gone). Unrelated
     * list/search reads keep their own generations.
     */
    private val memoryEditorGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Fences one explicit bulk-delete UI interaction. A new selection,
     * edited selection or cancel supersedes the previous interaction; its
     * late terminal still refreshes the service-owned data but is never
     * delivered into the newer UI.
     */
    private val memoryBulkInteractionGeneration =
        java.util.concurrent.atomic.AtomicLong(0)

    fun refreshMemory() {
        if (!admitted("settings.memory")) {
            // The memory domain is not (yet) the owner of this surface.
            // Settle a typed, retryable state instead of leaving the default
            // loading flag forever; a real later admission (or the page-open
            // ensure) re-reads it.
            update { state ->
                if (!state.memory.loaded && state.memoryStatus.error == null) {
                    state.copy(memoryStatus = SurfaceStatus(error = "unavailable"))
                } else {
                    state
                }
            }
            return
        }
        val generation = memoryGeneration.incrementAndGet()
        update {
            it.copy(
                memoryStatus = SurfaceStatus(loading = true),
                memory = it.memory.copy(loadingMore = false),
            )
        }
        fetchMemoryPage(generation, cursor = null, append = false)
    }

    /**
     * One REAL `memory.list` continuation. The original command pages the
     * store within 48KiB; without this action every entry after the first
     * page stayed unreachable, so the inventory could never be fully read.
     */
    fun loadMoreMemory() {
        if (!admitted("settings.memory")) return
        val surface = stateFlow.value.memory
        val cursor = surface.nextCursor ?: return
        if (surface.loadingMore || stateFlow.value.memoryStatus.loading) return
        val generation = memoryGeneration.get()
        update { it.copy(memory = it.memory.copy(loadingMore = true)) }
        fetchMemoryPage(generation, cursor, append = true)
    }

    private fun fetchMemoryPage(generation: Long, cursor: String?, append: Boolean) {
        val payload = buildMap<String, JsonElement> {
            put("limit", JsonPrimitive(50))
            cursor?.let { put("cursor", JsonPrimitive(it)) }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.list",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("mlist"),
                payload = JsonObject(payload),
            ),
        ) { outcome ->
            // A refresh/search that started later owns the surface now.
            if (memoryGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    if (!append && root == null) {
                        // A valueless Closed completion is a LOST value, not
                        // an empty inventory: settling it as "no memories"
                        // would be a fabricated empty (Privacy's
                        // summaryUnavailable analogue).
                        update {
                            it.copy(
                                memoryStatus = SurfaceStatus(error = "listUnavailable"),
                                memory = it.memory.copy(loaded = true, loadingMore = false),
                            )
                        }
                        return@trackOperation
                    }
                    val page = (root?.get("entries") as? JsonArray)
                        ?.mapNotNull { e -> decodeMemoryEntry(e as? JsonObject) }
                        ?: emptyList()
                    val rawNext = root?.string("nextCursor")
                    // Strict progress: a repeated cursor would loop forever,
                    // so the chain ends honestly instead of re-reading it.
                    val next = rawNext?.takeUnless { append && it == cursor }
                    update {
                        it.copy(
                            memoryStatus = SurfaceStatus(),
                            memory = it.memory.copy(
                                entries = if (append) {
                                    mergeMemoryEntries(it.memory.entries, page)
                                } else {
                                    page
                                },
                                nextCursor = next,
                                loaded = if (append) it.memory.loaded else true,
                                loadingMore = false,
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(
                        memoryStatus = SurfaceStatus(error = outcome.code),
                        memory = it.memory.copy(
                            loaded = if (append) it.memory.loaded else true,
                            loadingMore = false,
                        ),
                    )
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(
                        memoryStatus = SurfaceStatus(error = outcome.code),
                        memory = it.memory.copy(
                            loaded = if (append) it.memory.loaded else true,
                            loadingMore = false,
                        ),
                    )
                }
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> {
                    // A cancelled/replaced terminal of the INITIAL read must
                    // settle typed and retryable — never leave the surface on
                    // the default loading flag forever. Continuations only
                    // clear their spinner.
                    val code = if (outcome == HostOperationOutcome.Cancelled) {
                        "cancelled"
                    } else {
                        "superseded"
                    }
                    update {
                        if (append) {
                            it.copy(memory = it.memory.copy(loadingMore = false))
                        } else {
                            it.copy(
                                memoryStatus = SurfaceStatus(error = code),
                                memory = it.memory.copy(loaded = true, loadingMore = false),
                            )
                        }
                    }
                }
            }
        }
    }

    private fun mergeMemoryEntries(
        existing: List<MemoryEntryProjection>,
        next: List<MemoryEntryProjection>,
    ): List<MemoryEntryProjection> {
        val merged = LinkedHashMap<String, MemoryEntryProjection>()
        existing.forEach { merged[it.id] = it }
        next.forEach { merged[it.id] = it }
        return merged.values.toList()
    }

    /**
     * Opens THE one owned memory editor from a FRESH `memory.get`. The list
     * projection may be pages old, and a background refresh may replace the
     * row at any time; the editor therefore owns this reply's content and
     * full-row digest for its whole lifetime. A failed/superseded read
     * never opens a dialog (the old code ignored the false result), and a
     * newer tap/dismissal/page exit fences the late reply by generation.
     */
    fun openMemoryEditor(id: String) {
        if (id.isBlank()) return
        val generation = memoryEditorGeneration.incrementAndGet()
        if (!admitted("settings.memory")) {
            update {
                it.copy(
                    memoryEditor = null,
                    memoryEditorLoading = false,
                    memoryEditorError = "unavailable",
                    memoryEditorMutation = null,
                )
            }
            return
        }
        update {
            it.copy(
                memoryEditor = null,
                memoryEditorLoading = true,
                memoryEditorError = null,
                // The new open owns the surface: any typed terminal of the
                // previous editor belongs to that older generation now.
                memoryEditorMutation = null,
            )
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.get",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("mget"),
                payload = JsonObject(mapOf("id" to JsonPrimitive(id))),
            ),
        ) { outcome ->
            // A newer row tap / dismissal / page exit owns the editor now.
            if (memoryEditorGeneration.get() != generation) return@trackOperation
            if (outcome !is HostOperationOutcome.Completed) {
                val code = when (outcome) {
                    is HostOperationOutcome.Rejected -> outcome.code
                    is HostOperationOutcome.Failed -> outcome.code
                    else -> "memoryReadFailed"
                }
                update {
                    it.copy(memoryEditorLoading = false, memoryEditorError = code)
                }
                return@trackOperation
            }
            val fresh = decodeMemoryEntry(outcome.value as? JsonObject)
            if (fresh == null ||
                !fresh.id.equals(id, ignoreCase = true) ||
                fresh.revision.isBlank()
            ) {
                // Without a real full-row digest a save/delete could not be
                // CAS-fenced; refuse to open instead of drafting blind.
                update {
                    it.copy(
                        memoryEditorLoading = false,
                        memoryEditorError = "memoryReadMalformed",
                    )
                }
                return@trackOperation
            }
            update {
                // Publish ONLY the owned editor snapshot: an editor read is
                // not a list refresh, so it must not race/overwrite a newer
                // list or search projection with this possibly older page.
                it.copy(
                    memoryEditorLoading = false,
                    memoryEditor = MemoryEditorProjection(fresh, generation),
                    memoryEditorError = null,
                    memoryEditorMutation = null,
                )
            }
        }
    }

    /** Closes the owned editor and fences any in-flight `memory.get`. */
    fun closeMemoryEditor() {
        memoryEditorGeneration.incrementAndGet()
        update {
            it.copy(
                memoryEditor = null,
                memoryEditorLoading = false,
                memoryEditorError = null,
                memoryEditorMutation = null,
            )
        }
    }

    fun searchMemory(query: String) {
        if (!admitted("settings.memory")) return
        if (query.isBlank()) {
            clearMemorySearch()
            return
        }
        val generation = memorySearchGeneration.incrementAndGet()
        update {
            it.copy(
                memory = it.memory.copy(
                    searchActive = true,
                    searchQuery = query,
                    searchItems = emptyList(),
                    searchHandle = null,
                    searchNextCursor = null,
                    searchHasMore = false,
                    searchLoadingMore = false,
                    searchChangedCount = 0,
                ),
            )
        }
        dispatchMemorySearch(generation, query, handle = null, cursor = null)
    }

    /**
     * One handle+cursor continuation of the SAME search. The contract
     * requires the process-lifetime handle and never re-runs recall or
     * reinforcement for a page; without this the results were capped at the
     * first 20 items.
     */
    fun loadMoreMemorySearch() {
        if (!admitted("settings.memory")) return
        val surface = stateFlow.value.memory
        val handle = surface.searchHandle ?: return
        val cursor = surface.searchNextCursor ?: return
        if (!surface.searchHasMore || surface.searchLoadingMore) return
        val generation = memorySearchGeneration.get()
        update { it.copy(memory = it.memory.copy(searchLoadingMore = true)) }
        dispatchMemorySearch(generation, surface.searchQuery, handle, cursor)
    }

    private fun dispatchMemorySearch(
        generation: Long,
        query: String,
        handle: String?,
        cursor: String?,
    ) {
        val payload = buildMap<String, JsonElement> {
            put("query", JsonPrimitive(query))
            put("limit", JsonPrimitive(20))
            handle?.let { put("handle", JsonPrimitive(it)) }
            cursor?.let { put("cursor", JsonPrimitive(it)) }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.search",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("msearch"),
                payload = JsonObject(payload),
            ),
        ) { outcome ->
            if (memorySearchGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val projected = (root?.get("items") as? JsonArray)
                        ?.mapNotNull { e -> decodeSearchItem(e as? JsonObject) }
                        ?: emptyList()
                    val nextHandle = root?.string("searchHandle")
                    val rawNext = root?.string("nextCursor")
                    val hasMore = root?.bool("hasMore") ?: false
                    val nextCursor = rawNext?.takeUnless {
                        cursor != null && it == cursor
                    }
                    update { state ->
                        val items = if (handle == null) {
                            projected
                        } else {
                            val merged = LinkedHashMap<String, MemorySearchItemProjection>()
                            state.memory.searchItems.forEach { merged[it.id] = it }
                            projected.forEach { merged[it.id] = it }
                            merged.values.toList()
                        }
                        state.copy(
                            memoryStatus = SurfaceStatus(),
                            memory = state.memory.copy(
                                searchItems = items,
                                searchActive = true,
                                searchHandle = nextHandle ?: handle,
                                searchNextCursor = nextCursor,
                                searchHasMore = hasMore && nextCursor != null &&
                                    (nextHandle ?: handle) != null,
                                searchLoadingMore = false,
                                searchChangedCount = items.count {
                                    it.deleted || it.current == null
                                },
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(
                        memoryStatus = SurfaceStatus(error = outcome.code),
                        memory = it.memory.copy(searchLoadingMore = false, searchHasMore = false),
                    )
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(
                        memoryStatus = SurfaceStatus(error = outcome.code),
                        memory = it.memory.copy(searchLoadingMore = false, searchHasMore = false),
                    )
                }
                HostOperationOutcome.Cancelled -> update {
                    it.copy(
                        memoryStatus = SurfaceStatus(error = "cancelled"),
                        memory = it.memory.copy(searchLoadingMore = false, searchHasMore = false),
                    )
                }
                HostOperationOutcome.Superseded -> update {
                    it.copy(
                        memoryStatus = SurfaceStatus(error = "superseded"),
                        memory = it.memory.copy(searchLoadingMore = false, searchHasMore = false),
                    )
                }
            }
        }
    }

    fun clearMemorySearch() {
        memorySearchGeneration.incrementAndGet()
        update {
            it.copy(
                memory = it.memory.copy(
                    searchItems = emptyList(),
                    searchActive = false,
                    searchQuery = "",
                    searchHandle = null,
                    searchNextCursor = null,
                    searchHasMore = false,
                    searchLoadingMore = false,
                    searchChangedCount = 0,
                ),
            )
        }
    }

    /**
     * Opens ONE owned add-memory dialog. Every open gets a new generation,
     * so a late `memory.add` terminal for a cancelled/replaced dialog can
     * neither close nor fill the new one.
     */
    fun openAddMemory() {
        update {
            val current = it.memoryAdd
            it.copy(
                memoryAdd = MemoryAddSurface(
                    open = true,
                    generation = current.generation + 1,
                ),
            )
        }
    }

    /** Dismisses the dialog and fences any in-flight add result. */
    fun dismissAddMemory() {
        update {
            val current = it.memoryAdd
            it.copy(
                memoryAdd = current.copy(
                    open = false,
                    generation = current.generation + 1,
                    inFlight = false,
                    failure = null,
                ),
            )
        }
    }

    /**
     * ONE owned `memory.add` with the ORIGINAL grammar (`stateful`,
     * `createIntent`, `payload.content` + `payload.scope.kind`). The dialog
     * stays open with the user's draft on a typed refusal and on an
     * unconfirmed transport result (never claiming a success the writer did
     * not report); only a completed add closes it. The terminal publishes
     * only while the SAME dialog generation is still open, so the real
     * write/data refresh of an older dialog never touches a newer one.
     */
    fun submitAddMemory(content: String, scopeKind: String) {
        if (content.isBlank()) return
        val add = stateFlow.value.memoryAdd
        if (!add.open || add.inFlight) return
        if (!admitted("settings.memory")) {
            update {
                it.copy(memoryAdd = it.memoryAdd.copy(
                    failure = MemoryMutationOutcome.Refused("unavailable")))
            }
            return
        }
        val generation = add.generation
        update {
            it.copy(memoryAdd = it.memoryAdd.copy(
                inFlight = true,
                failure = null,
            ))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.add",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("madd"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "content" to JsonPrimitive(content),
                        "scope" to JsonObject(mapOf("kind" to JsonPrimitive(scopeKind))),
                    ),
                ),
            ),
        ) { outcome ->
            val result = mutationOutcome(outcome)
            // Applied and Unconfirmed both need a real list read so the user
            // can check whether the memory landed; only a typed refusal
            // proves nothing changed and needs no refresh.
            if (result !is MemoryMutationOutcome.Refused) refreshMemory()
            update { state ->
                val current = state.memoryAdd
                when {
                    // A dismissed/replaced dialog owns the UI now; the add
                    // itself (and any list refresh above) still happened.
                    !current.open || current.generation != generation -> state
                    result is MemoryMutationOutcome.Applied -> state.copy(
                        memoryAdd = current.copy(
                            open = false,
                            inFlight = false,
                            failure = null,
                        ),
                    )
                    else -> state.copy(
                        memoryAdd = current.copy(
                            inFlight = false,
                            failure = result,
                        ),
                    )
                }
            }
        }
    }

    /**
     * Save ONE memory from its editor draft using the row's FROZEN base
     * revision (the fresh `memory.get` digest captured at open). The live
     * list row is never consulted: a background refresh may already carry a
     * newer digest, and pairing this draft with it would silently overwrite
     * an external edit. A typed stale refusal keeps the draft and the old
     * base; it is never auto-upgraded to a newer CAS token.
     */
    fun updateMemory(
        id: String,
        revision: String,
        content: String?,
        importance: Double?,
        isPinned: Boolean?,
        onOutcome: (MemoryMutationOutcome) -> Unit,
    ) {
        if (!admitted("settings.memory")) {
            onOutcome(MemoryMutationOutcome.Refused("unavailable"))
            return
        }
        if (id.isBlank() || revision.isBlank()) {
            onOutcome(MemoryMutationOutcome.Refused("noBaseRevision"))
            return
        }
        val changes = mutableMapOf<String, JsonElement>()
        content?.let { changes["content"] = JsonPrimitive(it) }
        importance?.let { changes["importance"] = JsonPrimitive(it) }
        isPinned?.let { changes["isPinned"] = JsonPrimitive(it) }
        if (changes.isEmpty()) {
            onOutcome(MemoryMutationOutcome.Applied)
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.update",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("mupd"),
                revision = HostRevision("memory.$id", revision),
                payload = JsonObject(
                    mapOf("id" to JsonPrimitive(id), "changes" to JsonObject(changes)),
                ),
            ),
        ) { outcome ->
            onOutcome(mutationOutcome(outcome))
            if (outcome is HostOperationOutcome.Completed) refreshMemory()
        }
    }

    fun deleteMemory(
        id: String,
        revision: String,
        onOutcome: (MemoryMutationOutcome) -> Unit,
    ) {
        if (!admitted("settings.memory")) {
            onOutcome(MemoryMutationOutcome.Refused("unavailable"))
            return
        }
        if (id.isBlank() || revision.isBlank()) {
            onOutcome(MemoryMutationOutcome.Refused("noBaseRevision"))
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.delete",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("mdel"),
                revision = HostRevision("memory.$id", revision),
                payload = JsonObject(mapOf("id" to JsonPrimitive(id))),
            ),
        ) { outcome ->
            onOutcome(mutationOutcome(outcome))
            if (outcome is HostOperationOutcome.Completed) refreshMemory()
        }
    }

    /** True only while [editor]'s generation still owns the open editor. */
    private fun ownsMemoryEditor(editor: MemoryEditorProjection): Boolean =
        memoryEditorGeneration.get() == editor.generation &&
            stateFlow.value.memoryEditor?.generation == editor.generation

    /**
     * ONE owned editor save. The request uses the editor's FROZEN row digest
     * (captured at open), and the terminal publishes only while the SAME
     * editor generation still owns the surface. A late result for a
     * dismissed/replaced editor keeps its real write and the global data
     * refresh, but never closes (or writes an error into) a newer editor —
     * including an ABA re-open of the same row, which gets a new generation.
     */
    fun saveMemoryEditor(
        editor: MemoryEditorProjection,
        content: String,
        isPinned: Boolean,
    ) {
        if (!ownsMemoryEditor(editor)) return
        update { it.copy(memoryEditorMutation = null) }
        updateMemory(
            editor.entry.id,
            editor.entry.revision,
            content,
            null,
            isPinned,
        ) { result ->
            publishMemoryEditorMutation(
                editor,
                MemoryEditorOperation.Save,
                result,
            )
        }
    }

    /** ONE owned editor delete with the same generation fence as save. */
    fun deleteMemoryEditor(editor: MemoryEditorProjection) {
        if (!ownsMemoryEditor(editor)) return
        update { it.copy(memoryEditorMutation = null) }
        deleteMemory(editor.entry.id, editor.entry.revision) { result ->
            publishMemoryEditorMutation(
                editor,
                MemoryEditorOperation.Delete,
                result,
            )
        }
    }

    private fun publishMemoryEditorMutation(
        editor: MemoryEditorProjection,
        operation: MemoryEditorOperation,
        outcome: MemoryMutationOutcome,
    ) {
        // The service-owned write already ran; fence only the UI
        // publication by the originating editor generation.
        if (!ownsMemoryEditor(editor)) return
        if (outcome is MemoryMutationOutcome.Applied) {
            // Close ONLY the generation that dispatched the write. The
            // atomic bump is conditional so a close that races a newer
            // open can never overwrite the newer generation; the state
            // update re-checks the published editor as well.
            if (memoryEditorGeneration.get() == editor.generation) {
                memoryEditorGeneration.incrementAndGet()
            }
            update { state ->
                if (state.memoryEditor?.generation != editor.generation) {
                    state
                } else {
                    state.copy(
                        memoryEditor = null,
                        memoryEditorLoading = false,
                        memoryEditorError = null,
                        memoryEditorMutation = null,
                    )
                }
            }
            return
        }
        update { state ->
            if (state.memoryEditor?.generation != editor.generation) {
                state
            } else {
                state.copy(
                    memoryEditorMutation = MemoryEditorMutation(
                        generation = editor.generation,
                        operation = operation,
                        outcome = outcome,
                    ),
                )
            }
        }
    }

    private fun mutationOutcome(outcome: HostOperationOutcome): MemoryMutationOutcome =
        when (outcome) {
            is HostOperationOutcome.Completed -> MemoryMutationOutcome.Applied
            // A writer refusal (including the in-transaction digest CAS)
            // proves nothing was written.
            is HostOperationOutcome.Rejected -> MemoryMutationOutcome.Refused(outcome.code)
            // A transport/ack failure after submission cannot prove that the
            // commit did not happen; the UI must not claim otherwise.
            is HostOperationOutcome.Failed -> MemoryMutationOutcome.Unconfirmed(outcome.code)
            HostOperationOutcome.Cancelled -> MemoryMutationOutcome.Unconfirmed("cancelled")
            HostOperationOutcome.Superseded -> MemoryMutationOutcome.Unconfirmed("superseded")
        }

    /**
     * Validates the WHOLE explicit selection and freezes one bulk-delete
     * intent (batchID + syncRevision + every id/digest) at confirmation
     * opening. Invalid or duplicate entries are refused typed — they are
     * never filtered into a smaller "successful" batch. Entry ids/digests
     * must already be resolved by the caller; a selection that no longer
     * matches the visible rows must be refreshed rather than silently
     * narrowed.
     */
    fun prepareMemoryBulkDelete(
        entries: List<Pair<String, String>>,
    ): MemoryBulkDeletePreparation {
        val invalid = validateBulkDeleteTargets(entries)
        if (invalid != null) return MemoryBulkDeletePreparation.Invalid(invalid)
        return MemoryBulkDeletePreparation.Ready(
            MemoryBulkDeleteIntent(
                batchID = java.util.UUID.randomUUID().toString(),
                // Original MemoryMaintenance ordering value (milliseconds).
                // It is a tombstone ordering field, never a CAS precondition,
                // but it belongs to THIS intent identity and is reused on a
                // retry of the same uncertain write.
                syncRevision = System.currentTimeMillis(),
                entries = entries.map { (id, digest) ->
                    MemoryDeleteTarget(id = id, digest = digest)
                },
            ),
        )
    }

    /**
     * Starts ONE explicit bulk-delete UI interaction. A new selection,
     * edited selection or cancel supersedes the previous interaction; its
     * in-flight terminal is then delivered only as a service-owned data
     * refresh, never into the newer selection/failure state.
     */
    fun beginMemoryBulkInteraction(): MemoryBulkInteraction =
        MemoryBulkInteraction(memoryBulkInteractionGeneration.incrementAndGet())

    /**
     * One REAL `memory.delete.bulk` create-intent batch from a FROZEN
     * intent. The durable ledger is keyed by the client-proposed batchID, so
     * retrying the SAME uncertain write reuses the same identity (a new
     * batchID would be a different write). Each entry carries the full-row
     * digest captured at intent opening; a stale digest fails the whole
     * batch typed (all-or-nothing) and nothing is deleted.
     *
     * [interaction] is the UI interaction that dispatched this write. A
     * completed write always refreshes the real list, but the typed terminal
     * is delivered to the page ONLY while that interaction is still current:
     * a newer selection/intent must never be dismissed or rewritten by a
     * late result of an older one.
     */
    fun bulkDeleteMemory(
        intent: MemoryBulkDeleteIntent,
        interaction: MemoryBulkInteraction,
        onOutcome: (MemoryMutationOutcome) -> Unit,
    ) {
        if (!admitted("settings.memory")) {
            onOutcome(MemoryMutationOutcome.Refused("unavailable"))
            return
        }
        val invalid = validateBulkDeleteTargets(
            intent.entries.map { it.id to it.digest },
        )
        if (invalid != null || intent.batchID.isBlank() || intent.syncRevision < 0L) {
            onOutcome(MemoryMutationOutcome.Refused(invalid ?: "invalidIntent"))
            return
        }
        val payload = JsonObject(
            mapOf(
                "batchID" to JsonPrimitive(intent.batchID),
                "syncRevision" to JsonPrimitive(intent.syncRevision),
                "entries" to JsonArray(intent.entries.map { target ->
                    JsonObject(
                        mapOf(
                            "id" to JsonPrimitive(target.id),
                            "expectedDigest" to JsonPrimitive(target.digest),
                        ),
                    )
                }),
            ),
        )
        host.trackOperation(
            HostCommandRequest(
                command = "memory.delete.bulk",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("mdbulk"),
                createIntent = true,
                payload = payload,
            ),
        ) { outcome ->
            val result = mutationOutcome(outcome)
            if (outcome is HostOperationOutcome.Completed) refreshMemory()
            if (memoryBulkInteractionGeneration.get() == interaction.generation) {
                onOutcome(result)
            }
        }
    }

    /** Null when the whole target list is valid, else a typed refusal code. */
    private fun validateBulkDeleteTargets(entries: List<Pair<String, String>>): String? {
        if (entries.isEmpty()) return "emptySelection"
        if (entries.size > BULK_DELETE_LIMIT) return "bulkLimitExceeded"
        if (entries.any { (id, digest) -> id.isBlank() || digest.isBlank() }) {
            return "invalidSelection"
        }
        val ids = entries.map { it.first }
        if (ids.toSet().size != ids.size) return "duplicateSelection"
        return null
    }

    fun listCandidates() {
        if (!admitted("settings.memory")) return
        val generation = memoryCandidatesGeneration.incrementAndGet()
        update {
            it.copy(memory = it.memory.copy(candidatesLoadingMore = false))
        }
        fetchCandidatePage(generation, cursor = null, append = false)
    }

    /** Bounded continuation of the SAME candidate list (expiry sweep runs once). */
    fun loadMoreCandidates() {
        if (!admitted("settings.memory")) return
        val surface = stateFlow.value.memory
        val cursor = surface.candidatesNextCursor ?: return
        if (surface.candidatesLoadingMore) return
        val generation = memoryCandidatesGeneration.get()
        update { it.copy(memory = it.memory.copy(candidatesLoadingMore = true)) }
        fetchCandidatePage(generation, cursor, append = true)
    }

    private fun fetchCandidatePage(generation: Long, cursor: String?, append: Boolean) {
        val payload = buildMap<String, JsonElement> {
            put("limit", JsonPrimitive(50))
            cursor?.let { put("cursor", JsonPrimitive(it)) }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.candidates.list",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("mcand"),
                payload = JsonObject(payload),
            ),
        ) { outcome ->
            if (memoryCandidatesGeneration.get() != generation) return@trackOperation
            if (outcome !is HostOperationOutcome.Completed) {
                update { it.copy(memory = it.memory.copy(candidatesLoadingMore = false)) }
                return@trackOperation
            }
            val root = outcome.value as? JsonObject
            val page = (root?.get("candidates") as? JsonArray)
                ?.mapNotNull { c -> decodeCandidate(c as? JsonObject) }
                ?: emptyList()
            val rawNext = root?.string("nextCursor")
            val next = rawNext?.takeUnless { append && it == cursor }
            update { state ->
                val merged = LinkedHashMap<String, MemoryCandidateProjection>()
                if (append) state.memory.candidates.forEach { merged[it.id] = it }
                page.forEach { merged[it.id] = it }
                state.copy(
                    memory = state.memory.copy(
                        candidates = merged.values.toList(),
                        candidatesNextCursor = next,
                        // The expiry sweep runs in the FIRST page's writer
                        // transaction; a continuation keeps that disclosure.
                        candidatesSweepApplied = (root?.bool("expiredSweepApplied") ?: false) ||
                            (append && state.memory.candidatesSweepApplied),
                        candidatesLoadingMore = false,
                    ),
                )
            }
        }
    }

    fun resolveCandidate(id: String, revision: String, activate: Boolean, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.candidate.resolve",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("mres"),
                revision = HostRevision("memory.candidate.$id", revision),
                payload = JsonObject(
                    mapOf("id" to JsonPrimitive(id), "activate" to JsonPrimitive(activate)),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    listCandidates()
                    refreshMemory()
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun startOrganize(includeSemantic: Boolean, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
            return
        }
        // The start owns ONE correlation for its whole lifetime: the accepted
        // operation receipt (captured via onAccepted) plus this correlation
        // address the REAL operation for memory.organize.cancel — the
        // mailbox re-issues the same receipt for the same correlation.
        val correlation = client().correlationID("morg")
        // Admission must have an owner before onAccepted publishes its receipt.
        // A new start retires the previous proposal and its cancel identity.
        update { state ->
            state.copy(memory = state.memory.copy(organize = OrganizeSurface(
                proposalHandle = "", scannedCount = 0, suggestions = emptyList(),
                stale = false, startCorrelation = correlation,
            )))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.organize.start",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = correlation,
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "mode" to JsonPrimitive("reviewFirst"),
                        "includeSemantic" to JsonPrimitive(includeSemantic),
                    ),
                ),
            ),
            onAccepted = { receipt ->
                update { state ->
                    state.memory.organize?.let { organize ->
                        if (organize.startCorrelation != correlation) return@update state
                        state.copy(
                            memory = state.memory.copy(
                                organize = organize.copy(startReceipt = receipt),
                            ),
                        )
                    } ?: state
                }
            },
        ) { outcome ->
            if (stateFlow.value.memory.organize?.startCorrelation != correlation) {
                return@trackOperation
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val handle = root?.string("proposalHandle")
                    if (handle != null) {
                        update {
                            it.copy(
                                memory = it.memory.copy(
                                    organize = OrganizeSurface(
                                        proposalHandle = handle,
                                        scannedCount = root.long("scannedCount")?.toInt() ?: 0,
                                        suggestions = emptyList(),
                                        stale = root.bool("proposalStale") ?: false,
                                        autoDeletedCount = root.long("autoDeletedCount")
                                            ?.toInt() ?: 0,
                                        startCorrelation = correlation,
                                        startReceipt = it.memory.organize?.startReceipt,
                                    ),
                                ),
                            )
                        }
                        readOrganizeProposal(handle, null)
                        onOutcome(null)
                    } else {
                        onOutcome("organize_malformed")
                    }
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    /**
     * Reads the proposal page (and, via the returned `nextCursor`, every
     * remaining bounded page) so suggestions AND the entry summaries they
     * reference are complete before review. Late pages for a REPLACED
     * proposal handle are dropped (a newer startOrganize owns the surface).
     */
    fun readOrganizeProposal(handle: String, cursor: String?) {
        if (!admitted("settings.memory")) return
        readOrganizeProposalPage(handle, cursor, pages = 0,
            accumulatedSuggestions = ArrayList(), accumulatedEntries = ArrayList())
    }

    private fun readOrganizeProposalPage(
        handle: String,
        cursor: String?,
        pages: Int,
        accumulatedSuggestions: MutableList<OrganizeSuggestionProjection>,
        accumulatedEntries: MutableList<OrganizeEntryProjection>,
    ) {
        // Hard page bound: the proposal is budget-paged by the producer;
        // a malformed cursor can never loop the host forever.
        if (pages >= 64) return
        val payload = buildMap<String, JsonElement> {
            put("handle", JsonPrimitive(handle))
            cursor?.let { put("cursor", JsonPrimitive(it)) }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.organize.proposal.read",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("mprop"),
                payload = JsonObject(payload),
            ),
        ) { outcome ->
            if (outcome !is HostOperationOutcome.Completed) return@trackOperation
            val root = outcome.value as? JsonObject ?: return@trackOperation
            val current = stateFlow.value.memory.organize
            // Fence: a newer organize (different handle) owns the surface.
            if (current == null || current.proposalHandle != handle) return@trackOperation
            (root.get("suggestions") as? JsonArray)
                ?.mapNotNullTo(accumulatedSuggestions) { decodeSuggestion(it as? JsonObject) }
            (root.get("entries") as? JsonArray)
                ?.mapNotNullTo(accumulatedEntries) { decodeOrganizeEntry(it as? JsonObject) }
            val next = root.string("nextCursor")
            if (next != null) {
                readOrganizeProposalPage(handle, next, pages + 1,
                    accumulatedSuggestions, accumulatedEntries)
                return@trackOperation
            }
            val autoDelete = root.obj("autoDelete")?.let { a ->
                OrganizeAutoDeleteProjection(
                    status = a.string("status") ?: "none",
                    batchID = a.string("batchID"),
                )
            }
            update {
                it.copy(
                    memory = it.memory.copy(
                        organize = current.copy(
                            scannedCount = root.long("scannedCount")?.toInt()
                                ?: current.scannedCount,
                            suggestions = accumulatedSuggestions.toList(),
                            entries = accumulatedEntries.toList(),
                            stale = root.bool("stale") ?: false,
                            staleIDs = (root.get("staleIDs") as? JsonArray)
                                ?.mapNotNull { s -> (s as? JsonPrimitive)?.contentOrNull }
                                ?: emptyList(),
                            proposalID = root.string("proposalID") ?: "",
                            autoDelete = autoDelete,
                        ),
                    ),
                )
            }
        }
    }

    /**
     * Applies ONE proposal suggestion through the original batch ledger:
     * `{handle, suggestionID, batchID, syncRevision}` where batchID is a
     * fresh client-proposed ledger identity per attempt and syncRevision is
     * the tombstone ordering value (the original semantic: wall-clock
     * millis, NEVER a CAS precondition). The native transaction re-checks
     * every referenced row digest against the generation snapshot and
     * refuses with zero mutation on stale/missing — a typed failure here
     * never retries destructively; the user reruns organize instead.
     */
    fun applyOrganizeSuggestion(suggestionID: String, onOutcome: (String?) -> Unit) {
        val organize = stateFlow.value.memory.organize
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
            return
        }
        if (organize == null || organize.stale || organize.proposalHandle.isBlank()) {
            onOutcome(if (organize?.stale == true) "staleProposal" else "noProposal")
            return
        }
        val handle = organize.proposalHandle
        val fencedHandle = handle
        update {
            it.copy(memory = it.memory.copy(
                organize = it.memory.organize?.copy(applying = true, applyError = null),
            ))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.organize.apply",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("mapply"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "handle" to JsonPrimitive(handle),
                        "suggestionID" to JsonPrimitive(suggestionID),
                        "batchID" to JsonPrimitive(java.util.UUID.randomUUID().toString()),
                        "syncRevision" to JsonPrimitive(System.currentTimeMillis()),
                    ),
                ),
            ),
        ) { outcome ->
            // Fence: a replaced proposal owns the surface now.
            val current = stateFlow.value.memory.organize
            if (current == null || current.proposalHandle != fencedHandle) {
                onOutcome("superseded")
                return@trackOperation
            }
            update {
                it.copy(memory = it.memory.copy(
                    organize = it.memory.organize?.copy(applying = false),
                ))
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    // The ledger answered (applied | alreadyApplied); the
                    // entries the suggestion deleted are gone — re-read both
                    // surfaces truthfully.
                    refreshMemory()
                    readOrganizeProposal(fencedHandle, null)
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> {
                    update {
                        it.copy(memory = it.memory.copy(
                            organize = it.memory.organize?.copy(applyError = outcome.code),
                        ))
                    }
                    onOutcome(outcome.code)
                }
                is HostOperationOutcome.Failed -> {
                    update {
                        it.copy(memory = it.memory.copy(
                            organize = it.memory.organize?.copy(applyError = outcome.code),
                        ))
                    }
                    onOutcome(outcome.code)
                }
                else -> onOutcome("cancelled")
            }
        }
    }

    /**
     * Cancels the REAL accepted organize operation. The cancel envelope
     * reuses the START correlation: while the operation is still queued or
     * active, the mailbox re-issues the SAME operation receipt the facade's
     * cancel window is keyed on, so the native cancel marks the actual
     * operation (a fresh correlation would mint a new receipt and cancel
     * nothing). The cancel is submitted WITHOUT its own effect stream — the
     * START operation's own stream owns the terminal and reports the REAL
     * canceled{phase}/completed{phase} outcome. If the queue admission
     * returns a DIFFERENT receipt, the operation already settled and there
     * is nothing to cancel — an honest typed answer, never a fake success.
     */
    fun cancelOrganize(onOutcome: (String?) -> Unit) {
        val organize = stateFlow.value.memory.organize
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
            return
        }
        val correlation = organize?.startCorrelation
        val receipt = organize?.startReceipt
        if (organize == null || correlation == null || receipt == null) {
            onOutcome("noActiveOrganize")
            return
        }
        host.scope.launch(host.ioDispatcher) {
            when (val submitted = client().submit(
                HostCommandRequest(
                    command = "memory.organize.cancel",
                    scope = HostScope.ApplicationConfiguration("memory"),
                    stateful = false,
                    correlationID = correlation,
                ),
            )) {
                is HostSubmitResult.Accepted -> {
                    if (submitted.operationReceiptID == receipt) {
                        // The cancel reached the real operation; its terminal
                        // (delivered on this operation's own stream) owns
                        // the cancelled/finished state.
                        onOutcome(null)
                    } else {
                        onOutcome("noActiveOrganize")
                    }
                }
                is HostSubmitResult.Rejected -> onOutcome(submitted.reason)
                HostSubmitResult.Superseded -> onOutcome("superseded")
            }
        }
    }

    // ------------------------------------------------------- personalization

    /**
     * Reads the personalization document and the REAL revision history page
     * (`revisionsMeta` + `revisionsNextCursor`). With [revisionsCursor] the
     * history page is APPENDED to the current surface (the cursor is the
     * original bounded continuation from the previous reply); without it
     * the surface is replaced. Results are fenced by kind + epoch so a late
     * page can never overwrite a newer document or another kind.
     */
    fun refreshPersonalization(
        kind: String = "soul",
        revisionsCursor: String? = null,
        ownerViewGeneration: Long? = null,
    ) {
        if (!admitted("settings.personalization")) {
            // Settle a typed, retryable state for an unsettled surface
            // instead of leaving the default loading flag forever.
            update { state ->
                if (!state.personalization.loaded &&
                    state.personalizationStatus.error == null
                ) {
                    state.copy(personalizationStatus = SurfaceStatus(error = "unavailable"))
                } else {
                    state
                }
            }
            return
        }
        val append = revisionsCursor != null
        var epoch = 0L
        var contentGeneration = 0L
        synchronized(personalizationRefreshLock) {
            // A mutation-triggered refresh names the view that dispatched
            // it. The ownership check and the epoch/view bumps are ONE
            // critical section: a kind switch either wins here (and this
            // refresh is dropped before it can retarget) or is ordered
            // after this dispatch (and its newer epoch wins the reply).
            if (ownerViewGeneration != null &&
                (personalizationViewGeneration.get() != ownerViewGeneration ||
                    stateFlow.value.personalization.kind != kind)
            ) {
                return
            }
            epoch = personalizationEpoch.incrementAndGet()
            contentGeneration = if (append) {
                personalizationContentGeneration.get()
            } else {
                personalizationContentGeneration.incrementAndGet()
            }
            if (!append) {
                // A full document read establishes a NEW view: a mutation
                // dispatched under the previous view must not publish its
                // refresh/error into this one.
                personalizationViewGeneration.incrementAndGet()
            }
        }
        if (!append) {
            update {
                it.copy(
                    personalizationStatus = SurfaceStatus(loading = true),
                    // A new document read owns the content now; the older
                    // handle chain is fenced by the bumped generation, so
                    // never leave the editor stuck in a loading state.
                    personalization = it.personalization.copy(
                        contentLoading = false,
                        contentLoadFailed = false,
                    ),
                )
            }
        } else {
            update {
                it.copy(personalization = it.personalization.copy(revisionsLoadingMore = true))
            }
        }
        val payload = buildMap<String, JsonElement> {
            put("kind", JsonPrimitive(kind))
            revisionsCursor?.let { put("revisionsCursor", JsonPrimitive(it)) }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.get",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = false,
                correlationID = client().correlationID("pget"),
                payload = JsonObject(payload),
            ),
        ) { outcome ->
            if (personalizationEpoch.get() != epoch) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    if (!append && root == null) {
                        // A valueless Closed completion is a LOST value, not
                        // an empty document: the editor must not open an
                        // unsaved blank over the real state (Privacy's
                        // summaryUnavailable analogue).
                        update {
                            it.copy(
                                personalizationStatus =
                                    SurfaceStatus(error = "documentUnavailable"),
                                personalization = it.personalization.copy(
                                    loaded = true,
                                    contentLoading = false,
                                ),
                            )
                        }
                        return@trackOperation
                    }
                    val active = root?.obj("active")
                    val historyPage = (root?.get("revisionsMeta") as? JsonArray)
                        ?.mapNotNull { decodeRevisionMeta(it as? JsonObject) }
                        ?: emptyList()
                    val nextCursor = root?.string("revisionsNextCursor")
                    val inlineContent = active?.string("content")
                    val contentHandle = active?.obj("contentHandle")?.string("handle")
                    val needsHandleRead = inlineContent == null && contentHandle != null
                    update { state ->
                        val base = if (append &&
                            state.personalization.kind == kind
                        ) {
                            state.personalization.copy(
                                revisions = state.personalization.revisions + historyPage,
                                revisionsNextCursor = nextCursor,
                                revisionsLoadingMore = false,
                            )
                        } else {
                            PersonalizationSurface(
                                kind = kind,
                                // The initial document read settled — even an
                                // empty document is real settled data.
                                loaded = true,
                                // The ACTIVE slot is the real `active` document
                                // row, not MAX(history). A storedAsDraft result
                                // advances latestRevision without moving the
                                // active slot, so using latest here would
                                // misreport which revision is active.
                                activeRevision = active?.long("revision")?.toInt(),
                                content = inlineContent ?: "",
                                contentHandle = contentHandle,
                                contentLoading = needsHandleRead,
                                automaticUpdatesEnabled = root?.obj("cursor")
                                    ?.bool("automaticUpdatesEnabled") ?: false,
                                latestRevision = root?.long("latestRevision")?.toInt() ?: 0,
                                revisionToken = root?.string("revisionToken") ?: "",
                                revisions = historyPage,
                                revisionsNextCursor = nextCursor,
                                // The explicit generate outcome is a
                                // user-visible result; a routine document
                                // refresh must not erase it.
                                lastGenerateOutcome =
                                    state.personalization.lastGenerateOutcome
                                        .takeIf { state.personalization.kind == kind },
                                lastGenerateDraftReason =
                                    state.personalization.lastGenerateDraftReason
                                        .takeIf { state.personalization.kind == kind },
                            )
                        }
                        state.copy(
                            personalizationStatus = SurfaceStatus(),
                            personalization = base,
                        )
                    }
                    // Inline content is present only when the complete
                    // encoded response fits 48KiB; otherwise the ORIGINAL
                    // process-lifetime handle is chunk-read here so the
                    // editor shows (and saves) the real active document.
                    if (!append && needsHandleRead && contentHandle != null) {
                        loadActivePersonalizationContent(kind, contentHandle, contentGeneration)
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    if (append) {
                        it.copy(personalization = it.personalization.copy(
                            revisionsLoadingMore = false))
                    } else {
                        it.copy(
                            personalizationStatus = SurfaceStatus(error = outcome.code),
                            personalization = it.personalization.copy(
                                loaded = true,
                                contentLoading = false,
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Failed -> update {
                    if (append) {
                        it.copy(personalization = it.personalization.copy(
                            revisionsLoadingMore = false))
                    } else {
                        it.copy(
                            personalizationStatus = SurfaceStatus(error = outcome.code),
                            personalization = it.personalization.copy(
                                loaded = true,
                                contentLoading = false,
                            ),
                        )
                    }
                }
                HostOperationOutcome.Cancelled -> settlePersonalizationTerminal(
                    "cancelled", append,
                )
                HostOperationOutcome.Superseded -> settlePersonalizationTerminal(
                    "superseded", append,
                )
            }
        }
    }

    /**
     * A cancelled/replaced terminal of a `personalization.get` settles
     * typed and retryable: the initial read never keeps the default loading
     * flag forever, and a continuation never leaves the revisions pager
     * spinning. Settled documents are never re-opened by this path.
     */
    private fun settlePersonalizationTerminal(code: String, append: Boolean) {
        update {
            if (append) {
                it.copy(personalization = it.personalization.copy(
                    revisionsLoadingMore = false))
            } else {
                it.copy(
                    personalizationStatus = SurfaceStatus(error = code),
                    personalization = it.personalization.copy(
                        loaded = true,
                        contentLoading = false,
                    ),
                )
            }
        }
    }

    /**
     * Byte-exact chunk read of the ACTIVE document behind a real handle.
     * Fenced by the personalization epoch + exact kind/handle, so a late
     * page can never paste old content into a newer document or kind.
     */
    private fun loadActivePersonalizationContent(
        kind: String,
        handle: String,
        generation: Long,
    ) {
        readPersonalizationContent(handle, 0, CONTENT_PAGE_BYTES) { content, _ ->
            if (personalizationContentGeneration.get() != generation) {
                return@readPersonalizationContent
            }
            update { state ->
                val surface = state.personalization
                if (surface.kind != kind || surface.contentHandle != handle ||
                    !surface.contentLoading
                ) {
                    state
                } else {
                    state.copy(personalization = surface.copy(
                        content = content ?: surface.content,
                        contentLoading = false,
                        // The chunk reader returns null ONLY on a typed
                        // failure (its boolean is always true), exactly like
                        // the revision-read caller.
                        contentLoadFailed = content == null,
                    ))
                }
            }
        }
    }

    /** Loads the next bounded history page when the surface owns one. */
    fun loadMoreRevisions(kind: String) {
        val surface = stateFlow.value.personalization
        val cursor = surface.revisionsNextCursor ?: return
        if (surface.revisionsLoadingMore) return
        refreshPersonalization(kind, revisionsCursor = cursor)
    }

    private fun decodeRevisionMeta(obj: JsonObject?): RevisionMetaProjection? {
        obj ?: return null
        val revision = obj.long("revision")?.toInt() ?: return null
        return RevisionMetaProjection(
            id = obj.string("id") ?: return null,
            revision = revision,
            source = obj.string("source") ?: "manual",
            isActive = obj.bool("isActive") ?: false,
            createdAt = obj.string("createdAt") ?: "",
            contentBytes = obj.long("contentBytes")?.toInt() ?: 0,
            contentDigest = obj.string("contentDigest") ?: "",
        )
    }

    /**
     * Reads ONE historical revision through the original
     * `personalization.revision.read` (`{kind, revision}` → document with
     * inline content XOR an owned content handle; a handle pages through
     * the existing bounded `content.read` loop). The result is fenced by
     * kind + revision + epoch: opening another revision, switching kind or
     * a newer refresh discards a late answer.
     */
    fun readPersonalizationRevision(kind: String, revision: Int) {
        if (!admitted("settings.personalization")) return
        val epoch = personalizationEpoch.incrementAndGet()
        update {
            it.copy(personalization = it.personalization.copy(
                openRevision = null,
                revisionReadInFlight = true,
                revisionReadError = null,
            ))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.revision.read",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = false,
                correlationID = client().correlationID("prevread"),
                payload = JsonObject(
                    mapOf(
                        "kind" to JsonPrimitive(kind),
                        "revision" to JsonPrimitive(revision),
                    ),
                ),
            ),
        ) { outcome ->
            if (personalizationEpoch.get() != epoch) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val doc = (outcome.value as? JsonObject)?.obj("document")
                    if (doc == null) {
                        update {
                            it.copy(personalization = it.personalization.copy(
                                revisionReadInFlight = false,
                                revisionReadError = "revisionMalformed",
                            ))
                        }
                        return@trackOperation
                    }
                    val docRevision = doc.long("revision")?.toInt() ?: revision
                    val inline = doc.string("content")
                    val handle = doc.obj("contentHandle")?.string("handle")
                    val meta = RevisionReadProjection(
                        kind = kind,
                        revision = docRevision,
                        source = doc.string("source") ?: "manual",
                        isActive = doc.bool("isActive") ?: false,
                        createdAt = doc.string("createdAt") ?: "",
                        contentBytes = doc.long("contentBytes")?.toInt() ?: 0,
                        content = "",
                        digest = doc.string("contentDigest") ?: "",
                    )
                    fun applyContent(content: String?, error: String?) {
                        if (personalizationEpoch.get() != epoch) return
                        update {
                            it.copy(personalization = it.personalization.copy(
                                revisionReadInFlight = false,
                                openRevision = if (content != null) {
                                    meta.copy(content = content)
                                } else {
                                    null
                                },
                                revisionReadError = error,
                            ))
                        }
                    }
                    when {
                        inline != null -> applyContent(inline, null)
                        handle != null -> readPersonalizationContent(
                            handle, 0, CONTENT_PAGE_BYTES,
                        ) { content, _ -> applyContent(content, if (content == null) "revisionReadFailed" else null) }
                        else -> applyContent(null, "revisionEmpty")
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(personalization = it.personalization.copy(
                        revisionReadInFlight = false,
                        revisionReadError = outcome.code,
                    ))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(personalization = it.personalization.copy(
                        revisionReadInFlight = false,
                        revisionReadError = outcome.code,
                    ))
                }
                else -> Unit
            }
        }
    }

    /** Closes the open revision read (dismissal never mutates anything). */
    fun closePersonalizationRevision() {
        personalizationEpoch.incrementAndGet()
        update {
            it.copy(personalization = it.personalization.copy(
                openRevision = null,
                revisionReadError = null,
            ))
        }
    }

    /**
     * Rolls the active document back to ONE existing target revision: the
     * original append-only, non-destructive path (`personalization.rollback`
     * + active-slot CAS under `personalization.<kind>`). A stale token is a
     * typed refusal; the history list refreshes from the real reply.
     */
    fun rollbackPersonalization(
        kind: String,
        targetRevision: Int,
        onOutcome: (String?) -> Unit,
    ) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        if (kind != stateFlow.value.personalization.kind) {
            onOutcome("kindChanged")
            return
        }
        val token = stateFlow.value.personalization.revisionToken
        if (token.isBlank()) {
            onOutcome("noActiveDocument")
            return
        }
        val viewGeneration = personalizationViewGeneration.get()
        update {
            it.copy(personalization = it.personalization.copy(
                rollingBack = true, rollbackError = null))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.rollback",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = true,
                correlationID = client().correlationID("prollback"),
                revision = HostRevision("personalization.$kind", token),
                payload = JsonObject(
                    mapOf(
                        "kind" to JsonPrimitive(kind),
                        "targetRevision" to JsonPrimitive(targetRevision),
                    ),
                ),
            ),
        ) { outcome ->
            // The real rollback may have committed; only its UI publication
            // is fenced. The terminal clears its OWN flag and writes its
            // error only while the exact kind/view still owns the surface,
            // so a stale reply can neither clear a NEWER rollback's flag
            // nor write its typed error into a newer view.
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val published = publishPersonalizationRollback(
                        viewGeneration, kind, errorCode = null,
                    )
                    if (published) {
                        personalizationEpoch.incrementAndGet()
                        refreshPersonalization(
                            kind,
                            ownerViewGeneration = viewGeneration,
                        )
                        onOutcome(null)
                    } else {
                        onOutcome("staleOwner")
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    val published = publishPersonalizationRollback(
                        viewGeneration, kind, outcome.code,
                    )
                    onOutcome(if (published) outcome.code else "staleOwner")
                }
                is HostOperationOutcome.Failed -> {
                    val published = publishPersonalizationRollback(
                        viewGeneration, kind, outcome.code,
                    )
                    onOutcome(if (published) outcome.code else "staleOwner")
                }
                else -> {
                    val published = publishPersonalizationRollback(
                        viewGeneration, kind, errorCode = null,
                    )
                    onOutcome(if (published) "cancelled" else "staleOwner")
                }
            }
        }
    }

    /**
     * True only while [kind] is still the shown kind AND the view that was
     * current at dispatch is still the current view. A kind switch, retry or
     * any full document read in between makes an older mutation terminal
     * UI-stale, including an ABA return to the same kind.
     */
    private fun ownsPersonalizationView(viewGeneration: Long, kind: String): Boolean =
        personalizationViewGeneration.get() == viewGeneration &&
            stateFlow.value.personalization.kind == kind

    /**
     * Publishes a mutation error ONLY into the exact kind/view that
     * dispatched it, re-checking under the state update so a view switch
     * that lands during the callback cannot receive the error. Returns
     * whether the error was actually published.
     */
    private fun publishPersonalizationSaveError(
        viewGeneration: Long,
        kind: String,
        code: String,
    ): Boolean {
        if (!ownsPersonalizationView(viewGeneration, kind)) return false
        var published = false
        update { state ->
            if (personalizationViewGeneration.get() != viewGeneration ||
                state.personalization.kind != kind
            ) {
                state
            } else {
                published = true
                state.copy(personalization = state.personalization.copy(saveError = code))
            }
        }
        return published
    }

    /**
     * Clears/updates ONLY the rollback state of the kind/view that
     * dispatched the terminal; a newer view's in-flight flag or error is
     * never touched.
     */
    private fun publishPersonalizationRollback(
        viewGeneration: Long,
        kind: String,
        errorCode: String?,
    ): Boolean {
        if (!ownsPersonalizationView(viewGeneration, kind)) return false
        var published = false
        update { state ->
            if (personalizationViewGeneration.get() != viewGeneration ||
                state.personalization.kind != kind
            ) {
                state
            } else {
                published = true
                state.copy(personalization = state.personalization.copy(
                    rollingBack = false,
                    rollbackError = errorCode,
                ))
            }
        }
        return published
    }

    /**
     * Saves the page draft against the EXACT base it was written on.
     * [baseRevisionToken] is the native active-slot token captured when the
     * draft's content became editable; it is never re-read from a newer
     * refresh here (doing so would let a dirty draft silently overwrite an
     * external edit). A kind switch is refused locally; a stale token is a
     * typed writer refusal that keeps the draft recoverable.
     */
    fun savePersonalization(
        kind: String,
        content: String,
        baseRevisionToken: String,
        onOutcome: (String?) -> Unit,
    ) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        if (kind != stateFlow.value.personalization.kind) {
            onOutcome("kindChanged")
            return
        }
        if (baseRevisionToken.isBlank()) {
            onOutcome("noBaseRevision")
            return
        }
        val viewGeneration = personalizationViewGeneration.get()
        update {
            it.copy(personalization = it.personalization.copy(saveError = null))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.save",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = true,
                correlationID = client().correlationID("psave"),
                revision = HostRevision(
                    "personalization.$kind",
                    baseRevisionToken,
                ),
                payload = JsonObject(
                    mapOf("kind" to JsonPrimitive(kind), "content" to JsonPrimitive(content)),
                ),
            ),
        ) { outcome ->
            // The write's effect is service-owned; BOTH its refresh and its
            // typed error are published only for the exact kind/view that
            // dispatched it. A stale success is not refreshed into a newer
            // kind/view (the next real read shows the committed document).
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    if (ownsPersonalizationView(viewGeneration, kind)) {
                        refreshPersonalization(
                            kind,
                            ownerViewGeneration = viewGeneration,
                        )
                        onOutcome(null)
                    } else {
                        onOutcome("staleOwner")
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    val published = publishPersonalizationSaveError(
                        viewGeneration, kind, outcome.code,
                    )
                    onOutcome(if (published) outcome.code else "staleOwner")
                }
                is HostOperationOutcome.Failed -> {
                    val published = publishPersonalizationSaveError(
                        viewGeneration, kind, outcome.code,
                    )
                    onOutcome(if (published) outcome.code else "staleOwner")
                }
                else -> onOutcome(
                    if (ownsPersonalizationView(viewGeneration, kind)) {
                        "cancelled"
                    } else {
                        "staleOwner"
                    },
                )
            }
        }
    }

    fun setPersonalizationAutomatic(kind: String, enabled: Boolean, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        if (kind != stateFlow.value.personalization.kind) {
            onOutcome("kindChanged")
            return
        }
        val viewGeneration = personalizationViewGeneration.get()
        update {
            it.copy(personalization = it.personalization.copy(saveError = null))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.automatic.set",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = true,
                correlationID = client().correlationID("pauto"),
                revision = HostRevision(
                    "personalization.cursor.$kind",
                    stateFlow.value.personalization.revisionToken,
                ),
                payload = JsonObject(
                    mapOf("kind" to JsonPrimitive(kind), "enabled" to JsonPrimitive(enabled)),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    if (ownsPersonalizationView(viewGeneration, kind)) {
                        refreshPersonalization(
                            kind,
                            ownerViewGeneration = viewGeneration,
                        )
                        onOutcome(null)
                    } else {
                        onOutcome("staleOwner")
                    }
                }
                is HostOperationOutcome.Rejected -> {
                    val published = publishPersonalizationSaveError(
                        viewGeneration, kind, outcome.code,
                    )
                    onOutcome(if (published) outcome.code else "staleOwner")
                }
                is HostOperationOutcome.Failed -> {
                    val published = publishPersonalizationSaveError(
                        viewGeneration, kind, outcome.code,
                    )
                    onOutcome(if (published) outcome.code else "staleOwner")
                }
                else -> onOutcome(
                    if (ownsPersonalizationView(viewGeneration, kind)) {
                        "cancelled"
                    } else {
                        "staleOwner"
                    },
                )
            }
        }
    }

    /**
     * Starts ONE personalization generation. The operation owns ONE
     * correlation for its whole lifetime; the accepted receipt is captured
     * via [RuntimeHost.trackOperation]'s onAccepted so an explicit user
     * cancel can address the REAL operation (`personalization.generate.cancel`
     * reuses the correlation → the mailbox re-issues the same receipt the
     * facade's cancel window is keyed on). A terminal of a SUPERSEDED
     * generation (a newer generate owns the surface) is dropped, never
     * clearing the new operation's state.
     */
    fun generatePersonalization(kind: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        val correlation = client().correlationID("pgen")
        update {
            it.copy(personalization = it.personalization.copy(
                generating = true,
                generateError = null,
                generateCorrelation = correlation,
                generateReceipt = null,
            ))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.generate",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = true,
                correlationID = correlation,
                createIntent = true,
                payload = JsonObject(mapOf("kind" to JsonPrimitive(kind))),
            ),
            onAccepted = { receipt ->
                update { state ->
                    val p = state.personalization
                    if (p.generateCorrelation == correlation) {
                        state.copy(personalization = p.copy(generateReceipt = receipt))
                    } else {
                        state
                    }
                }
            },
        ) { outcome ->
            val current = stateFlow.value.personalization
            if (current.generateCorrelation != correlation) return@trackOperation
            update {
                it.copy(personalization = it.personalization.copy(
                    generating = false,
                    generateCorrelation = null,
                    generateReceipt = null,
                ))
            }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val effect = outcome.value as? JsonObject
                    val outcomeField = effect?.obj("outcome")
                    val draftReason = outcomeField?.obj("storedAsDraft")?.string("reason")
                    val active = outcomeField?.get("active")
                        ?.let { (it as? JsonPrimitive)?.booleanOrNull } == true
                    personalizationEpoch.incrementAndGet()
                    refreshPersonalization(kind)
                    // Publish the REAL terminal outcome (active versus
                    // storedAsDraft{reason}) before the refresh reply lands;
                    // the refresh preserves these fields.
                    if (active || draftReason != null) {
                        update {
                            it.copy(personalization = it.personalization.copy(
                                lastGenerateOutcome = if (active) "active" else "storedAsDraft",
                                lastGenerateDraftReason = draftReason,
                            ))
                        }
                    }
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> {
                    update {
                        it.copy(personalization = it.personalization.copy(generateError = outcome.code))
                    }
                    onOutcome(outcome.code)
                }
                is HostOperationOutcome.Failed -> {
                    update {
                        it.copy(personalization = it.personalization.copy(generateError = outcome.code))
                    }
                    onOutcome(outcome.code)
                }
                else -> onOutcome("cancelled")
            }
        }
    }

    /**
     * Cancels the REAL accepted generation: requires the accepted receipt
     * (the cancel control stays hidden until onAccepted fired) and reuses
     * the generation correlation so the mailbox re-issues the SAME receipt
     * the facade's cancel window is keyed on. Submitted WITHOUT its own
     * effect stream — the GENERATE operation's own stream owns the terminal
     * and reports the REAL canceled{phase}/committed outcome; a different
     * receipt at admission means the operation already settled (honest
     * typed answer, never a dismissal-claimed cancellation).
     */
    fun cancelPersonalizationGenerate(onOutcome: (String?) -> Unit) {
        val surface = stateFlow.value.personalization
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        val correlation = surface.generateCorrelation
        val receipt = surface.generateReceipt
        if (!surface.generating || correlation == null || receipt == null) {
            // No accepted operation yet (or the terminal already arrived):
            // there is nothing real to cancel.
            onOutcome("noActiveGeneration")
            return
        }
        host.scope.launch(host.ioDispatcher) {
            when (val submitted = client().submit(
                HostCommandRequest(
                    command = "personalization.generate.cancel",
                    scope = HostScope.ApplicationConfiguration("personalization"),
                    stateful = false,
                    correlationID = correlation,
                ),
            )) {
                is HostSubmitResult.Accepted -> {
                    if (submitted.operationReceiptID == receipt) {
                        onOutcome(null)
                    } else {
                        onOutcome("noActiveGeneration")
                    }
                }
                is HostSubmitResult.Rejected -> onOutcome(submitted.reason)
                HostSubmitResult.Superseded -> onOutcome("superseded")
            }
        }
    }

    /**
     * Bounded typed read for owned personalization handles. The wire chunk
     * carries `nextOffset` (null = the tail): pages are read until the tail
     * so an oversized document is never silently truncated after chunk 1
     * (the previous decoder invented a `done` flag the producer never
     * emits). One final callback with the full content; a mid-way failure
     * answers (null, true) like every other typed failure of this surface.
     */
    fun readPersonalizationContent(
        handle: String,
        offsetBytes: Int,
        maxBytes: Int,
        onResult: (String?, Boolean) -> Unit,
    ) {
        if (!admitted("settings.personalization")) {
            onResult(null, true)
            return
        }
        readContentPage(handle, offsetBytes, maxBytes,
            accumulated = StringBuilder(), pages = 0, onResult = onResult)
    }

    private fun readContentPage(
        handle: String,
        offset: Int,
        maxBytes: Int,
        accumulated: StringBuilder,
        pages: Int,
        onResult: (String?, Boolean) -> Unit,
    ) {
        // Hard iteration bound: a malformed producer can never loop the
        // host forever; honest documents page well inside this.
        if (pages >= 256) {
            onResult(null, true)
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "content.read",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = false,
                correlationID = client().correlationID("pread"),
                payload = JsonObject(
                    mapOf(
                        "handle" to JsonPrimitive(handle),
                        "offsetBytes" to JsonPrimitive(offset),
                        "maxBytes" to JsonPrimitive(maxBytes),
                    ),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val chunk = root?.string("chunk")
                    if (chunk == null) {
                        onResult(null, true)
                        return@trackOperation
                    }
                    accumulated.append(chunk)
                    val nextOffset = root.long("nextOffset")
                    if (nextOffset == null) {
                        onResult(accumulated.toString(), true)
                    } else {
                        readContentPage(handle, nextOffset.toInt(), maxBytes,
                            accumulated, pages + 1, onResult)
                    }
                }
                else -> onResult(null, true)
            }
        }
    }

    // ------------------------------------------------------------------ usage

    private val usageGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * One REAL `usage.statistics.get` page for a frozen dimension
     * (total|conversation|model|provider). A dimension change starts a new
     * generation; a continuation appends only while it still owns it.
     */
    fun refreshUsage(dimension: String = stateFlow.value.usage.dimension) {
        if (!admitted("settings.usage")) {
            // Settle a typed, retryable state for an unsettled surface
            // instead of leaving the default loading flag forever.
            update { state ->
                if (!state.usage.loaded && state.usageStatus.error == null) {
                    state.copy(usageStatus = SurfaceStatus(error = "unavailable"))
                } else {
                    state
                }
            }
            return
        }
        val normalized = when (dimension) {
            "conversation", "model", "provider" -> dimension
            else -> "total"
        }
        val generation = usageGeneration.incrementAndGet()
        update {
            it.copy(
                usageStatus = SurfaceStatus(loading = true),
                usage = it.usage.copy(
                    dimension = normalized,
                    rows = emptyList(),
                    nextCursor = null,
                    loadingMore = false,
                ),
            )
        }
        fetchUsagePage(generation, normalized, cursor = null, append = false)
    }

    /** Bounded continuation of this dimension's breakdown rows. */
    fun loadMoreUsage() {
        if (!admitted("settings.usage")) return
        val surface = stateFlow.value.usage
        val cursor = surface.nextCursor ?: return
        if (surface.loadingMore || stateFlow.value.usageStatus.loading) return
        val generation = usageGeneration.get()
        update { it.copy(usage = it.usage.copy(loadingMore = true)) }
        fetchUsagePage(generation, surface.dimension, cursor, append = true)
    }

    private fun fetchUsagePage(
        generation: Long,
        dimension: String,
        cursor: String?,
        append: Boolean,
    ) {
        val payload = buildMap<String, JsonElement> {
            put("dimension", JsonPrimitive(dimension))
            put("limit", JsonPrimitive(50))
            cursor?.let { put("cursor", JsonPrimitive(it)) }
        }
        host.trackOperation(
            HostCommandRequest(
                command = "usage.statistics.get",
                scope = HostScope.ApplicationConfiguration("usage"),
                stateful = false,
                correlationID = client().correlationID("uget"),
                payload = JsonObject(payload),
            ),
        ) { outcome ->
            if (usageGeneration.get() != generation) return@trackOperation
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    if (!append && root == null) {
                        // A valueless Closed completion is a LOST value, not
                        // "no usage recorded": settling it as empty would be
                        // a fabricated zero report (Privacy's
                        // summaryUnavailable analogue).
                        update {
                            it.copy(
                                usageStatus = SurfaceStatus(error = "statisticsUnavailable"),
                                usage = it.usage.copy(loaded = true, loadingMore = false),
                            )
                        }
                        return@trackOperation
                    }
                    val pageRows = (root?.get("rows") as? JsonArray)
                        ?.mapNotNull { r -> (r as? JsonObject)?.let(::decodeUsageRow) }
                        ?: emptyList()
                    val rawNext = root?.string("nextCursor")
                    val next = rawNext?.takeUnless { append && it == cursor }
                    update { state ->
                        val merged = LinkedHashMap<String, UsageBreakdownProjection>()
                        if (append) state.usage.rows.forEach { merged[it.id] = it }
                        pageRows.forEach { merged[it.id] = it }
                        state.copy(
                            usageStatus = SurfaceStatus(),
                            usage = UsageSurface(
                                totals = (root?.get("totals") as? JsonObject)
                                    ?.let(::decodeUsageTotals),
                                loaded = if (append) state.usage.loaded else true,
                                byDay = (root?.get("byDay") as? JsonArray)
                                    ?.mapNotNull { d ->
                                        (d as? JsonObject)?.let { day ->
                                            UsageDayProjection(
                                                date = day.string("date") ?: "",
                                                inputTokens = day.long("inputTokens") ?: 0,
                                                outputTokens = day.long("outputTokens") ?: 0,
                                                runs = day.long("runs") ?: 0,
                                            )
                                        }
                                    } ?: emptyList(),
                                rows = merged.values.toList(),
                                nextCursor = next,
                                loadingMore = false,
                                dimension = dimension,
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(
                        usageStatus = SurfaceStatus(error = outcome.code),
                        usage = it.usage.copy(
                            loaded = if (append) it.usage.loaded else true,
                            loadingMore = false,
                        ),
                    )
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(
                        usageStatus = SurfaceStatus(error = outcome.code),
                        usage = it.usage.copy(
                            loaded = if (append) it.usage.loaded else true,
                            loadingMore = false,
                        ),
                    )
                }
                HostOperationOutcome.Cancelled,
                HostOperationOutcome.Superseded -> {
                    // A cancelled/replaced terminal of the INITIAL read
                    // settles typed and retryable — never a permanent
                    // loading state; continuations only clear their spinner.
                    val code = if (outcome == HostOperationOutcome.Cancelled) {
                        "cancelled"
                    } else {
                        "superseded"
                    }
                    update {
                        if (append) {
                            it.copy(usage = it.usage.copy(loadingMore = false))
                        } else {
                            it.copy(
                                usageStatus = SurfaceStatus(error = code),
                                usage = it.usage.copy(loaded = true, loadingMore = false),
                            )
                        }
                    }
                }
            }
        }
    }

    private fun decodeUsageTotals(t: JsonObject): UsageTotalsProjection =
        UsageTotalsProjection(
            inputTokens = t.long("inputTokens") ?: 0,
            outputTokens = t.long("outputTokens") ?: 0,
            totalTokens = t.long("totalTokens") ?: 0,
            runs = t.long("runs") ?: 0,
            cacheReadTokens = t.long("cacheReadTokens"),
            cacheWriteTokens = t.long("cacheWriteTokens"),
            reasoningTokens = t.long("reasoningTokens"),
            averageTokensPerSecond = t.double("averageTokensPerSecond"),
            averageTimeToFirstTokenMs = t.double("averageTimeToFirstTokenMs"),
            averageDurationMs = t.double("averageDurationMs"),
        )

    private fun decodeUsageRow(row: JsonObject): UsageBreakdownProjection =
        UsageBreakdownProjection(
            id = row.string("id") ?: "",
            label = row.string("label") ?: "",
            inputTokens = row.long("inputTokens") ?: 0,
            outputTokens = row.long("outputTokens") ?: 0,
            runs = row.long("runs") ?: 0,
            totalTokens = row.long("totalTokens"),
            cacheReadTokens = row.long("cacheReadTokens"),
            cacheWriteTokens = row.long("cacheWriteTokens"),
            reasoningTokens = row.long("reasoningTokens"),
            averageTokensPerSecond = row.double("averageTokensPerSecond"),
            averageTimeToFirstTokenMs = row.double("averageTimeToFirstTokenMs"),
            averageDurationMs = row.double("averageDurationMs"),
        )

    // ---------------------------------------------------------------- privacy

    fun refreshPrivacySummary() {
        if (!admitted("settings.privacy")) {
            // The privacy domain is not (yet) the owner of this surface.
            // Settle a typed, retryable state instead of leaving the default
            // loading flag forever; a real later admission re-reads it.
            update { state ->
                if (state.privacy.summary == null && state.privacyStatus.error == null) {
                    state.copy(privacyStatus = SurfaceStatus(error = "unavailable"))
                } else {
                    state
                }
            }
            return
        }
        update { it.copy(privacyStatus = SurfaceStatus(loading = true)) }
        // Own read generation: a newer refresh supersedes every older reply
        // before any of it may touch the surface.
        val readGeneration = privacyReadGeneration.incrementAndGet()
        host.scope.launch(host.ioDispatcher) {
            if (!admitted("settings.privacy")) {
                if (readGeneration == privacyReadGeneration.get()) {
                    update { it.copy(privacyStatus = SurfaceStatus(error = "unavailable")) }
                }
                return@launch
            }
            // ACTUAL accepted native Root epoch, captured off-main BEFORE the
            // dispatch and re-checked after the reply. A plain read is never
            // re-routed onto a newer root; a changed root surfaces a typed,
            // retryable error instead of stale counts.
            val rootEpoch = host.nativeRootEpoch()
            if (rootEpoch == null) {
                if (readGeneration == privacyReadGeneration.get()) {
                    update {
                        it.copy(privacyStatus = SurfaceStatus(error = "rootUnavailable"))
                    }
                }
                return@launch
            }
            host.trackOperation(
                HostCommandRequest(
                    command = "privacy.summary.get",
                    scope = HostScope.ApplicationConfiguration("privacy"),
                    stateful = false,
                    correlationID = client().correlationID("prget"),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        if (readGeneration != privacyReadGeneration.get()) {
                            // A newer read owns the surface.
                            return@trackOperation
                        }
                        val currentEpoch = host.nativeRootEpoch()
                        if (currentEpoch == null || currentEpoch != rootEpoch) {
                            // Root changed underneath: the old projection
                            // (counts, digests AND its report carry-over)
                            // must not survive onto the new root.
                            update {
                                it.copy(
                                    privacyStatus = SurfaceStatus(error = "rootChanged"),
                                    privacy = PrivacySurface(),
                                )
                            }
                            return@trackOperation
                        }
                        val root = outcome.value as? JsonObject
                        if (root == null || !isPrivacySummaryDocument(root)) {
                            // A completed terminal without the typed summary
                            // document is a LOST value, not a successful empty
                            // read. Never clear loading silently (that renders
                            // "Loading…" forever with no retry).
                            update {
                                it.copy(
                                    privacyStatus = SurfaceStatus(error = "summaryUnavailable"),
                                )
                            }
                            return@trackOperation
                        }
                        update {
                            it.copy(
                                privacyStatus = SurfaceStatus(),
                                privacy = decodePrivacySummary(root, it.privacy, rootEpoch),
                            )
                        }
                    }
                    is HostOperationOutcome.Rejected -> {
                        if (readGeneration != privacyReadGeneration.get()) return@trackOperation
                        update {
                            it.copy(privacyStatus = SurfaceStatus(error = outcome.code))
                        }
                    }
                    is HostOperationOutcome.Failed -> {
                        if (readGeneration != privacyReadGeneration.get()) return@trackOperation
                        update {
                            it.copy(privacyStatus = SurfaceStatus(error = outcome.code))
                        }
                    }
                    HostOperationOutcome.Cancelled -> {
                        if (readGeneration != privacyReadGeneration.get()) return@trackOperation
                        update {
                            it.copy(privacyStatus = SurfaceStatus(error = "cancelled"))
                        }
                    }
                    HostOperationOutcome.Superseded -> {
                        if (readGeneration != privacyReadGeneration.get()) return@trackOperation
                        update {
                            it.copy(privacyStatus = SurfaceStatus(error = "superseded"))
                        }
                    }
                }
            }
        }
    }

    /**
     * Failure/deletionFailure page through the SAME privacy.summary.get.
     * The reply is accepted ONLY when its handle/kind match the request
     * exactly AND the report slot is still owned by that same handle AND
     * the ACTUAL root is unchanged across the read: a mismatched/arbitrary,
     * superseded or cross-root page can never overwrite a newer root's
     * report.
     *
     * Ownership is three-layered:
     *  1. per-READ generation — the NEWEST read of the slot wins, so two
     *     concurrent same-handle cursor requests (e.g. a duplicated "More"
     *     tap) can never land out of order and rewind the slot;
     *  2. slot generation + handle — a newer clear that replaced the slot
     *     fences every older in-flight read;
     *  3. the slot ownership is RE-CHECKED inside the state update, so a
     *     clear or newer page that lands between the pre-check and the
     *     write still cannot be overwritten.
     *
     * The whole read runs on the host io dispatcher: the native root epoch
     * is captured and re-verified OFF the UI thread (no row-click JNI).
     */
    fun readPrivacyReportPage(
        handle: String,
        kind: String,
        cursor: String?,
        maxItems: Int,
        onResult: (PrivacyReportPage?) -> Unit,
    ) {
        if (!admitted("settings.privacy")) {
            onResult(null)
            return
        }
        // Issue order belongs to the caller, not IO coroutine scheduling.
        val readGeneration = privacyReportReadGeneration.incrementAndGet()
        val slotGeneration = privacyReportGeneration.get()
        val projected = stateFlow.value.privacy
        val projectedRoot = projected.rootEpoch
        if (projectedRoot == null || projected.reportPage?.handle != handle ||
            projected.reportPage?.kind != kind) {
            onResult(null)
            return
        }
        host.scope.launch(host.ioDispatcher) {
            // ACTUAL accepted root, captured off-main BEFORE the dispatch
            // and re-checked on the reply; a plain page read is never
            // re-routed onto a newer root.
            val requestRoot = host.nativeRootEpoch()
            if (requestRoot == null || requestRoot != projectedRoot ||
                readGeneration != privacyReportReadGeneration.get() ||
                slotGeneration != privacyReportGeneration.get()) {
                onResult(null)
                return@launch
            }
            val report = mutableMapOf<String, JsonElement>(
                "handle" to JsonPrimitive(handle),
            )
            cursor?.let { report["cursor"] = JsonPrimitive(it) }
            report["maxItems"] = JsonPrimitive(maxItems)
            host.trackOperation(
                HostCommandRequest(
                    command = "privacy.summary.get",
                    scope = HostScope.ApplicationConfiguration("privacy"),
                    stateful = false,
                    correlationID = client().correlationID("prpage"),
                    payload = JsonObject(mapOf("report" to JsonObject(report))),
                ),
            ) { outcome ->
                when (outcome) {
                    is HostOperationOutcome.Completed -> {
                        val pageObject = (outcome.value as? JsonObject)?.obj("report")
                        val replyHandle = pageObject?.string("handle")
                        val replyKind = pageObject?.string("kind")
                        if (pageObject == null ||
                            replyHandle != handle ||
                            replyKind != kind ||
                            readGeneration != privacyReportReadGeneration.get() ||
                            slotGeneration != privacyReportGeneration.get() ||
                            host.nativeRootEpoch() != requestRoot ||
                            stateFlow.value.privacy.rootEpoch != requestRoot ||
                            stateFlow.value.privacy.reportPage?.handle != handle
                        ) {
                            // Foreign/arbitrary identity, a superseded slot,
                            // an older read, or a root change underneath.
                            onResult(null)
                            return@trackOperation
                        }
                        val page = PrivacyReportPage(
                            handle = replyHandle,
                            kind = replyKind,
                            items = (pageObject.get("items") as? JsonArray)
                                ?.mapNotNull { decodeFailure(it as? JsonObject) }
                                ?: emptyList(),
                            nextCursor = pageObject.string("nextCursor"),
                            total = pageObject.long("total") ?: 0,
                            done = pageObject.bool("done") ?: true,
                        )
                        // Re-validate ownership INSIDE the state update: the
                        // newest read + the same slot + the same handle must
                        // STILL hold at the moment of the write.
                        val applied = java.util.concurrent.atomic.AtomicBoolean(false)
                        update { state ->
                            val current = state.privacy
                            if (readGeneration != privacyReportReadGeneration.get() ||
                                slotGeneration != privacyReportGeneration.get() ||
                                current.rootEpoch != requestRoot ||
                                current.reportPage?.kind != kind ||
                                current.reportPage?.handle != handle
                            ) {
                                state
                            } else {
                                applied.set(true)
                                state.copy(privacy = current.copy(reportPage = page))
                            }
                        }
                        if (applied.get()) onResult(page) else onResult(null)
                    }
                    else -> onResult(null)
                }
            }
        }
    }

    /**
     * Creates the IMMUTABLE preview for ONE explicit user tap on a
     * previewed action row. Returns null (no side effects) when no current
     * in-root projection exists, a clear is already in flight, or the
     * projection no longer matches the current preview generation. The
     * digest alone is never consent: the clear path exchanges this preview
     * for ONE privileged native capability bound to its exact
     * epoch/digest/invocation/action.
     *
     * NO NATIVE CALL HERE: this runs on the UI thread at row-click time.
     * The preview pins the PROJECTION's cached root epoch — itself captured
     * off-main with before/after re-checks during the summary read — and
     * the ACTUAL root validation happens off-main in [validatePrivacyPreview]
     * before the capability is minted and again before dispatch. Root
     * validation is NOT removed; it is moved off the UI thread.
     */
    fun createPrivacyClearPreview(action: PrivacyClearAction): PrivacyClearPreview? {
        val state = stateFlow.value
        if (state.privacyClear?.inFlight == true) return null
        val privacy = state.privacy
        val summary = privacy.summary ?: return null
        val rootEpoch = privacy.rootEpoch ?: return null
        val projectedGeneration = privacy.previewGeneration ?: return null
        if (projectedGeneration != privacyEpochSource.get()) return null
        val digest = when (action) {
            PrivacyClearAction.HISTORY -> summary.historyRevision
            PrivacyClearAction.MODEL_CONFIGURATION -> summary.modelConfigRevision
        }
        if (digest.isBlank()) return null
        return PrivacyClearPreview(
            action = action,
            digest = digest,
            sourceNativeEpoch = rootEpoch,
            previewGeneration = projectedGeneration,
        )
    }

    /** Bump whenever a fresh preview is projected (invalidates old taps). */
    val privacyPreviewEpoch: Long
        get() = privacyEpochSource.get()

    private val privacyEpochSource = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Own generation of the projection read chain; a newer
     * [refreshPrivacySummary] supersedes every older reply.
     */
    private val privacyReadGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Own generation of the report paging slot; bumped exactly when a new
     * clear report replaces the slot, so a late page of a retired report
     * can never overwrite the new one.
     */
    private val privacyReportGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * Own generation of report-page READS; bumped on every issued page read
     * so only the NEWEST read of the slot may publish — concurrent
     * same-handle cursor requests can never land out of order and rewind
     * the slot.
     */
    private val privacyReportReadGeneration = java.util.concurrent.atomic.AtomicLong(0)

    /** Single-flight latch: ONE clear at a time; duplicate taps refused. */
    private val privacyClearSettlement = PrivacyClearSettlementGate()

    enum class PrivacyClearAction { HISTORY, MODEL_CONFIGURATION }

    fun clearPrivacyHistory(preview: PrivacyClearPreview, onOutcome: (String?) -> Unit) {
        clearPrivacy(preview, onOutcome)
    }

    fun clearPrivacyModelConfiguration(preview: PrivacyClearPreview, onOutcome: (String?) -> Unit) {
        clearPrivacy(preview, onOutcome)
    }

    /**
     * The ONE trusted clear path for both destructive operations.
     *
     * Sequence (R2-A trusted-host chain):
     *  1. local revalidation of the immutable preview against the CURRENT
     *     root/projection (refusal ⇒ typed code, no effects);
     *  2. ONE correlation minted for this exact invocation;
     *  3. the privileged native ingress (off-main) validates the live owner
     *     proof and mints ONE opaque `pc:v1:` capability bound to
     *     epoch + operation + digest + invocation + action — the owner
     *     token never enters the wire/UI/logs;
     *  4. revalidation immediately before dispatch (a root change after the
     *     mint refuses WITHOUT submitting; the capability simply expires —
     *     no re-mint, no replay against the current root);
     *  5. submit: the SAME correlation rides the envelope correlationID,
     *     the preview digest stays the exact revision.version, and ONLY the
     *     opaque capability is the payload.confirmToken;
     *  6. terminal: a completed report is projected truthfully (partial /
     *     remaining / preferencesFailure / failurePage), the SAME-root
     *     affected consumers re-read through their EXISTING controllers
     *     (history list + retained-holder reconciliation; provider/model /
     *     composer + defaults/preferences), then the summary re-reads under
     *     the CURRENT root. Every publish is fenced by the exact
     *     (action, previewGeneration, sourceNativeEpoch) identity.
     */
    private fun clearPrivacy(preview: PrivacyClearPreview, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.privacy")) {
            onOutcome("unavailable")
            return
        }
        val clearTicket = privacyClearSettlement.acquire()
        if (clearTicket == null) {
            onOutcome("inFlight")
            return
        }
        beginPrivacyClear(preview)
        host.scope.launch(host.ioDispatcher) {
            val operation: String
            val actionTag: String
            when (preview.action) {
                PrivacyClearAction.HISTORY -> {
                    operation = "privacy.history.clear"
                    actionTag = "historyClear"
                }
                PrivacyClearAction.MODEL_CONFIGURATION -> {
                    operation = "privacy.modelConfiguration.clear"
                    actionTag = "modelConfigClear"
                }
            }
            val earlyRefusal = validatePrivacyPreview(preview)
            if (earlyRefusal != null) {
                finishPrivacyClear(clearTicket, onOutcome) {
                    publishPrivacyClearTerminal(preview, error = earlyRefusal)
                    earlyRefusal
                }
                return@launch
            }
            // The App can only REQUEST the capability. The privileged
            // native ingress validates the live owner proof and mints one
            // capability bound to this exact preview digest and command
            // correlation; the process owner token never enters the wire.
            val correlation = client().correlationID(
                if (preview.action == PrivacyClearAction.HISTORY) "prh" else "prm")
            val capability = host.issuePrivacyConfirmation(
                expectedNativeEpoch = preview.sourceNativeEpoch,
                operation = operation,
                previewDigest = preview.digest,
                invocationID = correlation,
                action = actionTag,
            )
            if (capability == null) {
                finishPrivacyClear(clearTicket, onOutcome) {
                    publishPrivacyClearTerminal(preview, error = "confirmationUnavailable")
                    "confirmationUnavailable"
                }
                return@launch
            }
            // Revalidate immediately before dispatch: never replay a minted
            // capability against a changed root/projection.
            val dispatchRefusal = validatePrivacyPreview(preview)
            if (dispatchRefusal != null) {
                finishPrivacyClear(clearTicket, onOutcome) {
                    publishPrivacyClearTerminal(preview, error = dispatchRefusal)
                    dispatchRefusal
                }
                return@launch
            }
            host.trackOperation(
                HostCommandRequest(
                    command = operation,
                    scope = HostScope.ApplicationConfiguration("privacy"),
                    stateful = true,
                    correlationID = correlation,
                    revision = HostRevision(
                        if (preview.action == PrivacyClearAction.HISTORY) {
                            "privacy.history"
                        } else {
                            "privacy.modelConfiguration"
                        },
                        preview.digest,
                    ),
                    payload = JsonObject(mapOf("confirmToken" to JsonPrimitive(capability))),
                ),
            ) { outcome ->
                finishPrivacyClear(clearTicket, onOutcome) terminal@{
                    when (outcome) {
                        is HostOperationOutcome.Completed -> {
                            if (host.nativeRootEpoch() != preview.sourceNativeEpoch) {
                                publishPrivacyClearTerminal(preview, error = "rootChanged")
                                refreshPrivacySummary()
                                return@terminal "rootChanged"
                            }
                            privacyEpochSource.incrementAndGet()
                            val reportApplied = applyPrivacyClearReport(
                                outcome.value as? JsonObject,
                                history = preview.action == PrivacyClearAction.HISTORY,
                            )
                            if (!reportApplied) {
                                publishPrivacyClearTerminal(preview, error = "reportUnavailable")
                                refreshPrivacySummary()
                                return@terminal "reportUnavailable"
                            }
                            if (host.nativeRootEpoch() == preview.sourceNativeEpoch) {
                                if (preview.action == PrivacyClearAction.HISTORY) {
                                    host.conversations.refreshAfterPrivacyHistoryClear()
                                } else {
                                    host.conversations.refreshModels()
                                    host.providers.refreshProviders()
                                    refreshDefaults()
                                    refreshPreferences()
                                }
                            }
                            publishPrivacyClearTerminal(preview, error = null)
                            refreshPrivacySummary()
                            null
                        }
                        is HostOperationOutcome.Rejected -> {
                            publishPrivacyClearTerminal(preview, error = outcome.code)
                            outcome.code
                        }
                        is HostOperationOutcome.Failed -> {
                            val code = outcome.detail["wire"] ?: outcome.code
                            publishPrivacyClearTerminal(preview, error = code)
                            code
                        }
                        else -> {
                            publishPrivacyClearTerminal(preview, error = "cancelled")
                            "cancelled"
                        }
                    }
                }
            }
        }
    }

    /** Keep request ownership through all terminal mutations; notify after release. */
    private fun finishPrivacyClear(
        ticket: PrivacyClearSettlementGate.Ticket,
        onOutcome: (String?) -> Unit,
        terminal: () -> String?,
    ) {
        var result: String? = null
        if (privacyClearSettlement.finish(ticket) { result = terminal() }) {
            onOutcome(result)
        }
    }

    /**
     * Local revalidation of an immutable preview against the CURRENT
     * root/projection. Returns the typed refusal code or null while the
     * preview still exactly matches what the user saw.
     */
    private fun validatePrivacyPreview(preview: PrivacyClearPreview): String? {
        val privacy = stateFlow.value.privacy
        val summary = privacy.summary ?: return "previewUnavailable"
        if (privacy.rootEpoch != preview.sourceNativeEpoch) return "rootChanged"
        val liveEpoch = host.nativeRootEpoch() ?: return "rootUnavailable"
        if (liveEpoch != preview.sourceNativeEpoch) return "rootChanged"
        if (privacy.previewGeneration != preview.previewGeneration) return "previewStale"
        val currentDigest = when (preview.action) {
            PrivacyClearAction.HISTORY -> summary.historyRevision
            PrivacyClearAction.MODEL_CONFIGURATION -> summary.modelConfigRevision
        }
        if (currentDigest != preview.digest) return "previewStale"
        return null
    }

    /** Unconditionally opens the identity-fenced status for a new request. */
    private fun beginPrivacyClear(preview: PrivacyClearPreview) {
        update { state ->
            state.copy(
                privacyClear = PrivacyClearStatus(
                    action = preview.action,
                    previewGeneration = preview.previewGeneration,
                    sourceNativeEpoch = preview.sourceNativeEpoch,
                    inFlight = true,
                    error = null,
                ),
            )
        }
    }

    /**
     * Publishes a terminal update of [SettingsHostState.privacyClear] ONLY
     * while the exact (action, previewGeneration, sourceNativeEpoch)
     * identity is still the current request: a late callback of an older
     * request can neither clear nor rewrite a newer one. The single-flight
     * latch serializes clears, so the in-flight status always belongs to
     * the live request here.
     */
    private fun publishPrivacyClearTerminal(preview: PrivacyClearPreview, error: String?) {
        update { state ->
            val current = state.privacyClear
            val owned = current != null &&
                current.action == preview.action &&
                current.previewGeneration == preview.previewGeneration &&
                current.sourceNativeEpoch == preview.sourceNativeEpoch
            if (current != null && !owned) return@update state
            state.copy(
                privacyClear = PrivacyClearStatus(
                    action = preview.action,
                    previewGeneration = preview.previewGeneration,
                    sourceNativeEpoch = preview.sourceNativeEpoch,
                    inFlight = false,
                    error = error,
                ),
            )
        }
    }

    /**
     * Decodes the REAL `privacy.summary.get` value. The summary carries ONLY
     * per-resource counts and the two revision digests (plus credential
     * availability/snapshot receipt); `remaining`/`partial`/failure arrays
     * belong to a CLEAR REPORT and are preserved from [previous] across a
     * counts refresh instead of being inferred from absent fields — the
     * previous decoder marked every fresh summary partial. The projection is
     * bound to [rootEpoch], the ACTUAL native epoch verified before and
     * after the dispatch.
     *
     * SAME-OWNER CARRY-OVER ONLY: the report/remaining/failure/page slots
     * survive ONLY while the previous projection belonged to this exact
     * [rootEpoch]. The read's before/after epoch checks cannot see a root
     * transition that happened BEFORE the dispatch (the captured epoch is
     * already the new root while the surface still holds the old root's
     * data) — comparing the surface's bound epoch closes that hole: a new
     * root always starts from empty report slots, never inheriting the old
     * root's report handle or counters.
     */
    private fun isPrivacySummaryDocument(root: JsonObject): Boolean {
        val history = root.obj("history") ?: return false
        val models = root.obj("modelConfiguration") ?: return false
        return listOf("conversationCount", "runCount", "persistedGrantCount", "inMemoryGrantCount")
            .all { strictCount(history, it) != null } &&
            listOf("providerCount", "modelCount", "secretReferenceCount", "preferencesSyncRevision")
                .all { strictCount(models, it) != null } &&
            history.string("revision")?.isNotBlank() == true &&
            models.string("revision")?.isNotBlank() == true
    }

    private fun decodePrivacySummary(
        root: JsonObject?,
        previous: PrivacySurface,
        rootEpoch: Long?,
    ): PrivacySurface {
        if (root == null) return previous
        val history = root.obj("history")
        val modelConfig = root.obj("modelConfiguration")
        val sameRoot = previous.rootEpoch != null && previous.rootEpoch == rootEpoch
        val prior = if (sameRoot) previous.summary else null
        return PrivacySurface(
            summary = PrivacySummaryProjection(
                conversationCount = history?.long("conversationCount") ?: 0,
                runCount = history?.long("runCount") ?: 0,
                persistedGrantCount = history?.long("persistedGrantCount") ?: 0,
                inMemoryGrantCount = history?.long("inMemoryGrantCount") ?: 0,
                providerCount = modelConfig?.long("providerCount") ?: 0,
                modelCount = modelConfig?.long("modelCount") ?: 0,
                secretReferenceCount = modelConfig?.long("secretReferenceCount") ?: 0,
                preferencesSyncRevision = modelConfig?.long("preferencesSyncRevision") ?: 0,
                // Clear-report truth carries over across a counts refresh
                // of the SAME root only; it is replaced only by the next
                // real report and reset entirely on a root transition.
                remaining = prior?.remaining,
                remainingFailure = prior?.remainingFailure,
                preferencesFailure = prior?.preferencesFailure,
                partial = prior?.partial ?: false,
                historyRevision = history?.string("revision") ?: "",
                modelConfigRevision = modelConfig?.string("revision") ?: "",
                modelRemaining = prior?.modelRemaining,
                modelRemainingFailure = prior?.modelRemainingFailure,
                preferencesReset = prior?.preferencesReset,
                workspaceRemoved = prior?.workspaceRemoved,
                workspaceAbsent = prior?.workspaceAbsent,
                workspaceDeferred = prior?.workspaceDeferred,
            ),
            historyFailures = if (sameRoot) previous.historyFailures else emptyList(),
            modelConfigFailures = if (sameRoot) previous.modelConfigFailures else emptyList(),
            reportPage = if (sameRoot) previous.reportPage else null,
            rootEpoch = rootEpoch,
            previewGeneration = privacyEpochSource.incrementAndGet(),
        )
    }

    /**
     * Applies ONE completed clear report to the surface. The initial arrays
     * are bounded by the producer; [PrivacyReportPage] exposes the SAME
     * report handle for the remaining items through privacy.summary.get.
     * Each report owns ONE resource family: a history clear never erases a
     * model-config preference failure (and vice versa); `partial` reflects
     * the LATEST settled clear. Missing or malformed counts stay absent —
     * never invented zeros — and the omission is typed.
     *
     * Returns false ONLY when the completed outcome carries NO usable
     * report (null value, or an object with none of the report vocabulary):
     * the caller must then expose report-unavailable/uncertain and refresh
     * the counts — never a fabricated zero/success.
     */
    private fun applyPrivacyClearReport(root: JsonObject?, history: Boolean): Boolean {
        if (root == null) return false
        if (!hasReportVocabulary(root)) return false
        val failureKey = if (history) "failures" else "deletionFailures"
        val failures = (root.get(failureKey) as? JsonArray)
            ?.mapNotNull { decodeFailure(it as? JsonObject) } ?: emptyList()
        val remainingObject = root.obj("remaining")
        val remainingFailure = root.string("remainingFailure")
        val preferencesFailure = root.string("preferencesFailure")
        val wirePartial = root.bool("partial")
        val historyRemaining = if (history) decodeHistoryRemaining(remainingObject) else null
        val modelRemaining = if (history) null else decodeModelRemaining(remainingObject)
        // STRICT RECOUNT TRUTH: a usable recount requires the FULL count set
        // (every field present, integral, non-negative). Anything less is
        // unavailable: the counts stay absent, the omission is typed, and a
        // clear whose completeness cannot be shown is PARTIAL — even when
        // the wire claimed full success.
        val historyRecountUnavailable =
            history && (remainingObject == null || historyRemaining == null)
        val modelRecountUnavailable =
            !history && (remainingObject == null || modelRemaining == null)
        // Nullable truth: an absent `partial` flag is uncertainty, never a
        // silent claim of full success.
        val partial = (wirePartial ?: true) ||
            if (history) historyRecountUnavailable else modelRecountUnavailable
        val modelRemainingFailure = if (history) {
            null
        } else if (modelRecountUnavailable) {
            remainingFailure ?: "remainingRecountUnavailable"
        } else {
            remainingFailure
        }
        val preferencesReset = if (history) null else root.bool("preferencesReset")
        // ADDITIVE native accounting (G02-R7): real owned private-task
        // workspace directory effects. An absent key means an older native
        // build produced the report: stay null, never invent zeros (a
        // present all-zero block is itself the real "no ownership rows"
        // effect set).
        val workspaceDirectories = if (history) root.obj("workspaceDirectories") else null
        val workspaceRemoved = workspaceDirectories?.long("removed")
        val workspaceAbsent = workspaceDirectories?.long("absent")
        val workspaceDeferredCount = workspaceDirectories?.long("deferred")
        val page = root.obj("failurePage")?.let { p ->
            val handle = p.string("handle") ?: return@let null
            PrivacyReportPage(
                handle = handle,
                kind = if (history) "history" else "modelConfiguration",
                items = failures,
                nextCursor = p.string("nextCursor"),
                total = p.long("total") ?: failures.size.toLong(),
                done = p.string("nextCursor") == null,
            )
        }
        // The report slot has a new owner; late pages of the retired report
        // are fenced by this generation.
        privacyReportGeneration.incrementAndGet()
        update { state ->
            val prior = state.privacy
            val summary = prior.summary?.let { s ->
                s.copy(
                    remaining = if (history) historyRemaining else s.remaining,
                    remainingFailure = if (history) {
                        if (historyRecountUnavailable) {
                            remainingFailure ?: "remainingRecountUnavailable"
                        } else {
                            remainingFailure
                        }
                    } else {
                        s.remainingFailure
                    },
                    preferencesFailure = if (history) {
                        s.preferencesFailure
                    } else {
                        preferencesFailure
                    },
                    preferencesReset = if (history) s.preferencesReset else preferencesReset,
                    modelRemaining = if (history) s.modelRemaining else modelRemaining,
                    modelRemainingFailure = if (history) {
                        s.modelRemainingFailure
                    } else {
                        modelRemainingFailure
                    },
                    workspaceRemoved = if (history) {
                        workspaceRemoved
                    } else {
                        s.workspaceRemoved
                    },
                    workspaceAbsent = if (history) {
                        workspaceAbsent
                    } else {
                        s.workspaceAbsent
                    },
                    workspaceDeferred = if (history) {
                        workspaceDeferredCount
                    } else {
                        s.workspaceDeferred
                    },
                    partial = partial,
                )
            }
            state.copy(
                privacy = prior.copy(
                    summary = summary,
                    historyFailures = if (history) failures else prior.historyFailures,
                    modelConfigFailures = if (history) prior.modelConfigFailures else failures,
                    // The LATEST clear owns the single paging slot; a new
                    // clear without overflow retires the old handle.
                    reportPage = page,
                ),
            )
        }
        return true
    }

    /**
     * True when a completed clear reply carries at least one recognizable
     * report field; a Completed value with NONE of the report vocabulary
     * gives no basis to claim anything (unavailable, not success).
     */
    private fun hasReportVocabulary(root: JsonObject): Boolean =
        root.containsKey("failures") ||
            root.containsKey("deletionFailures") ||
            root.containsKey("remaining") ||
            root.containsKey("partial") ||
            root.containsKey("failurePage") ||
            root.containsKey("preferencesReset") ||
            root.containsKey("remainingFailure") ||
            root.containsKey("preferencesFailure") ||
            root.containsKey("enumerated") ||
            root.containsKey("deleted")

    private fun decodeFailure(obj: JsonObject?): PrivacyFailureProjection? {
        obj ?: return null
        return PrivacyFailureProjection(
            itemID = obj.string("itemID"),
            providerID = obj.string("providerID"),
            phase = obj.string("phase") ?: "unknown",
            reason = obj.string("reason") ?: "unknown",
        )
    }

    /**
     * STRICT count field: present, integral (Long-exact, no overflow) and
     * non-negative — anything else makes the WHOLE recount unavailable;
     * individual fields are never invented as zeros.
     */
    private fun strictCount(obj: JsonObject, key: String): Long? {
        val value = obj.long(key) ?: return null
        return if (value >= 0L) value else null
    }

    private fun decodeHistoryRemaining(obj: JsonObject?): PrivacyRemainingProjection? {
        obj ?: return null
        val conversationCount = strictCount(obj, "conversationCount") ?: return null
        val runCount = strictCount(obj, "runCount") ?: return null
        val persistedGrantCount = strictCount(obj, "persistedGrantCount") ?: return null
        val inMemoryGrantCount = strictCount(obj, "inMemoryGrantCount") ?: return null
        return PrivacyRemainingProjection(
            conversationCount = conversationCount,
            runCount = runCount,
            persistedGrantCount = persistedGrantCount,
            inMemoryGrantCount = inMemoryGrantCount,
        )
    }

    private fun decodeModelRemaining(obj: JsonObject?): PrivacyModelRemainingProjection? {
        obj ?: return null
        val providerCount = strictCount(obj, "providerCount") ?: return null
        val modelCount = strictCount(obj, "modelCount") ?: return null
        val secretReferenceCount = strictCount(obj, "secretReferenceCount") ?: return null
        return PrivacyModelRemainingProjection(
            providerCount = providerCount,
            modelCount = modelCount,
            secretReferenceCount = secretReferenceCount,
        )
    }


    // ------------------------------------------------------------ preferences

    /**
     * Reads the REAL `config.preferences.get` reply: the envelope value is
     * `{"revision":{resourceID:"preferences",version:<syncRevision>},
     *   "preferences":{…ModelSelectionPreferences…}}`.
     * The persisted default agent model lives at `preferences.
     * defaultAgentModelID` (the previous decoder read a non-existent top-level
     * `selectedModelID`, so the launchpad chip was always "no model").
     */
    fun refreshPreferences() {
        if (!host.readiness.value.providerConfigurationAdmitted) return
        host.trackOperation(
            HostCommandRequest(
                command = "config.preferences.get",
                scope = HostScope.ApplicationConfiguration("preferences"),
                stateful = false,
                correlationID = client().correlationID("pfget"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val revision = (root?.get("revision") as? JsonObject)
                        ?.string("version")
                    val preferences = root?.get("preferences") as? JsonObject
                    update {
                        it.copy(
                            preferences = PreferencesSurface(
                                selectedModelID = preferences?.string("defaultAgentModelID"),
                                revision = revision ?: "",
                                syncRevision = preferences?.long("syncRevision"),
                            ),
                            preferencesStatus = SurfaceStatus(),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(preferencesStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(preferencesStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
    }

    /**
     * Preferences CAS save under the REAL grammar: the payload is the FULL
     * `ModelSelectionPreferences` document with ONLY `defaultAgentModelID`
     * changed and `syncRevision` echoed from the read revision (the writer
     * validates the full-snapshot CAS and bumps the revision itself). The
     * previous `{selectedModelID}` stub was refused by the closed parser.
     */
    fun savePreferences(
        selectedModelID: String?,
        onOutcome: ((HostOperationOutcome) -> Unit)? = null,
    ): Boolean {
        if (!host.readiness.value.providerConfigurationAdmitted) return false
        val currentRevision = stateFlow.value.preferences.revision
        if (currentRevision.isBlank()) {
            // No real read yet: read once, then save against it.
            refreshPreferences()
            return true
        }
        host.trackOperation(
            HostCommandRequest(
                command = "config.preferences.get",
                scope = HostScope.ApplicationConfiguration("preferences"),
                stateful = false,
                correlationID = client().correlationID("pfget-pre"),
            ),
        ) { read ->
            if (read !is HostOperationOutcome.Completed) {
                update {
                    it.copy(preferencesStatus = SurfaceStatus(error = "preferences_unavailable"))
                }
                onOutcome?.invoke(read)
                return@trackOperation
            }
            val root = read.value as? JsonObject
            val revision = (root?.get("revision") as? JsonObject)?.string("version")
            val document = root?.get("preferences") as? JsonObject
            if (revision == null || document == null) {
                update {
                    it.copy(preferencesStatus = SurfaceStatus(error = "preferences_unavailable"))
                }
                return@trackOperation
            }
            val payload = JsonObject(
                LinkedHashMap(document).apply {
                    put("defaultAgentModelID",
                        selectedModelID?.let { JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull)
                    (revision.toLongOrNull())?.let { put("syncRevision", JsonPrimitive(it)) }
                },
            )
            host.trackOperation(
                HostCommandRequest(
                    command = "config.preferences.save",
                    scope = HostScope.ApplicationConfiguration("preferences"),
                    stateful = true,
                    correlationID = client().correlationID("pfsave"),
                    revision = HostRevision("preferences", revision),
                    payload = payload,
                ),
            ) { outcome ->
                onOutcome?.invoke(outcome)
                when (outcome) {
                    is HostOperationOutcome.Completed -> refreshPreferences()
                    is HostOperationOutcome.Rejected -> update {
                        it.copy(preferencesStatus = SurfaceStatus(error = outcome.code))
                    }
                    is HostOperationOutcome.Failed -> update {
                        it.copy(preferencesStatus = SurfaceStatus(error = outcome.code))
                    }
                    else -> Unit
                }
            }
        }
        return true
    }

    // --------------------------------------------------------------- decoders

    private fun decodeMemoryEntry(obj: JsonObject?): MemoryEntryProjection? {
        obj ?: return null
        return MemoryEntryProjection(
            id = obj.string("id") ?: return null,
            content = obj.string("content") ?: "",
            scopeKind = obj.obj("scope")?.string("kind") ?: "user",
            status = obj.string("status") ?: "active",
            importance = obj.obj("importance")?.let { (it as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull() }
                ?: obj.double("importance") ?: 0.5,
            isPinned = obj.bool("isPinned") ?: false,
            revision = obj.string("revision") ?: "",
        )
    }

    /**
     * ORIGINAL `MemorySearchItem` decode (R6): the contract carries
     * `current` (the live row or EXPLICIT null when it vanished between
     * recall and the fresh read) and `deleted`. The previous reader
     * invented a `projected` snapshot and compared revisions — the producer
     * never emits it, so `changedDuringSearch` was always false and a
     * deleted row was silently back-filled with fabricated content. The
     * only honest change signal is `deleted`; `current` stays null.
     */
    private fun decodeSearchItem(obj: JsonObject?): MemorySearchItemProjection? {
        obj ?: return null
        val currentElement = obj["current"]
        val current = if (currentElement == null ||
            currentElement is kotlinx.serialization.json.JsonNull
        ) {
            null
        } else {
            decodeMemoryEntry(currentElement as? JsonObject)
        }
        val deleted = obj.bool("deleted") ?: false
        return MemorySearchItemProjection(
            id = obj.string("id") ?: return null,
            current = current,
            deleted = deleted,
            changedDuringSearch = deleted,
        )
    }

    private fun decodeCandidate(obj: JsonObject?): MemoryCandidateProjection? {
        obj ?: return null
        return MemoryCandidateProjection(
            id = obj.string("id") ?: return null,
            content = obj.string("content") ?: "",
            status = obj.string("status") ?: "pending",
            revision = obj.string("revision") ?: "",
        )
    }

    private fun decodeSuggestion(obj: JsonObject?): OrganizeSuggestionProjection? {
        obj ?: return null
        return OrganizeSuggestionProjection(
            id = obj.string("id") ?: return null,
            kind = obj.string("kind") ?: "possibleDuplicate",
            reason = obj.string("reason") ?: "",
            canApplyAutomatically = obj.bool("canApplyAutomatically") ?: false,
            memoryIDs = (obj.get("memoryIDs") as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                ?: emptyList(),
            preferredMemoryID = obj.string("preferredMemoryID"),
        )
    }

    private fun decodeOrganizeEntry(obj: JsonObject?): OrganizeEntryProjection? {
        obj ?: return null
        return OrganizeEntryProjection(
            id = obj.string("id") ?: return null,
            scopeKind = obj.obj("scope")?.string("kind") ?: "user",
            status = obj.string("status") ?: "active",
            content = obj.string("content") ?: "",
            updatedAt = obj.string("updatedAt") ?: "",
        )
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.longOrNull

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

    private fun JsonObject.string(section: String, key: String): String? =
        obj(section)?.string(key)

    private companion object {
        /** Bounded chunk for owned-content reads (revision/handle bodies). */
        const val CONTENT_PAGE_BYTES = 16 * 1024

        /** Frozen `maximumBulkEntries` of the memory bulk-delete contract. */
        const val BULK_DELETE_LIMIT = 500
    }
}

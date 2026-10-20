// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
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
    private val stateFlow = MutableStateFlow(SettingsHostState())
    val state: StateFlow<SettingsHostState> = stateFlow

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
        val preferences: PreferencesSurface = PreferencesSurface(),
        val preferencesStatus: SurfaceStatus = SurfaceStatus(loading = true),
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
        val searchItems: List<MemorySearchItemProjection> = emptyList(),
        val searchActive: Boolean = false,
        val candidates: List<MemoryCandidateProjection> = emptyList(),
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

    data class OrganizeSurface(
        val proposalHandle: String,
        val scannedCount: Int,
        val suggestions: List<OrganizeSuggestionProjection>,
        val stale: Boolean,
        val proposalID: String = "",
    )

    data class OrganizeSuggestionProjection(
        val id: String,
        val kind: String,
        val reason: String,
        val canApplyAutomatically: Boolean,
    )

    data class PersonalizationSurface(
        val kind: String = "soul",
        val activeRevision: Int? = null,
        val content: String = "",
        val contentHandle: String? = null,
        val automaticUpdatesEnabled: Boolean = false,
        val latestRevision: Int = 0,
        val revisionToken: String = "",
        val generating: Boolean = false,
        val generateError: String? = null,
    )

    data class UsageSurface(
        val totals: UsageTotalsProjection? = null,
        val byDay: List<UsageDayProjection> = emptyList(),
        val rows: List<UsageBreakdownProjection> = emptyList(),
        val nextCursor: String? = null,
    )

    data class UsageTotalsProjection(
        val inputTokens: Long,
        val outputTokens: Long,
        val totalTokens: Long,
        val runs: Long,
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
    )

    data class PrivacySurface(
        val summary: PrivacySummaryProjection? = null,
        val historyFailures: List<PrivacyFailureProjection> = emptyList(),
        val modelConfigFailures: List<PrivacyFailureProjection> = emptyList(),
        /** Same-root report-store paging (never content.read). */
        val reportPage: PrivacyReportPage? = null,
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
    )

    data class PrivacyRemainingProjection(
        val conversationCount: Long,
        val runCount: Long,
        val persistedGrantCount: Long,
        val inMemoryGrantCount: Long,
    )

    data class PrivacyFailureProjection(
        val itemID: String?,
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

    data class PreferencesSurface(
        val selectedModelID: String? = null,
        val revision: String = "",
        val syncRevision: Long? = null,
    )

    internal fun start() {
        if (!host.readiness.value.storeReady) return
        refreshDefaults()
        refreshPreferences()
        if (host.readiness.value.settingsDomainsAdmitted.isNotEmpty()) {
            refreshMemory()
            refreshPersonalization()
            refreshUsage()
            refreshPrivacySummary()
        }
    }

    internal fun stop() {}

    private fun client() = host.commandClient
    private fun admitted(label: String): Boolean =
        host.readiness.value.storeReady &&
            (host.readiness.value.settingsDomainsAdmitted.contains(label) ||
                host.readiness.value.providerConfigurationAdmitted)

    private inline fun update(transform: (SettingsHostState) -> SettingsHostState) {
        stateFlow.value = transform(stateFlow.value)
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

    fun refreshMemory(cursor: String? = null) {
        if (!admitted("settings.memory")) return
        update { it.copy(memoryStatus = SurfaceStatus(loading = true)) }
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
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    update {
                        it.copy(
                            memoryStatus = SurfaceStatus(),
                            memory = it.memory.copy(
                                entries = (root?.get("entries") as? JsonArray)
                                    ?.mapNotNull { e -> decodeMemoryEntry(e as? JsonObject) }
                                    ?: emptyList(),
                                nextCursor = root?.string("nextCursor"),
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(memoryStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(memoryStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
    }

    fun searchMemory(query: String) {
        if (!admitted("settings.memory")) return
        update {
            it.copy(memory = it.memory.copy(searchActive = true))
        }
        host.trackOperation(
            HostCommandRequest(
                command = "memory.search",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("msearch"),
                payload = JsonObject(mapOf("query" to JsonPrimitive(query), "limit" to JsonPrimitive(20))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    val projected = (root?.get("items") as? JsonArray)
                        ?.mapNotNull { e -> decodeSearchItem(e as? JsonObject) }
                        ?: emptyList()
                    update {
                        it.copy(
                            memoryStatus = SurfaceStatus(),
                            memory = it.memory.copy(
                                searchItems = projected,
                                searchActive = true,
                            ),
                        )
                    }
                }
                else -> update { it.copy(memoryStatus = SurfaceStatus()) }
            }
        }
    }

    fun clearMemorySearch() {
        update { it.copy(memory = it.memory.copy(searchItems = emptyList(), searchActive = false)) }
    }

    fun addMemory(content: String, scopeKind: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
            return
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
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    refreshMemory()
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun updateMemory(
        id: String,
        revision: String,
        content: String?,
        importance: Double?,
        isPinned: Boolean?,
        onOutcome: (String?) -> Unit,
    ) {
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
            return
        }
        val changes = mutableMapOf<String, JsonElement>()
        content?.let { changes["content"] = JsonPrimitive(it) }
        importance?.let { changes["importance"] = JsonPrimitive(it) }
        isPinned?.let { changes["isPinned"] = JsonPrimitive(it) }
        if (changes.isEmpty()) {
            onOutcome(null)
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
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    refreshMemory()
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun deleteMemory(id: String, revision: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.memory")) {
            onOutcome("unavailable")
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
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    refreshMemory()
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun listCandidates() {
        if (!admitted("settings.memory")) return
        host.trackOperation(
            HostCommandRequest(
                command = "memory.candidates.list",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = false,
                correlationID = client().correlationID("mcand"),
                payload = JsonObject(mapOf("limit" to JsonPrimitive(50))),
            ),
        ) { outcome ->
            if (outcome is HostOperationOutcome.Completed) {
                val root = outcome.value as? JsonObject
                update {
                    it.copy(
                        memory = it.memory.copy(
                            candidates = (root?.get("candidates") as? JsonArray)
                                ?.mapNotNull { c -> decodeCandidate(c as? JsonObject) }
                                ?: emptyList(),
                        ),
                    )
                }
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
        host.trackOperation(
            HostCommandRequest(
                command = "memory.organize.start",
                scope = HostScope.ApplicationConfiguration("memory"),
                stateful = true,
                correlationID = client().correlationID("morg"),
                createIntent = true,
                payload = JsonObject(
                    mapOf(
                        "mode" to JsonPrimitive("reviewFirst"),
                        "includeSemantic" to JsonPrimitive(includeSemantic),
                    ),
                ),
            ),
        ) { outcome ->
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
                                        stale = false,
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

    fun readOrganizeProposal(handle: String, cursor: String?) {
        if (!admitted("settings.memory")) return
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
            if (outcome is HostOperationOutcome.Completed) {
                val root = outcome.value as? JsonObject
                update {
                    it.copy(
                        memory = it.memory.copy(
                            organize = OrganizeSurface(
                                proposalHandle = handle,
                                scannedCount = root?.long("scannedCount")?.toInt() ?: 0,
                                suggestions = (root?.get("suggestions") as? JsonArray)
                                    ?.mapNotNull { s -> decodeSuggestion(s as? JsonObject) }
                                    ?: emptyList(),
                                stale = root?.bool("stale") ?: false,
                                proposalID = root?.string("proposalID") ?: "",
                            ),
                        ),
                    )
                }
            }
        }
    }

    // ------------------------------------------------------- personalization

    fun refreshPersonalization(kind: String = "soul") {
        if (!admitted("settings.personalization")) return
        update { it.copy(personalizationStatus = SurfaceStatus(loading = true)) }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.get",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = false,
                correlationID = client().correlationID("pget"),
                payload = JsonObject(mapOf("kind" to JsonPrimitive(kind))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    update {
                        it.copy(
                            personalizationStatus = SurfaceStatus(),
                            personalization = PersonalizationSurface(
                                kind = kind,
                                activeRevision = root?.long("latestRevision")?.toInt(),
                                content = root?.obj("active")?.string("content") ?: "",
                                contentHandle = root?.obj("active")?.obj("contentHandle")
                                    ?.string("handle"),
                                automaticUpdatesEnabled = root?.obj("cursor")
                                    ?.bool("automaticUpdatesEnabled") ?: false,
                                latestRevision = root?.long("latestRevision")?.toInt() ?: 0,
                                revisionToken = root?.string("revisionToken") ?: "",
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(personalizationStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(personalizationStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
    }

    fun savePersonalization(kind: String, content: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.save",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = true,
                correlationID = client().correlationID("psave"),
                revision = HostRevision(
                    "personalization.$kind",
                    stateFlow.value.personalization.revisionToken,
                ),
                payload = JsonObject(
                    mapOf("kind" to JsonPrimitive(kind), "content" to JsonPrimitive(content)),
                ),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    refreshPersonalization(kind)
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun setPersonalizationAutomatic(kind: String, enabled: Boolean, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
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
                    refreshPersonalization(kind)
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun generatePersonalization(kind: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.personalization")) {
            onOutcome("unavailable")
            return
        }
        update { it.copy(personalization = it.personalization.copy(generating = true)) }
        host.trackOperation(
            HostCommandRequest(
                command = "personalization.generate",
                scope = HostScope.ApplicationConfiguration("personalization"),
                stateful = true,
                correlationID = client().correlationID("pgen"),
                createIntent = true,
                payload = JsonObject(mapOf("kind" to JsonPrimitive(kind))),
            ),
        ) { outcome ->
            update { it.copy(personalization = it.personalization.copy(generating = false)) }
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    refreshPersonalization(kind)
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

    fun refreshUsage() {
        if (!admitted("settings.usage")) return
        update { it.copy(usageStatus = SurfaceStatus(loading = true)) }
        host.trackOperation(
            HostCommandRequest(
                command = "usage.statistics.get",
                scope = HostScope.ApplicationConfiguration("usage"),
                stateful = false,
                correlationID = client().correlationID("uget"),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val root = outcome.value as? JsonObject
                    update {
                        it.copy(
                            usageStatus = SurfaceStatus(),
                            usage = UsageSurface(
                                totals = (root?.get("totals") as? JsonObject)?.let { t ->
                                    UsageTotalsProjection(
                                        inputTokens = t.long("inputTokens") ?: 0,
                                        outputTokens = t.long("outputTokens") ?: 0,
                                        totalTokens = t.long("totalTokens") ?: 0,
                                        runs = t.long("runs") ?: 0,
                                    )
                                },
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
                                rows = (root?.get("rows") as? JsonArray)
                                    ?.mapNotNull { r ->
                                        (r as? JsonObject)?.let { row ->
                                            UsageBreakdownProjection(
                                                id = row.string("id") ?: "",
                                                label = row.string("label") ?: "",
                                                inputTokens = row.long("inputTokens") ?: 0,
                                                outputTokens = row.long("outputTokens") ?: 0,
                                                runs = row.long("runs") ?: 0,
                                            )
                                        }
                                    } ?: emptyList(),
                                nextCursor = root?.string("nextCursor"),
                            ),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(usageStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(usageStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
    }

    // ---------------------------------------------------------------- privacy

    fun refreshPrivacySummary() {
        if (!admitted("settings.privacy")) return
        update { it.copy(privacyStatus = SurfaceStatus(loading = true)) }
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
                    val root = outcome.value as? JsonObject
                    update {
                        it.copy(
                            privacyStatus = SurfaceStatus(),
                            privacy = decodePrivacySummary(root),
                        )
                    }
                }
                is HostOperationOutcome.Rejected -> update {
                    it.copy(privacyStatus = SurfaceStatus(error = outcome.code))
                }
                is HostOperationOutcome.Failed -> update {
                    it.copy(privacyStatus = SurfaceStatus(error = outcome.code))
                }
                else -> Unit
            }
        }
    }

    /** Failure/deletionFailure page through the SAME privacy.summary.get. */
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
                    val page = (outcome.value as? JsonObject)?.obj("report")?.let { r ->
                        PrivacyReportPage(
                            handle = r.string("handle") ?: handle,
                            kind = r.string("kind") ?: kind,
                            items = (r.get("items") as? JsonArray)
                                ?.mapNotNull { decodeFailure(it as? JsonObject) }
                                ?: emptyList(),
                            nextCursor = r.string("nextCursor"),
                            total = r.long("total") ?: 0,
                            done = r.bool("done") ?: true,
                        )
                    }
                    if (page != null) {
                        update { state ->
                            state.copy(privacy = state.privacy.copy(reportPage = page))
                        }
                    }
                    onResult(page)
                }
                else -> onResult(null)
            }
        }
    }

    /**
     * Mint a trusted clear confirmation for the CURRENT preview + epoch.
     * Returns the confirmToken only after an exact user tap on the previewed
     * action row; the digest alone is never consent.
     */
    fun mintClearConfirmation(action: PrivacyClearAction, tappedPreviewEpoch: Long): String? {
        val summary = stateFlow.value.privacy.summary ?: return null
        val currentEpoch = privacyPreviewEpoch
        if (tappedPreviewEpoch != currentEpoch) return null
        return when (action) {
            PrivacyClearAction.HISTORY -> summary.historyRevision
            PrivacyClearAction.MODEL_CONFIGURATION -> summary.modelConfigRevision
        }
    }

    /** Bump whenever a fresh preview is projected (invalidates old taps). */
    val privacyPreviewEpoch: Long
        get() = privacyEpochSource.get()

    private val privacyEpochSource = java.util.concurrent.atomic.AtomicLong(0)

    enum class PrivacyClearAction { HISTORY, MODEL_CONFIGURATION }

    fun clearPrivacyHistory(confirmToken: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.privacy")) {
            onOutcome("unavailable")
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "privacy.history.clear",
                scope = HostScope.ApplicationConfiguration("privacy"),
                stateful = true,
                correlationID = client().correlationID("prh"),
                revision = HostRevision("privacy.history", confirmToken),
                payload = JsonObject(mapOf("confirmToken" to JsonPrimitive(confirmToken))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    privacyEpochSource.incrementAndGet()
                    refreshPrivacySummary()
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    fun clearPrivacyModelConfiguration(confirmToken: String, onOutcome: (String?) -> Unit) {
        if (!admitted("settings.privacy")) {
            onOutcome("unavailable")
            return
        }
        host.trackOperation(
            HostCommandRequest(
                command = "privacy.modelConfiguration.clear",
                scope = HostScope.ApplicationConfiguration("privacy"),
                stateful = true,
                correlationID = client().correlationID("prm"),
                revision = HostRevision("privacy.modelConfiguration", confirmToken),
                payload = JsonObject(mapOf("confirmToken" to JsonPrimitive(confirmToken))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    privacyEpochSource.incrementAndGet()
                    refreshPrivacySummary()
                    onOutcome(null)
                }
                is HostOperationOutcome.Rejected -> onOutcome(outcome.code)
                is HostOperationOutcome.Failed -> onOutcome(outcome.code)
                else -> onOutcome("cancelled")
            }
        }
    }

    private fun decodePrivacySummary(root: JsonObject?): PrivacySurface {
        root ?: return PrivacySurface()
        val history = root.obj("history")
        val modelConfig = root.obj("modelConfiguration")
        val remainingFailure = root.string("remainingFailure")
        val partial = root.bool("partial") ?: false
        val remaining = root.obj("remaining")?.let { r ->
            PrivacyRemainingProjection(
                conversationCount = r.long("conversationCount") ?: 0,
                runCount = r.long("runCount") ?: 0,
                persistedGrantCount = r.long("persistedGrantCount") ?: 0,
                inMemoryGrantCount = r.long("inMemoryGrantCount") ?: 0,
            )
        }
        val validRemaining = remaining ?: run {
            // remaining is null ONLY with a typed remainingFailure AND
            // partial=true (Main decision). A producer that omitted both is
            // surfaced as a typed recount-unavailable — never inferred zeros.
            if (partial && remainingFailure != null) {
                null
            } else {
                null
            }
        }
        val effectiveFailure = remainingFailure
            ?: if (remaining == null) "remainingRecountUnavailable" else null
        val effectivePartial = partial || (remaining == null)
        val surface = PrivacySurface(
            summary = PrivacySummaryProjection(
                conversationCount = history?.long("conversationCount") ?: 0,
                runCount = history?.long("runCount") ?: 0,
                persistedGrantCount = history?.long("persistedGrantCount") ?: 0,
                inMemoryGrantCount = history?.long("inMemoryGrantCount") ?: 0,
                providerCount = modelConfig?.long("providerCount") ?: 0,
                modelCount = modelConfig?.long("modelCount") ?: 0,
                secretReferenceCount = modelConfig?.long("secretReferenceCount") ?: 0,
                preferencesSyncRevision = modelConfig?.long("preferencesSyncRevision") ?: 0,
                remaining = validRemaining,
                remainingFailure = effectiveFailure,
                preferencesFailure = root.string("preferencesFailure"),
                partial = effectivePartial,
                historyRevision = history?.string("revision") ?: "",
                modelConfigRevision = modelConfig?.string("revision") ?: "",
            ),
            historyFailures = (root.get("failures") as? JsonArray)
                ?.mapNotNull { decodeFailure(it as? JsonObject) } ?: emptyList(),
            modelConfigFailures = (root.get("deletionFailures") as? JsonArray)
                ?.mapNotNull { decodeFailure(it as? JsonObject) } ?: emptyList(),
        )
        privacyEpochSource.incrementAndGet()
        return surface
    }

    private fun decodeFailure(obj: JsonObject?): PrivacyFailureProjection? {
        obj ?: return null
        return PrivacyFailureProjection(
            itemID = obj.string("itemID"),
            phase = obj.string("phase") ?: "unknown",
            reason = obj.string("reason") ?: "unknown",
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

    private fun decodeSearchItem(obj: JsonObject?): MemorySearchItemProjection? {
        obj ?: return null
        val current = decodeMemoryEntry(obj.obj("current"))
        val projectedEntry = obj.obj("projected")?.let { decodeMemoryEntry(it) }
        val changed = current != null && projectedEntry != null &&
            current.revision != projectedEntry.revision
        return MemorySearchItemProjection(
            id = obj.string("id") ?: return null,
            current = current ?: projectedEntry,
            deleted = obj.bool("deleted") ?: false,
            changedDuringSearch = changed,
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
}

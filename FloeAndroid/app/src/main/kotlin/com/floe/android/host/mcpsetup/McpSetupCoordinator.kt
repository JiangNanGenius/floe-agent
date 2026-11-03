// SPDX-License-Identifier: MPL-2.0
//
// C02 App-side driver for the guided Linux-owned MCP service setup.
//
// It runs only a user-started operation, polls bounded native phases on the
// IO dispatcher, and surfaces typed failures without inventing a running
// service, a saved connection or a generated tool. Its final commit is the
// native MCP-domain save; `onCommitted` only asks the existing MCP list to
// re-read the real row.
package com.floe.android.host.mcpsetup

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class McpSetupSnapshot(
    val loading: Boolean = false,
    val capabilities: McpSetupCapabilitiesDto? = null,
    val projects: List<McpSetupProjectDto> = emptyList(),
    val environments: List<McpSetupEnvironmentDto> = emptyList(),
    val selectedProjectId: String? = null,
    val templateAvailable: Boolean = false,
    val record: McpSetupRecordDto? = null,
    val busy: Boolean = false,
    val error: McpSetupException? = null,
    val lastPreflight: McpSetupPreflightDto? = null,
)

fun interface McpSetupTemplateProviding {
    /** Returns the verified App-bundled template bytes, or null honestly. */
    fun load(): ByteArray?
}

class McpSetupCoordinator(
    private val scope: CoroutineScope,
    private val client: McpSetupService,
    private val template: McpSetupTemplateProviding,
    private val onCommitted: (McpSetupRecordDto) -> Unit = {},
) {
    private val mutable = MutableStateFlow(McpSetupSnapshot())
    val state: StateFlow<McpSetupSnapshot> = mutable.asStateFlow()

    private var operation: Job? = null
    private var lastDraft: McpSetupDraftDto? = null

    fun load(projectId: String? = null) {
        if (operation?.isActive == true) return
        mutable.update { it.copy(loading = true, error = null) }
        scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    val capabilities = client.capabilities()
                    val projects = client.projects()
                    val environments = projectId?.let { client.environments(it) } ?: emptyList()
                    Triple(capabilities, projects, environments)
                }
                val bundled = withContext(Dispatchers.IO) { template.load() != null }
                mutable.update {
                    it.copy(
                        loading = false,
                        capabilities = result.first,
                        projects = result.second,
                        environments = result.third,
                        selectedProjectId = projectId,
                        templateAvailable = bundled,
                    )
                }
            } catch (error: McpSetupException) {
                mutable.update { it.copy(loading = false, error = error) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                mutable.update {
                    it.copy(
                        loading = false,
                        error = McpSetupException(
                            "unavailable",
                            "The MCP setup service is not available right now.",
                            retryable = true,
                        ),
                    )
                }
            }
        }
    }

    fun selectProject(projectId: String) {
        if (operation?.isActive == true) return
        mutable.update { it.copy(selectedProjectId = projectId, environments = emptyList()) }
        scope.launch {
            try {
                val environments = withContext(Dispatchers.IO) { client.environments(projectId) }
                mutable.update {
                    if (it.selectedProjectId == projectId) it.copy(environments = environments)
                    else it
                }
            } catch (error: McpSetupException) {
                mutable.update { it.copy(error = error) }
            }
        }
    }

    fun preflight(draft: McpSetupDraftDto): McpSetupPreflightDto {
        val local = McpSetupRules.findings(draft)
        val native = runCatching { client.validate(draft) }.getOrNull()
        val result = native ?: McpSetupPreflightDto(local.isEmpty(), local, draft.portText.toIntOrNull())
        mutable.update { it.copy(lastPreflight = result) }
        return result
    }

    fun start(draft: McpSetupDraftDto) {
        if (operation?.isActive == true) return
        val findings = McpSetupRules.findings(draft)
        if (findings.isNotEmpty()) {
            mutable.update {
                it.copy(
                    lastPreflight = McpSetupPreflightDto(false, findings, draft.portText.toIntOrNull()),
                    error = McpSetupException("invalidDraft", findings.first()),
                )
            }
            return
        }
        val bytes = template.load()
        if (bytes == null) {
            mutable.update {
                it.copy(error = McpSetupException(
                    "templateMissing",
                    "The verified MCP service template is not bundled in this build.",
                    retryable = false,
                ))
            }
            return
        }
        lastDraft = draft
        mutable.update { it.copy(busy = true, error = null, record = null) }
        operation = scope.launch {
            var current: McpSetupRecordDto? = null
            try {
                val created = withContext(Dispatchers.IO) { client.create(draft) }
                current = created
                publish(created)
                withContext(Dispatchers.IO) { client.stageTemplate(created.id, bytes) }
                var record = withContext(Dispatchers.IO) { client.prepare(created) }
                current = record
                publish(record)
                record = driveGenerationAndBuild(record)
                current = record
                if (record.phase == "readyToStart") {
                    record = withContext(Dispatchers.IO) { client.serviceStart(record) }
                    current = record
                    publish(record)
                }
                if (record.phase == "starting" || record.phase == "verifying") {
                    record = withContext(Dispatchers.IO) { client.verify(record) }
                    current = record
                    publish(record)
                }
                if (record.phase == "ready") {
                    record = withContext(Dispatchers.IO) { client.commit(record) }
                    current = record
                    publish(record)
                }
                if (record.phase == "added") {
                    onCommitted(record)
                    mutable.update { it.copy(busy = false, error = null) }
                } else {
                    mutable.update {
                        it.copy(
                            busy = false,
                            error = McpSetupException(
                                record.errorCode ?: "setupIncomplete",
                                record.errorMessage ?: "The MCP service was not added.",
                                retryable = true,
                            ),
                        )
                    }
                }
            } catch (cancelled: CancellationException) {
                // The explicit cancel path settles the native record.
                throw cancelled
            } catch (error: McpSetupException) {
                if (error.code != "connectionSaveFailed" &&
                    error.code != "staleRecord" &&
                    error.code != "operationTimedOut") {
                    current?.let { record ->
                        val latest = latestRecord(record)
                        runCatching {
                            withContext(Dispatchers.IO) { client.stop(latest, discard = false) }
                        }
                    }
                }
                mutable.update { it.copy(busy = false, error = error, record = current) }
            } catch (_: Throwable) {
                mutable.update {
                    it.copy(
                        busy = false,
                        record = current,
                        error = McpSetupException(
                            "internalError",
                            "The MCP service setup did not finish.",
                            retryable = true,
                        ),
                    )
                }
            }
        }
    }

    private suspend fun driveGenerationAndBuild(start: McpSetupRecordDto): McpSetupRecordDto {
        var record = start
        while (true) {
            when (record.phase) {
                "preparing", "generating" -> {
                    record = withContext(Dispatchers.IO) { client.prepare(record) }
                    publish(record)
                    if (record.phase == "generating") delay(POLL_MILLIS)
                }
                "prepared" -> {
                    record = withContext(Dispatchers.IO) { client.buildStart(record) }
                    publish(record)
                    if (record.phase == "building") delay(POLL_MILLIS)
                }
                "failed", "interrupted", "stopped" -> throw McpSetupException(
                    record.errorCode ?: "setupFailed",
                    record.errorMessage ?: "The MCP service setup failed.",
                    retryable = record.phase != "stopped",
                )
                "building" -> {
                    record = withContext(Dispatchers.IO) { client.buildPoll(record) }
                    publish(record)
                    if (record.phase == "building") delay(POLL_MILLIS)
                }
                "readyToStart", "starting", "verifying", "ready", "added" -> return record
                else -> throw McpSetupException(
                    record.errorCode ?: "invalidPhase",
                    record.errorMessage ?: "The MCP service reached an unexpected setup phase.",
                )
            }
        }
    }

    fun cancel() {
        val record = mutable.value.record
        operation?.cancel()
        operation = null
        if (record == null) {
            mutable.update { it.copy(busy = false, error = null) }
            return
        }
        mutable.update { it.copy(busy = true) }
        scope.launch {
            try {
                val latest = latestRecord(record)
                val settled = withContext(Dispatchers.IO) { client.stop(latest, discard = false) }
                mutable.update {
                    it.copy(
                        busy = false,
                        record = settled,
                        error = if (settled?.phase == "stopped") null else it.error,
                    )
                }
            } catch (error: McpSetupException) {
                mutable.update { it.copy(busy = false, error = error) }
            }
        }
    }

    fun discard() {
        val record = mutable.value.record ?: return
        if (record.phase == "added") {
            mutable.update {
                it.copy(error = McpSetupException(
                    "alreadyAdded",
                    "Delete the saved MCP server from the server list instead.",
                ))
            }
            return
        }
        operation?.cancel()
        operation = null
        mutable.update { it.copy(busy = true) }
        scope.launch {
            try {
                val latest = latestRecord(record)
                withContext(Dispatchers.IO) { client.stop(latest, discard = true) }
                mutable.update {
                    it.copy(
                        busy = false,
                        record = null,
                        error = null,
                        lastPreflight = null,
                    )
                }
            } catch (error: McpSetupException) {
                mutable.update { it.copy(busy = false, error = error) }
            }
        }
    }

    fun clearError() {
        mutable.update { it.copy(error = null) }
    }

    /** Retry only a verified connection commit. The service and receipt stay
     * live; no dependency phase is replayed. */
    fun retryCommit(recordId: String, revision: Long) {
        if (operation?.isActive == true) return
        val current = mutable.value.record ?: return
        if (current.id != recordId || current.revision != revision || current.phase != "ready") return
        mutable.update { it.copy(busy = true, error = null) }
        operation = scope.launch {
            try {
                val latest = latestRecord(current)
                if (latest.phase == "added") {
                    publish(latest)
                    onCommitted(latest)
                    mutable.update { it.copy(busy = false, error = null) }
                    return@launch
                }
                val record = withContext(Dispatchers.IO) { client.commit(latest) }
                publish(record)
                if (record.phase == "added") {
                    onCommitted(record)
                    mutable.update { it.copy(busy = false, error = null) }
                } else {
                    mutable.update {
                        it.copy(
                            busy = false,
                            error = McpSetupException(
                                record.errorCode ?: "connectionSaveFailed",
                                record.errorMessage ?: "The MCP connection could not be saved.",
                                retryable = true,
                            ),
                        )
                    }
                }
            } catch (error: McpSetupException) {
                mutable.update { it.copy(busy = false, error = error, record = current) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                mutable.update {
                    it.copy(
                        busy = false,
                        error = McpSetupException(
                            "connectionSaveFailed",
                            "The MCP connection could not be saved.",
                            retryable = true,
                        ),
                    )
                }
            }
        }
    }

    fun lastDraft(): McpSetupDraftDto? = lastDraft

    private fun publish(record: McpSetupRecordDto) {
        mutable.update { it.copy(record = record, error = null) }
    }

    private fun latestRecord(record: McpSetupRecordDto): McpSetupRecordDto =
        runCatching { client.records().firstOrNull { it.id == record.id } }
            .getOrNull() ?: record

    private companion object {
        const val POLL_MILLIS = 750L
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import android.content.ContentResolver
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.core.network.PhoneNetworkService
import com.floe.android.core.networkmonitor.CoverageLimits
import com.floe.android.core.networkmonitor.CoverageMetrics
import com.floe.android.core.networkmonitor.CoverageProbeParser
import com.floe.android.core.networkmonitor.CoverageReportRenderer
import com.floe.android.core.networkmonitor.CoverageScanParser
import com.floe.android.core.networkmonitor.CoverageSessionStore
import com.floe.android.core.pcap.PcapAnalysisStore
import com.floe.android.core.pcap.PcapCancellation
import com.floe.android.core.pcap.PcapLimits
import com.floe.android.core.pcap.PcapReportRenderer
import com.floe.android.core.pcap.PcapSummary
import com.floe.android.core.pcap.PcapSummaryCodec
import com.floe.android.core.pcap.PcapSummaryView
import com.floe.android.feature.network.CoverageExportFormatUi
import com.floe.android.feature.network.CoverageSampleRequest
import com.floe.android.feature.network.NetworkArtifactFailure
import com.floe.android.feature.network.NetworkArtifactState
import com.floe.android.feature.network.PcapExportFormatUi
import com.floe.android.feature.network.PcapFilterQuery
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class PhoneCoverageExecutor(
    private val service: PhoneNetworkService,
) : CoverageCaptureExecutor {
    override suspend fun execute(requestJson: String): String = service.execute(requestJson)
    override fun cancel(operationID: String) = service.cancel(operationID)
}

/** One picked content URI; no absolute paths, no broad file picker grants. */
internal class AndroidPcapContentSource(
    private val resolver: ContentResolver,
    private val uri: Uri,
) : PcapContentSource {
    override val displayName: String? by lazy {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0)?.take(128) else null
            }
        }.getOrNull()
    }
    override val mimeType: String? get() = runCatching { resolver.getType(uri) }.getOrNull()
    override val declaredBytes: Long? by lazy {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
            }
        }.getOrNull()?.takeIf { it > 0 }
    }

    override fun openStream(): InputStream =
        resolver.openInputStream(uri) ?: throw IOException("sourceUnavailable")
}

/**
 * Application-owned G07.3B artifact controller.
 *
 * It owns the App-private capture/coverage stores and all UI-triggered
 * work. It also owns the epoch-fenced tool pump (started by the host root
 * lifecycle) so `network.pcapAnalyze` and `network.coverageSummary` read the
 * same saved artifacts through opaque IDs only. There is no second permission
 * registry: the pump is a read-only store reader plus the task-ownership check
 * recorded with each artifact.
 */
class NetworkArtifactHostController(
    context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val currentNativeEpoch: () -> Long?,
    networkService: PhoneNetworkService,
    private val workspaceIdProvider: () -> String? = { null },
    private val access: NetworkArtifactAccess = NetworkArtifactAccess.DENY_ALL,
) {
    private val appContext = context.applicationContext
    private val root = File(appContext.filesDir, "network-artifacts")
    private val staging = File(root, "staging")
    private val pcapStore = PcapAnalysisStore(File(root, "pcap"))
    private val coverageStore = CoverageSessionStore(File(root, "coverage"))
    private val pcapImporter = PcapImportRunner(pcapStore, staging)
    private val coverage = CoverageArtifactCoordinator(
        store = coverageStore,
        executor = PhoneCoverageExecutor(networkService),
        currentTaskId = { null },
        ownerWorkspaceId = workspaceIdProvider(),
    )
    private val pump = NetworkArtifactHostPump(
        scope = scope,
        ioDispatcher = ioDispatcher,
        currentNativeEpoch = currentNativeEpoch,
        pcapStore = pcapStore,
        coverageStore = coverageStore,
        access = access,
    )
    private val mutableState = MutableStateFlow(NetworkArtifactState())
    val state: StateFlow<NetworkArtifactState> = mutableState.asStateFlow()
    private val loaded = AtomicBoolean(false)
    private val stopping = AtomicBoolean(false)
    private val importCancelled = AtomicBoolean(false)
    private var importJob: Job? = null
    private var coverageJob: Job? = null
    private var pcapExportJob: Job? = null
    private var coverageExportJob: Job? = null
    private var exportCancelled = AtomicBoolean(false)
    private val ownedJobs = java.util.concurrent.ConcurrentHashMap.newKeySet<Job>()
    private var selectedPcap: PcapSummary? = null
    private var pcapSelectionRequest: String? = null
    private var coverageSelectionRequest: String? = null
    private val pcapGrants = mutableMapOf<String, Boolean>()

    fun enter() {
        if (stopping.get()) return
        // UI entry is cheap: no disk scan, no job cancellation. Initial list
        // loading and stale orphan cleanup are service-owned IO; a re-enter
        // never touches an active import/export.
        if (loaded.compareAndSet(false, true)) {
            launchOwned {
                cleanupOrphanedStaging()
                reloadLists()
            }
        }
    }

    /**
     * Panel hide is not navigation away from the work: active analysis,
     * sampling and exports stay service-owned. Only an explicit Cancel or
     * Root retirement drains them.
     */
    fun leave() {
        mutableState.update {
            it.copy(
                pcap = it.pcap.copy(selectedID = null, selected = null),
                coverage = it.coverage.copy(selectedID = null, selected = null),
            )
        }
        synchronized(this) {
            selectedPcap = null
            pcapSelectionRequest = null
        }
        coverageSelectionRequest = null
    }

    /** Explicit user Cancel for the current analysis/transfer, bounded. */
    fun cancelActiveWork() {
        importCancelled.set(true)
        exportCancelled.set(true)
        importJob?.cancel()
        coverageJob?.cancel()
    }

    suspend fun start(epoch: Long): Boolean {
        stopping.set(false)
        return pump.start(epoch)
    }

    /** Every UI-triggered IO task is owned here so Root drain can prove it. */
    private fun launchOwned(block: suspend kotlinx.coroutines.CoroutineScope.() -> Unit): Job {
        val job = scope.launch(ioDispatcher, block = block)
        ownedJobs.add(job)
        job.invokeOnCompletion { ownedJobs.remove(job) }
        return job
    }

    /**
     * Root retirement: drain every owned job before the native root retires,
     * even when no mailbox epoch was bound (boundEpoch == 0). A false result
     * keeps the old generation owned; it is never reported as drained.
     */
    suspend fun stopAndJoin(expectedEpoch: Long, waitMillis: Long): Boolean {
        require(waitMillis > 0) { "waitMillis must be positive" }
        stopping.set(true)
        val deadline = System.nanoTime() + waitMillis * 1_000_000L
        importCancelled.set(true)
        exportCancelled.set(true)
        val pumpBudget = ((deadline - System.nanoTime()) / 1_000_000L)
            .coerceIn(1L, waitMillis)
        val artifactReady = pump.stopAndJoin(expectedEpoch, pumpBudget)
        val pending = ownedJobs.toList()
        pending.forEach { it.cancel() }
        var jobsReady = true
        if (pending.isNotEmpty()) {
            val remaining = ((deadline - System.nanoTime()) / 1_000_000L).coerceAtLeast(1L)
            val joined = kotlinx.coroutines.withTimeoutOrNull(remaining) {
                pending.forEach { it.join() }
            } != null
            if (!joined) jobsReady = false
        }
        return artifactReady && jobsReady
    }

    fun boundEpoch(): Long = pump.boundNativeEpoch

    fun statsJson(): String? = pump.statsJson()

    fun readinessJson(): String? = pump.readinessJson()

    // ------------------------------------------------------------------
    // Capture analysis
    // ------------------------------------------------------------------

    fun importPcap(uri: Uri, detailed: Boolean) {
        if (stopping.get()) return
        if (importJob?.isActive == true) return
        importCancelled.set(false)
        mutableState.update { it.copy(pcap = it.pcap.copy(importing = true, busy = true,
            importedBytes = 0L, failure = null, exportedBytes = null)) }
        val source = AndroidPcapContentSource(appContext.contentResolver, uri)
        importJob = launchOwned {
            val result = runCatching {
                pcapImporter.import(
                    source = source,
                    detailed = detailed,
                    ownerWorkspaceId = workspaceIdProvider(),
                    agentReadable = false,
                    cancellation = PcapCancellation { importCancelled.get() },
                    onProgress = { bytes ->
                        mutableState.update { state ->
                            state.copy(pcap = state.pcap.copy(importedBytes = bytes))
                        }
                    },
                )
            }.getOrElse { failure ->
                if (failure is CancellationException) throw failure
                PcapImportResult.Failure(PcapImportFailure.READ_FAILED)
            }
            synchronized(this@NetworkArtifactHostController) {
                when (result) {
                    is PcapImportResult.Success -> {
                        selectedPcap = result.summary
                        mutableState.update { state ->
                            state.copy(pcap = state.pcap.copy(
                                importing = false, busy = false,
                                importedBytes = 0L, failure = null,
                                selectedID = result.analysisID,
                            ))
                        }
                        refreshPcapLists()
                        publishPcap(result.summary, PcapFilterQuery(emptySet(), emptySet(), null, null, null, null), forceSelection = true)
                    }
                    is PcapImportResult.Failure -> mutableState.update { state ->
                        state.copy(pcap = state.pcap.copy(
                            importing = false, busy = false, importedBytes = 0L,
                            failure = result.failure.toUi(),
                        ))
                    }
                }
                importJob = null
            }
        }
    }

    fun closePcap() {
        synchronized(this) {
            selectedPcap = null
            pcapSelectionRequest = null
        }
        mutableState.update {
            it.copy(pcap = it.pcap.copy(selectedID = null, selected = null))
        }
    }

    fun closeCoverage() {
        coverageSelectionRequest = null
        mutableState.update {
            it.copy(coverage = it.coverage.copy(selectedID = null, selected = null))
        }
    }

    fun selectPcap(analysisID: String) {
        if (stopping.get()) return
        var previous: PcapSummary? = null
        synchronized(this) {
            pcapSelectionRequest = analysisID
            previous = selectedPcap?.takeIf { it.analysisID == analysisID }
        }
        if (previous != null) {
            publishPcap(previous!!, PcapFilterQuery(emptySet(), emptySet(), null, null, null, null), forceSelection = true)
            return
        }
        launchOwned {
            val summary = loadSummary(analysisID)
            if (synchronized(this@NetworkArtifactHostController) { pcapSelectionRequest } != analysisID) {
                return@launchOwned
            }
            if (summary == null) {
                mutableState.update { it.copy(pcap = it.pcap.copy(failure = NetworkArtifactFailure.NOT_FOUND)) }
            } else {
                synchronized(this@NetworkArtifactHostController) { selectedPcap = summary }
                publishPcap(summary, PcapFilterQuery(emptySet(), emptySet(), null, null, null, null), forceSelection = true)
            }
        }
    }

    fun applyFilters(analysisID: String, query: PcapFilterQuery) {
        if (stopping.get()) return
        val cached = synchronized(this) {
            selectedPcap?.takeIf { it.analysisID == analysisID }
        }
        if (cached != null) {
            publishPcap(cached, query)
            return
        }
        launchOwned {
            val summary = loadSummary(analysisID)
            if (state.value.pcap.selectedID != analysisID) return@launchOwned
            if (summary == null) {
                mutableState.update { it.copy(pcap = it.pcap.copy(failure = NetworkArtifactFailure.NOT_FOUND)) }
            } else {
                synchronized(this@NetworkArtifactHostController) { selectedPcap = summary }
                publishPcap(summary, query)
            }
        }
    }

    fun deletePcap(analysisID: String) {
        if (stopping.get()) return
        mutableState.update { it.copy(pcap = it.pcap.copy(busy = true, failure = null)) }
        launchOwned {
            val deleted = runCatching { pcapStore.delete(analysisID) }.getOrDefault(false)
            synchronized(this@NetworkArtifactHostController) {
                if (deleted && selectedPcap?.analysisID == analysisID) {
                    selectedPcap = null
                    mutableState.update {
                        it.copy(pcap = it.pcap.copy(selectedID = null, selected = null))
                    }
                }
                mutableState.update {
                    it.copy(pcap = it.pcap.copy(
                        busy = false,
                        failure = if (deleted) null else NetworkArtifactFailure.NOT_FOUND,
                    ))
                }
            }
            refreshPcapLists()
        }
    }

    fun exportPcapToUri(
        uri: Uri,
        analysisID: String,
        query: PcapFilterQuery,
        format: PcapExportFormatUi,
    ) {
        if (stopping.get()) return
        if (pcapExportJob?.isActive == true) return
        exportCancelled.set(false)
        mutableState.update {
            it.copy(pcap = it.pcap.copy(busy = true, failure = null, exportedBytes = null))
        }
        pcapExportJob = launchOwned {
            var staged: File? = null
            try {
                val summary = synchronized(this@NetworkArtifactHostController) {
                    selectedPcap?.takeIf { it.analysisID == analysisID }
                } ?: loadSummary(analysisID)
                if (summary == null) {
                    mutableState.update {
                        it.copy(pcap = it.pcap.copy(
                            busy = false, failure = NetworkArtifactFailure.NOT_FOUND,
                        ))
                    }
                    return@launchOwned
                }
                val view = PcapSummaryView.of(summary, query.toCore())
                val text = when (format) {
                    PcapExportFormatUi.JSON -> PcapReportRenderer.renderViewJson(view)
                    PcapExportFormatUi.MARKDOWN -> PcapReportRenderer.renderMarkdown(view)
                    PcapExportFormatUi.CSV -> PcapReportRenderer.renderCsv(view)
                }
                val bytes = text.toByteArray(Charsets.UTF_8)
                if (exportCancelled.get()) {
                    publishExportCancelled(pcap = true)
                    return@launchOwned
                }
                staged = stageExportFile("pcap", bytes)
                if (exportCancelled.get()) {
                    publishExportCancelled(pcap = true)
                    return@launchOwned
                }
                val written = commitStagedExport(
                    uri = uri,
                    staged = staged!!,
                    displayName = "floe-capture-${analysisID.take(8)}.${format.extension}",
                    mimeType = format.mimeType,
                    checkCancel = { exportCancelled.get() },
                )
                if (written == null) {
                    publishExportFailure(pcap = true)
                } else {
                    mutableState.update {
                        it.copy(pcap = it.pcap.copy(busy = false, exportedBytes = written))
                    }
                }
            } catch (_: Exception) {
                publishExportFailure(pcap = true)
            } finally {
                runCatching { staged?.delete() }
                pcapExportJob = null
            }
        }
    }

    fun setPcapAgentReadable(analysisID: String, readable: Boolean) {
        if (stopping.get()) return
        mutableState.update { it.copy(pcap = it.pcap.copy(busy = true, failure = null)) }
        launchOwned {
            val updated = runCatching { pcapStore.setAgentReadable(analysisID, readable) }.getOrNull()
            if (updated == null) {
                mutableState.update {
                    it.copy(pcap = it.pcap.copy(busy = false, failure = NetworkArtifactFailure.NOT_FOUND))
                }
            } else {
                pcapGrants[analysisID] = updated.agentReadable
                refreshPcapLists()
                val selected = state.value.pcap.selected
                if (selected?.item?.analysisID == analysisID) {
                    publishPcap(selectedPcap ?: loadSummary(analysisID) ?: return@launchOwned,
                        selected.filters)
                }
                mutableState.update {
                    it.copy(pcap = it.pcap.copy(busy = false, failure = null))
                }
            }
        }
    }

    fun setCoverageAgentReadable(sessionID: String, readable: Boolean) {
        if (stopping.get()) return
        mutableState.update { it.copy(coverage = it.coverage.copy(busy = true, failure = null)) }
        coverageJob = launchOwned {
            when (val result = coverage.setAgentReadable(sessionID, readable)) {
                is CoverageResult.Success -> {
                    publishCoverage(result.session, forceSelection = true)
                    refreshCoverageList()
                    mutableState.update {
                        it.copy(coverage = it.coverage.copy(busy = false, failure = null))
                    }
                }
                is CoverageResult.Failure -> mutableState.update {
                    it.copy(coverage = it.coverage.copy(busy = false, failure = result.failure.toUi()))
                }
            }
            coverageJob = null
        }
    }

    private fun refreshPcapLists() {
        val entries = runCatching { pcapStore.list() }.getOrDefault(emptyList())
        synchronized(pcapGrants) {
            pcapGrants.clear()
            entries.forEach { pcapGrants[it.analysisID] = it.agentReadable }
        }
        mutableState.update { state ->
            state.copy(pcap = state.pcap.copy(analyses = entries.map {
                com.floe.android.feature.network.PcapAnalysisItemUi(
                    analysisID = it.analysisID,
                    createdAtEpochMillis = it.createdAtEpochMillis,
                    status = it.status.wire,
                    format = it.format.wire,
                    sourceLabel = it.sourceLabel,
                    detailed = it.detailed,
                    packetCount = it.packetCount,
                    flowCount = it.flowCount,
                    sourceBytes = it.sourceBytes,
                    parseMillis = it.parseMillis,
                    agentReadable = it.agentReadable,
                )
            }))
        }
    }

    private fun publishPcap(summary: PcapSummary, query: PcapFilterQuery, forceSelection: Boolean = false) {
        if (!forceSelection && state.value.pcap.selectedID != summary.analysisID) return
        val readable = synchronized(pcapGrants) { pcapGrants[summary.analysisID] == true }
        val projection = NetworkArtifactProjection.pcap(summary, query, readable)
        mutableState.update { state ->
            state.copy(pcap = state.pcap.copy(
                selectedID = summary.analysisID,
                selected = projection,
                failure = null,
            ))
        }
    }

    private fun loadSummary(analysisID: String): PcapSummary? = try {
        pcapStore.read(analysisID)?.let { PcapSummaryCodec.decode(it.json) }
    } catch (_: Exception) {
        null
    }

    // ------------------------------------------------------------------
    // Coverage
    // ------------------------------------------------------------------

    fun createCoverageSession(name: String) {
        if (stopping.get()) return
        if (coverageJob?.isActive == true) return
        mutableState.update { it.copy(coverage = it.coverage.copy(busy = true, failure = null)) }
        coverageJob = launchOwned {
            when (val result = coverage.createSession(name)) {
                is CoverageResult.Success -> {
                    publishCoverage(result.session)
                    refreshCoverageList()
                    mutableState.update {
                        it.copy(coverage = it.coverage.copy(busy = false, failure = null))
                    }
                }
                is CoverageResult.Failure -> mutableState.update {
                    it.copy(coverage = it.coverage.copy(
                        busy = false, failure = result.failure.toUi(),
                        missingPermissions = result.missingPermissions,
                    ))
                }
            }
            coverageJob = null
        }
    }

    fun selectCoverage(sessionID: String) {
        if (stopping.get()) return
        coverageSelectionRequest = sessionID
        launchOwned {
            val session = coverage.session(sessionID)
            if (coverageSelectionRequest != sessionID) return@launchOwned
            if (session == null) {
                mutableState.update {
                    it.copy(coverage = it.coverage.copy(failure = NetworkArtifactFailure.NOT_FOUND))
                }
            } else {
                publishCoverage(session, forceSelection = true)
            }
        }
    }

    fun sampleCoverage(sessionID: String, request: CoverageSampleRequest) {
        if (stopping.get()) return
        if (coverageJob?.isActive == true) return
        mutableState.update {
            it.copy(coverage = it.coverage.copy(sampling = true, failure = null,
                missingPermissions = emptyList()))
        }
        coverageJob = launchOwned {
            val result = try {
                coverage.sample(sessionID, request)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                CoverageResult.Failure(CoverageFailure.SCAN_FAILED)
            }
            synchronized(this@NetworkArtifactHostController) {
                when (result) {
                    is CoverageResult.Success -> {
                        publishCoverage(result.session)
                        refreshCoverageList()
                        mutableState.update {
                            it.copy(coverage = it.coverage.copy(
                                sampling = false,
                                failure = if (result.missingPermissions.isNotEmpty()) {
                                    NetworkArtifactFailure.PERMISSION_REQUIRED
                                } else null,
                                missingPermissions = result.missingPermissions,
                            ))
                        }
                    }
                    is CoverageResult.Failure -> mutableState.update {
                        it.copy(coverage = it.coverage.copy(
                            sampling = false,
                            failure = result.failure.toUi(),
                            missingPermissions = result.missingPermissions,
                        ))
                    }
                }
                coverageJob = null
            }
        }
    }

    fun deleteCoverageSession(sessionID: String) {
        if (stopping.get()) return
        mutableState.update { it.copy(coverage = it.coverage.copy(busy = true, failure = null)) }
        launchOwned {
            val deleted = coverage.deleteSession(sessionID)
            mutableState.update { state ->
                if (deleted && state.coverage.selectedID == sessionID) {
                    state.copy(coverage = state.coverage.copy(
                        busy = false, selectedID = null, selected = null,
                        failure = null,
                    ))
                } else {
                    state.copy(coverage = state.coverage.copy(
                        busy = false,
                        failure = if (deleted) null else NetworkArtifactFailure.NOT_FOUND,
                    ))
                }
            }
            refreshCoverageList()
        }
    }

    fun saveFloorplan(uri: Uri) {
        if (stopping.get()) return
        val sessionID = state.value.coverage.selectedID ?: return
        if (coverageJob?.isActive == true) return
        mutableState.update { it.copy(coverage = it.coverage.copy(busy = true, failure = null)) }
        coverageJob = launchOwned {
            val outcome = readFloorplan(uri)
            when (outcome) {
                is FloorplanRead.Success -> {
                    val result = coverage.saveFloorplan(
                        sessionID, outcome.bytes, outcome.mimeType, outcome.width, outcome.height,
                    )
                    when (result) {
                        is CoverageResult.Success -> {
                            publishCoverage(result.session)
                            refreshCoverageList()
                            mutableState.update {
                                it.copy(coverage = it.coverage.copy(busy = false, failure = null))
                            }
                        }
                        is CoverageResult.Failure -> mutableState.update {
                            it.copy(coverage = it.coverage.copy(busy = false, failure = result.failure.toUi()))
                        }
                    }
                }
                is FloorplanRead.Failure -> mutableState.update {
                    it.copy(coverage = it.coverage.copy(busy = false, failure = outcome.failure))
                }
            }
            coverageJob = null
        }
    }

    fun exportCoverageToUri(uri: Uri, sessionID: String, format: CoverageExportFormatUi) {
        if (stopping.get()) return
        if (coverageExportJob?.isActive == true) return
        exportCancelled.set(false)
        mutableState.update {
            it.copy(coverage = it.coverage.copy(busy = true, failure = null, exportedBytes = null))
        }
        coverageExportJob = launchOwned {
            var staged: File? = null
            try {
                val session = coverage.session(sessionID)
                if (session == null) {
                    mutableState.update {
                        it.copy(coverage = it.coverage.copy(
                            busy = false, failure = NetworkArtifactFailure.NOT_FOUND,
                        ))
                    }
                    return@launchOwned
                }
                val timestamp = System.currentTimeMillis()
                val text = when (format) {
                    CoverageExportFormatUi.JSON ->
                        CoverageReportRenderer.renderJson(session, false, timestamp)
                    CoverageExportFormatUi.MARKDOWN ->
                        CoverageReportRenderer.renderMarkdown(session, false, timestamp)
                }
                val bytes = text.toByteArray(Charsets.UTF_8)
                if (exportCancelled.get()) {
                    publishExportCancelled(pcap = false)
                    return@launchOwned
                }
                staged = stageExportFile("coverage", bytes)
                if (exportCancelled.get()) {
                    publishExportCancelled(pcap = false)
                    return@launchOwned
                }
                val written = commitStagedExport(
                    uri = uri,
                    staged = staged!!,
                    displayName = "floe-wifi-coverage-${sessionID.take(8)}.${format.extension}",
                    mimeType = format.mimeType,
                    checkCancel = { exportCancelled.get() },
                )
                if (written == null) {
                    publishExportFailure(pcap = false)
                } else {
                    mutableState.update {
                        it.copy(coverage = it.coverage.copy(busy = false, exportedBytes = written))
                    }
                }
            } catch (_: Exception) {
                publishExportFailure(pcap = false)
            } finally {
                runCatching { staged?.delete() }
                coverageExportJob = null
            }
        }
    }

    private fun publishCoverage(
        session: com.floe.android.core.networkmonitor.CoverageSession,
        forceSelection: Boolean = false,
    ) {
        if (!forceSelection && state.value.coverage.selectedID != session.sessionID) return
        val image = coverage.floorplan(session.sessionID)
        val projection = NetworkArtifactProjection.coverage(
            session, System.currentTimeMillis(), image,
        )
        mutableState.update { state ->
            state.copy(coverage = state.coverage.copy(
                selectedID = session.sessionID,
                selected = projection,
                failure = null,
            ))
        }
    }

    private fun refreshCoverageList() {
        val sessions = coverage.sessions()
        mutableState.update { state ->
            state.copy(coverage = state.coverage.copy(
                sessions = sessions.map(NetworkArtifactProjection::coverageItem),
            ))
        }
    }

    private fun reloadLists() {
        refreshPcapLists()
        refreshCoverageList()
    }

    private fun readFloorplan(uri: Uri): FloorplanRead {
        val resolver = appContext.contentResolver
        val declared = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
            }
        }.getOrNull()
        if (declared != null && declared > CoverageLimits.MAX_FLOORPLAN_BYTES) {
            return FloorplanRead.Failure(NetworkArtifactFailure.FLOORPLAN_TOO_LARGE)
        }
        val mime = (runCatching { resolver.getType(uri) }.getOrNull() ?: "")
            .lowercase(java.util.Locale.ROOT)
            .let { if (it == "image/jpg") "image/jpeg" else it }
        val bytes = (try {
            resolver.openInputStream(uri)?.use { input ->
                readBounded(input, CoverageLimits.MAX_FLOORPLAN_BYTES.toLong())
            }
        } catch (_: SecurityException) {
            null
        } catch (_: IOException) {
            null
        }) ?: return FloorplanRead.Failure(NetworkArtifactFailure.FLOORPLAN_INVALID)
        if (bytes.size > CoverageLimits.MAX_FLOORPLAN_BYTES) {
            return FloorplanRead.Failure(NetworkArtifactFailure.FLOORPLAN_TOO_LARGE)
        }
        if (mime !in setOf("image/png", "image/jpeg", "image/webp")) {
            return FloorplanRead.Failure(NetworkArtifactFailure.FLOORPLAN_INVALID)
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth !in 1..CoverageLimits.MAX_FLOORPLAN_DIMENSION ||
            bounds.outHeight !in 1..CoverageLimits.MAX_FLOORPLAN_DIMENSION) {
            return FloorplanRead.Failure(NetworkArtifactFailure.FLOORPLAN_INVALID)
        }
        return FloorplanRead.Success(bytes, mime, bounds.outWidth, bounds.outHeight)
    }

    private fun readBounded(input: InputStream, limit: Long): ByteArray? {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer, 0, buffer.size)
            if (read < 0) break
            total += read
            if (total > limit) return null
            output.write(buffer, 0, read)
        }
        return output.toByteArray().takeIf { it.isNotEmpty() }
    }

    private fun stageExportFile(prefix: String, bytes: ByteArray): File {
        val directory = File(appContext.cacheDir, "network-artifact-exports")
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("exportStagingUnavailable")
        val file = File(directory, "$prefix-${UUID.randomUUID()}.tmp")
        var created = false
        try {
            FileOutputStream(file, false).use { output ->
                created = true
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
            return file
        } catch (failure: Exception) {
            if (created) runCatching { file.delete() }
            throw failure
        }
    }

    /**
     * Commits the complete staged bytes to the SAF-created new document,
     * then reads them back and verifies size+SHA-256. The original source is
     * never opened for write; a canceled/failed commit reports honestly and
     * leaves no local staged copy behind.
     */
    private fun commitStagedExport(
        uri: Uri,
        staged: File,
        displayName: String,
        mimeType: String,
        checkCancel: () -> Boolean,
    ): Long? {
        val resolver = appContext.contentResolver
        val bytes = staged.readBytes()
        if (bytes.isEmpty() || bytes.size > PcapLimits.MAX_RESULT_BYTES) return null
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val output = runCatching { resolver.openOutputStream(uri, "wt") }.getOrNull() ?: return null
        try {
            output.use { target ->
                var offset = 0
                while (offset < bytes.size) {
                    if (checkCancel()) return null
                    val count = minOf(64 * 1024, bytes.size - offset)
                    target.write(bytes, offset, count)
                    offset += count
                }
                target.flush()
            }
        } catch (_: IOException) {
            return null
        }
        val verified = runCatching {
            resolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(64 * 1024)
                val stored = java.io.ByteArrayOutputStream()
                var total = 0L
                while (total <= bytes.size) {
                    val read = input.read(buffer, 0, buffer.size)
                    if (read < 0) break
                    total += read
                    if (total > bytes.size) return@use false
                    stored.write(buffer, 0, read)
                }
                val readBack = stored.toByteArray()
                readBack.size == bytes.size && java.security.MessageDigest.getInstance("SHA-256")
                    .digest(readBack).joinToString("") { "%02x".format(it) } == digest
            } ?: false
        }.getOrDefault(false)
        return if (verified) bytes.size.toLong() else null
    }

    private fun publishExportFailure(pcap: Boolean) {
        if (pcap) {
            mutableState.update {
                it.copy(pcap = it.pcap.copy(busy = false, failure = NetworkArtifactFailure.EXPORT_FAILED))
            }
        } else {
            mutableState.update {
                it.copy(coverage = it.coverage.copy(busy = false,
                    failure = NetworkArtifactFailure.EXPORT_FAILED))
            }
        }
    }

    private fun publishExportCancelled(pcap: Boolean) {
        if (pcap) {
            mutableState.update {
                it.copy(pcap = it.pcap.copy(busy = false, failure = NetworkArtifactFailure.CANCELLED))
            }
        } else {
            mutableState.update {
                it.copy(coverage = it.coverage.copy(busy = false,
                    failure = NetworkArtifactFailure.CANCELLED))
            }
        }
    }

    private fun cleanupOrphanedStaging() {
        // Runs on IO from enter(); never touches the live import job's file.
        val live = importJob?.isActive == true
        if (live) return
        runCatching {
            val cutoff = System.currentTimeMillis() - 60 * 60 * 1_000L
            staging.listFiles()?.forEach { file ->
                if (file.isFile && file.name.endsWith(".part") &&
                    file.lastModified() < cutoff) {
                    file.delete()
                }
            }
        }
    }

    private sealed interface FloorplanRead {
        data class Success(val bytes: ByteArray, val mimeType: String, val width: Int, val height: Int) : FloorplanRead
        data class Failure(val failure: NetworkArtifactFailure) : FloorplanRead
    }

    private fun PcapImportFailure.toUi(): NetworkArtifactFailure = when (this) {
        PcapImportFailure.SOURCE_TOO_LARGE -> NetworkArtifactFailure.SOURCE_TOO_LARGE
        PcapImportFailure.SOURCE_UNAVAILABLE -> NetworkArtifactFailure.SOURCE_UNAVAILABLE
        PcapImportFailure.UNSUPPORTED_FORMAT -> NetworkArtifactFailure.UNSUPPORTED_FORMAT
        PcapImportFailure.READ_FAILED -> NetworkArtifactFailure.READ_FAILED
        PcapImportFailure.STORE_FAILED -> NetworkArtifactFailure.STORE_FAILED
        PcapImportFailure.STORE_FULL -> NetworkArtifactFailure.CAPTURE_LIMIT
        PcapImportFailure.CANCELLED -> NetworkArtifactFailure.CANCELLED
    }

    private fun CoverageFailure.toUi(): NetworkArtifactFailure = when (this) {
        CoverageFailure.NOT_FOUND -> NetworkArtifactFailure.NOT_FOUND
        CoverageFailure.INVALID_INPUT -> NetworkArtifactFailure.INVALID_INPUT
        CoverageFailure.SESSION_LIMIT -> NetworkArtifactFailure.SESSION_LIMIT
        CoverageFailure.POINT_LIMIT -> NetworkArtifactFailure.POINT_LIMIT
        CoverageFailure.PERMISSION_REQUIRED -> NetworkArtifactFailure.PERMISSION_REQUIRED
        CoverageFailure.SCAN_FAILED -> NetworkArtifactFailure.SCAN_FAILED
        CoverageFailure.STORE_FAILED -> NetworkArtifactFailure.STORE_FAILED
        CoverageFailure.CANCELLED -> NetworkArtifactFailure.CANCELLED
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.dataexchange

/** Presentation-only state. Every byte, hash, archive and journal is owned by
 * the App host/Swift data-exchange domain; this module never opens a file. */
public enum class DataExchangePhase {
    IDLE,
    BACKING_UP,
    INSPECTING,
    REVIEWING,
    RESTORING,
    COMPLETE,
    FAILED,
}

public data class DataExchangeScopeRow(
    val id: String,
    val reason: String,
)

public data class DataExchangeCanvasUi(
    val canvasID: String,
    val name: String,
)

public data class DataExchangeCapabilitiesUi(
    val formatVersion: Int,
    val backupExtension: String,
    val notesExtension: String,
    val canvasExtension: String = "flocanvas",
    val documentExtensions: List<String> = listOf("docx", "pdf"),
    val chunkBytes: Int,
    val included: List<String>,
    val excluded: List<DataExchangeScopeRow>,
    val databaseCopied: Boolean,
)

public data class DataExchangePlanUi(
    val projects: Int,
    val projectFiles: Int,
    val noteDocuments: Int,
    val noteResources: Int,
    val notebooks: Int,
    val settingsKeys: Int,
    val providerAdvisories: Int,
    val trashedNotesExcluded: Int,
    val skippedProjects: Int,
    val conversations: Int,
    val messages: Int,
    val runs: Int,
    val toolCalls: Int,
    val workspaces: Int,
    val canvasProjects: Int,
    val mediaProjects: Int,
    val mediaAssets: Int,
    val schedules: Int,
    val actionReceipts: Int,
    val mailReceipts: Int,
    val providerConfigs: Int,
    val executionEvidence: Int = 0,
    val todos: Int = 0,
    val toolResults: Int = 0,
    val appArtifacts: Int = 0,
    val captureFiles: Int = 0,
    val configSections: Int = 0,
    val mcpDefinitions: Int = 0,
    val memoryEntries: Int = 0,
    val memoryCandidates: Int = 0,
    val personalizationDocuments: Int = 0,
    val personalizationCursors: Int = 0,
    val checklistRevisions: Int = 0,
    val skills: Int = 0,
    val modelPreferences: Int = 0,
    val runDependencies: Int = 0,
    val omissions: Int = 0,
    val partial: Boolean = false,
    val warnings: List<String>,
)

public data class DataExchangeReceiptUi(
    val projects: Int,
    val noteDocuments: Int,
    val notebooks: Int,
    val settings: Int,
    val skippedProjects: Int,
    val conversations: Int = 0,
    val messages: Int = 0,
    val runs: Int = 0,
    val toolCalls: Int = 0,
    val workspaces: Int = 0,
    val schedules: Int = 0,
    val providers: Int = 0,
    val canvasProjects: Int = 0,
    val mediaProjects: Int = 0,
    val evidenceRows: Int = 0,
    val todos: Int = 0,
    val toolResults: Int = 0,
    val appArtifacts: Int = 0,
    val captureFiles: Int = 0,
    val cadPreserved: Int = 0,
    val configSections: Int = 0,
    val mcpDefinitions: Int = 0,
    val memoryEntries: Int = 0,
    val memoryCandidates: Int = 0,
    val personalizationDocuments: Int = 0,
    val personalizationCursors: Int = 0,
    val checklistRevisions: Int = 0,
    val skills: Int = 0,
    val modelPreferences: Int = 0,
    val partial: Boolean = false,
) {
    val isEmpty: Boolean
        get() = projects == 0 && noteDocuments == 0 && notebooks == 0 &&
            settings == 0 && conversations == 0 && messages == 0 &&
            canvasProjects == 0 && mediaProjects == 0 && todos == 0 &&
            toolResults == 0 && appArtifacts == 0 && captureFiles == 0 &&
            configSections == 0 && mcpDefinitions == 0 && memoryEntries == 0 &&
            memoryCandidates == 0 && personalizationDocuments == 0 &&
            checklistRevisions == 0 && skills == 0
}

public data class DataExchangeUiState(
    val loading: Boolean = true,
    val coreReady: Boolean = false,
    val phase: DataExchangePhase = DataExchangePhase.IDLE,
    val progressDone: Long = 0L,
    val progressTotal: Long = 0L,
    val capabilities: DataExchangeCapabilitiesUi? = null,
    val pendingRecoveries: Int = 0,
    val plan: DataExchangePlanUi? = null,
    val importMode: Boolean = false,
    val documentKind: String = "backup",
    val canvases: List<DataExchangeCanvasUi> = emptyList(),
    val backupBytes: Long? = null,
    val backupSha256: String? = null,
    val backupWarnings: List<String> = emptyList(),
    val receipt: DataExchangeReceiptUi? = null,
    val resultWarnings: List<String> = emptyList(),
    val errorCode: String? = null,
    val noticeCode: String? = null,
) {
    val busy: Boolean
        get() = phase == DataExchangePhase.BACKING_UP ||
            phase == DataExchangePhase.INSPECTING ||
            phase == DataExchangePhase.RESTORING
}

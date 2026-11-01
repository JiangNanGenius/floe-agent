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

public data class DataExchangeCapabilitiesUi(
    val formatVersion: Int,
    val backupExtension: String,
    val notesExtension: String,
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
    val warnings: List<String>,
)

public data class DataExchangeReceiptUi(
    val projects: Int,
    val noteDocuments: Int,
    val notebooks: Int,
    val settings: Int,
    val skippedProjects: Int,
) {
    val isEmpty: Boolean
        get() = projects == 0 && noteDocuments == 0 && notebooks == 0 && settings == 0
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

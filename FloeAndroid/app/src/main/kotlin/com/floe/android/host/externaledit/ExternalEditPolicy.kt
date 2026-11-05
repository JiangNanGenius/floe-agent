// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.util.UUID

/** Durable transport identity, never an independent file/environment authority. */
internal data class ExternalEditOwner(val taskID: String, val workspaceID: String) {
    init {
        require(validUUID(taskID) && validUUID(workspaceID))
    }
    companion object {
        fun validUUID(value: String): Boolean = runCatching {
            UUID.fromString(value).toString().equals(value, ignoreCase = true)
        }.getOrDefault(false)
    }
}

internal enum class ExternalEditPhase {
    EDITING, COMMITTING, SAVED, CONFLICT, SOURCE_PENDING, PAUSED, FINISHED,
}

internal data class ExternalEditRecord(
    val id: String,
    val owner: ExternalEditOwner,
    val logicalPath: String,
    val displayName: String,
    val baselineSHA256: String,
    val baselineBytes: Long,
    val sourceID: String? = null,
    val sourceRevision: String? = null,
    val phase: ExternalEditPhase = ExternalEditPhase.EDITING,
    val pendingSHA256: String? = null,
    val pendingBytes: Long? = null,
    val conflictSHA256: String? = null,
    val editedSHA256: String? = null,
    val errorCode: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
    val initialSHA256: String = baselineSHA256,
) {
    init {
        require(ExternalEditOwner.validUUID(id))
        require(ExternalEditPolicy.validPath(logicalPath))
        require(displayName.isNotBlank() && displayName.length <= 160 &&
            displayName.none { it == '/' || it == '\\' || it.code < 32 })
        require(ExternalEditPolicy.validSHA(baselineSHA256))
        require(ExternalEditPolicy.validSHA(initialSHA256))
        require(baselineBytes in 0..ExternalEditPolicy.MAX_BYTES)
        require(pendingSHA256 == null || ExternalEditPolicy.validSHA(pendingSHA256))
        require(pendingBytes == null || pendingBytes in 0..ExternalEditPolicy.MAX_BYTES)
        require((pendingSHA256 == null) == (pendingBytes == null))
        require(conflictSHA256 == null || ExternalEditPolicy.validSHA(conflictSHA256))
        require(editedSHA256 == null || ExternalEditPolicy.validSHA(editedSHA256))
    }
}

internal object ExternalEditPolicy {
    // Matches the existing native streamed replacement budget.
    const val MAX_BYTES = 256L * 1024 * 1024
    const val MAX_ACTIVE = 16
    enum class Decision { UNCHANGED, ALREADY_COMMITTED, REPLACE, CONFLICT }

    fun validPath(path: String): Boolean = path.isNotEmpty() && path.length <= 4096 &&
        path.none { it == '\\' || it.code < 32 } &&
        path.split('/').none { it.isEmpty() || it == "." || it == ".." }

    fun validSHA(value: String): Boolean = value.length == 64 &&
        value.all { it in '0'..'9' || it in 'a'..'f' }

    /** A successful Activity return is deliberately not an input. */
    fun decide(baseline: String, current: String, edited: String): Decision {
        require(listOf(baseline, current, edited).all(::validSHA))
        return when {
            edited == baseline -> Decision.UNCHANGED
            current == edited -> Decision.ALREADY_COMMITTED
            current == baseline -> Decision.REPLACE
            else -> Decision.CONFLICT
        }
    }
}

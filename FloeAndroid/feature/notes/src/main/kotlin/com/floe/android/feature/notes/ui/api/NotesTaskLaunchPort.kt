// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.api

/**
 * Explicit user selection of Notes document resources for an ordinary task.
 *
 * The presentation layer never reads or copies bytes itself and never names a
 * filesystem path. The App host re-reads the exact document revision and
 * resource metadata through the existing Notes authority, creates the REAL
 * ordinary conversation through the original launch ingress, grants read
 * access for exactly this document, and asks the Core launch receipt to stage
 * the selected resources into that task's workspace.
 *
 * The message shown here is the user's prompt. The host appends the real
 * attachment manifest before the ordinary `run.start`; the model never sees a
 * guessed path and the Notes original is never modified.
 */
public enum class NotesTaskLaunchResourceKind { PDF, IMAGE, DOCUMENT, OTHER }

public data class NotesTaskLaunchResource(
    public val resourceID: String,
    public val fileName: String,
    public val mediaType: String,
    public val byteCount: Long,
    /** Exact content-addressed Notes digest (lowercase SHA-256). */
    public val sha256: String,
    public val kind: NotesTaskLaunchResourceKind = NotesTaskLaunchResourceKind.OTHER,
) {
    init {
        require(resourceID.isNotBlank()) { "resource identity" }
        require(fileName.isNotBlank() && fileName != "." && fileName != "..") { "resource name" }
        require(fileName.encodeToByteArray().size <= 512) { "resource name bound" }
        require(mediaType.isNotBlank() && mediaType.encodeToByteArray().size <= 256) { "media type" }
        require(byteCount > 0L) { "resource size" }
        require(sha256.length == 64 && sha256.all { it in "0123456789abcdefABCDEF" }) {
            "content-addressed digest"
        }
    }
}

public data class NotesTaskLaunchRequest(
    public val documentID: String,
    public val documentRevision: Int,
    public val documentTitle: String,
    public val resources: List<NotesTaskLaunchResource>,
    public val prompt: String,
) {
    init {
        require(documentID.isNotBlank()) { "document identity" }
        require(documentRevision >= 0) { "document revision" }
        require(resources.isNotEmpty()) { "at least one resource" }
        require(resources.size <= NotesTaskLaunchPolicy.MAX_RESOURCES) { "resource count" }
        require(prompt.encodeToByteArray().size <= NotesTaskLaunchPolicy.MAX_PROMPT_BYTES) {
            "prompt bound"
        }
    }
}

public sealed interface NotesTaskLaunchOutcome {
    /**
     * A REAL ordinary conversation was created and the first-send composer
     * carries the exact Notes attachment manifest. [receiptID] is the Core
     * receipt identity printed in the manifest.
     */
    public data class Created(
        public val conversationID: String,
        public val receiptID: String,
    ) : NotesTaskLaunchOutcome

    /** A typed failure; a committed empty task may remain in history. */
    public data class Failed(
        public val failure: NotesPortFailure,
        public val retryable: Boolean = true,
    ) : NotesTaskLaunchOutcome
}

/**
 * Optional App-owned port. A null port keeps the Notes UI honest: the action
 * is hidden rather than shown as a placeholder that cannot work.
 */
public interface NotesTaskLaunchPort {
    /** True only when the live Notes/runtime generation can admit this action. */
    public fun isAvailable(): Boolean

    public suspend fun createTask(request: NotesTaskLaunchRequest): NotesTaskLaunchOutcome

    /** Explicit UI navigation after the originating Notes view is still current. */
    public fun openCreatedTask(conversationID: String): Boolean
}

/** Pure, shared bounds used by the sheet and both adapters (no Android API). */
public object NotesTaskLaunchPolicy {
    public const val MAX_RESOURCES: Int = 16
    public const val MAX_PROMPT_BYTES: Int = 32 * 1024
    public const val MAX_TOTAL_BYTES: Long = 512L * 1024L * 1024L
    public const val MAX_PROMPT_CHARS: Int = 8_000

    public fun totalBytes(resources: List<NotesTaskLaunchResource>): Long =
        resources.sumOf { it.byteCount }

    public fun validate(resources: List<NotesTaskLaunchResource>): NotesPortFailure? {
        if (resources.isEmpty()) return NotesPortFailure(NotesPortFailure.NOT_FOUND, "noResources")
        if (resources.size > MAX_RESOURCES) {
            return NotesPortFailure(NotesPortFailure.UNSUPPORTED, "tooManyResources")
        }
        if (resources.map { it.resourceID }.distinct().size != resources.size) {
            return NotesPortFailure(NotesPortFailure.UNSUPPORTED, "duplicateResource")
        }
        if (resources.any { it.byteCount > MAX_TOTAL_BYTES } || totalBytes(resources) > MAX_TOTAL_BYTES) {
            return NotesPortFailure(NotesPortFailure.UNSUPPORTED, "resourceBudget")
        }
        return null
    }
}

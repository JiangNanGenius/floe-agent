// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

/**
 * Core identity and capability models for the SAF gateway.
 *
 * Hard invariants (Main architecture 2026-10-23, official docs verified):
 *  - `content://` URI strings are kept as OPAQUE EXACT identity. Nothing here
 *    ever parses a provider URI into a POSIX path (plan §1189: SAF content is
 *    not POSIX). Provider/URI strings are untrusted data, never authorization.
 *  - OS `persistedUriPermissions` is the only grant truth. The caches in
 *    [SafGrantGateway] are rebuildable display hints and cannot confer access.
 *  - DocumentsContract exposes no atomic compare-and-swap. Writability comes
 *    from the exact `Document.COLUMN_FLAGS` bits, and `canWrite()`-style
 *    assumptions are not made anywhere.
 */

/** Classification of a URI string, performed platform-side (DocumentsContract). */
enum class SafUriKind { DOCUMENT, TREE, NON_SAF, UNKNOWN }

/** An opaque exact system URI. Never a path. */
data class SafUriRef(val uriString: String) {
    init {
        require(uriString.startsWith("content://")) {
            "SAF gateway accepts only content:// system URIs (never file paths)"
        }
    }
}

/**
 * Operation target: the exact granted tree (when the access came from a tree
 * picker), the provider document id, and the exact URI string the system or
 * the provider returned. All three are preserved without rewriting.
 */
data class SafDocumentRef(
    val tree: SafUriRef?,
    val documentId: String?,
    val parentDocumentId: String?,
    val uri: SafUriRef,
)

/** A document's size: providers legally report -1 / absent. Unknown stays Unknown. */
sealed class SafSize {
    data class Known(val bytes: Long) : SafSize() {
        init { require(bytes >= 0) { "a known size cannot be negative" } }
    }

    /** Not zero: the provider simply does not know or will not say. */
    data object Unknown : SafSize()

    companion object {
        /** Maps the raw COLUMN_SIZE long (null / negative = unknown, never coerced to 0). */
        fun fromProviderColumn(raw: Long?): SafSize =
            if (raw == null || raw < 0) Unknown else Known(raw)
    }
}

/**
 * Exact capability set derived from `Document.COLUMN_FLAGS`. Bit values are the
 * documented AOSP values; [AndroidSafBackend.selfCheck] verifies parity against
 * the compile-time `DocumentsContract` constants during qualification.
 */
object SafProviderFlagBits {
    const val SUPPORTS_THUMBNAIL = 1 shl 0
    const val SUPPORTS_WRITE = 1 shl 1
    const val SUPPORTS_DELETE = 1 shl 2
    const val DIR_SUPPORTS_CREATE = 1 shl 3
    const val DIR_PREFERS_GRID = 1 shl 4
    const val DIR_PREFERS_LAST_MODIFIED = 1 shl 5
    const val SUPPORTS_RENAME = 1 shl 6
    const val SUPPORTS_COPY = 1 shl 7
    const val SUPPORTS_MOVE = 1 shl 8
    const val VIRTUAL_DOCUMENT = 1 shl 9
    const val SUPPORTS_REMOVE = 1 shl 10
    const val SUPPORTS_SETTINGS = 1 shl 11
    const val WEB_LINKABLE = 1 shl 12
    const val PARTIAL = 1 shl 13
    const val DIR_BLOCKS_OPEN_DOCUMENT_TREE = 1 shl 15
}

/** Intent grant flag bits carried by explicit system picker results. */
object SafGrantFlagBits {
    const val GRANT_READ = 0x00000001 // Intent.FLAG_GRANT_READ_URI_PERMISSION
    const val GRANT_WRITE = 0x00000002 // Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    const val PERSISTABLE = 0x00000040 // Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
    const val PREFIX = 0x00000080 // Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
}

data class SafCapabilities(
    val write: Boolean,
    val delete: Boolean,
    val rename: Boolean,
    val copy: Boolean,
    val move: Boolean,
    val createChildren: Boolean,
    val removeFromParent: Boolean,
    val blocksOpenDocumentTree: Boolean,
    val virtual: Boolean,
    val rawFlags: Int,
) {
    companion object {
        fun fromProviderFlags(flags: Int): SafCapabilities = SafCapabilities(
            write = flags and SafProviderFlagBits.SUPPORTS_WRITE != 0,
            delete = flags and SafProviderFlagBits.SUPPORTS_DELETE != 0,
            rename = flags and SafProviderFlagBits.SUPPORTS_RENAME != 0,
            copy = flags and SafProviderFlagBits.SUPPORTS_COPY != 0,
            move = flags and SafProviderFlagBits.SUPPORTS_MOVE != 0,
            createChildren = flags and SafProviderFlagBits.DIR_SUPPORTS_CREATE != 0,
            removeFromParent = flags and SafProviderFlagBits.SUPPORTS_REMOVE != 0,
            blocksOpenDocumentTree = flags and SafProviderFlagBits.DIR_BLOCKS_OPEN_DOCUMENT_TREE != 0,
            virtual = flags and SafProviderFlagBits.VIRTUAL_DOCUMENT != 0,
            rawFlags = flags,
        )

        val NONE = fromProviderFlags(0)
    }
}

/** One provider document, mapped from exact cursor columns (bounded queries only). */
data class SafDocument(
    val ref: SafDocumentRef,
    val displayName: String,
    val mimeType: String,
    val size: SafSize,
    /** Milliseconds epoch. HINT ONLY: providers may lie or omit; never used as a revision. */
    val lastModifiedMillis: Long?,
    val capabilities: SafCapabilities,
) {
    val isVirtual: Boolean get() = capabilities.virtual

    companion object {
        const val MIME_DIR = "vnd.android.document/directory"
    }
}

/** The two URI permission axes the platform can actually grant. */
enum class SafAccessFlag { READ, WRITE }

/** One row of the OS truth (`ContentResolver.persistedUriPermissions`). */
data class GrantSnapshot(val uri: SafUriRef, val read: Boolean, val write: Boolean)

/**
 * Live permission probe at the platform edge. `persistedUriPermissions` only
 * proves PERSISTED grants and must NEVER be used to deny the current session
 * grant carried by an explicit system result — the Android implementation
 * additionally calls `ContentResolver.checkUriPermission` (own pid/uid).
 * UNKNOWN means the platform could not answer declaratively; the actual
 * descriptor open at operation time is the final word. No cache or model flag
 * grants access by itself.
 */
enum class ProbeFlag { GRANTED, DENIED, UNKNOWN }

data class AccessProbe(val read: ProbeFlag, val write: ProbeFlag)

/** Verified import result: staged bytes + the fingerprint built from ACTUAL bytes. */
data class ImportReceipt(val staged: StagedCopy, val fingerprint: SourceFingerprint)

/** Outcome of one `takePersistableUriPermission` attempt for exactly one flag. */
sealed class TakeOutcome {
    /** Persisted by THIS call (we therefore own the release decision). */
    data object Persisted : TakeOutcome()

    /** Already persisted by someone in this app (e.g. attachments/skills) — not ours. */
    data object AlreadyHeld : TakeOutcome()

    /** Could not persist; the access remains only the transient session grant. */
    data class TransientOnly(val reason: String) : TakeOutcome()

    /** Platform refused the persist call outright. */
    data class Refused(val reason: String) : TakeOutcome()
}

/**
 * One bounded child scan. Continuation rides an OPAQUE cursor token owned by
 * the backend (a held provider cursor with bounded lifetime), NOT a
 * displayName guess: providers may ignore SORT/LIMIT and names may repeat, so
 * a name cursor would drop or duplicate same-name rows. `nextCursorToken ==
 * null` means the scan exhausted; a non-null token means the caller stopped at
 * the limit with more rows behind the held cursor. `note` truthfully reports
 * cursor expiry/restart — the gateway never silently re-reads a page.
 */
data class ChildScan(
    val documents: List<SafDocument>,
    val nextCursorToken: String?,
    val truncatedByLimit: Boolean,
    val note: String?,
)

data class PageRequest(val limit: Int, val cursorToken: String? = null)

/** Bytes transferred by one bounded stream pass. `sha256` only after full completion. */
data class StreamSummary(
    val bytes: Long,
    val sha256: String,
    val completed: Boolean,
    val lengthHintBytes: Long?,
)

// ---------------------------------------------------------------------------
// Caller-owned local staging descriptors (POSIX app storage, like attachment
// staging). These describe LOCAL working-copy files only, never provider paths.
// ---------------------------------------------------------------------------

data class StagedLocalRef(val file: java.io.File, val name: String) {
    init { require(name.isNotBlank() && !name.contains('/') && !name.contains('\\')) }
}

/** Verified bytes imported from a provider document into caller-owned staging. */
data class StagedCopy(
    val local: StagedLocalRef,
    val sourceUri: SafUriRef,
    val sourceDocumentId: String?,
    val bytes: Long,
    val sha256: String,
    /** COLUMN_SIZE at import time, hint only (may be null = unknown). */
    val sizeHintBytes: Long?,
    /** COLUMN_LAST_MODIFIED at import time, hint only. */
    val lastModifiedHintMillis: Long?,
    val displayName: String,
)

/**
 * Working-copy source fingerprint. SHA-256 exists ONLY when actual bytes were
 * obtained through a bounded stream; a metadata-only fingerprint carries null
 * and can never authorize an overwrite comparison.
 */
data class SourceFingerprint(
    val sha256: String?,
    val bytes: Long?,
    val sizeHintBytes: Long?,
    val lastModifiedHintMillis: Long?,
    val observedAtMillis: Long,
)

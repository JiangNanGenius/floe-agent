// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

/** Machine-readable classification of every installer failure. */
enum class InstallFailure {
    /** Catalog entry itself is inconsistent (scheme, hash form, budgets). */
    INVALID_CATALOG,

    /** Transport error: non-200, redirect out of HTTPS, I/O failure. */
    TRANSPORT_FAILED,

    /** Remote body exceeded the catalog archive budget, or was size-short. */
    ARCHIVE_TOO_LARGE,

    /** Free-space floor (reserve) violated before or during streaming. */
    DISK_BUDGET,

    /** SHA-256 of the received archive does not equal the catalog pin. */
    DIGEST_MISMATCH,

    /** Stream ended inside a tar header, payload or before the end blocks. */
    ARCHIVE_TRUNCATED,

    /** tar header checksum, field form or structural expectation violated. */
    ARCHIVE_HEADER_CORRUPT,

    /** XZ container corrupt or over the decoder memory limit. */
    DECODE_FAILED,

    /** Entry path escapes the destination or the expected top prefix. */
    UNSAFE_PATH,

    /** A path component inside the destination is a stored symlink. */
    WRITE_THROUGH_SYMLINK,

    /** Two archive members claim the same destination slot incompatibly. */
    DESTINATION_COLLISION,

    /** Hardlink member without a safe, already-materialized regular file. */
    HARDLINK_TARGET_UNSAFE,

    /** Character/block/FIFO member under a REJECT device policy. */
    DEVICE_ENTRY_DISALLOWED,

    /** tar member type this profile does not materialize. */
    ENTRY_TYPE_UNSUPPORTED,

    /** Materializable-entry budget exceeded. */
    ENTRY_BUDGET,

    /** Extended-header record count or per-record byte budget exceeded. */
    METADATA_BUDGET,

    /** Single-member or total extracted byte budget exceeded. */
    SIZE_BUDGET,

    /** Materialized content fell below the catalog minimum counts. */
    CONTENT_UNDERFLOW,

    /** Publication target already exists — never overwrite a live rootfs. */
    DESTINATION_EXISTS,

    /** Publication target parent missing or not a directory. */
    DESTINATION_PARENT_MISSING,

    /** Catalog requires a case-sensitive volume; the destination is not one. */
    CASE_INSENSITIVE_DESTINATION,

    /** Publication rename failed across file stores (EXDEV). */
    CROSS_FILESTORE,

    /** Directory lacks a valid installer ownership marker; never deleted. */
    OWNER_MARKER_MISSING,

    /** Staging/published revision failed ownership/integrity inspection. */
    STAGING_INCOMPLETE,

    /** Unexpected platform I/O failure; cause retained, run treated as failed. */
    UNEXPECTED_IO,
}

open class RootfsInstallException(
    val failure: InstallFailure,
    val detail: String,
    cause: Throwable? = null,
) : Exception("${failure.name}: $detail", cause)

/** Cooperative cancellation; distinct from failure so callers need not retry. */
class RootfsCancelledException(val detail: String) : Exception("CANCELLED: $detail")

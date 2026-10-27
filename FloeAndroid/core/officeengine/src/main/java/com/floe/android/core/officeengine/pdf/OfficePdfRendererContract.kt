// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

/**
 * Wire contract for the isolated PDF renderer (main spec 2026-10-27: platform
 * docs recommend parsing untrusted PDFs "in a separate, isolated process with
 * the minimum permissions necessary"). The renderer service lives in its OWN
 * `isolatedProcess` — it receives NOTHING but a read-only file descriptor
 * copied through the binder transaction, a page index and a bounded zoom
 * percent, and returns NOTHING but a status, dimensions, and one bounded
 * SharedMemory pixel buffer. No paths, no network, no storage authority, no
 * arbitrary binder surface: unknown transaction codes and foreign callers
 * reject fail-closed, mirroring the proven OfficeHostSaveChannel pattern.
 *
 * Pure JVM constants + validation (the shape rules here are unit-testable
 * without any Android type).
 */
object OfficePdfRendererContract {

    const val DESCRIPTOR = "com.floe.android.core.officeengine.pdf.PdfRenderer"

    /** fd → pageCount. */
    const val T_DOCUMENT_INFO = 2

    /** fd + pageIndex + zoomPercent + requestId → status/dims + SharedMemory(ARGB_8888). */
    const val T_RENDER_PAGE = 3

    /**
     * Host → renderer: "I copied (or dropped) the pixels of shmId; the
     * renderer may close its handle." Always the transaction AFTER the
     * render reply has fully returned, which is exactly when the binder
     * driver has already duped the transferred fd — closing any earlier
     * could hand the host a dead descriptor.
     */
    const val T_RELEASE_SHM = 4

    // Terminal transport statuses (numeric, stable on the wire).
    const val S_OK = 0

    /** Shape outside the bounded rules; nothing was opened or allocated. */
    const val S_BAD_REQUEST = 1

    /** PdfRenderer said the document cannot be parsed (IOException). */
    const val S_INVALID_PDF = 2

    /**
     * PdfRenderer refused: password-protected or unsupported security scheme
     * (SecurityException). Honest refusal — no auth work in this slice.
     */
    const val S_PASSWORD = 3

    /** Renderer backlog bound hit; the host may retry after the current work drains. */
    const val S_BUSY = 4

    /** Transport/internal fault or a bounded join timeout. */
    const val S_INTERNAL = 5

    /** Sanity fence on claimed page indices (engines realistically export far fewer; oversized claims are refused before ANY open). */
    const val MAX_PAGE_INDEX = 20_000

    /** In-flight + queued jobs the isolated renderer accepts before replying BUSY. */
    const val MAX_INFLIGHT = 2

    /** Join bounds per transaction kind. */
    const val INFO_TIMEOUT_MS = 30_000L
    const val RENDER_TIMEOUT_MS = 45_000L

    const val MIN_REQUEST_ID = 1L

    /** Monotonic per-host request ids; 0 is never a valid id (catches default-zero parcels). */
    fun validRequestId(id: Long): Boolean = id >= MIN_REQUEST_ID

    fun validPageIndex(index: Int): Boolean = index in 0 until MAX_PAGE_INDEX

    fun validZoom(zoomPercent: Int): Boolean =
        zoomPercent in OfficePdfGeometry.MIN_ZOOM_PERCENT..OfficePdfGeometry.MAX_ZOOM_PERCENT

    fun validStatus(status: Int): Boolean = status in S_OK..S_INTERNAL
}

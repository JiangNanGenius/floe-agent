// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.graphics.Bitmap
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.SharedMemory

/**
 * Host-side calls against the isolated PDF renderer binder. Every function is
 * synchronous, fail-closed and never throws: any transport problem or an
 * invalid reply is `null` (or the named failure), and the caller surfaces an
 * honest UI error. Replies are fully re-validated before ANY pixel buffer is
 * mapped or any Bitmap is allocated ([OfficePdfGeometry.validateReply]).
 */
sealed class PdfRenderReply {
    /** documentInfo success. */
    data class Info(val requestId: Long, val pageCount: Int) : PdfRenderReply()

    /** renderPage success: pixels are already validated + copied into a Bitmap on the CALLING (worker) thread. */
    data class Page(val requestId: Long, val bitmap: Bitmap, val widthPx: Int, val heightPx: Int) : PdfRenderReply()

    /** Honest refusal statuses (never a path or engine detail). */
    data class Refusal(val requestId: Long, val status: Int) : PdfRenderReply()
}

// Transport failure / invalid reply is represented by the channel calls
// returning NULL — hosts map null to their own honest failure identity.

object OfficePdfRendererChannel {

    /**
     * Requests the real page count of the document behind [fd]. The FD is
     * ONLY read — the renderer never takes a writable descriptor, and the
     * service owns a kernel-dup of it for the duration of the parse.
     */
    @JvmStatic
    fun documentInfo(renderer: IBinder?, requestId: Long, fd: ParcelFileDescriptor): PdfRenderReply? {
        val reply = transact(renderer, OfficePdfRendererContract.T_DOCUMENT_INFO, requestId) { data ->
            data.writeLong(requestId)
            data.writeFileDescriptor(fd.fileDescriptor)
        } ?: return null
        return try {
            val id = reply.readLong()
            val status = reply.readInt()
            if (id != requestId || !OfficePdfRendererContract.validStatus(status)) return null
            when (status) {
                OfficePdfRendererContract.S_OK -> {
                    val pageCount = reply.readInt()
                    if (pageCount < 1 || pageCount > OfficePdfRendererContract.MAX_PAGE_INDEX) null
                    else PdfRenderReply.Info(id, pageCount)
                }
                else -> PdfRenderReply.Refusal(id, status)
            }
        } catch (_: Exception) {
            null
        } finally {
            reply.recycle()
        }
    }

    /**
     * Renders one page into a bounded ARGB_8888 Bitmap transferred over one
     * SharedMemory parcel (min28-safe: `SharedMemory` is Parcelable with a
     * public CREATOR and map/unmap APIs). All allocation happens on the
     * caller's worker thread after [OfficePdfGeometry.validateReply].
     */
    @JvmStatic
    fun renderPage(
        renderer: IBinder?,
        requestId: Long,
        fd: ParcelFileDescriptor,
        pageIndex: Int,
        zoomPercent: Int,
    ): PdfRenderReply? {
        val reply = transact(renderer, OfficePdfRendererContract.T_RENDER_PAGE, requestId) { data ->
            data.writeLong(requestId)
            data.writeFileDescriptor(fd.fileDescriptor)
            data.writeInt(pageIndex)
            data.writeInt(zoomPercent)
        } ?: return null
        var shmId = 0L
        return try {
            val id = reply.readLong()
            val status = reply.readInt()
            if (id != requestId || !OfficePdfRendererContract.validStatus(status)) return null
            if (status != OfficePdfRendererContract.S_OK) return PdfRenderReply.Refusal(id, status)
            val width = reply.readInt()
            val height = reply.readInt()
            val byteCount = reply.readLong()
            shmId = reply.readLong()
            if (!OfficePdfGeometry.validateReply(width, height, byteCount)) return null
            val shared = reply.readTypedObject(SharedMemory.CREATOR) ?: return null
            var mapped: java.nio.ByteBuffer? = null
            try {
                mapped = shared.mapReadOnly()
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(mapped)
                PdfRenderReply.Page(id, bitmap, width, height)
            } catch (_: Exception) {
                null
            } finally {
                runCatching { mapped?.let { SharedMemory.unmap(it) } }
                runCatching { shared.close() }
            }
        } catch (_: Exception) {
            null
        } finally {
            reply.recycle()
            // Hand the renderer process back its buffer exactly now: THIS
            // transact returning proves the driver already duped the fd into
            // our parcel, so the isolated side may close its handle safely.
            if (shmId > 0L) {
                transactVoid(renderer, OfficePdfRendererContract.T_RELEASE_SHM, requestId, shmId)
            }
        }
    }

    private fun transactVoid(renderer: IBinder?, code: Int, requestId: Long, shmId: Long) {
        if (renderer == null || !renderer.pingBinder()) return
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(OfficePdfRendererContract.DESCRIPTOR)
            data.writeLong(requestId)
            data.writeLong(shmId)
            renderer.transact(code, data, reply, 0)
        } catch (_: Exception) {
            // Fire-and-acknowledge: worst case the bounded renderer registry
            // force-retires the oldest handle on the next render.
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    private inline fun transact(
        renderer: IBinder?,
        code: Int,
        requestId: Long,
        writeArgs: (Parcel) -> Unit,
    ): Parcel? {
        if (renderer == null || !renderer.pingBinder()) return null
        if (!OfficePdfRendererContract.validRequestId(requestId)) return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(OfficePdfRendererContract.DESCRIPTOR)
            writeArgs(data)
            if (!renderer.transact(code, data, reply, 0)) {
                reply.recycle()
                return null
            }
            return reply
        } catch (_: Exception) {
            reply.recycle()
            return null
        } finally {
            data.recycle()
        }
    }
}

/**
 * Server-side transact core, shared by the isolated service's Binder. The
 * caller ([OfficePdfRendererService]) supplies the actual bounded render
 * function; this object owns only the trust/shape fence:
 *  - interface token + the ACTUAL owner-app UID equality
 *    ([callerIsOwner]) on every transaction — the service compares
 *    `Binder.getCallingUid()` against the app package UID of its own
 *    trusted Service context (`ApplicationInfo.uid`), never against a raw
 *    UID-range heuristic and never against anything the parcel carries;
 *  - complete argument shape validation BEFORE anything is opened;
 *  - a fixed reply field order; a malformed host is answered with
 *    S_INTERNAL, never with partial claims.
 */
object OfficePdfRendererBinder {

    sealed class ParsedRequest {
        data class Info(val requestId: Long, val fd: ParcelFileDescriptor) : ParsedRequest()
        data class Render(
            val requestId: Long,
            val fd: ParcelFileDescriptor,
            val pageIndex: Int,
            val zoomPercent: Int,
        ) : ParsedRequest()

        /** No FD: pure acknowledgement of a previously transferred buffer id. */
        data class Release(val requestId: Long, val shmId: Long) : ParsedRequest()
    }

    /**
     * Owner-UID fence (Main repair 2026-10-27, replacing the delivered
     * `callingUid !in 99000..199999` heuristic).
     *
     * The old range rule was NOT owner proof and was wrong for Android
     * multiuser: user-0 foreign app UIDs (10000..89999) all PASSED it, while
     * the owning app running under user 1 (UIDs like 111045) merely falls
     * inside the numeric AID_ISOLATED band and would have been REFUSED, and
     * isolated UIDs of higher users can fall outside the band. Raw range
     * checks conflate "isolated" with "some other user's normal app".
     *
     * The real rule: the caller must be EXACTLY the owning application's UID
     * for the user this service instance runs under — taken from the trusted
     * Service context `ApplicationInfo.uid` (the app package UID), NOT from
     * this isolated process's own `Process.myUid()`, NOT from a
     * caller-supplied UID/path/token, and NOT from any range heuristic.
     * Consequences (all unit-tested in the module's JVM test source set,
     * pure Kotlin — no Android identity service, no new permission):
     *  - owner UID equality: allowed (the app's own non-isolated process —
     *    the only process the non-exported service can ever hand the binder
     *    to, per the manifest `exported="false"` + `isolatedProcess="true"`
     *    that stay intact);
     *  - foreign normal-app UID under ANY user: refused (never the exact
     *    owner value; the numeric band no longer matters);
     *  - secondary-user instantiation: exact-match allowed (user 1's own
     *    app UID equals the owner value read from THIS user's context);
     *  - isolated-process UID (including this service's own): refused — an
     *    isolated UID never equals a package owner UID, and a second
     *    isolated process must never drive the parser;
     *  - non-positive calling/owner UID: invalid, refused fail-closed.
     */
    fun callerIsOwner(callingUid: Int, ownerAppUid: Int): Boolean =
        isPlausibleOwnerAppUid(ownerAppUid) && callingUid == ownerAppUid

    /** Owner anchor sanity: only a positive UID can identify an app package; the unreadable-owner sentinel (-1) is invalid. */
    fun isPlausibleOwnerAppUid(ownerAppUid: Int): Boolean = ownerAppUid > 0

    /**
     * Parses one transaction. On ANY shape failure the received FD (if the
     * parcel carried one) is closed here and null is returned, so a rejected
     * request leaks nothing into the isolated process.
     */
    @JvmStatic
    fun parse(data: Parcel, code: Int): ParsedRequest? {
        data.enforceInterface(OfficePdfRendererContract.DESCRIPTOR)
        return when (code) {
            OfficePdfRendererContract.T_DOCUMENT_INFO -> {
                val id = data.readLong()
                val fd = data.readFileDescriptor()
                if (!OfficePdfRendererContract.validRequestId(id) || fd == null) {
                    runCatching { fd?.close() }
                    return null
                }
                ParsedRequest.Info(id, fd)
            }

            OfficePdfRendererContract.T_RENDER_PAGE -> {
                val id = data.readLong()
                val fd = data.readFileDescriptor()
                val index = data.readInt()
                val zoom = data.readInt()
                if (!OfficePdfRendererContract.validRequestId(id) || fd == null ||
                    !OfficePdfRendererContract.validPageIndex(index) ||
                    !OfficePdfRendererContract.validZoom(zoom)
                ) {
                    runCatching { fd?.close() }
                    return null
                }
                ParsedRequest.Render(id, fd, index, zoom)
            }

            OfficePdfRendererContract.T_RELEASE_SHM -> {
                val id = data.readLong()
                val shmId = data.readLong()
                if (!OfficePdfRendererContract.validRequestId(id) || shmId < 0L) return null
                ParsedRequest.Release(id, shmId)
            }

            else -> null
        }
    }

    @JvmStatic
    fun writeInfoReply(reply: Parcel, requestId: Long, status: Int, pageCount: Int) {
        reply.writeLong(requestId)
        reply.writeInt(status)
        if (status == OfficePdfRendererContract.S_OK) reply.writeInt(pageCount)
    }

    @JvmStatic
    fun writePageReply(
        reply: Parcel,
        requestId: Long,
        status: Int,
        widthPx: Int,
        heightPx: Int,
        bytes: Long,
        shmId: Long,
        shared: SharedMemory?,
    ) {
        reply.writeLong(requestId)
        reply.writeInt(status)
        if (status == OfficePdfRendererContract.S_OK && shared != null) {
            reply.writeInt(widthPx)
            reply.writeInt(heightPx)
            reply.writeLong(bytes)
            reply.writeLong(shmId)
            reply.writeTypedObject(shared, 0)
        }
    }

    @JvmStatic
    fun writeReleaseReply(reply: Parcel, requestId: Long) {
        reply.writeLong(requestId)
        reply.writeInt(OfficePdfRendererContract.S_OK)
    }
}

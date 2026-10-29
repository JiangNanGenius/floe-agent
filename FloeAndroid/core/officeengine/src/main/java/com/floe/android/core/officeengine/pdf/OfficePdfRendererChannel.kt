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

    /** pageText success: bounded, identity-tagged text + point-space regions. */
    data class Text(val requestId: Long, val page: OfficePdfPageText) : PdfRenderReply()

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
    fun documentInfo(renderer: IBinder?, requestId: Long, fd: ParcelFileDescriptor): PdfRenderReply? =
        documentInfo(renderer, requestId, fd, null)

    /**
     * documentInfo with an OPTIONAL RAM-only password. The password crosses
     * the binder as a `char[]` (never a String/path/Bundle); the isolated
     * service copies it into the SDK's required String and zeroes its copy.
     * Null keeps the previous no-password behaviour.
     */
    @JvmStatic
    fun documentInfo(
        renderer: IBinder?,
        requestId: Long,
        fd: ParcelFileDescriptor,
        password: CharArray?,
    ): PdfRenderReply? {
        if (!OfficePdfTextContract.validPassword(password)) return null
        val reply = transact(renderer, OfficePdfRendererContract.T_DOCUMENT_INFO, requestId) { data ->
            data.writeLong(requestId)
            data.writeFileDescriptor(fd.fileDescriptor)
            data.writePassword(password)
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
    ): PdfRenderReply? = renderPage(renderer, requestId, fd, pageIndex, zoomPercent, null)

    @JvmStatic
    fun renderPage(
        renderer: IBinder?,
        requestId: Long,
        fd: ParcelFileDescriptor,
        pageIndex: Int,
        zoomPercent: Int,
        password: CharArray?,
    ): PdfRenderReply? {
        if (!OfficePdfTextContract.validPassword(password)) return null
        val reply = transact(renderer, OfficePdfRendererContract.T_RENDER_PAGE, requestId) { data ->
            data.writeLong(requestId)
            data.writeFileDescriptor(fd.fileDescriptor)
            data.writeInt(pageIndex)
            data.writeInt(zoomPercent)
            data.writePassword(password)
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

    /**
     * Extracts ONE page's bounded text + point-space regions from the SAME
     * isolated parser that renders it. Bounds are validated on the wire
     * BEFORE any list/string is materialized; a malformed reply returns null
     * and is never presented as "no text".
     */
    @JvmStatic
    fun pageText(
        renderer: IBinder?,
        requestId: Long,
        fd: ParcelFileDescriptor,
        pageIndex: Int,
        maxChars: Int,
        password: CharArray?,
    ): PdfRenderReply? {
        if (!OfficePdfRendererContract.validPageIndex(pageIndex)) return null
        if (maxChars !in 1..OfficePdfTextContract.MAX_TEXT_CHARS_PER_PAGE) return null
        if (!OfficePdfTextContract.validPassword(password)) return null
        val reply = transact(renderer, OfficePdfRendererContract.T_PAGE_TEXT, requestId) { data ->
            data.writeLong(requestId)
            data.writeFileDescriptor(fd.fileDescriptor)
            data.writeInt(pageIndex)
            data.writeInt(maxChars)
            data.writePassword(password)
        } ?: return null
        return try {
            val id = reply.readLong()
            val status = reply.readInt()
            if (id != requestId || !OfficePdfRendererContract.validTextStatus(status)) return null
            if (status != OfficePdfRendererContract.S_OK) return PdfRenderReply.Refusal(id, status)
            val pageIndexOut = reply.readInt()
            val pageCount = reply.readInt()
            val sourceBytes = reply.readLong()
            val pageWidthPt = reply.readFloat()
            val pageHeightPt = reply.readFloat()
            val flags = reply.readInt()
            if (pageIndexOut != pageIndex) return null
            if (pageCount !in 1..OfficePdfRendererContract.MAX_PAGE_INDEX) return null
            if (pageIndexOut >= pageCount) return null
            if (sourceBytes !in 1L..OfficePdfVerifiedSourceContract.MAX_SOURCE_BYTES) return null
            if (!OfficePdfTextContract.validPageBox(pageWidthPt, pageHeightPt)) return null
            if (flags and OfficePdfTextContract.FLAG_TRUNCATED.inv() != 0) return null
            val text = reply.readString() ?: return null
            if (text.length > maxChars) return null
            val regionCount = reply.readInt()
            if (regionCount !in 0..OfficePdfTextContract.MAX_TEXT_REGIONS) return null
            val regions = ArrayList<OfficePdfTextRegion>(regionCount)
            for (i in 0 until regionCount) {
                val start = reply.readInt()
                val end = reply.readInt()
                val rectCount = reply.readInt()
                if (start < 0 || end < start || end > text.length) return null
                if (rectCount !in 0..OfficePdfTextContract.MAX_REGION_RECTS) return null
                // Read the encoded array length FIRST and bound it before
                // allocating: a malformed reply can never drive a large
                // allocation here.
                val floatCount = reply.readInt()
                if (floatCount != rectCount * 4) return null
                val floats = FloatArray(floatCount)
                reply.readFloatArray(floats)
                val rects = ArrayList<OfficePdfTextRect>(rectCount)
                for (r in 0 until rectCount) {
                    val o = r * 4
                    val rect = OfficePdfTextRect(floats[o], floats[o + 1], floats[o + 2], floats[o + 3])
                    if (!OfficePdfTextContract.validRect(rect, pageWidthPt, pageHeightPt)) return null
                    rects.add(rect)
                }
                regions.add(OfficePdfTextRegion(start, end, rects))
            }
            val payload = OfficePdfPageText(
                pageIndex = pageIndexOut,
                pageCount = pageCount,
                sourceBytes = sourceBytes,
                pageWidthPt = pageWidthPt,
                pageHeightPt = pageHeightPt,
                text = text,
                regions = regions,
                truncated = (flags and OfficePdfTextContract.FLAG_TRUNCATED) != 0,
            )
            if (!OfficePdfTextContract.accept(payload, pageIndex, sourceBytes)) return null
            PdfRenderReply.Text(id, OfficePdfTextContract.sanitize(payload) ?: return null)
        } catch (_: Exception) {
            null
        } finally {
            reply.recycle()
        }
    }

    /** Writes the optional password as an explicit length + char array (-1 = none). */
    private fun Parcel.writePassword(password: CharArray?) {
        if (password == null) {
            writeInt(OfficePdfTextContract.NO_PASSWORD)
        } else {
            writeInt(password.size)
            writeCharArray(password)
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

    /**
     * Private sentinel for a malformed password shape. It is a unique object
     * so `null` keeps meaning "no password" and no valid array can equal it.
     */
    private val INVALID = CharArray(0)

    sealed class ParsedRequest {
        data class Info(
            val requestId: Long,
            val fd: ParcelFileDescriptor,
            val password: CharArray?,
        ) : ParsedRequest()
        data class Render(
            val requestId: Long,
            val fd: ParcelFileDescriptor,
            val pageIndex: Int,
            val zoomPercent: Int,
            val password: CharArray?,
        ) : ParsedRequest()

        data class Text(
            val requestId: Long,
            val fd: ParcelFileDescriptor,
            val pageIndex: Int,
            val maxChars: Int,
            val password: CharArray?,
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
                val password = readPasswordOrNull(data, fd)
                if (!OfficePdfRendererContract.validRequestId(id) || fd == null || password === INVALID) {
                    runCatching { fd?.close() }
                    password?.takeUnless { it === INVALID }?.fill('\u0000')
                    return null
                }
                ParsedRequest.Info(id, fd, password)
            }

            OfficePdfRendererContract.T_RENDER_PAGE -> {
                val id = data.readLong()
                val fd = data.readFileDescriptor()
                val index = data.readInt()
                val zoom = data.readInt()
                val password = readPasswordOrNull(data, fd)
                if (!OfficePdfRendererContract.validRequestId(id) || fd == null ||
                    !OfficePdfRendererContract.validPageIndex(index) ||
                    !OfficePdfRendererContract.validZoom(zoom) || password === INVALID
                ) {
                    runCatching { fd?.close() }
                    password?.takeUnless { it === INVALID }?.fill('\u0000')
                    return null
                }
                ParsedRequest.Render(id, fd, index, zoom, password)
            }

            OfficePdfRendererContract.T_PAGE_TEXT -> {
                val id = data.readLong()
                val fd = data.readFileDescriptor()
                val index = data.readInt()
                val maxChars = data.readInt()
                val password = readPasswordOrNull(data, fd)
                if (!OfficePdfRendererContract.validRequestId(id) || fd == null ||
                    !OfficePdfRendererContract.validPageIndex(index) ||
                    maxChars !in 1..OfficePdfTextContract.MAX_TEXT_CHARS_PER_PAGE ||
                    password === INVALID
                ) {
                    runCatching { fd?.close() }
                    password?.takeUnless { it === INVALID }?.fill('\u0000')
                    return null
                }
                ParsedRequest.Text(id, fd, index, maxChars, password)
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

    /**
     * Reads the optional password. Returns null for "none", the parsed array
     * for a valid one, and the private [INVALID] sentinel for a malformed
     * shape (the caller closes the FD and zeroes nothing it did not own).
     */
    private fun readPasswordOrNull(data: Parcel, fd: ParcelFileDescriptor?): CharArray? {
        val count = runCatching { data.readInt() }.getOrElse {
            runCatching { fd?.close() }
            return INVALID
        }
        if (count == OfficePdfTextContract.NO_PASSWORD) return null
        if (count !in 1..OfficePdfTextContract.MAX_PASSWORD_CHARS) {
            runCatching { fd?.close() }
            return INVALID
        }
        val chars = runCatching { data.createCharArray() }.getOrNull()
        if (chars == null || chars.size != count) {
            chars?.fill('\u0000')
            runCatching { fd?.close() }
            return INVALID
        }
        return chars
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
    fun writeTextReply(reply: Parcel, requestId: Long, status: Int, page: OfficePdfPageText?) {
        reply.writeLong(requestId)
        reply.writeInt(status)
        if (status != OfficePdfRendererContract.S_OK || page == null) return
        reply.writeInt(page.pageIndex)
        reply.writeInt(page.pageCount)
        reply.writeLong(page.sourceBytes)
        reply.writeFloat(page.pageWidthPt)
        reply.writeFloat(page.pageHeightPt)
        reply.writeInt(if (page.truncated) OfficePdfTextContract.FLAG_TRUNCATED else 0)
        reply.writeString(page.text)
        reply.writeInt(page.regions.size)
        for (region in page.regions) {
            reply.writeInt(region.startChar)
            reply.writeInt(region.endChar)
            reply.writeInt(region.rects.size)
            val floats = FloatArray(region.rects.size * 4)
            region.rects.forEachIndexed { i, rect ->
                val o = i * 4
                floats[o] = rect.left
                floats[o + 1] = rect.top
                floats[o + 2] = rect.right
                floats[o + 3] = rect.bottom
            }
            reply.writeFloatArray(floats)
        }
    }

    @JvmStatic
    fun writeReleaseReply(reply: Parcel, requestId: Long) {
        reply.writeLong(requestId)
        reply.writeInt(OfficePdfRendererContract.S_OK)
    }
}

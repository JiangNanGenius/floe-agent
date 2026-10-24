// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.os.Process
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * The real device backend. This file is the ONLY place touching
 * ContentResolver/DocumentsContract; it is deliberately NOT exercised by JVM
 * unit tests (framework stubs throw there) — tests inject fakes through
 * [SafPlatformBackend]. On-device behavior is verified by Main's qualification.
 *
 * API notes verified 2026-10-24 against official docs:
 *  - There is NO `ContentResolver.openInputStream(uri, CancellationSignal)`
 *    overload. Cancellable opens use
 *    `openAssetFileDescriptor(uri, "r", signal)` /
 *    `openTypedAssetFileDescriptor(uri, mime, null, signal)` (typed+signal on R+;
 *    the legacy 3-arg typed call on older levels, still loop-cancellable).
 *  - `takePersistableUriPermission` requires a flag ACTUALLY granted to us; we
 *    persist/release EXACTLY one requested flag at a time (defect 1 fix 2026-10-24:
 *    the official tree snippet pairs READ|WRITE, but pairing is NOT required and
 *    an unrequested paired take would entangle another feature's READ).
 *  - `queryChildDocuments`/cursor SORT/LIMIT are provider-opinionated: we pass
 *    NO selection/sort SQL at all and page through a HELD cursor lease instead
 *    (Main steering 2026-10-24).
 */
class AndroidSafBackend(private val context: Context) : SafPlatformBackend {

    private val resolver = context.contentResolver

    // ---- cursor leases: opaque token -> live held provider cursor --------
    private inner class Lease(
        val token: String,
        val treeUri: Uri,
        val parentDocumentId: String,
        var cursor: Cursor?,
        var consumed: Int,
        var lastUsedMillis: Long,
    )

    private val leases = ConcurrentHashMap<String, Lease>()
    private val leaseSeq = AtomicLong(0)
    private val leaseTtlMillis = 120_000L
    private val maxLeases = 8

    override fun classifyUri(uriString: String): SafUriKind = guarded {
        val uri = Uri.parse(uriString)
        when {
            DocumentsContract.isTreeUri(uri) -> SafUriKind.TREE
            DocumentsContract.isDocumentUri(context, uri) -> SafUriKind.DOCUMENT
            else -> SafUriKind.NON_SAF
        }
    }

    override fun persistedGrants(): List<GrantSnapshot> = guarded {
        resolver.persistedUriPermissions.map { permission ->
            GrantSnapshot(
                uri = SafUriRef(permission.uri.toString()),
                read = permission.isReadPermission,
                write = permission.isWritePermission,
            )
        }
    }

    override fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome {
        val real = Uri.parse(uri.uriString)
        val already = runCatching {
            resolver.persistedUriPermissions.any { p ->
                p.uri == real && (if (flag == SafAccessFlag.READ) p.isReadPermission else p.isWritePermission)
            }
        }.getOrDefault(false)
        if (already) return TakeOutcome.AlreadyHeld
        // Main steering 2026-10-24 defect 1: persist EXACTLY the requested single
        // flag. The official tree picker snippet pairs READ|WRITE, but pairing is
        // not a platform requirement; an unrequested paired take would let our
        // later release end a READ that another feature still relies on. If a
        // specific provider rejects WRITE-only persistence, that surfaces as a
        // truthful Refused outcome and the flag simply remains session-only.
        val bits = when (flag) {
            SafAccessFlag.READ -> Intent.FLAG_GRANT_READ_URI_PERMISSION
            SafAccessFlag.WRITE -> Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        }
        return try {
            resolver.takePersistableUriPermission(real, bits)
            TakeOutcome.Persisted
        } catch (security: SecurityException) {
            TakeOutcome.Refused("not-granted:${security.message?.take(64)}")
        } catch (bad: IllegalArgumentException) {
            TakeOutcome.Refused("bad-flags:${bad.message?.take(64)}")
        } catch (unsupported: UnsupportedOperationException) {
            TakeOutcome.TransientOnly("provider-refused-persist")
        }
    }

    override fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean = try {
        // Mirror the single-flag take: release only the requested flag (defect 1).
        resolver.releasePersistableUriPermission(
            Uri.parse(uri.uriString),
            when (flag) {
                SafAccessFlag.READ -> Intent.FLAG_GRANT_READ_URI_PERMISSION
                SafAccessFlag.WRITE -> Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            },
        )
        true
    } catch (t: RuntimeException) {
        false // already revoked/absent: never a retry loop (attachment precedent)
    }

    override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe {
        val real = Uri.parse(uri.uriString)
        fun probe(bit: Int): ProbeFlag = try {
            when (context.checkUriPermission(real, Process.myPid(), Process.myUid(), bit)) {
                PackageManager.PERMISSION_GRANTED -> ProbeFlag.GRANTED
                PackageManager.PERMISSION_DENIED -> ProbeFlag.DENIED
                else -> ProbeFlag.UNKNOWN
            }
        } catch (t: RuntimeException) {
            ProbeFlag.UNKNOWN // declarative answer unavailable; the real open decides
        }
        return AccessProbe(
            read = if (needsRead) probe(Intent.FLAG_GRANT_READ_URI_PERMISSION) else ProbeFlag.UNKNOWN,
            write = if (needsWrite) probe(Intent.FLAG_GRANT_WRITE_URI_PERMISSION) else ProbeFlag.UNKNOWN,
        )
    }

    override fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef? {
        val real = Uri.parse(tree.uriString)
        val rootDocId = runCatching { DocumentsContract.getTreeDocumentId(real) }.getOrNull() ?: return null
        val docUri = runCatching { DocumentsContract.buildDocumentUriUsingTree(real, rootDocId) }.getOrNull() ?: return null
        return SafDocumentRef(tree = tree, documentId = rootDocId, parentDocumentId = null, uri = SafUriRef(docUri.toString()))
    }

    override fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef? {
        val real = Uri.parse(tree.uriString)
        val built = runCatching { DocumentsContract.buildDocumentUriUsingTree(real, documentId) }.getOrNull()
        return built?.let { SafUriRef(it.toString()) }
    }

    override fun queryChildDocuments(
        tree: SafUriRef,
        parentDocumentId: String?,
        limit: Int,
        cursorToken: String?,
        cancel: SafCancelToken,
    ): ChildScan {
        val rootRef = if (parentDocumentId == null) resolveTreeRoot(tree)
            ?: throw SafBackendFaultException(SafBackendFault.NOT_FOUND, "tree root unresolvable")
        else null
        val parentId = parentDocumentId ?: rootRef!!.documentId
            ?: throw SafBackendFaultException(SafBackendFault.NOT_FOUND, "tree has no root document id")
        val realTree = Uri.parse(tree.uriString)
        sweepLeases()
        var note: String? = null
        var lease = cursorToken?.let { leases[it] }
        if (lease != null && (lease.treeUri != realTree || lease.parentDocumentId != parentId)) {
            closeLease(lease.token)
            lease = null
            note = "cursor-token-not-for-this-parent; restarted"
        }
        if (lease != null && (lease.cursor == null || leaseIsStale(lease))) {
            closeLease(lease.token)
            lease = null
            note = (note?.plus(" | ") ?: "") + "cursor-expired-restarted"
        }
        if (lease == null) {
            if (cursorToken != null) note = (note?.plus(" | ") ?: "") + "unknown-cursor-token-restarted"
            val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(realTree, parentId)
            val cursor = try {
                // No selection, no selectionArgs, no sort claim: we page through the
                // provider's own cursor instead of trusting honored LIMIT/SORT (it may
                // be ignored, and names can repeat).
                resolver.query(childUri, DOCUMENT_PROJECTION, null, null, null)
                    ?: throw SafBackendFaultException(SafBackendFault.OFFLINE, "provider returned a null cursor")
            } catch (fault: SafBackendFaultException) {
                throw fault
            } catch (t: Throwable) {
                throw mapThrowable(t)
            }
            lease = Lease("cs-" + leaseSeq.incrementAndGet(), realTree, parentId, cursor, 0, nowMillis())
            leases[lease.token] = lease
        }
        lease.lastUsedMillis = nowMillis()
        val startConsumed = lease.consumed
        val rows = ArrayList<SafDocument>(limit + 1)
        try {
            var position = startConsumed
            while (true) {
                cancel.ensureActive()
                if (rows.size > limit) {
                    // One row beyond the cap was fetched: MORE exists behind the cursor.
                    lease.consumed = startConsumed + limit
                    return ChildScan(
                        documents = ArrayList(rows.subList(0, limit)),
                        nextCursorToken = lease.token,
                        truncatedByLimit = true,
                        note = note,
                    )
                }
                val cursor = lease.cursor ?: throw SafBackendFaultException(SafBackendFault.OFFLINE, "cursor closed")
                if (!cursor.moveToPosition(position)) {
                    // exhausted: close the lease and report completion honestly
                    closeLease(lease.token)
                    return ChildScan(rows, nextCursorToken = null, truncatedByLimit = false, note = note)
                }
                rows += mapRow(cursor, tree, parentId)
                position++
            }
        } catch (cancelled: SafCancelledException) {
            closeLease(lease.token)
            throw cancelled
        } catch (fault: SafBackendFaultException) {
            closeLease(lease.token)
            throw fault
        } catch (t: Throwable) {
            closeLease(lease.token)
            throw mapThrowable(t)
        }
    }

    override fun releaseCursor(cursorToken: String): Boolean {
        val existed = leases.containsKey(cursorToken)
        closeLease(cursorToken)
        return existed
    }

    override fun releaseAllCursors() {
        leases.keys.toList().forEach { closeLease(it) }
    }

    private fun mapRow(cursor: Cursor, tree: SafUriRef, parentDocumentId: String): SafDocument {
        fun columnString(name: String): String? =
            cursor.getColumnIndex(name).takeIf { it >= 0 }?.let { cursor.getString(it) }
        fun columnLong(name: String): Long? =
            cursor.getColumnIndex(name).takeIf { it >= 0 }?.let { idx ->
                if (cursor.isNull(idx)) null else runCatching { cursor.getLong(idx) }.getOrNull()
                    ?: runCatching { cursor.getString(idx)?.toLongOrNull() }.getOrNull()
            }
        fun columnInt(name: String): Int =
            cursor.getColumnIndex(name).takeIf { it >= 0 }?.let {
                if (cursor.isNull(it)) 0 else runCatching { cursor.getInt(it) }.getOrDefault(0)
            } ?: 0
        val docId = columnString(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            ?: throw SafBackendFaultException(SafBackendFault.FAILED, "provider row without DOCUMENT_ID")
        val childUri = runCatching {
            DocumentsContract.buildDocumentUriUsingTree(Uri.parse(tree.uriString), docId)
        }.getOrNull() ?: throw SafBackendFaultException(SafBackendFault.FAILED, "cannot build child uri")
        val flags = columnInt(DocumentsContract.Document.COLUMN_FLAGS)
        return SafDocument(
            ref = SafDocumentRef(
                tree = tree,
                documentId = docId,
                parentDocumentId = parentDocumentId,
                uri = SafUriRef(childUri.toString()),
            ),
            displayName = columnString(DocumentsContract.Document.COLUMN_DISPLAY_NAME) ?: docId.substringAfterLast('/'),
            mimeType = columnString(DocumentsContract.Document.COLUMN_MIME_TYPE) ?: "application/octet-stream",
            size = SafSize.fromProviderColumn(columnLong(DocumentsContract.Document.COLUMN_SIZE)),
            lastModifiedMillis = columnLong(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
            capabilities = SafCapabilities.fromProviderFlags(flags),
        )
    }

    // ---- metadata + mutations ---------------------------------------------

    override fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument? = guarded(cancel) {
        // A document URI is directly queryable; DocumentsContract.queryDocument is a
        // provider-side name, not a reliable public client helper. Plain query with
        // no selection/sort keeps us provider-agnostic and SQL-free.
        val cursor = try {
            resolver.query(Uri.parse(ref.uri.uriString), DOCUMENT_PROJECTION, null, null, null)
        } catch (fnf: FileNotFoundException) {
            return@guarded null
        }
        cursor?.use {
            if (!it.moveToFirst()) null else mapRow(it, ref.tree ?: fallbackTreeOf(ref), ref.parentDocumentId ?: ref.documentId ?: "")
        }
    }

    override fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef, cancel: SafCancelToken): Boolean = guarded(cancel) {
        val rootRef = resolveTreeRoot(ancestorTree) ?: return@guarded false
        try {
            val parentUri = Uri.parse(rootRef.uri.uriString)
            val childUri = Uri.parse(child.uri.uriString)
            if (childUri.authority != parentUri.authority) return@guarded false
            val childId = DocumentsContract.getDocumentId(childUri)
            if (child.documentId != null && child.documentId != childId) return@guarded false
            val descendant = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                DocumentsContract.isChildDocument(resolver, parentUri, childUri)
            } else {
                // API 28 has canonical provider paths (API 26), but the public
                // isChildDocument client helper arrives in API 29. Require the
                // provider's tree-rooted ID path; opaque ID prefixes prove nothing.
                val rootId = rootRef.documentId ?: return@guarded false
                val scopedChild = DocumentsContract.buildDocumentUriUsingTree(
                    Uri.parse(ancestorTree.uriString), childId,
                )
                val path = DocumentsContract.findDocumentPath(resolver, scopedChild)?.path
                path != null && path.size > 1 && path.first() == rootId && path.last() == childId
            }
            ensureActive(cancel)
            descendant
        } catch (t: Throwable) {
            when (t) {
                is SecurityException -> throw SafBackendFaultException(SafBackendFault.REVOKED, t.message ?: "revoked")
                is IllegalArgumentException -> false
                else -> throw mapThrowable(t)
            }
        }
    }

    override fun openRead(ref: SafDocumentRef, mimeFilter: String?, cancel: SafCancelToken): ReadOpen {
        val real = Uri.parse(ref.uri.uriString)
        val signal = newSignal(cancel)
        return try {
            val afd = if (mimeFilter != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    resolver.openTypedAssetFileDescriptor(real, mimeFilter, null, signal)
                } else {
                    @Suppress("DEPRECATION")
                    resolver.openTypedAssetFileDescriptor(real, mimeFilter, null)
                }
            } else {
                resolver.openAssetFileDescriptor(real, "r", signal)
            } ?: return ReadOpen.NotFound
            val lengthHint = if (afd.length >= 0) afd.length else null
            cancel.ensureActive()
            ReadOpen.Opened(afd.createInputStream(), lengthHint)
        } catch (fnf: FileNotFoundException) {
            ReadOpen.NotFound
        } catch (t: Throwable) {
            throw mapThrowable(t)
        }
    }

    override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
        val real = Uri.parse(ref.uri.uriString)
        val signal = newSignal(cancel)
        return try {
            val afd = resolver.openAssetFileDescriptor(real, "wt", signal) ?: return WriteOpen.UnsupportedMode
            cancel.ensureActive()
            WriteOpen.Opened(afd.createOutputStream())
        } catch (fnf: FileNotFoundException) {
            WriteOpen.NotFound
        } catch (bad: IllegalArgumentException) {
            WriteOpen.UnsupportedMode
        } catch (unsupported: UnsupportedOperationException) {
            WriteOpen.UnsupportedMode
        } catch (t: Throwable) {
            throw mapThrowable(t)
        }
    }

    override fun streamTypes(ref: SafDocumentRef): List<String> = try {
        resolver.getStreamTypes(Uri.parse(ref.uri.uriString), "*/*")?.toList() ?: emptyList()
    } catch (t: Throwable) {
        when (t) {
            is SecurityException -> throw SafBackendFaultException(SafBackendFault.REVOKED, t.message ?: "revoked")
            else -> emptyList()
        }
    }

    override fun createDocument(
        tree: SafUriRef,
        parentDocumentId: String?,
        mimeType: String,
        displayName: String,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        ensureActive(cancel)
        val realTree = Uri.parse(tree.uriString)
        val parentUri = parentDocumentId?.let { DocumentsContract.buildDocumentUriUsingTree(realTree, it) }
            ?: runCatching { DocumentsContract.buildDocumentUriUsingTree(realTree, DocumentsContract.getTreeDocumentId(realTree)) }.getOrNull()
            ?: return OpResult.NullReturned("tree parent unresolvable")
        val created = try {
            DocumentsContract.createDocument(resolver, parentUri, mimeType, displayName)
        } catch (t: Throwable) {
            throw mapThrowable(t)
        } ?: return OpResult.NullReturned("provider returned null")
        val docId = runCatching { DocumentsContract.getDocumentId(created) }.getOrNull()
        return OpResult.Ok(
            SafDocumentRef(tree = tree, documentId = docId, parentDocumentId = parentDocumentId, uri = SafUriRef(created.toString())),
        )
    }

    override fun renameDocument(ref: SafDocumentRef, newName: String, cancel: SafCancelToken): OpResult<SafDocumentRef> {
        ensureActive(cancel)
        val renamed = try {
            DocumentsContract.renameDocument(resolver, Uri.parse(ref.uri.uriString), newName)
        } catch (t: Throwable) {
            throw mapThrowable(t)
        } ?: return OpResult.NullReturned("provider returned null")
        return OpResult.Ok(ref.copy(uri = SafUriRef(renamed.toString()), documentId = runCatching { DocumentsContract.getDocumentId(renamed) }.getOrNull() ?: ref.documentId))
    }

    override fun moveDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        ensureActive(cancel)
        // Defect 2 fix 2026-10-24: the real public overload is
        // moveDocument(resolver, sourceDocumentUri, sourceParentDocumentUri, targetParentUri).
        // The source parent must be EXPLICIT (tree + known parentDocumentId);
        // with no resolvable parent we refuse rather than guess one.
        val sourceTree = ref.tree ?: return OpResult.NullReturned("no tree context to resolve explicit source parent")
        val parentId = ref.parentDocumentId ?: return OpResult.NullReturned("explicit source parent required; refusing to guess")
        val realSourceTree = Uri.parse(sourceTree.uriString)
        val sourceParentUri = runCatching {
            DocumentsContract.buildDocumentUriUsingTree(realSourceTree, parentId)
        }.getOrNull() ?: return OpResult.NullReturned("source parent unresolvable")
        val realDest = Uri.parse(destTree.uriString)
        val destParentUri = destParentDocumentId?.let { DocumentsContract.buildDocumentUriUsingTree(realDest, it) }
            ?: runCatching { DocumentsContract.buildDocumentUriUsingTree(realDest, DocumentsContract.getTreeDocumentId(realDest)) }.getOrNull()
            ?: return OpResult.NullReturned("destination parent unresolvable")
        val moved = try {
            DocumentsContract.moveDocument(
                resolver,
                Uri.parse(ref.uri.uriString),
                sourceParentUri,
                destParentUri,
            )
        } catch (t: Throwable) {
            throw mapThrowable(t)
        } ?: return OpResult.NullReturned("provider returned null")
        val docId = runCatching { DocumentsContract.getDocumentId(moved) }.getOrNull() ?: ref.documentId
        return OpResult.Ok(SafDocumentRef(tree = destTree, documentId = docId, parentDocumentId = destParentDocumentId, uri = SafUriRef(moved.toString())))
    }

    override fun copyDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        ensureActive(cancel)
        val realDest = Uri.parse(destTree.uriString)
        val destParentUri = destParentDocumentId?.let { DocumentsContract.buildDocumentUriUsingTree(realDest, it) }
            ?: runCatching { DocumentsContract.buildDocumentUriUsingTree(realDest, DocumentsContract.getTreeDocumentId(realDest)) }.getOrNull()
            ?: return OpResult.NullReturned("destination parent unresolvable")
        val copied = try {
            DocumentsContract.copyDocument(resolver, Uri.parse(ref.uri.uriString), destParentUri)
        } catch (t: Throwable) {
            throw mapThrowable(t)
        } ?: return OpResult.NullReturned("provider returned null")
        val docId = runCatching { DocumentsContract.getDocumentId(copied) }.getOrNull()
        return OpResult.Ok(SafDocumentRef(tree = destTree, documentId = docId, parentDocumentId = destParentDocumentId, uri = SafUriRef(copied.toString())))
    }

    override fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): OpResult<Boolean> {
        ensureActive(cancel)
        return try {
            OpResult.Ok(DocumentsContract.deleteDocument(resolver, Uri.parse(ref.uri.uriString)))
        } catch (t: Throwable) {
            throw mapThrowable(t)
        }
    }

    override fun selfCheck(): List<String> {
        val mismatches = mutableListOf<String>()
        fun check(name: String, ours: Int, platform: Int) {
            if (ours != platform) mismatches += "$name: documented=$ours platform=$platform"
        }
        // These comparisons use the REAL compile-time SDK constants (inlined at
        // build time); any drift between our documented copies and android.jar
        // is caught on first device use.
        check("SUPPORTS_THUMBNAIL", SafProviderFlagBits.SUPPORTS_THUMBNAIL, DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL)
        check("SUPPORTS_WRITE", SafProviderFlagBits.SUPPORTS_WRITE, DocumentsContract.Document.FLAG_SUPPORTS_WRITE)
        check("SUPPORTS_DELETE", SafProviderFlagBits.SUPPORTS_DELETE, DocumentsContract.Document.FLAG_SUPPORTS_DELETE)
        check("DIR_SUPPORTS_CREATE", SafProviderFlagBits.DIR_SUPPORTS_CREATE, DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE)
        check("SUPPORTS_RENAME", SafProviderFlagBits.SUPPORTS_RENAME, DocumentsContract.Document.FLAG_SUPPORTS_RENAME)
        check("SUPPORTS_COPY", SafProviderFlagBits.SUPPORTS_COPY, DocumentsContract.Document.FLAG_SUPPORTS_COPY)
        check("SUPPORTS_MOVE", SafProviderFlagBits.SUPPORTS_MOVE, DocumentsContract.Document.FLAG_SUPPORTS_MOVE)
        check("VIRTUAL_DOCUMENT", SafProviderFlagBits.VIRTUAL_DOCUMENT, DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT)
        check("SUPPORTS_REMOVE", SafProviderFlagBits.SUPPORTS_REMOVE, DocumentsContract.Document.FLAG_SUPPORTS_REMOVE)
        check("GRANT_READ", SafGrantFlagBits.GRANT_READ, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        check("GRANT_WRITE", SafGrantFlagBits.GRANT_WRITE, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        check("PERSISTABLE", SafGrantFlagBits.PERSISTABLE, Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        return mismatches
    }

    // ---- plumbing ----------------------------------------------------------

    private fun newSignal(cancel: SafCancelToken): CancellationSignal {
        val signal = CancellationSignal()
        cancel.onCancel { runCatching { signal.cancel() } }
        if (cancel.isCancelled) runCatching { signal.cancel() }
        return signal
    }

    private fun ensureActive(cancel: SafCancelToken) {
        if (cancel.isCancelled) throw SafCancelledException()
    }

    private fun nowMillis(): Long = System.currentTimeMillis()

    private fun leaseIsStale(lease: Lease): Boolean = nowMillis() - lease.lastUsedMillis > leaseTtlMillis

    private fun sweepLeases() {
        val now = nowMillis()
        val stale = leases.entries.filter { now - it.value.lastUsedMillis > leaseTtlMillis }.map { it.key }
        stale.forEach { closeLease(it) }
        if (leases.size > maxLeases) {
            leases.entries.sortedBy { it.value.lastUsedMillis }.take(leases.size - maxLeases)
                .map { it.key }.forEach { closeLease(it) }
        }
    }

    private fun closeLease(token: String) {
        val lease = leases.remove(token) ?: return
        runCatching { lease.cursor?.close() }
        lease.cursor = null
    }

    private fun fallbackTreeOf(ref: SafDocumentRef): SafUriRef = ref.tree ?: ref.uri

    private inline fun <T> guarded(cancel: SafCancelToken, block: () -> T): T {
        ensureActive(cancel)
        return try {
            block()
        } catch (t: Throwable) {
            throw mapThrowable(t)
        }
    }

    private inline fun <T> guarded(block: () -> T): T = try {
        block()
    } catch (fault: SafBackendFaultException) {
        throw fault
    } catch (t: Throwable) {
        throw mapThrowable(t)
    }

    private fun mapThrowable(t: Throwable): SafBackendFaultException = when {
        t is SafBackendFaultException -> t
        t is SafCancelledException -> SafBackendFaultException(SafBackendFault.CANCELLED, "cancelled", t)
        // Android CancellationSignal throws OperationCanceledException; keep it
        // and the Java cancellation shape ahead of offline/provider-state mapping.
        t is OperationCanceledException -> SafBackendFaultException(SafBackendFault.CANCELLED, "signal", t)
        t is SecurityException -> SafBackendFaultException(SafBackendFault.REVOKED, t.message ?: "revoked", t)
        t is UnsupportedOperationException -> SafBackendFaultException(SafBackendFault.UNSUPPORTED, t.message ?: "unsupported", t)
        t is java.util.concurrent.CancellationException -> SafBackendFaultException(SafBackendFault.CANCELLED, "cancelled", t)
        t is IllegalStateException -> SafBackendFaultException(SafBackendFault.OFFLINE, t.message ?: "provider state", t)
        t is FileNotFoundException -> SafBackendFaultException(SafBackendFault.NOT_FOUND, t.message ?: "gone", t)
        t is IOException -> SafBackendFaultException(SafBackendFault.IO, t.message ?: "io", t)
        // android.os.DeadObjectException / RemoteException reach us as subclasses of
        // Exception with those names; binder death is an offline provider state.
        t.javaClass.name.contains("DeadObject") || t.javaClass.name.contains("RemoteException") ->
            SafBackendFaultException(SafBackendFault.OFFLINE, t.message ?: "binder", t)
        else -> SafBackendFaultException(SafBackendFault.FAILED, t.message ?: t.javaClass.simpleName, t)
    }

    companion object {
        private val DOCUMENT_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
    }
}

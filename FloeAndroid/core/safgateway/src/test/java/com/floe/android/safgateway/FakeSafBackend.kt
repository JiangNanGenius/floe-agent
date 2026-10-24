// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

/**
 * Deterministic in-memory SAF provider for JVM unit tests. Models the platform
 * behaviors the gateway depends on (per-flag persistence, session vs persisted
 * truth, held-cursor paging with duplicate names, mode-unsupported writes,
 * lying deletes, mid-stream failures, provider-null mutations) WITHOUT ever
 * touching Android framework stubs.
 */
class FakeSafBackend {

    enum class PersistMode { OK, ALREADY_HELD, FAILS }

    // ---- grant state --------------------------------------------------------
    val persisted = LinkedHashMap<String, MutableSet<SafAccessFlag>>()
    val session = LinkedHashMap<String, Set<SafAccessFlag>>()
    var persistMode: PersistMode = PersistMode.OK
    val takeLog = mutableListOf<Pair<String, SafAccessFlag>>()
    val releaseLog = mutableListOf<Pair<String, SafAccessFlag>>()
    var probeUnknown = false

    // ---- documents ----------------------------------------------------------
    class FakeDoc(
        val uriString: String,
        var name: String,
        var mimeType: String,
        var flags: Int,
        var content: ByteArray,
        var parentDocId: String?,
        var sizeRaw: Long? = null,
        var lastModified: Long? = null,
        val streamTypes: MutableList<String> = mutableListOf(),
    ) {
        val isVirtual: Boolean get() = flags and SafProviderFlagBits.VIRTUAL_DOCUMENT != 0
        fun documentIdFromUri(): String = uriString.substringAfterLast("/document/")
        fun snapshot(): ByteArray = content.copyOf()
    }

    val docs = LinkedHashMap<String, FakeDoc>()
    private val uriSeq = AtomicInteger(0)

    // ---- behavior switches --------------------------------------------------
    var offline = false
    var moveSupported = true
    var copySupported = true
    var writeModeSupported = true
    val writeBlockedUris = mutableSetOf<String>()
    var deleteLies = false
    var breakMembership = false
    var corruptNextCopies = false
    var failReadAfterBytes: Int? = null
    var failWriteAfterBytes: Int? = null
    var onNthRead: ((Int) -> Unit)? = null
    var afterWriteCommitHook: ((FakeDoc) -> Unit)? = null
    /** Mutate THIS uri's content at the next openRead, once (drift injection). */
    val mutateOnNextOpenRead = mutableMapOf<String, ByteArray>()
    /** Mutate whichever doc opens at this global read number, once. */
    var mutateOnOpenReadNumber: Pair<Int, ByteArray>? = null
    /** Throw IOException at this global read number, once (unreadable injection). */
    var throwOnOpenReadNumber: Int? = null
    var openReadCount = 0
    var typedReadCount = 0
    var writeOpens = 0
    var closedStreams = 0

    // ---- cursor leases --------------------------------------------------------
    private class Lease(val token: String, val parentKey: String, var consumed: Int)

    private val leases = LinkedHashMap<String, Lease>()
    private val leaseSeq = AtomicInteger(0)
    var expireNextLeaseUse = false

    fun treeUri(name: String = "main"): SafUriRef = SafUriRef("content://fake.provider/tree/$name")

    fun rootDocumentUriString(tree: SafUriRef): String =
        "content://fake.provider/document/" + treeRootId(tree)

    private fun treeRootId(tree: SafUriRef): String = tree.uriString.substringAfterLast("/tree/") + "-root"

    fun seedRoot(tree: SafUriRef, flags: Int = dirFlags()): FakeDoc {
        val rootId = treeRootId(tree)
        val uri = "content://fake.provider/document/$rootId"
        return FakeDoc(uri, "root", SafDocument.MIME_DIR, flags, ByteArray(0), parentDocId = null)
            .also { docs[uri] = it }
    }

    fun seedDoc(
        tree: SafUriRef,
        name: String,
        mime: String = "text/plain",
        flags: Int = writableFileFlags(),
        content: ByteArray,
        parentDocId: String? = treeRootId(tree),
    ): FakeDoc {
        val docId = "d-" + uriSeq.incrementAndGet()
        val uriString = "content://fake.provider/document/$docId"
        return FakeDoc(uriString, name, mime, flags, content, parentDocId).also { docs[uriString] = it }
    }

    fun refOf(tree: SafUriRef, doc: FakeDoc): SafDocumentRef = SafDocumentRef(
        tree = tree,
        documentId = doc.documentIdFromUri(),
        parentDocumentId = doc.parentDocId,
        uri = SafUriRef(doc.uriString),
    )

    fun writableFileFlags(withDelete: Boolean = true, withMove: Boolean = true, withCopy: Boolean = true): Int =
        SafProviderFlagBits.SUPPORTS_WRITE or
            SafProviderFlagBits.SUPPORTS_RENAME or
            (if (withDelete) SafProviderFlagBits.SUPPORTS_DELETE else 0) or
            (if (withMove) SafProviderFlagBits.SUPPORTS_MOVE else 0) or
            (if (withCopy) SafProviderFlagBits.SUPPORTS_COPY else 0)

    fun dirFlags(): Int =
        SafProviderFlagBits.DIR_SUPPORTS_CREATE or
            SafProviderFlagBits.SUPPORTS_WRITE or
            SafProviderFlagBits.SUPPORTS_DELETE

    private fun checkOffline() {
        if (offline) throw SafBackendFaultException(SafBackendFault.OFFLINE, "provider offline")
    }

    // ---- interface -----------------------------------------------------------

    val backend: SafPlatformBackend = object : SafPlatformBackend {

        override fun classifyUri(uriString: String): SafUriKind = when {
            uriString.contains("/tree/") -> SafUriKind.TREE
            uriString.contains("/document/") -> SafUriKind.DOCUMENT
            else -> SafUriKind.NON_SAF
        }

        override fun persistedGrants(): List<GrantSnapshot> {
            checkOffline()
            return persisted.filter { it.value.isNotEmpty() }.map { (uri, flags) ->
                GrantSnapshot(SafUriRef(uri), SafAccessFlag.READ in flags, SafAccessFlag.WRITE in flags)
            }
        }

        override fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome {
            takeLog += uri.uriString to flag
            return when (persistMode) {
                PersistMode.FAILS -> TakeOutcome.TransientOnly("simulated-refusal")
                PersistMode.ALREADY_HELD -> TakeOutcome.AlreadyHeld
                PersistMode.OK -> {
                    val set = persisted.getOrPut(uri.uriString) { mutableSetOf() }
                    if (flag in set) TakeOutcome.AlreadyHeld else {
                        set += flag
                        TakeOutcome.Persisted
                    }
                }
            }
        }

        override fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean {
            releaseLog += uri.uriString to flag
            val set = persisted[uri.uriString] ?: return false
            return set.remove(flag)
        }

        override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe {
            fun flagProbe(flag: SafAccessFlag, needed: Boolean): ProbeFlag {
                if (!needed) return ProbeFlag.UNKNOWN
                if (probeUnknown) return ProbeFlag.UNKNOWN
                val has = persisted[uri.uriString]?.contains(flag) == true ||
                    session[uri.uriString]?.contains(flag) == true
                return if (has) ProbeFlag.GRANTED else ProbeFlag.DENIED
            }
            return AccessProbe(
                read = flagProbe(SafAccessFlag.READ, needsRead),
                write = flagProbe(SafAccessFlag.WRITE, needsWrite),
            )
        }

        override fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef? {
            checkOffline()
            if (!tree.uriString.contains("/tree/")) return null
            return SafDocumentRef(
                tree = tree,
                documentId = treeRootId(tree),
                parentDocumentId = null,
                uri = SafUriRef(rootDocumentUriString(tree)),
            )
        }

        override fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef? =
            SafUriRef("content://fake.provider/document/$documentId")

        override fun queryChildDocuments(
            tree: SafUriRef,
            parentDocumentId: String?,
            limit: Int,
            cursorToken: String?,
            cancel: SafCancelToken,
        ): ChildScan {
            checkOffline()
            val parentKey = parentDocumentId ?: treeRootId(tree)
            val ordered = docs.values.filter { it.parentDocId == parentKey }
            var note: String? = null
            var lease = cursorToken?.let { leases[it] }
            if (lease != null && expireNextLeaseUse) {
                leases.remove(lease.token)
                lease = null
                expireNextLeaseUse = false
                note = "cursor-expired-restarted"
            }
            if (lease != null && lease.parentKey != parentKey) {
                leases.remove(lease.token)
                lease = null
                note = "cursor-token-not-for-this-parent; restarted"
            }
            if (lease == null) {
                if (cursorToken != null && note == null) note = "unknown-cursor-token-restarted"
                lease = Lease("fcs-" + leaseSeq.incrementAndGet(), parentKey, 0)
                leases[lease.token] = lease
            }
            val rows = ArrayList<FakeDoc>(limit + 1)
            val startConsumed = lease.consumed
            var position = startConsumed
            while (true) {
                cancel.ensureActive()
                if (rows.size > limit) {
                    lease.consumed = startConsumed + limit
                    return ChildScan(
                        documents = rows.take(limit).map { toDocument(it, tree, parentKey) },
                        nextCursorToken = lease.token,
                        truncatedByLimit = true,
                        note = note,
                    )
                }
                if (position >= ordered.size) {
                    leases.remove(lease.token)
                    return ChildScan(
                        documents = rows.map { toDocument(it, tree, parentKey) },
                        nextCursorToken = null,
                        truncatedByLimit = false,
                        note = note,
                    )
                }
                rows += ordered[position]
                position++
            }
        }

        override fun releaseCursor(cursorToken: String): Boolean = leases.remove(cursorToken) != null

        override fun releaseAllCursors() {
            leases.clear()
        }

        override fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument? {
            checkOffline()
            cancel.ensureActive()
            val doc = docs[ref.uri.uriString] ?: return null
            return toDocument(doc, ref.tree, doc.parentDocId ?: "")
        }

        override fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef, cancel: SafCancelToken): Boolean {
            if (breakMembership) return false
            cancel.ensureActive()
            val rootId = treeRootId(ancestorTree)
            if (child.uri.uriString == rootDocumentUriString(ancestorTree)) return true
            var current = docs[child.uri.uriString]?.parentDocId
            var hops = 0
            while (current != null && hops++ < 64) {
                if (current == rootId) return true
                current = docs["content://fake.provider/document/$current"]?.parentDocId
            }
            return false
        }

        override fun openRead(ref: SafDocumentRef, mimeFilter: String?, cancel: SafCancelToken): ReadOpen {
            checkOffline()
            val doc = docs[ref.uri.uriString] ?: return ReadOpen.NotFound
            if (doc.isVirtual && mimeFilter == null) {
                throw SafBackendFaultException(SafBackendFault.UNSUPPORTED, "virtual document has no raw bytes")
            }
            if (mimeFilter != null) typedReadCount++
            openReadCount++
            mutateOnNextOpenRead.remove(ref.uri.uriString)?.let { doc.content = it }
            mutateOnOpenReadNumber?.takeIf { it.first == openReadCount }?.let {
                doc.content = it.second
                mutateOnOpenReadNumber = null
            }
            if (throwOnOpenReadNumber == openReadCount) {
                throwOnOpenReadNumber = null
                throw IOException("simulated provider became unreadable")
            }
            val data = doc.snapshot()
            var reads = 0
            var seen = 0
            val input = object : ByteArrayInputStream(data) {
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    cancel.ensureActive()
                    reads++
                    onNthRead?.invoke(reads)
                    val n = super.read(b, off, len)
                    if (n > 0) {
                        seen += n
                        failReadAfterBytes?.let {
                            if (seen > it) throw IOException("simulated provider stream died")
                        }
                    }
                    return n
                }

                override fun close() {
                    closedStreams++
                    super.close()
                }
            }
            return ReadOpen.Opened(input, lengthHintBytes = doc.sizeRaw)
        }

        override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
            checkOffline()
            val doc = docs[ref.uri.uriString] ?: return WriteOpen.NotFound
            if (!writeModeSupported || doc.uriString in writeBlockedUris) return WriteOpen.UnsupportedMode
            writeOpens++
            val committed = ByteArrayOutputStream()
            var written = 0
            val out = object : ByteArrayOutputStream() {
                override fun write(b: ByteArray, off: Int, len: Int) {
                    cancel.ensureActive()
                    written += len
                    failWriteAfterBytes?.let {
                        if (written > it) throw IOException("simulated write died mid-pass")
                    }
                    committed.write(b, off, len)
                    super.write(b, off, len)
                }

                override fun close() {
                    // Providers commit at close; a mid-write failure leaves the
                    // truncated bytes behind, like a real truncate-open.
                    doc.content = committed.toByteArray()
                    afterWriteCommitHook?.invoke(doc)
                    super.close()
                }
            }
            return WriteOpen.Opened(out)
        }

        override fun streamTypes(ref: SafDocumentRef): List<String> =
            docs[ref.uri.uriString]?.streamTypes?.toList() ?: emptyList()

        override fun createDocument(
            tree: SafUriRef,
            parentDocumentId: String?,
            mimeType: String,
            displayName: String,
            cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> {
            checkOffline()
            cancel.ensureActive()
            val parent = parentDocumentId ?: treeRootId(tree)
            val created = seedDoc(tree, displayName, mimeType, writableFileFlags(), ByteArray(0), parent)
            return OpResult.Ok(SafDocumentRef(tree, created.documentIdFromUri(), parent, SafUriRef(created.uriString)))
        }

        override fun renameDocument(ref: SafDocumentRef, newName: String, cancel: SafCancelToken): OpResult<SafDocumentRef> {
            checkOffline()
            cancel.ensureActive()
            val doc = docs[ref.uri.uriString] ?: return OpResult.NullReturned("gone")
            if (doc.flags and SafProviderFlagBits.SUPPORTS_RENAME == 0) return OpResult.NullReturned("no rename")
            doc.name = newName
            return OpResult.Ok(ref)
        }

        override fun moveDocument(
            ref: SafDocumentRef,
            destTree: SafUriRef,
            destParentDocumentId: String?,
            cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> {
            checkOffline()
            cancel.ensureActive()
            if (ref.parentDocumentId == null) return OpResult.NullReturned("explicit source parent required by contract")
            val doc = docs[ref.uri.uriString] ?: return OpResult.NullReturned("gone")
            if (!moveSupported) return OpResult.NullReturned("cross-provider move rejected")
            if (doc.flags and SafProviderFlagBits.SUPPORTS_MOVE == 0) return OpResult.NullReturned("no move flag")
            val parent = destParentDocumentId ?: treeRootId(destTree)
            doc.parentDocId = parent
            return OpResult.Ok(ref.copy(tree = destTree, parentDocumentId = parent))
        }

        override fun copyDocument(
            ref: SafDocumentRef,
            destTree: SafUriRef,
            destParentDocumentId: String?,
            cancel: SafCancelToken,
        ): OpResult<SafDocumentRef> {
            checkOffline()
            cancel.ensureActive()
            val doc = docs[ref.uri.uriString] ?: return OpResult.NullReturned("gone")
            if (!copySupported) return OpResult.NullReturned("no copy")
            val parent = destParentDocumentId ?: treeRootId(destTree)
            val copy = seedDoc(destTree, doc.name, doc.mimeType, doc.flags, doc.snapshot(), parent)
            if (corruptNextCopies) copy.content = "corrupted-by-provider".toByteArray()
            return OpResult.Ok(SafDocumentRef(destTree, copy.documentIdFromUri(), parent, SafUriRef(copy.uriString)))
        }

        override fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): OpResult<Boolean> {
            checkOffline()
            cancel.ensureActive()
            val doc = docs[ref.uri.uriString] ?: return OpResult.Ok(false)
            if (deleteLies) return OpResult.Ok(true) // "succeeds" while keeping the doc
            docs.remove(ref.uri.uriString)
            doc.parentDocId = null
            return OpResult.Ok(true)
        }

        override fun selfCheck(): List<String> = emptyList()
    }

    private fun toDocument(doc: FakeDoc, tree: SafUriRef?, parentKey: String): SafDocument = SafDocument(
        ref = SafDocumentRef(
            tree = tree,
            documentId = doc.documentIdFromUri(),
            parentDocumentId = parentKey.ifBlank { null },
            uri = SafUriRef(doc.uriString),
        ),
        displayName = doc.name,
        mimeType = doc.mimeType,
        size = SafSize.fromProviderColumn(doc.sizeRaw),
        lastModifiedMillis = doc.lastModified,
        capabilities = SafCapabilities.fromProviderFlags(doc.flags),
    )

    fun expireLeases() {
        expireNextLeaseUse = true
    }

    companion object {
        fun stagingDir(name: String): File =
            File(
                System.getProperty("java.io.tmpdir") ?: ".",
                "safgw-$name-${System.nanoTime()}",
            ).apply { mkdirs() }
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.AccessProbe
import com.floe.android.safgateway.ChildScan
import com.floe.android.safgateway.GrantSnapshot
import com.floe.android.safgateway.OpResult
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.ReadOpen
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCancelledException
import com.floe.android.safgateway.SafCapabilities
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafProviderFlagBits
import com.floe.android.safgateway.SafSize
import com.floe.android.safgateway.SafUriKind
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.TakeOutcome
import com.floe.android.safgateway.WriteOpen
import java.io.ByteArrayInputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * In-memory provider behind the REAL `SafGatewayService`. It mirrors the
 * documented platform contract the controller depends on:
 *  - child rows carry the exact tree, the child's document id and its parent;
 *  - capabilities come from the row's flag bits, never from a guess;
 *  - held-cursor paging is offset-based and honest about the next token;
 *  - a cancelled scan throws [SafCancelledException] exactly like the real
 *    backend's CancellationSignal path.
 */
internal class FakeSpaceFilesBackend(
    val treeUri: String = "content://com.floe.test.documents/tree/primary%3ASpaceFiles",
    val rootDocumentId: String = "primary:SpaceFiles",
) : SafPlatformBackend {

    val tree = SafUriRef(treeUri)

    private val children = ConcurrentHashMap<String, MutableList<SafDocument>>()
    private val documentsByUri = ConcurrentHashMap<String, SafDocument>()
    private val documentNames = ConcurrentHashMap<String, String>()
    val content = ConcurrentHashMap<String, ByteArray>()

    val persisted = ConcurrentHashMap<String, MutableSet<SafAccessFlag>>()
    val takeCalls = CopyOnWriteArrayList<String>()
    val listingCalls = CopyOnWriteArrayList<ListingCall>()
    val createCalls = CopyOnWriteArrayList<CreateCall>()
    val renameCalls = CopyOnWriteArrayList<Pair<String, String>>()
    val deleteCalls = CopyOnWriteArrayList<String>()
    val copyCalls = CopyOnWriteArrayList<String>()
    val moveCalls = CopyOnWriteArrayList<String>()
    val releaseCalls = AtomicInteger()
    val openReadCalls = AtomicInteger()

    var probeGranted: Boolean = true
    /** Models the exact WRITE bit the system returned for the current session. */
    var probeWriteGranted: Boolean = true
    var persistableOffered: Boolean = true
    var nativeMoveSupported: Boolean = true
    /** Document URIs whose provider rejects truncate-write; a freshly created
     * sibling stays writable so the save-as fallback can land verified bytes. */
    val truncateUnsupportedUris = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    var faultOnChildScan: Throwable? = null
    var scanEntered: CountDownLatch? = null
    var cancelObserved: AtomicBoolean = AtomicBoolean(false)
    /** Block every child scan until its token is cancelled (cancellation probe). */
    var blockScansUntilCancelled: Boolean = false

    private val createdSeq = AtomicInteger(0)

    data class ListingCall(
        val tree: String,
        val parentDocumentId: String?,
        val cursor: String?,
        val limit: Int,
    )

    data class CreateCall(val parentDocumentId: String?, val mimeType: String, val displayName: String)

    init {
        val rootRef = SafDocumentRef(
            tree = tree,
            documentId = rootDocumentId,
            parentDocumentId = null,
            uri = SafUriRef("$treeUri/document/$rootDocumentId"),
        )
        register(
            SafDocument(
                ref = rootRef,
                displayName = "SpaceFiles",
                mimeType = SafDocument.MIME_DIR,
                size = SafSize.Unknown,
                lastModifiedMillis = null,
                capabilities = caps(write = true, createChildren = true),
            ),
        )
    }

    // ---- fixtures -------------------------------------------------------

    fun addDirectory(
        documentId: String,
        name: String,
        parentDocumentId: String? = rootDocumentId,
        write: Boolean = true,
        delete: Boolean = true,
        rename: Boolean = true,
        createChildren: Boolean = true,
        copy: Boolean = false,
        move: Boolean = false,
    ): SafDocument = register(
        SafDocument(
            ref = ref(documentId, parentDocumentId),
            displayName = name,
            mimeType = SafDocument.MIME_DIR,
            size = SafSize.Unknown,
            lastModifiedMillis = null,
            capabilities = caps(
                write = write,
                delete = delete,
                rename = rename,
                createChildren = createChildren,
                copy = copy,
                move = move,
            ),
        ),
    ).also { documentNames[documentId] = name }

    fun addFile(
        documentId: String,
        name: String,
        bytes: ByteArray = ByteArray(0),
        mimeType: String = "text/plain",
        parentDocumentId: String? = rootDocumentId,
        size: SafSize? = null,
        write: Boolean = true,
        delete: Boolean = true,
        rename: Boolean = true,
        copy: Boolean = false,
        move: Boolean = false,
        virtual: Boolean = false,
    ): SafDocument {
        content[uriFor(documentId)] = bytes
        return register(
            SafDocument(
                ref = ref(documentId, parentDocumentId),
                displayName = name,
                mimeType = mimeType,
                size = size ?: SafSize.Known(bytes.size.toLong()),
                lastModifiedMillis = null,
                capabilities = caps(
                    write = write,
                    delete = delete,
                    rename = rename,
                    copy = copy,
                    move = move,
                    virtual = virtual,
                ),
            ),
        ).also { documentNames[documentId] = name }
    }

    fun addPersisted(flags: Set<SafAccessFlag> = setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)) {
        persisted[treeUri] = flags.toMutableSet()
    }

    fun document(documentId: String): SafDocument? = documentsByUri[uriFor(documentId)]

    /** URI + decoded content of the (single) document with this display name. */
    fun contentByDisplayName(name: String): Pair<String, String>? =
        documentsByUri.values.firstOrNull { it.displayName == name }
            ?.let { doc ->
                val bytes = content[doc.ref.uri.uriString] ?: return null
                doc.ref.uri.uriString to String(bytes, Charsets.UTF_8)
            }

    private fun uriFor(documentId: String) = "$treeUri/document/$documentId"

    private fun ref(documentId: String, parentDocumentId: String?): SafDocumentRef =
        SafDocumentRef(
            tree = tree,
            documentId = documentId,
            parentDocumentId = parentDocumentId,
            uri = SafUriRef(uriFor(documentId)),
        )

    private fun caps(
        write: Boolean = false,
        delete: Boolean = false,
        rename: Boolean = false,
        createChildren: Boolean = false,
        copy: Boolean = false,
        move: Boolean = false,
        virtual: Boolean = false,
    ): SafCapabilities = SafCapabilities(
        write = write,
        delete = delete,
        rename = rename,
        copy = copy,
        move = move,
        createChildren = createChildren,
        removeFromParent = false,
        blocksOpenDocumentTree = false,
        virtual = virtual,
        rawFlags = (if (write) SafProviderFlagBits.SUPPORTS_WRITE else 0) or
            (if (delete) SafProviderFlagBits.SUPPORTS_DELETE else 0) or
            (if (rename) SafProviderFlagBits.SUPPORTS_RENAME else 0) or
            (if (createChildren) SafProviderFlagBits.DIR_SUPPORTS_CREATE else 0) or
            (if (copy) SafProviderFlagBits.SUPPORTS_COPY else 0) or
            (if (move) SafProviderFlagBits.SUPPORTS_MOVE else 0) or
            (if (virtual) SafProviderFlagBits.VIRTUAL_DOCUMENT else 0),
    )

    private fun register(document: SafDocument): SafDocument {
        documentsByUri[document.ref.uri.uriString] = document
        val isRoot = document.ref.documentId == rootDocumentId && document.ref.parentDocumentId == null
        if (isRoot) return document
        val parent = document.ref.parentDocumentId ?: rootDocumentId
        children.getOrPut(parent) { CopyOnWriteArrayList() }.add(document)
        return document
    }

    // ---- SafPlatformBackend --------------------------------------------

    override fun classifyUri(uriString: String): SafUriKind = when {
        uriString.startsWith(treeUri) && uriString.contains("/document/") -> SafUriKind.DOCUMENT
        uriString == treeUri -> SafUriKind.TREE
        else -> SafUriKind.NON_SAF
    }

    override fun persistedGrants(): List<GrantSnapshot> = persisted.map { (uri, flags) ->
        GrantSnapshot(SafUriRef(uri), SafAccessFlag.READ in flags, SafAccessFlag.WRITE in flags)
    }

    override fun takePersistable(uri: SafUriRef, flag: SafAccessFlag): TakeOutcome {
        takeCalls += flag.name
        if (!persistableOffered) return TakeOutcome.TransientOnly("provider-refused-persist")
        val flags = persisted.getOrPut(uri.uriString) { mutableSetOf() }
        val already = flag in flags
        flags += flag
        return if (already) TakeOutcome.AlreadyHeld else TakeOutcome.Persisted
    }

    override fun releasePersistable(uri: SafUriRef, flag: SafAccessFlag): Boolean {
        releaseCalls.incrementAndGet()
        persisted[uri.uriString]?.let { flags ->
            flags -= flag
            if (flags.isEmpty()) persisted.remove(uri.uriString)
        }
        return true
    }

    override fun resolveTreeRoot(tree: SafUriRef): SafDocumentRef? = SafDocumentRef(
        tree = tree,
        documentId = rootDocumentId,
        parentDocumentId = null,
        uri = SafUriRef(uriFor(rootDocumentId)),
    )

    override fun documentUriFor(tree: SafUriRef, documentId: String): SafUriRef =
        SafUriRef("${tree.uriString}/document/$documentId")

    override fun documentIdOf(uri: SafUriRef): String? =
        uri.uriString.substringAfterLast("/document/", "").takeIf { it.isNotEmpty() }

    override fun probeAccess(uri: SafUriRef, needsRead: Boolean, needsWrite: Boolean): AccessProbe =
        if (probeGranted) {
            AccessProbe(
                read = if (needsRead) ProbeFlag.GRANTED else ProbeFlag.UNKNOWN,
                write = writeProbe(needsWrite),
            )
        } else {
            AccessProbe(
                read = if (needsRead) ProbeFlag.DENIED else ProbeFlag.UNKNOWN,
                write = if (needsWrite) ProbeFlag.DENIED else ProbeFlag.UNKNOWN,
            )
        }

    private fun writeProbe(needsWrite: Boolean): ProbeFlag = when {
        !needsWrite -> ProbeFlag.UNKNOWN
        probeGranted && probeWriteGranted -> ProbeFlag.GRANTED
        else -> ProbeFlag.DENIED
    }

    override fun queryChildDocuments(
        tree: SafUriRef,
        parentDocumentId: String?,
        limit: Int,
        cursorToken: String?,
        cancel: SafCancelToken,
    ): ChildScan {
        listingCalls += ListingCall(tree.uriString, parentDocumentId, cursorToken, limit)
        scanEntered?.countDown()
        if (blockScansUntilCancelled) {
            while (!cancel.isCancelled) Thread.sleep(2)
            cancelObserved.set(true)
            throw SafCancelledException()
        }
        faultOnChildScan?.let { throw it }
        val parent = parentDocumentId ?: rootDocumentId
        val all = children[parent]?.toList().orEmpty()
        val from = cursorToken?.removePrefix("cursor-")?.toIntOrNull() ?: 0
        val page = all.drop(from).take(limit)
        val next = from + page.size
        val more = next < all.size
        return ChildScan(
            documents = page,
            nextCursorToken = if (more) "cursor-$next" else null,
            truncatedByLimit = more,
            note = null,
        )
    }

    override fun releaseCursor(cursorToken: String): Boolean = cursorToken.startsWith("cursor-")

    override fun releaseAllCursors() = Unit

    override fun queryDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafDocument? =
        documentsByUri[ref.uri.uriString]

    override fun isChildOf(child: SafDocumentRef, ancestorTree: SafUriRef, cancel: SafCancelToken): Boolean =
        child.uri.uriString.startsWith(ancestorTree.uriString)

    override fun openRead(ref: SafDocumentRef, mimeFilter: String?, cancel: SafCancelToken): ReadOpen {
        openReadCalls.incrementAndGet()
        val bytes = content[ref.uri.uriString] ?: return ReadOpen.NotFound
        return ReadOpen.Opened(ByteArrayInputStream(bytes), bytes.size.toLong())
    }

    override fun openWriteTruncate(ref: SafDocumentRef, cancel: SafCancelToken): WriteOpen {
        if (ref.uri.uriString in truncateUnsupportedUris) return WriteOpen.UnsupportedMode
        // The real DocumentsProvider contract: the bytes that flush through
        // the returned stream ARE the document's new content on close.
        return WriteOpen.Opened(object : java.io.OutputStream() {
            private val sink = java.io.ByteArrayOutputStream()

            override fun write(b: Int) {
                sink.write(b)
            }

            override fun write(b: ByteArray, off: Int, len: Int) {
                sink.write(b, off, len)
            }

            override fun close() {
                super.close()
                val bytes = sink.toByteArray()
                content[ref.uri.uriString] = bytes
                val existing = documentsByUri[ref.uri.uriString] ?: return
                val updated = existing.copy(size = SafSize.Known(bytes.size.toLong()))
                documentsByUri[ref.uri.uriString] = updated
                val parent = existing.ref.parentDocumentId ?: rootDocumentId
                children[parent]?.let { siblings ->
                    val index = siblings.indexOfFirst { it.ref.uri == ref.uri }
                    if (index >= 0) siblings[index] = updated
                }
            }
        })
    }

    override fun streamTypes(ref: SafDocumentRef): List<String> = emptyList()

    override fun createDocument(
        tree: SafUriRef,
        parentDocumentId: String?,
        mimeType: String,
        displayName: String,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        createCalls += CreateCall(parentDocumentId, mimeType, displayName)
        val parent = parentDocumentId ?: rootDocumentId
        val id = "created-${createdSeq.incrementAndGet()}"
        val created = SafDocument(
            ref = ref(id, parent),
            displayName = displayName,
            mimeType = mimeType,
            size = if (mimeType == SafDocument.MIME_DIR) SafSize.Unknown else SafSize.Known(0),
            lastModifiedMillis = null,
            capabilities = caps(
                write = true,
                delete = true,
                rename = true,
                createChildren = mimeType == SafDocument.MIME_DIR,
            ),
        )
        register(created)
        documentNames[id] = displayName
        if (mimeType != SafDocument.MIME_DIR) content[uriFor(id)] = ByteArray(0)
        return OpResult.Ok(created.ref)
    }

    override fun renameDocument(
        ref: SafDocumentRef,
        newName: String,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        renameCalls += ref.uri.uriString to newName
        val existing = documentsByUri[ref.uri.uriString]
            ?: return OpResult.NullReturned("unknown document")
        val renamed = existing.copy(displayName = newName)
        documentsByUri[ref.uri.uriString] = renamed
        val siblings = children[existing.ref.parentDocumentId ?: rootDocumentId]
        val index = siblings?.indexOfFirst { it.ref.uri == ref.uri } ?: -1
        if (siblings != null && index >= 0) siblings[index] = renamed
        documentNames[existing.ref.documentId ?: ""] = newName
        return OpResult.Ok(renamed.ref)
    }

    override fun moveDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        moveCalls += ref.uri.uriString
        if (!nativeMoveSupported) return OpResult.NullReturned("provider refused native move")
        val existing = documentsByUri[ref.uri.uriString] ?: return OpResult.NullReturned("unknown document")
        val destParent = destParentDocumentId ?: rootDocumentId
        children[existing.ref.parentDocumentId ?: rootDocumentId]?.removeAll { it.ref.uri == ref.uri }
        val moved = existing.copy(ref = existing.ref.copy(parentDocumentId = destParent))
        children.getOrPut(destParent) { CopyOnWriteArrayList() }.add(moved)
        documentsByUri[moved.ref.uri.uriString] = moved
        return OpResult.Ok(moved.ref)
    }

    override fun copyDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): OpResult<SafDocumentRef> {
        copyCalls += ref.uri.uriString
        val source = documentsByUri[ref.uri.uriString] ?: return OpResult.NullReturned("unknown document")
        val parent = destParentDocumentId ?: rootDocumentId
        val id = "copy-${createdSeq.incrementAndGet()}"
        val copied = source.copy(ref = ref(id, parent))
        register(copied)
        content[uriFor(id)] = content[ref.uri.uriString] ?: ByteArray(0)
        return OpResult.Ok(copied.ref)
    }

    override fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): OpResult<Boolean> {
        deleteCalls += ref.uri.uriString
        val existing = documentsByUri[ref.uri.uriString] ?: return OpResult.Ok(true)
        children[existing.ref.parentDocumentId ?: rootDocumentId]?.removeAll { it.ref.uri == ref.uri }
        documentsByUri.remove(ref.uri.uriString)
        content.remove(ref.uri.uriString)
        return OpResult.Ok(true)
    }

    override fun selfCheck(): List<String> = emptyList()
}

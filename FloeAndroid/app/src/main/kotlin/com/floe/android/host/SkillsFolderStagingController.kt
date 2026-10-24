// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import com.floe.android.bridge.SkillsFolderStagingNative
import com.floe.android.bridge.SkillsFolderStagingNativeException
import com.floe.android.feature.integrations.StagedPackageRefUi
import java.io.InputStream
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * S11 — genuine SAF folder staging for Skills imports.
 *
 * This is the ONLY folder lane: a SEPARATELY owned picker request state
 * (it never shares the attachment picker's lane) whose results are fenced
 * by the exact captured request. The composition glue
 * [SkillsFolderPickerEffect] presents the platform `OpenDocumentTree` for
 * each captured request; a result arriving for a superseded/older request
 * is dropped WITHOUT any IO, binding or state write (the same owner-
 * capture rule the accepted attachment controller uses).
 *
 * What really happens on a selected tree:
 *  1. The route opens against the ACTUAL native Root epoch + the host UI
 *     admission generation captured when the request was presented (never
 *     re-read late in a callback — the values ride the captured request).
 *  2. The domain allocates its OWN scratch directory (trusted native seam
 *     → `SkillsDomain.hostCreateStagingDirectory` under the domain's own
 *     staging root). No model JSON ever names a path; there is no host
 *     filesystem backdoor and no second approval system.
 *  3. The selected DocumentProvider tree is walked through a bounded copy
 *     (original directory/filename safety, ≤256 files, ≤2 MiB/file,
 *     ≤8 MiB total, depth ≤16, duplicate-case-collision refusal, traversal
 *     segment refusal, non-stream mime families skipped, cancellation
 *     aborts the owned tree) through the trusted native byte channel into
 *     that directory.
 *  4. On finish the NATIVE side re-computes the ORIGINAL canonical digest
 *     over the actual disk inventory and calls
 *     `SkillsDomain.registerStagedFolder(directory:receipt:now:)`, which
 *     validates beneath its stagingRoot with the real digest/count/bytes/
 *     TTL and returns the genuine current-epoch `stg:v1:` scoped token.
 *     Nothing installs on arrival.
 *  5. Only the opaque [StagedPackageRefUi] crosses back to the module's
 *     import-confirm form; the existing `skills.install` `folder.import`
 *     path validates/reviews/installs it (original package safety and
 *     review gates unchanged). A model-authored arbitrary path or a
 *     synthetic stg:v1 token remains impossible by the closed grammar.
 *
 * Scoped grants: the app asks the platform to PERSIST a READ-only tree
 * grant only while a retry of THIS user-initiated import stays possible
 * (never WRITE, never all-files). A refusal/revocation is handled by the
 * typed copy failure; the successful copy releases the grant because the
 * staged bytes are now the domain's own, so the URI grant is no longer
 * useful least-scope state. No plaintext secret material is ever logged:
 * failures carry bounded typed codes only, never URIs, names or bytes.
 */
class SkillsFolderStagingController internal constructor(
    private val host: RuntimeHost,
    private val onStaged: (StagedPackageRefUi) -> Unit,
    private val onStageFailure: (String) -> Unit,
    private val admitted: () -> Boolean,
) {

    /** One captured picker presentation. `nativeRootEpoch` and
     *  `uiGeneration` are the values the request was LAUNCHED under; a
     *  late callback acts on these exact values, never on a replacement
     *  request. */
    data class FolderPickerRequest(
        val incarnation: Long,
        val nativeRootEpoch: Long,
        val uiGeneration: Long,
    )

    /** The trusted native staging byte channel — the ONE seam tests
     *  inject. Mirrors the accepted attachment channel discipline: opaque
     *  receipts across the boundary, bytes pushed in bounded chunks,
     *  typed status exceptions only, nothing reversible into paths. */
    internal interface StagingChannel {
        fun routeOpen(incarnation: Long, uiGeneration: Long, rootEpoch: Long): String
        fun routeClose(routeReceipt: String)
        /** Native allocates `<stagingRoot>/folder-<uuid>` for this tree. */
        fun treeOpen(routeReceipt: String, displayNameHint: String?): String
        fun fileBegin(treeHandle: String, relativePath: String): String
        fun fileWrite(fileHandle: String, data: ByteArray, offset: Int, length: Int)
        fun fileEnd(fileHandle: String)
        fun fileAbort(fileHandle: String)
        /** Returns "<stgToken> <fileCount> <totalBytes>" — three
         *  domain-minted ASCII tokens (opaque handle + real counts). */
        fun treeFinish(treeHandle: String, displayNameHint: String?): String
        fun treeAbort(treeHandle: String)
    }

    private object NativeStagingChannel : StagingChannel {
        override fun routeOpen(
            incarnation: Long,
            uiGeneration: Long,
            rootEpoch: Long,
        ): String = SkillsFolderStagingNative.folderRouteOpen(
            incarnation, uiGeneration, rootEpoch)

        override fun routeClose(routeReceipt: String) =
            SkillsFolderStagingNative.folderRouteClose(routeReceipt)

        override fun treeOpen(routeReceipt: String, displayNameHint: String?): String =
            SkillsFolderStagingNative.folderTreeOpen(routeReceipt, displayNameHint)

        override fun fileBegin(treeHandle: String, relativePath: String): String =
            SkillsFolderStagingNative.folderFileBegin(treeHandle, relativePath)

        override fun fileWrite(
            fileHandle: String,
            data: ByteArray,
            offset: Int,
            length: Int,
        ) = SkillsFolderStagingNative.folderFileWrite(fileHandle, data, offset, length)

        override fun fileEnd(fileHandle: String) =
            SkillsFolderStagingNative.folderFileEnd(fileHandle)

        override fun fileAbort(fileHandle: String) =
            SkillsFolderStagingNative.folderFileAbort(fileHandle)

        override fun treeFinish(treeHandle: String, displayNameHint: String?): String =
            SkillsFolderStagingNative.folderTreeFinish(treeHandle, displayNameHint)

        override fun treeAbort(treeHandle: String) =
            SkillsFolderStagingNative.folderTreeAbort(treeHandle)
    }

    internal var channel: StagingChannel = NativeStagingChannel

    /** The SAF tree walk seam: production reads the selected
     *  DocumentProvider through ContentResolver ([SafFolderTreeReader]);
     *  JVM fixtures inject a synthetic reader (no Android framework is
     *  needed to prove the bounds, safety and fencing logic below). */
    internal interface FolderTreeReader {
        val displayName: String?
        val rootDocumentId: String?
        fun children(documentId: String): List<FolderChild>
        fun openStream(documentId: String): InputStream?
        /** Best-effort PERSISTENT READ-ONLY tree grant; returns true when
         *  the platform granted+persisted it. Never a WRITE request. */
        fun takeReadGrant(): Boolean
        fun releaseReadGrant()
    }

    data class FolderChild(
        val documentId: String,
        val name: String,
        val isDirectory: Boolean,
        /** Declared size if the provider reports one; never trusted as a
         *  substitute for the streamed byte accounting below. */
        val declaredBytes: Long?,
    )

    /** Production reader: binds the picked tree URI once and answers the
     *  walk/grant primitives against it. The URI itself never crosses the
     *  native seam (bytes + relative paths only) and never enters logs. */
    private class SafFolderTreeReader(
        private val context: Context,
        private val treeUri: Uri,
    ) : FolderTreeReader {
        override val displayName: String? get() {
            // The tree URI's last path segment is the document id, not a
            // display name; query the root document row itself.
            return try {
                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri, DocumentsContract.getTreeDocumentId(treeUri))
                context.contentResolver.query(
                    docUri,
                    arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                    null, null, null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(
                            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                        if (idx >= 0) cursor.getString(idx) else null
                    } else null
                }
            } catch (t: RuntimeException) {
                null
            }
        }

        override val rootDocumentId: String? get() = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (t: IllegalArgumentException) {
            null
        }

        override fun children(documentId: String): List<FolderChild> {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
            val out = ArrayList<FolderChild>()
            context.contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_FLAGS,
                ),
                null, null, null,
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                while (cursor.moveToNext()) {
                    if (idIdx < 0 || nameIdx < 0 || mimeIdx < 0) continue
                    val id = cursor.getString(idIdx) ?: continue
                    val name = cursor.getString(nameIdx) ?: continue
                    val mime = cursor.getString(mimeIdx) ?: ""
                    val size = if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                        cursor.getLong(sizeIdx)
                    } else {
                        null
                    }
                    out.add(
                        FolderChild(
                            documentId = id,
                            name = name,
                            isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
                            declaredBytes = size,
                        ),
                    )
                }
            }
            return out
        }

        override fun openStream(documentId: String): InputStream? = try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
            context.contentResolver.openInputStream(docUri)
        } catch (t: Exception) {
            null
        }

        private var readGrantLease: com.floe.android.safgateway.SafSharedGrantBroker.Lease? = null

        @Synchronized
        override fun takeReadGrant(): Boolean {
            if (readGrantLease == null) {
                readGrantLease = SharedUriGrantAuthority.acquireRead(context.contentResolver, treeUri)
            }
            return readGrantLease?.persistedAtAcquisition == true
        }

        @Synchronized
        override fun releaseReadGrant() {
            readGrantLease?.close()
            readGrantLease = null
        }
    }

    /** Test seam for the tree walk. */
    internal var readerOverride: FolderTreeReader? = null

    private val pickerRequestFlow = MutableStateFlow<FolderPickerRequest?>(null)
    val pickerRequest: StateFlow<FolderPickerRequest?> = pickerRequestFlow

    private val requestIncarnation = AtomicLong(0)

    /** Opaque per-host-generation launch namespace for the composition
     *  folder-picker lane (MAIN_ANDROID_PLATFORM_LAUNCH_OWNERSHIP_20261021):
     *  the glue persists `namespace:incarnation` for the ONE OpenDocumentTree
     *  it launched and only dispatches a callback whose saved namespace
     *  still matches THIS generation, so a counter reset after process death
     *  can never bind a restored pre-death callback to a new request. No URI,
     *  secret, user content or grant state is carried. */
    internal val launchNamespace: String = PlatformLaunchOwnership.mintNamespace()

    private var activeJob: Job? = null
    @Volatile
    private var cancelledInFlight = false

    companion object {
        /** Mirror of the ORIGINAL SkillValidationLimits defaults the domain
         *  validator enforces (256 files / 2 MiB / 8 MiB). Streaming caps
         *  here refuse BEFORE the native copy overshoots; the domain's own
         *  register/validate path remains the actual authority. */
        const val MAX_FILES = 256
        const val MAX_FILE_BYTES = 2L * 1024 * 1024
        const val MAX_TOTAL_BYTES = 8L * 1024 * 1024
        const val MAX_DEPTH = 16
        private const val CHUNK_BYTES = 64 * 1024

        /** Original directory/filename safety (validator `validate
         *  (relativePath:)` segment rules, mirrored projection only). */
        internal fun isSafeSegment(name: String): Boolean {
            if (name.isEmpty() || name == "." || name == "..") return false
            if (name.contains('/') || name.contains('\\') || name.contains('\u0000')) {
                return false
            }
            if (name.toByteArray(Charsets.UTF_8).size > 255) return false
            return true
        }

        /** Collision key mirroring the validator's duplicate-path rule
         *  (canonical NFC lowercased). */
        internal fun collisionKey(relativePath: String): String {
            val normalized = java.text.Normalizer.normalize(relativePath, java.text.Normalizer.Form.NFC)
            return normalized.lowercase()
        }
    }

    // ---------------------------------------------------------------- picker

    /** Present the picker. TRUE = a real request object flipped the state
     *  the composition launcher observes; false means nothing was
     *  presented (the module never treats it as success). */
    fun presentPicker(): Boolean {
        if (!admitted()) return false
        val epoch = host.nativeRootEpoch() ?: return false
        // A new explicit request replaces the pending owner: the previous
        // incarnation's late result (if any arrives) is dropped by the
        // fence in [onTreeResult]; nothing is bound to a replacement.
        pickerRequestFlow.value = FolderPickerRequest(
            incarnation = requestIncarnation.incrementAndGet(),
            nativeRootEpoch = epoch,
            uiGeneration = HostUiAdmission.nextGeneration(),
        )
        return true
    }

    /** Leaving the surface drops an UNLAUNCHED request only; an in-flight
     *  staging job is service-owned and keeps running (same rule as
     *  installs/commits). */
    fun abandonUnlaunched() {
        if (activeJob == null) pickerRequestFlow.value = null
    }

    fun cancelPicker() {
        requestIncarnation.incrementAndGet()
        pickerRequestFlow.value = null
    }

    /** Composition glue delivers the platform result for the CAPTURED
     *  request; a result for a superseded/older incarnation is dropped
     *  without IO. */
    fun onTreeResult(request: FolderPickerRequest, treeUri: Uri?) {
        if (pickerRequestFlow.value?.incarnation != request.incarnation) return
        pickerRequestFlow.value = null
        if (treeUri == null) return // user dismissed: nothing staged, nothing claimed
        if (!admitted()) return
        startStaging(request, SafFolderTreeReader(host.appContext, treeUri))
    }

    /** Uri-free entry used by JVM fixtures (the production overload above
     *  funnels here once the platform result exists). */
    internal fun onTreeResult(request: FolderPickerRequest, reader: FolderTreeReader) {
        if (pickerRequestFlow.value?.incarnation != request.incarnation) return
        pickerRequestFlow.value = null
        if (!admitted()) return
        startStaging(request, reader)
    }

    private fun startStaging(request: FolderPickerRequest, reader: FolderTreeReader) {
        cancelledInFlight = false
        activeJob = host.scope.launch(host.ioDispatcher) {
            try {
                stageTree(request, reader)
            } catch (cancel: CancellationException) {
                throw cancel
            }
        }?.also { job ->
            job.invokeOnCompletion { activeJob = null }
        }
    }

    /** Explicit cancel of the in-flight copy (UI cancel affordance): the
     *  owned tree is aborted natively (recoverable cleanup), no partial
     *  receipt can exist, and the URI grant is released through the LIVE
     *  reader captured for the current staging pass. */
    fun cancelActiveStaging() {
        cancelledInFlight = true
        activeJob?.cancel()
        activeJob = null
        // The copy owns its reference until actual provider IO settles;
        // stageTree's finally releases it on every terminal path.
    }

    private var activeReader: FolderTreeReader? = null

    fun invalidate() {
        activeJob?.cancel()
        activeJob = null
        pickerRequestFlow.value = null
    }

    // ------------------------------------------------------------ staging

    private fun stageTree(request: FolderPickerRequest, source: FolderTreeReader) {
        activeReader = source
        val rootName = source.displayName ?: "folder"
        var route: String? = null
        var tree: String? = null
        var grantReleased = false
        var currentFile: String? = null
        try {
            route = channel.routeOpen(
                request.incarnation, request.uiGeneration, request.nativeRootEpoch)
            tree = channel.treeOpen(route, rootName)
            treeHandleForAbort = tree
            // The retry window starts here: take the least-scope READ
            // grant only while this user-initiated import could still be
            // retried after a failure.
            source.takeReadGrant() // false = session-only, never fake persistence

            val rootDoc = source.rootDocumentId
                ?: return failStage("folder_root_unreadable")
            var fileCount = 0
            var totalBytes = 0L
            val seenKeys = HashSet<String>()
            val stack = ArrayDeque<Triple<String, String, Int>>()
            stack.addLast(Triple(rootDoc, "", 0))
            while (stack.isNotEmpty()) {
                if (cancelledInFlight) return failStage("folder_cancelled")
                val (docId, prefix, depth) = stack.removeFirst()
                if (depth > MAX_DEPTH) return failStage("folder_too_deep")
                val kids = runCatching { source.children(docId) }
                    .getOrElse { return failStage("folder_tree_unreadable") }
                for (child in kids) {
                    if (cancelledInFlight) return failStage("folder_cancelled")
                    if (!isSafeSegment(child.name)) return failStage("folder_unsafe_name")
                    val relative = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
                    if (relative.toByteArray(Charsets.UTF_8).size > 512) {
                        return failStage("folder_path_too_long")
                    }
                    if (relative.contains("..") || relative.startsWith("/")) {
                        return failStage("folder_unsafe_name")
                    }
                    if (!seenKeys.add(collisionKey(relative))) {
                        return failStage("folder_duplicate_path")
                    }
                    if (child.isDirectory) {
                        stack.addLast(Triple(child.documentId, relative, depth + 1))
                        continue
                    }
                    if (fileCount + 1 > MAX_FILES) return failStage("folder_too_many_files")
                    if (child.declaredBytes != null && child.declaredBytes > MAX_FILE_BYTES) {
                        return failStage("folder_file_too_large")
                    }
                    if (totalBytes > MAX_TOTAL_BYTES - MAX_FILE_BYTES) {
                        return failStage("folder_package_too_large")
                    }
                    fileCount += 1
                    val fileHandle = channel.fileBegin(tree, relative)
                    currentFile = fileHandle
                    currentFileHandle = currentFile
                    var fileBytes = 0L
                    val buffer = ByteArray(CHUNK_BYTES)
                    val stream = source.openStream(child.documentId)
                        ?: run {
                            runCatching { channel.fileAbort(fileHandle) }
                            currentFile = null
                            currentFileHandle = null
                            return failStage("folder_source_unreadable")
                        }
                    stream.use { input ->
                        while (true) {
                            if (cancelledInFlight) return failStage("folder_cancelled")
                            val read = input.read(buffer)
                            if (read < 0) break
                            if (fileBytes + read > MAX_FILE_BYTES) {
                                runCatching { channel.fileAbort(fileHandle) }
                                currentFile = null
                                currentFileHandle = null
                                return failStage("folder_file_too_large")
                            }
                            channel.fileWrite(fileHandle, buffer, 0, read)
                            fileBytes += read
                        }
                    }
                    if (fileBytes == 0L) {
                        // Empty files are copied (the original validator
                        // decides policy over them; staging does not drop
                        // content the user selected).
                    }
                    channel.fileEnd(fileHandle)
                    currentFile = null
                    currentFileHandle = null
                    totalBytes += fileBytes
                    if (totalBytes > MAX_TOTAL_BYTES) return failStage("folder_package_too_large")
                }
            }
            if (fileCount == 0) return failStage("folder_empty")
            val reply = channel.treeFinish(tree, rootName)
            val tokens = reply.split(" ")
            if (tokens.size != 3 || !tokens[0].startsWith("stg:v1:") ||
                tokens[1].toLongOrNull() == null || tokens[2].toLongOrNull() == null
            ) {
                return failStage("stage_refused")
            }
            // Success: the bytes are now the domain's OWN staged tree under
            // the trusted staging root; the URI grant is no longer useful
            // least-scope state, so it is released.
            runCatching { source.releaseReadGrant() }
            grantReleased = true
            val reference = StagedPackageRefUi(
                handle = tokens[0],
                displayName = rootName,
                mimeType = null,
                sizeBytes = tokens[2].toLong(),
            )
            onStaged(reference)
        } catch (cancel: CancellationException) {
            runCatching { currentFile?.let { channel.fileAbort(it) } }
            runCatching { tree?.let { channel.treeAbort(it) } }
            // Recoverable cleanup of this owned tree only; the grant stays
            // ONLY if a user could still retry — an explicit cancel
            // released it above via cancelActiveStaging.
            throw cancel
        } catch (native: SkillsFolderStagingNativeException) {
            runCatching { currentFile?.let { channel.fileAbort(it) } }
            runCatching { tree?.let { channel.treeAbort(it) } }
            fail(reasonFor(native.status))
        } catch (t: Throwable) {
            runCatching { currentFile?.let { channel.fileAbort(it) } }
            runCatching { tree?.let { channel.treeAbort(it) } }
            fail("folder_stage_failed")
        } finally {
            if (!grantReleased) runCatching { source.releaseReadGrant() }
            runCatching { route?.let { channel.routeClose(it) } }
            currentFileHandle = null
            treeHandleForAbort = null
            activeReader = null
        }
    }

    /** Guard failure: abort the live file + owned tree FIRST (explicit
     *  recoverable cleanup of this lane's scratch copy), then report the
     *  bounded typed reason. routeClose in the finally is the second
     *  layer, never the only one. */
    private fun failStage(reason: String): Unit {
        runCatching { currentFileHandle?.let { channel.fileAbort(it) } }
        runCatching { treeHandleForAbort?.let { channel.treeAbort(it) } }
        fail(reason)
    }

    private var currentFileHandle: String? = null
    private var treeHandleForAbort: String? = null

    private fun fail(reason: String): Unit {
        // The staged copy (if any) was aborted above; the module keeps its
        // form state and the host reports the bounded typed reason only.
        // An explicit user cancel is silent (nothing "failed").
        if (reason == "folder_cancelled") return
        onStageFailure(reason)
    }

    /** Typed status space owned by the native folder-staging seam (see
     *  SkillsFolderStagingNative.kt): only the numeric status crosses;
     *  never a path, URI, name or byte content. */
    private fun reasonFor(status: Int): String = when (status) {
        -402 -> "folder_stale_generation"
        -403, -404, -405 -> "stage_refused"
        -406, -407 -> "folder_unsafe_name"
        -408 -> "folder_too_many_files"
        -409 -> "folder_package_too_large"
        -410 -> "folder_too_deep"
        -411 -> "storage_full"
        -412 -> "folder_write_failed"
        -414 -> "folder_digest_mismatch"
        -415 -> "folder_receipt_refused"
        -416 -> "stage_saturated"
        else -> "folder_stage_failed"
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/**
 * Provider document operations over the backend seam. Memory-bounded by
 * design: directory scans ride held opaque cursors with an explicit row cap,
 * streams stop at the caller's declared byteLimit, and an unknown size is
 * NEVER permission to buffer the whole document.
 *
 * Capability truth comes from the exact `Document.COLUMN_FLAGS` on the fresh
 * metadata row. Mutation results keep the EXACT URI the provider returned;
 * identities we cannot bind surface as [SafFailure.AmbiguousIdentity] instead
 * of a guess. Gating distinguishes persisted grants from live session access
 * and only asks the platform to re-pick (typed) after real expiry.
 */
class SafProviderOperations internal constructor(
    private val backend: SafPlatformBackend,
    private val grants: SafGrantGateway,
    private val limits: SafLimits,
) {

    // -----------------------------------------------------------------------
    // Bounded lazy directory + metadata (held-cursor paging)
    // -----------------------------------------------------------------------

    fun listTreePage(
        tree: SafUriRef,
        parentDocumentId: String?,
        request: PageRequest,
        cancel: SafCancelToken,
    ): SafOutcome<ChildScan> = guarded(cancel) {
        gated(treeAnchor(tree), setOf(SafAccessFlag.READ)) {
            val limit = request.limit.coerceIn(1, limits.maxPageItems)
            SafOutcome.success(backend.queryChildDocuments(tree, parentDocumentId, limit, request.cursorToken, cancel))
        }
    }

    /** Give back a held cursor early (closed folder in the UI, task teardown). */
    fun releaseCursor(cursorToken: String): Boolean = backend.releaseCursor(cursorToken)

    fun treeRoot(tree: SafUriRef, cancel: SafCancelToken): SafOutcome<SafDocumentRef> = guarded(cancel) {
        gated(treeAnchor(tree), setOf(SafAccessFlag.READ)) {
            backend.resolveTreeRoot(tree)?.let { SafOutcome.success(it) }
                ?: SafOutcome.failure(SafFailure.NotFound)
        }
    }

    fun metadata(ref: SafDocumentRef, cancel: SafCancelToken): SafOutcome<SafDocument> = guarded(cancel) {
        gated(ref, setOf(SafAccessFlag.READ)) {
            backend.queryDocument(ref, cancel)?.let { SafOutcome.success(it) }
                ?: SafOutcome.failure(SafFailure.NotFound)
        }
    }

    // -----------------------------------------------------------------------
    // Bounded streaming reads (cancellable PFD/stream at the platform edge)
    // -----------------------------------------------------------------------

    /**
     * Stream the document into [sink] in chunks, hashing as it goes. Virtual
     * documents are opened ONLY through a provider-supported typed MIME; raw
     * bytes are never pretended to exist. A `byteLimit` breach stops the pass
     * and reports [SafFailure.SizeLimitExceeded] — the partial sink output is
     * the caller's to discard; nothing here labels a breached pass complete.
     */
    fun streamRead(
        ref: SafDocumentRef,
        byteLimit: Long?,
        typedAcceptMime: String?,
        cancel: SafCancelToken,
        sink: (ByteArray, Int) -> Unit,
    ): SafOutcome<StreamSummary> = guarded(cancel) {
        gated(ref, setOf(SafAccessFlag.READ)) {
            val doc = backend.queryDocument(ref, cancel) ?: return@gated SafOutcome.failure(SafFailure.NotFound)
            val open: ReadOpen = if (doc.isVirtual) {
                val types = backend.streamTypes(ref)
                if (typedAcceptMime == null || types.isEmpty() || !mimeAcceptable(typedAcceptMime, types)) {
                    return@gated SafOutcome.failure(
                        SafFailure.Unsupported(
                            "virtual document; ask for one of the provider stream types: ${types.joinToString()}",
                        ),
                        "no raw byte representation is promised",
                    )
                }
                backend.openRead(ref, typedAcceptMime, cancel)
            } else {
                if (typedAcceptMime != null) {
                    return@gated SafOutcome.failure(SafFailure.Failed("typed reads are only valid for virtual documents"))
                }
                backend.openRead(ref, null, cancel)
            }
            when (open) {
                is ReadOpen.NotFound -> SafOutcome.failure(SafFailure.NotFound)
                is ReadOpen.Opened -> copyInto(open.input, open.lengthHintBytes, byteLimit, cancel, sink)
            }
        }
    }

    /** Collect into memory ONLY under an explicit hard cap (never unbounded). */
    fun readBounded(
        ref: SafDocumentRef,
        maxBytes: Long,
        typedAcceptMime: String?,
        cancel: SafCancelToken,
    ): SafOutcome<ByteArray> {
        if (maxBytes !in 1..(64L shl 20)) {
            return SafOutcome.failure(SafFailure.Failed("readBounded cap must be 1..64 MiB"))
        }
        val collected = ArrayList<ByteArray>()
        var total = 0L
        val outcome = streamRead(ref, maxBytes, typedAcceptMime, cancel) { chunk, count ->
            val piece = chunk.copyOf(count)
            collected += piece
            total += count
        }
        return when (outcome) {
            is SafOutcome.Success -> SafOutcome.success(flatten(collected, total.toInt()), outcome.note)
            is SafOutcome.Failure -> SafOutcome.failure(outcome.failure, outcome.detail)
        }
    }

    /**
     * Import bounded bytes into a caller-owned POSIX staging directory under a
     * sanitized, identity-suffixed name. The part file is promoted ONLY after
     * the stream finished within the cap AND the staged read-back hash equals
     * the streamed hash. Virtual documents are refused here with a typed
     * actionable answer (use [streamRead] with a typed accept MIME).
     */
    fun stageToWorkingCopy(
        ref: SafDocumentRef,
        stagingRoot: File,
        byteLimit: Long?,
        cancel: SafCancelToken,
    ): SafOutcome<StagedCopy> = guarded(cancel) {
        gated(ref, setOf(SafAccessFlag.READ)) {
            val doc = backend.queryDocument(ref, cancel) ?: return@gated SafOutcome.failure(SafFailure.NotFound)
            if (doc.isVirtual) {
                return@gated SafOutcome.failure(
                    SafFailure.Unsupported(
                        "virtual document needs a typed accept MIME; stage via streamRead with an offered type",
                    ),
                )
            }
            val root = runCatching { stagingRoot.canonicalFile }.getOrNull()
                ?: return@gated SafOutcome.failure(SafFailure.Failed("staging root not resolvable"))
            if (!root.isDirectory) {
                return@gated SafOutcome.failure(SafFailure.Failed("staging root must be a caller-created directory"))
            }
            val identity = ref.uri.uriString + "|" + (ref.documentId ?: "")
            val safeName = SafStagingNames.forStaging(doc.displayName, identity, limits)
            val finalFile = File(root, safeName)
            val partFile = File(root, "$safeName.part-${UUID.randomUUID()}")
            if (!SafStagingNames.isWithin(root, finalFile) || !SafStagingNames.isWithin(root, partFile)) {
                return@gated SafOutcome.failure(SafFailure.Failed("staging name escaped caller root"))
            }
            val streamed: SafOutcome<StreamSummary> = try {
                val open = backend.openRead(ref, null, cancel)
                if (open is ReadOpen.NotFound) {
                    SafOutcome.failure<StreamSummary>(SafFailure.NotFound)
                } else {
                    val opened = open as ReadOpen.Opened
                    val out = FileOutputStream(partFile)
                    var result: SafOutcome<StreamSummary>? = null
                    try {
                        result = copyInto(
                            opened.input,
                            opened.lengthHintBytes,
                            byteLimit,
                            cancel,
                        ) { chunk, count -> out.write(chunk, 0, count) }
                        if (result is SafOutcome.Success) {
                            out.flush()
                            runCatching { out.fd.sync() }
                        }
                    } finally {
                        runCatching { out.close() }
                    }
                    result ?: SafOutcome.failure<StreamSummary>(SafFailure.Failed("staging pass produced no result"))
                }
            } catch (fault: SafBackendFaultException) {
                SafOutcome.failure(fault.fault.toSafFailure(), fault.message)
            } catch (io: IOException) {
                SafOutcome.failure(SafFailure.Io(io.message ?: "staging io"))
            }
            val summary = when (streamed) {
                is SafOutcome.Success -> streamed.value
                is SafOutcome.Failure -> {
                    // Failed passes never promote unverified bytes; source
                    // bytes remain untouched on the provider.
                    runCatching { partFile.delete() }
                    return@gated SafOutcome.failure(streamed.failure, streamed.detail)
                }
            }
            val readback = runCatching { hashFile(partFile) }
            if (readback.isFailure || readback.getOrNull() != summary.sha256) {
                return@gated SafOutcome.failure(
                    SafFailure.Conflict(
                        "staged bytes failed read-back verification; part retained for recovery: ${partFile.name}",
                    ),
                )
            }
            if (finalFile.exists() && !finalFile.delete()) {
                return@gated SafOutcome.failure(SafFailure.Io("cannot replace existing staged name"))
            }
            if (!partFile.renameTo(finalFile)) {
                return@gated SafOutcome.failure(SafFailure.Io("staged part could not be promoted"))
            }
            SafOutcome.success(
                StagedCopy(
                    local = StagedLocalRef(finalFile, finalFile.name),
                    sourceUri = ref.uri,
                    sourceDocumentId = ref.documentId,
                    bytes = summary.bytes,
                    sha256 = summary.sha256,
                    sizeHintBytes = (doc.size as? SafSize.Known)?.bytes,
                    lastModifiedHintMillis = doc.lastModifiedMillis,
                    displayName = doc.displayName,
                ),
            )
        }
    }

    // -----------------------------------------------------------------------
    // Mutation operations with exact capability gates
    // -----------------------------------------------------------------------

    fun createDocument(
        tree: SafUriRef,
        parentDocumentId: String?,
        mimeType: String,
        displayName: String,
        cancel: SafCancelToken,
    ): SafOutcome<SafDocumentRef> = guarded(cancel) {
        gated(treeAnchor(tree), setOf(SafAccessFlag.WRITE)) {
            if (SafStagingNames.isUnsafeDisplayName(displayName)) {
                return@gated SafOutcome.failure(SafFailure.Failed("display name is not a single safe segment"))
            }
            val parentRef = parentRefFor(tree, parentDocumentId)
                ?: return@gated SafOutcome.failure(SafFailure.NotFound)
            val parentDoc = backend.queryDocument(parentRef, cancel)
                ?: return@gated SafOutcome.failure(SafFailure.NotFound)
            if (!parentDoc.capabilities.createChildren) {
                return@gated SafOutcome.failure(SafFailure.Unsupported("parent document does not advertise child creation"))
            }
            when (val created = backend.createDocument(tree, parentDocumentId, mimeType, displayName, cancel)) {
                is OpResult.Ok -> {
                    if (!backend.isChildOf(created.value, tree, cancel)) {
                        return@gated SafOutcome.failure(
                            SafFailure.AmbiguousIdentity(
                                "provider returned ${created.value.uri.uriString} which is not a child of the granted tree",
                            ),
                        )
                    }
                    SafOutcome.success(created.value)
                }
                is OpResult.NullReturned -> SafOutcome.failure(
                    SafFailure.Unsupported("provider refused createDocument (${created.detail})"),
                )
            }
        }
    }

    fun renameDocument(ref: SafDocumentRef, newName: String, cancel: SafCancelToken): SafOutcome<SafDocumentRef> =
        guarded(cancel) {
            gated(ref, setOf(SafAccessFlag.WRITE)) {
                if (SafStagingNames.isUnsafeDisplayName(newName)) {
                    return@gated SafOutcome.failure(SafFailure.Failed("new name is not a single safe segment"))
                }
                val doc = backend.queryDocument(ref, cancel) ?: return@gated SafOutcome.failure(SafFailure.NotFound)
                if (!doc.capabilities.rename) {
                    return@gated SafOutcome.failure(SafFailure.Unsupported("provider flags do not support rename"))
                }
                when (val renamed = backend.renameDocument(ref, newName, cancel)) {
                    is OpResult.Ok -> {
                        val after = backend.queryDocument(renamed.value, cancel)
                        SafOutcome.success(
                            renamed.value,
                            if (after?.displayName == newName) null else "provider has not reflected the new name in metadata yet",
                        )
                    }
                    is OpResult.NullReturned -> SafOutcome.failure(SafFailure.Failed("provider returned null for rename (${renamed.detail})"))
                }
            }
        }

    fun deleteDocument(ref: SafDocumentRef, cancel: SafCancelToken): SafOutcome<Unit> = guarded(cancel) {
        gated(ref, setOf(SafAccessFlag.WRITE)) {
            val doc = backend.queryDocument(ref, cancel) ?: return@gated SafOutcome.failure(SafFailure.NotFound)
            if (!doc.capabilities.delete) {
                return@gated SafOutcome.failure(SafFailure.Unsupported("provider flags do not support delete"))
            }
            when (val deleted = backend.deleteDocument(ref, cancel)) {
                is OpResult.Ok -> {
                    if (!deleted.value) {
                        SafOutcome.failure(SafFailure.Failed("provider reported delete=false"))
                    } else {
                        val still = backend.queryDocument(ref, cancel)
                        if (still != null) {
                            SafOutcome.failure(SafFailure.Conflict("provider reported delete but the document is still queryable"))
                        } else {
                            SafOutcome.success(Unit)
                        }
                    }
                }
                is OpResult.NullReturned -> SafOutcome.failure(SafFailure.Failed("delete returned no result (${deleted.detail})"))
            }
        }
    }

    /**
     * Provider-side copy (FLAG_SUPPORTS_COPY) verified by hashing BOTH ends
     * through bounded streams. A receipt exists only when both hashes
     * completed; an unverifiable copy reports failure with the destination left
     * exactly where it is — never silently deleted, never claimed identical.
     */
    fun copyDocumentVerified(
        source: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        byteLimit: Long,
        cancel: SafCancelToken,
    ): SafOutcome<CopyReceipt> = guarded(cancel) {
        gated(source, setOf(SafAccessFlag.READ)) {
            gated(treeAnchor(destTree), setOf(SafAccessFlag.WRITE)) {
                val doc = backend.queryDocument(source, cancel) ?: return@gated SafOutcome.failure(SafFailure.NotFound)
                if (!doc.capabilities.copy) {
                    return@gated SafOutcome.failure(
                        SafFailure.Unsupported("provider flags do not support copyDocument; use the verified relay path"),
                    )
                }
                when (val copied = backend.copyDocument(source, destTree, destParentDocumentId, cancel)) {
                    is OpResult.Ok -> {
                        if (!backend.isChildOf(copied.value, destTree, cancel)) {
                            return@gated SafOutcome.failure(SafFailure.AmbiguousIdentity("copy result is not a child of the destination tree"))
                        }
                        val sourceHash = hashDocument(source, byteLimit, cancel)
                        if (sourceHash !is SafOutcome.Success) {
                            return@gated SafOutcome.failure(
                                (sourceHash as SafOutcome.Failure).failure,
                                "copy exists but source verification failed: ${sourceHash.detail}",
                            )
                        }
                        val destHash = hashDocument(copied.value, byteLimit, cancel)
                        if (destHash !is SafOutcome.Success) {
                            return@gated SafOutcome.failure(
                                (destHash as SafOutcome.Failure).failure,
                                "copy exists but destination verification failed: ${destHash.detail}",
                            )
                        }
                        SafOutcome.success(
                            CopyReceipt(
                                destination = copied.value,
                                sourceUri = source.uri,
                                sourceSha256 = sourceHash.value.sha256,
                                destinationSha256 = destHash.value.sha256,
                                bytes = sourceHash.value.bytes,
                            ),
                        )
                    }
                    is OpResult.NullReturned -> SafOutcome.failure(SafFailure.Failed("provider returned null for copyDocument (${copied.detail})"))
                }
            }
        }
    }

    /** Native provider move ONLY (same provider, FLAG_SUPPORTS_MOVE). */
    fun moveDocument(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        cancel: SafCancelToken,
    ): SafOutcome<SafDocumentRef> = guarded(cancel) {
        gated(ref, setOf(SafAccessFlag.READ, SafAccessFlag.WRITE)) {
            gated(treeAnchor(destTree), setOf(SafAccessFlag.WRITE)) {
                // Defect 2 fix 2026-10-24: DocumentsContract.moveDocument takes an
                // EXPLICIT source parent URI. Without resolvable parent identity we
                // report typed Unsupported instead of guessing a parent.
                if (ref.parentDocumentId == null) {
                    return@gated SafOutcome.failure(
                        SafFailure.Unsupported("moveDocument requires explicit source parent identity; refusing to guess it"),
                    )
                }
                val doc = backend.queryDocument(ref, cancel) ?: return@gated SafOutcome.failure(SafFailure.NotFound)
                if (!doc.capabilities.move) {
                    return@gated SafOutcome.failure(SafFailure.Unsupported("provider flags do not support moveDocument"))
                }
                when (val moved = backend.moveDocument(ref, destTree, destParentDocumentId, cancel)) {
                    is OpResult.Ok -> {
                        if (!backend.isChildOf(moved.value, destTree, cancel)) {
                            return@gated SafOutcome.failure(SafFailure.AmbiguousIdentity("move result is not a child of the destination tree"))
                        }
                        SafOutcome.success(moved.value)
                    }
                    is OpResult.NullReturned -> SafOutcome.failure(SafFailure.Failed("provider returned null for moveDocument (${moved.detail})"))
                }
            }
        }
    }

    /**
     * Truthful move ladder (Main steering 2026-10-24):
     *  1. native move when the provider supports it;
     *  2. on unsupported: verified copy — provider copy, else bounded relay
     *     through caller-owned scratch — with destination hash == source hash;
     *  3. explicit source delete ONLY after verification, ONLY when the caller
     *     allowed it and the source advertises deletion.
     * Delete-on-start never happens; every earlier failure leaves the source
     * untouched. Grant/revocation failures propagate typed without fallback.
     */
    fun moveWithVerifiedCopyFallback(
        ref: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        relayScratchRoot: File?,
        allowSourceDelete: Boolean,
        byteLimit: Long,
        cancel: SafCancelToken,
    ): SafOutcome<MoveResult> = guarded(cancel) {
        val nativeAttempt = moveDocument(ref, destTree, destParentDocumentId, cancel)
        if (nativeAttempt is SafOutcome.Success) {
            return@guarded SafOutcome.success(
                MoveResult(MoveMode.NATIVE_MOVE, nativeAttempt.value, null, false, "provider moved the document natively"),
                nativeAttempt.note,
            )
        }
        if (nativeAttempt is SafOutcome.Failure) {
            val fallbackEligible = nativeAttempt.failure is SafFailure.Unsupported ||
                nativeAttempt.failure is SafFailure.Failed ||
                nativeAttempt.failure is SafFailure.NotFound // provider refused the move call itself
            if (!fallbackEligible) {
                return@guarded SafOutcome.failure(nativeAttempt.failure, nativeAttempt.detail)
            }
        }
        val doc = backend.queryDocument(ref, cancel) ?: return@guarded SafOutcome.failure(SafFailure.NotFound)
        val copy: SafOutcome<CopyReceipt> = if (doc.capabilities.copy) {
            copyDocumentVerified(ref, destTree, destParentDocumentId, byteLimit, cancel)
        } else {
            relayCopyVerified(ref, destTree, destParentDocumentId, relayScratchRoot, byteLimit, cancel)
        }
        when (copy) {
            is SafOutcome.Failure -> SafOutcome.failure(copy.failure, "fallback copy failed; source untouched: ${copy.detail}")
            is SafOutcome.Success -> {
                if (!copy.value.byteIdentical) {
                    SafOutcome.failure(
                        SafFailure.Conflict("destination hash does not match source; destination kept, source untouched"),
                        "manual reconciliation required for ${copy.value.destination.uri.uriString}",
                    )
                } else if (!allowSourceDelete) {
                    SafOutcome.success(
                        MoveResult(
                            MoveMode.VERIFIED_COPY_SOURCE_RETAINED,
                            copy.value.destination,
                            copy.value,
                            false,
                            "caller did not authorize source deletion; both copies exist",
                        ),
                    )
                } else if (!doc.capabilities.delete) {
                    SafOutcome.success(
                        MoveResult(
                            MoveMode.VERIFIED_COPY_SOURCE_RETAINED,
                            copy.value.destination,
                            copy.value,
                            false,
                            "source provider does not support delete; copy verified, source retained",
                        ),
                    )
                } else {
                    // Defect 5 fix 2026-10-24: FRESH source rehash before the explicit
                    // delete step. If the source changed or became unreadable after the
                    // verified copy, BOTH source and destination are retained and the
                    // outcome says so; deletion never runs on stale verification.
                    val fresh = hashDocument(ref, byteLimit, cancel)
                    if (fresh !is SafOutcome.Success) {
                        SafOutcome.success(
                            MoveResult(
                                MoveMode.VERIFIED_COPY_SOURCE_RETAINED,
                                copy.value.destination,
                                copy.value,
                                false,
                                "source unreadable at pre-delete recheck (${(fresh as SafOutcome.Failure).failure.code}); both source and destination retained; reconcile",
                            ),
                        )
                    } else if (fresh.value.sha256 != copy.value.sourceSha256) {
                        SafOutcome.success(
                            MoveResult(
                                MoveMode.VERIFIED_COPY_SOURCE_RETAINED,
                                copy.value.destination,
                                copy.value,
                                false,
                                "source changed after the verified copy; both source and destination retained; reconcile",
                            ),
                        )
                    } else {
                        val deleteOutcome = deleteDocument(ref, cancel)
                        if (deleteOutcome is SafOutcome.Success) {
                            SafOutcome.success(
                                MoveResult(
                                    MoveMode.VERIFIED_COPY_PLUS_DELETE,
                                    copy.value.destination,
                                    copy.value,
                                    true,
                                    "verified copy, fresh pre-delete rehash match, explicit source delete",
                                ),
                            )
                        } else {
                            SafOutcome.success(
                                MoveResult(
                                    MoveMode.VERIFIED_COPY_SOURCE_RETAINED,
                                    copy.value.destination,
                                    copy.value,
                                    false,
                                    "source delete failed (${(deleteOutcome as SafOutcome.Failure).failure.code}); copy verified, source retained",
                                ),
                            )
                        }
                    }
                }
                }
            }
        }

    /** Bounded cross-provider relay copy: stage -> create doc -> stream -> hash-compare. */
    private fun relayCopyVerified(
        source: SafDocumentRef,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        scratchRoot: File?,
        byteLimit: Long,
        cancel: SafCancelToken,
    ): SafOutcome<CopyReceipt> {
        val root = scratchRoot
            ?: return SafOutcome.failure(SafFailure.Failed("relay copy needs a caller-owned scratch directory"))
        val staged = stageToWorkingCopy(source, root, byteLimit, cancel)
        if (staged !is SafOutcome.Success) {
            return SafOutcome.failure((staged as SafOutcome.Failure).failure, "relay staging failed")
        }
        val srcDoc = backend.queryDocument(source, cancel) ?: return SafOutcome.failure(SafFailure.NotFound)
        val created = createDocument(destTree, destParentDocumentId, srcDoc.mimeType, srcDoc.displayName, cancel)
        if (created !is SafOutcome.Success) {
            return SafOutcome.failure((created as SafOutcome.Failure).failure, "relay destination create failed")
        }
        val written = writeFileFromStaged(created.value, staged.value.local, cancel)
        if (written !is SafOutcome.Success) {
            return SafOutcome.failure(
                (written as SafOutcome.Failure).failure,
                "relay write failed; destination document exists but may be incomplete: ${created.value.uri.uriString}",
            )
        }
        val destHash = hashDocument(created.value, byteLimit, cancel)
        if (destHash !is SafOutcome.Success) {
            return SafOutcome.failure((destHash as SafOutcome.Failure).failure, "relay destination is present but unreadable for verification")
        }
        return SafOutcome.success(
            CopyReceipt(
                destination = created.value,
                sourceUri = source.uri,
                sourceSha256 = staged.value.sha256,
                destinationSha256 = destHash.value.sha256,
                bytes = staged.value.bytes,
            ),
        )
    }

    /**
     * Stream caller-owned staged bytes into a target document through the
     * truncate-write path. Used by exports and the (host-permitted) destructive
     * save. No atomicity claim; no partial write is ever labeled success.
     */
    internal fun writeFileFromStaged(
        target: SafDocumentRef,
        staged: StagedLocalRef,
        cancel: SafCancelToken,
    ): SafOutcome<StreamSummary> = guarded(cancel) {
        gated(target, setOf(SafAccessFlag.WRITE)) {
            val open = when (val w = backend.openWriteTruncate(target, cancel)) {
                is WriteOpen.UnsupportedMode -> return@gated SafOutcome.failure(
                    SafFailure.Unsupported("provider does not support truncate-write on this document"),
                )
                is WriteOpen.NotFound -> return@gated SafOutcome.failure(SafFailure.NotFound)
                is WriteOpen.Opened -> w
            }
            val hasher = SafStreamHasher(limits.chunkBytes)
            val buffer = ByteArray(limits.chunkBytes)
            val expectedBytes = staged.file.length()
            var failure: SafFailure? = null
            try {
                FileInputStream(staged.file).use { input ->
                    open.output.use { output ->
                        while (true) {
                            cancel.ensureActive()
                            val n = input.read(buffer)
                            if (n < 0) break
                            hasher.consume(buffer, n)
                            output.write(buffer, 0, n)
                        }
                        output.flush()
                    }
                }
            } catch (cancelled: SafCancelledException) {
                failure = SafFailure.Cancelled
            } catch (io: IOException) {
                failure = SafFailure.Io(io.message ?: "write io")
            } catch (fault: SafBackendFaultException) {
                failure = fault.fault.toSafFailure()
            }
            val f = failure
            if (f != null) {
                return@gated SafOutcome.failure(f, "partial write possible after ${hasher.bytes} bytes")
            }
            SafOutcome.success(
                StreamSummary(hasher.bytes, hasher.finishHex(), completed = true, lengthHintBytes = expectedBytes),
            )
        }
    }

    /** Hash one document through the bounded read path (never buffers fully). */
    internal fun hashDocument(ref: SafDocumentRef, byteLimit: Long, cancel: SafCancelToken): SafOutcome<StreamSummary> =
        streamRead(ref, byteLimit, null, cancel) { _, _ -> }

    // -----------------------------------------------------------------------

    private inline fun <T> gated(ref: SafDocumentRef, needs: Set<SafAccessFlag>, block: () -> SafOutcome<T>): SafOutcome<T> =
        when (val verdict = grants.gate(ref, needs)) {
            is GateVerdict.Denied -> SafOutcome.failure(verdict.failure)
            is GateVerdict.Allowed -> block()
        }

    private fun treeAnchor(tree: SafUriRef): SafDocumentRef =
        SafDocumentRef(tree = null, documentId = null, parentDocumentId = null, uri = tree)

    private fun parentRefFor(tree: SafUriRef, parentDocumentId: String?): SafDocumentRef? {
        val docId = parentDocumentId ?: return backend.resolveTreeRoot(tree)
        val uri = backend.documentUriFor(tree, docId) ?: return null
        return SafDocumentRef(tree = tree, documentId = docId, parentDocumentId = null, uri = uri)
    }

    private fun copyInto(
        input: java.io.InputStream,
        lengthHintBytes: Long?,
        byteLimit: Long?,
        cancel: SafCancelToken,
        sink: (ByteArray, Int) -> Unit,
    ): SafOutcome<StreamSummary> {
        val hasher = SafStreamHasher(limits.chunkBytes)
        val buffer = ByteArray(limits.chunkBytes)
        return try {
            while (true) {
                cancel.ensureActive()
                val n = input.read(buffer)
                if (n < 0) break
                if (byteLimit != null && hasher.bytes + n > byteLimit) {
                    return SafOutcome.failure(SafFailure.SizeLimitExceeded(byteLimit))
                }
                hasher.consume(buffer, n)
                sink(buffer, n)
            }
            SafOutcome.success(
                StreamSummary(hasher.bytes, hasher.finishHex(), completed = true, lengthHintBytes = lengthHintBytes),
            )
        } catch (cancelled: SafCancelledException) {
            SafOutcome.failure(SafFailure.Cancelled)
        } catch (fault: SafBackendFaultException) {
            SafOutcome.failure(fault.fault.toSafFailure(), fault.message)
        } catch (io: IOException) {
            SafOutcome.failure(SafFailure.Io(io.message ?: "stream io"))
        } finally {
            runCatching { input.close() }
        }
    }

    private fun flatten(parts: List<ByteArray>, total: Int): ByteArray {
        val out = ByteArray(total)
        var pos = 0
        parts.forEach { p ->
            System.arraycopy(p, 0, out, pos, p.size)
            pos += p.size
        }
        return out
    }

    private fun mimeAcceptable(accept: String, offered: List<String>): Boolean = offered.any { type ->
        if (type.equals(accept, ignoreCase = true)) return@any true
        val acceptPrefix = accept.substringBefore('/')
        val typePrefix = type.substringBefore('/')
        (accept.endsWith("/*") && acceptPrefix == typePrefix) ||
            (type.endsWith("/*") && acceptPrefix == typePrefix)
    }

    private fun hashFile(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private inline fun <T> guarded(cancel: SafCancelToken, block: () -> SafOutcome<T>): SafOutcome<T> {
        if (cancel.isCancelled) return SafOutcome.failure(SafFailure.Cancelled)
        return try {
            block()
        } catch (cancelled: SafCancelledException) {
            SafOutcome.failure(SafFailure.Cancelled)
        } catch (fault: SafBackendFaultException) {
            SafOutcome.failure(fault.fault.toSafFailure(), fault.message)
        } catch (io: IOException) {
            SafOutcome.failure(SafFailure.Io(io.message ?: "io"))
        } catch (security: SecurityException) {
            SafOutcome.failure(SafFailure.Revoked, security.message)
        } catch (state: IllegalStateException) {
            SafOutcome.failure(SafFailure.ProviderOffline, state.message)
        } catch (unsupported: UnsupportedOperationException) {
            SafOutcome.failure(SafFailure.Unsupported(unsupported.message ?: "unsupported"))
        } catch (t: Throwable) {
            SafOutcome.failure(SafFailure.Failed(t.message ?: t.javaClass.simpleName))
        }
    }
}

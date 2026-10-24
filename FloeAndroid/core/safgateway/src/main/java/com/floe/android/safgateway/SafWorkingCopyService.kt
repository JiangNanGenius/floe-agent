// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Native-side durable adoption hook (Main steering 2026-10-24). Before ANY
 * destructive provider write the recovery receipt (exact URI, document id,
 * source hash, replacement hash intent, recovery file path) must be handed to
 * the trusted coordinator, which PERSISTS it in the existing native journal and
 * only then permits the write. The gateway keeps only a RAM pointer — no
 * parallel Kotlin journal — so after process death the coordinator reconciles
 * from its own persisted receipt against the recorded URI/hash/recovery path.
 */
interface SafCommitCoordinator {
    fun requestCommitPermit(receipt: RecoveryReceipt): CommitPermit
}

sealed class CommitPermit {
    /** Receipt durably persisted by the native coordinator; destructive write allowed. */
    data object Permitted : CommitPermit()

    /** Coordinator will persist soon but has NOT confirmed: do not write yet. */
    data class Deferred(val reason: String) : CommitPermit()

    /** Coordinator rejects this write (policy, user cancel, storage pressure). */
    data class Refused(val reason: String) : CommitPermit()
}

enum class PreparedState { AWAITING_COMMIT, SOURCE_CHANGED }

/** A staged original + the live identities captured at prepare time. */
data class PreparedSave(
    val receipt: RecoveryReceipt,
    val target: SafDocumentRef,
    val state: PreparedState,
    val expectedSourceSha256: String?,
    val observedSourceSha256: String,
    val mimeType: String,
    val displayName: String,
)

/**
 * Working-copy seam: import/export receipts and the two-phase recoverable save.
 * Document/workspace/task revision, CAS and journal stay with Main's original
 * Swift authority; this class only moves verified bytes and hands receipts out.
 */
class SafWorkingCopyService internal constructor(
    private val backend: SafPlatformBackend,
    private val operations: SafProviderOperations,
    private val limits: SafLimits,
) {
    /** RAM pointer registry only — durability belongs to the native coordinator. */
    private val prepared = ConcurrentHashMap<String, PreparedSave>()

    /** Drift receipts issued during the pre-write recheck (defect 4 fix). */
    private val driftRecoveries = ConcurrentHashMap<String, RecoveryReceipt>()

    // -----------------------------------------------------------------------
    // Import / export receipts
    // -----------------------------------------------------------------------

    fun importDocument(
        ref: SafDocumentRef,
        stagingRoot: File,
        byteLimit: Long?,
        cancel: SafCancelToken,
    ): SafOutcome<ImportReceipt> {
        val staged = operations.stageToWorkingCopy(ref, stagingRoot, byteLimit, cancel)
        return when (staged) {
            is SafOutcome.Success -> SafOutcome.success(
                ImportReceipt(
                    staged = staged.value,
                    fingerprint = SourceFingerprint(
                        sha256 = staged.value.sha256,
                        bytes = staged.value.bytes,
                        sizeHintBytes = staged.value.sizeHintBytes,
                        lastModifiedHintMillis = staged.value.lastModifiedHintMillis,
                        observedAtMillis = System.currentTimeMillis(),
                    ),
                ),
                staged.note,
            )
            is SafOutcome.Failure -> SafOutcome.failure(staged.failure, staged.detail)
        }
    }

    /** Metadata-only fingerprint: size/mtime are HINTS; sha is null = bytes not obtained. */
    fun metadataFingerprint(ref: SafDocumentRef, cancel: SafCancelToken): SafOutcome<SourceFingerprint> {
        val doc = operations.metadata(ref, cancel)
        return doc.mapValue {
            SourceFingerprint(
                sha256 = null,
                bytes = (it.size as? SafSize.Known)?.bytes,
                sizeHintBytes = (it.size as? SafSize.Known)?.bytes,
                lastModifiedHintMillis = it.lastModifiedMillis,
                observedAtMillis = System.currentTimeMillis(),
            )
        }
    }

    /**
     * Export staged bytes as a NEW distinct provider document (ACTION_CREATE_DOCUMENT
     * semantics — never overwrites a same-name document), then verify by reading
     * the destination back through a bounded stream.
     */
    fun exportStagedCopy(
        copy: StagedCopy,
        destTree: SafUriRef,
        destParentDocumentId: String?,
        displayName: String,
        cancel: SafCancelToken,
    ): SafOutcome<ExportReceipt> {
        if (SafStagingNames.isUnsafeDisplayName(displayName)) {
            return SafOutcome.failure(SafFailure.Failed("export name is not a single safe segment"))
        }
        val created = operations.createDocument(destTree, destParentDocumentId, MIME_OCTET, displayName, cancel)
        if (created !is SafOutcome.Success) {
            return SafOutcome.failure((created as SafOutcome.Failure).failure, "export create failed; source staging untouched")
        }
        val written = operations.writeFileFromStaged(created.value, copy.local, cancel)
        if (written !is SafOutcome.Success) {
            return SafOutcome.failure(
                (written as SafOutcome.Failure).failure,
                "export write failed; created document may be incomplete: ${created.value.uri.uriString}",
            )
        }
        val readback = operations.hashDocument(created.value, copy.bytes, cancel)
        if (readback !is SafOutcome.Success) {
            return SafOutcome.success(
                ExportReceipt(
                    created = created.value,
                    bytes = copy.bytes,
                    sourceSha256 = copy.sha256,
                    destinationReadbackSha256 = null,
                    readbackVerified = false,
                ),
                "destination present but unreadable for verification: ${(readback as SafOutcome.Failure).failure.code}",
            )
        }
        val verified = readback.value.sha256 == copy.sha256 && readback.value.bytes == copy.bytes
        return if (verified) {
            SafOutcome.success(
                ExportReceipt(
                    created = created.value,
                    bytes = copy.bytes,
                    sourceSha256 = copy.sha256,
                    destinationReadbackSha256 = readback.value.sha256,
                    readbackVerified = true,
                ),
            )
        } else {
            SafOutcome.failure(
                SafFailure.Conflict("export read-back hash does not match staged bytes; destination kept, nothing deleted"),
                "staged=${copy.sha256} destination=${readback.value.sha256}",
            )
        }
    }

    // -----------------------------------------------------------------------
    // Two-phase recoverable save
    // -----------------------------------------------------------------------

    /**
     * PHASE 1: revalidate grant + exact write capability, then preserve the
     * CURRENT source bytes into caller-owned recovery storage (bounded, synced,
     * hashed) BEFORE any destructive possibility. If the observed hash differs
     * from the expected import hash the prepared state is SOURCE_CHANGED and
     * [commitSave] will refuse to write — the differing current bytes are still
     * preserved (someone else's work must stay recoverable too).
     */
    fun prepareSave(
        target: SafDocumentRef,
        expectedSourceSha256: String?,
        recoveryStore: File,
        byteLimit: Long,
        cancel: SafCancelToken,
    ): SafOutcome<PreparedSave> {
        require(byteLimit in 1..(2L shl 30)) { "recovery byte limit must be 1..2 GiB" }
        val doc = operations.metadata(target, cancel)
        if (doc !is SafOutcome.Success) return SafOutcome.failure((doc as SafOutcome.Failure).failure, doc.detail)
        if (!doc.value.capabilities.write) {
            return SafOutcome.failure(SafFailure.ReadOnly, "provider flags do not mark this document writable")
        }
        val root = runCatching { recoveryStore.canonicalFile }.getOrNull()
            ?: return SafOutcome.failure(SafFailure.Failed("recovery store not resolvable"))
        if (!root.isDirectory) {
            return SafOutcome.failure(SafFailure.Failed("recovery store must be a caller-created directory"))
        }
        val identity = target.uri.uriString + "|" + (target.documentId ?: "")
        val safeName = SafStagingNames.forStaging(doc.value.displayName, identity, limits) + ".recovery"
        val finalFile = File(root, safeName)
        val partFile = File(root, "$safeName.part-${UUID.randomUUID()}")
        if (!SafStagingNames.isWithin(root, finalFile) || !SafStagingNames.isWithin(root, partFile)) {
            return SafOutcome.failure(SafFailure.Failed("recovery name escaped caller store"))
        }
        // Preserve the CURRENT bytes first, always, before any decision to write.
        val preserved = copySourceToRecovery(target, partFile, byteLimit, cancel)
        val (bytes, sha) = when (preserved) {
            is SafOutcome.Success -> preserved.value
            is SafOutcome.Failure -> {
                runCatching { partFile.delete() }
                return SafOutcome.failure(preserved.failure, "original could not be preserved; no write will be attempted: ${preserved.detail}")
            }
        }
        if (!partFile.renameTo(finalFile)) {
            runCatching { partFile.delete() }
            return SafOutcome.failure(SafFailure.Io("recovery part could not be promoted"))
        }
        val receipt = RecoveryReceipt(
            receiptId = "rec-" + UUID.randomUUID(),
            file = StagedLocalRef(finalFile, finalFile.name),
            sha256 = sha,
            bytes = bytes,
            targetUri = target.uri,
            targetDocumentId = target.documentId,
            issuedAtMillis = System.currentTimeMillis(),
        )
        val state = if (expectedSourceSha256 != null && expectedSourceSha256 != sha) {
            PreparedState.SOURCE_CHANGED
        } else {
            PreparedState.AWAITING_COMMIT
        }
        val preparedSave = PreparedSave(
            receipt = receipt,
            target = target,
            state = state,
            expectedSourceSha256 = expectedSourceSha256,
            observedSourceSha256 = sha,
            mimeType = doc.value.mimeType,
            displayName = doc.value.displayName,
        )
        prepared[receipt.receiptId] = preparedSave
        return SafOutcome.success(
            preparedSave,
            when (state) {
                PreparedState.SOURCE_CHANGED -> "source changed since import; commitSave will refuse to overwrite"
                else -> null
            },
        )
    }

    /**
     * PHASE 2: apply the replacement.
     *  - SOURCE_CHANGED: never writes; returns [SaveReceipt.Conflict] with the
     *    preserved current bytes (typed reconciliation for the Swift authority).
     *  - Non-destructive default (policy or unsupported overwrite): SAVE_AS_SIBLING
     *    — the original stays untouched; the receipt says so honestly.
     *  - Destructive overwrite requires policy.allowDestructiveOverwrite AND
     *    preferSaveAsWhenReplacementNotProven=false AND a coordinator Permitted
     *    decision (the receipt must already be durably journalled natively).
     *  - After any attempted truncate-write the target is read back and hashed;
     *    only a matching read-back is reported Committed. Everything else keeps
     *    the recovery receipt and labels the outcome recoverable/deferred.
     */
    fun commitSave(
        preparedSave: PreparedSave,
        replacement: StagedLocalRef,
        replacementSha256: String,
        policy: SavePolicy,
        coordinator: SafCommitCoordinator?,
        cancel: SafCancelToken,
    ): SafOutcome<SaveReceipt> {
        if (cancel.isCancelled) return SafOutcome.failure(SafFailure.Cancelled)
        val registered = prepared[preparedSave.receipt.receiptId]
        if (registered == null) {
            return SafOutcome.failure(
                SafFailure.Failed("prepared save is not registered (process restart?) — reconcile via the coordinator's persisted receipt"),
                "reconcile:${preparedSave.receipt.receiptId}",
            )
        }
        if (registered != preparedSave) {
            return SafOutcome.failure(SafFailure.Conflict("prepared receipt identity does not match registered source"))
        }
        if (preparedSave.state == PreparedState.SOURCE_CHANGED) {
            return SafOutcome.success(
                SaveReceipt.Conflict(
                    expectedSha256 = preparedSave.expectedSourceSha256 ?: "",
                    observedSha256 = preparedSave.observedSourceSha256,
                    recovery = preparedSave.receipt,
                ),
            )
        }
        val destructive = policy.allowDestructiveOverwrite && !policy.preferSaveAsWhenReplacementNotProven
        if (!destructive) {
            return saveAsSibling(preparedSave, replacement, replacementSha256, policy, cancel, reason = "non-destructive policy: atomic replacement cannot be proven for this provider")
        }
        val coordinatorOrFailure = coordinator ?: return SafOutcome.success(
            SaveReceipt.RecoverableFailure(
                code = "commit-permit-coordinator-missing",
                recoveryPreserved = preparedSave.receipt,
                partialWritePossible = false,
                reconciliationRequired = false,
            ),
            "no native coordinator wired; destructive overwrite refused, nothing touched",
        )
        val decision = coordinatorOrFailure.requestCommitPermit(preparedSave.receipt)
        if (decision !is CommitPermit.Permitted) {
            val why = when (decision) {
                is CommitPermit.Deferred -> "deferred:${decision.reason}"
                is CommitPermit.Refused -> "refused:${decision.reason}"
                else -> "unknown"
            }
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "commit-permit-$why",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = false,
                ),
                "coordinator has not durably journalled the recovery receipt; write refused",
            )
        }
        // Fresh revalidation at the moment of destruction (grant, capability, identity).
        val live = operations.metadata(preparedSave.target, cancel)
        if (live !is SafOutcome.Success) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "target-unreadable-at-commit",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = true,
                ),
            )
        }
        if (!live.value.capabilities.write) {
            if (policy.allowSaveAsSibling) {
                return saveAsSibling(preparedSave, replacement, replacementSha256, policy, cancel, reason = "document lost write capability; saved as sibling instead")
            }
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "write-capability-lost",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = false,
                ),
            )
        }
        // Defect 4 fix 2026-10-24: rehash the CURRENT bytes immediately before the
        // destructive write. A generic DocumentsProvider cannot guarantee CAS — this
        // narrows the race window; the final consistency authority is the native
        // coordinator (SaveReceipt.Committed.providerCasGuaranteed is always false).
        val recheck = operations.hashDocument(preparedSave.target, policy.recoveryByteLimit, cancel)
        if (recheck !is SafOutcome.Success) {
            val rc = (recheck as SafOutcome.Failure).failure
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "recheck-${rc.code}",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = true,
                ),
                "current source unreadable/oversized at commit; NOTHING written",
            )
        }
        if (recheck.value.sha256 != preparedSave.receipt.sha256) {
            // Third-party drift since prepareSave: preserve the drifted bytes too,
            // then report conflict WITHOUT writing.
            val drift = preserveDriftBytes(preparedSave, policy.recoveryByteLimit, cancel)
            return SafOutcome.success(
                SaveReceipt.Conflict(
                    expectedSha256 = preparedSave.receipt.sha256,
                    observedSha256 = recheck.value.sha256,
                    recovery = preparedSave.receipt,
                    driftRecovery = drift,
                ),
            )
        }
        val written = operations.writeFileFromStaged(preparedSave.target, replacement, cancel)
        if (written !is SafOutcome.Success) {
            val f = (written as SafOutcome.Failure)
            val modeUnsupported = f.failure is SafFailure.Unsupported
            if (modeUnsupported && policy.allowSaveAsSibling) {
                return saveAsSibling(preparedSave, replacement, replacementSha256, policy, cancel, reason = "provider rejects truncate-write; saved as sibling instead")
            }
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "write-${f.failure.code}",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = true,
                    reconciliationRequired = true,
                ),
                f.detail,
            )
        }
        // Read-back verification: the ONLY state that may be reported Committed.
        val readback = operations.hashDocument(preparedSave.target, maxOf(replacement.file.length(), 1L), cancel)
        if (readback !is SafOutcome.Success) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = if ((readback as? SafOutcome.Failure)?.failure is SafFailure.SizeLimitExceeded)
                        "post-write-verification-mismatch" else "post-write-readback-unreadable",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = true,
                    reconciliationRequired = true,
                ),
            )
        }
        if (readback.value.sha256 != replacementSha256) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "post-write-verification-mismatch",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = true,
                    reconciliationRequired = true,
                ),
                "target=${readback.value.sha256} replacement=$replacementSha256",
            )
        }
        return SafOutcome.success(
            SaveReceipt.Committed(
                strategy = SaveStrategy.WRITE_TRUNCATE_NON_ATOMIC,
                target = preparedSave.target,
                writtenSha256 = replacementSha256,
                readbackVerified = true,
                recovery = preparedSave.receipt,
            ),
            "recovery stays registered and on disk until the coordinator adopts it",
        )
    }

    private fun saveAsSibling(
        preparedSave: PreparedSave,
        replacement: StagedLocalRef,
        replacementSha256: String,
        policy: SavePolicy,
        cancel: SafCancelToken,
        reason: String,
    ): SafOutcome<SaveReceipt> {
        if (!policy.allowSaveAsSibling) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "save-as-disabled-by-policy",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = false,
                ),
                reason,
            )
        }
        val tree = preparedSave.target.tree
        if (tree == null) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "save-as-needs-tree-context",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = false,
                ),
                "document opened without a tree grant cannot create a sibling; re-pick a tree or grant create intent explicitly",
            )
        }
        val siblingName = siblingDisplayName(preparedSave.displayName, preparedSave.receipt.receiptId)
        val created = operations.createDocument(
            tree,
            preparedSave.target.parentDocumentId ?: backend.resolveTreeRoot(tree)?.documentId,
            preparedSave.mimeType.ifBlank { MIME_OCTET },
            siblingName,
            cancel,
        )
        if (created !is SafOutcome.Success) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "sibling-create-${(created as SafOutcome.Failure).failure.code}",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = false,
                    reconciliationRequired = true,
                ),
                "original untouched: ${preparedSave.target.uri.uriString}",
            )
        }
        val written = operations.writeFileFromStaged(created.value, replacement, cancel)
        if (written !is SafOutcome.Success) {
            return SafOutcome.success(
                SaveReceipt.RecoverableFailure(
                    code = "sibling-write-${(written as SafOutcome.Failure).failure.code}",
                    recoveryPreserved = preparedSave.receipt,
                    partialWritePossible = true,
                    reconciliationRequired = true,
                ),
                "sibling ${created.value.uri.uriString} may be incomplete; original untouched",
            )
        }
        val verify = operations.hashDocument(created.value, maxOf(replacement.file.length(), 1L), cancel)
        val readbackSha = (verify as? SafOutcome.Success)?.value?.sha256
        return SafOutcome.success(
            SaveReceipt.SaveAsCreated(
                created = ExportReceipt(
                    created = created.value,
                    bytes = replacement.file.length(),
                    sourceSha256 = replacementSha256,
                    destinationReadbackSha256 = readbackSha,
                    readbackVerified = readbackSha == replacementSha256,
                ),
                originalUntouched = true,
                reason = reason,
            ),
            if (readbackSha == replacementSha256) null else "sibling read-back did not confirm; verify before trusting the save-as",
        )
    }

    /**
     * Adopt transfers recovery ownership to the native coordinator. It NEVER
     * deletes bytes: the recovery file stays until the host decides otherwise
     * (Main steering 2026-10-24). Covers prepare and drift receipts.
     */
    fun adoptRecovery(receiptId: String): SafOutcome<RecoveryReceipt> {
        val preparedHit = prepared.remove(receiptId)?.receipt
        val driftHit = driftRecoveries.remove(receiptId)
        val receipt = preparedHit ?: driftHit
            ?: return SafOutcome.failure(SafFailure.Failed("unknown receipt (already adopted, or process restarted — reconcile from the persisted journal)"))
        return SafOutcome.success(receipt, "ownership transferred; bytes left on disk")
    }

    /** Drop only this RAM pointer. OS state, files and the coordinator journal are untouched. */
    fun releaseRecoveryReference(receiptId: String): Boolean =
        prepared.remove(receiptId) != null || driftRecoveries.remove(receiptId) != null

    fun pendingRecoveryReceipts(): List<RecoveryReceipt> =
        prepared.values.map { it.receipt } + driftRecoveries.values

    internal fun siblingDisplayName(original: String, receiptId: String): String {
        val tag = receiptId.removePrefix("rec-").take(8)
        val candidate = "$original.floe-save-$tag"
        return if (SafStagingNames.isUnsafeDisplayName(candidate)) "document.floe-save-$tag" else candidate
    }

    /**
     * Defect 4 fix 2026-10-24: after the pre-write recheck detects drift, preserve
     * the CURRENT (drifted) bytes into a second caller-owned recovery file so a
     * third writer's work also stays recoverable. Returns null (and the conflict is
     * still reported honestly) when the drift cannot be preserved.
     */
    private fun preserveDriftBytes(
        preparedSave: PreparedSave,
        byteLimit: Long,
        cancel: SafCancelToken,
    ): RecoveryReceipt? {
        val store = preparedSave.receipt.file.file.parentFile ?: return null
        val safeName = preparedSave.receipt.file.name + ".drift-" + preparedSave.receipt.receiptId.removePrefix("rec-").take(8)
        val finalFile = File(store, safeName)
        val partFile = File(store, "$safeName.part-${UUID.randomUUID()}")
        if (!SafStagingNames.isWithin(store, finalFile) || !SafStagingNames.isWithin(store, partFile)) return null
        val preserved = copySourceToRecovery(preparedSave.target, partFile, byteLimit, cancel)
        if (preserved !is SafOutcome.Success) {
            runCatching { partFile.delete() }
            return null
        }
        val (bytes, sha) = preserved.value
        if (!partFile.renameTo(finalFile)) {
            runCatching { partFile.delete() }
            return null
        }
        val drift = RecoveryReceipt(
            receiptId = "rec-drift-" + UUID.randomUUID(),
            file = StagedLocalRef(finalFile, finalFile.name),
            sha256 = sha,
            bytes = bytes,
            targetUri = preparedSave.receipt.targetUri,
            targetDocumentId = preparedSave.receipt.targetDocumentId,
            issuedAtMillis = System.currentTimeMillis(),
        )
        driftRecoveries[drift.receiptId] = drift
        return drift
    }

    private fun copySourceToRecovery(
        target: SafDocumentRef,
        partFile: File,
        byteLimit: Long,
        cancel: SafCancelToken,
    ): SafOutcome<Pair<Long, String>> {
        val open = try {
            backend.openRead(target, null, cancel)
        } catch (fault: SafBackendFaultException) {
            return SafOutcome.failure(fault.fault.toSafFailure(), fault.message)
        } catch (io: IOException) {
            return SafOutcome.failure(SafFailure.Io(io.message ?: "recovery open io"))
        }
        if (open is ReadOpen.NotFound) return SafOutcome.failure(SafFailure.NotFound)
        val opened = open as ReadOpen.Opened
        val hasher = SafStreamHasher(limits.chunkBytes)
        val buffer = ByteArray(limits.chunkBytes)
        return try {
            FileOutputStream(partFile).use { out ->
                while (true) {
                    cancel.ensureActive()
                    val n = opened.input.read(buffer)
                    if (n < 0) break
                    if (hasher.bytes + n > byteLimit) {
                        return SafOutcome.failure(SafFailure.SizeLimitExceeded(byteLimit))
                    }
                    out.write(buffer, 0, n)
                    hasher.consume(buffer, n)
                }
                out.flush()
                runCatching { out.fd.sync() }
            }
            SafOutcome.success(hasher.bytes to hasher.finishHex())
        } catch (cancelled: SafCancelledException) {
            SafOutcome.failure(SafFailure.Cancelled)
        } catch (fault: SafBackendFaultException) {
            SafOutcome.failure(fault.fault.toSafFailure(), fault.message)
        } catch (io: IOException) {
            SafOutcome.failure(SafFailure.Io(io.message ?: "recovery copy io"))
        } finally {
            runCatching { opened.input.close() }
        }
    }

    private companion object {
        const val MIME_OCTET = "application/octet-stream"
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCancelledException
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafLimits
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.SafPlatformBackend
import com.floe.android.safgateway.SafUriRef
import com.floe.android.safgateway.WriteOpen
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/** One requested Save Copy of one exact owned run output. The identity is
 * the runtime-sealed (conversation, run, output) triple plus a monotonic
 * request generation — never a session token minted for a preview mount. */
internal data class RunOutputSaveIdentity(
    val conversationID: String,
    val runID: String,
    val outputID: String,
    val generation: Long,
) {
    init {
        require(conversationID.isNotBlank() && runID.isNotBlank() && outputID.isNotBlank())
        require(generation > 0)
    }
}

/** The OPENED owned egress as a bounded readable source. Production backs
 * this with the native ticket (lease held); qualification scripts it. The
 * implementing owner MUST close it exactly once after settling. */
internal interface RunOutputEgressSource : AutoCloseable {
    val info: RunOutputEgressInfo
    /** Copies up to buffer.size bytes at offset; 0 = clean EOF; negative =
     * typed native status. */
    fun read(offset: Long, buffer: ByteArray): Int
    override fun close()
}

internal enum class RunOutputSaveStage { AWAITING_TARGET, STAGING, TRANSFERRING, VERIFYING }

internal sealed class RunOutputSaveOutcome {
    /** ONLY reachable after the destination read-back matched the NATIVE
     * verified size AND streamed SHA-256 byte-for-byte. */
    data class Saved(
        val identity: RunOutputSaveIdentity,
        val destination: SafUriRef,
        val bytes: Long,
        val sha256: String,
        val grantPersisted: Set<SafAccessFlag>,
        val grantTransientOnly: Boolean,
    ) : RunOutputSaveOutcome()

    data class Cancelled(
        val identity: RunOutputSaveIdentity,
        val stage: RunOutputSaveStage,
        val reason: String,
        val partialWritePossible: Boolean,
    ) : RunOutputSaveOutcome()

    data class Failed(
        val identity: RunOutputSaveIdentity,
        val code: String,
        val stage: RunOutputSaveStage,
        val detail: String?,
        val destinationUri: SafUriRef?,
        val partialWritePossible: Boolean,
    ) : RunOutputSaveOutcome()
}

internal sealed class RunOutputSaveDelivery {
    data class TargetAccepted(
        val identity: RunOutputSaveIdentity,
        val uri: SafUriRef,
        val granted: Set<SafAccessFlag>,
        val persisted: Set<SafAccessFlag>,
        val transientOnly: Boolean,
    ) : RunOutputSaveDelivery()

    data class NoTarget(val identity: RunOutputSaveIdentity?, val reason: String)
        : RunOutputSaveDelivery()
    data class Refused(val identity: RunOutputSaveIdentity, val code: String,
                       val detail: String) : RunOutputSaveDelivery()
}

/** Save Copy of an owned run output to a system-picked CREATE_DOCUMENT
 * destination.
 *
 * This deliberately REUSES the existing SAF file-write services with the
 * SAME semantics the reviewed Office Save-Copy controller uses (there is no
 * separate `SafStreamVerifier` in the repo — verification IS
 * `SafProviderOperations.streamRead` + streamed hashing):
 *   * system CREATE_DOCUMENT picker spec + EXPLICIT acceptance of the
 *     ACTUAL returned intent flags (only the flags the platform really
 *     granted are recorded; persist attempts stay per-flag WRITE-first);
 *   * live access evidence recheck before any IO;
 *   * Phase 1 stages the trusted egress bytes into this controller's own
 *     scratch while streaming size + SHA-256, with the exact EOF probe;
 *   * Phase 2 writes via `backend.openWriteTruncate` (never a path grant
 *     from the display name; the destination is the picked document);
 *   * Phase 3 reads the destination BACK through the gateway and reports
 *     [RunOutputSaveOutcome.Saved] ONLY on exact size + digest equality
 *     against the native-verified receipt digest.
 *   * Cancellation/failure NEVER deletes or relabels a possibly-written
 *     destination and NEVER touches the run-output snapshot (the original
 *     stays immutable and recoverable; the caller closes the egress lease
 *     exactly once).
 * The original snapshot bytes remain owned by the run-output lifecycle; this
 * lane only reads them under the generation lease.
 */
internal class RunOutputSaveCopyController(
    private val service: SafGatewayService,
    private val backend: SafPlatformBackend,
    private val stagingRoot: File,
    private val limits: SafLimits = SafLimits.DEFAULT,
) {
    companion object {
        const val MAX_BYTES = RunOutputReply.MAX_BYTES // 256 MiB — the frozen output cap
    }

    private val lock = Any()
    private var generation = 0L
    private var active: Active? = null

    private class Active(
        val identity: RunOutputSaveIdentity,
        val spec: PickRequestSpec,
        val source: RunOutputEgressSource,
        var target: SafDocumentRef? = null,
        var persisted: Set<SafAccessFlag> = emptySet(),
        var transientOnly: Boolean = false,
        var delivered: Boolean = false,
        var stage: RunOutputSaveStage = RunOutputSaveStage.AWAITING_TARGET,
        var settled: RunOutputSaveOutcome? = null,
        var cancel: SafCancelToken? = null,
        var scratchDir: File? = null,
    )

    /** Mints the next pick request for ONE exact output. Fails closed while
     * another save owns the slot (single active operation, like the
     * reviewed controller). */
    fun prepare(source: RunOutputEgressSource): Pair<RunOutputSaveIdentity, PickRequestSpec>? {
        val info = source.info
        // Display name must be an inert single component; the MIME must be
        // concrete (mirrors OfficeSaveCopySource rules — wildcards refused).
        if (info.displayName.contains('/') || info.displayName.contains('\\') ||
            info.displayName.startsWith('.') || info.displayName.isEmpty() ||
            info.mimeType.isEmpty() || info.mimeType.contains('*') ||
            info.mimeType.count { it == '/' } != 1) {
            return null
        }
        val expected = "RunOutputs/${info.runID}/${info.outputID}/${info.displayName}"
        if (info.relativePath != expected) return null
        if (info.byteCount !in 1..MAX_BYTES) return null
        synchronized(lock) {
            if (active != null) return null
            val identity = RunOutputSaveIdentity(
                conversationID = info.conversationID,
                runID = info.runID,
                outputID = info.outputID,
                generation = ++generation,
            )
            val spec = service.grants.pickerForCreateDocument(info.mimeType, info.displayName)
            active = Active(identity, spec, source)
            return identity to spec
        }
    }

    /** Accepts the ACTUAL picker result (URI + real intent flags). Only
     * WRITE + READ live access can carry the operation forward; persistence
     * is recorded as the gateway actually achieved it (transient fallback
     * stays honest). */
    @Suppress("ReturnCount")
    fun deliverPickResult(resultUriString: String?, returnedIntentFlags: Int,
                          identity: RunOutputSaveIdentity): RunOutputSaveDelivery {
        val claim = synchronized(lock) {
            val current = active ?: return RunOutputSaveDelivery.NoTarget(null, "no active save")
            if (current.identity != identity) {
                return RunOutputSaveDelivery.NoTarget(identity, "identity does not own the active save")
            }
            if (current.delivered) {
                return RunOutputSaveDelivery.NoTarget(identity, "pick result already delivered once")
            }
            current.delivered = true
            current
        }
        val accepted = when (val result = service.grants.acceptPickResult(
            claim.spec, resultUriString, returnedIntentFlags,
        )) {
            is PickAcceptResult.Cancelled -> {
                settle(claim, RunOutputSaveOutcome.Cancelled(
                    identity, RunOutputSaveStage.AWAITING_TARGET, result.reason,
                    partialWritePossible = false))
                return RunOutputSaveDelivery.NoTarget(identity, result.reason)
            }
            is PickAcceptResult.Rejected -> {
                settle(claim, RunOutputSaveOutcome.Failed(
                    identity, "pick-rejected", RunOutputSaveStage.AWAITING_TARGET,
                    result.detail, null, partialWritePossible = false))
                return RunOutputSaveDelivery.Refused(identity, "pick-rejected", result.detail)
            }
            is PickAcceptResult.Accepted -> result
        }
        if (!accepted.granted.contains(SafAccessFlag.WRITE) ||
            !accepted.granted.contains(SafAccessFlag.READ)) {
            settle(claim, RunOutputSaveOutcome.Failed(
                identity, "write-flag-missing", RunOutputSaveStage.AWAITING_TARGET,
                "the platform result did not actually grant read+write", accepted.uri,
                partialWritePossible = false))
            return RunOutputSaveDelivery.Refused(identity, "write-flag-missing",
                "the platform result did not actually grant read+write")
        }
        val evidence = try { service.grants.currentAccess(accepted.uri) } catch (_: Exception) { null }
        // Truth order (same precedence SafGrantGateway itself applies when
        // retaining a grant): an explicit live DENIED probe is authoritative —
        // a stale persisted row can never revive access the current session
        // denies. UNKNOWN probes stay non-fatal (persisted rows still count).
        val readLive = evidence?.let { it.read && it.probeRead != ProbeFlag.DENIED } ?: false
        val writeLive = evidence?.let { it.write && it.probeWrite != ProbeFlag.DENIED } ?: false
        if (!readLive || !writeLive) {
            settle(claim, RunOutputSaveOutcome.Failed(
                identity, "access-not-live", RunOutputSaveStage.AWAITING_TARGET,
                "platform probe denies the returned grant", accepted.uri,
                partialWritePossible = false))
            return RunOutputSaveDelivery.Refused(identity, "access-not-live",
                "platform probe denies the returned grant")
        }
        synchronized(lock) {
            if (active !== claim) return@synchronized
            claim.target = SafDocumentRef(tree = null, documentId = null,
                                          parentDocumentId = null, uri = accepted.uri)
            claim.persisted = accepted.persisted
            claim.transientOnly = accepted.transientOnly
        }
        if (claim.target == null) {
            return RunOutputSaveDelivery.NoTarget(identity, "operation was replaced during acceptance")
        }
        return RunOutputSaveDelivery.TargetAccepted(identity, accepted.uri, accepted.granted,
                                                    accepted.persisted, accepted.transientOnly)
    }

    /** Three-phase verified transfer. Runs on the gateway IO thread; every
     * chunk boundary honours [cancel]. The caller MUST close the egress
     * source once this returns (lease release exactly once). */
    fun transfer(identity: RunOutputSaveIdentity, cancel: SafCancelToken): RunOutputSaveOutcome {
        var outcome: RunOutputSaveOutcome
        try {
            val current = synchronized(lock) {
                val op = active
                if (op == null || op.identity != identity) {
                    return RunOutputSaveOutcome.Cancelled(identity,
                        RunOutputSaveStage.AWAITING_TARGET, "no active operation for this identity",
                        partialWritePossible = false)
                }
                op.cancel = cancel
                op
            }
            val target = current.target
                ?: run {
                    val orphan = RunOutputSaveOutcome.Failed(
                        identity, "no-target", RunOutputSaveStage.AWAITING_TARGET,
                        "deliver the picker result first", null, partialWritePossible = false)
                    settle(current, orphan)
                    return orphan
                }
            // Retain the platform grant references for the duration of IO
            // through the SAME app-wide broker every SAF lane uses; failure
            // to retain means the grant vanished and nothing may be written.
            val readLease = com.floe.android.host.SharedUriGrantAuthority.broker
                .retain(target.uri, SafAccessFlag.READ)
            val writeLease = com.floe.android.host.SharedUriGrantAuthority.broker
                .retain(target.uri, SafAccessFlag.WRITE)
            try {
                outcome = transferLocked(current.source, target, identity, cancel)
            } finally {
                readLease.release()
                writeLease.release()
            }
        } catch (fault: Exception) {
            outcome = RunOutputSaveOutcome.Failed(identity, "io-fault",
                RunOutputSaveStage.TRANSFERRING, fault.message, null,
                partialWritePossible = false)
        }
        settle(synchronized(lock) { active?.takeIf { it.identity == identity } }, outcome)
        return outcome
    }

    private fun transferLocked(source: RunOutputEgressSource, target: SafDocumentRef,
                               identity: RunOutputSaveIdentity,
                               cancel: SafCancelToken): RunOutputSaveOutcome {
        val info = source.info
        val bytes = info.byteCount
        val expectedSha = info.sha256
        // Phase 1: stage the trusted egress into our own scratch, bounded,
        // hashed, with the exact EOF probe. The provider destination is NOT
        // touched until the staged bytes prove to be exactly the verified
        // snapshot.
        synchronized(lock) { active?.stage = RunOutputSaveStage.STAGING }
        val dir = File(stagingRoot, "ro-${UUID.randomUUID()}")
        if (!dir.mkdirs()) {
            return RunOutputSaveOutcome.Failed(identity, "scratch-unavailable",
                RunOutputSaveStage.STAGING, null, null, false)
        }
        synchronized(lock) { active?.scratchDir = dir }
        if (!dir.canonicalFile.path.startsWith(stagingRoot.canonicalFile.path + File.separator)) {
            return RunOutputSaveOutcome.Failed(identity, "scratch-escape",
                RunOutputSaveStage.STAGING, null, null, false)
        }
        val part = File(dir, "payload.part")
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            FileOutputStream(part).use { out ->
                val buffer = ByteArray(limits.chunkBytes)
                var offset = 0L
                while (offset < bytes) {
                    cancel.ensureActive()
                    val copied = source.read(offset, buffer)
                    if (copied <= 0 || copied > buffer.size || copied > bytes - offset) {
                        throw IllegalStateException("invalid-egress-chunk:$copied")
                    }
                    digest.update(buffer, 0, copied)
                    out.write(buffer, 0, copied)
                    offset += copied
                }
                cancel.ensureActive()
                // Exact EOF matters as well as the header digest/size.
                if (source.read(bytes, buffer) != 0) throw IllegalStateException("egress-length-mismatch")
                out.flush()
                out.fd.sync()
            }
        } catch (cancelled: SafCancelledException) {
            part.delete()
            return RunOutputSaveOutcome.Cancelled(identity, RunOutputSaveStage.STAGING,
                "cancelled while staging", partialWritePossible = false)
        } catch (error: Exception) {
            part.delete()
            return RunOutputSaveOutcome.Failed(identity, error.message ?: "stage-failed",
                RunOutputSaveStage.STAGING, "nothing was written to the destination",
                null, partialWritePossible = false)
        }
        val stagedSha = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        if (part.length() != bytes) {
            part.delete()
            return RunOutputSaveOutcome.Failed(identity, "source-length-mismatch",
                RunOutputSaveStage.STAGING,
                "streamed ${part.length()} bytes, expected $bytes", null, false)
        }
        if (stagedSha != expectedSha) {
            part.delete()
            return RunOutputSaveOutcome.Failed(identity, "source-hash-mismatch",
                RunOutputSaveStage.STAGING,
                "staged bytes differ from the verified native snapshot; nothing was written",
                null, false)
        }

        // Phase 2: write the staged bytes into the DISTINCT picked document.
        synchronized(lock) { active?.stage = RunOutputSaveStage.TRANSFERRING }
        val open = try {
            backend.openWriteTruncate(target, cancel)
        } catch (io: IOException) {
            return RunOutputSaveOutcome.Failed(identity, "write-open-io",
                RunOutputSaveStage.TRANSFERRING, io.message, target.uri, false)
        }
        when (open) {
            is WriteOpen.UnsupportedMode -> return RunOutputSaveOutcome.Failed(
                identity, "write-unsupported", RunOutputSaveStage.TRANSFERRING,
                "provider rejects truncate-write on the picked document", target.uri, false)
            is WriteOpen.NotFound -> return RunOutputSaveOutcome.Failed(
                identity, "not-found", RunOutputSaveStage.TRANSFERRING,
                "the picked document is gone before the write", target.uri, false)
            is WriteOpen.Opened -> {
                var failure: SafFailure? = null
                try {
                    part.inputStream().use { input ->
                        open.output.use { output ->
                            val buffer = ByteArray(limits.chunkBytes)
                            while (true) {
                                cancel.ensureActive()
                                val n = input.read(buffer)
                                if (n < 0) break
                                output.write(buffer, 0, n)
                            }
                            output.flush()
                        }
                    }
                } catch (cancelled: SafCancelledException) {
                    failure = SafFailure.Cancelled
                } catch (io: IOException) {
                    failure = SafFailure.Io(io.message ?: "write io")
                }
                val f = failure
                if (f == SafFailure.Cancelled) {
                    // Cancel honoured at a chunk boundary AFTER bytes may
                    // have reached the provider: honest Cancelled; the
                    // uncertain destination is kept, never deleted or
                    // relabelled.
                    return RunOutputSaveOutcome.Cancelled(identity,
                        RunOutputSaveStage.TRANSFERRING, "cancelled during destination write",
                        partialWritePossible = true)
                } else if (f != null) {
                    // Uncertain destination: kept, never deleted, never
                    // relabelled; partialWritePossible stays honest.
                    return RunOutputSaveOutcome.Failed(identity, "write-failed",
                        RunOutputSaveStage.TRANSFERRING, "provider write did not settle cleanly",
                        target.uri, partialWritePossible = true)
                }
            }
        }

        // Phase 3: read the destination back; size + streamed SHA equality
        // against the NATIVE verified digest is the ONLY path to Saved.
        synchronized(lock) { active?.stage = RunOutputSaveStage.VERIFYING }
        val readback = service.operations.streamRead(target, MAX_BYTES, null, cancel) { _, _ -> }
        return when (readback) {
            is SafOutcome.Failure -> {
                val cancelled = readback.failure == SafFailure.Cancelled
                if (cancelled) {
                    RunOutputSaveOutcome.Cancelled(identity, RunOutputSaveStage.VERIFYING,
                        "cancelled during destination read-back", partialWritePossible = true)
                } else {
                    RunOutputSaveOutcome.Failed(identity, "verify-unavailable",
                        RunOutputSaveStage.VERIFYING, readback.detail, target.uri,
                        partialWritePossible = true)
                }
            }
            is SafOutcome.Success -> {
                val summary = readback.value
                if (!summary.completed || summary.bytes != bytes || summary.sha256 != expectedSha) {
                    RunOutputSaveOutcome.Failed(identity, "verify-mismatch",
                        RunOutputSaveStage.VERIFYING,
                        "read-back ${summary.bytes} bytes sha ${summary.sha256}; " +
                            "expected $bytes bytes sha $expectedSha",
                        target.uri, partialWritePossible = true)
                } else {
                    val persisted = synchronized(lock) { active?.persisted ?: emptySet() }
                    val transientOnly = synchronized(lock) { active?.transientOnly ?: true }
                    RunOutputSaveOutcome.Saved(identity, target.uri, summary.bytes,
                        summary.sha256, persisted, transientOnly)
                }
            }
        }
    }

    /** Cancel the in-flight/awaiting operation by identity. A transfer that
     * already reached the provider cannot be reversed; the outcome labels it
     * honestly via partialWritePossible. */
    fun cancel(identity: RunOutputSaveIdentity, reason: String): Boolean {
        val current = synchronized(lock) {
            active?.takeIf { it.identity == identity }?.also { it.cancel?.cancel() } ?: return false
        }
        if (current.stage == RunOutputSaveStage.AWAITING_TARGET ||
            current.stage == RunOutputSaveStage.STAGING) {
            settle(current, RunOutputSaveOutcome.Cancelled(identity,
                current.stage, reason, partialWritePossible = false))
            return true
        }
        return false
    }

    private fun settle(current: Active?, outcome: RunOutputSaveOutcome) {
        if (current == null) return
        synchronized(lock) {
            if (active === current && current.settled == null) {
                current.settled = outcome
                active = null
                current.scratchDir?.let { dir ->
                    if (isWithin(stagingRoot, dir)) dir.deleteRecursivelySafely(stagingRoot)
                }
            }
        }
    }

    /** Drop the active operation for an unmounted surface / runtime stop. */
    fun abandonActive(reason: String): RunOutputSaveIdentity? = synchronized(lock) {
        val current = active ?: return@synchronized null
        current.cancel?.cancel()
        settle(current, RunOutputSaveOutcome.Cancelled(current.identity, current.stage, reason,
            partialWritePossible = false))
        current.identity
    }

    private fun isWithin(root: File, candidate: File): Boolean = runCatching {
        val base = root.canonicalFile.path
        val path = candidate.canonicalFile.path
        path.startsWith(base + File.separator) && path != base
    }.getOrDefault(false)

    private fun File.deleteRecursivelySafely(root: File) {
        if (!isWithin(root, this) && canonicalFile != root.canonicalFile) return
        listFiles()?.forEach { it.delete() }
        delete()
    }

}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.content.Context
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.ui.design.DesignExportDeliveryResult
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.host.SharedUriGrantAuthority
import com.floe.android.mediaintegration.MediaWorkbenchExportProof
import com.floe.android.safgateway.AndroidSafBackend
import com.floe.android.safgateway.PickAcceptResult
import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.ProbeFlag
import com.floe.android.safgateway.SafAccessFlag
import com.floe.android.safgateway.SafCancelToken
import com.floe.android.safgateway.SafCancelledException
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafGatewayService
import com.floe.android.safgateway.SafOutcome
import com.floe.android.safgateway.WriteOpen
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal data class DesignPendingPick(
    val incarnation: Long,
    val spec: PickRequestSpec,
    val suggestedName: String,
)

/**
 * Application-owned verified Save for one design export receipt.
 *
 * The design UI starts the operation; this process-owned worker owns the
 * picker wait and the real provider IO. Rotation keeps the pending pick and
 * in-flight copy; an actual Root stop fences new work, cancels the picker and
 * the copy, and waits for the whole operation before Root may be released.
 *
 * The destination is only a picked SAF document. The source is re-proved
 * against the live design state/root immediately before staging and again
 * immediately before writing; [DesignExportDeliveryResult.Delivered] is
 * returned only after a streamed read-back matches the receipt size and
 * SHA-256 exactly.
 */
internal class DesignExportDelivery(
    context: Context,
    private val workerScope: CoroutineScope,
) {
    companion object {
        const val PICK_TIMEOUT_MILLIS = 10 * 60 * 1000L
        const val RETIRE_TIMEOUT_MILLIS = 15_000L
    }

    private val applicationContext = context.applicationContext
    private val stagingRoot = File(applicationContext.cacheDir, "DesignExportScratch")
    private val backend = AndroidSafBackend(applicationContext)
    private val gateway = SafGatewayService(backend)

    val launchNamespace: String = PlatformLaunchOwnership.mintNamespace()

    private val deliveryMutex = Mutex()
    private val lock = Any()
    private var active: Active? = null
    private var stopping = false
    private var incarnationCounter = 0L

    private val mutablePending = MutableStateFlow<DesignPendingPick?>(null)
    val pendingPick: StateFlow<DesignPendingPick?> = mutablePending

    private sealed interface PickOutcome {
        data class Uri(val uriString: String, val flags: Int) : PickOutcome
        data object UserCancelled : PickOutcome
        data class HostCancelled(val reason: String) : PickOutcome
    }

    private class Active(
        val incarnation: Long,
        val spec: PickRequestSpec,
        val staged: File,
        val scratchDir: File,
        val expectedBytes: Long,
        val expectedSha: String,
        val captureKey: String,
        val cancel: SafCancelToken,
        val pending: CompletableDeferred<PickOutcome>,
        val settled: CompletableDeferred<Unit>,
    )

    /** A new accepted creative epoch may deliver again. */
    fun onNativeCreativeBound() {
        synchronized(lock) { stopping = false }
    }

    fun fenceForRootStop() {
        synchronized(lock) { stopping = true }
    }

    /**
     * The Root stop was aborted before native root release (a pending media
     * or design drain). The old Root is still bound, so design work may resume
     * on the same accepted generation; a later stop fences it again.
     */
    fun onNativeRootStopAborted() {
        synchronized(lock) { stopping = false }
    }

    fun completePick(incarnation: Long, uriString: String?, flags: Int) {
        val current = synchronized(lock) {
            active?.takeIf { it.incarnation == incarnation }
        } ?: return
        current.pending.complete(
            if (uriString.isNullOrBlank()) {
                PickOutcome.UserCancelled
            } else {
                PickOutcome.Uri(uriString, flags)
            },
        )
    }

    fun cancelPendingForUnmountedSurface(reason: String) {
        val current = synchronized(lock) { active } ?: return
        current.pending.complete(PickOutcome.HostCancelled(reason))
    }

    suspend fun retireForRootStop(
        timeoutMillis: Long = RETIRE_TIMEOUT_MILLIS,
    ): Boolean {
        val current = synchronized(lock) {
            stopping = true
            active
        }
        current?.pending?.complete(PickOutcome.HostCancelled("rootStop"))
        current?.cancel?.cancel()
        val deadline = System.currentTimeMillis() + timeoutMillis.coerceIn(0L, 60_000L)
        val acquired = withTimeoutOrNull(
            (deadline - System.currentTimeMillis()).coerceAtLeast(1L),
        ) {
            deliveryMutex.withLock { }
            true
        } ?: false
        if (!acquired) return false
        val settled = synchronized(lock) { active?.settled }
        return withTimeoutOrNull(1_000L) { settled?.await() } != null || settled == null
    }

    suspend fun deliver(
        capture: DesignArtifactAccess.DesignArtifactCapture,
        reverify: suspend () -> DesignArtifactAccess.DesignArtifactCapture,
    ): DesignExportDeliveryResult =
        workerScope.async { runDelivery(capture, reverify) }.await()

    private suspend fun runDelivery(
        capture: DesignArtifactAccess.DesignArtifactCapture,
        reverify: suspend () -> DesignArtifactAccess.DesignArtifactCapture,
    ): DesignExportDeliveryResult = withContext(Dispatchers.IO) {
        if (!deliveryMutex.tryLock()) {
            return@withContext DesignExportDeliveryResult.Refused(
                "designDeliveryBusy", retryable = true)
        }
        var scratchDir: File? = null
        var admitted: Active? = null
        try {
            if (synchronized(lock) { stopping }) {
                return@withContext DesignExportDeliveryResult.Refused("staleGeneration")
            }
            val fresh = try {
                reverify()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: CreativeException) {
                return@withContext DesignExportDeliveryResult.Refused(error.code, error.retryable)
            } catch (_: Throwable) {
                return@withContext DesignExportDeliveryResult.Refused("designOwnerUnverified")
            }
            if (fresh.key != capture.key) {
                return@withContext DesignExportDeliveryResult.Refused("designReceiptChanged")
            }
            val dir = File(stagingRoot, "export-${UUID.randomUUID()}")
            if (!dir.mkdirs() || !isWithin(stagingRoot, dir)) {
                return@withContext DesignExportDeliveryResult.Refused("designScratchUnavailable")
            }
            scratchDir = dir
            val part = File(dir, "payload.part")
            MediaWorkbenchExportProof.verifyAndStage(
                source = fresh.file,
                expectedBytes = fresh.byteCount,
                expectedSha256 = fresh.sha256,
                stagingTarget = part,
            ) ?: return@withContext DesignExportDeliveryResult.Refused("designOutputChanged")

            if (synchronized(lock) { stopping }) {
                return@withContext DesignExportDeliveryResult.Refused("staleGeneration")
            }
            val spec = try {
                gateway.grants.pickerForCreateDocument(fresh.mimeType, fresh.suggestedName)
            } catch (_: IllegalArgumentException) {
                return@withContext DesignExportDeliveryResult.Refused("invalidReceipt")
            }
            val incarnation = synchronized(lock) { ++incarnationCounter }
            val operation = Active(
                incarnation = incarnation,
                spec = spec,
                staged = part,
                scratchDir = dir,
                expectedBytes = fresh.byteCount,
                expectedSha = fresh.sha256,
                captureKey = fresh.key,
                cancel = SafCancelToken(),
                pending = CompletableDeferred(),
                settled = CompletableDeferred(),
            )
            synchronized(lock) {
                if (stopping || active != null) {
                    return@withContext DesignExportDeliveryResult.Refused(
                        if (stopping) "staleGeneration" else "designDeliveryBusy",
                        retryable = !stopping,
                    )
                }
                active = operation
                admitted = operation
                mutablePending.value = DesignPendingPick(
                    incarnation = incarnation,
                    spec = spec,
                    suggestedName = fresh.suggestedName,
                )
            }
            try {
                val outcome = withTimeoutOrNull(PICK_TIMEOUT_MILLIS) {
                    operation.pending.await()
                } ?: PickOutcome.HostCancelled("pickTimeout")
                if (synchronized(lock) { mutablePending.value?.incarnation == incarnation }) {
                    mutablePending.value = null
                }
                when (outcome) {
                    PickOutcome.UserCancelled -> DesignExportDeliveryResult.Cancelled
                    is PickOutcome.HostCancelled -> {
                        if (outcome.reason == "rootStop") {
                            DesignExportDeliveryResult.Refused("staleGeneration")
                        } else {
                            DesignExportDeliveryResult.Refused("designPickCancelled")
                        }
                    }
                    is PickOutcome.Uri -> {
                        // Fresh owner/root/byte proof immediately before the
                        // destination write. A revoked epoch cannot copy stale
                        // design bytes into a just-picked document.
                        val beforeWrite = try {
                            reverify()
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: CreativeException) {
                            return@withContext DesignExportDeliveryResult.Refused(
                                error.code, error.retryable)
                        } catch (_: Throwable) {
                            return@withContext DesignExportDeliveryResult.Refused(
                                "designOwnerUnverified")
                        }
                        if (beforeWrite.key != operation.captureKey) {
                            return@withContext DesignExportDeliveryResult.Refused(
                                "designReceiptChanged")
                        }
                        writeVerified(operation, outcome.uriString, outcome.flags)
                    }
                }
            } finally {
                if (synchronized(lock) { mutablePending.value?.incarnation == incarnation }) {
                    mutablePending.value = null
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            DesignExportDeliveryResult.Refused(
                (error as? CreativeException)?.code ?: "designDeliveryFailed")
        } finally {
            if (scratchDir != null) deleteScratch(scratchDir)
            synchronized(lock) {
                if (admitted != null && active === admitted) active = null
            }
            admitted?.settled?.complete(Unit)
            deliveryMutex.unlock()
        }
    }

    private suspend fun writeVerified(
        operation: Active,
        uriString: String,
        flags: Int,
    ): DesignExportDeliveryResult {
        if (synchronized(lock) { stopping } || operation.cancel.isCancelled) {
            return DesignExportDeliveryResult.Refused("staleGeneration")
        }
        val accepted = gateway.grants.acceptPickResult(operation.spec, uriString, flags)
        when (accepted) {
            is PickAcceptResult.Cancelled -> return DesignExportDeliveryResult.Cancelled
            is PickAcceptResult.Rejected -> return DesignExportDeliveryResult.Refused("pickRejected")
            is PickAcceptResult.Accepted -> Unit
        }
        val granted = accepted as PickAcceptResult.Accepted
        if (!granted.granted.contains(SafAccessFlag.READ) ||
            !granted.granted.contains(SafAccessFlag.WRITE)
        ) {
            return DesignExportDeliveryResult.Refused("writeGrantMissing")
        }
        val evidence = try {
            gateway.grants.currentAccess(granted.uri)
        } catch (_: Throwable) {
            null
        }
        val readLive = evidence?.let { it.read && it.probeRead != ProbeFlag.DENIED } ?: false
        val writeLive = evidence?.let { it.write && it.probeWrite != ProbeFlag.DENIED } ?: false
        if (!readLive || !writeLive) {
            return DesignExportDeliveryResult.Refused("designGrantNotLive")
        }
        val target = SafDocumentRef(
            tree = null,
            documentId = null,
            parentDocumentId = null,
            uri = granted.uri,
        )
        var written = 0L
        val readLease = SharedUriGrantAuthority.broker.retain(granted.uri, SafAccessFlag.READ)
        val writeLease = SharedUriGrantAuthority.broker.retain(granted.uri, SafAccessFlag.WRITE)
        try {
            when (val open = backend.openWriteTruncate(target, operation.cancel)) {
                is WriteOpen.UnsupportedMode ->
                    return DesignExportDeliveryResult.Refused("writeUnsupported")
                is WriteOpen.NotFound ->
                    return DesignExportDeliveryResult.Refused("destinationNotFound")
                is WriteOpen.Opened -> {
                    try {
                        FileInputStream(operation.staged).use { input ->
                            open.output.use { output ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    operation.cancel.ensureActive()
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    output.write(buffer, 0, read)
                                    written += read
                                }
                                output.flush()
                            }
                        }
                    } catch (_: SafCancelledException) {
                        return if (written == 0L && deleteOwnedEmptyDestination(target)) {
                            DesignExportDeliveryResult.Cancelled
                        } else {
                            DesignExportDeliveryResult.Refused("designCancelledPartial")
                        }
                    } catch (_: IOException) {
                        return DesignExportDeliveryResult.Refused("designWriteFailed")
                    }
                }
            }
            if (written != operation.expectedBytes) {
                return DesignExportDeliveryResult.Refused("designLengthMismatch")
            }
            val readback = gateway.operations.streamRead(
                target,
                operation.expectedBytes,
                null,
                operation.cancel,
            ) { _, _ -> }
            return when (readback) {
                is SafOutcome.Failure -> {
                    if (readback.failure == SafFailure.Cancelled) {
                        DesignExportDeliveryResult.Refused("designCancelledPartial")
                    } else {
                        DesignExportDeliveryResult.Refused("designVerifyUnavailable")
                    }
                }
                is SafOutcome.Success -> {
                    val summary = readback.value
                    if (!summary.completed ||
                        summary.bytes != operation.expectedBytes ||
                        !summary.sha256.equals(operation.expectedSha, ignoreCase = true)
                    ) {
                        DesignExportDeliveryResult.Refused("designVerifyMismatch")
                    } else {
                        DesignExportDeliveryResult.Delivered(
                            byteCount = summary.bytes,
                            sha256 = summary.sha256.lowercase(),
                        )
                    }
                }
            }
        } finally {
            writeLease.release()
            readLease.release()
        }
    }

    private fun deleteOwnedEmptyDestination(target: SafDocumentRef): Boolean = try {
        gateway.operations.deleteDocument(target, SafCancelToken()) is SafOutcome.Success
    } catch (_: Throwable) {
        false
    }

    private fun isWithin(root: File, candidate: File): Boolean = runCatching {
        val base = root.canonicalFile.path
        val path = candidate.canonicalFile.path
        path.startsWith(base + File.separator) && path != base
    }.getOrDefault(false)

    private fun deleteScratch(directory: File) {
        if (!isWithin(stagingRoot, directory)) return
        runCatching {
            directory.listFiles()?.forEach { it.delete() }
            directory.delete()
        }
    }
}

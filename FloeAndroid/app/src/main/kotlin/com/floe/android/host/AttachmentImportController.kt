// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.R
import com.floe.android.bridge.AttachmentStagingNative
import com.floe.android.bridge.AttachmentStagingNativeException
import com.floe.android.feature.conversation.AttachmentImportUi
import com.floe.android.feature.conversation.AttachmentKindUi
import com.floe.android.feature.conversation.AttachmentOpenRequest
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.StagedAttachmentUi
import java.security.MessageDigest
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * App-host attachment import/staging ownership over the REAL native producer
 * (MAIN_APP_ATTACHMENT_NATIVE_BINDING_DECISION_20261019).
 *
 * What changed from the retired legacy controller:
 *  * NO second app-side filesDir staging backend and NO host-chosen
 *    filename/path on the wire — ContentResolver bytes stream through the
 *    trusted native byte channel (`routeOpen/begin/write/end/abort`), and
 *    the ONLY native staging authority is the opaque ingress/staging
 *    receipt space minted by the host (`sing:v1:` / `stag:v1:`).
 *  * Ready/sendable is published ONLY after the native `attachment.stage`
 *    command's effect terminal accepts — a delayed/refused/failed native
 *    operation stays pending/failed; there is no premature Ready and no
 *    auto-send.
 *  * The picker launch owner is CAPTURED immutably: a result arriving for a
 *    superseded launcher (navigation/new request) is dropped without IO,
 *    binding or state writes. Recomposition/background/lock is not
 *    navigation — only a newer requestPicker replaces the owner.
 *  * Scoped READ grant only, taken solely when the platform offers
 *    persistable read access as a justified user import; no blanket
 *    READ|WRITE request. The per-file bound mirrors the native
 *    128 MiB cap (the native side enforces its own caps regardless).
 *
 * Root ownership (this batch): a picker request is issued for EITHER an
 * existing conversation session OR the client-RAM Home draft (a real
 * `conversationId = null` compose route — the bridge documents it as the
 * new-conversation composer: a valid host route exists before any run, and
 * NO durable empty conversation is ever created just to open the picker or
 * stage files before C1). The delivered result carries the EXACT ISSUED
 * REQUEST; two picker requests on the same conversation (or the same Home
 * generation) have different incarnations, so a late OLD result can never
 * clear another request/draft, navigate an old task, create a header row or
 * mutate a replacement Home. Draft-owned staged rows flow to
 * `RootWorkspaceController` (which the Home first send hands to the created
 * holder under the one-writer C1); conversation-owned rows keep the existing
 * holder projection path.
 *
 * The staged bytes are consumed by the run owner through the ORIGINAL atomic
 * `RunLaunchStore.prepare`; arrival never auto-sends.
 */
class AttachmentImportController internal constructor(
    private val host: RuntimeHost,
) {
    /**
     * Picker presentation requests (host → composition glue). The launcher
     * identity is immutable: [incarnation] invalidates stale results, and
     * the root half ([session] XOR [draftNonce]) states exactly WHOSE
     * ownership the pick belongs to. A draft pick carries the client Home
     * draft nonce + the service-owned Home generation it was issued on;
     * neither is a persisted task id.
     */
    data class PickerRequest(
        val session: ConversationSessionToken?,
        val incarnation: Long,
        val draftNonce: String? = null,
        val draftHomeGeneration: Long = -1L,
    ) {
        init {
            require((session == null) == (draftNonce != null)) {
                "a picker request is owned by exactly one root (session XOR draft)"
            }
        }

        val isDraftOwned: Boolean get() = draftNonce != null
    }

    /** The immutable ownership descriptor for ONE staging route (a settled
     * pick or its retry). Exactly one half is set: a conversation session
     * with its exact epoch, or the client Home draft nonce with the
     * service-owned Home generation the pick was issued on. */
    private class StageOwner(
        val session: ConversationSessionToken?,
        val draftNonce: String?,
        val draftHomeGeneration: Long,
    ) {
        val isDraftOwned: Boolean get() = session == null && draftNonce != null
        val cancelled = AtomicBoolean(false)
        val input = AtomicReference<InputStream?>(null)
        val job = AtomicReference<Job?>(null)
        val ingress = AtomicReference<String?>(null)
        val retrying = AtomicBoolean(false)
        /** Exactly-once route release. The native `attachment.stage` publish
         *  requires the ingress AND its route live (native refuses
         *  `routeStale`, and closeRoute aborts the route's
         *  finished-but-unpublished ingresses), so the route stays OPEN
         *  through the whole asynchronous publication and is closed by
         *  exactly one terminal path: publish terminal, cancel, or a copy
         *  that never submitted. */
        val routeClosed = AtomicBoolean(false)
        @Volatile var sourceUri: Uri? = null
        @Volatile var stagingId: String? = null
        @Volatile var rootEpoch: Long? = null
    }

    /** The native producer byte channel — the ONE seam tests inject. */
    internal interface StagingChannel {
        fun routeOpen(
            conversationId: String?,
            incarnation: Long,
            draftRevision: Long,
            isTemporary: Boolean,
        ): String
        fun routeClose(routeReceipt: String)
        /** Returns "<ingressReceipt> <stagingId>" (two native-minted tokens). */
        fun begin(routeReceipt: String, reusingStagingId: String?): String
        fun write(ingressReceipt: String, data: ByteArray, offset: Int, length: Int)
        fun end(ingressReceipt: String, displayNameHint: String?, mimeTypeHint: String?)
        fun abort(ingressReceipt: String)
    }

    /** Production channel: the REAL native producer JNI surface. */
    private object NativeStagingChannel : StagingChannel {
        override fun routeOpen(
            conversationId: String?,
            incarnation: Long,
            draftRevision: Long,
            isTemporary: Boolean,
        ): String = AttachmentStagingNative.stagingRouteOpen(
            conversationId, incarnation, draftRevision, isTemporary)

        override fun routeClose(routeReceipt: String) =
            AttachmentStagingNative.stagingRouteClose(routeReceipt)

        override fun begin(routeReceipt: String, reusingStagingId: String?): String =
            AttachmentStagingNative.stagingBegin(routeReceipt, reusingStagingId)

        override fun write(ingressReceipt: String, data: ByteArray, offset: Int, length: Int) =
            AttachmentStagingNative.stagingWrite(ingressReceipt, data, offset, length)

        override fun end(ingressReceipt: String, displayNameHint: String?, mimeTypeHint: String?) =
            AttachmentStagingNative.stagingEnd(ingressReceipt, displayNameHint, mimeTypeHint)

        override fun abort(ingressReceipt: String) =
            AttachmentStagingNative.stagingAbort(ingressReceipt)
    }

    internal var channel: StagingChannel = NativeStagingChannel

    /**
     * One RESOLVED importable content source. This is the pure content-
     * resolution seam: the production [sourceResolver] reads ONLY through
     * ContentResolver, while JVM tests substitute in-memory sources (a null
     * [uri]) so the whole native-producer staging lifecycle — route open →
     * ingress begin/write/end → asynchronous `attachment.stage` publication
     * → owned route close — runs without android framework stubs. The
     * staging authority (route/ingress receipts, staging ids, handles) stays
     * entirely native; this carrier only describes the picked bytes.
     */
    internal class AttachmentSource(
        /** The platform URI, null ONLY for substituted test sources. */
        val uri: Uri?,
        val scheme: String,
        val authority: String?,
        val displayName: String,
        val mimeType: String,
        /** Declared size from the provider, -1 when unknown. */
        val declaredSize: Long,
        val openStream: () -> InputStream?,
    )

    /** Resolves a platform picker [Uri] into an [AttachmentSource]. Runs on
     *  the IO copy dispatcher; never mints identity — it only describes
     *  bytes the native producer then ingests. */
    internal var sourceResolver: (Uri) -> AttachmentSource = { uri -> resolveSource(uri) }

    private fun resolveSource(uri: Uri): AttachmentSource {
        val context: Context = host.appContext
        var displayName = uri.lastPathSegment ?: "attachment"
        var declaredSize = -1L
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIndex >= 0) cursor.getString(nameIndex)?.let { displayName = it }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        declaredSize = cursor.getLong(sizeIndex)
                    }
                }
            }
        }
        val mimeType = runCatching { context.contentResolver.getType(uri) }
            .getOrNull() ?: "application/octet-stream"
        return AttachmentSource(
            uri = uri,
            scheme = uri.scheme.orEmpty(),
            authority = uri.authority,
            displayName = displayName,
            mimeType = mimeType,
            declaredSize = declaredSize,
            openStream = {
                runCatching { context.contentResolver.openInputStream(uri) }.getOrNull()
            },
        )
    }

    private val pickerRequestFlow = MutableStateFlow<PickerRequest?>(null)
    val pickerRequest: StateFlow<PickerRequest?> = pickerRequestFlow

    private val launcherIncarnation = AtomicLong(0)

    /** Opaque per-host-generation launch namespace for the composition
     *  picker lane (MAIN_ANDROID_PLATFORM_LAUNCH_OWNERSHIP_20261021). The
     *  picker glue persists `namespace:incarnation` for the ONE picker it
     *  launched and only dispatches a callback whose saved namespace still
     *  matches THIS generation — a counter reset after process death can
     *  then never bind a restored pre-death callback to a new request.
     *  Carries no URI, secret, user content or permission state. */
    internal val launchNamespace: String = PlatformLaunchOwnership.mintNamespace()

    /** RAM-only ownership bookkeeping (never persisted). Keyed by the
     *  NATIVE staging id — the host never mints attachment identities.
     *  [draftNonce] non-null (with [session] null) marks a Home-draft-owned
     *  row: staged before C1, handed to the launch by RootWorkspaceController. */
    private data class StagingEntry(
        val session: ConversationSessionToken?,
        val draftNonce: String?,
        val draftHomeGeneration: Long,
        val sourceUri: Uri?,
        val staged: StagedAttachmentUi,
        val routeReceipt: String,
        val ingressReceipt: String,
        val stagingHandle: String?,
        val attempt: StageOwner,
    )

    private val entries = ConcurrentHashMap<String, StagingEntry>()
    private val copies = ConcurrentHashMap<StageOwner, Unit>()
    private val cleanupJobs = ConcurrentHashMap<Job, Unit>()
    private val readGrantLeases = ConcurrentHashMap<Uri, com.floe.android.safgateway.SafSharedGrantBroker.Lease>()
    private val stopped = AtomicBoolean(false)

    companion object {
        /** Mirrors the native per-file cap (AttachmentStagingLimits in the
         *  shared core). Oversized imports are refused typed BEFORE streaming;
         *  the native side enforces its own caps regardless. */
        const val MAX_STAGING_BYTES = 128L * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024

        /** Presentation owner marker for a Home-draft staged row. This is a
         *  CLIENT RAM nonce (never a persisted/DB task identity): the first
         *  send replaces it with the real conversation ownership. */
        const val DRAFT_OWNER_PREFIX = "home-draft:"
    }

    internal fun start() { stopped.set(false) }
    internal suspend fun stop() {
        stopped.set(true)
        cancelPicker()
        val attempts = (copies.keys + entries.values.map { it.attempt }).distinct()
        attempts.forEach(::cancelCopy)
        attempts.mapNotNull { it.job.get() }.forEach { it.join() }
        entries.keys.toList().forEach(::discardEntry)
        readGrantLeases.keys.toList().forEach(::releaseScopedReadIfUnused)
        cleanupJobs.keys.toList().forEach { it.join() }
    }

    private fun admitted(): Boolean = !stopped.get() && host.readiness.value.attachmentStagingAdmitted

    private fun ownerIsCurrent(owner: StageOwner): Boolean {
        if (!admitted() || owner.cancelled.get()) return false
        return owner.session?.let { host.conversations.attachmentSessionIsCurrent(it) }
            ?: (host.conversations.rootWorkspace.currentDraftOwner() ==
                (owner.draftNonce to owner.draftHomeGeneration))
    }

    private suspend fun ensureOwner(owner: StageOwner) {
        currentCoroutineContext().ensureActive()
        if (!ownerIsCurrent(owner) || host.nativeRootEpoch() != owner.rootEpoch) {
            throw CancellationException("attachment_owner_changed")
        }
    }

    private fun cancelCopy(owner: StageOwner) {
        val first = owner.cancelled.compareAndSet(false, true)
        owner.job.get()?.cancel()
        val input = owner.input.getAndSet(null)
        val ingress = owner.ingress.get()
        if (!first && input == null) return
        launchCleanup {
            input?.let { runCatching { it.close() } }
            ingress?.let { runCatching { channel.abort(it) } }
        }
    }

    private fun launchCleanup(action: () -> Unit) {
        val job = host.scope.launch(host.ioDispatcher, start = CoroutineStart.LAZY) { action() }
        cleanupJobs[job] = Unit
        job.invokeOnCompletion { cleanupJobs.remove(job) }
        job.start()
    }

    private fun startCopy(owner: StageOwner, uri: Uri, replacingId: String? = null) {
        SharedUriGrantAuthority.withExclusiveAuthority { owner.sourceUri = uri; copies[owner] = Unit }
        // Resolution itself stays on the IO copy dispatcher (deferred through
        // the provider), never on the picker's calling thread.
        startCopyCore(owner, replacingId) {
            // Retain/check/take before metadata or stream IO; a second feature
            // cannot drop the shared OS grant between those steps.
            SharedUriGrantAuthority.withExclusiveAuthority {
                if (!readGrantLeases.containsKey(uri)) {
                    readGrantLeases[uri] = SharedUriGrantAuthority.acquireRead(host.appContext.contentResolver, uri)
                }
            }
            sourceResolver(uri)
        }
    }

    /** Test seam for one owned staging attempt (mirrors the exact session /
     *  draft ownership a picker result carries; the picker-capture lane is
     *  exercised on-device, this drives the producer lifecycle). Stages a
     *  substituted in-memory source under REAL root ownership without a
     *  platform picker round or framework types; the native producer
     *  contract exercised here is byte-for-byte the production one, only
     *  the byte source differs. */
    internal fun stageSubstitutedSource(
        session: ConversationSessionToken?,
        draftNonce: String?,
        draftHomeGeneration: Long,
        source: AttachmentSource,
    ) {
        val owner = StageOwner(session, draftNonce, draftHomeGeneration)
        SharedUriGrantAuthority.withExclusiveAuthority { owner.sourceUri = source.uri; copies[owner] = Unit }
        startCopyCore(owner, null) { source }
    }

    private fun startCopyCore(
        owner: StageOwner,
        replacingId: String?,
        sourceProvider: () -> AttachmentSource,
    ) {
        val replacedAttempt = replacingId?.let { entries[it]?.attempt }
        val job = host.scope.launch(host.ioDispatcher, start = CoroutineStart.LAZY) {
            try {
                when (val result = stageThroughNativeProducer(owner, sourceProvider(), replacingId)) {
                    is StageResult.Failed -> publishCopyFailure(owner, result.reason)
                    is StageResult.Staged -> Unit
                }
            } catch (_: CancellationException) {
                cancelCopy(owner)
            } catch (_: Exception) {
                publishCopyFailure(owner, "source_unreadable")
            } finally {
                SharedUriGrantAuthority.withExclusiveAuthority { copies.remove(owner) }
                if (owner.cancelled.get()) {
                    owner.stagingId?.let { id ->
                        entries[id]?.takeIf { it.attempt === owner }?.let {
                            cancelInternal(it.session, it.draftNonce, id)
                        }
                    }
                }
                owner.sourceUri?.let(::releaseScopedReadIfUnused)
                replacedAttempt?.retrying?.set(false)
            }
        }
        owner.job.set(job)
        job.invokeOnCompletion {
            SharedUriGrantAuthority.withExclusiveAuthority { copies.remove(owner) }
            replacedAttempt?.retrying?.set(false)
        }
        job.start()
    }

    private fun publishCopyFailure(owner: StageOwner, reason: String) = synchronized(owner) {
        if (!ownerIsCurrent(owner)) return@synchronized
        val id = owner.stagingId
        val entry = id?.let { entries[it] }
        if (id != null && entry != null && entry.attempt === owner) {
            val failure = AttachmentImportUi.Failed(failureMessage(reason))
            entries[id] = entry.copy(staged = entry.staged.copy(import = failure))
            publishProgress(owner.session, owner.draftNonce, id, failure)
        } else if (owner.session != null) {
            host.conversations.onAttachmentImportFailed(owner.session, reason)
        } else if (owner.draftNonce != null) {
            host.conversations.rootWorkspace.onDraftAttachmentFailed(owner.draftNonce)
        }
    }

    internal fun failureMessage(reason: String): String = try {
        host.appContext.getString(when (reason) {
            "attachment_too_large" -> R.string.attachment_import_too_large_notice
            "storage_full" -> R.string.integrations_storage_full
            else -> R.string.attachment_import_failed_notice
        })
    } catch (_: RuntimeException) { "attachment_unavailable" }

    // ---------------------------------------------------------------- picker

    fun requestPicker(session: ConversationSessionToken) {
        if (!admitted()) return
        // Capture the immutable launch owner: any result not matching THIS
        // incarnation is a stale/foreign result and is dropped without IO.
        pickerRequestFlow.value = PickerRequest(
            session = session,
            incarnation = launcherIncarnation.incrementAndGet(),
        )
    }

    /** Home-draft pick: issued for the CURRENT service-owned Home generation
     * under the caller-provided client RAM nonce. The compose route is
     * `conversationId = null` — no durable row is created (⇄ bridge: "a
     * valid host route exists before any run; no fabricated conversation").
     * Returns false (nothing started) when staging is not admitted or the
     * draft surface identity is missing; the caller shows an honest state. */
    fun requestDraftPicker(draftNonce: String, draftHomeGeneration: Long): Boolean {
        if (!admitted()) return false
        if (draftNonce.isBlank() || draftHomeGeneration < 0L) return false
        pickerRequestFlow.value = PickerRequest(
            session = null,
            incarnation = launcherIncarnation.incrementAndGet(),
            draftNonce = draftNonce,
            draftHomeGeneration = draftHomeGeneration,
        )
        return true
    }

    fun cancelPicker() {
        // Invalidate the current launcher without fabricating a new owner.
        launcherIncarnation.incrementAndGet()
        pickerRequestFlow.value = null
    }

    /**
     * Composition glue delivers the platform picker result here WITH THE
     * EXACT ISSUED REQUEST (never a re-read of a replacement request at
     * result time). A result for a superseded launcher — newer request,
     * cancel, or a replacement Home generation — is dropped without IO,
     * binding or any state write; it never clears the CURRENT request or
     * draft either. A null uri settles only the still-current issued
     * request's own cancel.
     */
    fun onPickerResult(request: PickerRequest, uri: Uri?) {
        val pending = pickerRequestFlow.value ?: return
        // Exact-owner validation: the CURRENT request must be identical to
        // the ISSUED one — same root (session epoch OR draft nonce +
        // generation) AND the same launcher incarnation. Two picks on the
        // SAME conversation have different incarnations, so a late result
        // for oldA can never attach to newB (the original result-time
        // re-read defect this closes).
        if (pending != request) return
        launcherIncarnation.incrementAndGet()
        pickerRequestFlow.value = null
        if (uri == null) return // the user cancelled THIS request: nothing staged
        if (!admitted()) return
        // The staged row appears only via onAttachmentStaged after the native
        // stage terminal accepts (the presentation row is host-added; there is
        // deliberately no pre-stage row, so no progress event is emitted here).
        startCopy(StageOwner(request.session, request.draftNonce, request.draftHomeGeneration), uri)
    }

    // ------------------------------------------------------------ native copy

    private sealed interface StageResult {
        data class Staged(val stagingId: String) : StageResult
        data class Failed(val reason: String) : StageResult
    }

    private suspend fun stageThroughNativeProducer(
        owner: StageOwner,
        source: AttachmentSource,
        replacingId: String? = null,
    ): StageResult = withContext(Dispatchers.IO) {
        if (source.scheme != "content" || source.authority.isNullOrBlank()) {
            return@withContext StageResult.Failed("source_unreadable")
        }
        owner.rootEpoch = host.nativeRootEpoch()?.takeIf { it > 0 }
            ?: return@withContext StageResult.Failed("stage_refused")
        ensureOwner(owner)
        val displayName = source.displayName.ifBlank { "attachment" }
        val declaredSize = source.declaredSize
        ensureOwner(owner)
        if (declaredSize > MAX_STAGING_BYTES) return@withContext StageResult.Failed("attachment_too_large")
        val mimeType = source.mimeType.ifBlank { "application/octet-stream" }
        var routeReceipt: String? = null
        var ingressReceipt: String? = null
        var submittedForPublication = false
        try {
            // Home generations legitimately start at zero; the native route
            // contract requires a strictly positive incarnation. Preserve the
            // exact Home generation for ownership and map it injectively here.
            val routeIncarnation = owner.session?.sessionEpoch ?: run {
                if (owner.draftHomeGeneration == Long.MAX_VALUE) {
                    return@withContext StageResult.Failed("stage_refused")
                }
                owner.draftHomeGeneration + 1L
            }
            if (routeIncarnation <= 0L) return@withContext StageResult.Failed("stage_refused")
            routeReceipt = channel.routeOpen(
                conversationId = owner.session?.conversationId,
                incarnation = routeIncarnation,
                draftRevision = 0L,
                isTemporary = false,
            )
            ensureOwner(owner)
            val tokens = channel.begin(routeReceipt, null).split(" ")
            if (tokens.size != 2 || tokens.any { it.isBlank() }) {
                return@withContext StageResult.Failed("stage_refused")
            }
            ingressReceipt = tokens[0]
            owner.ingress.set(ingressReceipt)
            val stagingId = tokens[1]
            owner.stagingId = stagingId
            ensureOwner(owner)
            val ownerMarker = owner.session?.conversationId ?: "$DRAFT_OWNER_PREFIX${owner.draftNonce}"
            val pending = StagedAttachmentUi(
                id = stagingId, displayName = displayName, mimeType = mimeType,
                kind = kindFor(mimeType), byteCount = 0L, sha256 = "",
                ownerConversationId = ownerMarker, import = AttachmentImportUi.InProgress(null),
            )
            val initial = StagingEntry(
                session = owner.session, draftNonce = owner.draftNonce,
                draftHomeGeneration = owner.draftHomeGeneration, sourceUri = source.uri,
                staged = pending, routeReceipt = routeReceipt,
                ingressReceipt = ingressReceipt, stagingHandle = null, attempt = owner,
            )
            if (entries.putIfAbsent(stagingId, initial) != null) {
                return@withContext StageResult.Failed("stage_refused")
            }
            synchronized(owner) {
                if (ownerIsCurrent(owner)) {
                    replacingId?.let { oldId ->
                        entries.remove(oldId)
                        publishRemoved(owner.session, owner.draftNonce, oldId)
                    }
                    // The native id is real, but the digest/Ready proof do NOT
                    // exist yet. This processing row makes real cancellation reachable.
                    publishStaged(owner.session, owner.draftNonce, pending)
                }
            }
            ensureOwner(owner)
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            var lastPercent = -1
            val buffer = ByteArray(CHUNK_BYTES)
            source.openStream()?.use { input ->
                owner.input.set(input)
                try {
                    while (true) {
                        ensureOwner(owner)
                        val read = input.read(buffer)
                        ensureOwner(owner)
                        if (read < 0) break
                        if (read == 0) throw java.io.IOException("source_unreadable")
                        if (total + read > MAX_STAGING_BYTES) {
                            channel.abort(ingressReceipt)
                            return@withContext StageResult.Failed("attachment_too_large")
                        }
                        channel.write(ingressReceipt, buffer, 0, read)
                        digest.update(buffer, 0, read)
                        total += read
                        if (declaredSize > 0) {
                            val percent = ((total * 100L) / declaredSize).coerceIn(0L, 99L).toInt()
                            if (percent > lastPercent) {
                                lastPercent = percent
                                synchronized(owner) {
                                    if (ownerIsCurrent(owner) && entries[stagingId]?.attempt === owner) {
                                        publishProgress(owner.session, owner.draftNonce, stagingId,
                                            AttachmentImportUi.InProgress(percent / 100f))
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    owner.input.compareAndSet(input, null)
                }
            } ?: return@withContext StageResult.Failed("source_unreadable")
            if (total == 0L) return@withContext StageResult.Failed("source_unreadable")
            ensureOwner(owner)
            channel.end(ingressReceipt, displayName, mimeType)
            ensureOwner(owner)
            val staged = pending.copy(
                byteCount = total,
                sha256 = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) },
                import = AttachmentImportUi.InProgress(1f),
            )
            synchronized(owner) {
                if (ownerIsCurrent(owner)) {
                    entries.computeIfPresent(stagingId) { _, entry ->
                        if (entry.attempt === owner) entry.copy(staged = staged) else entry
                    }
                    if (entries[stagingId]?.attempt === owner) publishStaged(owner.session, owner.draftNonce, staged)
                }
            }
            ensureOwner(owner)
            submitStage(owner.session, owner.draftNonce, stagingId, ingressReceipt, staged)
            submittedForPublication = true
            StageResult.Staged(stagingId)
        } catch (cancel: CancellationException) {
            cancelCopy(owner)
            throw cancel
        } catch (native: AttachmentStagingNativeException) {
            StageResult.Failed(reasonFor(native.status))
        } catch (_: Exception) {
            StageResult.Failed("source_unreadable")
        } finally {
            // EOF must settle before publication. A failed copy retains only
            // its recoverable source/Failed row; partial ingress is aborted.
            // ROUTE LIFETIME (R8 real App failure): when publication was
            // submitted, the route must stay OPEN — the asynchronous native
            // `attachment.stage` publish refuses a stale route and the
            // native closeRoute aborts the route's finished-but-unpublished
            // ingress, so closing here (before the terminal arrives) aborts
            // the very ingress the publish reads. Route ownership transfers
            // to the terminal/cancel paths (closeOwnedRoute). Only a copy
            // that never submitted (or was cancelled inline) closes here.
            if (!submittedForPublication || owner.cancelled.get()) {
                ingressReceipt?.let { runCatching { channel.abort(it) } }
                closeOwnedRoute(owner, routeReceipt)
            }
        }
    }

    /** Release exactly the route this attempt opened. Idempotent across
     *  every terminal path (publish terminal, cancel, retry replacement,
     *  host stop); the native close runs off the caller's attempt lock.
     *  A failed/never-opened route is a no-op. */
    private fun closeOwnedRoute(owner: StageOwner, routeReceipt: String?) {
        if (routeReceipt == null) return
        if (!owner.routeClosed.compareAndSet(false, true)) return
        launchCleanup { runCatching { channel.routeClose(routeReceipt) } }
    }

    private fun kindFor(mimeType: String): AttachmentKindUi = when {
        mimeType.startsWith("image/") -> AttachmentKindUi.IMAGE
        mimeType.startsWith("audio/") -> AttachmentKindUi.AUDIO
        mimeType.startsWith("text/") || mimeType == "application/pdf" ->
            AttachmentKindUi.DOCUMENT
        else -> AttachmentKindUi.OTHER
    }

    private fun reasonFor(status: Int): String = when (status) {
        -307 -> "attachment_too_large"
        -308 -> "attachment_too_large"
        -309 -> "storage_full"
        -313 -> "stage_refused"
        -314 -> "stage_refused"
        else -> "source_unreadable"
    }

    /** Publish the staged ingress with the native `attachment.stage`
     *  command. `Ready` is published ONLY when the effect terminal accepts;
     *  a refused/failed/delayed operation stays pending/failed. */
    private fun submitStage(
        session: ConversationSessionToken?,
        draftNonce: String?,
        stagingId: String,
        ingressReceipt: String,
        staged: StagedAttachmentUi,
    ) {
        val submittedEntry = entries[stagingId] ?: return
        val owner = submittedEntry.attempt
        val submittedRoute = submittedEntry.routeReceipt
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.stage",
                scope = HostScope.ApplicationConfiguration("attachmentStaging"),
                stateful = false,
                correlationID = host.commandClient.correlationID("astage"),
                payload = JsonObject(mapOf("ingressReceipt" to JsonPrimitive(ingressReceipt))),
            ),
        ) { outcome ->
            // Native root readback is off-main. The attempt lock serializes
            // publication with removal/cancellation, not with file copying.
            host.scope.launch(host.ioDispatcher) {
                val sameRoot = host.nativeRootEpoch() == owner.rootEpoch
                // Attachment commands use the frozen identifier-only detail
                // carrier, not the object value slot. Bind the returned handle
                // to this attempt's exact native staging identity.
                val handle = if (outcome is HostOperationOutcome.Completed &&
                    outcome.detail["result"] == "accepted" &&
                    outcome.detail["stagingID"] == stagingId
                ) {
                    outcome.detail["stagingHandle"]?.takeIf { it.isNotBlank() }
                } else null
                var discardLateHandle = false
                synchronized(owner) {
                    val entry = entries[stagingId]
                    if (entry?.attempt !== owner) {
                        // Publication can commit before cancellation while its
                        // success callback arrives after removal. Cancel-ingress
                        // cannot release an already published record.
                        discardLateHandle = sameRoot && handle != null
                        return@synchronized
                    }
                    if (!sameRoot || !ownerIsCurrent(owner)) {
                        cancelInternal(session, draftNonce, stagingId)
                        discardLateHandle = sameRoot && handle != null
                        return@synchronized
                    }
                    if (handle != null) {
                        val ready = staged.copy(import = AttachmentImportUi.Ready)
                        entries[stagingId] = entry.copy(stagingHandle = handle, staged = ready)
                        publishStaged(session, draftNonce, ready)
                    } else {
                        val reason = when (outcome) {
                            is HostOperationOutcome.Rejected -> outcome.code
                            is HostOperationOutcome.Failed -> outcome.code
                            is HostOperationOutcome.Completed -> outcome.detail["code"] ?: "stage_refused"
                            else -> "stage_refused"
                        }
                        publishCopyFailure(owner, reason)
                    }
                }
                if (discardLateHandle && handle != null) discardNativeHandle(handle)
                closeOwnedRoute(owner, submittedRoute)
            }
        }
    }

    private fun publishStaged(
        session: ConversationSessionToken?,
        draftNonce: String?,
        staged: StagedAttachmentUi,
    ) {
        if (session != null) {
            host.conversations.onAttachmentStaged(session, staged)
        } else if (draftNonce != null) {
            host.conversations.rootWorkspace.onDraftAttachmentStaged(draftNonce, staged)
        }
    }

    private fun publishProgress(
        session: ConversationSessionToken?,
        draftNonce: String?,
        stagingId: String,
        import: AttachmentImportUi,
    ) {
        if (session != null) {
            host.conversations.onAttachmentProgress(session, stagingId, import)
        } else if (draftNonce != null) {
            host.conversations.rootWorkspace.onDraftAttachmentProgress(draftNonce, stagingId, import)
        }
    }

    // -------------------------------------------------------------- controls

    fun retry(session: ConversationSessionToken, stagingId: String): Boolean =
        retryInternal(session, null, stagingId)

    /** Retry a draft-owned failed row from the SAME recoverable source
     *  receipt (the entry keeps the picked URI; the staged bytes for any
     *  earlier attempt were aborted/typed-failed, so this re-issues the
     *  real copy+stage under the ENTRY's actual ownership — exact session
     *  epoch / draft nonce + Home generation, never a synthesized identity). */
    fun retryDraft(draftNonce: String, stagingId: String): Boolean =
        retryInternal(null, draftNonce, stagingId)

    private fun retryInternal(
        session: ConversationSessionToken?,
        draftNonce: String?,
        stagingId: String,
    ): Boolean {
        val entry = entries[stagingId] ?: return false
        if (entry.session != session || entry.draftNonce != draftNonce) return false
        if (entry.staged.import !is AttachmentImportUi.Failed || !admitted()) return false
        if (session != null && !host.conversations.attachmentSessionIsCurrent(session)) return false
        if (draftNonce != null && host.conversations.rootWorkspace.currentDraftOwner() !=
            (draftNonce to entry.draftHomeGeneration)) return false
        val uri = entry.sourceUri ?: return false
        if (!entry.attempt.retrying.compareAndSet(false, true)) return false
        // Preserve the failed row/source until a NEW native id actually
        // exists. A pre-begin failure therefore stays retryable.
        cancelNativeStaging(stagingId)
        startCopy(StageOwner(session, draftNonce, entry.draftHomeGeneration), uri, replacingId = stagingId)
        return true
    }

    fun cancel(session: ConversationSessionToken, stagingId: String): Boolean =
        cancelInternal(session, null, stagingId)

    fun cancelDraft(draftNonce: String, stagingId: String): Boolean =
        cancelInternal(null, draftNonce, stagingId)

    private fun cancelInternal(
        session: ConversationSessionToken?,
        draftNonce: String?,
        stagingId: String,
    ): Boolean {
        val observed = entries[stagingId] ?: return false
        if (observed.session != session || observed.draftNonce != draftNonce) return false
        synchronized(observed.attempt) {
            val entry = entries[stagingId] ?: return false
            if (entry.attempt !== observed.attempt || entry.session != session ||
                entry.draftNonce != draftNonce) return false
            cancelCopy(entry.attempt)
            // The row is leaving while its ingress may still be
            // finished-but-unpublished: release exactly this attempt's
            // route (the native close drains the ingress). The terminal
            // handler that may already own this close dedups through the
            // attempt's routeClosed flag — never a double close.
            closeOwnedRoute(entry.attempt, entry.routeReceipt)
            entries.remove(stagingId)
            publishRemoved(session, draftNonce, stagingId)
            cancelNativeStaging(stagingId)
            entry.sourceUri?.let(::releaseScopedReadIfUnused)
        }
        return true
    }

    private fun cancelNativeStaging(stagingId: String) {
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.staging.cancel",
                scope = HostScope.ApplicationConfiguration("attachmentStaging"),
                stateful = false,
                correlationID = host.commandClient.correlationID("acancel"),
                payload = JsonObject(mapOf("stagingID" to JsonPrimitive(stagingId))),
            ),
        ) { }
    }

    private fun publishRemoved(session: ConversationSessionToken?, draftNonce: String?, stagingId: String) {
        if (session != null) host.conversations.onAttachmentRemoved(session, stagingId)
        else if (draftNonce != null) host.conversations.rootWorkspace.onDraftAttachmentRemoved(draftNonce, stagingId)
    }

    fun discard(session: ConversationSessionToken, stagingId: String) {
        val entry = entries[stagingId] ?: return
        if (entry.session != session || entry.draftNonce != null) return
        discardEntry(stagingId, entry)
    }

    fun discardDraft(draftNonce: String, stagingId: String) {
        val entry = entries[stagingId] ?: return
        if (entry.draftNonce != draftNonce || entry.session != null) return
        discardEntry(stagingId, entry)
    }

    private fun discardEntry(stagingId: String) {
        val entry = entries[stagingId] ?: return
        discardEntry(stagingId, entry)
    }

    private fun discardEntry(stagingId: String, entry: StagingEntry) {
        if (entries[stagingId] !== entry) return
        val handle = entry.stagingHandle
        if (handle == null) {
            cancelInternal(entry.session, entry.draftNonce, stagingId)
            return
        }
        synchronized(entry.attempt) {
            if (entries[stagingId] !== entry) return
            entry.attempt.cancelled.set(true)
            entries.remove(stagingId)
            publishRemoved(entry.session, entry.draftNonce, stagingId)
            discardNativeHandle(handle)
        }
        entry.sourceUri?.let(::releaseScopedReadIfUnused)
    }

    private fun discardNativeHandle(handle: String) {
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.staging.discard",
                scope = HostScope.ApplicationConfiguration("attachmentStaging"),
                stateful = false,
                correlationID = host.commandClient.correlationID("adiscard"),
                payload = JsonObject(mapOf("stagingHandle" to JsonPrimitive(handle))),
            ),
        ) { }
    }

    /** Drain EVERY draft-owned row for [draftNonce] (an actual navigation /
     *  Home replacement, or host teardown): live copies are cancelled+aborted,
     *  Ready staged handles are discarded, and the source grants released.
     *  Conversation-owned rows are never touched. Called by
     *  RootWorkspaceController AFTER it has cleared its own presentation
     *  mirror, so the cleanup is real and ordered, not a UI guess. */
    internal fun drainDraft(draftNonce: String) {
        copies.keys.filter { it.draftNonce == draftNonce }.forEach(::cancelCopy)
        val ids = entries.entries
            .filter { it.value.draftNonce == draftNonce }
            .map { it.key }
        for (id in ids) {
            val entry = entries[id] ?: continue
            if (entry.stagingHandle != null) {
                discardDraft(draftNonce, id)
            } else {
                cancelDraft(draftNonce, id)
            }
        }
    }

    internal fun drainSession(session: ConversationSessionToken) {
        copies.keys.filter { it.session == session }.forEach(::cancelCopy)
        entries.entries.filter { it.value.session == session }.map { it.key }
            .forEach { discard(session, it) }
    }

    /** Transfer ready Home rows before its route retires. Lock every exact
     * attempt in stable order, then validate all rows before moving any. */
    internal fun handoffDraftToSession(
        nonce: String,
        session: ConversationSessionToken,
        stagingIds: List<String>,
    ): Boolean {
        if (stagingIds.isEmpty()) return true
        if (!host.conversations.attachmentSessionIsCurrent(session) ||
            stagingIds.distinct().size != stagingIds.size) return false
        val observed = stagingIds.sorted().map { entries[it] ?: return false }
        fun move(index: Int): Boolean {
            if (index < observed.size) return synchronized(observed[index].attempt) { move(index + 1) }
            val epoch = host.nativeRootEpochReader() ?: return false
            if (host.conversations.rootWorkspace.currentDraftOwner().first != nonce) return false
            if (observed.any { entries[it.staged.id] !== it || it.draftNonce != nonce ||
                    it.session != null || !it.staged.isReady || it.stagingHandle == null ||
                    it.attempt.cancelled.get() || it.attempt.rootEpoch != epoch }) return false
            observed.forEach { entry ->
                entries[entry.staged.id] = entry.copy(session = session, draftNonce = null,
                    staged = entry.staged.copy(ownerConversationId = session.conversationId))
            }
            return true
        }
        val moved = move(0)
        if (moved) observed.forEach { entry ->
            host.conversations.onAttachmentStaged(session,
                entry.staged.copy(ownerConversationId = session.conversationId))
        }
        return moved
    }

    /** UI row IDs are not native capabilities. Resolve only this live
     * session's Ready records; never drop unknown/not-ready rows silently. */
    internal fun launchHandles(
        session: ConversationSessionToken,
        rows: List<StagedAttachmentUi>,
    ): List<String>? {
        if (rows.isEmpty()) return emptyList()
        if (!host.conversations.attachmentSessionIsCurrent(session) ||
            rows.map { it.id }.distinct().size != rows.size) return null
        val epoch = host.nativeRootEpochReader() ?: return null
        return rows.map { row ->
            val entry = entries[row.id] ?: return null
            synchronized(entry.attempt) {
                if (entries[row.id] !== entry || entry.session != session ||
                    entry.draftNonce != null || !row.isReady || !entry.staged.isReady ||
                    row.sha256 != entry.staged.sha256 || entry.attempt.cancelled.get() ||
                    entry.attempt.rootEpoch != epoch) return null
                entry.stagingHandle ?: return null
            }
        }
    }

    /** Native prepared/queue commit now owns the bytes. Release host-only
     * bookkeeping and the source read grant; never discard committed data. */
    internal fun consumeSessionRows(session: ConversationSessionToken, ids: List<String>) {
        ids.forEach { id ->
            val entry = entries[id] ?: return@forEach
            var removed = false
            synchronized(entry.attempt) {
                if (entry.session == session && entry.draftNonce == null && entries.remove(id, entry)) {
                    entry.attempt.cancelled.set(true)
                    removed = true
                }
            }
            if (removed) entry.sourceUri?.let(::releaseScopedReadIfUnused)
        }
    }

    /** The native staging handle minted for a Ready draft row (never a
     *  host-fabricated token). Absent/null means the row is not sendable. */
    internal fun draftHandle(stagingId: String): String? =
        entries[stagingId]?.takeIf { it.draftNonce != null }?.stagingHandle

    /** Commit staged attachments to a conversation (pre-run lease handoff). */
    fun commit(session: ConversationSessionToken, stagingIds: List<String>): Boolean {
        if (stagingIds.isEmpty()) return true
        if (!host.conversations.attachmentSessionIsCurrent(session)) return false
        val handles = stagingIds.mapNotNull {
            entries[it]?.takeIf { e -> e.session == session }?.stagingHandle
        }
        if (handles.size != stagingIds.size || stagingIds.distinct().size != stagingIds.size) return false
        val revision = host.conversations.entryFor(session.conversationId)
            ?.builder?.conversationRevision?.let { HostRevision(it.resourceID, it.version) }
            ?: return false
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.commit",
                scope = HostScope.ConversationLifecycle(session.conversationId),
                stateful = true,
                correlationID = host.commandClient.correlationID("acommit"),
                revision = revision,
                payload = JsonObject(
                    mapOf("stagingHandles" to JsonArray(
                        handles.map { JsonPrimitive(it) })),
                ),
            ),
        ) { }
        return true
    }

    /** Open a message attachment for viewing. */
    fun open(request: AttachmentOpenRequest) {
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.read",
                scope = HostScope.ConversationLifecycle(request.conversationId),
                stateful = false,
                correlationID = host.commandClient.correlationID("aread"),
                payload = JsonObject(
                    mapOf(
                        "messageID" to JsonPrimitive(request.messageId),
                        "attachmentID" to JsonPrimitive(request.attachmentId),
                    ),
                ),
            ),
        ) { }
    }

    private fun releaseScopedReadIfUnused(uri: Uri) = launchCleanup {
        SharedUriGrantAuthority.withExclusiveAuthority {
            if (entries.values.any { it.sourceUri == uri } || copies.keys.any { it.sourceUri == uri }) return@withExclusiveAuthority
            readGrantLeases.remove(uri)?.close()
        }
    }
}

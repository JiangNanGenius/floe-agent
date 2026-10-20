// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.bridge.AttachmentStagingNative
import com.floe.android.bridge.AttachmentStagingNativeException
import com.floe.android.feature.conversation.AttachmentImportUi
import com.floe.android.feature.conversation.AttachmentKindUi
import com.floe.android.feature.conversation.AttachmentOpenRequest
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.StagedAttachmentUi
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
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
 * The staged bytes are consumed by the run owner through the ORIGINAL atomic
 * `RunLaunchStore.prepare`; arrival never auto-sends.
 */
class AttachmentImportController internal constructor(
    private val host: RuntimeHost,
) {
    /** Picker presentation requests (host → composition glue). The launcher
     *  identity is immutable: [incarnation] invalidates stale results. */
    data class PickerRequest(
        val session: ConversationSessionToken,
        val incarnation: Long,
    )

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

    private val pickerRequestFlow = MutableStateFlow<PickerRequest?>(null)
    val pickerRequest: StateFlow<PickerRequest?> = pickerRequestFlow

    private val launcherIncarnation = AtomicLong(0)

    /** RAM-only session staging bookkeeping (never persisted). Keyed by the
     *  NATIVE staging id — the host never mints attachment identities. */
    private data class StagingEntry(
        val session: ConversationSessionToken,
        val sourceUri: Uri?,
        val staged: StagedAttachmentUi,
        val routeReceipt: String,
        val ingressReceipt: String,
        val stagingHandle: String?,
    )

    private val entries = LinkedHashMap<String, StagingEntry>()

    companion object {
        /** Mirrors the native per-file cap (AttachmentStagingLimits in the
         *  shared core). Oversized imports are refused typed BEFORE streaming;
         *  the native side enforces its own caps regardless. */
        const val MAX_STAGING_BYTES = 128L * 1024 * 1024
        private const val CHUNK_BYTES = 64 * 1024
    }

    internal fun start() {}
    internal fun stop() {
        entries.clear()
        pickerRequestFlow.value = null
    }

    private fun admitted(): Boolean = host.readiness.value.attachmentStagingAdmitted

    // ---------------------------------------------------------------- picker

    fun requestPicker(session: ConversationSessionToken) {
        if (!admitted()) return
        // Capture the immutable launch owner: any result not matching THIS
        // incarnation is a stale/foreign result and is dropped without IO.
        pickerRequestFlow.value = PickerRequest(session, launcherIncarnation.incrementAndGet())
    }

    fun cancelPicker() {
        // Invalidate the current launcher without fabricating a new owner.
        launcherIncarnation.incrementAndGet()
        pickerRequestFlow.value = null
    }

    /** Composition glue delivers the platform picker result here. A result
     *  for a superseded launcher (navigation/newer request) is dropped. */
    fun onPickerResult(session: ConversationSessionToken, uri: Uri) {
        val pending = pickerRequestFlow.value
        // Exact-owner validation: same session AND the still-current launcher
        // incarnation. A newer requestPicker or cancelPicker already bumped
        // the incarnation, so a late oldA result never touches newB.
        if (pending == null || pending.session != session) return
        launcherIncarnation.incrementAndGet()
        pickerRequestFlow.value = null
        if (!admitted()) return
        // The staged row appears only via onAttachmentStaged after the native
        // stage terminal accepts (the presentation row is host-added; there is
        // deliberately no pre-stage row, so no progress event is emitted here).
        host.scope.launch(host.ioDispatcher) {
            when (val result = stageThroughNativeProducer(session, uri)) {
                // Ready publishes only on the native stage terminal; a failed
                // import before any host-added row has no row to update (the
                // presentation row is host-added exclusively by
                // onAttachmentStaged — late/early progress cannot fabricate).
                is StageResult.Staged -> Unit
                is StageResult.Failed -> Unit
            }
        }
    }

    // ------------------------------------------------------------ native copy

    private sealed interface StageResult {
        data class Staged(val stagingId: String) : StageResult
        data class Failed(val reason: String) : StageResult
    }

    private suspend fun stageThroughNativeProducer(
        session: ConversationSessionToken,
        uri: Uri,
    ): StageResult = withContext(Dispatchers.IO) {
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
        if (declaredSize > MAX_STAGING_BYTES) {
            return@withContext StageResult.Failed("attachment_too_large")
        }
        val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"

        var routeReceipt: String? = null
        var ingressReceipt: String? = null
        try {
            routeReceipt = channel.routeOpen(
                conversationId = session.conversationId,
                incarnation = session.sessionEpoch,
                draftRevision = 0L,
                isTemporary = false,
            )
            val begin = channel.begin(routeReceipt, null)
            val tokens = begin.split(" ")
            if (tokens.size != 2) return@withContext StageResult.Failed("stage_refused")
            ingressReceipt = tokens[0]
            val stagingId = tokens[1]

            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            val buffer = ByteArray(CHUNK_BYTES)
            context.contentResolver.openInputStream(uri)?.use { input ->
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (total + read > MAX_STAGING_BYTES) {
                        channel.abort(ingressReceipt)
                        return@withContext StageResult.Failed("attachment_too_large")
                    }
                    channel.write(ingressReceipt, buffer, 0, read)
                    digest.update(buffer, 0, read)
                    total += read
                }
            } ?: run {
                channel.abort(ingressReceipt)
                return@withContext StageResult.Failed("source_unreadable")
            }
            if (total == 0L) {
                channel.abort(ingressReceipt)
                return@withContext StageResult.Failed("source_unreadable")
            }
            // EOF: the native producer flushes/fsyncs and marks the ingress
            // ready for the `attachment.stage` publish command.
            channel.end(ingressReceipt, displayName, mimeType)
            channel.routeClose(routeReceipt)
            // Persist the READ grant ONLY when the platform offers persistable
            // read access (a justified user import enabling retry without a
            // re-pick). Never a blanket WRITE request.
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
            val staged = StagedAttachmentUi(
                id = stagingId,
                displayName = displayName,
                mimeType = mimeType,
                kind = kindFor(mimeType),
                byteCount = total,
                sha256 = sha256,
                ownerConversationId = session.conversationId,
                import = AttachmentImportUi.InProgress(null),
            )
            entries[stagingId] = StagingEntry(
                session, uri, staged, routeReceipt, ingressReceipt, null)
            submitStage(session, stagingId, ingressReceipt, staged)
            StageResult.Staged(stagingId)
        } catch (cancel: CancellationException) {
            ingressReceipt?.let { runCatching { channel.abort(it) } }
            throw cancel
        } catch (native: AttachmentStagingNativeException) {
            ingressReceipt?.let { runCatching { channel.abort(it) } }
            StageResult.Failed(reasonFor(native.status))
        } catch (t: Throwable) {
            ingressReceipt?.let { runCatching { channel.abort(it) } }
            StageResult.Failed("source_unreadable")
        } finally {
            routeReceipt?.let { runCatching { channel.routeClose(it) } }
        }
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
        session: ConversationSessionToken,
        stagingId: String,
        ingressReceipt: String,
        staged: StagedAttachmentUi,
    ) {
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.stage",
                scope = HostScope.ApplicationConfiguration("attachmentStaging"),
                stateful = false,
                correlationID = host.commandClient.correlationID("astage"),
                payload = JsonObject(mapOf("ingressReceipt" to JsonPrimitive(ingressReceipt))),
            ),
        ) { outcome ->
            when (outcome) {
                is HostOperationOutcome.Completed -> {
                    val handle = (outcome.value as? JsonObject)
                        ?.get("stagingHandle")
                        ?.let { (it as? JsonPrimitive)?.content }
                    entries[stagingId]?.let { entry ->
                        entries[stagingId] = entry.copy(stagingHandle = handle)
                    }
                    host.conversations.onAttachmentStaged(
                        session, staged.copy(import = AttachmentImportUi.Ready))
                }
                else -> {
                    entries.remove(stagingId)
                    host.conversations.onAttachmentProgress(
                        session, stagingId,
                        AttachmentImportUi.Failed(
                            when (outcome) {
                                is HostOperationOutcome.Rejected -> outcome.code
                                is HostOperationOutcome.Failed -> outcome.code
                                else -> "stage_failed"
                            }),
                    )
                }
            }
        }
    }

    // -------------------------------------------------------------- controls

    fun retry(session: ConversationSessionToken, stagingId: String): Boolean {
        val entry = entries[stagingId] ?: return false
        val uri = entry.sourceUri ?: return false
        host.conversations.onAttachmentProgress(
            session, stagingId, AttachmentImportUi.InProgress(null))
        host.scope.launch(host.ioDispatcher) {
            entries.remove(stagingId)
            // The row for stagingId may still exist (retry): surface failure.
            when (val result = stageThroughNativeProducer(session, uri)) {
                is StageResult.Staged -> Unit
                is StageResult.Failed -> host.conversations.onAttachmentProgress(
                    session, stagingId, AttachmentImportUi.Failed(result.reason))
            }
        }
        return true
    }

    fun cancel(session: ConversationSessionToken, stagingId: String): Boolean {
        val entry = entries[stagingId] ?: return false
        entries.remove(stagingId)
        runCatching { channel.abort(entry.ingressReceipt) }
        host.trackOperation(
            HostCommandRequest(
                command = "attachment.staging.cancel",
                scope = HostScope.ApplicationConfiguration("attachmentStaging"),
                stateful = false,
                correlationID = host.commandClient.correlationID("acancel"),
                payload = JsonObject(mapOf("stagingID" to JsonPrimitive(stagingId))),
            ),
        ) { }
        entry.sourceUri?.let { releaseScopedRead(context = host.appContext, uri = it) }
        return true
    }

    fun discard(session: ConversationSessionToken, stagingId: String) {
        val entry = entries[stagingId] ?: return
        entries.remove(stagingId)
        val handle = entry.stagingHandle
        if (handle != null) {
            host.trackOperation(
                HostCommandRequest(
                    command = "attachment.staging.discard",
                    scope = HostScope.ApplicationConfiguration("attachmentStaging"),
                    stateful = false,
                    correlationID = host.commandClient.correlationID("adiscard"),
                    payload = JsonObject(
                        mapOf("stagingHandle" to JsonPrimitive(handle))),
                ),
            ) { }
        }
        entry.sourceUri?.let { releaseScopedRead(context = host.appContext, uri = it) }
    }

    /** Commit staged attachments to a conversation (pre-run lease handoff). */
    fun commit(session: ConversationSessionToken, stagingIds: List<String>): Boolean {
        if (stagingIds.isEmpty()) return true
        val handles = stagingIds.mapNotNull { entries[it]?.stagingHandle }
        if (handles.isEmpty()) return false
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

    private fun releaseScopedRead(context: Context, uri: Uri) {
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }
}

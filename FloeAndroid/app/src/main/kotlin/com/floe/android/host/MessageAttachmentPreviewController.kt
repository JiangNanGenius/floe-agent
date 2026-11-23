// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.floe.android.bridge.AttachmentStagingNative
import com.floe.android.feature.conversation.AttachmentOpenRequest
import com.floe.android.host.spacefiles.SpaceFilesNames
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal class MessageAttachmentPreviewController(private val host: RuntimeHost) {
    internal data class Preview(
        val request: AttachmentOpenRequest,
        val token: UUID,
        val loading: Boolean = true,
        val file: File? = null,
        val text: String? = null,
        val truncated: Boolean = false,
        val externalOpenFailed: Boolean = false,
    )

    private val mutable = MutableStateFlow<Preview?>(null)
    val state = mutable.asStateFlow()

    fun open(request: AttachmentOpenRequest, ownerCurrent: () -> Boolean): Boolean {
        val attachmentID = request.attachmentId ?: return false
        if (runCatching { UUID.fromString(attachmentID) }.isFailure) return false
        val pending = Preview(request, UUID.randomUUID())
        val unavailable = pending.copy(loading = false)
        mutable.value = pending
        val current = { ownerCurrent() && mutable.value?.token == pending.token }
        host.trackOperation(
            request = HostCommandRequest(
                command = "attachment.read",
                scope = HostScope.ConversationLifecycle(request.conversationId),
                stateful = false,
                correlationID = host.commandClient.correlationID("aread"),
                payload = JsonObject(mapOf("attachmentID" to JsonPrimitive(attachmentID))),
            ),
            beforeSubmit = current,
        ) { outcome ->
            if (!current()) {
                mutable.compareAndSet(pending, unavailable)
                return@trackOperation
            }
            val detail = (outcome as? HostOperationOutcome.Completed)?.detail.orEmpty()
            host.scope.launch(Dispatchers.IO) {
                val ready = try {
                    stage(pending, attachmentID, detail, current)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    unavailable
                }
                if (!current() || !mutable.compareAndSet(pending, ready)) {
                    ready.file?.let { file ->
                        file.delete()
                        file.parentFile?.delete()
                    }
                    mutable.compareAndSet(pending, unavailable)
                }
            }
        }
        return true
    }

    fun dismiss(conversationId: String) {
        val entry = mutable.value ?: return
        if (entry.request.conversationId == conversationId) mutable.compareAndSet(entry, null)
    }

    fun openWith(context: Context, entry: Preview) {
        val file = entry.file ?: return
        if (mutable.value != entry) return
        try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.externaledits", file)
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(SpaceFilesNames.extensionOf(file.name))
                ?: "application/octet-stream"
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            view.clipData = ClipData.newUri(context.contentResolver, file.name, uri)
            context.startActivity(Intent.createChooser(view, null))
        } catch (_: Exception) {
            mutable.compareAndSet(entry, entry.copy(externalOpenFailed = true))
        }
    }

    private fun stage(
        pending: Preview,
        attachmentID: String,
        receipt: Map<String, String>,
        current: () -> Boolean,
    ): Preview {
        check(current() && receipt["state"] == "readable" &&
            receipt["attachmentID"].equals(attachmentID, ignoreCase = true))
        val size = checkNotNull(receipt["byteCount"]?.toLongOrNull())
        check(size in 0..MAX_BYTES)
        val context = checkNotNull(host.appContextOrNull)
        val root = File(context.cacheDir, "message-attachment-previews")
        val cutoff = System.currentTimeMillis() - CACHE_LIFETIME_MILLIS
        root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { previous ->
            if (runCatching { UUID.fromString(previous.name) }.isSuccess) {
                previous.listFiles()?.forEach(File::delete)
                previous.delete()
            }
        }
        val directory = File(root, pending.token.toString())
        check(directory.mkdirs())
        val name = pending.request.displayName.takeIf(SpaceFilesNames::isSafeSegment) ?: "attachment"
        val file = File(directory, name)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.outputStream().use { output ->
                var offset = 0L
                val page = ByteArray(64 * 1024)
                while (offset < size) {
                    check(current())
                    val count = minOf(page.size.toLong(), size - offset).toInt()
                    val readBuffer = if (count == page.size) page else ByteArray(count)
                    val read = AttachmentStagingNative.attachmentRead(
                        attachmentID, pending.request.conversationId, offset, readBuffer,
                    )
                    check(read == count)
                    digest.update(readBuffer)
                    output.write(readBuffer)
                    offset += read
                }
            }
            receipt["sha256"]?.takeIf { it.isNotBlank() }?.let { expected ->
                check(digest.digest().joinToString("") { byte -> "%02x".format(byte) } == expected)
            }
            val text = if (SpaceFilesNames.allowsTextPreview("", name)) {
                file.inputStream().use { input ->
                    val bytes = ByteArray(minOf(size, TEXT_BYTES).toInt())
                    java.io.DataInputStream(input).readFully(bytes)
                    bytes.decodeToString()
                }
            } else {
                null
            }
            return pending.copy(loading = false, file = file, text = text,
                truncated = text != null && size > TEXT_BYTES)
        } catch (failure: Throwable) {
            file.delete()
            directory.delete()
            throw failure
        }
    }

    private companion object {
        const val MAX_BYTES = 128L * 1024 * 1024
        const val TEXT_BYTES = 32L * 1024
        const val CACHE_LIFETIME_MILLIS = 24 * 60 * 60 * 1000L
    }
}

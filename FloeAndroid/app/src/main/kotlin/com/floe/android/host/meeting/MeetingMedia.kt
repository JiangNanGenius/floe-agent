// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.R
import java.io.File
import java.io.IOException

/**
 * Real container metadata probe used for both imports and crash recovery.
 * `readable` is true only when the platform extractor opened the file. Nothing
 * here invents duration, audio or video presence.
 */
internal object MeetingMediaProbe {
    fun probe(file: File): ProbedMedia {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val duration = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?.coerceAtLeast(0L)
                ?: 0L
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            val hasVideo = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            val mime = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
                ?.takeIf { it.isNotBlank() }
            ProbedMedia(
                readable = true,
                durationMillis = duration,
                hasAudio = hasAudio,
                hasVideo = hasVideo,
                mimeType = mime,
            )
        } catch (_: Exception) {
            ProbedMedia(false, 0L, false, false, null)
        } finally {
            runCatching { retriever.release() }
        }
    }
}

/**
 * Bounded content-Uri import. The source Uri grants one read; the bytes become
 * an app-owned file before any metadata references them. A failed probe or
 * commit removes only that new staging file and leaves the meeting untouched.
 */
internal class MeetingMediaImporter(
    private val context: Context,
    private val repository: MeetingRepository,
) {
    suspend fun import(
        meetingId: String,
        uri: Uri,
        displayName: String?,
    ): MeetingMaterial {
        // Fail early for an unknown meeting; nothing is created for it.
        repository.detail(meetingId)

        val resolver = context.contentResolver
        val declaredMime = runCatching { resolver.getType(uri) }.getOrNull()
        val sourceName = displayName
            ?: queryDisplayName(uri)
            ?: uri.lastPathSegment?.substringAfterLast('/')
        val sizeHint = querySize(uri)
        if (sizeHint != null && sizeHint > MEETING_MAX_IMPORT_BYTES) {
            throw meetingError(
                MeetingErrorCode.TOO_LARGE,
                "The selected media is too large.",
                detail = "bytes=$sizeHint",
            )
        }

        val materialId = MeetingIds.newId()
        val guessedExtension = extensionFor(
            mime = declaredMime,
            sourceName = sourceName,
        )
        val staging = repository.importStagingFile(meetingId, materialId, guessedExtension)
        try {
            val input = try {
                resolver.openInputStream(uri)
            } catch (error: SecurityException) {
                throw meetingError(
                    MeetingErrorCode.SOURCE_UNAVAILABLE,
                    "The selected media could not be read.",
                    detail = "permission",
                    cause = error,
                )
            } catch (error: Exception) {
                throw meetingError(
                    MeetingErrorCode.SOURCE_UNAVAILABLE,
                    "The selected media could not be read.",
                    detail = "open",
                    cause = error,
                )
            } ?: throw meetingError(
                MeetingErrorCode.SOURCE_UNAVAILABLE,
                "The selected media could not be read.",
            )
            val bytes = input.use { copyBounded(it, staging, MEETING_MAX_IMPORT_BYTES) }
            if (bytes <= 0L) {
                throw meetingError(MeetingErrorCode.UNSUPPORTED_MEDIA, "The selected media is empty.")
            }
            val probed = MeetingMediaProbe.probe(staging)
            if (!probed.readable) {
                throw meetingError(
                    MeetingErrorCode.CORRUPT_MEDIA,
                    "The selected media could not be verified.",
                )
            }
            if (!probed.hasAudio && !probed.hasVideo && probed.durationMillis <= 0L) {
                throw meetingError(
                    MeetingErrorCode.UNSUPPORTED_MEDIA,
                    "The selected file is not readable audio or video.",
                )
            }
            val hasVideo = when {
                probed.hasVideo -> true
                probed.hasAudio -> false
                else -> declaredMime?.startsWith("video/") == true
            }
            val extension = extensionFor(
                mime = declaredMime ?: probed.mimeType,
                sourceName = sourceName,
            )
            return repository.commitImport(
                meetingId = meetingId,
                materialId = materialId,
                stagedFile = staging,
                displayName = MeetingText.displayName(
                    sourceName,
                    context.getString(R.string.meeting_import_default_name),
                ),
                extension = extension,
                mimeType = declaredMime ?: probed.mimeType,
                durationMillis = probed.durationMillis,
                hasVideo = hasVideo,
            )
        } catch (error: MeetingException) {
            runCatching { staging.delete() }
            throw error
        } catch (error: SecurityException) {
            runCatching { staging.delete() }
            throw meetingError(
                MeetingErrorCode.SOURCE_UNAVAILABLE,
                "The selected media could not be read.",
                detail = "permission",
                cause = error,
            )
        } catch (error: IOException) {
            runCatching { staging.delete() }
            throw storageFailure(error, "importStream")
        } catch (error: Exception) {
            runCatching { staging.delete() }
            throw storageFailure(error, "import")
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment?.substringAfterLast('/')
        return runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    cursor.getString(index)?.takeIf { it.isNotBlank() }
                } else {
                    null
                }
            }
        }.getOrNull()
    }

    private fun querySize(uri: Uri): Long? {
        if (uri.scheme == "file") {
            return runCatching { File(requireNotNull(uri.path)).length().takeIf { it > 0 } }.getOrNull()
        }
        return runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getLong(index).takeIf { it > 0 }
                } else {
                    null
                }
            }
        }.getOrNull()
    }

    companion object {
        private val MIME_EXTENSIONS = mapOf(
            "audio/mp4" to "m4a",
            "audio/m4a" to "m4a",
            "audio/x-m4a" to "m4a",
            "audio/mpeg" to "mp3",
            "audio/mp3" to "mp3",
            "audio/wav" to "wav",
            "audio/x-wav" to "wav",
            "audio/wave" to "wav",
            "audio/aac" to "aac",
            "audio/aac-adts" to "aac",
            "audio/ogg" to "ogg",
            "audio/opus" to "opus",
            "audio/flac" to "flac",
            "audio/x-flac" to "flac",
            "audio/amr" to "amr",
            "audio/3gpp" to "3gp",
            "video/mp4" to "mp4",
            "video/quicktime" to "mov",
            "video/x-m4v" to "m4v",
            "video/webm" to "webm",
            "video/x-matroska" to "mkv",
            "video/3gpp" to "3gp",
            "video/x-msvideo" to "avi",
            "video/mpeg" to "mpg",
        )

        private val SOURCE_EXTENSIONS = setOf(
            "m4a", "mp4", "m4v", "mov", "mp3", "aac", "wav", "ogg", "opus",
            "flac", "amr", "3gp", "webm", "mkv", "avi", "mpg",
        )

        internal fun extensionFor(mime: String?, sourceName: String?): String {
            val normalized = mime
                ?.substringBefore(';')
                ?.trim()
                ?.lowercase()
            if (normalized != null) {
                MIME_EXTENSIONS[normalized]?.let { return it }
            }
            val fromName = sourceName
                ?.substringAfterLast('.', "")
                ?.lowercase()
                ?.takeIf { it in SOURCE_EXTENSIONS }
            if (fromName != null) return fromName
            return "media"
        }
    }
}

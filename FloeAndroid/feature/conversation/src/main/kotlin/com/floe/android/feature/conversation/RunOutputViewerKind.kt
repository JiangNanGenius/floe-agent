// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import java.util.Locale

/**
 * Owned run-output preview kinds for the App's own full-screen viewer lane
 * (text/Markdown reading space plus bounded image/audio/video playback).
 *
 * The classification is a PURE closed agreement between the two sealed
 * facts the native owner already verified — the receipt's declared MIME and
 * its display-name extension — never a sniff of model text, artifact
 * metadata or a resolved path. BOTH sides must agree: a markdown receipt
 * over a `.png` name (or the reverse) is [UNSUPPORTED], never a guess.
 *
 * [UNSUPPORTED] is an honest answer, not a failure: such cards keep their
 * real Save Copy action and carry an explicit limitation note instead of a
 * fake preview affordance.
 */
enum class RunOutputViewerKind { TEXT, IMAGE, AUDIO, VIDEO, UNSUPPORTED }

/** The closed MIME/extension agreement table shared by the card affordance
 * gate and the App-host open router (one table, two consumers, no drift). */
object RunOutputViewerSupport {

    /** Accepted text/markdown space: plain text and Markdown source only.
     * Content renders as READABLE TEXT (no WebView, no remote images, no
     * script) — sealed bytes stay the only input. */
    private val TEXT_MIME_TO_EXTENSIONS = mapOf(
        "text/plain" to setOf("txt", "text", "log"),
        "text/markdown" to setOf("md", "markdown"),
        "text/x-markdown" to setOf("md", "markdown"),
    )

    /** Decode-provable raster formats (BitmapFactory-bound). */
    private val IMAGE_MIME_TO_EXTENSIONS = mapOf(
        "image/png" to setOf("png"),
        "image/jpeg" to setOf("jpg", "jpeg"),
        "image/webp" to setOf("webp"),
        "image/gif" to setOf("gif"),
    )

    /** Platform MediaPlayer-playable audio containers. */
    private val AUDIO_MIME_TO_EXTENSIONS = mapOf(
        "audio/wav" to setOf("wav"),
        "audio/x-wav" to setOf("wav"),
        "audio/mpeg" to setOf("mp3"),
        "audio/mp3" to setOf("mp3"),
        // An audio-only MP4 keeps its audio container names; a `.mp4` name
        // stays the VIDEO agreement's territory — MIME alone never decides.
        "audio/mp4" to setOf("m4a", "aac"),
        "audio/x-m4a" to setOf("m4a"),
        "audio/aac" to setOf("aac", "m4a"),
        "audio/ogg" to setOf("ogg"),
        "application/ogg" to setOf("ogg"),
    )

    /** Platform MediaPlayer-playable video containers. */
    private val VIDEO_MIME_TO_EXTENSIONS = mapOf(
        "video/mp4" to setOf("mp4"),
        "video/webm" to setOf("webm"),
        "video/3gpp" to setOf("3gp"),
    )

    /** Every extension the App-owned viewer lane can stage (the staging
     * format gate; classification still requires MIME agreement). */
    val STAGED_EXTENSIONS: Set<String> = TEXT_MIME_TO_EXTENSIONS.values.flatten()
        .plus(IMAGE_MIME_TO_EXTENSIONS.values.flatten())
        .plus(AUDIO_MIME_TO_EXTENSIONS.values.flatten())
        .plus(VIDEO_MIME_TO_EXTENSIONS.values.flatten())
        .toSortedSet()

    fun classify(mimeType: String, displayName: String): RunOutputViewerKind {
        val mime = mimeType.substringBefore(';').trim().lowercase(Locale.ROOT)
        val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (mime.isEmpty() || extension.isEmpty()) return RunOutputViewerKind.UNSUPPORTED
        return when {
            TEXT_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true ->
                RunOutputViewerKind.TEXT
            IMAGE_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true ->
                RunOutputViewerKind.IMAGE
            AUDIO_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true ->
                RunOutputViewerKind.AUDIO
            VIDEO_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true ->
                RunOutputViewerKind.VIDEO
            else -> RunOutputViewerKind.UNSUPPORTED
        }
    }

    /** True only under the closed agreement (the card Open affordance and
     * the host router both consult THIS, so an offered Open is always
     * backed by a real in-App route). */
    fun supportsPreview(mimeType: String, displayName: String): Boolean =
        classify(mimeType, displayName) != RunOutputViewerKind.UNSUPPORTED
}

// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry contracts shared by the platform host and its JVM regressions.
//
// These types are deliberately Android-framework free: Intents, ContentResolver,
// NotesService and RuntimeHost stay in the host/adapter files. Everything here
// is bounded, closed and content-free in toString() except the explicitly
// user-visible display metadata used by the chooser.
package com.floe.android.host.entryflow

import java.security.MessageDigest
import java.util.UUID

internal const val ENTRY_MAX_ITEMS = 5
internal const val ENTRY_MAX_TEXT_BYTES = 1_048_576L
internal const val ENTRY_MAX_ITEM_BYTES = 64L * 1024L * 1024L
internal const val ENTRY_MAX_TOTAL_BYTES = 128L * 1024L * 1024L
internal const val ENTRY_MAX_URL_BYTES = 8_192
internal const val ENTRY_DEDUP_WINDOW_MS = 10L * 60L * 1_000L
internal const val ENTRY_DISCARD_WINDOW_MS = 5L * 1_000L
internal const val ENTRY_INTAKE_TTL_MS = 10L * 60L * 1_000L
internal const val ENTRY_MAX_FEEDBACK_CHARS = 8_000
internal const val ENTRY_MAX_DIAGNOSTIC_BYTES = 128 * 1024

/** A parsed supported entry route. IDs are canonical lowercase UUIDs. */
internal sealed interface C07EntryRoute {
    data object NewTask : C07EntryRoute
    data class Task(val conversationID: String) : C07EntryRoute
    data class Schedule(val scheduleID: String) : C07EntryRoute
    data class Share(val intakeID: String?) : C07EntryRoute
}

internal sealed interface C07RouteParse {
    data class Parsed(val route: C07EntryRoute) : C07RouteParse
    data class Refused(val code: String) : C07RouteParse
}

/**
 * Strict `floe://` parser (the Android executable counterpart of
 * `C07AppEntryRoute` in the shared core).
 *
 * The link is only a navigation/intake request. It can never carry a prompt,
 * approval, permission, command, path or task target that has not been
 * re-read from the existing store.
 */
internal object C07EntryRouteParser {
    private val hosts = setOf("new", "task", "schedule", "share")

    fun parse(raw: String): C07RouteParse {
        if (raw.isEmpty() || raw.toByteArray(Charsets.UTF_8).size > ENTRY_MAX_URL_BYTES) {
            return C07RouteParse.Refused("tooLong")
        }
        if (raw.any { it.code < 0x21 || it.code == 0x7F }) {
            return C07RouteParse.Refused("malformed")
        }
        if (!raw.startsWith("floe://", ignoreCase = true)) {
            return C07RouteParse.Refused("unsupportedScheme")
        }
        val uri = runCatching { java.net.URI(raw) }.getOrNull()
            ?: return C07RouteParse.Refused("malformed")
        if (!uri.scheme.equals("floe", ignoreCase = true)) {
            return C07RouteParse.Refused("unsupportedScheme")
        }
        if (uri.userInfo != null || uri.port != -1 || uri.fragment != null) {
            return C07RouteParse.Refused("malformed")
        }
        val host = uri.host?.lowercase() ?: return C07RouteParse.Refused("malformed")
        val rawPath = uri.rawPath.orEmpty()
        if (rawPath.contains('%') || rawPath.contains('\\') || rawPath.contains("..")) {
            return C07RouteParse.Refused("malformed")
        }
        if (host !in hosts) return C07RouteParse.Refused("unsupportedAction")
        val query = uri.rawQuery
        return when (host) {
            "new" -> {
                if (rawPath.isNotEmpty() && rawPath != "/") {
                    C07RouteParse.Refused("malformed")
                } else if (query != null) {
                    C07RouteParse.Refused("unexpectedParameters")
                } else {
                    C07RouteParse.Parsed(C07EntryRoute.NewTask)
                }
            }
            "task" -> parseIdRoute(rawPath, query)?.let {
                C07RouteParse.Parsed(C07EntryRoute.Task(it))
            } ?: C07RouteParse.Refused("invalidTarget")
            "schedule" -> parseIdRoute(rawPath, query)?.let {
                C07RouteParse.Parsed(C07EntryRoute.Schedule(it))
            } ?: C07RouteParse.Refused("invalidTarget")
            "share" -> parseShare(rawPath, query)
            else -> C07RouteParse.Refused("unsupportedAction")
        }
    }

    private fun parseIdRoute(rawPath: String, query: String?): String? {
        if (query != null) return null
        if (!rawPath.startsWith("/") || rawPath.length != 37) return null
        return canonicalUuid(rawPath.substring(1))
    }

    private fun parseShare(rawPath: String, query: String?): C07RouteParse {
        if (rawPath.isNotEmpty() && rawPath != "/") {
            return C07RouteParse.Refused("malformed")
        }
        if (query == null) return C07RouteParse.Parsed(C07EntryRoute.Share(null))
        if (query.contains('&') || query.count { it == '=' } != 1) {
            return C07RouteParse.Refused("unexpectedParameters")
        }
        val name = query.substringBefore('=')
        val value = query.substringAfter('=')
        if (name != "intake") return C07RouteParse.Refused("unexpectedParameters")
        val id = canonicalUuid(value) ?: return C07RouteParse.Refused("invalidTarget")
        return C07RouteParse.Parsed(C07EntryRoute.Share(id))
    }

    private fun canonicalUuid(value: String): String? = C07EntryIds.canonicalUuid(value)
}

/** Strict canonical UUID identity used by links and notification payloads. */
internal object C07EntryIds {
    fun canonicalUuid(value: String?): String? {
        if (value == null || value.length != 36) return null
        if (value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-') return null
        if (value.any { ch ->
                !(ch in '0'..'9' || ch in 'a'..'f' || ch in 'A'..'F' || ch == '-')
            }
        ) {
            return null
        }
        val parsed = runCatching { UUID.fromString(value) }.getOrNull() ?: return null
        return parsed.toString().takeIf { it.equals(value, ignoreCase = true) }
    }
}

internal enum class C07EntryItemKind { TEXT, FILE }

/**
 * One admitted share/open item. The content URI and text stay internals of
 * the host: [toString] exposes only the bounded display metadata, so this
 * value is safe in diagnostics and test failures.
 */
internal class C07EntryCapturedItem(
    val index: Int,
    val kind: C07EntryItemKind,
    val uriString: String?,
    val mimeType: String,
    val displayName: String,
    val declaredBytes: Long,
    val text: String?,
) {
    override fun toString(): String =
        "C07EntryCapturedItem(index=$index, kind=$kind, mime=$mimeType, " +
            "bytes=$declaredBytes, nameChars=${displayName.length})"
}

internal sealed interface C07ShareValidation {
    data class Accepted(
        val totalKnownBytes: Long,
        val textBytes: Long,
    ) : C07ShareValidation

    data class Refused(val code: C07EntryRefusal) : C07ShareValidation
}

internal enum class C07EntryRefusal {
    EMPTY,
    ITEM_LIMIT,
    TEXT_TOO_LARGE,
    ITEM_TOO_LARGE,
    TOTAL_TOO_LARGE,
    UNSUPPORTED,
    CONTENT_MISMATCH,
    INVALID_URI,
    GRANT_REVOKED,
    UNREADABLE,
    TOO_LARGE,
    FAILED,
    POLICY_UNAVAILABLE,
    BUSY,
    STALE,
    NOTES_UNAVAILABLE,
    STAGING_UNAVAILABLE,
    TARGET_UNAVAILABLE,
}

/**
 * Bounded, explicit share/open policy. MIME parameters are stripped; unknown
 * sizes are allowed at admission (declared -1) only for a supported type and
 * are enforced while copying. Executable, markup, archive-bomb and unknown
 * binary payloads are refused rather than forwarded to a consumer.
 */
internal object C07SharePolicy {
    private val exactTypes = setOf(
        "text/plain",
        "application/pdf",
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/zip",
    )
    private val octetExtensions = setOf(
        "pdf", "png", "jpg", "jpeg", "webp", "gif", "txt", "md",
        "docx", "xlsx", "pptx", "zip",
    )

    fun normalizeMime(raw: String?): String =
        raw.orEmpty().substringBefore(';').trim().lowercase()

    fun isSupported(mimeType: String, displayName: String): Boolean {
        if (mimeType == "application/zip") {
            return extension(displayName) in setOf("zip", "docx", "xlsx", "pptx")
        }
        if (mimeType in exactTypes) return true
        if (mimeType == "application/octet-stream") {
            return extension(displayName) in octetExtensions
        }
        return false
    }

    fun validate(items: List<C07EntryCapturedItem>): C07ShareValidation {
        if (items.isEmpty()) return C07ShareValidation.Refused(C07EntryRefusal.EMPTY)
        if (items.size > ENTRY_MAX_ITEMS) {
            return C07ShareValidation.Refused(C07EntryRefusal.ITEM_LIMIT)
        }
        var textBytes = 0L
        var totalKnown = 0L
        for (item in items) {
            when (item.kind) {
                C07EntryItemKind.TEXT -> {
                    val bytes = item.text?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: 0L
                    if (bytes <= 0L) return C07ShareValidation.Refused(C07EntryRefusal.EMPTY)
                    textBytes += bytes
                    if (textBytes > ENTRY_MAX_TEXT_BYTES) {
                        return C07ShareValidation.Refused(C07EntryRefusal.TEXT_TOO_LARGE)
                    }
                }
                C07EntryItemKind.FILE -> {
                    if (!isSupported(item.mimeType, item.displayName)) {
                        return C07ShareValidation.Refused(C07EntryRefusal.UNSUPPORTED)
                    }
                    if (item.declaredBytes < -1L) {
                        return C07ShareValidation.Refused(C07EntryRefusal.UNREADABLE)
                    }
                    if (item.declaredBytes > ENTRY_MAX_ITEM_BYTES) {
                        return C07ShareValidation.Refused(C07EntryRefusal.ITEM_TOO_LARGE)
                    }
                    if (item.declaredBytes > 0L) totalKnown += item.declaredBytes
                }
            }
        }
        if (totalKnown > ENTRY_MAX_TOTAL_BYTES) {
            return C07ShareValidation.Refused(C07EntryRefusal.TOTAL_TOO_LARGE)
        }
        return C07ShareValidation.Accepted(totalKnown, textBytes)
    }

    fun extension(displayName: String): String =
        displayName.substringAfterLast('.', "").trim().lowercase()

    /**
     * Metadata-only name. It is never used as a path; the native notes and
     * attachment stores validate their own file-name hints again.
     */
    fun sanitizeDisplayName(raw: String?): String {
        val leaf = raw.orEmpty()
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .filter { it.code >= 0x20 && it.code != 0x7F }
            .trim()
        return leaf.take(120).ifBlank { "attachment" }
    }

    fun noteTitle(displayName: String): String {
        val stem = displayName.substringBeforeLast('.', displayName).trim()
        return stem.take(120).ifBlank { displayName.take(120) }
    }
}

/** Stable duplicate-suppression key. Only a digest is persisted. */
internal object C07EntryFingerprint {
    fun of(
        action: String,
        subject: String?,
        items: List<C07EntryCapturedItem>,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        fun field(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            digest.update((bytes.size ushr 24).toByte())
            digest.update((bytes.size ushr 16).toByte())
            digest.update((bytes.size ushr 8).toByte())
            digest.update(bytes.size.toByte())
            digest.update(bytes)
        }
        field(action)
        field(subject.orEmpty())
        field(items.size.toString())
        for (item in items) {
            field(item.kind.name)
            when (item.kind) {
                C07EntryItemKind.TEXT -> field(sha256(item.text.orEmpty()))
                C07EntryItemKind.FILE -> {
                    field(item.uriString.orEmpty())
                    field(item.mimeType)
                    field(item.declaredBytes.toString())
                    field(item.displayName)
                }
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

internal object C07EntryCopy {
    fun textPreview(items: List<C07EntryCapturedItem>): String? {
        val text = items.filter { it.kind == C07EntryItemKind.TEXT }
            .mapNotNull { it.text }
            .firstOrNull { it.isNotBlank() }
            ?: return null
        return text.take(4_096)
            .split(Regex("\\s+"))
            .filter { it.isNotEmpty() }
            .joinToString(" ")
            .take(200)
    }
}

/** Identifier-only notification payload constants. */
internal object C07EntryNotification {
    const val ACTION_QUESTION = "com.floe.android.entry.QUESTION"
    const val ACTION_SCHEDULE = "com.floe.android.entry.SCHEDULE"
    const val EXTRA_CONVERSATION_ID = "floe.entry.conversationID"
    const val EXTRA_REQUEST_ID = "floe.entry.requestID"
    const val EXTRA_QUESTION_ID = "floe.entry.questionID"
    const val EXTRA_SCHEDULE_ID = "floe.entry.scheduleID"

    fun validQuestionId(value: String?): String? =
        value?.takeIf { it.length in 1..128 && it.all { ch -> ch.code in 0x21..0x7E } }

    fun validQuestionTextId(value: String?): String? =
        value?.takeIf { it.length in 1..160 && it.all { ch -> ch.code in 0x21..0x7E } }
}

internal sealed interface C07EntryNavigation {
    data class OpenTask(val conversationID: String) : C07EntryNavigation
    data class OpenSchedule(val scheduleID: String) : C07EntryNavigation
    data class OpenNewTask(val intakeID: String?) : C07EntryNavigation
    data object OpenNotes : C07EntryNavigation
}

internal data class C07HomeDraftAdoption(
    val revision: Long,
    val text: String,
)

internal data class C07ScheduleFocus(
    val requestID: Long,
    val scheduleID: String,
)

internal enum class C07SetupStep(val key: String) {
    WELCOME("welcome"),
    MODELS("models"),
    VOICE("voice"),
    FILES("files"),
    NOTIFICATIONS("notifications"),
    DONE("done");

    companion object {
        fun fromKey(key: String?): C07SetupStep =
            entries.firstOrNull { it.key == key } ?: WELCOME
    }
}

internal data class C07SetupState(
    val step: C07SetupStep = C07SetupStep.WELCOME,
    val seen: Boolean = false,
    val finished: Boolean = false,
    val skipped: Boolean = false,
    val updatedAt: Long = 0L,
)

internal enum class C07EntryJournalStatus { ADMITTED, COMPLETED, DISCARDED, FAILED }

internal data class C07JournalRecord(
    val fingerprint: String,
    val intakeID: String,
    val status: C07EntryJournalStatus,
    val updatedAt: Long,
    val expiresAt: Long,
)

/** Pure duplicate policy shared by the store and its JVM regressions. */
internal object C07EntryDedup {
    fun blocks(
        record: C07JournalRecord?,
        fingerprint: String,
        liveIntakeID: String?,
        now: Long,
    ): Boolean {
        if (record == null || record.fingerprint != fingerprint) return false
        if (record.expiresAt <= now) return false
        return when (record.status) {
            C07EntryJournalStatus.ADMITTED -> record.intakeID == liveIntakeID
            C07EntryJournalStatus.COMPLETED,
            C07EntryJournalStatus.DISCARDED,
            C07EntryJournalStatus.FAILED -> true
        }
    }
}

/** Pure, side-effect-free setup-guide navigation. It never reads or writes a
 * provider, model, voice, account or credential choice. */
internal object C07SetupMachine {
    fun next(state: C07SetupState, now: Long): C07SetupState {
        val next = C07SetupStep.entries.getOrNull(state.step.ordinal + 1)
            ?: return state
        return state.copy(step = next, seen = true, updatedAt = now)
    }

    fun previous(state: C07SetupState, now: Long): C07SetupState {
        val previous = C07SetupStep.entries.getOrNull(state.step.ordinal - 1)
            ?: return state
        return state.copy(step = previous, seen = true, updatedAt = now)
    }

    fun dismiss(state: C07SetupState, now: Long): C07SetupState =
        state.copy(seen = true, updatedAt = now)

    fun skip(state: C07SetupState, now: Long): C07SetupState =
        state.copy(seen = true, skipped = true, updatedAt = now)

    fun finish(state: C07SetupState, now: Long): C07SetupState =
        state.copy(seen = true, finished = true, updatedAt = now)

    fun offerOnce(state: C07SetupState, now: Long): Pair<C07SetupState, Boolean> {
        if (state.seen) return state to false
        return state.copy(seen = true, updatedAt = now) to true
    }
}

/** Bounded in-process replay guard for Activity/notification redelivery. */
internal class C07EntryReplayGuard(
    private val windowMillis: Long = 30_000L,
    private val limit: Int = 12,
) {
    private val seen = LinkedHashMap<String, Long>()

    fun admit(key: String, now: Long): Boolean {
        val prior = seen[key]
        if (prior != null && now - prior < windowMillis) return false
        seen[key] = now
        while (seen.size > limit) {
            val first = seen.keys.firstOrNull() ?: break
            seen.remove(first)
        }
        return true
    }
}

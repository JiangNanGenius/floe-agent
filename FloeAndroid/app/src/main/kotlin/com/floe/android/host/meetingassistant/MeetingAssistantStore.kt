// SPDX-License-Identifier: MPL-2.0
//
// Durable, bounded per-meeting assistant history.
//
// This store NEVER touches `meeting.json`, the notes, the transcript, a
// recording or a meeting snapshot. It keeps only the user's question, the
// action kind, the real conversation/run identities returned by the native
// `prepared` commit, and the exact durable assistant answer (with its message
// id). A corrupt file is preserved by renaming it, never silently deleted.
package com.floe.android.host.meetingassistant

import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal class MeetingAssistantStore private constructor(
    private val root: File,
    private val clock: () -> Long,
) {
    private data class MeetingDoc(
        var conversationId: String?,
        var modelId: String?,
        val entries: MutableList<MeetingAssistantEntry>,
    )

    private val lock = Any()
    private val docs = LinkedHashMap<String, MeetingDoc>()
    private val clearedMeetingIds = LinkedHashSet<String>()
    private var loaded = false
    private var fileUnreadable = false

    fun load(meetingId: String): MeetingAssistantBinding {
        if (!isIdentifier(meetingId)) {
            return MeetingAssistantBinding(null, null, emptyList())
        }
        return synchronized(lock) {
            ensureLoadedLocked()
            val doc = docs[meetingId]
            if (doc == null) {
                MeetingAssistantBinding(null, null, emptyList(), fileUnreadable)
            } else {
                MeetingAssistantBinding(
                    conversationId = doc.conversationId,
                    modelId = doc.modelId,
                    entries = doc.entries.sortedByDescending { it.createdAtMillis },
                    unreadable = fileUnreadable,
                )
            }
        }
    }

    fun conversationId(meetingId: String): String? {
        if (!isIdentifier(meetingId)) return null
        return synchronized(lock) {
            ensureLoadedLocked()
            docs[meetingId]?.conversationId
        }
    }

    fun bindConversation(meetingId: String, conversationId: String): Boolean {
        if (!isIdentifier(meetingId) || !isIdentifier(conversationId)) return false
        return synchronized(lock) {
            ensureLoadedLocked()
            if (meetingId in clearedMeetingIds) return@synchronized false
            val doc = docs.getOrPut(meetingId) { MeetingDoc(null, null, ArrayList()) }
            doc.conversationId = conversationId
            persistLocked()
        }
    }

    fun clearConversation(meetingId: String): Boolean {
        if (!isIdentifier(meetingId)) return false
        return synchronized(lock) {
            ensureLoadedLocked()
            if (meetingId in clearedMeetingIds) return@synchronized false
            val doc = docs[meetingId] ?: return@synchronized true
            doc.conversationId = null
            persistLocked()
        }
    }

    fun selectModel(meetingId: String, modelId: String): Boolean {
        if (!isIdentifier(meetingId) || !isIdentifier(modelId)) return false
        return synchronized(lock) {
            ensureLoadedLocked()
            if (meetingId in clearedMeetingIds) return@synchronized false
            val doc = docs.getOrPut(meetingId) { MeetingDoc(null, null, ArrayList()) }
            doc.modelId = modelId
            persistLocked()
        }
    }

    /**
     * Records the real prepared turn. A later [recordPending] can never
     * downgrade an entry that already settled (the stream may settle before
     * this write reaches the store).
     */
    fun recordPending(meetingId: String, entry: MeetingAssistantEntry): Boolean {
        if (!isIdentifier(meetingId)) return false
        if (!entryBelongsToMeeting(entry, meetingId)) return false
        return synchronized(lock) {
            ensureLoadedLocked()
            if (meetingId in clearedMeetingIds) return@synchronized false
            val doc = docs.getOrPut(meetingId) { MeetingDoc(null, null, ArrayList()) }
            if (doc.conversationId == null) {
                doc.conversationId = entry.conversationId
            }
            val pending = entry.copy(
                status = MeetingAssistantEntryStatus.PENDING,
                answer = null,
                assistantMessageId = null,
                failure = null,
                answerTruncated = false,
            )
            val index = doc.entries.indexOfFirst { it.id == entry.id }
            if (index >= 0) {
                val existing = doc.entries[index]
                if (existing.status != MeetingAssistantEntryStatus.PENDING) {
                    return@synchronized true
                }
                doc.entries[index] = pending
            } else {
                doc.entries.add(pending)
            }
            persistLocked()
        }
    }

    /** Stores the settled, real durable outcome for one prepared turn. */
    fun complete(meetingId: String, entry: MeetingAssistantEntry): Boolean {
        if (!isIdentifier(meetingId)) return false
        if (!entryBelongsToMeeting(entry, meetingId)) return false
        return synchronized(lock) {
            ensureLoadedLocked()
            if (meetingId in clearedMeetingIds) return@synchronized false
            val doc = docs.getOrPut(meetingId) { MeetingDoc(null, null, ArrayList()) }
            if (doc.conversationId == null) {
                doc.conversationId = entry.conversationId
            }
            val bounded = boundAnswer(entry)
            val index = doc.entries.indexOfFirst { it.id == entry.id }
            if (index >= 0) doc.entries[index] = bounded else doc.entries.add(bounded)
            persistLocked()
        }
    }

    /**
     * Removes one meeting's local assistant history; the real task is kept.
     *
     * A successful clear keeps a bounded in-process tombstone, so a late in-flight
     * callback ([recordPending], [complete], [bindConversation],
     * [selectModel], [clearConversation]) cannot rebuild that meeting while
     * the tombstone is retained. When the durable write fails the document is
     * restored and `false` is returned: the history is still fully present,
     * a later call really persists the removal, and the failure is never
     * reported as a success.
     */
    fun clearMeeting(meetingId: String): Boolean {
        if (!isIdentifier(meetingId)) return false
        return synchronized(lock) {
            ensureLoadedLocked()
            if (!docs.containsKey(meetingId)) {
                rememberClearedLocked(meetingId)
                return@synchronized true
            }
            // compactLocked mutates entry lists in place; copy them so a
            // failed persist can honestly restore the pre-clear state.
            val snapshot = docs.mapValues { (_, value) ->
                value.copy(entries = ArrayList(value.entries))
            }
            docs.remove(meetingId)
            if (persistLocked()) {
                rememberClearedLocked(meetingId)
                true
            } else {
                docs.clear()
                docs.putAll(snapshot)
                false
            }
        }
    }

    // ------------------------------------------------------------- internals

    /**
     * Bounded, per-process tombstone of cleared meeting ids. Ids are unique
     * per meeting, so evicting the oldest entry is safe; the bound only caps
     * memory across many deletions in one process life.
     */
    private fun rememberClearedLocked(meetingId: String) {
        clearedMeetingIds.add(meetingId)
        while (clearedMeetingIds.size > MAX_CLEARED_MEETINGS) {
            clearedMeetingIds.remove(clearedMeetingIds.first())
        }
    }

    private fun entryBelongsToMeeting(entry: MeetingAssistantEntry, meetingId: String): Boolean =
        entry.id.startsWith("$meetingId$ENTRY_ID_SEPARATOR") &&
            entry.id.length > meetingId.length + ENTRY_ID_SEPARATOR.length

    private fun ensureLoadedLocked() {
        if (loaded) return
        loaded = true
        val file = file()
        if (!file.exists()) return
        val parsed = runCatching {
            val length = file.length()
            if (length < 0L || length > MAX_FILE_BYTES * 2L) {
                throw IllegalStateException("historyTooLarge")
            }
            decode(file.readText(Charsets.UTF_8))
        }.getOrElse {
            quarantineLocked(file)
            return
        }
        docs.clear()
        docs.putAll(parsed)
    }

    private fun quarantineLocked(file: File) {
        fileUnreadable = true
        val target = File(root, "$FILE_NAME.corrupt-${clock()}")
        runCatching { Files.move(file.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
    }

    private fun file(): File = File(root, FILE_NAME)

    private fun persistLocked(): Boolean {
        compactLocked()
        var encoded = encodeLocked()
        var attempts = 0
        while (encoded.toByteArray(Charsets.UTF_8).size > MAX_FILE_BYTES &&
            attempts < MAX_TRIM_ATTEMPTS
        ) {
            if (!dropOldestNonPendingLocked()) break
            encoded = encodeLocked()
            attempts++
        }
        val bytes = encoded.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_FILE_BYTES) return false
        if (!root.exists() && !root.mkdirs()) return false
        val target = file()
        val temp = File(root, "$FILE_NAME.tmp")
        val written = runCatching {
            FileOutputStream(temp).use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
        }.isSuccess
        if (!written) {
            temp.delete()
            return false
        }
        val moved = runCatching {
            try {
                Files.move(
                    temp.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    temp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        }.isSuccess
        if (!moved) {
            temp.delete()
            return false
        }
        fsyncDirectory(root)
        fileUnreadable = false
        return true
    }

    private fun compactLocked() {
        // Drop meetings that own nothing (a failed selection write).
        docs.entries.removeAll { (_, doc) ->
            doc.conversationId == null && doc.modelId == null && doc.entries.isEmpty()
        }
        if (docs.size > MAX_MEETINGS) {
            val ordered = docs.entries.sortedByDescending { (_, doc) ->
                doc.entries.maxOfOrNull { it.createdAtMillis } ?: Long.MIN_VALUE
            }
            val keep = ordered.take(MAX_MEETINGS).map { it.key }.toSet()
            docs.keys.retainAll(keep)
        }
        docs.values.forEach { doc ->
            if (doc.entries.size > MAX_ENTRIES_PER_MEETING) {
                val pending = doc.entries.filter {
                    it.status == MeetingAssistantEntryStatus.PENDING
                }
                val room = (MAX_ENTRIES_PER_MEETING - pending.size).coerceAtLeast(0)
                val others = doc.entries
                    .filter { it.status != MeetingAssistantEntryStatus.PENDING }
                    .sortedByDescending { it.createdAtMillis }
                    .take(room)
                val kept = (pending + others).sortedBy { it.createdAtMillis }
                doc.entries.clear()
                doc.entries.addAll(kept)
            }
        }
    }

    private fun dropOldestNonPendingLocked(): Boolean {
        val candidates = docs.entries.flatMap { (meetingId, doc) ->
            doc.entries
                .filter { it.status != MeetingAssistantEntryStatus.PENDING }
                .map { meetingId to it }
        }
        if (candidates.isEmpty()) return false
        val dropCount = (candidates.size / 10).coerceAtLeast(1)
        candidates.sortedBy { it.second.createdAtMillis }
            .take(dropCount)
            .forEach { (meetingId, entry) ->
                docs[meetingId]?.entries?.removeAll { it.id == entry.id }
            }
        return true
    }

    private fun encodeLocked(): String {
        val rootObject = buildJsonObject {
            put("version", FORMAT_VERSION)
            put("meetings", buildJsonArray {
                docs.forEach { (meetingId, doc) ->
                    add(buildJsonObject {
                        put("meetingId", meetingId)
                        doc.conversationId?.let { put("conversationId", it) }
                        doc.modelId?.let { put("modelId", it) }
                        put("entries", buildJsonArray {
                            doc.entries.forEach { entry -> add(encodeEntry(entry)) }
                        })
                    })
                }
            })
        }
        return rootObject.toString()
    }

    private fun encodeEntry(entry: MeetingAssistantEntry): JsonObject = buildJsonObject {
        put("id", entry.id)
        put("action", entry.action.name)
        put("question", entry.question)
        put("status", entry.status.name)
        entry.answer?.let { put("answer", it) }
        put("createdAtMillis", entry.createdAtMillis)
        put("notesRevision", entry.notesRevision)
        put("transcriptRevision", entry.transcriptRevision)
        entry.conversationId?.let { put("conversationId", it) }
        entry.runId?.let { put("runId", it) }
        entry.failure?.let { put("failure", it.name) }
        entry.assistantMessageId?.let { put("assistantMessageId", it) }
        if (entry.answerTruncated) put("answerTruncated", true)
    }

    private fun decode(text: String): Map<String, MeetingDoc> {
        val rootObject = json.parseToJsonElement(text).jsonObject
        val version = rootObject.long("version") ?: throw IllegalArgumentException("version")
        if (version != FORMAT_VERSION) throw IllegalArgumentException("version")
        val meetings = rootObject["meetings"] as? JsonArray
            ?: throw IllegalArgumentException("meetings")
        val decoded = LinkedHashMap<String, MeetingDoc>()
        meetings.forEach outer@{ element ->
            val objectValue = element as? JsonObject ?: return@outer
            val meetingId = objectValue.string("meetingId") ?: return@outer
            if (!isIdentifier(meetingId)) return@outer
            val conversationId = objectValue.string("conversationId")
                ?.takeIf(::isIdentifier)
            val modelId = objectValue.string("modelId")?.takeIf(::isIdentifier)
            val entries = ArrayList<MeetingAssistantEntry>()
            (objectValue["entries"] as? JsonArray)?.forEach entry@{ entryElement ->
                val entry = entryElement as? JsonObject ?: return@entry
                decodeEntry(entry, meetingId)?.let(entries::add)
            }
            decoded[meetingId] = MeetingDoc(conversationId, modelId, entries)
        }
        return decoded
    }

    private fun decodeEntry(objectValue: JsonObject, meetingId: String): MeetingAssistantEntry? {
        val id = objectValue.string("id") ?: return null
        if (!id.startsWith("$meetingId$ENTRY_ID_SEPARATOR")) return null
        val action = objectValue.string("action")
            ?.let { raw -> MeetingAssistantAction.entries.firstOrNull { it.name == raw } }
            ?: return null
        val status = objectValue.string("status")
            ?.let { raw -> MeetingAssistantEntryStatus.entries.firstOrNull { it.name == raw } }
            ?: return null
        val question = objectValue.string("question") ?: ""
        if (question.toByteArray(Charsets.UTF_8).size > MAX_QUESTION_BYTES) return null
        val createdAtMillis = objectValue.long("createdAtMillis") ?: return null
        val notesRevision = objectValue.long("notesRevision") ?: 0L
        val transcriptRevision = objectValue.long("transcriptRevision") ?: 0L
        val conversationId = objectValue.string("conversationId")
            ?.takeIf(::isIdentifier)
        val runId = objectValue.string("runId")?.takeIf(::isIdentifier)
        val failure = objectValue.string("failure")
            ?.let { raw -> MeetingAssistantFailureCode.entries.firstOrNull { it.name == raw } }
        val assistantMessageId = objectValue.string("assistantMessageId")
            ?.takeIf(::isIdentifier)
        val answerTruncated = objectValue.bool("answerTruncated") ?: false
        var answerTruncatedOnLoad = false
        val answer = objectValue.string("answer")?.let { raw ->
            if (raw.toByteArray(Charsets.UTF_8).size > MAX_ANSWER_BYTES + 64) {
                answerTruncatedOnLoad = true
                boundedUtf8(raw, MAX_ANSWER_BYTES) + "\n\n[truncated]"
            } else {
                raw
            }
        }
        return MeetingAssistantEntry(
            id = id,
            action = action,
            question = question,
            status = status,
            answer = answer,
            createdAtMillis = createdAtMillis,
            notesRevision = notesRevision,
            transcriptRevision = transcriptRevision,
            conversationId = conversationId,
            runId = runId,
            failure = failure,
            assistantMessageId = assistantMessageId,
            answerTruncated = answerTruncated || answerTruncatedOnLoad,
        )
    }

    private fun boundAnswer(entry: MeetingAssistantEntry): MeetingAssistantEntry {
        val answer = entry.answer ?: return entry
        if (answer.toByteArray(Charsets.UTF_8).size <= MAX_ANSWER_BYTES) {
            return entry.copy(answerTruncated = false)
        }
        val marker = "\n\n[truncated]"
        val room = (MAX_ANSWER_BYTES - marker.toByteArray(Charsets.UTF_8).size).coerceAtLeast(0)
        return entry.copy(
            answer = boundedUtf8(answer, room) + marker,
            answerTruncated = true,
        )
    }

    companion object {
        private const val FILE_NAME = "meeting-assistant-history.json"
        private const val FORMAT_VERSION = 1L
        private const val MAX_FILE_BYTES = 4 * 1024 * 1024
        private const val MAX_MEETINGS = 40
        private const val MAX_ENTRIES_PER_MEETING = 24
        private const val MAX_ANSWER_BYTES = 24_000
        private const val MAX_QUESTION_BYTES = 8_000
        private const val MAX_TRIM_ATTEMPTS = 24
        private const val MAX_CLEARED_MEETINGS = 512
        internal const val ENTRY_ID_SEPARATOR = ":"
        private val json = Json { ignoreUnknownKeys = true; isLenient = false }
        private val instances = HashMap<String, MeetingAssistantStore>()

        fun instance(root: File): MeetingAssistantStore = synchronized(instances) {
            instances.getOrPut(root.absolutePath) {
                MeetingAssistantStore(root, System::currentTimeMillis)
            }
        }

        /** Test seam: a private root and clock with no process-wide reuse. */
        internal fun forTest(root: File, clock: () -> Long): MeetingAssistantStore =
            MeetingAssistantStore(root, clock)
    }
}

internal fun newMeetingAssistantEntryId(meetingId: String): String =
    "$meetingId${MeetingAssistantStore.ENTRY_ID_SEPARATOR}${UUID.randomUUID()}"

/** Strict UUID identity check used for native meeting/model/run identities. */
internal fun isIdentifier(raw: String): Boolean =
    raw.isNotBlank() && runCatching { UUID.fromString(raw) }.isSuccess

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun JsonObject.long(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull

private fun JsonObject.bool(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.let { primitive ->
        when (primitive.content.lowercase()) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

private fun fsyncDirectory(directory: File) {
    runCatching {
        FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal enum class ArtifactHandoffPhase {
    /** Verified private copy exists, launch not yet acknowledged. */
    STAGED,

    /** The explicit target Activity launch was accepted. This is NOT proof
     * that the viewer displayed or the importer saved anything. */
    LAUNCHED,

    /** Grant revoked and private copy removed; no completion inferred. */
    FINISHED,

    /** Operator/model cancellation; grant revoked, copy removed. */
    CANCELLED,

    /** Owner/launch/copy failure retained for an honest status; no grant is
     * active and no success is implied. */
    PAUSED,
}

/**
 * What is actually known about the one platform launch for a record.
 *
 * This is deliberately separate from [ArtifactHandoffRecord.launched] so a
 * definitely-not-dispatched failure stays retryable while a launch whose OS
 * outcome was never recorded stays permanently unreplayable:
 *
 *  - [NONE]      no launch call has been made; a later open may launch.
 *  - [REJECTED]  a trusted preflight refusal, or one of the CLOSED known
 *                no-dispatch platform exceptions (ActivityNotFoundException/
 *                SecurityException); the verified private copy is retained and
 *                may be retried.
 *  - [UNKNOWN]   the OS start call was attempted, or a start receipt was not
 *                recorded (process death, coroutine cancellation, a post-start
 *                publication/callback failure, or any other unobservable
 *                platform error). No later call may replay it; only
 *                status/finish/cancel remain meaningful.
 *  - [ACCEPTED]  the platform accepted the explicit Activity start. This is
 *                still not proof of display, playback, edit or import.
 */
internal enum class ArtifactHandoffLaunchAttempt {
    NONE,
    REJECTED,
    UNKNOWN,
    ACCEPTED,
}

/**
 * One read-only handoff record. `source` is the exact source family; the
 * workspace path or the native-sealed run-output triple is retained so the
 * record itself can never be rebound to another file/output.
 *
 * The file never contains a URI, absolute path, grant token or model text
 * beyond the bounded display name (which is derived from the source name).
 */
internal data class ArtifactHandoffRecord(
    val id: String,
    val owner: ExternalEditOwner,
    val source: String,
    val logicalPath: String?,
    val runID: String?,
    val outputID: String?,
    val displayName: String,
    val mimeType: String,
    val sha256: String,
    val bytes: Long,
    val targetPackage: String,
    val targetComponent: String,
    val phase: ArtifactHandoffPhase,
    val launched: Boolean,
    val toolLaunchKey: String? = null,
    val toolLaunchConfirmed: Boolean = false,
    val launchAttempt: ArtifactHandoffLaunchAttempt = ArtifactHandoffLaunchAttempt.NONE,
    val errorCode: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
) {
    init {
        require(ExternalEditOwner.validUUID(id))
        require(source == "workspace" || source == "output")
        require(
            (source == "workspace" && logicalPath != null && runID == null && outputID == null) ||
                (source == "output" && logicalPath == null && runID != null && outputID != null &&
                    ArtifactHandoffPolicy.validOutputID(outputID) &&
                    ExternalEditOwner.validUUID(runID)),
        )
        require(displayName.isNotBlank() && displayName.length <= ArtifactHandoffPolicy.MAX_DISPLAY_NAME)
        require(displayName.none { it == '/' || it == '\\' || it.code < 32 })
        require(mimeType.isNotBlank() && !mimeType.contains('*') && mimeType.count { it == '/' } == 1)
        require(sha256.length == 64 && sha256.all { it in '0'..'9' || it in 'a'..'f' })
        require(bytes in 0..ArtifactHandoffPolicy.MAX_BYTES)
        require(targetPackage.isNotBlank() && targetComponent.startsWith("$targetPackage/"))
        require(toolLaunchKey == null ||
            (toolLaunchKey.length in 1..256 && toolLaunchKey.none { it.code < 32 }))
        // The attempt is the single source of truth: only ACCEPTED is a
        // confirmed launch, and only a confirmed launch may report launched.
        require((launchAttempt == ArtifactHandoffLaunchAttempt.ACCEPTED) == toolLaunchConfirmed)
        require((launchAttempt == ArtifactHandoffLaunchAttempt.ACCEPTED) == launched)
        require(!launched || phase != ArtifactHandoffPhase.STAGED)
        require(launchAttempt != ArtifactHandoffLaunchAttempt.UNKNOWN ||
            (!launched && !toolLaunchConfirmed))
        require(errorCode == null || errorCode.matches(Regex("[A-Za-z0-9_]{1,80}")))
    }

    val workingRelativePath: String get() = "views/$id/$displayName"
}

/**
 * Crash-safe handoff metadata only. The source bytes remain owned by the
 * workspace/native run-output services; the journal never records a URI or
 * an absolute path. Unknown version/corrupt rows are retained untouched and
 * fail closed (the controller reports `journalUnavailable`).
 */
internal class ArtifactHandoffJournal(private val root: File) {
    init {
        check(!Files.isSymbolicLink(root.toPath()))
        check(root.isDirectory || root.mkdirs())
    }

    fun load(): List<ArtifactHandoffRecord> {
        val files = root.listFiles { file -> file.name.endsWith(".json") }
            ?: error("journalUnavailable")
        check(files.size <= MAX_RECORDS) { "journalCapacity" }
        return files.map { file ->
            check(!Files.isSymbolicLink(file.toPath()) && file.isFile &&
                file.length() in 1..MAX_JSON_BYTES)
            val objectValue = Json.parseToJsonElement(file.readText()) as? JsonObject
                ?: error("journalMalformed")
            decode(objectValue).also { check(file.name == "${it.id}.json") }
        }
    }

    fun save(record: ArtifactHandoffRecord) {
        val destination = File(root, "${record.id}.json")
        check(!Files.isSymbolicLink(destination.toPath()))
        if (!destination.exists()) {
            check((root.listFiles { file -> file.name.endsWith(".json") }?.size
                ?: error("journalUnavailable")) < MAX_RECORDS) { "journalCapacity" }
        }
        val part = File(root, ".${UUID.randomUUID()}.part")
        try {
            val bytes = encode(record).toString().toByteArray(Charsets.UTF_8)
            check(bytes.size <= MAX_JSON_BYTES)
            FileOutputStream(part).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            Files.move(part.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING)
        } finally {
            part.delete()
        }
    }

    companion object {
        private const val MAX_RECORDS = 256
        private const val MAX_JSON_BYTES = 64L * 1024
        private const val VERSION = 1L

        /** Error codes written by a launch attempt that is definitely known
         * NOT to have reached the OS. Older rows lacked `launchAttempt`; these
         * codes let replay protection keep the retryable distinction instead
         * of turning the copy into a permanently unconfirmed record. Every
         * other legacy keyed row is conservatively `UNKNOWN`. */
        private val LEGACY_NOT_DISPATCHED = setOf(
            "foregroundRequired", "targetNotPermitted", "copyChanged", "copyUnavailable",
            "cancelled", "launchRejected", "backgroundUnavailable", "phoneArmRequired",
            "phoneTargetRequired", "phoneServiceNotReady", "phonePausedByUser",
            "phoneFinishing", "phoneBusy", "stoppedByUser", "humanTakeover",
            "deviceLocked", "deviceRunUnavailable", "invalidRequest",
        )

        internal fun encode(record: ArtifactHandoffRecord): JsonObject = buildJsonObject {
            put("version", VERSION)
            put("id", record.id)
            put("taskID", record.owner.taskID)
            put("workspaceID", record.owner.workspaceID)
            put("source", record.source)
            record.logicalPath?.let { put("logicalPath", it) }
            record.runID?.let { put("runID", it) }
            record.outputID?.let { put("outputID", it) }
            put("displayName", record.displayName)
            put("mimeType", record.mimeType)
            put("sha256", record.sha256)
            put("bytes", record.bytes)
            put("targetPackage", record.targetPackage)
            put("targetComponent", record.targetComponent)
            put("phase", record.phase.name)
            put("launched", record.launched)
            record.toolLaunchKey?.let { put("toolLaunchKey", it) }
            put("toolLaunchConfirmed", record.toolLaunchConfirmed)
            put("launchAttempt", record.launchAttempt.name)
            record.errorCode?.let { put("errorCode", it) }
            put("updatedAt", record.updatedAt)
        }

        internal fun decode(value: JsonObject): ArtifactHandoffRecord {
            fun text(key: String): String? = (value[key] as? JsonPrimitive)
                ?.takeIf { it.isString }?.contentOrNull
            fun number(key: String): Long? = (value[key] as? JsonPrimitive)
                ?.takeIf { !it.isString }?.longOrNull
            fun bool(key: String): Boolean? = (value[key] as? JsonPrimitive)
                ?.takeIf { !it.isString }?.booleanOrNull
            require(number("version") == VERSION)
            val toolLaunchKey = text("toolLaunchKey")
            val errorCode = text("errorCode")
            val launched = requireNotNull(bool("launched"))
            // The retired v1 writer did not persist `toolLaunchConfirmed`;
            // a recorded launched start is exactly the old confirmation.
            val confirmed = bool("toolLaunchConfirmed") ?: launched
            val attempt = when (val raw = text("launchAttempt")) {
                null -> when {
                    confirmed -> ArtifactHandoffLaunchAttempt.ACCEPTED
                    toolLaunchKey != null && errorCode != null &&
                        errorCode in LEGACY_NOT_DISPATCHED ->
                        ArtifactHandoffLaunchAttempt.REJECTED
                    toolLaunchKey != null -> ArtifactHandoffLaunchAttempt.UNKNOWN
                    else -> ArtifactHandoffLaunchAttempt.NONE
                }
                else -> ArtifactHandoffLaunchAttempt.valueOf(raw)
            }
            return ArtifactHandoffRecord(
                id = requireNotNull(text("id")),
                owner = ExternalEditOwner(
                    requireNotNull(text("taskID")), requireNotNull(text("workspaceID"))),
                source = requireNotNull(text("source")),
                logicalPath = text("logicalPath"),
                runID = text("runID"),
                outputID = text("outputID"),
                displayName = requireNotNull(text("displayName")),
                mimeType = requireNotNull(text("mimeType")),
                sha256 = requireNotNull(text("sha256")),
                bytes = requireNotNull(number("bytes")),
                targetPackage = requireNotNull(text("targetPackage")),
                targetComponent = requireNotNull(text("targetComponent")),
                phase = ArtifactHandoffPhase.valueOf(requireNotNull(text("phase"))),
                launched = launched,
                toolLaunchKey = toolLaunchKey,
                toolLaunchConfirmed = confirmed,
                launchAttempt = attempt,
                errorCode = errorCode,
                updatedAt = requireNotNull(number("updatedAt")),
            )
        }
    }
}

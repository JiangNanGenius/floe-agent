// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import android.app.Activity
import android.app.KeyguardManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import com.floe.android.FloeApplication
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import com.floe.android.host.output.NativeRunOutputChannel
import com.floe.android.host.output.RunOutputDescriptor
import com.floe.android.host.output.RunOutputListResult
import com.floe.android.host.output.RunOutputOfficeSnapshotStager
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

internal data class ArtifactHandoffState(
    val records: List<ArtifactHandoffRecord> = emptyList(),
    val failure: String? = null,
)

/**
 * Application-owned read-only artifact handoff service.
 *
 * Chain: exact task-owned workspace file OR this run's native-sealed output ->
 * existing verified snapshot stager -> App-private FileProvider copy ->
 * EXPLICIT installed target from the user's Settings > Device app ceiling ->
 * ACTION_VIEW with a READ-ONLY grant. No Downloads write, no whole-storage
 * permission, no operator chooser and no raw model path/ID authority.
 *
 * Two launch routes share that chain:
 *  - the ordinary direct Activity route while this task is visibly foreground;
 *  - the narrow Full-platform background route over the EXISTING PhoneControl
 *    armed owner/epoch/session fence when Floe is backgrounded (for example a
 *    native viewer is already foreground). That route is typed (no Intent,
 *    flags, extras or URI authority from the model), is read-only, and never
 *    creates a grant or selection by itself. If device automation is not
 *    armed, the reply is a typed next step to the real device.observe path.
 *
 * Launch acceptance is only "the platform accepted the explicit Activity
 * request". `saved` and `completed` are always false here: a viewer/import UI
 * being open is not a completed edit or a saved calendar entry. The model
 * must observe, and read back, the actual target app under the existing
 * Phone grants.
 *
 * Definite pre-dispatch failures keep the verified copy retryable; a launch
 * whose OS outcome was not recorded is never replayed under any later call.
 */
internal class ArtifactHandoffController(
    private val context: Context,
    private val host: RuntimeHost,
) {
    private val editsRoot = File(context.filesDir, "ExternalEdits")
    private val root = File(editsRoot, "viewings")
    private val workingParent = File(editsRoot, "working")
    private val workingRoot = File(workingParent, "views")
    private val snapshotRoot = File(root, "snapshots")
    private val outputSnapshotRoot = File(root, "output-snapshots")
    private val lock = Mutex()
    private val records = LinkedHashMap<String, ArtifactHandoffRecord>()
    private val mutableState = MutableStateFlow(ArtifactHandoffState())
    val state: StateFlow<ArtifactHandoffState> = mutableState
    private val journal: ArtifactHandoffJournal? = try {
        check(!Files.isSymbolicLink(editsRoot.toPath()))
        check(!Files.isSymbolicLink(root.toPath()))
        check(!Files.isSymbolicLink(workingParent.toPath()))
        check(!Files.isSymbolicLink(workingRoot.toPath()))
        ArtifactHandoffJournal(File(root, "journal")).also { store ->
            store.load().forEach { records[it.id] = it }
            mutableState.value = ArtifactHandoffState(records.values.toList())
        }
    } catch (_: Exception) {
        mutableState.value = ArtifactHandoffState(failure = "journalUnavailable")
        null
    }

    private class Failure(val code: String) : Exception(code)
    private data class Binding(
        val owner: WorkspaceOfficeSnapshotStager.Owner,
        val current: () -> Boolean,
    )
    private data class SourceFacts(
        val displayName: String,
        val mime: ArtifactHandoffMime,
    )

    private fun publish() {
        mutableState.value = mutableState.value.copy(
            records = records.values.sortedByDescending { it.updatedAt })
    }

    private fun save(record: ArtifactHandoffRecord) {
        (journal ?: throw Failure("journalUnavailable")).save(record)
        records[record.id] = record
        publish()
    }

    private fun sameOwner(a: ExternalEditOwner, b: ExternalEditOwner) =
        a.taskID.equals(b.taskID, true) && a.workspaceID.equals(b.workspaceID, true)

    private fun allowedPackages(): Set<String> =
        host.artifactHandoffTargetAuthority?.allowedTargetPackages().orEmpty()

    /** Reuses the SAME owner/current checks as the reviewed external-edit and
     * workspace services. Nothing here trusts the bridge request's IDs. */
    private suspend fun bind(owner: ExternalEditOwner): Binding {
        val epoch = host.nativeRootEpoch() ?: throw Failure("ownerUnavailable")
        val generation = host.commandClient.generation()
        val current = {
            host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation &&
                host.readiness.value.storeReady &&
                host.conversations.entryFor(owner.taskID)?.isTemporary != true
        }
        val client = G04WorkspaceBridgeClient.bindExisting(host, owner.taskID, current)
        if (!client.workspaceID.equals(owner.workspaceID, true) || !current()) {
            throw Failure("ownerChanged")
        }
        return Binding(
            WorkspaceOfficeSnapshotStager.Owner(
                owner.taskID, client.workspaceID, epoch, generation), current)
    }

    private fun directory(id: String): File {
        require(ExternalEditOwner.validUUID(id))
        check(!Files.isSymbolicLink(workingParent.toPath()))
        check(!Files.isSymbolicLink(workingRoot.toPath()))
        check(workingParent.isDirectory || workingParent.mkdirs())
        check(workingRoot.isDirectory || workingRoot.mkdirs())
        val dir = File(workingRoot, id)
        check(!Files.isSymbolicLink(dir.toPath()))
        check(dir.isDirectory || dir.mkdirs())
        return dir
    }

    private fun workingFile(record: ArtifactHandoffRecord): File =
        File(File(workingRoot, record.id), record.displayName)

    private fun measured(file: File): Pair<String, Long> {
        if (Files.isSymbolicLink(file.toPath()) || !file.isFile ||
            file.length() !in 0..ArtifactHandoffPolicy.MAX_BYTES) {
            throw Failure("copyUnavailable")
        }
        val digest = MessageDigest.getInstance("SHA-256")
        var bytes = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                bytes += count
                if (bytes > ArtifactHandoffPolicy.MAX_BYTES) throw Failure("contentTooLarge")
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } to bytes
    }

    private fun copyVerified(source: File, destination: File, sha256: String, bytes: Long) {
        val parent = destination.parentFile ?: throw Failure("copyUnavailable")
        check(!Files.isSymbolicLink(parent.toPath()))
        check(parent.isDirectory || parent.mkdirs())
        val part = File(parent, ".${UUID.randomUUID()}.part")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var copied = 0L
            source.inputStream().use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > bytes) throw Failure("copyChanged")
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            if (copied != bytes || actual != sha256 || measured(part) != (sha256 to bytes)) {
                throw Failure("copyChanged")
            }
            Files.move(part.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            if (measured(destination) != (sha256 to bytes)) throw Failure("copyChanged")
        } finally {
            part.delete()
        }
    }

    private fun deleteWorking(record: ArtifactHandoffRecord) {
        val dir = File(workingRoot, record.id)
        if (!dir.exists()) return
        val canonicalRoot = workingRoot.canonicalPath + File.separator
        if (!dir.canonicalPath.startsWith(canonicalRoot)) return
        if (Files.isSymbolicLink(dir.toPath())) return
        dir.deleteRecursively()
    }

    private fun revoke(record: ArtifactHandoffRecord) {
        // The URI is derived from the validated record identity, not from a
        // current file existence check: a copy deleted after an UNKNOWN
        // launch must still have any explicit read grant revoked.
        if (Files.isSymbolicLink(workingRoot.toPath()) ||
            Files.isSymbolicLink(File(workingRoot, record.id).toPath())) return
        runCatching {
            val uri = FileProvider.getUriForFile(context,
                "${context.packageName}.externaledits", workingFile(record))
            context.revokeUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    private fun receipt(owner: ExternalEditOwner, runID: String,
                        outputID: String): RunOutputDescriptor {
        val service = host.runOutputs ?: throw Failure("runOutputUnavailable")
        // The native bridge echoes Swift `UUID.uuidString` (uppercase) in its
        // canonical page/path identity. Ask with that exact form so the
        // strict reply grammar and the sealed `RunOutputs/<RUN>/<OUTPUT>`
        // namespace agree; the journal keeps the package's lower-case form.
        return when (val result = service.receipts(owner.taskID.uppercase(), runID.uppercase())) {
            is RunOutputListResult.Ok -> {
                val item = result.items.firstOrNull { it.outputID == outputID }
                    ?: throw Failure("outputMissing")
                if (item.availabilityRaw != "available") throw Failure("outputUnavailable")
                item
            }
            is RunOutputListResult.Refused -> throw Failure("outputUnavailable:${result.status}")
        }
    }

    private fun sourceFacts(owner: ExternalEditOwner, source: String, path: String?,
                            outputID: String?, runID: String?): SourceFacts = when (source) {
        "workspace" -> {
            val relative = path ?: throw Failure("invalidPath")
            val name = ArtifactHandoffPolicy.displayNameFor(relative)
                ?: throw Failure("invalidPath")
            val mime = ArtifactHandoffPolicy.mimeFor(name) ?: throw Failure("unsupportedType")
            SourceFacts(name, mime)
        }
        "output" -> {
            val output = outputID ?: throw Failure("invalidOutput")
            val run = runID ?: throw Failure("invalidRun")
            val descriptor = receipt(owner, run, output)
            val name = ArtifactHandoffPolicy.displayNameFor(descriptor.displayName)
                ?: throw Failure("invalidOutput")
            if (!ArtifactHandoffPolicy.mimeMatchesExtension(name, descriptor.mimeType)) {
                throw Failure("unsupportedType")
            }
            val mime = ArtifactHandoffPolicy.mimeFor(name) ?: throw Failure("unsupportedType")
            SourceFacts(name, mime)
        }
        else -> throw Failure("invalidSource")
    }

    @Suppress("DEPRECATION")
    private fun installedHandlers(mime: ArtifactHandoffMime): List<ArtifactHandoffHandler> {
        val manager = context.packageManager
        // Synthetic probe only: the MIME/scheme is what is matched. It does
        // not name or read a real file, and the actual launch always uses
        // the verified FileProvider URI built for the staged copy.
        val probe = Uri.parse("content://${context.packageName}.externaledits/working/views/probe")
        val rows = LinkedHashMap<String, ArtifactHandoffHandler>()
        for (candidate in mime.all) {
            val intent = Intent(Intent.ACTION_VIEW)
                .addCategory(Intent.CATEGORY_DEFAULT)
                .setDataAndType(probe, candidate)
            val resolved = runCatching { manager.queryIntentActivities(intent, 0) }
                .getOrDefault(emptyList())
            for (info in resolved) {
                val activity = info.activityInfo ?: continue
                val packageName = activity.packageName ?: continue
                val className = activity.name ?: continue
                val component = "$packageName/$className"
                if (rows.containsKey(component)) continue
                val label = runCatching { activity.loadLabel(manager).toString() }
                    .getOrDefault(packageName)
                rows[component] = ArtifactHandoffHandler(
                    packageName = packageName,
                    className = className,
                    label = label.take(80),
                    priority = info.priority,
                    mimeType = candidate,
                )
            }
        }
        return rows.values.take(64)
    }

    private fun candidateJson(handler: ArtifactHandoffHandler): JSONObject = JSONObject()
        .put("packageName", handler.packageName)
        .put("component", handler.componentName)
        .put("label", handler.label)
        .put("mimeType", handler.mimeType)
        .put("priority", handler.priority)

    private fun permitted(handlers: List<ArtifactHandoffHandler>): List<ArtifactHandoffHandler> =
        ArtifactHandoffPolicy.permittedHandlers(
            handlers, allowedPackages(), context.packageName)

    private fun failure(code: String, nextStep: String? = null): JSONObject =
        JSONObject().put("ok", false).put("error", code).apply {
            nextStep?.let { put("nextStep", it) }
        }

    private fun failureFor(record: ArtifactHandoffRecord, code: String,
                           nextStep: String? = null): JSONObject =
        failure(code, nextStep)
            .put("sessionID", record.id)
            .put("launchState", ArtifactHandoffPolicy.launchStateName(record))
            .put("viewerState", ArtifactHandoffPolicy.viewerStateName(record))
            .put("viewerVisible", record.viewerVisible ?: JSONObject.NULL)

    private fun candidateArray(handlers: List<ArtifactHandoffHandler>): JSONArray =
        JSONArray(handlers.map(::candidateJson))

    // MARK: - Tool actions

    suspend fun toolOperation(
        activity: Activity?,
        owner: ExternalEditOwner,
        action: String,
        source: String,
        path: String?,
        outputID: String?,
        runID: String?,
        sessionID: String?,
        targetPackage: String?,
        targetComponent: String?,
        launchKey: String,
        allowed: () -> Boolean,
    ): JSONObject {
        try {
            if (!allowed()) return failure("cancelled")
            if (action == "targets") return targets(owner, source, path, outputID, runID)
            if (action == "open") {
                return lock.withLock {
                    openLocked(activity, owner, source, path, outputID, runID, sessionID,
                        targetPackage, targetComponent, launchKey, allowed)
                }
            }
            val id = sessionID?.takeIf { ArtifactHandoffPolicy.validSessionID(it) }
                ?: return failure("sessionMissing")
            return lock.withLock {
                val row = records[id] ?: return failure("sessionMissing")
                if (!sameOwner(row.owner, owner) || !ArtifactHandoffPolicy.sourceMatches(
                        row, source, path, outputID)) {
                    return failure("ownerChanged")
                }
                if (row.phase == ArtifactHandoffPhase.FINISHED ||
                    row.phase == ArtifactHandoffPhase.CANCELLED) {
                    return terminalReply(row)
                }
                when (action) {
                    "status" -> statusLocked(row, owner)
                    "finish", "cancel" -> finishLocked(row, action == "cancel")
                    else -> failure("invalidAction")
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return failure((error as? Failure)?.code
                ?: (error as? G04WorkspaceBridgeClient.Failure)?.code
                ?: (error as? WorkspaceOfficeSnapshotStager.Failure)?.code
                ?: (error as? RunOutputOfficeSnapshotStager.Failure)?.code
                ?: "operationFailed")
        }
    }

    private suspend fun targets(owner: ExternalEditOwner, source: String, path: String?,
                                outputID: String?, runID: String?): JSONObject {
        bind(owner) // proves task/workspace currency even for a metadata query
        val facts = sourceFacts(owner, source, path, outputID, runID)
        val candidates = permitted(installedHandlers(facts.mime))
        val reply = JSONObject().put("ok", candidates.isNotEmpty())
            .put("source", source)
            .put("displayName", facts.displayName)
            .put("mimeType", facts.mime.primary)
            .put("targets", candidateArray(candidates))
            .put("readOnly", true)
        if (candidates.isEmpty()) reply.put("error", "noPermittedTarget")
        return reply
    }

    private suspend fun openLocked(
        activity: Activity?,
        owner: ExternalEditOwner,
        source: String,
        path: String?,
        outputID: String?,
        runID: String?,
        sessionID: String?,
        targetPackage: String?,
        targetComponent: String?,
        launchKey: String,
        allowed: () -> Boolean,
    ): JSONObject {
        if (!allowed()) return failure("cancelled")
        val currentRunID = runID ?: throw Failure("invalidRun")
        // An active record whose OS launch outcome was never recorded (or
        // whose accepted launch was not observed foreground) blocks ANY later
        // open of the same owner/source, including a different session/key:
        // staging another record would silently replay a launch that may
        // already have reached the viewer/importer. Only an explicit
        // finish/cancel clears it.
        records.values.firstOrNull { row ->
            sameOwner(row.owner, owner) &&
                ArtifactHandoffPolicy.sourceMatches(row, source, path, outputID) &&
                ArtifactHandoffPolicy.blocksNewLaunch(row)
        }?.let { unresolved ->
            val outcomeUnknown = unresolved.launchAttempt ==
                ArtifactHandoffLaunchAttempt.UNKNOWN
            return failureFor(unresolved,
                if (outcomeUnknown) "launchUnconfirmed" else "viewerNotVisible",
                if (outcomeUnknown) {
                    "An earlier launch of this source has an unknown OS outcome; " +
                        "do not open it again. Observe the target, then finish or cancel " +
                        "that session first."
                } else {
                    "An earlier launch of this source was accepted, but the target " +
                        "viewer window was not observed. Observe the device, then " +
                        "finish or cancel that session before trying another target."
                })
        }
        // Another model call cannot overwrite a launch whose OS outcome was
        // lost; the durable record retains the exact launch identity. A
        // definite pre-dispatch refusal remains retryable, while an
        // unconfirmed OS launch is never replayed through any path.
        records.values.firstOrNull { it.toolLaunchKey == launchKey }?.let { existing ->
            if (!sameOwner(existing.owner, owner) || !ArtifactHandoffPolicy.sourceMatches(
                    existing, source, path, outputID)) return failure("ownerChanged")
            when (ArtifactHandoffPolicy.launchDisposition(existing)) {
                ArtifactHandoffLaunchDisposition.ALREADY_LAUNCHED -> return recordReply(existing)
                ArtifactHandoffLaunchDisposition.OUTCOME_UNKNOWN ->
                    return failureFor(existing, "launchUnconfirmed",
                        "The earlier OS launch outcome is unknown; do not repeat open. " +
                            "Observe the target, then status/finish/cancel.")
                ArtifactHandoffLaunchDisposition.TERMINAL ->
                    return failure(
                        if (existing.phase == ArtifactHandoffPhase.CANCELLED)
                            "sessionCancelled" else "sessionFinished",
                    ).put("sessionID", existing.id)
                ArtifactHandoffLaunchDisposition.READY -> {
                    if (sessionID != null && !sessionID.equals(existing.id, true)) {
                        return failure("ownerChanged")
                    }
                    if (targetPackage != null && existing.targetPackage != targetPackage) {
                        return failureFor(existing, "targetNotPermitted")
                    }
                    if (targetComponent != null && existing.targetComponent != targetComponent) {
                        return failureFor(existing, "targetNotPermitted")
                    }
                    val binding = bind(owner)
                    return launchExisting(activity, existing, binding, allowed, currentRunID)
                }
            }
        }
        if (sessionID != null) {
            val existing = records[sessionID] ?: return failure("sessionMissing")
            if (!sameOwner(existing.owner, owner) ||
                !ArtifactHandoffPolicy.sourceMatches(existing, source, path, outputID)) {
                return failure("ownerChanged")
            }
            if (targetPackage != null && existing.targetPackage != targetPackage) {
                return failureFor(existing, "targetNotPermitted")
            }
            if (targetComponent != null && existing.targetComponent != targetComponent) {
                return failureFor(existing, "targetNotPermitted")
            }
            return when {
                existing.phase == ArtifactHandoffPhase.FINISHED ->
                    failure("sessionFinished").put("sessionID", existing.id)
                existing.phase == ArtifactHandoffPhase.CANCELLED ->
                    failure("sessionCancelled").put("sessionID", existing.id)
                else -> when (ArtifactHandoffPolicy.launchDisposition(existing)) {
                    ArtifactHandoffLaunchDisposition.ALREADY_LAUNCHED -> {
                        val file = workingFile(existing)
                        val valid = runCatching {
                            !Files.isSymbolicLink(file.toPath()) && file.isFile &&
                                measured(file) == (existing.sha256 to existing.bytes)
                        }.getOrDefault(false)
                        if (valid) recordReply(existing)
                        else {
                            val latest = existing.copy(phase = ArtifactHandoffPhase.PAUSED,
                                errorCode = "copyUnavailable",
                                updatedAt = System.currentTimeMillis())
                            save(latest)
                            failureFor(latest, "copyUnavailable")
                        }
                    }
                    ArtifactHandoffLaunchDisposition.OUTCOME_UNKNOWN ->
                        failureFor(existing, "launchUnconfirmed",
                            "The earlier OS launch outcome is unknown; do not repeat open. " +
                                "Observe the target, then status/finish/cancel.")
                    ArtifactHandoffLaunchDisposition.TERMINAL ->
                        failure(if (existing.phase == ArtifactHandoffPhase.CANCELLED)
                            "sessionCancelled" else "sessionFinished")
                            .put("sessionID", existing.id)
                    ArtifactHandoffLaunchDisposition.READY -> {
                        val binding = bind(owner)
                        launchExisting(activity, existing, binding, allowed, currentRunID)
                    }
                }
            }
        }
        if (records.values.count { ArtifactHandoffPolicy.canResume(it) } >=
            ArtifactHandoffPolicy.MAX_ACTIVE) {
            return failure("sessionLimit")
        }
        val binding = bind(owner)
        val sourceRunID = if (source == "output") currentRunID else null
        val facts = sourceFacts(owner, source, path, outputID, sourceRunID)
        val permittedHandlers = permitted(installedHandlers(facts.mime))
        val choice = ArtifactHandoffPolicy.selectTarget(
            permittedHandlers, targetPackage, targetComponent)
        return when (choice) {
            is ArtifactHandoffTargetChoice.None -> {
                return failure("noPermittedTarget").put("targets", candidateArray(emptyList()))
            }
            is ArtifactHandoffTargetChoice.Ambiguous -> {
                return failure("targetRequired")
                    .put("targets", candidateArray(choice.handlers))
            }
            is ArtifactHandoffTargetChoice.Refused -> return failure(choice.code)
            is ArtifactHandoffTargetChoice.Selected -> {
                if (!allowed()) return failure("cancelled")
                val id = UUID.randomUUID().toString()
                val (sha256, bytes) = when (source) {
                    "workspace" -> stageWorkspace(binding, path!!, id, facts.displayName)
                    else -> stageOutput(binding, sourceRunID!!, outputID!!, id, facts.displayName)
                }
                if (!binding.current() || !allowed()) {
                    deleteWorking(ArtifactHandoffRecord(
                        id, owner, source, path, sourceRunID, outputID, facts.displayName,
                        facts.mime.primary, sha256, bytes, choice.handler.packageName,
                        choice.handler.componentName, ArtifactHandoffPhase.STAGED, false))
                    return failure("cancelled")
                }
                val record = ArtifactHandoffRecord(
                    id = id,
                    owner = owner,
                    source = source,
                    logicalPath = path,
                    runID = sourceRunID,
                    outputID = outputID,
                    displayName = facts.displayName,
                    mimeType = choice.handler.mimeType,
                    sha256 = sha256,
                    bytes = bytes,
                    targetPackage = choice.handler.packageName,
                    targetComponent = choice.handler.componentName,
                    phase = ArtifactHandoffPhase.STAGED,
                    launched = false,
                    toolLaunchKey = launchKey,
                    toolLaunchConfirmed = false,
                )
                save(record)
                launchExisting(activity, record, binding, allowed, currentRunID)
            }
        }
    }

    private fun stageWorkspace(binding: Binding, path: String, id: String,
                               displayName: String): Pair<String, Long> {
        val snapshot = WorkspaceOfficeSnapshotStager(File(snapshotRoot, id))
            .stageForExternalEdit(binding.owner, path, binding.current)
        return try {
            if (!ArtifactHandoffPolicy.validPath(path) ||
                ArtifactHandoffPolicy.displayNameFor(path) != displayName) {
                throw Failure("invalidPath")
            }
            val destination = File(directory(id), displayName)
            copyVerified(snapshot.file, destination, snapshot.sha256, snapshot.bytes)
            snapshot.sha256 to snapshot.bytes
        } finally {
            snapshot.file.parentFile?.deleteRecursively()
        }
    }

    private fun stageOutput(binding: Binding, runID: String, outputID: String, id: String,
                            displayName: String): Pair<String, Long> {
        val owner = RunOutputOfficeSnapshotStager.Owner(
            conversationID = binding.owner.taskID.uppercase(),
            runID = runID.uppercase(),
            outputID = outputID,
            nativeEpoch = binding.owner.nativeEpoch,
            hostGeneration = binding.owner.hostGeneration,
        )
        val stager = RunOutputOfficeSnapshotStager(
            root = File(outputSnapshotRoot, id),
            channel = NativeRunOutputChannel,
            formats = ArtifactHandoffPolicy.outputFormats,
        )
        val snapshot = stager.stage(owner, binding.current)
        return try {
            val destination = File(directory(id), displayName)
            copyVerified(snapshot.file, destination, snapshot.sha256, snapshot.bytes)
            snapshot.sha256 to snapshot.bytes
        } finally {
            snapshot.file.parentFile?.deleteRecursively()
        }
    }

    /** Re-proves the explicit target at the moment of launch: the package
     * must still be in the user's current target-app ceiling and the exact
     * component must still be an installed ACTION_VIEW handler for the
     * recorded MIME. A stale `targets` result can never authorize a launch. */
    @Suppress("DEPRECATION")
    private fun targetStillPermitted(record: ArtifactHandoffRecord): Boolean {
        if (record.targetPackage !in allowedPackages() ||
            ArtifactHandoffPolicy.forbiddenPackage(record.targetPackage, context.packageName)) {
            return false
        }
        val probe = Uri.parse("content://${context.packageName}.externaledits/working/views/probe")
        val intent = Intent(Intent.ACTION_VIEW)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .setDataAndType(probe, record.mimeType)
        return runCatching { context.packageManager.queryIntentActivities(intent, 0) }
            .getOrDefault(emptyList())
            .any { info ->
                info.activityInfo?.packageName == record.targetPackage &&
                    info.activityInfo?.name == record.targetComponent.substringAfter('/')
            }
    }

    private suspend fun launchExisting(
        activity: Activity?,
        record: ArtifactHandoffRecord,
        binding: Binding,
        allowed: () -> Boolean,
        runID: String,
    ): JSONObject {
        val stillCurrent = { allowed() && binding.current() }
        if (!stillCurrent()) {
            save(record.copy(errorCode = "cancelled", updatedAt = System.currentTimeMillis()))
            return failureFor(record, "cancelled")
        }
        if (!targetStillPermitted(record)) {
            val latest = record.copy(phase = ArtifactHandoffPhase.PAUSED,
                errorCode = "targetNotPermitted", updatedAt = System.currentTimeMillis())
            save(latest)
            return failureFor(latest, "targetNotPermitted")
        }
        // Keep the verified copy for an explicit retry. A missing/changed
        // private copy is a real failure, not a success substitute.
        val copyState = try { measured(workingFile(record)) }
        catch (failure: Failure) {
            val latest = record.copy(phase = ArtifactHandoffPhase.PAUSED,
                errorCode = failure.code, updatedAt = System.currentTimeMillis())
            save(latest)
            return failureFor(latest, failure.code)
        }
        if (copyState != (record.sha256 to record.bytes)) {
            val latest = record.copy(phase = ArtifactHandoffPhase.PAUSED,
                errorCode = "copyChanged", updatedAt = System.currentTimeMillis())
            save(latest)
            return failureFor(latest, "copyChanged")
        }

        val target = foregroundActivity(activity, record.owner.taskID)
        val backgroundLauncher = if (target == null) {
            host.artifactHandoffTargetAuthority?.backgroundDocumentLauncher()
        } else null
        when (ArtifactHandoffPolicy.launchRoute(
            taskVisibleAndSelected = target != null,
            floeVisible = floeVisible(activity),
            backgroundAvailable = backgroundLauncher != null,
        )) {
            ArtifactHandoffLaunchRoute.FOREGROUND_REQUIRED -> {
                // This exact task is not the visible conversation. That is a
                // real foreground precondition; do not take the screen through
                // device automation while the user is looking at another Floe
                // task.
                val latest = record.copy(errorCode = "foregroundRequired",
                    updatedAt = System.currentTimeMillis())
                save(latest)
                return failureFor(latest, "foregroundRequired",
                    "Bring this task to the foreground and retry with the returned sessionID.")
            }
            ArtifactHandoffLaunchRoute.UNAVAILABLE -> {
                val latest = record.copy(errorCode = "backgroundUnavailable",
                    updatedAt = System.currentTimeMillis())
                save(latest)
                return failureFor(latest, "backgroundUnavailable",
                    "No background document route is available; bring this task to the " +
                        "foreground and retry with the returned sessionID.")
            }
            ArtifactHandoffLaunchRoute.FOREGROUND,
            ArtifactHandoffLaunchRoute.BACKGROUND -> Unit
        }

        val file = workingFile(record)
        val uri = try {
            FileProvider.getUriForFile(context, "${context.packageName}.externaledits", file)
        } catch (_: Exception) {
            val latest = record.copy(phase = ArtifactHandoffPhase.PAUSED,
                errorCode = "copyUnavailable", updatedAt = System.currentTimeMillis())
            save(latest)
            return failureFor(latest, "copyUnavailable")
        }
        val launch = ArtifactHandoffPolicy.launchFor(
            ArtifactHandoffHandler(record.targetPackage,
                record.targetComponent.substringAfter('/'),
                record.displayName, 0, record.mimeType),
            record.displayName)
        try {
            context.grantUriPermission(launch.packageName, uri,
                ArtifactHandoffPolicy.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {
            val latest = record.copy(phase = ArtifactHandoffPhase.PAUSED,
                launchAttempt = ArtifactHandoffLaunchAttempt.REJECTED,
                errorCode = "launchRejected", updatedAt = System.currentTimeMillis())
            save(latest)
            return failureFor(latest, "launchRejected")
        }

        // Mark the one OS launch as possibly in flight BEFORE it is issued.
        // If the process dies between here and the accepted-start save, the
        // durable record refuses every later replay instead of duplicating
        // the viewer/importer effect. A typed pre-dispatch refusal below
        // proves no OS call happened and is moved back to REJECTED.
        val inFlight = record.copy(phase = ArtifactHandoffPhase.PAUSED,
            launched = false, toolLaunchConfirmed = false,
            launchAttempt = ArtifactHandoffLaunchAttempt.UNKNOWN,
            errorCode = "launchUnconfirmed", updatedAt = System.currentTimeMillis())
        if (!saveOrNull(inFlight)) {
            revokeReadGrant(uri)
            return failureFor(record, "journalUnavailable")
        }

        if (target != null) {
            val intent = Intent(launch.action)
                .setDataAndType(uri, launch.mimeType)
                .setClassName(launch.packageName, launch.className)
                .addFlags(ArtifactHandoffPolicy.grantFlags(launch))
                .apply { clipData = ClipData.newRawUri(launch.clipLabel, uri) }
            var started = false
            try {
                withContext(Dispatchers.Main) {
                    // Last fence before the OS call: a Stop/cancel that landed
                    // while this coroutine waited for the main thread must not
                    // produce a late viewer launch. A task switch/keyguard in
                    // the same window is a real foreground precondition and
                    // stays a retryable, definitely-not-dispatched refusal.
                    if (!stillCurrent()) throw Failure("cancelled")
                    if (target.isFinishing || target.isDestroyed ||
                        foregroundActivity(activity, record.owner.taskID) == null
                    ) {
                        throw Failure("foregroundRequired")
                    }
                    // Only these two platform exceptions prove that the
                    // target was not started. Every other exception is left
                    // to the boundary below and becomes UNKNOWN, never a
                    // retryable rejection.
                    try {
                        target.startActivity(intent)
                        started = true
                    } catch (_: ActivityNotFoundException) {
                        throw Failure("launchRejected")
                    } catch (_: SecurityException) {
                        throw Failure("launchRejected")
                    }
                }
            } catch (cancelled: CancellationException) {
                if (ArtifactHandoffPolicy.startDisposition(started, false) ==
                    ArtifactHandoffStartDisposition.ACCEPTED) {
                    // startActivity returned before the cancellation: record
                    // the accepted start so no later open can replay it.
                    return acceptedLaunch(inFlight, viewerVisible = null)
                }
                throw cancelled
            } catch (failure: Failure) {
                // Trusted preflight cancellations/foreground requirements and
                // the two closed known no-dispatch exceptions.
                revokeReadGrant(uri)
                val latest = inFlight.copy(launchAttempt = ArtifactHandoffLaunchAttempt.REJECTED,
                    errorCode = failure.code, updatedAt = System.currentTimeMillis())
                return refusedLaunch(latest, failure.code)
            } catch (_: Exception) {
                return when (ArtifactHandoffPolicy.startDisposition(
                    startReturned = started, knownNonDispatch = false)) {
                    ArtifactHandoffStartDisposition.ACCEPTED ->
                        acceptedLaunch(inFlight, viewerVisible = null)
                    ArtifactHandoffStartDisposition.UNKNOWN ->
                        failureFor(inFlight, "launchUnconfirmed",
                            "The OS launch outcome is unknown; do not repeat open. " +
                                "Observe the target, then status/finish/cancel.")
                    ArtifactHandoffStartDisposition.NOT_DISPATCHED -> {
                        // Defensive only: a proven no-dispatch exception is
                        // converted to Failure above and handled there.
                        revokeReadGrant(uri)
                        val latest = inFlight.copy(
                            launchAttempt = ArtifactHandoffLaunchAttempt.REJECTED,
                            errorCode = "launchRejected",
                            updatedAt = System.currentTimeMillis())
                        refusedLaunch(latest, "launchRejected")
                    }
                }
            }
            return acceptedLaunch(inFlight, viewerVisible = null)
        }

        val launcher = backgroundLauncher
            ?: return failureFor(inFlight, "backgroundUnavailable",
                "No background document route is available.")
        val request = ArtifactHandoffBackgroundDocumentRequest(
            taskID = record.owner.taskID,
            runID = runID,
            nativeEpoch = binding.owner.nativeEpoch,
            hostGeneration = binding.owner.hostGeneration,
            uri = uri,
            mimeType = record.mimeType,
            packageName = record.targetPackage,
            className = record.targetComponent.substringAfter('/'),
            displayName = record.displayName,
        )
        val result = try {
            launcher.launch(request, stillCurrent)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            ArtifactHandoffBackgroundLaunchResult.Unknown
        }
        return when (result) {
            is ArtifactHandoffBackgroundLaunchResult.Accepted ->
                acceptedLaunch(inFlight, result.viewerVisible)
            is ArtifactHandoffBackgroundLaunchResult.Refused -> {
                revokeReadGrant(uri)
                val latest = inFlight.copy(launchAttempt = ArtifactHandoffLaunchAttempt.REJECTED,
                    errorCode = result.code, updatedAt = System.currentTimeMillis())
                refusedLaunch(latest, result.code, result.nextStep)
            }
            ArtifactHandoffBackgroundLaunchResult.Unknown -> {
                // The viewer may already hold the read grant; keep it until an
                // explicit finish/cancel/root stop instead of cutting off a
                // launch we cannot see. The durable UNKNOWN state forbids any
                // replay.
                failureFor(inFlight, "launchUnconfirmed",
                    "The OS launch outcome is unknown; do not repeat open. " +
                        "Observe the target, then status/finish/cancel.")
            }
        }
    }

    /** The App's own Activity is visible, but this task is not its selected
     * conversation. The direct route requires an actual foreground task. */
    private fun floeVisible(activity: Activity?): Boolean =
        activity != null && !activity.isFinishing && !activity.isDestroyed &&
            (activity.application as? FloeApplication)?.isActivityInForeground() == true &&
            !activity.getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun revokeReadGrant(uri: Uri) {
        runCatching {
            context.revokeUriPermission(uri, ArtifactHandoffPolicy.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun saveOrNull(record: ArtifactHandoffRecord): Boolean =
        runCatching { save(record) }.isSuccess

    private fun acceptedLaunch(
        inFlight: ArtifactHandoffRecord,
        viewerVisible: Boolean?,
    ): JSONObject {
        // The OS start was accepted. viewerVisible is the separate, bounded
        // post-dispatch foreground read; a null value is reported as unknown
        // and never upgraded to a display/playback claim.
        val launched = inFlight.copy(phase = ArtifactHandoffPhase.LAUNCHED,
            launched = true, toolLaunchConfirmed = true,
            launchAttempt = ArtifactHandoffLaunchAttempt.ACCEPTED, errorCode = null,
            viewerVisible = viewerVisible,
            updatedAt = System.currentTimeMillis())
        if (!saveOrNull(launched)) {
            // The OS accepted the start but the confirmation did not persist.
            // Keep the durable/in-memory UNKNOWN record: never replay, and
            // never claim a confirmed launch we could not record.
            return failureFor(inFlight, "launchUnconfirmed",
                "The viewer may have opened, but the launch receipt could not be recorded; " +
                    "do not repeat open. Observe the target, then status/finish/cancel.")
        }
        return recordReply(launched)
    }

    private fun refusedLaunch(record: ArtifactHandoffRecord, code: String,
                              nextStep: String? = null): JSONObject {
        if (!saveOrNull(record)) {
            val durableUnknown = records[record.id] ?: record
            return failureFor(durableUnknown, "launchUnconfirmed",
                "The launch was refused, but the refusal receipt could not be recorded; " +
                    "do not assume the viewer opened.")
        }
        return failureFor(record, code, nextStep)
    }

    private fun foregroundActivity(activity: Activity?, taskID: String): Activity? =
        activity?.takeIf {
            !it.isFinishing && !it.isDestroyed &&
                (it.application as? FloeApplication)?.isActivityInForeground() == true &&
                host.conversations.currentVisibleConversationId().equals(taskID, true) &&
                !it.getSystemService(KeyguardManager::class.java).isKeyguardLocked
        }

    private suspend fun statusLocked(row: ArtifactHandoffRecord,
                                     owner: ExternalEditOwner): JSONObject {
        bind(owner)
        val file = workingFile(row)
        val present = !Files.isSymbolicLink(file.toPath()) && file.isFile
        val verified = if (present) {
            runCatching { measured(file) == (row.sha256 to row.bytes) }.getOrDefault(false)
        } else false
        if (!present || !verified) {
            val latest = row.copy(phase = ArtifactHandoffPhase.PAUSED,
                errorCode = if (!present) "copyUnavailable" else "copyChanged",
                updatedAt = System.currentTimeMillis())
            save(latest)
            return failureFor(latest, latest.errorCode ?: "copyUnavailable")
                .put("state", latest.phase.name.lowercase())
                .put("launched", latest.launched)
                .put("copyPresent", present)
                .put("copyVerified", verified)
                .put("readOnly", true).put("saved", false).put("completed", false)
        }
        return JSONObject().put("ok", true)
            .put("sessionID", row.id)
            .put("state", row.phase.name.lowercase())
            .put("source", row.source)
            .apply {
                row.logicalPath?.let { put("path", it) }
                row.outputID?.let { put("outputID", it) }
            }
            .put("displayName", row.displayName)
            .put("mimeType", row.mimeType)
            .put("targetPackage", row.targetPackage)
            .put("targetComponent", row.targetComponent)
            .put("sha256", row.sha256)
            .put("byteCount", row.bytes)
            .put("launched", row.launched)
            .put("launchState", ArtifactHandoffPolicy.launchStateName(row))
            .put("viewerState", ArtifactHandoffPolicy.viewerStateName(row))
            .put("viewerVisible", row.viewerVisible ?: JSONObject.NULL)
            .put("copyPresent", true)
            .put("copyVerified", true)
            // An UNKNOWN launch may have opened the viewer, so its read grant
            // is retained until an explicit finish/cancel/root stop.
            .put("grantRetained", row.launchAttempt == ArtifactHandoffLaunchAttempt.ACCEPTED ||
                row.launchAttempt == ArtifactHandoffLaunchAttempt.UNKNOWN)
            .apply {
                if (row.viewerVisible == false) {
                    put("nextStep", "The launch was accepted, but the target viewer window " +
                        "was not observed. Observe the device; if the viewer did not open, " +
                        "finish this session before trying another installed target.")
                }
            }
            .put("readOnly", true).put("saved", false).put("completed", false)
            .put("sourceVerifiedAtLaunch", true)
    }

    private fun finishLocked(row: ArtifactHandoffRecord, cancelled: Boolean): JSONObject {
        revoke(row)
        deleteWorking(row)
        val phase = if (cancelled) ArtifactHandoffPhase.CANCELLED
        else ArtifactHandoffPhase.FINISHED
        val latest = row.copy(phase = phase, errorCode = null,
            updatedAt = System.currentTimeMillis())
        save(latest)
        return JSONObject().put("ok", true)
            .put("sessionID", latest.id)
            .put("state", phase.name.lowercase())
            .put("grantRevoked", true)
            .put("copyRemoved", true)
            .put("launched", latest.launched)
            .put("launchState", ArtifactHandoffPolicy.launchStateName(latest))
            .put("viewerState", ArtifactHandoffPolicy.viewerStateName(latest))
            .put("viewerVisible", latest.viewerVisible ?: JSONObject.NULL)
            .put("readOnly", true).put("saved", false).put("completed", false)
    }

    /** A terminal record is reported as-is: no copy, no grant, no saved or
     * completed claim. Repeated finish/cancel is idempotent. */
    private fun terminalReply(row: ArtifactHandoffRecord): JSONObject =
        recordReply(row)
            .put("copyPresent", false)
            .put("copyVerified", false)
            .put("grantRetained", false)
            .put("grantRevoked", row.phase == ArtifactHandoffPhase.FINISHED ||
                row.phase == ArtifactHandoffPhase.CANCELLED)
            .put("copyRemoved", true)

    private fun recordReply(row: ArtifactHandoffRecord): JSONObject = JSONObject()
        .put("ok", true)
        .put("sessionID", row.id)
        .put("state", row.phase.name.lowercase())
        .put("source", row.source)
        .apply {
            row.logicalPath?.let { put("path", it) }
            row.outputID?.let { put("outputID", it) }
        }
        .put("displayName", row.displayName)
        .put("mimeType", row.mimeType)
        .put("targetPackage", row.targetPackage)
        .put("targetComponent", row.targetComponent)
        .put("sha256", row.sha256)
        .put("byteCount", row.bytes)
        .put("launched", row.launched)
        .put("launchState", ArtifactHandoffPolicy.launchStateName(row))
        .put("viewerState", ArtifactHandoffPolicy.viewerStateName(row))
        .put("viewerVisible", row.viewerVisible ?: JSONObject.NULL)
        .apply {
            if (row.viewerVisible == false) {
                put("nextStep", "The launch was accepted, but the target viewer window was " +
                    "not observed. Observe the device; if the viewer did not open, finish " +
                    "this session before trying another installed target.")
            }
        }
        .put("readOnly", true)
        .put("saved", false)
        .put("completed", false)

    /** Root retirement: revoke every read grant and remove the App-private
     * copies. The source artifact is untouched and remains owned by the
     * workspace/run-output services. */
    suspend fun onRootStopped() {
        lock.withLock {
            var changed = 0
            for (row in records.values.toList()) {
                if (!ArtifactHandoffPolicy.canResume(row)) continue
                runCatching { revoke(row) }
                runCatching { deleteWorking(row) }
                runCatching {
                    save(row.copy(phase = ArtifactHandoffPhase.CANCELLED,
                        errorCode = "runtimeStopped", updatedAt = System.currentTimeMillis()))
                }
                changed += 1
            }
            if (changed > 0) {
                android.util.Log.i("FloeArtifactHandoff", "root_stopped_active=$changed")
            }
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.os.FileObserver
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.SourceHostReply
import com.floe.android.host.WorkspaceOfficeSnapshotStager
import java.io.File
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal data class ExternalEditState(
    val records: List<ExternalEditRecord> = emptyList(),
    val busy: Set<String> = emptySet(),
    val failure: String? = null,
    val preparing: Boolean = false,
)

/** App-owned handoff transport. All original reads/writes go through existing native authority. */
internal class ExternalEditController(private val context: Context, private val host: RuntimeHost) {
    private val root = File(context.filesDir, "ExternalEdits")
    private val lock = Mutex()
    private val records = LinkedHashMap<String, ExternalEditRecord>()
    private val observers = ConcurrentHashMap<String, FileObserver>()
    private val debounce = ConcurrentHashMap<String, Job>()
    private val launchClaim = AtomicBoolean(false)
    private val mutableState = MutableStateFlow(ExternalEditState())
    val state: StateFlow<ExternalEditState> = mutableState
    private val journal: ExternalEditJournal? = try {
        check(!Files.isSymbolicLink(root.toPath()))
        ExternalEditJournal(File(root, "journal")).also { store ->
            store.load().forEach { records[it.id] = it }
            mutableState.value = ExternalEditState(records.values.toList())
        }
    } catch (_: Exception) {
        mutableState.value = ExternalEditState(failure = "journalUnavailable")
        null
    }

    init {
        records.values.filter { it.phase != ExternalEditPhase.FINISHED }.forEach { row ->
            runCatching { watch(row) }.onFailure {
                mutableState.value = mutableState.value.copy(failure = "copyUnavailable")
            }
        }
        // A restored handoff waits for the real registry/workspace to become ready.
        host.scope.launch(host.ioDispatcher) {
            host.readiness.map { it.storeReady }.distinctUntilChanged().collect { ready ->
                if (ready) onForeground()
            }
        }
    }

    private class Failure(val code: String) : Exception(code)
    private data class Binding(val owner: WorkspaceOfficeSnapshotStager.Owner, val current: () -> Boolean)

    private suspend fun bind(owner: ExternalEditOwner): Binding {
        val epoch = host.nativeRootEpoch() ?: throw Failure("ownerUnavailable")
        val generation = host.commandClient.generation()
        val current = {
            host.nativeRootEpoch() == epoch && host.commandClient.generation() == generation &&
                host.readiness.value.storeReady &&
                host.conversations.entryFor(owner.taskID)?.isTemporary == false
        }
        val client = G04WorkspaceBridgeClient.bindExisting(host, owner.taskID, current)
        if (!client.workspaceID.equals(owner.workspaceID, true) || !current()) throw Failure("ownerChanged")
        return Binding(WorkspaceOfficeSnapshotStager.Owner(owner.taskID, client.workspaceID, epoch, generation), current)
    }

    private fun publish() {
        mutableState.value = mutableState.value.copy(records = records.values.sortedByDescending { it.updatedAt })
    }

    private fun save(row: ExternalEditRecord) {
        (journal ?: throw Failure("journalUnavailable")).save(row)
        records[row.id] = row
        publish()
    }

    private fun sameOwner(a: ExternalEditOwner, b: ExternalEditOwner) =
        a.taskID.equals(b.taskID, true) && a.workspaceID.equals(b.workspaceID, true)

    private fun directory(group: String, id: String): File {
        require(ExternalEditOwner.validUUID(id))
        val parent = File(root, group)
        check(!Files.isSymbolicLink(parent.toPath()))
        check(parent.isDirectory || parent.mkdirs())
        return File(parent, id).also {
            check(!Files.isSymbolicLink(it.toPath()))
            check(it.isDirectory || it.mkdirs())
        }
    }

    private fun working(row: ExternalEditRecord) = File(directory("working", row.id), row.displayName)

    private fun measured(file: File): Pair<String, Long> {
        if (Files.isSymbolicLink(file.toPath()) || !file.isFile ||
            file.length() !in 0..ExternalEditPolicy.MAX_BYTES) throw Failure("copyUnavailable")
        val digest = MessageDigest.getInstance("SHA-256")
        var bytes = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                bytes += count
                if (bytes > ExternalEditPolicy.MAX_BYTES) throw Failure("contentTooLarge")
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } to bytes
    }

    /** Copies into a private immutable candidate; the editor never receives its URI. */
    private fun preserve(file: File, id: String, group: String): Pair<File, Pair<String, Long>> {
        val before = measured(file)
        val dir = directory(group, id)
        val result = File(dir, "${before.first}.bin")
        if (result.exists()) {
            if (measured(result) != before) throw Failure("copyChanged")
        } else {
            val part = File(dir, ".${UUID.randomUUID()}.part")
            try {
                file.inputStream().use { input ->
                    FileOutputStream(part).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > ExternalEditPolicy.MAX_BYTES) throw Failure("contentTooLarge")
                            output.write(buffer, 0, count)
                        }
                        output.fd.sync()
                    }
                }
                if (measured(part) != before || measured(file) != before) throw Failure("copyChanged")
                Files.move(part.toPath(), result.toPath())
            } finally { part.delete() }
        }
        return result to before
    }

    private fun snapshot(row: ExternalEditRecord, binding: Binding): WorkspaceOfficeSnapshotStager.Snapshot =
        WorkspaceOfficeSnapshotStager(File(root, "snapshots")).stageForExternalEdit(
            binding.owner, row.logicalPath, binding.current)

    private fun releaseSnapshot(snapshot: WorkspaceOfficeSnapshotStager.Snapshot) {
        // Only this controller's unexposed native transport copy.
        snapshot.file.delete()
        snapshot.file.parentFile?.delete()
    }

    private suspend fun prepare(owner: ExternalEditOwner, path: String, linux: Boolean = false): ExternalEditRecord = lock.withLock {
        if (journal == null) throw Failure("journalUnavailable")
        if (!ExternalEditPolicy.validPath(path)) throw Failure("invalidPath")
        records.values.firstOrNull { sameOwner(it.owner, owner) && it.logicalPath == path &&
            it.phase != ExternalEditPhase.FINISHED }?.let {
            if ((it.linuxWorkingPath != null) != linux) {
                // No handler means no Android editor received a write grant.
                // Explicit Linux fallback may reuse that unchanged recovery copy.
                if (linux && it.linuxWorkingPath == null && it.errorCode == "noEditor" &&
                    it.phase == ExternalEditPhase.EDITING &&
                    measured(working(it)) == (it.baselineSHA256 to it.baselineBytes)) {
                    val handedOff = it.copy(linuxWorkingPath = ".floe-edits/${it.id}/${it.displayName}",
                        errorCode = null, updatedAt = System.currentTimeMillis())
                    save(handedOff)
                    return@withLock handedOff
                }
                throw Failure("editorAlreadyOpen")
            }
            return@withLock it
        }
        if (records.values.count { it.phase != ExternalEditPhase.FINISHED } >= ExternalEditPolicy.MAX_ACTIVE)
            throw Failure("sessionLimit")
        val binding = bind(owner)
        host.workspaceEditors.withExternalMutation(owner.taskID) {
            val stager = WorkspaceOfficeSnapshotStager(File(root, "snapshots"))
            val source = stager.stageForExternalEdit(binding.owner, path, binding.current)
            try {
                val id = UUID.randomUUID().toString()
                val name = path.substringAfterLast('/').filter { it.code >= 32 && it != '\\' }.takeLast(160)
                val row = ExternalEditRecord(id, owner, path, name, source.sha256, source.bytes,
                    source.sourceID, source.sourceRevision,
                    linuxWorkingPath = if (linux) ".floe-edits/$id/$name" else null)
                preserve(source.file, id, "versions")
                val copy = working(row)
                source.file.inputStream().use { input -> FileOutputStream(copy).use { output ->
                    input.copyTo(output, 64 * 1024); output.fd.sync()
                } }
                if (measured(copy) != (source.sha256 to source.bytes) || !binding.current())
                    throw Failure("copyChanged")
                save(row)
                watch(row)
                row
            } finally { releaseSnapshot(source) }
        }
    }

    private fun uri(row: ExternalEditRecord) = FileProvider.getUriForFile(
        context, "${context.packageName}.externaledits", working(row))

    private fun intent(row: ExternalEditRecord, edit: Boolean, file: File = working(row)): Intent {
        val fileURI = FileProvider.getUriForFile(context, "${context.packageName}.externaledits", file)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
            row.displayName.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
        return Intent(if (edit) Intent.ACTION_EDIT else Intent.ACTION_VIEW).apply {
            setDataAndType(fileURI, mime)
            clipData = ClipData.newRawUri(row.displayName, fileURI)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (edit) addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    suspend fun hasActiveLinuxEdit(id: String): Boolean = lock.withLock {
        records[id]?.let { it.linuxWorkingPath != null && it.phase != ExternalEditPhase.FINISHED } == true
    }

    suspend fun prepareLinux(owner: ExternalEditOwner, path: String): ExternalEditRecord =
        prepare(owner, path, linux = true)

    /** A trusted guest transfer writes a private candidate, never the authorized
     * original. The same CAS/provider save path handles Android and Linux edits. */
    suspend fun receiveLinuxSnapshot(id: String, transfer: suspend (File) -> Unit): Boolean {
        val row = lock.withLock {
            val value = records[id] ?: throw Failure("sessionMissing")
            if (value.linuxWorkingPath == null || value.phase == ExternalEditPhase.FINISHED)
                return false
            bind(value.owner)
            value
        }
        val directory = File(root, "linux-candidates").apply { mkdirs() }
        val candidate = File(directory, "${UUID.randomUUID()}.part")
        try {
            transfer(candidate)
            measured(candidate) // Stream limit/digest checked again by the common save path.
            lock.withLock {
                val current = records[id] ?: throw Failure("sessionMissing")
                if (!sameOwner(row.owner, current.owner) || current.linuxWorkingPath != row.linuxWorkingPath ||
                    current.phase == ExternalEditPhase.FINISHED) return false
                val binding = bind(current.owner)
                if (!binding.current()) throw Failure("ownerChanged")
                if (current.phase == ExternalEditPhase.CONFLICT) preserve(working(current), id, "versions")
                val incoming = measured(candidate)
                Files.move(candidate.toPath(), working(current).toPath(),
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
                if (current.phase == ExternalEditPhase.CONFLICT) save(current.copy(
                    editedSHA256 = incoming.first, errorCode = "editedCopyChanged", updatedAt = System.currentTimeMillis()))
            }
            reconcile(id)
            return true
        } finally { candidate.delete() }
    }

    /** Android first. No external handler is an actionable result, not a fake Linux launch. */
    fun openAndroid(activity: Activity, owner: ExternalEditOwner, path: String) {
        if (!launchClaim.compareAndSet(false, true)) return
        mutableState.value = mutableState.value.copy(preparing = true,
            failure = if (journal == null) mutableState.value.failure else null)
        val weakActivity = WeakReference(activity)
        host.scope.launch(host.ioDispatcher) {
            var row: ExternalEditRecord? = null
            try {
                row = prepare(owner, path)
                val binding = bind(row.owner)
                val launch = intent(row, true)
                if (context.packageManager.queryIntentActivities(launch, 0)
                        .none { it.activityInfo.packageName != context.packageName }) throw Failure("noEditor")
                withContext(Dispatchers.Main) {
                    val target = weakActivity.get()?.takeIf { !it.isFinishing && !it.isDestroyed }
                        ?: throw Failure("activityUnavailable")
                    if (!binding.current()) throw Failure("ownerChanged")
                    target.startActivity(Intent.createChooser(launch, null))
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                val code = (error as? Failure)?.code ?: (error as? G04WorkspaceBridgeClient.Failure)?.code ?: "operationFailed"
                lock.withLock {
                    row?.let { records[it.id] }?.let { save(it.copy(errorCode = code, updatedAt = System.currentTimeMillis())) }
                        ?: run { mutableState.value = mutableState.value.copy(failure = code) }
                }
            } finally {
                launchClaim.set(false)
                mutableState.value = mutableState.value.copy(preparing = false)
            }
        }
    }

    fun viewCopy(activity: Activity, id: String) {
        state.value.records.firstOrNull { it.id == id }?.let { row ->
            runCatching { activity.startActivity(Intent.createChooser(intent(row, false), null)) }
                .onFailure { mutableState.value = mutableState.value.copy(failure = "noViewer") }
        }
    }

    fun viewOriginal(activity: Activity, id: String) {
        state.value.records.firstOrNull { it.id == id }?.let { row ->
            runCatching {
                val file = File(directory("versions", row.id), "${row.initialSHA256}.bin")
                if (measured(file).first != row.initialSHA256) throw Failure("copyChanged")
                activity.startActivity(Intent.createChooser(intent(row, false, file), null))
            }.onFailure { mutableState.value = mutableState.value.copy(failure = "noViewer") }
        }
    }

    @Suppress("DEPRECATION")
    private fun watch(row: ExternalEditRecord) {
        if (observers.containsKey(row.id)) return
        val dir = directory("working", row.id)
        val observer = object : FileObserver(dir.path, FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                if (path == row.displayName) {
                    debounce.remove(row.id)?.cancel()
                    debounce[row.id] = host.scope.launch(host.ioDispatcher) { delay(600); reconcile(row.id) }
                }
            }
        }
        if (observers.putIfAbsent(row.id, observer) == null) observer.startWatching()
    }

    fun onForeground() {
        state.value.records.filter { it.phase != ExternalEditPhase.FINISHED }.forEach { row ->
            host.scope.launch(host.ioDispatcher) { reconcile(row.id) }
        }
    }

    fun retry(id: String) { host.scope.launch(host.ioDispatcher) { reconcile(id) } }

    private suspend fun reconcile(id: String) = lock.withLock {
        var row = records[id] ?: return@withLock
        if (row.phase == ExternalEditPhase.FINISHED || row.phase == ExternalEditPhase.CONFLICT) return@withLock
        if (!host.readiness.value.storeReady) return@withLock
        mutableState.value = mutableState.value.copy(busy = mutableState.value.busy + id)
        try {
            val binding = bind(row.owner)
            host.workspaceEditors.withExternalMutation(row.owner.taskID) {
                val current = snapshot(row, binding)
                try {
                    // Recover a commit that landed before its journal ACK, without replaying it.
                    var needsSourceSync = row.phase == ExternalEditPhase.SOURCE_PENDING
                    if (row.pendingSHA256 != null && current.sha256 == row.pendingSHA256 && current.bytes == row.pendingBytes) {
                        row = row.copy(baselineSHA256 = current.sha256, baselineBytes = current.bytes,
                            phase = if (row.sourceID != null) ExternalEditPhase.SOURCE_PENDING else ExternalEditPhase.SAVED,
                            pendingSHA256 = null, pendingBytes = null)
                        save(row)
                        needsSourceSync = row.sourceID != null
                    }
                    val (candidate, edited) = preserve(working(row), id, "candidates")
                    when (ExternalEditPolicy.decide(row.baselineSHA256, current.sha256, edited.first)) {
                        ExternalEditPolicy.Decision.UNCHANGED -> {
                            save(row.copy(errorCode = null,
                                pendingSHA256 = null, pendingBytes = null, updatedAt = System.currentTimeMillis()))
                            if (needsSourceSync) syncProvider(row, binding)
                            return@withExternalMutation
                        }
                        ExternalEditPolicy.Decision.CONFLICT -> {
                            preserve(current.file, id, "versions")
                            save(row.copy(phase = ExternalEditPhase.CONFLICT, conflictSHA256 = current.sha256,
                                editedSHA256 = edited.first, errorCode = "conflict", updatedAt = System.currentTimeMillis()))
                            return@withExternalMutation
                        }
                        ExternalEditPolicy.Decision.REPLACE -> {
                            preserve(current.file, id, "versions")
                            row = row.copy(phase = ExternalEditPhase.COMMITTING, pendingSHA256 = edited.first,
                                pendingBytes = edited.second, errorCode = null, updatedAt = System.currentTimeMillis())
                            save(row)
                            if (!binding.current()) throw Failure("ownerChanged")
                            val answer = SourceHostReply.call { buffer ->
                                WorkspaceSourceNative.saveOriginal(binding.owner.nativeEpoch,
                                    binding.owner.taskID, binding.owner.workspaceID, row.logicalPath,
                                    row.baselineSHA256, edited.first, edited.second, candidate.canonicalPath, buffer)
                            }
                            if (!answer.ok || answer.text("local") != "committed" ||
                                answer.text("committedSHA256") != edited.first || answer.number("committedBytes") != edited.second)
                                throw Failure(if (answer.text("local") == "conflict") "conflict" else "commitUnconfirmed")
                        }
                        ExternalEditPolicy.Decision.ALREADY_COMMITTED -> Unit
                    }
                    if (!binding.current()) throw Failure("ownerChanged")
                    row = row.copy(baselineSHA256 = edited.first, baselineBytes = edited.second,
                        pendingSHA256 = null, pendingBytes = null, conflictSHA256 = null,
                        editedSHA256 = null,
                        phase = if (row.sourceID != null) ExternalEditPhase.SOURCE_PENDING else ExternalEditPhase.SAVED,
                        errorCode = null,
                        updatedAt = System.currentTimeMillis())
                    save(row)
                    // A local CAS receipt does not claim the attached SAF original was updated.
                    if (row.sourceID != null) syncProvider(row, binding)
                } finally { releaseSnapshot(current) }
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            val latest = records[id] ?: row
            val code = (error as? Failure)?.code ?: (error as? G04WorkspaceBridgeClient.Failure)?.code ?: "operationFailed"
            // Retain pending commit identity on unknown outcomes; no success or blind replay.
            save(latest.copy(phase = ExternalEditPhase.PAUSED, errorCode = code, updatedAt = System.currentTimeMillis()))
        } catch (_: LinkageError) {
            save((records[id] ?: row).copy(phase = ExternalEditPhase.PAUSED, errorCode = "runtimeUnavailable"))
        } finally {
            mutableState.value = mutableState.value.copy(busy = mutableState.value.busy - id)
        }
    }

    private suspend fun syncProvider(row: ExternalEditRecord, binding: Binding) {
        // Persist incomplete status BEFORE entering a cancellable provider hop.
        save(row.copy(phase = ExternalEditPhase.SOURCE_PENDING, errorCode = "sourcePending"))
        val lane = host.workspaceSourceHost?.headlessLaneFor(row.owner.taskID,
            row.owner.workspaceID, binding.owner.nativeEpoch, binding.owner.hostGeneration, binding.current)
        val result = lane?.savePathToProvider(row.logicalPath)
        if (result?.status == "ok" && binding.current()) save(row.copy(phase = ExternalEditPhase.SAVED,
            errorCode = null, updatedAt = System.currentTimeMillis()))
    }

    /** The user's decision binds both versions they were shown, never a force overwrite. */
    fun resolve(id: String, useEdited: Boolean, reviewedEditedSHA: String?, reviewedOriginalSHA: String?) {
        host.scope.launch(host.ioDispatcher) {
            var proceed = false
            lock.withLock {
                val row = records[id]?.takeIf { it.phase == ExternalEditPhase.CONFLICT } ?: return@withLock
                try {
                    val binding = bind(row.owner)
                    val current = snapshot(row, binding)
                    try {
                        val actualEditedSHA = measured(working(row)).first
                        if (current.sha256 != row.conflictSHA256 || actualEditedSHA != row.editedSHA256 ||
                            reviewedEditedSHA != row.editedSHA256 || reviewedOriginalSHA != row.conflictSHA256) {
                            preserve(current.file, row.id, "versions")
                            save(row.copy(conflictSHA256 = current.sha256, editedSHA256 = actualEditedSHA,
                                errorCode = "conflictChanged", updatedAt = System.currentTimeMillis()))
                            return@withLock
                        }
                        if (useEdited) {
                            save(row.copy(baselineSHA256 = current.sha256, baselineBytes = current.bytes,
                                phase = ExternalEditPhase.EDITING, conflictSHA256 = null, editedSHA256 = null,
                                pendingSHA256 = null, pendingBytes = null, errorCode = null))
                            proceed = true
                        } else finishLocked(row)
                    } finally { releaseSnapshot(current) }
                } catch (_: Exception) {
                    save(row.copy(errorCode = "conflictChanged", updatedAt = System.currentTimeMillis()))
                }
            }
            if (proceed) reconcile(id)
        }
    }

    fun finish(id: String) {
        host.scope.launch(host.ioDispatcher) { lock.withLock { records[id]?.let(::finishLocked) } }
    }

    private fun finishLocked(row: ExternalEditRecord) {
        // Keep the working copy, original versions and any unconfirmed commit for recovery.
        context.revokeUriPermission(uri(row), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        observers.remove(row.id)?.stopWatching()
        debounce.remove(row.id)?.cancel()
        save(row.copy(phase = ExternalEditPhase.FINISHED,
            errorCode = if (row.pendingSHA256 != null) "commitUnconfirmed" else row.errorCode,
            updatedAt = System.currentTimeMillis()))
    }
}

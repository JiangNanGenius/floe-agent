// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.Settings
import com.floe.android.rootsystem.DeleteReceipt
import com.floe.android.rootsystem.FileEntry
import com.floe.android.rootsystem.FileRead
import com.floe.android.rootsystem.FileWriteReceipt
import com.floe.android.rootsystem.InterfaceInfo
import com.floe.android.rootsystem.MoveReceipt
import com.floe.android.rootsystem.NetworkDiagnostics
import com.floe.android.rootsystem.PackageLifecycleReceipt
import com.floe.android.rootsystem.PackageManagementReceipt
import com.floe.android.rootsystem.PackageQuery
import com.floe.android.rootsystem.PacketCaptureChunk
import com.floe.android.rootsystem.PacketCaptureInfo
import com.floe.android.rootsystem.PackageRecord
import com.floe.android.rootsystem.ProcessRecord
import com.floe.android.rootsystem.RouteInfo
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.ServiceRecord
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.policy.PathPolicy
import com.floe.android.rootsystem.policy.PermissionOpsDecision
import com.floe.android.rootsystem.policy.PermissionOpsPolicy
import com.floe.android.rootsystem.policy.ProtectedTargets
import com.floe.android.rootsystem.policy.StagedApkPolicy
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.net.NetworkInterface
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.concurrent.TimeUnit

/**
 * The complete typed host operation set. No method accepts a command, script,
 * raw binder transaction or model-authored path expression. Every file target
 * is canonicalized and re-checked inside the granted scope; every query is
 * bounded; package management is the closed force-stop/install/uninstall set
 * with protected/system refusal, staged-APK path validation, cooperative
 * cancellation and post-operation PackageManager read-back.
 */
internal class SystemOperations(
    private val context: Context,
    private val identity: ServerIdentity,
) {
    class OpException(val code: String) : Exception(code)

    // Includes the stable Floe parent, not only the package that launched this
    // service: the runtime component is a sibling applicationId.
    private val ownPackages = identity.protectedPackages
    private val captureSessions = RootCaptureSessions(context)
    private val uiOperations = UiOperations(context, identity)

    /**
     * Digest-named staged paths with an in-flight operation. The maintenance
     * release refuses "busy" instead of deleting a live reference; sweeping
     * skips them too.
     */
    private val activeStagedPaths = java.util.Collections.synchronizedSet(HashSet<String>())

    private val settingsOperations = SettingsOperations(
        currentUser = ::currentUserId,
    ) { argv, timeoutMillis, cancelled, onTail ->
        try {
            runPackageChild(
                argv = argv,
                timeoutMillis = timeoutMillis,
                cancelled = cancelled,
                unavailableCode = "settings_unavailable",
                timeoutCode = "settings_timeout",
                onOutputTail = onTail,
            )
        } catch (e: OpException) {
            throw SettingsOperations.SettingsException(e.code)
        }
    }

    init {
        // Abandoned staged copies from a previous service generation are
        // bounded by age and removed before any new operation runs.
        sweepStagingDir()
    }

    // ---------------------------------------------------------------- files

    fun fileList(
        scope: ScopeRoot,
        relativePath: String,
        maxEntries: Int,
        cancelled: () -> Boolean,
    ): List<FileEntry> {
        val bound = maxEntries.coerceIn(1, BinderProtocol.MAX_LIST)
        val root = scopeDirectory(scope)
        val target = resolve(scope, relativePath)
        if (!target.isDirectory) throw OpException("not_directory")
        val children = target.listFiles() ?: throw OpException("list_failed")
        val result = ArrayList<FileEntry>(minOf(children.size, bound))
        for (child in children.sortedWith(compareBy({ !it.isDirectory }, { it.name }))) {
            if (cancelled()) throw OpException("cancelled")
            if (result.size >= bound) break
            // Never follow a symlink out of the granted scope; list only real
            // entries. Operations re-canonicalize and would reject an escape.
            if (Files.isSymbolicLink(child.toPath())) continue
            if (ProtectedTargets.isProtectedPath(child.absolutePath, ownPackages)) continue
            val relative = root.toPath().relativize(child.toPath()).toString()
            if (result.size < bound) {
                result.add(
                    FileEntry(
                        name = child.name.take(BinderProtocol.MAX_NAME),
                        relativePath = relative.take(BinderProtocol.MAX_RELATIVE_PATH),
                        directory = child.isDirectory,
                        sizeBytes = if (child.isFile) child.length() else 0L,
                        modifiedAtMillis = child.lastModified(),
                    ),
                )
            }
        }
        return result
    }

    fun fileRead(
        scope: ScopeRoot,
        relativePath: String,
        offset: Long,
        maxBytes: Int,
    ): FileRead {
        if (offset < 0) throw OpException("offset")
        val limit = maxBytes.coerceIn(1, BinderProtocol.MAX_READ_BYTES)
        val target = resolve(scope, relativePath)
        if (!target.isFile) throw OpException("not_file")
        if (target.length() > MAX_FILE_SERVED_BYTES) throw OpException("file_too_large")
        RandomAccessFile(target, "r").use { file ->
            if (offset > file.length()) throw OpException("offset")
            file.seek(offset)
            val remaining = file.length() - offset
            val readSize = minOf(remaining, limit.toLong()).toInt()
            val bytes = ByteArray(readSize)
            file.readFully(bytes)
            return FileRead(bytes, remaining > readSize)
        }
    }

    fun fileWrite(
        scope: ScopeRoot,
        relativePath: String,
        data: ByteArray,
        overwrite: Boolean,
    ): FileWriteReceipt {
        if (!scope.writable) throw OpException("scope_read_only")
        if (data.size > BinderProtocol.MAX_WRITE_BYTES) throw OpException("write_too_large")
        val root = scopeDirectory(scope)
        val target = resolve(scope, relativePath, writable = true)
        if (target.isDirectory) throw OpException("is_directory")
        val parent = target.parentFile ?: throw OpException("parent")
        if (!parent.isDirectory) throw OpException("parent_missing")
        if (target.exists() && !overwrite) throw OpException("exists")

        // Use the canonical parent for the staging file so a swapped symlink
        // cannot place the temp file inside a protected or out-of-scope tree.
        val parentCanonical = parent.canonicalFile
        if (!PathPolicy.isWithin(root.path, parentCanonical.path)) throw OpException("escape")
        if (ProtectedTargets.isProtectedPath(parentCanonical.path, ownPackages)) {
            throw OpException("protected")
        }
        val temp = Files.createTempFile(parentCanonical.toPath(), ".floe-", ".tmp")
        var committed = false
        try {
            val tempCanonical = temp.toFile().canonicalFile
            if (!PathPolicy.isWithin(root.path, tempCanonical.path)) throw OpException("escape")
            if (ProtectedTargets.isProtectedPath(tempCanonical.path, ownPackages)) {
                throw OpException("protected")
            }
            FileOutputStream(temp.toFile()).use { stream ->
                stream.write(data)
                stream.flush()
                stream.fd.sync()
            }
            // Re-resolve the target immediately before the atomic commit so a
            // replaced ancestor/symlink cannot move the write outside the grant.
            val commitTarget = resolve(scope, relativePath, writable = true)
            if (commitTarget.path != target.path) throw OpException("changed")
            moveAtomic(temp, commitTarget.toPath(), overwrite)
            committed = true
            return FileWriteReceipt(relativePath, data.size, atomic = true)
        } finally {
            if (!committed) runCatching { Files.deleteIfExists(temp) }
        }
    }

    fun fileMove(
        scope: ScopeRoot,
        fromRelativePath: String,
        toRelativePath: String,
        overwrite: Boolean,
    ): MoveReceipt {
        if (!scope.writable) throw OpException("scope_read_only")
        val source = resolve(scope, fromRelativePath, writable = true)
        val destination = resolve(scope, toRelativePath, writable = true)
        if (!source.exists()) throw OpException("not_found")
        // Directory moves are refused entirely, so an ancestor directory can
        // never be relocated across or out of a protected subtree.
        if (source.isDirectory) throw OpException("is_directory")
        if (destination.isDirectory) throw OpException("is_directory")
        if (destination.exists() && !overwrite) throw OpException("exists")
        try {
            val sourceCommit = resolve(scope, fromRelativePath, writable = true)
            val destinationCommit = resolve(scope, toRelativePath, writable = true)
            if (sourceCommit.path != source.path || destinationCommit.path != destination.path) {
                throw OpException("changed")
            }
            if (overwrite) {
                Files.move(
                    source.toPath(),
                    destination.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } else {
                Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            }
        } catch (_: AtomicMoveNotSupportedException) {
            throw OpException("atomic_unavailable")
        }
        return MoveReceipt(fromRelativePath, toRelativePath)
    }

    fun fileDelete(
        scope: ScopeRoot,
        relativePath: String,
        recursive: Boolean,
        cancelled: () -> Boolean,
    ): DeleteReceipt {
        if (!scope.writable) throw OpException("scope_read_only")
        val root = scopeDirectory(scope)
        val target = resolve(scope, relativePath, writable = true)
        if (target == root) throw OpException("scope_root_delete")
        if (!target.exists()) throw OpException("not_found")
        if (target.isDirectory) {
            // Refuse an ancestor directory before walkFileTree deletes any
            // entry: the target may contain Floe credentials or runtime data.
            if (ProtectedTargets.containsProtectedSubtree(target.path, ownPackages)) {
                throw OpException("protected_ancestor")
            }
            val children = target.list()?.size ?: 0
            if (!recursive && children > 0) throw OpException("not_empty")
            val commitTarget = resolve(scope, relativePath, writable = true)
            if (commitTarget.path != target.path) throw OpException("changed")
            val counter = intArrayOf(0)
            Files.walkFileTree(target.toPath(), object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    checkDelete(file)
                    Files.deleteIfExists(file)
                    counter[0]++
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(dir: Path, exc: java.io.IOException?): FileVisitResult {
                    if (exc != null) throw exc
                    checkDelete(dir)
                    Files.deleteIfExists(dir)
                    counter[0]++
                    return FileVisitResult.CONTINUE
                }

                private fun checkDelete(path: Path) {
                    if (cancelled()) throw OpException("cancelled")
                    if (counter[0] >= MAX_DELETE_ENTRIES) throw OpException("delete_budget")
                    val pathString = path.toFile().canonicalPath
                    if (!PathPolicy.isWithin(root.path, pathString)) throw OpException("escape")
                    if (ProtectedTargets.isProtectedPath(pathString, ownPackages)) {
                        throw OpException("protected")
                    }
                    if (ProtectedTargets.isReadOnlySystemPath(pathString)) {
                        throw OpException("scope_read_only")
                    }
                }
            })
            return DeleteReceipt(counter[0])
        }
        val commitTarget = resolve(scope, relativePath, writable = true)
        if (commitTarget.path != target.path) throw OpException("changed")
        Files.deleteIfExists(commitTarget.toPath())
        return DeleteReceipt(1)
    }

    // -------------------------------------------------------------- process

    fun processQuery(filter: String?, maxEntries: Int): List<ProcessRecord> {
        return ProcessTableQuery.select(readProcessTable(), filter, maxEntries)
    }

    // -------------------------------------------------------------- service

    @Suppress("DEPRECATION")
    fun serviceQuery(maxEntries: Int): List<ServiceRecord> {
        val bound = maxEntries.coerceIn(1, BinderProtocol.MAX_LIST)
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: throw OpException("activity_manager")
        return manager.getRunningServices(bound).mapNotNull { info ->
            val component = info.service ?: return@mapNotNull null
            val process = info.process ?: component.packageName
            ServiceRecord(
                processName = process.take(BinderProtocol.MAX_NAME),
                className = component.className.take(BinderProtocol.MAX_TEXT),
                pid = info.pid,
                foreground = info.foreground,
            )
        }
    }

    // -------------------------------------------------------------- package

    fun packageQuery(
        packageName: String?,
        includeSystem: Boolean,
        maxEntries: Int,
        cancelled: () -> Boolean,
        includeUninstalled: Boolean = false,
    ): PackageQuery {
        val bound = maxEntries.coerceIn(1, BinderProtocol.MAX_LIST)
        val manager = context.packageManager
        val runningUids = runCatching { readProcessTable().map { it.uid }.toHashSet() }
            .getOrDefault(hashSetOf<Int>())
        val result = ArrayList<PackageRecord>(bound)
        var truncated = false

        if (packageName != null) {
            if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
            val info = try {
                manager.getPackageInfo(packageName, 0)
            } catch (_: PackageManager.NameNotFoundException) {
                if (!includeUninstalled || !isSystemImagePackageUninstalledForUser(packageName)) {
                    return PackageQuery(emptyList(), false)
                }
                return PackageQuery(
                    listOf(
                        PackageRecord(
                            packageName = packageName,
                            uid = -1,
                            versionCode = 0L,
                            system = true,
                            enabled = false,
                            running = false,
                        ),
                    ),
                    false,
                )
            }
            val app = info.applicationInfo ?: return PackageQuery(emptyList(), false)
            result.add(
                PackageRecord(
                    packageName = info.packageName,
                    uid = app.uid,
                    versionCode = info.longVersionCode,
                    system = (app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0,
                    enabled = app.enabled,
                    running = app.uid in runningUids,
                ),
            )
            return PackageQuery(result, false)
        }

        val packages = try {
            manager.getInstalledPackages(0)
        } catch (_: Throwable) {
            throw OpException("package_list")
        }.sortedBy { it.packageName }
        for (info in packages) {
            if (cancelled()) throw OpException("cancelled")
            val app = info.applicationInfo ?: continue
            val system = (app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
            if (!includeSystem && system) continue
            if (result.size >= bound) {
                truncated = true
                break
            }
            result.add(
                PackageRecord(
                    packageName = info.packageName.take(BinderProtocol.MAX_NAME),
                    uid = app.uid,
                    versionCode = info.longVersionCode,
                    system = system,
                    enabled = app.enabled,
                    running = app.uid in runningUids,
                ),
            )
        }
        if (includeUninstalled && !truncated && result.size < bound) {
            // Merge system-image packages that are uninstalled for the current
            // user (pm list packages -u -s): the only trustworthy discovery
            // path for restore/remove targets, since PackageManager hides them
            // from every UID. They surface disabled with unknown version.
            val known = result.mapTo(HashSet()) { it.packageName }
            for (name in listSystemImagePackagesUninstalledForUser(cancelled)) {
                if (cancelled()) throw OpException("cancelled")
                if (result.size >= bound) {
                    truncated = true
                    break
                }
                if (known.add(name)) {
                    result.add(
                        PackageRecord(
                            packageName = name.take(BinderProtocol.MAX_NAME),
                            uid = -1,
                            versionCode = 0L,
                            system = true,
                            enabled = false,
                            running = false,
                        ),
                    )
                }
            }
        }
        return PackageQuery(result, truncated)
    }

    /**
     * `pm list packages -u -s --user <current>`: system-image packages not
     * installed for the current user. Bounded output, cooperative cancel.
     */
    private fun listSystemImagePackagesUninstalledForUser(cancelled: () -> Boolean): List<String> {
        val currentUser = currentUserId()
        var output = ""
        val exit = runPackageChild(
            argv = listOf(
                "/system/bin/pm", "list", "packages", "-u", "-s",
                "--user", currentUser.toString(),
            ),
            timeoutMillis = PM_LIST_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "pm_unavailable",
            onOutputTail = { output = it },
        )
        if (exit != 0) return emptyList()
        val installed = runCatching {
            context.packageManager.getInstalledPackages(0)
                .mapNotNull { it.packageName }
                .toHashSet()
        }.getOrDefault(hashSetOf())
        return output.lineSequence()
            .map { it.trim() }
            .filter { it.startsWith("package:") }
            .map { it.removePrefix("package:").trim() }
            .filter { it.isNotEmpty() && PACKAGE_NAME.matches(it) && it !in installed }
            .distinct()
            .take(BinderProtocol.MAX_LIST)
            .toList()
    }

    private fun isSystemImagePackageUninstalledForUser(packageName: String): Boolean =
        listSystemImagePackagesUninstalledForUser({ false }).contains(packageName)

    fun forceStopPackage(packageName: String, userId: Int): PackageManagementReceipt {
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        if (userId !in 0..999) throw OpException("user")
        val denial = ProtectedTargets.canManagePackage(
            packageName = packageName,
            userId = userId,
            ownPackages = ownPackages,
            allowed = true,
            operation = "force_stop",
        )
        if (denial != null) throw OpException(denial)

        val uid = packageUid(packageName) ?: throw OpException("package_not_found")
        val exit = runPackageChild(
            argv = listOf("/system/bin/am", "force-stop", "--user", userId.toString(), packageName),
            timeoutMillis = FORCE_STOP_TIMEOUT_MILLIS,
            cancelled = { false },
            unavailableCode = "am_unavailable",
            timeoutCode = "am_timeout",
        )
        if (exit != 0) throw OpException("force_stop_failed")
        Thread.sleep(300)
        val stillRunning = runCatching { readProcessTable().any { it.uid == uid } }
            .getOrDefault(true)
        return PackageManagementReceipt(packageName, userId, "force_stop", stillRunning)
    }

    /**
     * Install one App-staged APK through the real package manager.
     *
     * Ownership boundary: the staged file lives in a user-writable tree, so
     * its bytes are NOT trusted yet. Before anything runs, this service
     * streams a bounded private snapshot into its own staging area
     * (`/data/local/tmp/floe-staging`), verifies the snapshot's size,
     * SHA-256 and archive identity (package/version/signing) against the
     * [com.floe.android.rootsystem.StagedApkBinding] captured at staging
     * time, and only then streams THAT SAME immutable owned snapshot to
     * `pm install -S <exactBytes>` on the child stdin. A modified APK can
     * therefore never reach pm, let alone be committed, before
     * `apk_modified` fails the call. The snapshot is removed in all paths.
     *
     * Transport note: stdin streaming also avoids depending on
     * system_server being able to reopen an app-private path on every
     * supported release.
     *
     * Authority: the staged path is re-validated against the shared-storage
     * ceiling and canonicalized with the service UID; protected/system
     * identities are refused before dispatch. Read-back runs against the
     * exact user the install targeted; a cross-user request is refused
     * instead of being verified against the wrong profile. Success requires
     * the real command completion plus version/signing read-back equality
     * (see [com.floe.android.rootsystem.policy.PackageLifecycleDecision]),
     * so an already-installed OLD package never reports a failed update as
     * success.
     */
    fun installPackage(
        stagedPath: String,
        userId: Int,
        binding: com.floe.android.rootsystem.StagedApkBinding,
        cancelled: () -> Boolean,
    ): PackageLifecycleReceipt {
        if (cancelled()) throw OpException("cancelled")
        val currentUser = currentUserId()
        if (userId != currentUser) throw OpException("cross_user_unsupported")
        val normalized = StagedApkPolicy.normalizeStagedPath(stagedPath)
            ?: throw OpException("apk_path")
        val target = try {
            File(normalized).canonicalFile
        } catch (_: Throwable) {
            throw OpException("apk_path")
        }
        if (!StagedApkPolicy.isStagedPath(target.path)) throw OpException("apk_path")
        // A staged path under the service staging leaf naming scheme must
        // live in THIS process's owned leaf (real backend UID +
        // authenticated bound host package): a Root-owned generation can
        // never be consumed or released by the ADB-owned one and vice versa.
        if (isServiceLeafPath(target.path) &&
            !StagedApkPolicy.isOwnedStagePath(
                target.path, identity.serverUid, identity.packageName)
        ) {
            throw OpException("stage_owner")
        }
        if (!target.isFile) throw OpException("apk_missing")
        if (Files.isSymbolicLink(File(normalized).toPath())) throw OpException("apk_path")
        val size = target.length()
        if (size <= 0L || size > StagedApkPolicy.MAX_APK_BYTES) throw OpException("apk_size")
        if (binding.expectedSizeBytes > 0 && size != binding.expectedSizeBytes) {
            throw OpException("apk_modified")
        }

        // 1) Owned immutable snapshot: copy + digest in one pass, then verify
        //    the SNAPSHOT (never the user-writable source) against the
        //    staging-time binding, including the archive identity.
        synchronized(activeStagedPaths) { activeStagedPaths.add(target.path) }
        val snapshot = try {
            snapshotOwnedCopy(target, cancelled)
        } finally {
            synchronized(activeStagedPaths) { activeStagedPaths.remove(target.path) }
        }
        try {
            if (snapshot.file.length() != size) throw OpException("apk_modified")
            if (binding.expectedSha256 != null &&
                !snapshot.sha256.equals(binding.expectedSha256, ignoreCase = true)
            ) {
                throw OpException("apk_modified")
            }
            val archive = packageArchive(snapshot.file) ?: throw OpException("apk_unreadable")
            val packageName = archive.packageName ?: throw OpException("apk_unreadable")
            if (binding.expectedPackageName != null && packageName != binding.expectedPackageName) {
                throw OpException("apk_identity")
            }
            val denial = ProtectedTargets.canManagePackage(
                packageName = packageName,
                userId = userId,
                ownPackages = ownPackages,
                allowed = true,
                operation = "install",
            )
            if (denial != null) throw OpException(denial)

            // 2) Stream the snapshot bytes to pm stdin; verification and
            //    input are the same owned bytes by construction.
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            var streamedBytes = 0L
            var reason: String? = null
            val exit = runPackageChild(
                argv = listOf(
                    "/system/bin/pm",
                    "install",
                    "-r",
                    "--user",
                    userId.toString(),
                    "-S",
                    size.toString(),
                    // With -S and no path, pm consumes stdin. Some vendor
                    // parsers treat a trailing standalone '-' as an unknown
                    // option rather than the stdin path (Samsung API 33).
                ),
                timeoutMillis = INSTALL_TIMEOUT_MILLIS,
                cancelled = cancelled,
                unavailableCode = "pm_unavailable",
                stdinFile = snapshot.file,
                stdinDigest = digest,
                onStreamedBytes = { sent -> streamedBytes = sent },
                onOutputTail = { reason = conciseFailureReason(it) },
            )
            if (cancelled()) throw OpException("cancelled")
            if (streamedBytes != size) throw OpException("apk_modified")

            val installed = packageInfo(packageName)
            val presentAfter = installed != null
            val decision = com.floe.android.rootsystem.policy.PackageLifecycleDecision.install(
                com.floe.android.rootsystem.policy.PackageLifecycleDecision.InstallFacts(
                    pmExitCode = exit,
                    presentAfter = presentAfter,
                    archiveVersionCode = archive.longVersionCode,
                    installedVersionCode = installed?.longVersionCode,
                    signingMatched = signingDigestsEqual(archive, installed),
                ),
            )
            return PackageLifecycleReceipt(
                packageName = packageName,
                userId = userId,
                operation = "install",
                succeeded = decision.succeeded,
                presentAfter = presentAfter,
                versionCode = installed?.longVersionCode ?: archive.longVersionCode,
                detailCode = decision.detailCode,
                failureDetail = if (decision.succeeded) null else reason,
            )
        } finally {
            runCatching { snapshot.file.delete() }
        }
    }

    /**
     * Copy [source] into the service-owned staging area as one immutable,
     * size-verified snapshot. Each installation owns a fresh file, so a
     * digest-named earlier copy cannot substitute different bytes of the
     * same size. Cancellation is cooperative; uncommitted files are removed.
     */
    private class OwnedSnapshot(val file: File, val sha256: String)

    /**
     * The exact staging leaf this service process owns, created directly
     * under the pre-existing trusted /data/local/tmp: `floe-staging-<uid>-
     * <hostPackage>` from the verified server identity. No shared parent is
     * ever created, so a Root->ADB owner switch never strands the other
     * UID's cache. The resolved leaf is re-verified (real directory, not a
     * symlink, exact expected path) and kept private (0700).
     */
    private fun ownedStageDir(): File {
        val expected = StagedApkPolicy.ownedStageRoot(identity.serverUid, identity.packageName)
            ?: throw OpException("staging_unavailable")
        val dir = File(expected)
        try {
            android.system.Os.mkdir(expected, 0x1C0)
        } catch (failure: android.system.ErrnoException) {
            if (failure.errno != android.system.OsConstants.EEXIST) {
                throw OpException("staging_unavailable")
            }
        }
        // Check the actual owner through a no-follow directory descriptor
        // before changing modes. A pre-existing link or another UID's leaf
        // must never redirect chmod into someone else's directory.
        try {
            val descriptor = android.system.Os.open(
                expected,
                android.system.OsConstants.O_RDONLY or
                    android.system.OsConstants.O_NONBLOCK or
                    android.system.OsConstants.O_NOFOLLOW or
                    android.system.OsConstants.O_CLOEXEC,
                0,
            )
            try {
                val metadata = android.system.Os.fstat(descriptor)
                if (!android.system.OsConstants.S_ISDIR(metadata.st_mode) ||
                    metadata.st_uid != identity.serverUid
                ) throw OpException("staging_unavailable")
                android.system.Os.fchmod(descriptor, 0x1C0)
            } finally {
                android.system.Os.close(descriptor)
            }
        } catch (_: Throwable) {
            throw OpException("staging_unavailable")
        }
        val canonical = try {
            dir.canonicalFile
        } catch (_: Throwable) {
            throw OpException("staging_unavailable")
        }
        if (canonical.path != expected || Files.isSymbolicLink(dir.toPath())) {
            throw OpException("staging_unavailable")
        }
        return canonical
    }

    private fun snapshotOwnedCopy(source: File, cancelled: () -> Boolean): OwnedSnapshot {
        val dir = ownedStageDir()
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val temp = try {
            File.createTempFile(".install-", ".apk", dir)
        } catch (_: Throwable) {
            throw OpException("staging_unavailable")
        }
        var committed = false
        try {
            android.system.Os.chmod(temp.path, 0x180) // owner read/write
            RandomAccessFile(source, "r").use { input ->
                FileOutputStream(temp).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        if (cancelled()) throw OpException("cancelled")
                        val read = input.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                        copied += read
                        if (copied > StagedApkPolicy.MAX_APK_BYTES) throw OpException("apk_size")
                    }
                    output.flush()
                    output.fd.sync()
                }
            }
            if (temp.length() != source.length()) throw OpException("apk_modified")
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            android.system.Os.chmod(temp.path, 0x100) // immutable installation input
            committed = true
            return OwnedSnapshot(temp, sha)
        } finally {
            if (!committed) runCatching { temp.delete() }
        }
    }

    /**
     * Uninstall one third-party package for [userId]. Protected and system
     * packages are refused before dispatch; the outcome is verified with a
     * PackageManager read-back for the exact requested user (cross-user is
     * refused, never verified against the service's own profile), so a
     * reported success always means the package is actually gone for that
     * user.
     */
    fun uninstallPackage(
        packageName: String,
        userId: Int,
        cancelled: () -> Boolean,
    ): PackageLifecycleReceipt {
        if (cancelled()) throw OpException("cancelled")
        val currentUser = currentUserId()
        if (userId != currentUser) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        val denial = ProtectedTargets.canManagePackage(
            packageName = packageName,
            userId = userId,
            ownPackages = ownPackages,
            allowed = true,
            operation = "uninstall",
        )
        if (denial != null) throw OpException(denial)
        val system = packageApplication(packageName)?.let {
            (it.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
        } ?: throw OpException("package_not_found")
        ProtectedTargets.canAlterSystemPackage("uninstall", system)?.let {
            throw OpException(it)
        }

        var reason: String? = null
        val exit = runPackageChild(
            argv = listOf("/system/bin/pm", "uninstall", "--user", userId.toString(), packageName),
            timeoutMillis = UNINSTALL_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "pm_unavailable",
            onOutputTail = { reason = conciseFailureReason(it) },
        )
        if (cancelled()) throw OpException("cancelled")
        val presentAfter = packageInfo(packageName) != null
        val decision = com.floe.android.rootsystem.policy.PackageLifecycleDecision.uninstall(
            com.floe.android.rootsystem.policy.PackageLifecycleDecision.UninstallFacts(
                pmExitCode = exit,
                presentAfter = presentAfter,
            ),
        )
        return PackageLifecycleReceipt(
            packageName = packageName,
            userId = userId,
            operation = "uninstall",
            succeeded = decision.succeeded,
            presentAfter = presentAfter,
            versionCode = 0L,
            detailCode = decision.detailCode,
            failureDetail = if (decision.succeeded) null else reason,
        )
    }

    /**
     * Enable / disable / disable-user one installed app for the CURRENT
     * profile through the real package manager. Floe/platform/security
     * essentials and the packages holding the current launcher, input-method
     * or dialer roles are refused before dispatch; an OS refusal on pm's side
     * is a real per-item failure. Success requires exit 0 AND a
     * PackageManager read-back whose enabledSetting equals the requested
     * state for the same user.
     */
    fun setPackageEnabled(
        packageName: String,
        userId: Int,
        state: String,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.PackageStateReceipt {
        if (cancelled()) throw OpException("cancelled")
        val currentUser = currentUserId()
        if (userId != currentUser) throw OpException("cross_user_unsupported")
        if (state !in com.floe.android.rootsystem.policy.ProtectedTargets.SET_ENABLED_STATES) {
            throw OpException("package_state")
        }
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        val app = packageApplication(packageName) ?: throw OpException("package_not_found")
        val system = (app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
        val denial = com.floe.android.rootsystem.policy.ProtectedTargets.canChangeAppState(
            packageName = packageName,
            userId = userId,
            ownPackages = ownPackages,
            allowed = true,
            operation = "set_enabled",
            systemPackage = system,
            currentRolePackages = resolveCurrentRolePackages(),
        )
        if (denial != null) throw OpException(denial)

        var reason: String? = null
        val exit = runPackageChild(
            argv = listOf(
                "/system/bin/pm", state, "--user", userId.toString(), packageName,
            ),
            timeoutMillis = SET_ENABLED_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "pm_unavailable",
            onOutputTail = { reason = conciseFailureReason(it) },
        )
        if (cancelled()) throw OpException("cancelled")
        val observed = enabledSettingToken(packageName)
        val decision = com.floe.android.rootsystem.policy.PackageLifecycleDecision.setEnabled(
            pmExitCode = exit,
            requestedState = state,
            observedState = observed,
        )
        return com.floe.android.rootsystem.PackageStateReceipt(
            packageName = packageName,
            userId = userId,
            operation = "set_enabled",
            requestedState = state,
            stateAfter = observed,
            succeeded = decision.succeeded,
            detailCode = decision.detailCode,
            failureDetail = if (decision.succeeded) null else reason,
        )
    }

    /**
     * Remove one noncritical preinstalled (system-image) app for the current
     * user. The system image stays intact and the app can be brought back
     * with [restorePackage]. Third-party targets refuse (they use the
     * ordinary uninstall path); protected and current-role packages refuse.
     * Success requires exit 0 plus absence for the exact requested user.
     */
    fun removePackageForUser(
        packageName: String,
        userId: Int,
        cancelled: () -> Boolean,
    ): PackageLifecycleReceipt {
        if (cancelled()) throw OpException("cancelled")
        val currentUser = currentUserId()
        if (userId != currentUser) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        val denial = com.floe.android.rootsystem.policy.ProtectedTargets.canChangeAppState(
            packageName = packageName,
            userId = userId,
            ownPackages = ownPackages,
            allowed = true,
            operation = "remove_for_user",
            systemPackage = packageSystemFlag(packageName),
            currentRolePackages = resolveCurrentRolePackages(),
        )
        if (denial != null) throw OpException(denial)

        var reason: String? = null
        val exit = runPackageChild(
            argv = listOf("/system/bin/pm", "uninstall", "-k", "--user", userId.toString(), packageName),
            timeoutMillis = REMOVE_FOR_USER_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "pm_unavailable",
            onOutputTail = { reason = conciseFailureReason(it) },
        )
        if (cancelled()) throw OpException("cancelled")
        val presentAfter = packageInfo(packageName) != null
        val decision = com.floe.android.rootsystem.policy.PackageLifecycleDecision.removeForUser(
            com.floe.android.rootsystem.policy.PackageLifecycleDecision.UninstallFacts(
                pmExitCode = exit,
                presentAfter = presentAfter,
            ),
        )
        return PackageLifecycleReceipt(
            packageName = packageName,
            userId = userId,
            operation = "remove_for_user",
            succeeded = decision.succeeded,
            presentAfter = presentAfter,
            versionCode = packageInfo(packageName)?.longVersionCode ?: 0L,
            detailCode = decision.detailCode,
            failureDetail = if (decision.succeeded) null else reason,
        )
    }

    /**
     * Restore one system-image app previously removed for the current user
     * (pm install-existing). Present-for-user read-back decides success; a
     * package that is not in the system image refuses honestly.
     */
    fun restorePackage(
        packageName: String,
        userId: Int,
        cancelled: () -> Boolean,
    ): PackageLifecycleReceipt {
        if (cancelled()) throw OpException("cancelled")
        val currentUser = currentUserId()
        if (userId != currentUser) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        val denial = com.floe.android.rootsystem.policy.ProtectedTargets.canChangeAppState(
            packageName = packageName,
            userId = userId,
            ownPackages = ownPackages,
            allowed = true,
            operation = "restore",
            systemPackage = packageSystemFlag(packageName, includeUninstalled = true),
            currentRolePackages = resolveCurrentRolePackages(),
        )
        if (denial != null) throw OpException(denial)

        var reason: String? = null
        val exit = runPackageChild(
            argv = listOf(
                "/system/bin/pm", "install-existing", "--user", userId.toString(), packageName,
            ),
            timeoutMillis = RESTORE_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "pm_unavailable",
            onOutputTail = { reason = conciseFailureReason(it) },
        )
        if (cancelled()) throw OpException("cancelled")
        val presentAfter = packageInfo(packageName) != null
        val decision = com.floe.android.rootsystem.policy.PackageLifecycleDecision.restore(
            com.floe.android.rootsystem.policy.PackageLifecycleDecision.RestoreFacts(
                pmExitCode = exit,
                presentAfter = presentAfter,
            ),
        )
        return PackageLifecycleReceipt(
            packageName = packageName,
            userId = userId,
            operation = "restore",
            succeeded = decision.succeeded,
            presentAfter = presentAfter,
            versionCode = packageInfo(packageName)?.longVersionCode ?: 0L,
            detailCode = decision.detailCode,
            failureDetail = if (decision.succeeded) null else reason,
        )
    }

    // --------------------------------------------------- permissions / appops

    /**
     * Read the real manifest-declared permissions, protection levels and
     * granted state for [packageName] of the CURRENT profile (cross-user
     * refuses honestly; the subsystem is bound to the service's own user).
     * Read-only queries intentionally do NOT carry the mutation-grade
     * protected-target refusal: public package/permission metadata for any
     * selected target may be disclosed. Rows come only from the live
     * PackageManager read; nothing is inferred from the declaration alone.
     */
    fun queryPermissions(
        packageName: String,
        userId: Int,
    ): com.floe.android.rootsystem.PermissionQueryResult {
        if (userId != currentUserId()) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        val info = packageInfoWithPermissions(packageName)
            ?: throw OpException("package_not_found")
        val requested = info.requestedPermissions ?: emptyArray()
        val flags = info.requestedPermissionsFlags ?: IntArray(requested.size)
        val out = ArrayList<com.floe.android.rootsystem.PermissionState>(
            minOf(requested.size, MAX_PERMISSION_QUERY_ROWS),
        )
        for (index in requested.indices) {
            if (out.size >= MAX_PERMISSION_QUERY_ROWS) break
            val name = requested[index].take(PermissionOpsPolicy.MAX_PERMISSION_NAME)
            if (!PermissionOpsPolicy.PERMISSION_NAME.matches(name)) continue
            val protection = runCatching {
                context.packageManager.getPermissionInfo(name, 0)?.protectionLevel
            }.getOrNull() ?: continue
            val granted = index < flags.size &&
                (flags[index] and
                    android.content.pm.PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0
            out += com.floe.android.rootsystem.PermissionState(
                name = name,
                protectionLevel = PermissionOpsPolicy.protectionToken(protection),
                granted = granted,
            )
        }
        out.sortWith(
            compareByDescending<com.floe.android.rootsystem.PermissionState> { it.granted }
                .thenBy { it.name },
        )
        return com.floe.android.rootsystem.PermissionQueryResult(packageName, userId, out)
    }

    /**
     * Grant or revoke one manifest-declared runtime (dangerous) or
     * development permission for the current user through the real
     * `pm grant/revoke --user` path. The declaration and its protection
     * level are re-validated here from the live package record (never from
     * model text); signature/fixed/admin/platform permissions refuse as
     * "permission_protected" before dispatch; a package sharing its UID with
     * another package refuses as "shared_uid_refused" because a UID-scoped
     * runtime grant cannot avoid collateral effect on the sibling.
     * [grantedBefore] is established from the live read before any mutation
     * and the call refuses when the profile cannot be established. Success
     * requires exit 0 plus an independent read-back of the same user's grant
     * state, so an OS refusal is a real per-item failure, never "success".
     */
    fun managePermission(
        packageName: String,
        userId: Int,
        permission: String,
        action: String,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.PermissionSetReceipt {
        if (cancelled()) throw OpException("cancelled")
        if (userId != currentUserId()) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        if (ProtectedTargets.isProtectedPackage(packageName, ownPackages)) {
            throw OpException("protected_target")
        }
        if (action !in PermissionOpsPolicy.ACTIONS) throw OpException("permission_action")
        if (!PermissionOpsPolicy.PERMISSION_NAME.matches(permission)) {
            throw OpException("permission")
        }
        val info = packageInfoWithPermissions(packageName)
            ?: throw OpException("package_not_found")
        sharedUidRefusal(packageName)?.let { throw OpException(it) }
        val requested = info.requestedPermissions ?: emptyArray()
        if (permission !in requested) throw OpException("permission_not_declared")
        val protection = runCatching {
            context.packageManager.getPermissionInfo(permission, 0)?.protectionLevel
        }.getOrNull() ?: throw OpException("permission_unknown")
        PermissionOpsPolicy.permissionMutable(protection)?.let { throw OpException(it) }
        val grantedBefore = permissionGranted(packageName, permission)
            ?: throw OpException("verify_unavailable")

        var reason: String? = null
        val exit = runPackageChild(
            argv = listOf(
                "/system/bin/pm", action, "--user", userId.toString(), packageName, permission,
            ),
            timeoutMillis = PERMISSION_SET_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "pm_unavailable",
            onOutputTail = { reason = conciseFailureReason(it) },
        )
        if (cancelled()) throw OpException("cancelled")
        val grantedAfter = permissionGranted(packageName, permission)
            ?: throw OpException("verify_unavailable")
        val decision = PermissionOpsDecision.permission(exit, action, grantedAfter)
        return com.floe.android.rootsystem.PermissionSetReceipt(
            packageName = packageName,
            userId = userId,
            permission = permission,
            action = action,
            grantedBefore = grantedBefore,
            grantedAfter = grantedAfter,
            succeeded = decision.succeeded,
            detailCode = decision.detailCode,
            failureDetail = if (decision.succeeded) null else reason,
        )
    }

    /**
     * Read the closed-catalog AppOps modes for [packageName] of the current
     * user: one bounded single-operation `appops get --user <u> <pkg> <OP>`
     * per catalog entry (never --uid, never a multi-op dump to parse). Like
     * the permission query this read-only disclosure is NOT subject to the
     * mutation-grade protected-target refusal. Each row preserves the
     * per-package override, the UID-level mode and the platform default
     * SEPARATELY plus the computed effective mode; an unparseable single-op
     * response reports an "unknown" row instead of a fabricated default,
     * and a failed read fails the whole query honestly.
     */
    fun queryAppOps(
        packageName: String,
        userId: Int,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.AppOpsQueryResult {
        if (cancelled()) throw OpException("cancelled")
        if (userId != currentUserId()) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        if (packageApplication(packageName) == null) throw OpException("package_not_found")
        val sdk = android.os.Build.VERSION.SDK_INT
        val ops = ArrayList<com.floe.android.rootsystem.AppOpsModeState>(
            PermissionOpsPolicy.APP_OPS.size,
        )
        val queryDeadline = android.os.SystemClock.elapsedRealtime() + APPOPS_GET_TIMEOUT_MILLIS
        for (spec in PermissionOpsPolicy.APP_OPS) {
            if (sdk < spec.minSdk) continue
            if (cancelled()) throw OpException("cancelled")
            val remaining = queryDeadline - android.os.SystemClock.elapsedRealtime()
            if (remaining <= 0L) throw OpException("appops_timeout")
            val opName = spec.opName
            val parsed = try {
                readAppOpsParsed(packageName, userId, opName, cancelled,
                    timeoutMillis = minOf(APPOPS_GET_TIMEOUT_MILLIS, remaining))
            } catch (e: OpException) {
                if (e.code == "appops_unparseable") {
                    // Row-level honest refusal: keep the row, mark unknown.
                    PermissionOpsPolicy.AppOpsGet(null, null, null, false, true)
                } else {
                    throw e
                }
            }
            ops += com.floe.android.rootsystem.AppOpsModeState(
                operation = spec.token,
                opName = opName,
                overrideMode = parsed.overrideMode,
                uidMode = parsed.uidMode,
                defaultMode = parsed.defaultMode,
                effective = PermissionOpsDecision.effectiveMode(
                    parsed.overrideMode,
                    parsed.uidMode,
                    parsed.defaultMode,
                    parsed.noOperations,
                ),
            )
        }
        return com.floe.android.rootsystem.AppOpsQueryResult(packageName, userId, ops)
    }

    /**
     * Set one closed-catalog AppOps mode for [packageName] of the current
     * user through the real `appops set` path. Two closed write scopes:
     *
     *  - [PermissionOpsPolicy.SCOPE_PACKAGE] (the legacy default): the
     *    package form `appops set --user <u> <pkg> <op> <mode>`; a package
     *    sharing its UID with another package refuses before dispatch as
     *    "shared_uid_refused".
     *  - [PermissionOpsPolicy.SCOPE_UID]: the UID form `appops set --user
     *    <u> --uid <uid> <op> <mode>`. The UID is resolved HERE from the
     *    live installed identity of the selected package (never accepted
     *    from the wire), must be uniquely owned by exactly this package
     *    (shared UIDs and unresolvable ownership refuse), and the identity
     *    is re-validated immediately before dispatch so a stale UID mapping
     *    fails closed ("uid_identity_changed") instead of writing another
     *    app's UID mode. Only the protected/critical package refusal and
     *    the current-profile binding apply as for the package scope.
     *
     * The restorable BEFORE state (override/UID/default separately) is
     * captured before the set and the observed rows after it; unparseable
     * read-back refuses instead of reporting success. Success requires exit
     * 0 plus a read-back proving the request ON THE REQUESTED SCOPE's row:
     * a concrete mode equals that row, "default" is proven by the row being
     * gone OR recorded as "default". Per the frozen C1 evidence a package
     * override match must never be reported as an effective UID change.
     */
    fun manageAppOps(
        packageName: String,
        userId: Int,
        operation: String,
        mode: String,
        scope: String = PermissionOpsPolicy.SCOPE_PACKAGE,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.AppOpsSetReceipt {
        if (cancelled()) throw OpException("cancelled")
        if (userId != currentUserId()) throw OpException("cross_user_unsupported")
        if (!PACKAGE_NAME.matches(packageName)) throw OpException("package")
        if (ProtectedTargets.isProtectedPackage(packageName, ownPackages)) {
            throw OpException("protected_target")
        }
        val scopeToken = PermissionOpsPolicy.appOpScope(scope)
            ?: throw OpException("appop_scope")
        val sdk = android.os.Build.VERSION.SDK_INT
        val spec = PermissionOpsPolicy.appOp(operation, sdk)
            ?: throw OpException("appop_operation")
        if (!PermissionOpsPolicy.modeSupported(mode, sdk)) throw OpException("appop_mode")
        if (packageApplication(packageName) == null) throw OpException("package_not_found")
        sharedUidRefusal(packageName)?.let { throw OpException(it) }
        val opName = spec.opName
        val uidScope = scopeToken == PermissionOpsPolicy.SCOPE_UID
        // The UID-scope target must still be a CURRENTLY INSTALLED package:
        // resolution is installed-only by construction (packageApplication),
        // so removed-for-user/system-image-only identities refuse here.
        val resolvedUid = if (uidScope) resolveUniqueUidOrThrow(packageName) else -1

        val before = readAppOpsParsed(
            packageName, userId, opName, cancelled,
            uid = if (uidScope) resolvedUid else null,
        )
        if (uidScope) revalidateUidIdentityOrThrow(packageName, resolvedUid)
        var reason: String? = null
        val exit = runPackageChild(
            argv = if (uidScope) {
                listOf(
                    "/system/bin/appops", "set", "--user", userId.toString(),
                    "--uid", resolvedUid.toString(), opName, mode,
                )
            } else {
                listOf(
                    "/system/bin/appops", "set", "--user", userId.toString(),
                    packageName, opName, mode,
                )
            },
            timeoutMillis = APPOPS_SET_TIMEOUT_MILLIS,
            cancelled = cancelled,
            unavailableCode = "appops_unavailable",
            timeoutCode = "appops_timeout",
            onOutputTail = { reason = conciseFailureReason(it) },
        )
        if (cancelled()) throw OpException("cancelled")
        val after = readAppOpsParsed(
            packageName, userId, opName, cancelled,
            uid = if (uidScope) resolvedUid else null,
        )
        if (uidScope) revalidateUidIdentityOrThrow(packageName, resolvedUid)
        val decision = PermissionOpsDecision.appOps(
            exit, mode, after.overrideMode, scopeToken, after.uidMode,
        )
        return com.floe.android.rootsystem.AppOpsSetReceipt(
            packageName = packageName,
            userId = userId,
            operation = spec.token,
            opName = opName,
            scope = scopeToken,
            resolvedUid = resolvedUid,
            overrideBefore = before.overrideMode,
            uidBefore = before.uidMode,
            defaultBefore = before.defaultMode,
            effectiveBefore = PermissionOpsDecision.effectiveMode(
                before.overrideMode,
                before.uidMode,
                before.defaultMode,
                before.noOperations,
            ),
            requestedMode = mode,
            overrideAfter = after.overrideMode,
            uidAfter = after.uidMode,
            effectiveAfter = PermissionOpsDecision.effectiveMode(
                after.overrideMode,
                after.uidMode,
                after.defaultMode,
                after.noOperations,
            ),
            succeeded = decision.succeeded,
            detailCode = decision.detailCode,
            failureDetail = if (decision.succeeded) null else reason,
        )
    }

    /**
     * Authoritative service-side UID resolution for the UID write scope:
     * the installed application identity of [packageName] gives the UID,
     * and the UID must be owned by EXACTLY this package. Shared UIDs
     * ("shared_uid_refused") and unresolvable/inconsistent ownership
     * ("uid_scope_unavailable") refuse; the numeric UID itself is never
     * taken from the caller.
     */
    private fun resolveUniqueUidOrThrow(packageName: String): Int {
        val uid = packageApplication(packageName)?.uid ?: throw OpException("package_not_found")
        val siblings = runCatching {
            context.packageManager.getPackagesForUid(uid)?.distinct()
        }.getOrNull() ?: throw OpException("uid_scope_unavailable")
        PermissionOpsPolicy.uidScopeOwnershipRefusal(siblings, packageName)
            ?.let { throw OpException(it) }
        return uid
    }

    /**
     * Stale-identity guard: re-resolve the package->UID mapping and the UID
     * ownership immediately BEFORE the mutation so an identity that changed
     * between the capture read and the set fails closed instead of writing
     * the mode onto a different UID.
     */
    private fun revalidateUidIdentityOrThrow(packageName: String, uid: Int) {
        val current = packageApplication(packageName)?.uid
            ?: throw OpException("package_not_found")
        if (current != uid) throw OpException("uid_identity_changed")
        val siblings = runCatching {
            context.packageManager.getPackagesForUid(uid)?.distinct()
        }.getOrNull() ?: throw OpException("uid_scope_unavailable")
        PermissionOpsPolicy.uidScopeOwnershipRefusal(siblings, packageName)
            ?.let { throw OpException(it) }
    }

    /**
     * One bounded single-operation `appops get`. Command failure maps to a
     * typed code; unparseable output maps to "appops_unparseable" so callers
     * fail closed instead of treating ambiguity as absence.
     */
    private fun readAppOpsParsed(
        packageName: String,
        userId: Int,
        opName: String,
        cancelled: () -> Boolean,
        timeoutMillis: Long = APPOPS_GET_TIMEOUT_MILLIS,
        uid: Int? = null,
    ): PermissionOpsPolicy.AppOpsGet {
        // A numeric-UID query omits package overrides. Preserve the package
        // snapshot as well so a UID write cannot report that override as absent.
        val packageState = if (uid != null) {
            readAppOpsParsed(packageName, userId, opName, cancelled, timeoutMillis)
        } else {
            null
        }
        var tail: String? = null
        // UID form (`--uid <uid>`) is used only for the UID write scope's
        // before/after reads; the package form stays the default everywhere.
        val exit = runPackageChild(
            argv = if (uid != null) {
                listOf(
                    "/system/bin/appops", "get", "--user", userId.toString(),
                    "--uid", uid.toString(), opName,
                )
            } else {
                listOf(
                    "/system/bin/appops", "get", "--user", userId.toString(),
                    packageName, opName,
                )
            },
            timeoutMillis = timeoutMillis,
            cancelled = cancelled,
            unavailableCode = "appops_unavailable",
            timeoutCode = "appops_timeout",
            maxOutputChars = APPOPS_MAX_OUTPUT_CHARS,
            onOutputTail = { tail = it },
        )
        if (exit != 0) throw OpException("appops_get_failed")
        val parsed = PermissionOpsPolicy.parseAppOpsGet(tail ?: "", opName)
        if (parsed.unparseable) throw OpException("appops_unparseable")
        return packageState?.copy(uidMode = parsed.uidMode) ?: parsed
    }

    /**
     * Refuse when [packageName] shares its Linux UID with another package:
     * UID-scoped runtime grants/AppOps entries cannot avoid collateral
     * effect on the sibling, so the mutation is out of scope even though
     * the package-form argv itself looks targeted. Queries may still
     * disclose the state honestly.
     */
    private fun sharedUidRefusal(packageName: String): String? {
        val uid = packageApplication(packageName)?.uid ?: return "package_not_found"
        val siblings = runCatching {
            context.packageManager.getPackagesForUid(uid)?.distinct()
        }.getOrNull() ?: return "uid_scope_unavailable"
        if (siblings.isEmpty() || packageName !in siblings) return "uid_scope_unavailable"
        return PermissionOpsPolicy.sharedUidRefusal(siblings.size)
    }

    /** Live permission grant read-back for the service's own user profile. */
    private fun permissionGranted(packageName: String, permission: String): Boolean? = try {
        context.packageManager.checkPermission(permission, packageName) ==
            PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) {
        null
    }

    private fun packageInfoWithPermissions(
        packageName: String,
    ): android.content.pm.PackageInfo? = try {
        context.packageManager.getPackageInfo(
            packageName,
            android.content.pm.PackageManager.GET_PERMISSIONS,
        )
    } catch (_: Throwable) {
        null
    }

    /**
     * Packages holding device-critical roles right now: the resolved default
     * launcher (HOME), Settings.Secure default input method, and the Telecom
     * default dialer. Real role holders, never model-supplied names.
     */
    private fun resolveCurrentRolePackages(): Set<String> {
        val roles = LinkedHashSet<String>()
        runCatching {
            val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
                .addCategory(android.content.Intent.CATEGORY_HOME)
            val resolved = if (android.os.Build.VERSION.SDK_INT >= 33) {
                context.packageManager.queryIntentActivities(
                    intent,
                    PackageManager.ResolveInfoFlags.of(0L),
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.queryIntentActivities(intent, 0)
            }
            resolved.mapNotNullTo(roles) { it.activityInfo?.packageName }
        }
        runCatching {
            val ime = Settings.Secure.getString(
                context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD,
            )
            ime?.substringBefore('/')?.trim()?.takeIf { it.isNotEmpty() }?.let(roles::add)
        }
        runCatching {
            val telecom = context.getSystemService(android.telecom.TelecomManager::class.java)
            telecom?.defaultDialerPackage?.takeIf { it.isNotEmpty() }?.let(roles::add)
        }
        return roles
    }

    private fun packageSystemFlag(packageName: String, includeUninstalled: Boolean = false): Boolean =
        packageApplication(packageName, includeUninstalled)?.let {
            (it.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
        } ?: throw OpException("package_not_found")

    /**
     * Read-back token of the real enabled state for the current user from
     * PackageManager enabled-setting API for this profile, retaining the
     * distinction between the default and explicit enabled/disabled states.
     */
    private fun enabledSettingToken(packageName: String): String {
        val setting = runCatching {
            context.packageManager.getApplicationEnabledSetting(packageName)
        }.getOrNull() ?: return "unknown"
        return when (setting) {
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> "default"
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> "enabled"
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> "disabled"
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER ->
                "disabled-user"
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED ->
                "disabled-until-used"
            else -> "unknown"
        }
    }

    /**
     * Copy one APK from a user-granted shared-storage path into the
     * service-owned staging area (`/data/local/tmp/floe-staging`). The copy
     * is digest-named, size-bounded, cooperatively cancellable and verified
     * after its atomic commit; it never installs anything. Stale staging
     * files are swept on service start so abandoned copies never accumulate.
     */
    fun stageApk(
        sourcePath: String,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.StagedCopyReceipt {
        if (cancelled()) throw OpException("cancelled")
        val normalized = StagedApkPolicy.normalizeStagedPath(sourcePath)
            ?: throw OpException("apk_path")
        val source = try {
            File(normalized).canonicalFile
        } catch (_: Throwable) {
            throw OpException("apk_path")
        }
        if (!StagedApkPolicy.isStagedPath(source.path)) throw OpException("apk_path")
        if (!source.isFile) throw OpException("apk_missing")
        if (Files.isSymbolicLink(File(normalized).toPath())) throw OpException("apk_path")
        val size = source.length()
        if (size <= 0L || size > StagedApkPolicy.MAX_APK_BYTES) throw OpException("apk_size")

        val dir = ownedStageDir()
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val temp = File(dir, ".incoming-${System.nanoTime()}")
        var committed = false
        try {
            RandomAccessFile(source, "r").use { input ->
                FileOutputStream(temp).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        if (cancelled()) throw OpException("cancelled")
                        val read = input.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                        copied += read
                        if (copied > StagedApkPolicy.MAX_APK_BYTES) throw OpException("apk_size")
                    }
                    output.flush()
                    output.fd.sync()
                }
            }
            if (temp.length() != size) throw OpException("apk_modified")
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            val target = File(dir, "$sha.apk")
            // Always commit freshly verified owned bytes: an existing
            // digest-named file is only kept when its OWN digest genuinely
            // matches the name (never a size-only reuse), otherwise it is
            // replaced by the fresh temp in one atomic rename.
            synchronized(activeStagedPaths) { activeStagedPaths.add(target.path) }
            try {
                if (target.exists() && !verifyOwnedDigest(target, sha)) {
                    if (!target.delete()) throw OpException("staging_unavailable")
                }
                if (!target.exists() && !temp.renameTo(target)) {
                    throw OpException("staging_unavailable")
                }
                committed = true
                val packageName = packageArchive(target)?.packageName
                return com.floe.android.rootsystem.StagedCopyReceipt(
                    stagedPath = target.path,
                    sizeBytes = size,
                    sha256 = sha,
                    packageName = packageName,
                )
            } finally {
                synchronized(activeStagedPaths) { activeStagedPaths.remove(target.path) }
            }
        } finally {
            if (!committed) runCatching { temp.delete() }
        }
    }

    /**
     * True when [file]'s actual SHA-256 equals [sha] (the digest-encoded
     * name). A same-size stale copy can therefore never impersonate the
     * digest-named cache entry.
     */
    private fun verifyOwnedDigest(file: File, sha: String): Boolean {        if (!file.isFile) return false
        val actual = runCatching {
            file.inputStream().use { input ->
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
                digest.digest().joinToString("") { "%02x".format(it) }
            }
        }.getOrNull() ?: return false
        return actual.equals(sha, ignoreCase = true)
    }

    /** True when [path] uses the service staging leaf naming scheme. */
    private fun isServiceLeafPath(path: String): Boolean {
        val parent = StagedApkPolicy.SERVICE_STAGING_PARENT
        if (!path.startsWith("$parent/")) return false
        val leaf = path.removePrefix("$parent/").substringBefore('/')
        return leaf.startsWith("floe-staging-")
    }

    /**
     * Typed authenticated maintenance release for the App's "remove staged
     * APK" action on service-owned (file-root origin) entries. Refuses while
     * an operation actively references the file, only ever touches THIS
     * process's owned namespace, and deletes only when the file's real digest
     * matches its digest name (never a blind unlink oracle). Original source
     * files and other owners' caches are untouched.
     */
    fun releaseOwnedStagedApk(sha256: String, cancelled: () -> Boolean): Boolean {
        if (cancelled()) throw OpException("cancelled")
        if (!sha256.matches(Regex("^[0-9a-f]{64}$"))) return false
        val target = File(ownedStageDir(), "$sha256.apk")
        if (!StagedApkPolicy.isOwnedStagePath(
                target.path, identity.serverUid, identity.packageName)) {
            return false
        }
        synchronized(activeStagedPaths) {
            if (target.path in activeStagedPaths) throw OpException("staged_busy")
        }
        if (!target.exists()) return true
        return verifyOwnedDigest(target, sha256) && runCatching { target.delete() }.getOrDefault(false)
    }

    // ----------------------------------------------------------- settings

    fun readSetting(
        namespace: String,
        key: String,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.SettingReadResult =
        settingsOperations.read(namespace, key, cancelled)

    fun writeSettings(
        changes: List<com.floe.android.rootsystem.SettingsChange>,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.SettingsBatchReceipt =
        settingsOperations.write(changes, cancelled)

    // -------------------------------------------------------------- network

    fun packetCaptureStart(
        requestId: String,
        taskId: String,
        runId: String,
        epoch: Long,
        helperId: String,
        interfaceName: String,
        snaplen: Int,
        maxBytes: Long,
        maxMillis: Long,
    ): PacketCaptureInfo {
        val started = captureSessions.start(
            requestId = requestId,
            helperId = helperId,
            interfaceName = interfaceName,
            snaplen = snaplen,
            maxBytes = maxBytes,
            maxMillis = maxMillis,
            owner = RootCaptureSessions.OwnerIdentity(taskId, runId, epoch),
        )
        return PacketCaptureInfo(started.captureId, started.helperPath)
    }

    fun packetCaptureRead(
        captureId: String,
        taskId: String,
        runId: String,
        epoch: Long,
        maxBytes: Int,
    ): PacketCaptureChunk {
        val chunk = captureSessions.read(
            captureId,
            maxBytes,
            RootCaptureSessions.OwnerIdentity(taskId, runId, epoch),
        )
        return PacketCaptureChunk(chunk.bytes, chunk.done, chunk.bytesRead, chunk.endReason)
    }

    fun packetCaptureStop(
        captureId: String,
        taskId: String,
        runId: String,
        epoch: Long,
    ): PacketCaptureChunk {
        val chunk = captureSessions.stop(
            captureId,
            RootCaptureSessions.OwnerIdentity(taskId, runId, epoch),
        )
        return PacketCaptureChunk(chunk.bytes, chunk.done, chunk.bytesRead, chunk.endReason)
    }

    fun cancelPacketCaptures(requestId: String) {
        captureSessions.cancel(requestId)
    }

    // --------------------------------------------------------------- typed UI

    fun uiSupported(): Boolean = uiOperations.supported()

    fun uiStatus(): com.floe.android.rootsystem.UiBackendStatus = uiOperations.status()

    fun uiObserve(
        claim: com.floe.android.rootsystem.OperationClaim,
        targets: Set<String>,
        request: com.floe.android.rootsystem.UiObserveRequest,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.UiObservation =
        uiOperations.observe(claim, targets, request, cancelled)

    fun uiAct(
        claim: com.floe.android.rootsystem.OperationClaim,
        targets: Set<String>,
        request: com.floe.android.rootsystem.UiActRequest,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.UiActResult =
        uiOperations.act(claim, targets, request, cancelled)

    fun uiScreenshotBegin(
        claim: com.floe.android.rootsystem.OperationClaim,
        targets: Set<String>,
        request: com.floe.android.rootsystem.UiScreenshotRequest,
        cancelled: () -> Boolean,
    ): com.floe.android.rootsystem.UiScreenshotInfo =
        uiOperations.screenshotBegin(claim, targets, request, cancelled)

    fun uiScreenshotRead(
        claim: com.floe.android.rootsystem.OperationClaim,
        screenshotId: String,
        offset: Int,
        maxBytes: Int,
    ): com.floe.android.rootsystem.UiScreenshotChunk =
        uiOperations.screenshotRead(claim, screenshotId, offset, maxBytes)

    fun uiScreenshotClose(
        claim: com.floe.android.rootsystem.OperationClaim,
        screenshotId: String,
    ): Boolean = uiOperations.screenshotClose(claim, screenshotId)

    fun cancelUi(claim: com.floe.android.rootsystem.OperationClaim) {
        uiOperations.cancel(claim)
    }

    fun cancelUi(requestId: String) {
        uiOperations.cancel(requestId)
    }

    fun close() {
        captureSessions.close()
        uiOperations.close()
    }

    fun networkDiagnostics(): NetworkDiagnostics {
        val interfaces = ArrayList<InterfaceInfo>()
        val enumeration = NetworkInterface.getNetworkInterfaces()
        if (enumeration != null) {
            val list = java.util.Collections.list(enumeration).take(32)
            for (networkInterface in list) {
                val addresses = java.util.Collections.list(networkInterface.inetAddresses)
                    .take(8)
                    .mapNotNull { it.hostAddress?.take(128) }
                interfaces.add(
                    InterfaceInfo(
                        name = networkInterface.name.take(BinderProtocol.MAX_NAME),
                        up = runCatching { networkInterface.isUp }.getOrDefault(false),
                        addresses = addresses,
                    ),
                )
            }
        }

        val routes = ArrayList<RouteInfo>()
        val transports = ArrayList<String>()
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val active = connectivity?.activeNetwork
        if (active != null) {
            connectivity.getLinkProperties(active)?.let { properties ->
                val interfaceName = properties.interfaceName?.take(BinderProtocol.MAX_NAME) ?: ""
                properties.routes.take(64).forEach { route ->
                    routes.add(
                        RouteInfo(
                            interfaceName = interfaceName,
                            destination = route.destination?.toString()?.take(BinderProtocol.MAX_TEXT) ?: "",
                            gateway = route.gateway?.hostAddress?.take(BinderProtocol.MAX_TEXT),
                            defaultRoute = route.isDefaultRoute,
                        ),
                    )
                }
            }
            val capabilities = connectivity.getNetworkCapabilities(active)
            if (capabilities != null) {
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) transports.add("wifi")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) transports.add("cellular")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) transports.add("ethernet")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) transports.add("vpn")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) transports.add("bluetooth")
            }
        }
        return NetworkDiagnostics(interfaces, routes, transports)
    }

    // -------------------------------------------------------------- helpers

    private fun scopeDirectory(scope: ScopeRoot): File {
        if (!scope.path.startsWith("/")) throw OpException("scope_relative")
        val root = try {
            File(scope.path).canonicalFile
        } catch (_: Throwable) {
            throw OpException("scope")
        }
        // Re-validate the canonical root on every operation, not only when the
        // grant was registered: a replaced symlink cannot widen the ceiling.
        PathPolicy.validateScopeBase(root.path, ownPackages, scope.writable)?.let {
            throw OpException(it)
        }
        if (!root.isDirectory) throw OpException("scope_missing")
        if (ProtectedTargets.isProtectedPath(root.path, ownPackages)) throw OpException("protected")
        if (scope.writable && ProtectedTargets.isReadOnlySystemPath(root.path)) {
            throw OpException("scope_read_only")
        }
        return root
    }

    private fun resolve(scope: ScopeRoot, relativePath: String, writable: Boolean = false): File {
        val normalized = when (val result = PathPolicy.normalizeRelative(relativePath)) {
            is PathPolicy.RelativeResult.Ok -> result.relative
            is PathPolicy.RelativeResult.Rejected -> throw OpException(result.code)
        }
        val root = scopeDirectory(scope)
        val target = if (normalized.isEmpty()) root else File(root, normalized).canonicalFile
        if (!PathPolicy.isWithin(root.path, target.path)) throw OpException("escape")
        if (ProtectedTargets.isProtectedPath(target.path, ownPackages)) throw OpException("protected")
        if (writable && ProtectedTargets.isReadOnlySystemPath(target.path)) {
            throw OpException("scope_read_only")
        }
        return target
    }

    private fun moveAtomic(source: Path, destination: Path, overwrite: Boolean) {
        try {
            if (overwrite) {
                Files.move(
                    source,
                    destination,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } else {
                Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE)
            }
        } catch (_: AtomicMoveNotSupportedException) {
            throw OpException("atomic_unavailable")
        } catch (_: java.nio.file.FileAlreadyExistsException) {
            throw OpException("exists")
        }
    }

    private fun readProcessTable(): List<ProcessRecord> {
        val process = try {
            ProcessBuilder("/system/bin/ps", "-A", "-o", "PID,UID,NAME")
                .redirectErrorStream(true)
                .start()
        } catch (_: Throwable) {
            return fallbackProcesses()
        }
        val output = drainBounded(process, MAX_PS_BYTES)
        val finished = try {
            process.waitFor(3, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!finished) {
            process.destroy()
            return fallbackProcesses()
        }
        if (process.exitValue() != 0) return fallbackProcesses()

        return ProcessTableQuery.parse(output)
    }

    @Suppress("DEPRECATION")
    private fun fallbackProcesses(): List<ProcessRecord> {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptyList()
        return manager.runningAppProcesses.orEmpty().map {
            ProcessRecord(it.pid, it.uid, it.processName.take(BinderProtocol.MAX_NAME))
        }
    }

    private fun packageUid(packageName: String): Int? = try {
        context.packageManager.getApplicationInfo(packageName, 0).uid
    } catch (_: Throwable) {
        null
    }

    private fun packageInfo(packageName: String): android.content.pm.PackageInfo? = try {
        context.packageManager.getPackageInfo(
            packageName, android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES)
    } catch (_: Throwable) {
        null
    }

    private fun packageApplication(
        packageName: String,
        includeUninstalled: Boolean = false,
    ): android.content.pm.ApplicationInfo? = try {
        context.packageManager.getApplicationInfo(packageName,
            if (includeUninstalled) PackageManager.MATCH_UNINSTALLED_PACKAGES else 0)
    } catch (_: Throwable) {
        null
    }

    /**
     * Run one bounded `pm`/`am` child with CONCURRENT output draining: a
     * reader thread consumes stdout (retaining only a bounded tail) for the
     * whole lifetime of the child, so a silent or chatty child can never
     * stall on a full pipe and bypass the timeout/cancel poll below. When
     * [stdinFile] is given, a writer thread streams exactly those bytes to
     * the child stdin while updating [stdinDigest] and reporting the count
     * to [onStreamedBytes] — verification and streamed input are the same
     * owned bytes.
     *
     * Cancellation: the poll loop destroys the child, both threads see the
     * closed pipes and terminate, and the caller reaps them with a bounded
     * join before any result is returned. Throws [OpException] on start
     * failure ("pm_unavailable"/[unavailableCode]), timeout ("pm_timeout")
     * and cancellation ("cancelled").
     */
    private fun runPackageChild(
        argv: List<String>,
        timeoutMillis: Long,
        cancelled: () -> Boolean,
        unavailableCode: String,
        timeoutCode: String = "pm_timeout",
        stdinFile: File? = null,
        stdinDigest: java.security.MessageDigest? = null,
        onStreamedBytes: (Long) -> Unit = {},
        onOutputTail: ((String) -> Unit)? = null,
        // The appops get tail legitimately carries one short line per catalog
        // operation; callers bound their own larger ceiling, everything else
        // keeps the historical 512-char tail.
        maxOutputChars: Int = MAX_CHILD_OUTPUT_CHARS,
    ): Int {
        val process = try {
            ProcessBuilder(argv).redirectErrorStream(true).start()
        } catch (_: Throwable) {
            throw OpException(unavailableCode)
        }
        val outputLock = Object()
        val outputTail = StringBuilder()
        val reader = Thread {
            try {
                process.inputStream.use { input ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        synchronized(outputLock) {
                            if (outputTail.length < maxOutputChars) {
                                outputTail.append(String(buffer, 0, read, Charsets.UTF_8))
                            }
                        }
                    }
                }
            } catch (_: Throwable) {
                // Child destroyed or pipe closed: draining is best-effort and
                // never the source of truth for the outcome.
            }
        }.apply { isDaemon = true; name = "floe-pm-drain" }
        reader.start()

        var writer: Thread? = null
        if (stdinFile != null) {
            writer = Thread {
                try {
                    process.outputStream.use { output ->
                        RandomAccessFile(stdinFile, "r").use { input ->
                            val buffer = ByteArray(64 * 1024)
                            var sent = 0L
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                stdinDigest?.update(buffer, 0, read)
                                output.write(buffer, 0, read)
                                sent += read
                                onStreamedBytes(sent)
                            }
                        }
                        output.flush()
                    }
                } catch (_: Throwable) {
                    // pm may close stdin early on failure; the exit code and
                    // read-back still decide the outcome honestly.
                }
            }.apply { isDaemon = true; name = "floe-pm-feed" }
            writer.start()
        }

        return try {
            val finished = waitForPackageManager(process, timeoutMillis, cancelled)
            if (!finished) {
                process.destroy()
                throw OpException(timeoutCode)
            }
            if (cancelled()) {
                process.destroy()
                throw OpException("cancelled")
            }
            // Child exit and pipe drain are independent. Capture the reason
            // after the bounded drain, not before the reader's last chunk.
            joinChildThread(reader)
            val tail = synchronized(outputLock) { outputTail.toString() }
            onOutputTail?.invoke(tail)
            process.exitValue()
        } finally {
            // Reap both helpers: stdin/stdout close when the child dies, so
            // the joins terminate; the bound keeps a wedged thread from
            // leaking past the operation.
            joinChildThread(reader)
            writer?.let(::joinChildThread)
            runCatching { process.inputStream.close() }
            runCatching { process.outputStream.close() }
        }
    }

    /**
     * Reduce a bounded `pm` output tail to one concise, non-sensitive failure
     * token: the first Failure/Error-style line wins, otherwise the last
     * non-empty line. No host paths, no free-form dumps, bounded length.
     */
    private fun conciseFailureReason(outputTail: String): String? {
        val lines = outputTail.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            // pm prints this generic header before the actionable exception.
            // Returning the header alone hides the cause from users/models.
            .filterNot { it.startsWith("Exception occurred while executing '") }
            .filterNot { it.startsWith("at ") || it.startsWith("... ") }
            .toList()
        if (lines.isEmpty()) return null
        val reason = lines.firstOrNull {
            it.contains("ailure", ignoreCase = true) ||
                it.contains("rror", ignoreCase = true) ||
                it.contains("denied", ignoreCase = true) ||
                it.contains("refused", ignoreCase = true) ||
                it.contains("xception", ignoreCase = true)
        } ?: lines.last()
        val cleaned = reason.filter { it.code >= 0x20 && it.code != 0x7F }.trim()
        return cleaned.take(96).ifEmpty { null }
    }

    private fun joinChildThread(thread: Thread) {
        try {
            thread.join(CHILD_THREAD_JOIN_MILLIS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    /**
     * Sweep THIS process's owned staging namespace only: expired digest-named
     * copies and abandoned partial (.incoming-*) files bounded by age never
     * accumulate, and the other backend UID's or other host package's cache
     * is never touched.
     */
    private fun sweepStagingDir() {
        val dir = runCatching { ownedStageDir() }.getOrNull() ?: return
        val files = dir.listFiles() ?: return
        val now = System.currentTimeMillis()
        for (file in files) {
            val age = now - file.lastModified()
            val expired = when {
                file.name.endsWith(".apk") && age > STAGING_RETENTION_MILLIS -> true
                file.name.startsWith(".incoming-") && age > PARTIAL_RETENTION_MILLIS -> true
                else -> false
            }
            if (expired) {
                synchronized(activeStagedPaths) {
                    if (file.path !in activeStagedPaths) runCatching { file.delete() }
                }
            }
        }
    }

    private fun currentUserId(): Int = try {
        // android.os.UserHandle.myUserId() without a static import keeps the
        // service class host-test friendly via runCatching fallback.
        val method = android.os.UserHandle::class.java.getMethod("myUserId")
        method.invoke(null) as Int
    } catch (_: Throwable) {
        0
    }

    private fun packageArchive(target: File): android.content.pm.PackageInfo? = try {
        // Mirror of RuntimeSigningIdentity.archiveQueryFlags (core/runtimeipc,
        // mirrored here to avoid a module dependency cycle): Pie/Q archives
        // only collect certificates when GET_SIGNATURES is requested TOO, so
        // SDK 28/29 query with both flags. Only the modern SigningInfo route
        // is trusted for identity — never the legacy oldest signature.
        @Suppress("DEPRECATION")
        val flags = android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES or
            (if (android.os.Build.VERSION.SDK_INT in 28..29)
                android.content.pm.PackageManager.GET_SIGNATURES else 0)
        context.packageManager.getPackageArchiveInfo(target.path, flags)
    } catch (_: Throwable) {
        null
    }

    /**
     * Trust contract mirrored from RuntimeSigningIdentity.read: only the
     * MODERN current signer set (SigningInfo.apkContentsSigners with the
     * multiple/history selection rules) identifies a package; the legacy
     * signature array is queried on 28/29 purely so certificate collection
     * runs at all, never as a trust source. An unreadable identity yields an
     * empty set, which can only fail verification (never silently pass).
     */
    private fun signingDigests(info: android.content.pm.PackageInfo?): Set<String> {
        val signing = runCatching { info?.signingInfo }.getOrNull() ?: return emptySet()
        val multiple = runCatching { signing.hasMultipleSigners() }.getOrNull()
            ?: return emptySet()
        val current = runCatching {
            signing.apkContentsSigners.orEmpty()
                .map { signer -> sha256Hex(signer.toByteArray()) }
                .toSet()
        }.getOrDefault(emptySet())
        val history = if (multiple) emptyList() else runCatching {
            signing.signingCertificateHistory.orEmpty()
                .map { signer -> sha256Hex(signer.toByteArray()) }
        }.getOrDefault(emptyList())
        val sha256 = Regex("^[0-9a-f]{64}$")
        if (current.any { !sha256.matches(it) } || history.any { !sha256.matches(it) }) {
            return emptySet()
        }
        return when {
            multiple -> current.takeIf { it.size >= 2 } ?: emptySet()
            current.size > 1 -> emptySet()
            history.isNotEmpty() -> {
                val last = history.last()
                if (current.isNotEmpty() && current != setOf(last)) emptySet()
                else setOf(last)
            }
            else -> current
        }
    }

    private fun signingDigestsEqual(
        archive: android.content.pm.PackageInfo,
        installed: android.content.pm.PackageInfo?,
    ): Boolean {
        if (installed == null) return false
        val archiveSet = signingDigests(archive)
        val installedSet = signingDigests(installed)
        if (archiveSet.isEmpty() || installedSet.isEmpty()) return false
        return archiveSet == installedSet
    }

    private fun sha256Hex(bytes: ByteArray): String = try {
        java.security.MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
    } catch (_: Throwable) {
        ""
    }

    /**
     * Wait for a `pm` child with cooperative cancellation: polling checks the
     * live registry fence and destroys the child so a cancelled install never
     * keeps mutating the device. Returns false only on timeout.
     */
    private fun waitForPackageManager(
        process: Process,
        timeoutMillis: Long,
        cancelled: () -> Boolean,
    ): Boolean {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        while (System.nanoTime() < deadline) {
            if (cancelled()) {
                process.destroy()
                return true
            }
            if (!process.isAlive) return true
            try {
                Thread.sleep(50)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                process.destroy()
                return true
            }
        }
        return !process.isAlive
    }

    private fun drainBounded(process: Process, limit: Int): String {
        val output = java.io.ByteArrayOutputStream()
        try {
            process.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (output.size() + read > limit) {
                        output.write(buffer, 0, (limit - output.size()).coerceAtLeast(0))
                        break
                    }
                    output.write(buffer, 0, read)
                }
            }
        } catch (_: Throwable) {
        }
        return String(output.toByteArray(), Charsets.UTF_8)
    }

    private companion object {
        const val MAX_FILE_SERVED_BYTES = 16L * 1024 * 1024
        const val MAX_DELETE_ENTRIES = 5000
        const val MAX_PS_BYTES = 256 * 1024
        const val INSTALL_TIMEOUT_MILLIS = 90_000L
        const val UNINSTALL_TIMEOUT_MILLIS = 30_000L
        const val FORCE_STOP_TIMEOUT_MILLIS = 5_000L
        const val SET_ENABLED_TIMEOUT_MILLIS = 30_000L
        const val REMOVE_FOR_USER_TIMEOUT_MILLIS = 60_000L
        const val RESTORE_TIMEOUT_MILLIS = 60_000L
        const val PM_LIST_TIMEOUT_MILLIS = 20_000L
        const val PERMISSION_SET_TIMEOUT_MILLIS = 30_000L
        const val APPOPS_GET_TIMEOUT_MILLIS = 20_000L
        const val APPOPS_SET_TIMEOUT_MILLIS = 30_000L
        const val APPOPS_MAX_OUTPUT_CHARS = 4096
        const val MAX_PERMISSION_QUERY_ROWS = 256
        const val MAX_CHILD_OUTPUT_CHARS = 512
        const val CHILD_THREAD_JOIN_MILLIS = 2_000L
        const val STAGING_RETENTION_MILLIS = 24L * 60 * 60 * 1000
        const val PARTIAL_RETENTION_MILLIS = 60L * 60 * 1000
        val PACKAGE_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
    }
}

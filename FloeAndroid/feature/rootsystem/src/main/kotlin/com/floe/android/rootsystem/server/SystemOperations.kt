// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.floe.android.rootsystem.DeleteReceipt
import com.floe.android.rootsystem.FileEntry
import com.floe.android.rootsystem.FileRead
import com.floe.android.rootsystem.FileWriteReceipt
import com.floe.android.rootsystem.InterfaceInfo
import com.floe.android.rootsystem.MoveReceipt
import com.floe.android.rootsystem.NetworkDiagnostics
import com.floe.android.rootsystem.PackageManagementReceipt
import com.floe.android.rootsystem.PackageQuery
import com.floe.android.rootsystem.PackageRecord
import com.floe.android.rootsystem.ProcessRecord
import com.floe.android.rootsystem.RouteInfo
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.ServiceRecord
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.policy.PathPolicy
import com.floe.android.rootsystem.policy.ProtectedTargets
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
 * bounded; destructive package management is limited to force-stop with
 * post-readback and protected-target refusal.
 */
internal class SystemOperations(
    private val context: Context,
    private val identity: ServerIdentity,
) {
    class OpException(val code: String) : Exception(code)

    // Includes the stable Floe parent, not only the package that launched this
    // service: the runtime component is a sibling applicationId.
    private val ownPackages = identity.protectedPackages

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
        val bound = maxEntries.coerceIn(1, BinderProtocol.MAX_LIST)
        val needle = filter?.take(BinderProtocol.MAX_TEXT)?.lowercase()
        val records = readProcessTable()
        return records.asSequence()
            .filter { needle == null || it.name.lowercase().contains(needle) || it.pid.toString() == needle }
            .take(bound)
            .toList()
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
                return PackageQuery(emptyList(), false)
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
        return PackageQuery(result, truncated)
    }

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
        val process = try {
            ProcessBuilder(
                "/system/bin/am",
                "force-stop",
                "--user",
                userId.toString(),
                packageName,
            ).redirectErrorStream(true).start()
        } catch (_: Throwable) {
            throw OpException("am_unavailable")
        }
        drainBounded(process, 32 * 1024)
        val finished = try {
            process.waitFor(5, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!finished) {
            process.destroy()
            throw OpException("am_timeout")
        }
        if (process.exitValue() != 0) throw OpException("force_stop_failed")

        Thread.sleep(300)
        val stillRunning = runCatching { readProcessTable().any { it.uid == uid } }
            .getOrDefault(true)
        return PackageManagementReceipt(packageName, userId, "force_stop", stillRunning)
    }

    // -------------------------------------------------------------- network

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

        val records = ArrayList<ProcessRecord>()
        for (line in output.lineSequence()) {
            if (line.isBlank() || line.startsWith("PID")) continue
            val match = PS_LINE.matchEntire(line.trim()) ?: continue
            val pid = match.groupValues[1].toIntOrNull() ?: continue
            val uid = match.groupValues[2].toIntOrNull() ?: continue
            val name = match.groupValues[3].trim()
            if (name.isEmpty()) continue
            records.add(ProcessRecord(pid, uid, name.take(BinderProtocol.MAX_NAME)))
            if (records.size >= BinderProtocol.MAX_LIST) break
        }
        return records
    }

    @Suppress("DEPRECATION")
    private fun fallbackProcesses(): List<ProcessRecord> {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptyList()
        return manager.runningAppProcesses.orEmpty().map {
            ProcessRecord(it.pid, it.uid, it.processName.take(BinderProtocol.MAX_NAME))
        }.take(BinderProtocol.MAX_LIST)
    }

    private fun packageUid(packageName: String): Int? = try {
        context.packageManager.getApplicationInfo(packageName, 0).uid
    } catch (_: Throwable) {
        null
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
        val PACKAGE_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
        val PS_LINE = Regex("^(\\d+)\\s+(\\d+)\\s+(.+)$")
    }
}

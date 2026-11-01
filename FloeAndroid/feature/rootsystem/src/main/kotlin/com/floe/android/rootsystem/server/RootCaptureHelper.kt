// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import org.json.JSONObject

/**
 * Production identity for the Full-only root capture helper.
 *
 * Exact bytes are produced by `scripts/root-capture/build-helper.sh`, verified
 * as an AArch64/min28/16 KiB-segment PIE, and staged both as
 * `lib/arm64-v8a/libfloecapture_helper.so` and as the
 * `assets/root-capture/helper.json` digest manifest.
 *
 * Execution never trusts a path under a shell-writable tree:
 *  1. the installed package-manager native library directory is canonicalized,
 *     required to be inside the verified installed APK's code directory, and
 *     its no-symlink ancestry plus exact SHA-256/size/executable byte identity
 *     are checked; if it is executable, that protected path is executed;
 *  2. only when no executable package-manager copy exists are the exact bytes
 *     read from the verified installed APK and installed into a root-owned
 *     0700 directory below `/data/local/floe-capture` whose every ancestor is
 *     validated as root/system-owned and not shell-writable. The staged file is
 *     opened O_CREAT|O_EXCL|O_NOFOLLOW, fsynced, digest-checked, renamed inside
 *     that protected directory and re-verified before exec.
 *
 * There is no `/data/local/tmp` installation, no arbitrary URL, model command,
 * system tcpdump fallback or placeholder digest. A missing/invalid artifact
 * reports `helperUnavailable` and root capture cannot start. A package update
 * that changes the code directory or manifest digest fails closed rather than
 * executing another version's bytes.
 */
object RootCaptureHelper {
    const val ASSET_PATH: String = "root-capture/helper.json"
    const val PACKAGED_NAME: String = "libfloecapture_helper.so"
    const val APK_ENTRY: String = "lib/arm64-v8a/$PACKAGED_NAME"
    const val HELPER_ID: String = "tcpdump-v1"
    const val SCHEMA: String = "floe.root-capture-helper.v1"

    /** Root-owned, non-shell-writable execution/output parent. */
    const val PROTECTED_ROOT: String = "/data/local/floe-capture"
    const val HELPER_ROOT: String = "$PROTECTED_ROOT/helper"
    const val WORK_ROOT: String = "$PROTECTED_ROOT/work"

    /** Ordinary adb/shell identity; never an accepted owner of helper paths. */
    const val SHELL_UID: Int = 2000
    const val SHELL_GID: Int = 2000
    const val SYSTEM_UID: Int = 1000

    private const val ORIGIN_NATIVE_LIBRARY = "nativeLibrary"
    private const val ORIGIN_INSTALLED_COPY = "installedCopy"

    // POSIX mode bits, duplicated here so the pure policy functions do not
    // depend on Android runtime field initialization (and stay deterministic
    // in host-side unit tests). Values match OsConstants on Android.
    private const val MODE_TYPE_MASK = 0xF000
    private const val MODE_DIRECTORY = 0x4000
    private const val MODE_REGULAR = 0x8000
    private const val MODE_SYMLINK = 0xA000
    private const val MODE_EXECUTE_OWNER = 0x40
    private const val MODE_WRITE_GROUP = 0x10
    private const val MODE_WRITE_OTHER = 0x2

    private const val MAX_HELPER_BYTES = 32L * 1024L * 1024L
    private const val MAX_MANIFEST_BYTES = 16 * 1024
    private const val STALE_HELPER_MILLIS = 24L * 60L * 60L * 1000L
    private const val STALE_STAGE_MILLIS = 60L * 60L * 1000L
    private const val STALE_CAPTURE_MILLIS = 24L * 60L * 60L * 1000L
    private const val MAX_WORK_FILES = 16

    data class Manifest(
        val id: String,
        val version: String,
        val abi: String,
        val minSdk: Int,
        val pageSize: Int,
        val packagedName: String,
        val sha256: String,
        val sizeBytes: Long,
    )

    data class Status(
        val available: Boolean,
        val code: String? = null,
        val message: String? = null,
        val sha256: String? = null,
        val path: String? = null,
    )

    data class Resolved(
        val path: File,
        val sha256: String,
        val version: String,
        val origin: String,
    )

    class HelperException(val code: String) : Exception(code)

    /**
     * Full-App preflight. The file is the extracted native library shipped in
     * this signed APK; the expected digest comes from the same APK's asset
     * manifest. A missing generated artifact simply makes root unavailable.
     */
    fun appPreflight(context: Context): Status {
        val manifest = try {
            context.assets.open(ASSET_PATH).use { readManifest(it) }
        } catch (_: Throwable) {
            return Status(false, "helperUnavailable", "The verified root capture helper is not packaged.")
        } ?: return Status(false, "helperManifestInvalid", "The root capture helper manifest is invalid.")
        if (!Build.SUPPORTED_ABIS.contains(manifest.abi)) {
            return Status(false, "helperAbiUnsupported", "This device ABI has no verified root helper.")
        }
        val nativeDirectory = context.applicationInfo.nativeLibraryDir
            ?: return Status(false, "helperUnavailable", "The packaged native library directory is unavailable.")
        val file = File(nativeDirectory, PACKAGED_NAME)
        val verified = verify(
            file,
            manifest,
            expectedRootOwner = false,
            requireExecutable = false,
        )
        if (verified != null) {
            return Status(
                false,
                verified,
                "The packaged root capture helper failed verification.",
            )
        }
        return Status(true, sha256 = manifest.sha256, path = file.absolutePath)
    }

    /**
     * Root-server resolution. The exact installed APK path carried by the
     * verified server arguments must still be PackageManager's sourceDir.
     */
    fun resolveForServer(context: Context): Resolved {
        val installed = installedFloeApk(context)
            ?: throw HelperException("helper_package")
        val zip = try {
            ZipFile(installed.apk)
        } catch (_: Throwable) {
            throw HelperException("helper_package")
        }
        zip.use { archive ->
            val manifestEntry = archive.getEntry("assets/$ASSET_PATH")
                ?: throw HelperException("helper_unavailable")
            val manifest = try {
                archive.getInputStream(manifestEntry).use { readManifest(it) }
            } catch (_: Throwable) {
                throw HelperException("helper_manifest")
            } ?: throw HelperException("helper_manifest")
            if (!Build.SUPPORTED_ABIS.contains(manifest.abi)) {
                throw HelperException("helper_abi")
            }
            when (val native = resolveInstalledNative(context, installed, manifest)) {
                is NativeResolution.Ready -> return native.resolved
                is NativeResolution.Invalid -> throw HelperException(native.code)
                NativeResolution.Missing -> Unit
            }
            // No usable package-manager copy: install the exact APK entry
            // under the protected root tree. The source APK was already bound
            // to PackageManager's verified sourceDir above.
            val entry = archive.getEntry(APK_ENTRY)
                ?: throw HelperException("helper_unavailable")
            return installFromApk(archive, entry, manifest)
        }
    }

    /** Root-owned working directory for the helper's `-w` output. */
    fun prepareWorkDirectory(): File {
        val directory = File(WORK_ROOT)
        ensureProtectedDirectory(directory)
        pruneWorkFiles(directory)
        return directory
    }

    /**
     * Pure manifest validation shared with the deterministic tests.
     * Returns a closed failure code or null.
     */
    fun manifestProblem(
        id: String,
        version: String,
        abi: String,
        minSdk: Int,
        pageSize: Int,
        packagedName: String,
        sha256: String,
        sizeBytes: Long,
    ): String? {
        if (id != HELPER_ID) return "helper_manifest"
        if (version.isBlank() || version.length > 128) return "helper_manifest"
        if (abi != "arm64-v8a") return "helper_manifest"
        if (minSdk < 28 || minSdk > 99) return "helper_manifest"
        if (pageSize < 16_384 || pageSize > 65_536) return "helper_manifest"
        if (packagedName != PACKAGED_NAME) return "helper_manifest"
        if (!sha256.matches(Regex("^[0-9a-f]{64}$"))) return "helper_manifest"
        if (sizeBytes !in 1L..MAX_HELPER_BYTES) return "helper_manifest"
        return null
    }

    fun readManifest(input: InputStream): Manifest? {
        val bytes = try {
            readBounded(input, MAX_MANIFEST_BYTES) ?: return null
        } catch (_: Throwable) {
            return null
        }
        val json = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Throwable) {
            return null
        }
        val id = json.optString("id")
        val version = json.optString("version")
        val abi = json.optString("abi")
        val minSdk = json.optInt("minSdk", -1)
        val pageSize = json.optInt("pageSize", -1)
        val packagedName = json.optString("packagedName")
        val sha = json.optString("sha256").lowercase()
        val size = json.optLong("sizeBytes", -1L)
        if (manifestProblem(id, version, abi, minSdk, pageSize, packagedName, sha, size) != null) {
            return null
        }
        return Manifest(id, version, abi, minSdk, pageSize, packagedName, sha, size)
    }

    /** One filesystem object's no-follow facts for ancestry validation. */
    data class PathFacts(
        val path: String,
        val directory: Boolean,
        val symlink: Boolean,
        val uid: Int,
        val gid: Int,
        val mode: Int,
    ) {
        val otherWritable: Boolean
            get() = (mode and MODE_WRITE_OTHER) != 0
        val groupWritable: Boolean
            get() = (mode and MODE_WRITE_GROUP) != 0

        companion object {
            fun of(path: String, stat: StructStat): PathFacts = PathFacts(
                path = path,
                directory = (stat.st_mode and MODE_TYPE_MASK) == MODE_DIRECTORY,
                symlink = (stat.st_mode and MODE_TYPE_MASK) == MODE_SYMLINK,
                uid = stat.st_uid,
                gid = stat.st_gid,
                mode = stat.st_mode,
            )
        }
    }

    /**
     * Pure ancestry rule. [facts] is ordered from the outermost ancestor to
     * the directory that will hold helper bytes/output.
     *
     * The ordinary shell identity (uid/gid 2000) and any world write must not
     * be able to create, rename or replace an entry. Root/system ownership is
     * required; `/data` and `/data/app` are system-owned 0771 and are accepted
     * because their group is `system` (1000), not `shell`.
     */
    fun ancestryProblem(facts: List<PathFacts>, requireRootOwnedLeaf: Boolean): String? {
        if (facts.isEmpty()) return "helper_install"
        for ((index, factsForPath) in facts.withIndex()) {
            if (factsForPath.symlink) return "helperSymlink"
            if (!factsForPath.directory) return "helperNotDirectory"
            if (factsForPath.otherWritable) return "helperWorldWritable"
            if (factsForPath.groupWritable && factsForPath.gid == SHELL_GID) {
                return "helperShellWritable"
            }
            if (factsForPath.uid != 0 && factsForPath.uid != SYSTEM_UID) {
                return "helperOwner"
            }
            if (index == facts.lastIndex && requireRootOwnedLeaf) {
                if (factsForPath.uid != 0) return "helperOwnerMismatch"
                if (factsForPath.groupWritable || factsForPath.otherWritable) {
                    return "helperWritableByOthers"
                }
            }
        }
        return null
    }

    /**
     * Pure package-update binding: the canonical native library directory must
     * live below the installed APK's own code directory (`<code>/lib/<abi>`),
     * never under a sibling/newer package directory.
     */
    fun nativeDirectoryInsidePackage(
        apkCanonicalPath: String,
        nativeDirectoryCanonicalPath: String,
    ): Boolean {
        if (!apkCanonicalPath.startsWith("/data/") &&
            !apkCanonicalPath.startsWith("/mnt/expand/")
        ) {
            return false
        }
        val codeRoot = File(apkCanonicalPath).parent ?: return false
        val packageManaged = codeRoot.startsWith("/data/app/") ||
            codeRoot.startsWith("/data/user/") ||
            codeRoot.startsWith("/mnt/expand/")
        if (!packageManaged) return false
        val prefix = codeRoot.trimEnd('/') + "/lib/"
        if (!nativeDirectoryCanonicalPath.startsWith(prefix)) return false
        val tail = nativeDirectoryCanonicalPath.removePrefix(prefix).trim('/')
        return tail.isNotEmpty() && !tail.contains('/')
    }

    /**
     * Returns null when the file is the exact verified regular byte identity,
     * otherwise a closed failure code. No boolean shortcut.
     */
    fun verify(
        file: File,
        manifest: Manifest,
        expectedRootOwner: Boolean,
        requireExecutable: Boolean = expectedRootOwner,
        allowedOwners: Set<Int>? = null,
    ): String? {
        val fd = try {
            Os.open(
                file.absolutePath,
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
                0,
            )
        } catch (_: Throwable) {
            return "helperMissing"
        }
        try {
            val stat = try {
                Os.fstat(fd)
            } catch (_: Throwable) {
                return "helperMissing"
            }
            val facts = StatFacts.of(stat)
            if (facts.symlink) return "helperSymlink"
            if (!facts.regular) return "helperNotRegular"
            if (facts.size != manifest.sizeBytes) return "helperSizeMismatch"
            if (expectedRootOwner && facts.uid != 0) return "helperOwnerMismatch"
            if (allowedOwners != null && facts.uid !in allowedOwners) return "helperOwnerMismatch"
            if (requireExecutable && !facts.executable) return "helperNotExecutable"
            if (facts.groupOrOtherWritable) return "helperWritableByOthers"
            val digest = try {
                sha256(fd)
            } catch (_: Throwable) {
                return "helperUnreadable"
            }
            if (digest != manifest.sha256) return "helperDigestMismatch"
            return null
        } finally {
            runCatching { Os.close(fd) }
        }
    }

    /** Pure stat checks kept here so the rule is directly testable. */
    data class StatFacts(
        val regular: Boolean,
        val symlink: Boolean,
        val uid: Int,
        val size: Long,
        val executable: Boolean,
        val groupOrOtherWritable: Boolean,
    ) {
        companion object {
            fun of(stat: StructStat): StatFacts = StatFacts(
                regular = (stat.st_mode and MODE_TYPE_MASK) == MODE_REGULAR,
                symlink = (stat.st_mode and MODE_TYPE_MASK) == MODE_SYMLINK,
                uid = stat.st_uid,
                size = stat.st_size,
                executable = (stat.st_mode and MODE_EXECUTE_OWNER) != 0,
                groupOrOtherWritable =
                    (stat.st_mode and (MODE_WRITE_GROUP or MODE_WRITE_OTHER)) != 0,
            )
        }
    }

    private sealed interface NativeResolution {
        data class Ready(val resolved: Resolved) : NativeResolution
        data object Missing : NativeResolution
        data class Invalid(val code: String) : NativeResolution
    }

    private data class InstalledApk(val packageName: String, val apk: File)

    /**
     * Prefer the package-manager's extracted native library. The code
     * directory binding prevents mixing an old APK manifest with a newer
     * package directory during an update; exact digest/size/executable checks
     * reject any other bytes.
     */
    private fun resolveInstalledNative(
        context: Context,
        installed: InstalledApk,
        manifest: Manifest,
    ): NativeResolution {
        val info = try {
            context.packageManager.getPackageInfo(installed.packageName, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            return NativeResolution.Invalid("helper_package")
        }
        val application = info.applicationInfo ?: return NativeResolution.Invalid("helper_package")
        val source = runCatching { File(application.sourceDir).canonicalPath }.getOrNull()
            ?: return NativeResolution.Invalid("helper_package")
        val installedApk = runCatching { installed.apk.canonicalPath }.getOrNull()
            ?: return NativeResolution.Invalid("helper_package")
        if (source != installedApk) return NativeResolution.Invalid("helper_package")
        val nativeValue = application.nativeLibraryDir ?: return NativeResolution.Missing
        val nativeDirectory = runCatching { File(nativeValue).canonicalFile }.getOrNull()
            ?: return NativeResolution.Invalid("helper_package")
        if (!nativeDirectoryInsidePackage(installedApk, nativeDirectory.path)) {
            return NativeResolution.Invalid("helper_package")
        }
        val directoryFacts = factsAlong(nativeDirectory.path)
            ?: return NativeResolution.Invalid("helper_install")
        val ancestry = ancestryProblem(directoryFacts, requireRootOwnedLeaf = false)
        if (ancestry != null) return NativeResolution.Missing
        val file = File(nativeDirectory, PACKAGED_NAME)
        if (!file.exists()) return NativeResolution.Missing
        val problem = verify(
            file,
            manifest,
            expectedRootOwner = false,
            requireExecutable = true,
            allowedOwners = setOf(0, SYSTEM_UID),
        )
        if (problem == null) {
            return NativeResolution.Ready(
                Resolved(file, manifest.sha256, manifest.version, ORIGIN_NATIVE_LIBRARY),
            )
        }
        return if (problem == "helperMissing" || problem == "helperSymlink" ||
            problem == "helperNotExecutable"
        ) {
            NativeResolution.Missing
        } else {
            NativeResolution.Invalid(problem)
        }
    }

    private fun installFromApk(
        archive: ZipFile,
        entry: ZipEntry,
        manifest: Manifest,
    ): Resolved {
        val root = File(HELPER_ROOT)
        ensureProtectedDirectory(root)
        pruneHelperCache(root, manifest.sha256)
        val directory = File(root, manifest.sha256)
        ensureProtectedDirectory(directory)
        val target = File(directory, "tcpdump")
        if (verify(
                target,
                manifest,
                expectedRootOwner = true,
                requireExecutable = true,
                allowedOwners = setOf(0),
            ) == null
        ) {
            return Resolved(target, manifest.sha256, manifest.version, ORIGIN_INSTALLED_COPY)
        }
        writeVerified(archive.getInputStream(entry), directory, target, manifest)
        val failure = verify(
            target,
            manifest,
            expectedRootOwner = true,
            requireExecutable = true,
            allowedOwners = setOf(0),
        )
        if (failure != null) {
            runCatching { target.delete() }
            throw HelperException("helper_verify")
        }
        return Resolved(target, manifest.sha256, manifest.version, ORIGIN_INSTALLED_COPY)
    }

    /**
     * O_EXCL|O_NOFOLLOW staging inside a validated root-only directory, then an
     * in-directory rename. Only a root process can alter the directory entry,
     * so no ordinary adb/shell user can swap the verified executable between
     * the digest check and exec.
     */
    private fun writeVerified(
        source: InputStream,
        directory: File,
        target: File,
        manifest: Manifest,
    ) {
        val staging = File(directory, ".helper-${UUID.randomUUID()}.tmp")
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            val fd = Os.open(
                staging.absolutePath,
                OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                    OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,
                0x180, // 0600
            )
            FileOutputStream(fd).use { output ->
                source.use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        total += read
                        if (total > manifest.sizeBytes) throw IOException("oversize")
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                }
                output.flush()
                output.fd.sync()
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (total != manifest.sizeBytes || actual != manifest.sha256) {
                throw IOException("digest")
            }
            runCatching { Os.chmod(staging.absolutePath, 0x140) } // 0500
            try {
                Os.rename(staging.absolutePath, target.absolutePath)
            } catch (_: Throwable) {
                throw HelperException("helper_install")
            }
        } catch (failure: Throwable) {
            runCatching { staging.delete() }
            if (failure is HelperException) throw failure
            throw HelperException("helper_install")
        }
    }

    private fun ensureProtectedDirectory(directory: File) {
        val absolute = directory.absolutePath
        if (!absolute.startsWith("$PROTECTED_ROOT/") && absolute != PROTECTED_ROOT) {
            throw HelperException("helper_install")
        }
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw HelperException("helper_install")
        }
        val facts = factsAlong(absolute) ?: throw HelperException("helper_install")
        ancestryProblem(facts, requireRootOwnedLeaf = true)?.let { throw HelperException(it) }
        runCatching { Os.chmod(absolute, 0x1C0) } // 0700
    }

    private fun factsAlong(path: String): List<PathFacts>? {
        val absolute = File(path).absoluteFile.path
        if (!absolute.startsWith("/")) return null
        val parts = absolute.split('/').filter { it.isNotEmpty() }
        val facts = ArrayList<PathFacts>(parts.size + 1)
        var current = "/"
        facts += factsOf(current) ?: return null
        for (part in parts) {
            current = if (current == "/") "/$part" else "$current/$part"
            facts += factsOf(current) ?: return null
        }
        return facts
    }

    private fun factsOf(path: String): PathFacts? {
        val stat = runCatching { Os.lstat(path) }.getOrNull() ?: return null
        return PathFacts.of(path, stat)
    }

    /**
     * The installed APK named by the verified server arguments. PackageManager
     * must still report the same canonical sourceDir, so a server started for
     * one installation cannot read another installation's bytes.
     */
    private fun installedFloeApk(context: Context): InstalledApk? {
        val arguments = try {
            File("/proc/self/cmdline").readBytes().toString(Charsets.UTF_8)
                .split('\u0000')
        } catch (_: Throwable) {
            return null
        }
        var packageName: String? = null
        var apkPath: String? = null
        for (argument in arguments) {
            if (argument.startsWith("--package=")) {
                packageName = argument.substringAfter("--package=").takeIf {
                    it.isNotBlank() && it.length <= 127
                }
            } else if (argument.startsWith("--apk=")) {
                apkPath = argument.substringAfter("--apk=").takeIf {
                    it.startsWith("/") && it.length <= 4096
                }
            }
        }
        val packageValue = packageName ?: return null
        val pathValue = apkPath ?: return null
        val info = try {
            context.packageManager.getPackageInfo(packageValue, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        val source = info.applicationInfo?.sourceDir ?: return null
        // The exact installed bytes are mandatory; a copied/renamed APK is not
        // the signed package this server was started for.
        val sourcePath = runCatching { File(source).canonicalPath }.getOrNull() ?: return null
        val argumentPath = runCatching { File(pathValue).canonicalPath }.getOrNull() ?: return null
        if (sourcePath != argumentPath) return null
        val apk = File(source)
        if (!apk.isFile) return null
        return InstalledApk(packageValue, apk)
    }

    private fun pruneHelperCache(root: File, keep: String) {
        runCatching {
            val now = System.currentTimeMillis()
            for (child in root.listFiles().orEmpty()) {
                if (child.name == keep) continue
                if (!child.name.matches(Regex("^[0-9a-f]{64}$"))) continue
                if (!child.isDirectory) continue
                val stat = runCatching { Os.lstat(child.absolutePath) }.getOrNull() ?: continue
                if ((stat.st_mode and OsConstants.S_IFMT) != OsConstants.S_IFDIR) continue
                val binary = File(child, "tcpdump")
                val age = now - binary.lastModified()
                if (binary.lastModified() > 0 && age < STALE_HELPER_MILLIS) continue
                runCatching { child.deleteRecursively() }
            }
            for (child in root.listFiles().orEmpty()) {
                if (!child.name.startsWith(".helper-") || !child.name.endsWith(".tmp")) continue
                if (now - child.lastModified() >= STALE_STAGE_MILLIS) {
                    runCatching { child.delete() }
                }
            }
        }
    }

    private fun pruneWorkFiles(directory: File) {
        runCatching {
            val now = System.currentTimeMillis()
            val captures = directory.listFiles()
                ?.filter { it.isFile && it.name.matches(Regex("^capture-[0-9a-fA-F-]{36}\\.pcap$")) }
                ?.sortedByDescending { it.lastModified() }
                .orEmpty()
            for ((index, file) in captures.withIndex()) {
                val age = now - file.lastModified()
                // A live capture is bounded to five minutes; files this old
                // can never be a live writer's output. The newest 16 stay
                // retained even past the age bound.
                if (index < MAX_WORK_FILES && age < STALE_CAPTURE_MILLIS) continue
                if (age >= STALE_CAPTURE_MILLIS || index >= MAX_WORK_FILES) {
                    runCatching { file.delete() }
                }
            }
            for (child in directory.listFiles().orEmpty()) {
                if (!child.name.startsWith(".capture-") || !child.name.endsWith(".tmp")) continue
                if (now - child.lastModified() >= STALE_STAGE_MILLIS) {
                    runCatching { child.delete() }
                }
            }
        }
    }

    private fun readBounded(input: InputStream, maxBytes: Int): ByteArray? {
        val buffer = ByteArray(maxBytes.coerceAtLeast(1))
        var total = 0
        while (true) {
            if (total >= buffer.size) {
                // Probe one extra byte: an oversized manifest is invalid.
                return if (input.read() < 0) buffer.copyOf(total) else null
            }
            val read = input.read(buffer, total, buffer.size - total)
            if (read < 0) break
            if (read == 0) continue
            total += read
        }
        return buffer.copyOf(total)
    }

    private fun sha256(fd: java.io.FileDescriptor): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = try {
                Os.read(fd, buffer, 0, buffer.size)
            } catch (_: Throwable) {
                throw IOException("read")
            }
            if (read <= 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import java.io.IOException

enum class FileKind { MISSING, DIRECTORY, REGULAR, SYMLINK, OTHER }

/**
 * Every filesystem side effect the installer performs, behind one seam.
 *
 * Production devices use the bionic implementation (android.system.Os) with
 * full 12-bit modes (setuid/setgid/sticky included). Host JVM checks use the
 * java.nio implementation; extra mode bits are applied through /bin/chmod
 * only for the few members that carry them (host dev/CI path, never the
 * Android path). No caller may pass a model-selected path: roots come from
 * the service, already resolved against its own app-private directory.
 */
interface PosixFileOps {

    fun kind(file: File): FileKind

    /** Create one directory level; fails if it already exists. */
    fun createDirectory(file: File, mode: Int)

    fun chmod(file: File, mode: Int)

    /** Store the target text verbatim; never resolved during extraction. */
    fun symlink(link: File, targetText: String)

    fun hardLink(existing: File, link: File)

    /** Open a brand-new regular file for exclusive write (O_WRONLY|O_CREAT|O_EXCL). */
    fun createNewFile(file: File): java.io.OutputStream

    /** Text file for installer metadata (overwrite allowed: same directory is ours). */
    fun writeText(file: File, text: String)

    fun readText(file: File): String

    /** Best-effort modification time; false when the platform refuses. */
    fun setModificationTime(file: File, epochMs: Long): Boolean

    fun usableSpace(file: File): Long

    /** rename(2): same-file-store only; cross-store must fail, not copy. */
    fun atomicMove(from: File, to: File)

    /**
     * Bottom-up delete that never follows a stored symlink: symlinked
     * directories are unlinked, not walked. Callers must first prove
     * ownership via the installer marker.
     */
    fun deleteTree(owned: File) {
        when (kind(owned)) {
            FileKind.DIRECTORY -> {
                val children = owned.listFiles()
                    ?: throw IOException("cannot list directory ${owned.path}")
                children.forEach { child -> deleteTree(child) }
            }
            FileKind.MISSING -> return
            else -> Unit // unlink the leaf (regular file, dangling or live symlink)
        }
        if (!owned.delete() && kind(owned) != FileKind.MISSING) {
            throw IOException("cannot delete ${owned.path}")
        }
    }

    companion object {
        /** Android devices get the bionic path; host JVM falls back to NIO. */
        fun discover(): PosixFileOps = try {
            Class.forName("android.system.Os")
            // Class reference resolved only after the runtime proves it can
            // link the bionic types; hosts never load AndroidPosixFileOps.
            AndroidPosixFileOps.create()
        } catch (t: Throwable) {
            JvmPosixFileOps()
        }
    }
}

/**
 * bionic-backed implementation used whenever android.system.Os exists.
 * Methods reference Os only inside bodies, so the class is safe to *load* on
 * a host JVM; host tests construct [JvmPosixFileOps] directly and the
 * default() path never invokes the Os methods there.
 */
internal class AndroidPosixFileOps private constructor() : PosixFileOps {

    override fun kind(file: File): FileKind {
        return try {
            val stat = android.system.Os.lstat(file.path)
            val fmt = (stat.st_mode.toLong() and
                android.system.OsConstants.S_IFMT.toLong()).toInt()
            when {
                fmt == android.system.OsConstants.S_IFLNK -> FileKind.SYMLINK
                fmt == android.system.OsConstants.S_IFDIR -> FileKind.DIRECTORY
                fmt == android.system.OsConstants.S_IFREG -> FileKind.REGULAR
                else -> FileKind.OTHER
            }
        } catch (errno: android.system.ErrnoException) {
            if (errno.errno == android.system.OsConstants.ENOENT) FileKind.MISSING
            else if (errno.errno == android.system.OsConstants.ENOTDIR) FileKind.MISSING
            else throw IOException("lstat failed: ${file.path}", errno)
        }
    }

    override fun createDirectory(file: File, mode: Int) {
        android.system.Os.mkdir(file.path, mode and 0x1FF)
        android.system.Os.chmod(file.path, mode and 0xFFF) // 12 octal mode bits
    }

    override fun chmod(file: File, mode: Int) {
        android.system.Os.chmod(file.path, mode and 0xFFF) // 12 octal mode bits
    }

    override fun symlink(link: File, targetText: String) {
        android.system.Os.symlink(targetText, link.path)
    }

    override fun hardLink(existing: File, link: File) {
        android.system.Os.link(existing.path, link.path)
    }

    override fun createNewFile(file: File): java.io.OutputStream {
        val fd = android.system.Os.open(
            file.path,
            android.system.OsConstants.O_WRONLY or
                android.system.OsConstants.O_CREAT or android.system.OsConstants.O_EXCL,
            0x180, // 0600; the real mode is applied right after the payload
        )
        return AndroidFdOutputStream(fd)
    }

    override fun writeText(file: File, text: String) {
        file.parentFile?.let { parent ->
            if (kind(parent) != FileKind.DIRECTORY) ensureDirectoryTree(parent)
        }
        val fd = android.system.Os.open(
            file.path,
            android.system.OsConstants.O_WRONLY or
                android.system.OsConstants.O_CREAT or android.system.OsConstants.O_TRUNC,
            0x180,
        )
        AndroidFdOutputStream(fd).use { it.write(text.toByteArray(Charsets.UTF_8)) }
    }

    override fun readText(file: File): String {
        val fd = android.system.Os.open(file.path, android.system.OsConstants.O_RDONLY, 0)
        try {
            val bytes = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val n = android.system.Os.read(fd, buffer, 0, buffer.size)
                if (n <= 0) break
                bytes.write(buffer, 0, n)
            }
            return String(bytes.toByteArray(), Charsets.UTF_8)
        } finally {
            android.system.Os.close(fd)
        }
    }

    override fun setModificationTime(file: File, epochMs: Long): Boolean = try {
        // android.system.Os exposes no utime family on this SDK; File's
        // bionic-backed setLastModified covers the guest mtime semantics.
        file.setLastModified(epochMs)
    } catch (_: Exception) {
        false
    }

    override fun usableSpace(file: File): Long = file.usableSpace

    override fun atomicMove(from: File, to: File) {
        android.system.Os.rename(from.path, to.path)
    }

    companion object {
        fun create(): PosixFileOps = AndroidPosixFileOps()
    }
}

/** Buffered writer over an Os FileDescriptor (bionic has no FileOutputStream(fd)). */
private class AndroidFdOutputStream(private val fd: java.io.FileDescriptor) : java.io.OutputStream() {
    private var pending: ByteArray? = null
    private var filled = 0

    override fun write(byte: Int) {
        val buffer = pending ?: ByteArray(16 * 1024).also { pending = it }
        buffer[filled++] = byte.toByte()
        if (filled == buffer.size) flushBuffer(buffer)
    }

    override fun write(data: ByteArray, offset: Int, length: Int) {
        var done = 0
        while (done < length) {
            val buffer = pending ?: ByteArray(16 * 1024).also { pending = it }
            val take = minOf(buffer.size - filled, length - done)
            data.copyInto(buffer, filled, offset + done, offset + done + take)
            filled += take
            done += take
            if (filled == buffer.size) flushBuffer(buffer)
        }
    }

    private fun flushBuffer(buffer: ByteArray) {
        var offset = 0
        while (offset < filled) {
            offset += android.system.Os.write(fd, buffer, offset, filled - offset)
        }
        filled = 0
    }

    override fun flush() {
        pending?.let { if (filled > 0) flushBuffer(it) }
    }

    private var closed = false

    override fun close() {
        if (closed) return
        closed = true
        try {
            flush()
        } finally {
            android.system.Os.close(fd)
        }
    }
}

/**
 * java.nio implementation for host JVM builds and focused component checks.
 * rwx bits go through PosixFilePermissions; the rare members carrying
 * setuid/setgid/sticky use /bin/chmod so host tests exercise the same
 * 12-bit semantics the device gets from Os.chmod. Not used on Android.
 */
internal class JvmPosixFileOps : PosixFileOps {

    override fun kind(file: File): FileKind {
        val path = file.toPath()
        // lstat semantics first: a dangling symlink is still a SYMLINK here.
        if (java.nio.file.Files.isSymbolicLink(path)) return FileKind.SYMLINK
        if (!java.nio.file.Files.exists(path)) return FileKind.MISSING
        return when {
            file.isDirectory -> FileKind.DIRECTORY
            file.isFile -> FileKind.REGULAR
            else -> FileKind.OTHER
        }
    }

    override fun createDirectory(file: File, mode: Int) {
        java.nio.file.Files.createDirectory(file.toPath())
        chmod(file, mode)
    }

    override fun chmod(file: File, mode: Int) {
        val bits = mode and 0xFFF // 12 octal mode bits (0o7777)
        val view = java.nio.file.Files.getFileAttributeView(
            file.toPath(), java.nio.file.attribute.PosixFileAttributeView::class.java,
            java.nio.file.LinkOption.NOFOLLOW_LINKS,
        ) ?: throw IOException("no POSIX attributes for ${file.path}")
        val permissions = java.nio.file.attribute.PosixFilePermissions.fromString(
            (if (bits and 0x100 != 0) "r" else "-") + (if (bits and 0x080 != 0) "w" else "-") +
            (if (bits and 0x040 != 0) "x" else "-") + (if (bits and 0x020 != 0) "r" else "-") +
            (if (bits and 0x010 != 0) "w" else "-") + (if (bits and 0x008 != 0) "x" else "-") +
            (if (bits and 0x004 != 0) "r" else "-") + (if (bits and 0x002 != 0) "w" else "-") +
            (if (bits and 0x001 != 0) "x" else "-"),
        )
        view.setPermissions(permissions)
        if (bits and 0xE00 != 0) { // setuid/setgid/sticky = octal 0o7000
            // NIO cannot express setuid/setgid/sticky; use the host chmod tool.
            val process = ProcessBuilder("/bin/chmod", Integer.toOctalString(bits), file.path)
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
            if (process.waitFor() != 0) {
                throw IOException(
                    "chmod 0" + Integer.toOctalString(bits) +
                        " failed for ${file.path}: $output",
                )
            }
        }
    }

    override fun symlink(link: File, targetText: String) {
        java.nio.file.Files.createSymbolicLink(
            link.toPath(), java.nio.file.Paths.get(targetText),
        )
    }

    override fun hardLink(existing: File, link: File) {
        java.nio.file.Files.createLink(link.toPath(), existing.toPath())
    }

    override fun createNewFile(file: File): java.io.OutputStream =
        java.nio.file.Files.newOutputStream(
            file.toPath(),
            java.nio.file.StandardOpenOption.WRITE,
            java.nio.file.StandardOpenOption.CREATE_NEW,
        )

    override fun writeText(file: File, text: String) {
        file.parentFile?.let { parent ->
            if (kind(parent) != FileKind.DIRECTORY) ensureDirectoryTree(parent)
        }
        file.writeText(text, Charsets.UTF_8)
    }

    override fun readText(file: File): String = file.readText(Charsets.UTF_8)

    override fun setModificationTime(file: File, epochMs: Long): Boolean = try {
        java.nio.file.Files.setLastModifiedTime(
            file.toPath(), java.nio.file.attribute.FileTime.fromMillis(epochMs),
        )
        true
    } catch (_: Exception) {
        false
    }

    override fun usableSpace(file: File): Long = file.usableSpace

    override fun atomicMove(from: File, to: File) {
        java.nio.file.Files.move(
            from.toPath(), to.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE,
        )
    }
}

/**
 * Idempotent chain creation for installer-owned parents only (workspace
 * subdirectories). Guest directories are materialized by the extractor with
 * their archive modes; this helper is used for metadata paths such as
 * downloads/ and marker writes, where 0755 default is sufficient.
 */
internal fun PosixFileOps.ensureDirectoryTree(dir: File) {
    val missing = ArrayDeque<File>()
    var cursor = dir
    while (kind(cursor) == FileKind.MISSING) {
        missing.addFirst(cursor)
        cursor = cursor.parentFile ?: break
    }
    if (kind(cursor) != FileKind.DIRECTORY) {
        throw RootfsInstallException(
            InstallFailure.DESTINATION_PARENT_MISSING, "cannot create ${dir.path}",
        )
    }
    for (level in missing) {
        if (kind(level) != FileKind.DIRECTORY) createDirectory(level, 0x1FF)
    }
}

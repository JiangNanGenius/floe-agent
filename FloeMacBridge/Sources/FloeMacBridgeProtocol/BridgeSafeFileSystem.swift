import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin

/// Descriptor-relative commit: a directory swapped for a symbolic link while
/// network IO is suspended can never redirect the final write outside root.
public enum BridgeSafeFileSystem {
    public static func commit(staged source: URL, relativePath: String, under root: URL, expectedSHA256: String?) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BridgeFailure.unsafePath }
        var parent = try openRoot(root)
        guard parent >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(parent) }
        for component in parts.dropLast() {
            if Darwin.mkdirat(parent, component, 0o700) != 0, errno != EEXIST { throw BridgeFailure.unsafePath }
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BridgeFailure.unsafePath }
            Darwin.close(parent); parent = next
        }
        guard let name = parts.last else { throw BridgeFailure.unsafePath }
        let mode = try checkExisting(name, parent: parent, expected: expectedSHA256)
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(input) }
        var inputStat = stat()
        guard Darwin.fstat(input, &inputStat) == 0, inputStat.st_mode & S_IFMT == S_IFREG else { throw BridgeFailure.unsafePath }
        let temporary = ".floe-commit-" + UUID().uuidString
        let output = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else { throw BridgeFailure.unsafePath }
        defer { Darwin.close(output); Darwin.unlinkat(parent, temporary, 0) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw BridgeFailure.remote("Cannot read the transferred file.") }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { throw BridgeFailure.unsafePath }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, address.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw BridgeFailure.remote("Cannot save the transferred file.") }
                    offset += written
                }
            }
        }
        guard Darwin.fsync(output) == 0 else { throw BridgeFailure.remote("Cannot save the transferred file.") }
        _ = try checkExisting(name, parent: parent, expected: expectedSHA256)
        guard Darwin.renameat(parent, temporary, parent, name) == 0 else { throw BridgeFailure.remote("Cannot commit the transferred file.") }
        _ = Darwin.fsync(parent)
    }
    public static func moveToRecovery(relativePath: String, under root: URL, expectedSHA256: String,
                                      recoveryRoot: URL) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BridgeFailure.unsafePath }
        var parent = try openRoot(root)
        defer { Darwin.close(parent) }
        for component in parts.dropLast() {
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BridgeFailure.unsafePath }
            Darwin.close(parent); parent = next
        }
        guard let name = parts.last else { throw BridgeFailure.unsafePath }
        _ = try checkExisting(name, parent: parent, expected: expectedSHA256)
        let recovery = try openRoot(recoveryRoot)
        defer { Darwin.close(recovery) }
        guard Darwin.renameat(parent, name, recovery, name) == 0 else { throw BridgeFailure.remote("Cannot retain the removed file for recovery.") }
    }
    private static func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw BridgeFailure.unsafePath }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeFailure.unsafePath }
        do {
            for component in root.standardizedFileURL.path.split(separator: "/") {
                let next = Darwin.openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw BridgeFailure.unsafePath }
                Darwin.close(descriptor); descriptor = next
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    private static func checkExisting(_ name: String, parent: Int32, expected: String?) throws -> mode_t {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT, expected == nil else { throw BridgeFailure.remote("The destination changed. Both copies were retained.") }
            return 0o600
        }
        defer { Darwin.close(descriptor) }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0, details.st_mode & S_IFMT == S_IFREG else { throw BridgeFailure.unsafePath }
        guard let expected else { throw BridgeFailure.remote("The destination changed. Both copies were retained.") }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var digest = SHA256()
        while let chunk = try reader.read(upToCount: 256 * 1_024), !chunk.isEmpty { digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw BridgeFailure.remote("The destination changed. Both copies were retained.")
        }
        return details.st_mode & 0o777
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@discardableResult
private func furnitureAssetSystemClose(_ descriptor: Int32) -> Int32 {
#if canImport(Darwin)
    return Darwin.close(descriptor)
#elseif canImport(Glibc)
    return Glibc.close(descriptor)
#else
    return -1
#endif
}

private func furnitureAssetSystemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    return Darwin.read(descriptor, buffer, count)
#elseif canImport(Glibc)
    return Glibc.read(descriptor, buffer, count)
#else
    return -1
#endif
}

enum FurnitureAssetPathError: Error, Equatable {
    case empty
    case absolute
    case traversal
    case invalidComponent
    case invalidCharacter
    case tooLong
    case unsupportedPrefix
}

/// Path rules shared by the OBJ/MTL parser and the library layout. Every
/// stored path is canonical. Source references may traverse from a model or
/// material subdirectory to another directory inside the selected root;
/// traversal above that root, absolute paths and drive prefixes are refused.
enum FurnitureAssetPathName {
    static func normalise(_ raw: String, maxBytes: Int) throws -> String {
        guard !raw.isEmpty else { throw FurnitureAssetPathError.empty }
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FurnitureAssetPathError.invalidCharacter
        }
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw FurnitureAssetPathError.invalidCharacter
        }

        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { throw FurnitureAssetPathError.absolute }
        guard !path.hasPrefix("//") else { throw FurnitureAssetPathError.absolute }
        guard !path.contains(":") else { throw FurnitureAssetPathError.unsupportedPrefix }
        guard path.utf8.count <= maxBytes else { throw FurnitureAssetPathError.tooLong }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw FurnitureAssetPathError.empty }
        for component in components {
            guard !component.isEmpty else { throw FurnitureAssetPathError.invalidComponent }
            guard component != ".", component != ".." else { throw FurnitureAssetPathError.traversal }
            guard component.utf8.count <= 255 else { throw FurnitureAssetPathError.tooLong }
        }
        return components.joined(separator: "/")
    }

    static func components(_ raw: String, maxBytes: Int) throws -> [String] {
        let normalised = try normalise(raw, maxBytes: maxBytes)
        return normalised.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    static func resolve(_ reference: String, relativeTo directory: String, maxBytes: Int) throws -> String {
        guard !reference.isEmpty else {throw FurnitureAssetPathError.empty}
        guard reference==reference.trimmingCharacters(in:.whitespacesAndNewlines),
              !reference.unicodeScalars.contains(where:{$0.value<0x20 || $0.value==0x7F}) else {
            throw FurnitureAssetPathError.invalidCharacter
        }
        let path=reference.replacingOccurrences(of:"\\",with:"/")
        guard !path.hasPrefix("/"),!path.hasPrefix("~") else{throw FurnitureAssetPathError.absolute}
        guard !path.contains(":") else{throw FurnitureAssetPathError.unsupportedPrefix}
        guard path.utf8.count<=maxBytes else{throw FurnitureAssetPathError.tooLong}
        var result:[String]=[]
        if !directory.isEmpty {result=try components(directory,maxBytes:maxBytes)}
        for component in path.split(separator:"/",omittingEmptySubsequences:false) {
            guard !component.isEmpty else{throw FurnitureAssetPathError.invalidComponent}
            if component=="." {continue}
            if component==".." {
                guard !result.isEmpty else{throw FurnitureAssetPathError.traversal}
                result.removeLast()
            } else {
                guard component.utf8.count<=255 else{throw FurnitureAssetPathError.tooLong}
                result.append(String(component))
            }
        }
        return try normalise(result.joined(separator:"/"),maxBytes:maxBytes)
    }

    static func basename(_ path: String, maxBytes: Int) throws -> String {
        let components = try components(path, maxBytes: maxBytes)
        guard let last = components.last, !last.isEmpty else { throw FurnitureAssetPathError.empty }
        return last
    }

    static func parentDirectory(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }

    static func storedResourcePath(sourceRelativePath: String, maxBytes: Int) throws -> String {
        let source = try normalise(sourceRelativePath, maxBytes: maxBytes)
        return "files/" + source
    }

    static func storedMetadataPath(kind: String, basename: String, maxBytes: Int) throws -> String {
        let name = try normalise(basename, maxBytes: maxBytes)
        guard !name.contains("/") else { throw FurnitureAssetPathError.invalidComponent }
        return "metadata/" + kind + "/" + name
    }

    static func sourcePath(fromStored relativePath: String, prefix: String, maxBytes: Int) throws -> String {
        let stored = try normalise(relativePath, maxBytes: maxBytes)
        guard stored.hasPrefix(prefix + "/") else { throw FurnitureAssetPathError.invalidComponent }
        let source = String(stored.dropFirst(prefix.count + 1))
        return try normalise(source, maxBytes: maxBytes)
    }

    /// A bounded, non-secret representation for a refused reference. Absolute
    /// author-machine prefixes are reduced to the final component so a manifest
    /// does not retain a private host path.
    static func redactedReference(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.map { character -> Character in
            if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                return " "
            }
            return character
        }
        var value = String(cleaned)
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("\\\\") || (value.count > 1 && value[value.index(value.startIndex, offsetBy: 1)] == ":") {
            let last = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "reference"
            value = ".../" + last
        }
        if value.utf8.count > 256 {
            value = String(value.prefix(256))
        }
        return value.isEmpty ? "reference" : value
    }
}

enum FurnitureAssetProbe: Equatable {
    case regularFile(byteCount: Int)
    case missing
    case unsafe
    case notRegular
    case unreadable
}

enum FurnitureAssetSourceAccessError: Error, Equatable {
    case missing
    case unsafe
    case notRegular
    case unreadable
    case tooLarge(Int)
    case io(String)
}

/// Descriptor-relative source reads. Every path component is opened with
/// `O_NOFOLLOW`; a symlink, absolute path or `..` component cannot escape the
/// selected root even if it changes after an outer check.
final class FurnitureAssetSourceAccess {
    private var rootDescriptor: Int32?

    init(rootURL: URL) throws {
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = resolved.path.withCString {
            open($0, Int32(O_RDONLY) | Int32(O_DIRECTORY) | Int32(O_CLOEXEC))
        }
        guard descriptor >= 0 else {
            throw FurnitureAssetSourceAccessError.io("the source root could not be opened")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            furnitureAssetSystemClose(descriptor)
            throw FurnitureAssetSourceAccessError.io("the source root could not be inspected")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            furnitureAssetSystemClose(descriptor)
            throw FurnitureAssetSourceAccessError.notRegular
        }
        rootDescriptor = descriptor
    }

    deinit {
        close()
    }

    func close() {
        guard let descriptor = rootDescriptor else { return }
        rootDescriptor = nil
        furnitureAssetSystemClose(descriptor)
    }

    func probe(_ relativePath: String, maxPathBytes: Int) -> FurnitureAssetProbe {
        do {
            let descriptor = try openRegularFile(relativePath, maxPathBytes: maxPathBytes)
            defer { furnitureAssetSystemClose(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return .unreadable }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return .notRegular }
            guard info.st_size >= 0, info.st_size <= Int64(Int.max) else { return .notRegular }
            return .regularFile(byteCount: Int(info.st_size))
        } catch let error as FurnitureAssetSourceAccessError {
            switch error {
            case .missing: return .missing
            case .unsafe: return .unsafe
            case .notRegular: return .notRegular
            case .unreadable: return .unreadable
            case .tooLarge: return .notRegular
            case .io: return .unreadable
            }
        } catch {
            return .unreadable
        }
    }

    func readFile(_ relativePath: String, limit: Int, maxPathBytes: Int) throws -> Data {
        guard limit > 0 else { throw FurnitureAssetSourceAccessError.tooLarge(limit) }
        let descriptor = try openRegularFile(relativePath, maxPathBytes: maxPathBytes)
        defer { furnitureAssetSystemClose(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw FurnitureAssetSourceAccessError.unreadable
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FurnitureAssetSourceAccessError.notRegular
        }
        guard info.st_size >= 0, info.st_size <= Int64(limit) else {
            throw FurnitureAssetSourceAccessError.tooLarge(limit)
        }

        var data = Data()
        data.reserveCapacity(min(Int(info.st_size), 1_048_576))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return furnitureAssetSystemRead(descriptor, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FurnitureAssetSourceAccessError.io("a source file could not be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= limit else {
                throw FurnitureAssetSourceAccessError.tooLarge(limit)
            }
        }
        return data
    }

    private func openRegularFile(_ relativePath: String, maxPathBytes: Int) throws -> Int32 {
        guard let root = rootDescriptor else { throw FurnitureAssetSourceAccessError.io("the source root is closed") }
        let components = try FurnitureAssetPathName.components(relativePath, maxBytes: maxPathBytes)
        guard !components.isEmpty else { throw FurnitureAssetSourceAccessError.missing }

        var current = dup(root)
        guard current >= 0 else { throw FurnitureAssetSourceAccessError.io("the source root is closed") }
        for (offset, component) in components.enumerated() {
            let isFinal = offset == components.count - 1
            let flags = isFinal
                ? (Int32(O_RDONLY) | Int32(O_NOFOLLOW) | Int32(O_CLOEXEC) | Int32(O_NONBLOCK))
                : (Int32(O_RDONLY) | Int32(O_DIRECTORY) | Int32(O_NOFOLLOW) | Int32(O_CLOEXEC))
            let next = component.withCString { openat(current, $0, flags) }
            let code = errno
            furnitureAssetSystemClose(current)
            guard next >= 0 else {
                switch code {
                case ENOENT:
                    throw FurnitureAssetSourceAccessError.missing
                case ELOOP, ENOTDIR:
                    throw FurnitureAssetSourceAccessError.unsafe
                case EACCES, EPERM:
                    throw FurnitureAssetSourceAccessError.unreadable
                default:
                    throw FurnitureAssetSourceAccessError.io("a source path component could not be opened")
                }
            }
            current = next
        }
        return current
    }
}

enum FurnitureAssetHashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

enum FurnitureAssetFileSystem {
    static func isSymbolicLink(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func isDirectoryNotSymlink(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    static func ensureDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard isDirectoryNotSymlink(url, fileManager: fileManager) else {
                throw FurnitureAssetLibraryError.io("a library directory is not a real directory")
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == url.standardizedFileURL.path else {
                throw FurnitureAssetLibraryError.io("a library directory is a symbolic link")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            // Another store may have created the same directory between the
            // check and this call. Re-check the actual resulting directory.
            guard fileManager.fileExists(atPath: url.path),
                  isDirectoryNotSymlink(url, fileManager: fileManager),
                  url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
                throw FurnitureAssetLibraryError.io("a library directory could not be created")
            }
            return
        }
        guard isDirectoryNotSymlink(url, fileManager: fileManager) else {
            throw FurnitureAssetLibraryError.io("a library directory was created as a non-directory")
        }
    }

    static func ensureDirectoryTree(_ url: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard isDirectoryNotSymlink(url, fileManager: fileManager) else {
                throw FurnitureAssetLibraryError.io("a library path is not a real directory")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            guard fileManager.fileExists(atPath: url.path),
                  isDirectoryNotSymlink(url, fileManager: fileManager) else {
                throw FurnitureAssetLibraryError.io("a library directory tree could not be created")
            }
            return
        }
    }

    static func ensureParentDirectory(for fileURL: URL, inside root: URL, fileManager: FileManager = .default) throws {
        let rootStandard = root.standardizedFileURL
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        guard parent == rootStandard || contains(parent, in: rootStandard),
              parent.pathComponents.count >= rootStandard.pathComponents.count else {
            throw FurnitureAssetLibraryError.io("a stored file parent escapes its version root")
        }
        var current = rootStandard
        let relative = parent.pathComponents.dropFirst(rootStandard.pathComponents.count)
        for component in relative {
            current.appendPathComponent(component, isDirectory: true)
            if fileManager.fileExists(atPath: current.path) {
                guard isDirectoryNotSymlink(current, fileManager: fileManager) else {
                    throw FurnitureAssetLibraryError.io("a stored file parent is a symbolic link or non-directory")
                }
            } else {
                do {
                    try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                } catch {
                    throw FurnitureAssetLibraryError.io("a stored file parent could not be created")
                }
            }
        }
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count else { return false }
        return Array(components.prefix(rootComponents.count)) == rootComponents
    }

    static func removeIfPresent(_ url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    static func fileExists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

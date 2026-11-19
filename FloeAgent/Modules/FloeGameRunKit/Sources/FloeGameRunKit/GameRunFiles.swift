// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct GameRunSourceFile: Sendable, Equatable {
    let path: GameRelativePath
    let bytes: Int
    let executable: Bool
}

/// Bounded, symlink-refusing listing of the selected root. This is a scan of
/// the host-materialized revision, not a repository API and not an access grant.
struct GameRunSourceIndex: Sendable {
    let rootURL: URL
    let relativeRoot: String
    let files: [GameRunSourceFile]
    let directories: [GameRelativePath]
    private let fileSet: Set<String>

    init(rootURL: URL, relativeRoot: String, files: [GameRunSourceFile],
         directories: [GameRelativePath]) {
        self.rootURL = rootURL
        self.relativeRoot = relativeRoot
        self.files = files.sorted { $0.path.value < $1.path.value }
        self.directories = directories.sorted { $0.value < $1.value }
        self.fileSet = Set(files.map(\.path.value))
    }

    var paths: [GameRelativePath] { files.map(\.path) }
    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    func contains(_ path: String) -> Bool { fileSet.contains(path) }

    func anyFile(suffix: String) -> Bool {
        files.contains { $0.path.value.lowercased().hasSuffix(suffix.lowercased()) }
    }

    func anyFile(prefix: String) -> Bool {
        files.contains { $0.path.value.lowercased().hasPrefix(prefix.lowercased()) }
    }

    func hasPrefix(_ prefix: String) -> Bool {
        files.contains { $0.path.value.hasPrefix(prefix) }
    }

    func anyFile(name: String) -> Bool {
        let target = name.lowercased()
        return files.contains { ($0.path.value as NSString).lastPathComponent.lowercased() == target }
    }

    func rootNames() -> Set<String> {
        Set(files.filter { !$0.path.value.contains("/") }
            .map { ($0.path.value as NSString).lastPathComponent.lowercased() })
    }

    func byPath(_ value: String) -> GameRunSourceFile? {
        files.first { $0.path.value == value }
    }

    func wasmFile() -> GameRunSourceFile? {
        files.first { gameRunIsWASMPath($0.path.value) }
    }
}

enum GameRunTreeScanner {
    static func scan(rootURL: URL, relativeRoot: String,
                     limits: GameRunPreparationLimits) throws -> GameRunSourceIndex {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw GameRunPreparationError.invalidProject("selected root is unavailable")
        }
        defer { close(descriptor) }
        var files: [GameRunSourceFile] = []
        var directories: [GameRelativePath] = []

        func walk(_ parent: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth <= limits.maximumDepth else {
                throw GameRunPreparationError.invalidProject("selected root is too deep")
            }
            let child = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                throw GameRunPreparationError.invalidProject("selected root is unreadable")
            }
            guard let stream = fdopendir(child) else {
                close(child)
                throw GameRunPreparationError.invalidProject("selected root is unreadable")
            }
            defer { closedir(stream) }
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else {
                        throw GameRunPreparationError.invalidProject("selected root is unreadable")
                    }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                if GameProjectReader.versionControlNames.contains(name.lowercased()) { continue }
                guard files.count + directories.count < limits.maximumEntries else {
                    throw GameRunPreparationError.invalidProject("selected root has too many entries")
                }
                let path: GameRelativePath
                do { path = try GameRelativePath(prefix + name) }
                catch {
                    throw GameRunPreparationError.invalidProject("unsupported file name")
                }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw GameRunPreparationError.invalidProject("selected root entry is unreadable")
                }
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFDIR else {
                    throw GameRunPreparationError.invalidProject("unsafe entry \(path.value)")
                }
                if type == S_IFDIR {
                    directories.append(path)
                    let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else {
                        throw GameRunPreparationError.invalidProject("unsafe directory \(path.value)")
                    }
                    do {
                        try walk(next, prefix + name + "/", depth + 1)
                    } catch {
                        close(next)
                        throw error
                    }
                    close(next)
                } else {
                    let size = info.st_size
                    guard size >= 0, size <= off_t(limits.maximumFileBytes) else {
                        throw GameRunPreparationError.invalidProject("file is too large: \(path.value)")
                    }
                    files.append(.init(path: path, bytes: Int(size),
                        executable: info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0))
                }
            }
        }

        try walk(descriptor, "", 0)
        return .init(rootURL: root, relativeRoot: relativeRoot,
                     files: files, directories: directories)
    }
}

enum GameRunFileIO {
    static func read(root: URL, path: GameRelativePath, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw GameRunPreparationError.invalidProject("read bound")
        }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw GameRunPreparationError.invalidProject("root is unavailable")
        }
        defer { close(rootFD) }
        let components = path.value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else {
            throw GameRunPreparationError.invalidProject("empty path")
        }
        var current = rootFD
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY)
            let next = openat(current, component, flags)
            if current != rootFD { close(current) }
            guard next >= 0 else {
                throw GameRunPreparationError.invalidProject("unreadable file \(path.value)")
            }
            current = next
        }
        defer { close(current) }
        var info = stat()
        guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= off_t(maximumBytes) else {
            throw GameRunPreparationError.invalidProject("unsafe or oversized file \(path.value)")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(32_768, maximumBytes + 1))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(current, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw GameRunPreparationError.invalidProject("read failed \(path.value)")
            }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else {
                throw GameRunPreparationError.invalidProject("file is too large \(path.value)")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Reads only the first `maximumBytes` of a regular file. The file itself
    /// may be larger; this is used for bounded format checks (WASM magic).
    static func readPrefix(root: URL, path: GameRelativePath, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw GameRunPreparationError.invalidProject("read bound")
        }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw GameRunPreparationError.invalidProject("root is unavailable")
        }
        defer { close(rootFD) }
        let components = path.value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var current = rootFD
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY)
            let next = openat(current, component, flags)
            if current != rootFD { close(current) }
            guard next >= 0 else {
                throw GameRunPreparationError.invalidProject("unreadable file \(path.value)")
            }
            current = next
        }
        defer { close(current) }
        var info = stat()
        guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GameRunPreparationError.invalidProject("unsafe file \(path.value)")
        }
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        let count = buffer.withUnsafeMutableBytes { bytes in
            systemRead(current, bytes.baseAddress!, bytes.count)
        }
        guard count >= 0 else {
            throw GameRunPreparationError.invalidProject("read failed \(path.value)")
        }
        return Data(buffer.prefix(count))
    }

    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameRunPreparationError.invalidArtifact("output directory")
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw GameRunPreparationError.invalidArtifact("write \(url.lastPathComponent)")
        }
        let readback = try Data(contentsOf: url)
        guard readback == data else {
            throw GameRunPreparationError.invalidArtifact("read back \(url.lastPathComponent)")
        }
    }

    /// Copies the scanned file bytes into a fresh staging directory. Unknown and
    /// license files are retained; no source path is rewritten.
    static func copyTree(index: GameRunSourceIndex, to destination: URL,
                         limits: GameRunPreparationLimits) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GameRunPreparationError.invalidArtifact("staging already exists")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for directory in index.directories {
            let url = destination.appendingPathComponent(directory.value, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var total = 0
        for file in index.files {
            try Task.checkCancellation()
            guard total <= limits.maximumProjectBytes - file.bytes else {
                throw GameRunPreparationError.invalidProject("project bytes")
            }
            let bytes = try read(root: index.rootURL, path: file.path,
                                 maximumBytes: max(file.bytes + 1, 1))
            guard bytes.count == file.bytes else {
                throw GameRunPreparationError.invalidProject("file changed \(file.path.value)")
            }
            total += bytes.count
            try write(bytes, to: destination.appendingPathComponent(file.path.value))
            if file.executable {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                    ofItemAtPath: destination.appendingPathComponent(file.path.value).path)
            }
        }
    }

    static func readIfRegular(root: URL, path: GameRelativePath, maximumBytes: Int) -> Data? {
        (try? read(root: root, path: path, maximumBytes: maximumBytes))
    }
}

func gameRunIsWASMPath(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasSuffix(".wasm") || lower.hasSuffix(".wasm.br")
        || lower.hasSuffix(".wasm.gz") || lower.hasSuffix(".wasm.unityweb")
}

func gameRunIsCompressedWASMPath(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasSuffix(".wasm.br") || lower.hasSuffix(".wasm.gz")
        || lower.hasSuffix(".wasm.unityweb")
}

struct GameRunWebEntry: Sendable, Equatable {
    let entry: GameRelativePath
    /// Normalized local script paths that exist in the inventory.
    let references: [String]
    /// Remote/data/javascript script references that the offline CSP blocks.
    let externalReferences: [String]
    /// Normalized local script paths that are referenced but absent.
    let missingReferences: [String]
    let isPublishedTwine: Bool
    let hasInlineScript: Bool
    let hasScriptTag: Bool

    var isSelfContained: Bool {
        externalReferences.isEmpty && missingReferences.isEmpty
    }
}

enum GameRunWebProbe {
    static func evaluate(index: GameRunSourceIndex, entry: GameRelativePath?,
                         limits: GameRunPreparationLimits, inspectTwine: Bool = false) throws -> GameRunWebEntry? {
        guard let entry else { return nil }
        let storyScanLimit = min(limits.maximumFileBytes, 16 * 1024 * 1024)
        let isPublishedTwine = try inspectTwine && GameProjectInspector.isTwineHTML(
            reader: GameProjectReader(rootURL: index.rootURL, maximumFileBytes: limits.maximumFileBytes),
            path: entry, maximumScanBytes: storyScanLimit)
        let bytes = try GameRunFileIO.read(root: index.rootURL, path: entry,
            maximumBytes: isPublishedTwine ? max(limits.maximumIndexBytes, storyScanLimit) : limits.maximumIndexBytes)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw GameRunPreparationError.invalidProject("HTML entry is not UTF-8")
        }
        let scriptTag: NSRegularExpression
        let sourceAttribute: NSRegularExpression
        do {
            scriptTag = try NSRegularExpression(pattern: #"<script\b([^>]*)>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators])
            sourceAttribute = try NSRegularExpression(pattern: #"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
                options: [.caseInsensitive])
        } catch {
            throw GameRunPreparationError.invalidProject("script matcher")
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var references: [String] = []
        var external: [String] = []
        var missing: [String] = []
        var hasInline = false
        var hasScriptTag = false
        for match in scriptTag.matches(in: text, options: [], range: range) {
            hasScriptTag = true
            guard let attributesRange = Range(match.range(at: 1), in: text) else { continue }
            let attributes = String(text[attributesRange])
            let attributesNS = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
            guard let sourceMatch = sourceAttribute.firstMatch(in: attributes, options: [], range: attributesNS) else {
                hasInline = true
                continue
            }
            let raw: String
            if let valueRange = Range(sourceMatch.range(at: 1), in: attributes) {
                raw = String(attributes[valueRange])
            } else if let valueRange = Range(sourceMatch.range(at: 2), in: attributes) {
                raw = String(attributes[valueRange])
            } else if let valueRange = Range(sourceMatch.range(at: 3), in: attributes) {
                raw = String(attributes[valueRange])
            } else {
                continue
            }
            let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            let lower = source.lowercased()
            if lower.hasPrefix("data:") || lower.hasPrefix("javascript:")
                || lower.contains("://") || source.hasPrefix("//") {
                external.append(source)
                continue
            }
            let withoutQuery = source.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            var components = entry.value.split(separator: "/").dropLast().map(String.init)
            var escaped = false
            for rawComponent in withoutQuery.split(separator: "/", omittingEmptySubsequences: false) {
                let component = String(rawComponent)
                if component.isEmpty || component == "." { continue }
                if component == ".." {
                    guard !components.isEmpty else { escaped = true; break }
                    components.removeLast()
                } else {
                    components.append(component)
                }
            }
            guard !escaped, !components.isEmpty else {
                external.append(source)
                continue
            }
            let normalized: String
            do { normalized = try GameRelativePath(components.joined(separator: "/")).value }
            catch {
                external.append(source)
                continue
            }
            if index.contains(normalized) {
                references.append(normalized)
            } else {
                missing.append(normalized)
            }
        }
        return .init(entry: entry,
                     references: references.sorted(),
                     externalReferences: external,
                     missingReferences: missing.sorted(),
                     isPublishedTwine: isPublishedTwine,
                     hasInlineScript: hasInline,
                     hasScriptTag: hasScriptTag)
    }
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer,
                        _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
#else
    Glibc.read(descriptor, buffer, count)
#endif
}

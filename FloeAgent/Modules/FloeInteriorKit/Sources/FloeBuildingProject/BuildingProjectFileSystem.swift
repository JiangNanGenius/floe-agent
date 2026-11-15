import CryptoKit
import Darwin
import Foundation

enum BuildingProjectPaths {
    static let manifestName = "Manifest.json"
    static let generationsDirectoryName = "Generations"
    static let stagingDirectoryName = "Staging"
    static let journalDirectoryName = "Journal"
    static let workDirectoryName = "Work"
    static let abandonedDirectoryName = "Abandoned"
    static let lockName = ".project.lock"
    static let generationFileName = "Generation.json"
    static let workingCopyFileName = "WorkingCopy.json"

    static let recordsDirectoryName = "Records"
    static let cadDirectoryName = "CAD"
    static let editorStateDirectoryName = "EditorState"
    static let assetResourcesDirectoryName = "AssetResources"

    static let editorStateRelativePath = "editor-state.json"
    static let recordsDatabaseRelativePath = "Building/Records.sqlite"

    static func sectionDirectoryName(_ section: BuildingFileSection) -> String {
        switch section {
        case .records: return recordsDirectoryName
        case .cad: return cadDirectoryName
        case .editorState: return editorStateDirectoryName
        case .assetResources: return assetResourcesDirectoryName
        }
    }

    static func generationDirectoryURL(root: URL, generationID: String) -> URL {
        root.appendingPathComponent(generationsDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
    }

    static func sectionRootURL(generationURL: URL, section: BuildingFileSection) -> URL {
        generationURL.appendingPathComponent(sectionDirectoryName(section), isDirectory: true)
    }

    static func isContained(root: URL, url: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func isSameOrAncestor(_ ancestor: URL, of descendant: URL) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.count >= ancestorComponents.count else { return false }
        return Array(descendantComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    static func validateRelativePath(
        _ path: String,
        limits: BuildingProjectLimits,
        label: String
    ) throws {
        guard !path.isEmpty else {
            throw BuildingProjectError.pathEscapesRoot("\(label) has an empty path")
        }
        guard path.utf8.count <= limits.maxRelativePathLength else {
            throw BuildingProjectError.budgetExceeded(
                "\(label) path \(path.prefix(64)) is longer than \(limits.maxRelativePathLength) bytes"
            )
        }
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.utf8.contains(UInt8(0)) else {
            throw BuildingProjectError.pathEscapesRoot(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count - 1 <= limits.maxDirectoryDepth else {
            throw BuildingProjectError.pathEscapesRoot(path)
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw BuildingProjectError.pathEscapesRoot(path)
            }
            guard component.utf8.count <= 255 else {
                throw BuildingProjectError.pathEscapesRoot(path)
            }
        }
    }

    static func isRecordsPath(_ path: String) -> Bool {
        if path == recordsDatabaseRelativePath { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 5,
              components[0] == "Building",
              components[1] == "Sources",
              components[2] == "blobs",
              components[3].count == 2,
              components[4].count == 64 else {
            return false
        }
        let prefix = components[3]
        let digest = components[4]
        guard digest.hasPrefix(prefix) else { return false }
        return prefix.utf8.allSatisfy { isLowercaseHex($0) }
            && digest.utf8.allSatisfy { isLowercaseHex($0) }
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

struct BuildingInspectedFile {
    let section: BuildingFileSection
    let relativePath: String
    let url: URL
    let byteCount: Int
}

enum BuildingProjectFileSystem {
    enum Kind: Equatable {
        case missing
        case regular
        case directory
        case symbolicLink
        case other
    }

    static func kind(of url: URL) -> Kind {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .other
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG { return .regular }
        if type == S_IFDIR { return .directory }
        if type == S_IFLNK { return .symbolicLink }
        return .other
    }

    static func fileSize(_ url: URL) throws -> Int {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw BuildingProjectError.ioFailure("\(url.lastPathComponent) is not a regular file")
        }
        guard info.st_size >= 0, info.st_size <= Int64(Int.max) else {
            throw BuildingProjectError.ioFailure("\(url.lastPathComponent) has an invalid size")
        }
        return Int(info.st_size)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func inspectTree(
        root: URL,
        section: BuildingFileSection,
        limits: BuildingProjectLimits,
        isCancelled: @Sendable () -> Bool
    ) throws -> [BuildingInspectedFile] {
        switch kind(of: root) {
        case .directory:
            break
        case .missing:
            throw BuildingProjectError.ioFailure("the \(section.rawValue) directory is missing")
        case .symbolicLink:
            throw BuildingProjectError.symbolicLinkRejected(sectionDirectoryLabel(section))
        case .regular, .other:
            throw BuildingProjectError.unsupportedFileType(sectionDirectoryLabel(section))
        }
        var result: [BuildingInspectedFile] = []
        var seen: Set<String> = []
        var totalBytes = 0
        try walkTree(
            directory: root,
            prefix: "",
            depth: 0,
            section: section,
            limits: limits,
            isCancelled: isCancelled,
            result: &result,
            seen: &seen,
            totalBytes: &totalBytes
        )
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func walkTree(
        directory: URL,
        prefix: String,
        depth: Int,
        section: BuildingFileSection,
        limits: BuildingProjectLimits,
        isCancelled: @Sendable () -> Bool,
        result: inout [BuildingInspectedFile],
        seen: inout Set<String>,
        totalBytes: inout Int
    ) throws {
        if isCancelled() { throw BuildingProjectError.cancelled }
        guard depth <= limits.maxDirectoryDepth else {
            throw BuildingProjectError.budgetExceeded("directory depth exceeds \(limits.maxDirectoryDepth)")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw BuildingProjectError.ioFailure("cannot list \(directory.lastPathComponent)")
        }
        for name in names {
            if isCancelled() { throw BuildingProjectError.cancelled }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw BuildingProjectError.pathEscapesRoot(name)
            }
            let relativePath = prefix.isEmpty ? name : prefix + "/" + name
            try BuildingProjectPaths.validateRelativePath(
                relativePath,
                limits: limits,
                label: section.rawValue
            )
            let child = directory.appendingPathComponent(name, isDirectory: false)
            switch kind(of: child) {
            case .directory:
                try walkTree(
                    directory: child,
                    prefix: relativePath,
                    depth: depth + 1,
                    section: section,
                    limits: limits,
                    isCancelled: isCancelled,
                    result: &result,
                    seen: &seen,
                    totalBytes: &totalBytes
                )
            case .regular:
                guard result.count < limits.maxFileCount else {
                    throw BuildingProjectError.budgetExceeded(
                        "\(section.rawValue) has more than \(limits.maxFileCount) files"
                    )
                }
                let folded = relativePath.lowercased()
                guard seen.insert(folded).inserted else {
                    throw BuildingProjectError.duplicatePath(relativePath)
                }
                let byteCount = try fileSize(child)
                guard byteCount <= limits.maxSingleFileBytes else {
                    throw BuildingProjectError.budgetExceeded(
                        "\(relativePath) is \(byteCount) bytes; the limit is \(limits.maxSingleFileBytes)"
                    )
                }
                guard totalBytes <= limits.maxTotalBytes - byteCount else {
                    throw BuildingProjectError.budgetExceeded(
                        "\(section.rawValue) exceeds maxTotalBytes \(limits.maxTotalBytes)"
                    )
                }
                totalBytes += byteCount
                result.append(BuildingInspectedFile(
                    section: section,
                    relativePath: relativePath,
                    url: child,
                    byteCount: byteCount
                ))
            case .symbolicLink:
                throw BuildingProjectError.symbolicLinkRejected(relativePath)
            case .other:
                throw BuildingProjectError.unsupportedFileType(relativePath)
            case .missing:
                throw BuildingProjectError.sourceChangedDuringCommit(relativePath)
            }
        }
    }

    static func hashTree(
        root: URL,
        section: BuildingFileSection,
        limits: BuildingProjectLimits,
        isCancelled: @Sendable () -> Bool
    ) throws -> [BuildingFileRecord] {
        let inspected = try inspectTree(
            root: root,
            section: section,
            limits: limits,
            isCancelled: isCancelled
        )
        var records: [BuildingFileRecord] = []
        records.reserveCapacity(inspected.count)
        for entry in inspected {
            if isCancelled() { throw BuildingProjectError.cancelled }
            let digest = try hashFile(
                entry.url,
                relativePath: entry.relativePath,
                chunkBytes: limits.copyChunkBytes,
                isCancelled: isCancelled
            )
            guard digest.byteCount == entry.byteCount else {
                throw BuildingProjectError.sourceChangedDuringCommit(entry.relativePath)
            }
            records.append(BuildingFileRecord(
                section: section,
                relativePath: entry.relativePath,
                byteCount: digest.byteCount,
                sha256: digest.sha256
            ))
        }
        return records
    }

    static func hashFile(
        _ url: URL,
        relativePath: String,
        chunkBytes: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> (sha256: String, byteCount: Int) {
        guard kind(of: url) == .regular else {
            throw BuildingProjectError.unsupportedFileType(relativePath)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            if isCancelled() { throw BuildingProjectError.cancelled }
            total += chunk.count
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    static func copyTree(
        from sourceRoot: URL,
        to destinationRoot: URL,
        section: BuildingFileSection,
        inspected: [BuildingInspectedFile],
        limits: BuildingProjectLimits,
        isCancelled: @Sendable () -> Bool,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> [BuildingFileRecord] {
        guard kind(of: destinationRoot) == .missing else {
            throw BuildingProjectError.ioFailure("the staging \(section.rawValue) directory already exists")
        }
        try ensureDirectory(destinationRoot)
        var copied: [BuildingFileRecord] = []
        copied.reserveCapacity(inspected.count)
        var completed = 0
        for entry in inspected {
            if isCancelled() { throw BuildingProjectError.cancelled }
            guard entry.section == section else {
                throw BuildingProjectError.ioFailure("mixed sections in a copy request")
            }
            let destination = destinationRoot.appendingPathComponent(entry.relativePath, isDirectory: false)
            try ensureDirectory(destination.deletingLastPathComponent())
            let result = try copyFile(
                from: entry.url,
                to: destination,
                expectedByteCount: entry.byteCount,
                expectedSHA256: nil,
                relativePath: entry.relativePath,
                chunkBytes: limits.copyChunkBytes,
                isCancelled: isCancelled
            )
            copied.append(BuildingFileRecord(
                section: section,
                relativePath: entry.relativePath,
                byteCount: result.byteCount,
                sha256: result.sha256
            ))
            completed += 1
            progress?(completed)
        }
        let destinationHashes = try hashTree(
            root: destinationRoot,
            section: section,
            limits: limits,
            isCancelled: isCancelled
        )
        let expected = copied.sorted { $0.relativePath < $1.relativePath }
        guard destinationHashes == expected else {
            throw BuildingProjectError.ioFailure(
                "the copied \(section.rawValue) files did not read back with the same hashes"
            )
        }
        let sourceAfter: [BuildingFileRecord]
        do {
            sourceAfter = try hashTree(
                root: sourceRoot,
                section: section,
                limits: limits,
                isCancelled: isCancelled
            )
        } catch let error as BuildingProjectError {
            if error == .cancelled { throw error }
            throw BuildingProjectError.sourceChangedDuringCommit(section.rawValue)
        } catch {
            throw BuildingProjectError.sourceChangedDuringCommit(section.rawValue)
        }
        guard sourceAfter == destinationHashes else {
            throw BuildingProjectError.sourceChangedDuringCommit(section.rawValue)
        }
        return destinationHashes
    }

    static func copyFile(
        from source: URL,
        to destination: URL,
        expectedByteCount: Int,
        expectedSHA256: String?,
        relativePath: String,
        chunkBytes: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> (sha256: String, byteCount: Int) {
        if isCancelled() { throw BuildingProjectError.cancelled }
        guard expectedByteCount >= 0, kind(of: source) == .regular else {
            throw BuildingProjectError.sourceChangedDuringCommit(relativePath)
        }
        let fileManager = FileManager.default
        try ensureDirectory(destination.deletingLastPathComponent())
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BuildingProjectError.ioFailure("cannot create \(destination.lastPathComponent)")
        }
        let input = try FileHandle(forReadingFrom: source)
        var output: FileHandle?
        var completed = false
        defer {
            try? input.close()
            if let output {
                try? output.close()
            }
            if !completed {
                try? fileManager.removeItem(at: destination)
            }
        }
        let writer = try FileHandle(forWritingTo: destination)
        output = writer
        var hasher = SHA256()
        var total = 0
        while let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty {
            if isCancelled() { throw BuildingProjectError.cancelled }
            total += chunk.count
            guard total <= expectedByteCount else {
                throw BuildingProjectError.sourceChangedDuringCommit(relativePath)
            }
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
        }
        guard total == expectedByteCount else {
            throw BuildingProjectError.sourceChangedDuringCommit(relativePath)
        }
        try writer.synchronize()
        try writer.close()
        output = nil
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, digest != expectedSHA256 {
            throw BuildingProjectError.sourceChangedDuringCommit(relativePath)
        }
        let readback = try hashFile(
            destination,
            relativePath: relativePath,
            chunkBytes: chunkBytes,
            isCancelled: isCancelled
        )
        guard readback.sha256 == digest, readback.byteCount == total else {
            throw BuildingProjectError.ioFailure(
                "\(relativePath) did not read back with the same bytes"
            )
        }
        completed = true
        return (digest, total)
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)
        let temp = parent.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try data.write(to: temp, options: .atomic)
            let handle = try FileHandle(forUpdating: temp)
            try handle.synchronize()
            try handle.close()
            let result = temp.path.withCString { source in
                url.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else {
                throw BuildingProjectError.ioFailure(
                    "rename failed with errno \(errno): \(String(cString: strerror(errno)))"
                )
            }
            fsyncDirectory(parent)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    static func readBounded(_ url: URL, maxBytes: Int) throws -> Data {
        guard kind(of: url) == .regular else {
            throw BuildingProjectError.ioFailure("\(url.lastPathComponent) is not a regular file")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            let remaining = maxBytes + 1 - data.count
            guard remaining > 0 else {
                throw BuildingProjectError.budgetExceeded("\(url.lastPathComponent) is over its byte limit")
            }
            let chunkSize = min(64 * 1024, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            if data.count > maxBytes {
                throw BuildingProjectError.budgetExceeded("\(url.lastPathComponent) is over its byte limit")
            }
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if kind(of: url) == .missing {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } else if kind(of: url) != .directory {
            throw BuildingProjectError.ioFailure("\(url.lastPathComponent) is not a directory")
        }
    }

    static func listDirectoryNames(_ url: URL) throws -> [String] {
        switch kind(of: url) {
        case .missing:
            return []
        case .directory:
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        case .symbolicLink:
            throw BuildingProjectError.symbolicLinkRejected(url.lastPathComponent)
        case .regular, .other:
            throw BuildingProjectError.unsupportedFileType(url.lastPathComponent)
        }
    }

    static func removeTree(_ url: URL) throws {
        switch kind(of: url) {
        case .missing:
            return
        case .directory:
            try FileManager.default.removeItem(at: url)
        case .symbolicLink:
            throw BuildingProjectError.symbolicLinkRejected(url.lastPathComponent)
        case .regular, .other:
            throw BuildingProjectError.unsupportedFileType(url.lastPathComponent)
        }
    }

    static func fsyncDirectory(_ url: URL) {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        _ = Darwin.close(descriptor)
    }

    static func requireNoSymlinkComponents(root: URL, url: URL) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            throw BuildingProjectError.pathEscapesRoot(url.path)
        }
        var current = root
        for component in urlComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            if kind(of: current) == .symbolicLink {
                throw BuildingProjectError.symbolicLinkRejected(url.path)
            }
        }
    }

    private static func sectionDirectoryLabel(_ section: BuildingFileSection) -> String {
        BuildingProjectPaths.sectionDirectoryName(section)
    }
}

enum BuildingProjectJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}

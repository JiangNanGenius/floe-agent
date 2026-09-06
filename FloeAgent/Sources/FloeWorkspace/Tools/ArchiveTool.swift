// FloeWorkspace — workspace.archive agent tool.
//
// First-class zip capability: create, extract and list archives inside the
// task workspace. Extraction is bounded (entry count, total bytes, entry-name
// sanitization) so a hostile archive cannot escape the workspace or fill the
// device.

import Foundation
import ZIPFoundation
import FloeCore
import FloeTools

/// Creates, extracts and lists zip archives inside the workspace.
public struct WorkspaceArchiveTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var source: String
        public var destination: String?
        /// zip or tar; defaults to the destination/source extension.
        public var format: String?
        /// Present when the call is routed to a host scope; always rejected.
        public var scope: String?

        public init(action: String, source: String, destination: String? = nil, format: String? = nil, scope: String? = nil) {
            self.action = action
            self.source = source
            self.destination = destination
            self.format = format
            self.scope = scope
        }
    }

    public static let name = "workspace.archive"
    public static let toolDescription =
        "Archive operations inside the workspace. action=create packs one file or directory into a new archive at destination; action=extract unpacks into a new destination directory (entry count and total size are capped, unsafe entry names are skipped); action=list shows entries. Formats: zip and tar (format parameter or file extension). For compressed variants (tar.gz/tar.bz2/tar.xz/gz/bz2/xz) and 7z/rar use exec.localPython, which bundles tarfile/gzip/bz2/lzma. Existing destinations are never overwritten."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["create", "extract", "list"]},
        "source": {"type": "string", "description": "Workspace-relative source: file/directory to pack (create) or archive to read (extract/list)"},
        "destination": {"type": "string", "description": "Workspace-relative output archive (create) or output directory (extract); required for create and extract"},
        "format": {"type": "string", "enum": ["zip", "tar"], "description": "Archive format; defaults to the destination/source extension"}
      },
      "required": ["action", "source"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private static let maxEntries = 5_000
    private static let maxTotalUncompressedBytes = 256 * 1_024 * 1_024
    private static let maxListedEntries = 500

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        guard ["create", "extract", "list"].contains(args.action) else {
            throw WorkspaceToolError.invalidArguments("action must be create, extract or list")
        }
        for path in [args.source, args.destination].compactMap({ $0 }) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                  !trimmed.split(separator: "/").contains("..") else {
                throw WorkspaceToolError.invalidArguments("paths must be workspace-relative")
            }
        }
        if args.action != "list",
           args.destination?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw WorkspaceToolError.invalidArguments("destination is required for create and extract")
        }
        if let format = args.format, format != "zip", format != "tar" {
            throw WorkspaceToolError.invalidArguments("format must be zip or tar")
        }
    }

    /// Resolves the archive format from the explicit parameter or extension.
    private func format(for args: Arguments) throws -> String {
        if let format = args.format { return format }
        let reference = args.action == "create" ? (args.destination ?? "") : args.source
        switch (reference as NSString).pathExtension.lowercased() {
        case "tar": return "tar"
        case "zip": return "zip"
        default:
            throw WorkspaceToolError.invalidArguments(
                "Cannot infer the archive format from \(reference); pass format: zip or tar. " +
                "Compressed variants (tar.gz/tar.bz2/tar.xz/gz/bz2/xz) are available through exec.localPython."
            )
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.source)
        let service = try environment.makeService(context: context)
        let guarder = service.guardResolver
        let sourceURL = try guarder.resolve(args.source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw WorkspaceToolError.notFound(args.source)
        }
        switch (args.action, try format(for: args)) {
        case ("create", "tar"):
            return try createTar(args, context: context, guarder: guarder, sourceURL: sourceURL)
        case ("extract", "tar"):
            return try extractTar(args, context: context, guarder: guarder, sourceURL: sourceURL)
        case ("list", "tar"):
            return try listTar(args, sourceURL: sourceURL)
        case ("create", _):
            return try create(args, context: context, guarder: guarder, sourceURL: sourceURL)
        case ("extract", _):
            return try extract(args, context: context, guarder: guarder, sourceURL: sourceURL)
        default:
            return try list(args, sourceURL: sourceURL)
        }
    }

    // MARK: - create

    private func create(
        _ args: Arguments,
        context: ToolContext,
        guarder: WorkspacePathGuard,
        sourceURL: URL
    ) throws -> ToolExecutionOutput {
        let destination = args.destination!
        try context.authorizeWorkspacePath(destination)
        let destinationURL = try guarder.resolve(destination)
        try guarder.assertWritable(destinationURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceToolError.alreadyExists(destination)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        let temporary = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let archive = Archive(url: temporary, accessMode: .create) else {
            throw FloeError.internalError("Could not create the archive")
        }
        var entryCount = 0
        var totalBytes: Int64 = 0
        if isDirectory.boolValue {
            let base = sourceURL.deletingLastPathComponent()
            let basePath = base.path
            let sourceName = sourceURL.lastPathComponent
            func relativePath(for item: URL) -> String {
                let itemPath = item.path
                if itemPath.hasPrefix(basePath + "/") {
                    return String(itemPath.dropFirst(basePath.count + 1))
                }
                // macOS temp roots differ by symlink resolution (/var vs
                // /private/var). Re-anchor on the source directory name so
                // entry names always stay workspace-relative.
                let marker = "/" + sourceName + "/"
                if let range = itemPath.range(of: marker, options: .backwards) {
                    return sourceName + "/" + itemPath[range.upperBound...]
                }
                return item.lastPathComponent
            }
            guard let enumerator = FileManager.default.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { throw WorkspaceToolError.notFound(args.source) }
            for case let item as URL in enumerator {
                try context.cancellation.throwIfCancelled()
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                let relative = relativePath(for: item)
                if values.isDirectory == true {
                    try archive.addEntry(
                        with: relative + "/",
                        fileURL: item,
                        compressionMethod: .none
                    )
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard entryCount < Self.maxEntries else {
                    throw WorkspaceToolError.tooLarge(limit: Self.maxEntries)
                }
                let size = Int64((try item.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                totalBytes += size
                guard totalBytes <= Int64(Self.maxTotalUncompressedBytes) else {
                    throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
                }
                try archive.addEntry(
                    with: relative,
                    fileURL: item,
                    compressionMethod: .deflate
                )
                entryCount += 1
            }
        } else {
            let size = Int64((try sourceURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard size <= Int64(Self.maxTotalUncompressedBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
            }
            try archive.addEntry(
                with: sourceURL.lastPathComponent,
                fileURL: sourceURL,
                compressionMethod: .deflate
            )
            entryCount = 1
            totalBytes = size
        }
        try FileManager.default.moveItem(at: temporary, to: destinationURL)
        return WorkspaceToolSupport.output(
            "status=ok action=create source=\(args.source) destination=\(destination) entries=\(entryCount) uncompressedBytes=\(totalBytes)"
        )
    }

    // MARK: - extract

    private func extract(
        _ args: Arguments,
        context: ToolContext,
        guarder: WorkspacePathGuard,
        sourceURL: URL
    ) throws -> ToolExecutionOutput {
        let destination = args.destination!
        try context.authorizeWorkspacePath(destination)
        let destinationURL = try guarder.resolve(destination)
        try guarder.assertWritable(destinationURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceToolError.alreadyExists(destination)
        }
        guard let archive = Archive(url: sourceURL, accessMode: .read) else {
            throw WorkspaceToolError.invalidArguments("source is not a readable zip archive")
        }
        var extracted = 0
        var skipped = 0
        var totalBytes: UInt64 = 0
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for entry in archive {
            try context.cancellation.throwIfCancelled()
            // Directory entries are structural: file extraction recreates the
            // tree, and only files count toward the reported total.
            guard entry.type == .file else { continue }
            guard extracted < Self.maxEntries else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxEntries)
            }
            // Never let an entry escape the destination or touch absolute paths.
            let name = entry.path
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !name.hasPrefix("/"), !name.hasPrefix("~"),
                  !components.contains(".."), !components.isEmpty else {
                skipped += 1
                continue
            }
            totalBytes += entry.uncompressedSize
            guard totalBytes <= UInt64(Self.maxTotalUncompressedBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
            }
            let target = destinationURL.appendingPathComponent(name)
            guard target.path.hasPrefix(destinationURL.path + "/") else {
                skipped += 1
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
            extracted += 1
        }
        return WorkspaceToolSupport.output(
            "status=ok action=extract source=\(args.source) destination=\(destination) entries=\(extracted) skipped=\(skipped) uncompressedBytes=\(totalBytes)"
        )
    }

    // MARK: - list

    // MARK: - zip list

    private func list(_ args: Arguments, sourceURL: URL) throws -> ToolExecutionOutput {
        guard let archive = Archive(url: sourceURL, accessMode: .read) else {
            throw WorkspaceToolError.invalidArguments("source is not a readable zip archive")
        }
        var lines = ["status=ok action=list source=\(args.source)"]
        var count = 0
        var truncated = false
        for entry in archive {
            if count >= Self.maxListedEntries { truncated = true; break }
            lines.append("\(entry.type == .directory ? "dir" : "file")\t\(entry.uncompressedSize)\t\(entry.path)")
            count += 1
        }
        lines[0] += " entries=\(count) truncated=\(truncated)"
        return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
    }

    // MARK: - tar create / extract / list

    private func createTar(
        _ args: Arguments,
        context: ToolContext,
        guarder: WorkspacePathGuard,
        sourceURL: URL
    ) throws -> ToolExecutionOutput {
        let destination = args.destination!
        try context.authorizeWorkspacePath(destination)
        let destinationURL = try guarder.resolve(destination)
        try guarder.assertWritable(destinationURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceToolError.alreadyExists(destination)
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        var writer = TarArchiveWriter()
        var entryCount = 0
        var totalBytes: Int64 = 0
        if isDirectory.boolValue {
            let base = sourceURL.deletingLastPathComponent()
            let basePath = base.path
            let sourceName = sourceURL.lastPathComponent
            guard let enumerator = FileManager.default.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { throw WorkspaceToolError.notFound(args.source) }
            for case let item as URL in enumerator {
                try context.cancellation.throwIfCancelled()
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                let relative = Self.relativeName(
                    of: item.path, basePath: basePath, sourceName: sourceName
                )
                if values.isDirectory == true {
                    try writer.addDirectory(name: relative)
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard entryCount < Self.maxEntries else {
                    throw WorkspaceToolError.tooLarge(limit: Self.maxEntries)
                }
                let size = Int64((try item.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                totalBytes += size
                guard totalBytes <= Int64(Self.maxTotalUncompressedBytes) else {
                    throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
                }
                let contents = try Data(contentsOf: item, options: [.mappedIfSafe])
                try writer.addFile(name: relative, contents: contents)
                entryCount += 1
            }
        } else {
            let size = Int64((try sourceURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard size <= Int64(Self.maxTotalUncompressedBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
            }
            let contents = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            try writer.addFile(name: sourceURL.lastPathComponent, contents: contents)
            entryCount = 1
            totalBytes = size
        }
        let tarData = writer.finish()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try tarData.write(to: destinationURL, options: [.atomic])
        return WorkspaceToolSupport.output(
            "status=ok action=create format=tar source=\(args.source) destination=\(destination) entries=\(entryCount) uncompressedBytes=\(totalBytes)"
        )
    }

    private func extractTar(
        _ args: Arguments,
        context: ToolContext,
        guarder: WorkspacePathGuard,
        sourceURL: URL
    ) throws -> ToolExecutionOutput {
        let destination = args.destination!
        try context.authorizeWorkspacePath(destination)
        let destinationURL = try guarder.resolve(destination)
        try guarder.assertWritable(destinationURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceToolError.alreadyExists(destination)
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard data.count <= Int(Self.maxTotalUncompressedBytes) + 1_048_576 else {
            throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
        }
        let entries = try TarArchiveReader.entries(in: data)
        var extracted = 0
        var skipped = 0
        var totalBytes: UInt64 = 0
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for entry in entries where !entry.isDirectory {
            try context.cancellation.throwIfCancelled()
            guard extracted < Self.maxEntries else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxEntries)
            }
            let name = entry.name
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            // macOS AppleDouble metadata (._name) is noise, not content.
            if let baseName = components.last, baseName.hasPrefix("._") {
                continue
            }
            guard !name.hasPrefix("/"), !name.hasPrefix("~"),
                  !components.contains(".."), !components.isEmpty else {
                skipped += 1
                continue
            }
            totalBytes += UInt64(entry.size)
            guard totalBytes <= UInt64(Self.maxTotalUncompressedBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
            }
            let target = destinationURL.appendingPathComponent(name)
            guard target.path.hasPrefix(destinationURL.path + "/") else {
                skipped += 1
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.contents.write(to: target, options: [.atomic])
            extracted += 1
        }
        return WorkspaceToolSupport.output(
            "status=ok action=extract format=tar source=\(args.source) destination=\(destination) entries=\(extracted) skipped=\(skipped) uncompressedBytes=\(totalBytes)"
        )
    }

    private func listTar(_ args: Arguments, sourceURL: URL) throws -> ToolExecutionOutput {
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let entries = try TarArchiveReader.entries(in: data)
        var lines = ["status=ok action=list format=tar source=\(args.source)"]
        var count = 0
        var truncated = false
        for entry in entries {
            if count >= Self.maxListedEntries { truncated = true; break }
            lines.append("\(entry.isDirectory ? "dir" : "file")\t\(entry.size)\t\(entry.name)")
            count += 1
        }
        lines[0] += " entries=\(count) truncated=\(truncated)"
        return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
    }

    private static func relativeName(of itemPath: String, basePath: String, sourceName: String) -> String {
        if itemPath.hasPrefix(basePath + "/") {
            return String(itemPath.dropFirst(basePath.count + 1))
        }
        let marker = "/" + sourceName + "/"
        if let range = itemPath.range(of: marker, options: .backwards) {
            return sourceName + "/" + itemPath[range.upperBound...]
        }
        return URL(fileURLWithPath: itemPath).lastPathComponent
    }
}

// MARK: - Minimal ustar reader/writer (no external dependency)

enum TarArchiveError: Error {
    case nameTooLong
    case malformedArchive
    case checksumMismatch
}

/// Writes POSIX ustar archives: 512-byte header blocks, file data padded to
/// 512, two zero blocks at the end.
struct TarArchiveWriter {
    private(set) var data = Data()

    mutating func addDirectory(name: String) throws {
        let normalized = name.hasSuffix("/") ? name : name + "/"
        data.append(try Self.header(name: normalized, size: 0, typeflag: "5"))
    }

    mutating func addFile(name: String, contents: Data) throws {
        data.append(try Self.header(name: name, size: contents.count, typeflag: "0"))
        data.append(contents)
        let padding = (512 - contents.count % 512) % 512
        if padding > 0 { data.append(Data(count: padding)) }
    }

    func finish() -> Data {
        data + Data(count: 1_024)
    }

    private static func header(name: String, size: Int, typeflag: Character) throws -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func write(_ string: String, at offset: Int, maxLength: Int) {
            let bytes = Array(string.utf8.prefix(maxLength))
            block.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        func octal(_ value: Int, at offset: Int, length: Int) {
            let text = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, length - 1 - text.count)) + text
            write(padded, at: offset, maxLength: length - 1)
        }

        var nameField = name
        var prefixField = ""
        if name.utf8.count > 100 {
            // ustar long-name split: prefix (155) + "/" + name (100).
            var splitOffset: String.Index? = nil
            var cursor = name.startIndex
            while let slash = name[cursor...].firstIndex(of: "/") {
                let candidatePrefix = String(name[..<slash])
                let candidateName = String(name[name.index(after: slash)...])
                if candidatePrefix.utf8.count <= 155, candidateName.utf8.count <= 100 {
                    splitOffset = slash
                }
                cursor = name.index(after: slash)
            }
            guard let slash = splitOffset else { throw TarArchiveError.nameTooLong }
            prefixField = String(name[..<slash])
            nameField = String(name[name.index(after: slash)...])
        }
        guard nameField.utf8.count <= 100 else { throw TarArchiveError.nameTooLong }

        write(nameField, at: 0, maxLength: 100)
        write(typeflag == "5" ? "0000755" : "0000644", at: 100, maxLength: 7)
        write("0000000", at: 108, maxLength: 7)
        write("0000000", at: 116, maxLength: 7)
        octal(size, at: 124, length: 12)
        octal(Int(Date().timeIntervalSince1970), at: 136, length: 12)
        block[156] = typeflag.asciiValue ?? 0x30
        write("ustar", at: 257, maxLength: 6)
        write("00", at: 263, maxLength: 2)
        write("floe", at: 265, maxLength: 32)
        write("floe", at: 297, maxLength: 32)
        write(prefixField, at: 345, maxLength: 155)
        // Checksum: field treated as eight spaces.
        for index in 148..<156 { block[index] = 0x20 }
        let checksum = block.reduce(0) { $0 + Int($1) }
        let checksumText = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - checksumText.count)) + checksumText
        write(padded, at: 148, maxLength: 6)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }
}

/// Reads POSIX ustar archives produced by common tools (GNU/BSD tar).
struct TarArchiveReader {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: Int
        let contents: Data
    }

    static func entries(in data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        var pendingLongName: String? = nil
        while offset + 512 <= data.count {
            let header = data[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { break }
            func field(_ start: Int, _ length: Int) -> String {
                let bytes = header[(header.startIndex + start)..<(header.startIndex + start + length)]
                let trimmed = bytes.prefix { $0 != 0 }
                return String(decoding: trimmed, as: UTF8.self)
            }
            let name = field(0, 100)
            let prefix = field(345, 155)
            let fullName = prefix.isEmpty ? name : prefix + "/" + name
            guard let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) else {
                throw TarArchiveError.malformedArchive
            }
            let typeflag = header[header.startIndex + 156]
            // Verify the header checksum before trusting any field.
            var checksumBlock = [UInt8](header)
            for index in 148..<156 { checksumBlock[index] = 0x20 }
            let expected = checksumBlock.reduce(0) { $0 + Int($1) }
            let recordedText = field(148, 8).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            guard let recorded = Int(recordedText, radix: 8), recorded == expected else {
                throw TarArchiveError.checksumMismatch
            }
            let dataStart = offset + 512
            guard dataStart + size <= data.count else {
                throw TarArchiveError.malformedArchive
            }
            let payload = Data(data[dataStart..<(dataStart + size)])
            offset = dataStart + ((size + 511) / 512) * 512

            switch typeflag {
            case Character("x").asciiValue, Character("g").asciiValue:
                // pax extended/global header: harvest path= for the next entry.
                pendingLongName = paxValue(forKey: "path", in: payload) ?? pendingLongName
                continue
            case Character("L").asciiValue:
                // GNU long name: payload is the null-terminated name itself.
                pendingLongName = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
                continue
            case Character("K").asciiValue:
                continue // GNU long link name; irrelevant for extraction.
            default:
                break
            }
            let isDirectory = typeflag == Character("5").asciiValue
            let isFile = typeflag == Character("0").asciiValue || typeflag == 0
            guard isDirectory || isFile else { continue }
            let finalName = pendingLongName ?? fullName
            pendingLongName = nil
            guard !finalName.isEmpty else { continue }
            let contents = isDirectory ? Data() : payload
            entries.append(Entry(name: finalName, isDirectory: isDirectory, size: size, contents: contents))
        }
        return entries
    }

    /// Extracts `key=value` from pax extended-header records (`len key=value\n`).
    private static func paxValue(forKey key: String, in payload: Data) -> String? {
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            guard let spaceIndex = payload[cursor...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: payload[cursor..<spaceIndex], as: UTF8.self)),
                  length > 0, cursor + length <= payload.endIndex else { break }
            let record = payload[(spaceIndex + 1)..<(cursor + length - 1)]
            if let equals = record.firstIndex(of: 0x3D) {
                let recordKey = String(decoding: record[..<equals], as: UTF8.self)
                if recordKey == key {
                    return String(decoding: record[(equals + 1)...], as: UTF8.self)
                }
            }
            cursor += length
        }
        return nil
    }
}

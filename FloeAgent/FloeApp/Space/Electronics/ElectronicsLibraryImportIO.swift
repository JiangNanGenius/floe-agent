// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import ZIPFoundation
import FloeElectronicsCore

/// Reads only picker-authorized files. Original files/archives are never
/// modified; native packages retain every original input byte on acceptance.
nonisolated enum ElectronicsLibraryImportIO {
    static let maximumFiles = 4_096
    static let maximumFileBytes = 32 * 1_024 * 1_024
    static let maximumTotalBytes = 128 * 1_024 * 1_024
    static func inspect(_ urls: [URL]) async throws -> EDALibraryImportDraft {
        let worker = Task.detached(priority: .userInitiated) {
            let files = try readSelections(urls)
            return try EDALibraryImport.inspect(files: files, title: urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Imported libraries", cancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func readSelections(_ urls: [URL]) throws -> [String: Data] {
        guard !urls.isEmpty, urls.count <= maximumFiles else { throw EDAError.invalid("library selection count") }
        var files: [String: Data] = [:], total = 0
        func insert(_ path: String, _ data: Data) throws {
            try Task.checkCancellation()
            guard EDALibraryPackage.safeRelativePath(path), files[path] == nil, files.count < maximumFiles,
                  data.count <= maximumFileBytes, total + data.count <= maximumTotalBytes else { throw EDAError.invalid("library path, collision or size limit") }
            files[path] = data; total += data.count
        }
        for source in urls {
            try Task.checkCancellation()
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?, result: Result<[String: Data], Error>?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                result = Result {
                    let values = try readable.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw EDAError.unsupported("library symbolic-link selection") }
                    if values.isDirectory == true {
                        let root = readable.standardizedFileURL.resolvingSymlinksInPath()
                        var enumerationFailure: Error?
                        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationFailure = error; return false }) else { throw EDAError.invalid("library directory") }
                        var collected: [String: Data] = [:], size = 0, traversed = 0
                        for case let file as URL in iterator {
                            try Task.checkCancellation(); traversed += 1
                            guard traversed <= maximumFiles * 2 else { throw EDAError.invalid("library directory entry limit") }
                            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                            guard attributes.isSymbolicLink != true else { throw EDAError.unsupported("library directory symbolic link") }
                            if attributes.isDirectory == true { continue }
                            guard attributes.isRegularFile == true, collected.count < maximumFiles else { throw EDAError.invalid("regular library input") }
                            let relative = root.lastPathComponent + "/" + String(file.path.dropFirst(root.path.count + 1))
                            let bytes = try PersonalPreviewFile(root: root, url: file, maximumBytes: maximumFileBytes).data()
                            guard EDALibraryPackage.safeRelativePath(relative), collected[relative] == nil, size + bytes.count <= maximumTotalBytes else { throw EDAError.invalid("library directory byte limit") }
                            collected[relative] = bytes; size += bytes.count
                        }
                        if let enumerationFailure { throw enumerationFailure }
                        return collected
                    }
                    guard values.isRegularFile == true else { throw EDAError.invalid("regular library input") }
                    let parent = readable.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                    let zipped = readable.pathExtension.lowercased() == "zip"
                    let bytes = try PersonalPreviewFile(root: parent, url: parent.appendingPathComponent(readable.lastPathComponent), maximumBytes: zipped ? maximumTotalBytes : maximumFileBytes).data()
                    if zipped { return try archiveFiles(bytes) }
                    let family = parent.lastPathComponent
                    let key = (family.hasSuffix(".pretty") || family.hasSuffix(".kicad_symdir") ? family + "/" : "") + readable.lastPathComponent
                    return [key: bytes]
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw EDAError.invalid("coordinated library read") }
            for (path, bytes) in try result.get() { try insert(path, bytes) }
        }
        return files
    }
    static func archiveFiles(_ bytes: Data) throws -> [String: Data] {
        guard bytes.count <= maximumTotalBytes else { throw EDAError.invalid("library archive size") }
        let archive = try Archive(data: bytes, accessMode: .read)
        var files: [String: Data] = [:], seen: Set<String> = [], total = 0, count = 0
        for entry in archive {
            try Task.checkCancellation(); count += 1
            let path = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard count <= maximumFiles * 2, EDALibraryPackage.safeRelativePath(path), !path.contains("\0"),
                  seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw EDAError.invalid("library archive entry path or collision") }
            if entry.type == .directory { continue }
            guard entry.type == .file, files.count < maximumFiles, entry.uncompressedSize <= UInt64(maximumFileBytes) else { throw EDAError.invalid("library archive file type or limit") }
            var data = Data()
            let checksum = try archive.extract(entry, bufferSize: 32_768) { block in
                try Task.checkCancellation()
                guard total + block.count <= maximumTotalBytes, data.count + block.count <= maximumFileBytes else { throw EDAError.invalid("library archive expanded byte limit") }
                data.append(block); total += block.count
            }
            guard checksum == entry.checksum, data.count == entry.uncompressedSize else { throw EDAError.invalid("library archive checksum") }
            files[path] = data
        }
        guard !files.isEmpty else { throw EDAError.invalid("empty library archive") }; return files
    }
}
#endif

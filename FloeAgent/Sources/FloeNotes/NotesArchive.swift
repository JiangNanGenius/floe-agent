// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto
import ZIPFoundation

/// Portable editable document, not a database backup. Import always creates a new document;
/// assistant grants, conversations, deleted data and undo history are deliberately not imported.
public enum NotesArchive {
    private struct Manifest: Codable, Sendable {
        var version = 1
        var document: NoteDocument
        var resources: [Resource]
    }
    private struct Resource: Codable, Sendable {
        var id: UUID
        var hash: String
        var size: Int64
        var path: String { "resources/\(hash)" }
    }
    private static let maximumResource: Int64 = 536_870_912
    private static let maximumTotal: Int64 = 2_147_483_648
    private static let maximumManifest = 16_777_216

    public static func export(document: NoteDocument, store: NotesStore, to destination: URL) async throws {
        try document.validate()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NoteError.invalidOperation("导出目标已经存在。")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".notes-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var inputs: [(UUID, URL)] = []
        for id in document.resourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            inputs.append((id, try await store.resourceURL(id)))
        }
        let worker = Task.detached(priority: .userInitiated) {
            let archive = try Archive(url: temporary, accessMode: .create)
            var resources: [Resource] = []; var total: Int64 = 0
            for (id, url) in inputs {
                try Task.checkCancellation()
                let (hash, size) = try digest(url)
                guard hash == url.lastPathComponent else { throw NoteError.resourceUnavailable }
                total += size
                guard total <= maximumTotal else { throw NoteError.invalidOperation("手记归档超过 2 GB，请拆分导出。") }
                let resource = Resource(id: id, hash: hash, size: size)
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                try archive.addEntry(with: resource.path, type: .file, uncompressedSize: size, compressionMethod: .none) { position, size in
                    try Task.checkCancellation()
                    try file.seek(toOffset: UInt64(position))
                    return try file.read(upToCount: size) ?? Data()
                }
                resources.append(resource)
            }
            let manifest = try JSONEncoder().encode(Manifest(document: document, resources: resources))
            guard manifest.count <= maximumManifest else { throw NoteError.invalidOperation("手记结构过大，请拆分导出。") }
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifest.count), compressionMethod: .deflate) { position, size in
                manifest.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public static func importDocument(from source: URL, notebookID: UUID?, store: NotesStore) async throws -> NoteDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = Task.detached(priority: .userInitiated) {
            let archive = try Archive(url: source, accessMode: .read)
            var paths: Set<String> = []; var count = 0
            for entry in archive {
                count += 1
                guard count <= 20_001, entry.type == .file, paths.insert(entry.path).inserted else {
                    throw NoteError.invalidDocument("归档包含重复或不支持的条目。")
                }
            }
            guard let entry = archive["manifest.json"], entry.uncompressedSize <= maximumManifest else {
                throw NoteError.invalidDocument("归档清单缺失或过大。")
            }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard data.count + chunk.count <= maximumManifest else { throw NoteError.invalidDocument("归档清单过大。") }
                data.append(chunk)
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1, manifest.resources.count <= 20_000,
                  Set(manifest.resources.map(\.id)) == manifest.document.resourceIDs,
                  Set(manifest.resources.map(\.id)).count == manifest.resources.count,
                  Set(manifest.resources.map(\.path)).count == manifest.resources.count,
                  paths == Set(["manifest.json"] + manifest.resources.map(\.path)) else {
                throw NoteError.invalidDocument("手记版本或资源清单无效。")
            }
            try manifest.document.validate()
            var total: Int64 = 0
            for resource in manifest.resources {
                try Task.checkCancellation()
                guard resource.hash.count == 64, resource.hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                      resource.size >= 0, resource.size <= maximumResource,
                      let entry = archive[resource.path], entry.uncompressedSize == resource.size else {
                    throw NoteError.invalidDocument("归档资源声明无效。")
                }
                total += resource.size
                guard total <= maximumTotal else { throw NoteError.invalidDocument("归档展开后超过 2 GB。") }
                // Destination is generated from a validated digest, never from archive path text.
                let url = directory.appendingPathComponent(resource.hash)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw NoteError.resourceUnavailable }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                var size: Int64 = 0; var hash = SHA256()
                _ = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    size += Int64(chunk.count)
                    guard size <= resource.size else { throw NoteError.invalidDocument("归档资源超过声明长度。") }
                    hash.update(data: chunk); try file.write(contentsOf: chunk)
                }
                guard size == resource.size, hex(hash.finalize()) == resource.hash else { throw NoteError.invalidDocument("归档资源校验失败。") }
            }
            return manifest
        }
        let manifest = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        var ids: [UUID: UUID] = [:]
        for resource in manifest.resources {
            ids[resource.id] = try await store.importResource(from: directory.appendingPathComponent(resource.hash), mediaType: "application/octet-stream")
        }
        var document = manifest.document
        let originalID = document.id
        document.id = UUID(); document.notebookID = notebookID; document.deletedAt = nil
        document.officeResourceID = document.officeResourceID.flatMap { ids[$0] }
        for p in document.pages.indices {
            document.pages[p].backgroundResourceID = document.pages[p].backgroundResourceID.flatMap { ids[$0] }
            document.pages[p].drawingResourceID = document.pages[p].drawingResourceID.flatMap { ids[$0] }
            for e in document.pages[p].elements.indices {
                document.pages[p].elements[e].resourceID = document.pages[p].elements[e].resourceID.flatMap { ids[$0] }
                if document.pages[p].elements[e].source?.space == .notes, document.pages[p].elements[e].source?.documentID == originalID {
                    document.pages[p].elements[e].source?.documentID = document.id
                }
            }
        }
        for n in document.nodes.indices {
            document.nodes[n].imageResourceID = document.nodes[n].imageResourceID.flatMap { ids[$0] }
            if document.nodes[n].source?.space == .notes, document.nodes[n].source?.documentID == originalID { document.nodes[n].source?.documentID = document.id }
        }
        try document.validate()
        return document
    }

    private static func digest(_ url: URL) throws -> (String, Int64) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); var size: Int64 = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); size += Int64(chunk.count)
            guard size <= maximumResource else { throw NoteError.invalidOperation("单个手记资源超过 512 MB。") }
            hash.update(data: chunk)
        }
        return (hex(hash.finalize()), size)
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

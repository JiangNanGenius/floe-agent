// SPDX-License-Identifier: MPL-2.0
//
// iOS-compatible `.floenote` reader/writer.
//
// The writer is the REAL shared FloeNotes `NotesArchive` (same source family
// as the fixed iOS donor commit a59b4d4005f616c611df67fab7620e9853c525b9),
// so manifests and resource layout are the established format rather than a
// new C07 invention:
//
//   manifest.json   { version: 2, document, linkedDocuments?, resources }
//   resources/<SHA-256>
//
// The reader validates that exact layout before any document identity is
// allocated. Import always creates new document/resource identities; never
// overwrites an existing note. The actual bundle creation remains NotesStore's
// atomic `createBundle` path, reached through C07RestoreSink.
import Foundation
import Crypto
import ZIPFoundation
import FloeNotes

public struct C07ParsedNoteResource: Sendable, Equatable {
    public var originalID: UUID
    public var sha256: String
    public var byteCount: Int64
    public var stagedURL: URL

    public init(originalID: UUID, sha256: String, byteCount: Int64, stagedURL: URL) {
        self.originalID = originalID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.stagedURL = stagedURL
    }
}

public struct C07NoteDocumentPlan: Sendable {
    public var original: NoteDocument
    public var newDocumentID: UUID

    public init(original: NoteDocument, newDocumentID: UUID) {
        self.original = original
        self.newDocumentID = newDocumentID
    }
}

public struct C07ParsedNoteArchive: Sendable {
    public var rootOriginalID: UUID
    public var metadataTitle: String
    /// Root document first, then linked mind maps in manifest order.
    public var documents: [C07NoteDocumentPlan]
    public var resources: [C07ParsedNoteResource]
    public var warnings: [String]

    public var documentIDMap: [UUID: UUID] {
        Dictionary(uniqueKeysWithValues: documents.map {
            ($0.original.id, $0.newDocumentID)
        })
    }

    public var newDocumentIDs: [UUID] { documents.map(\.newDocumentID) }
}

public enum C07NotesPackage {
    private struct PrivateManifest: Codable, Sendable {
        var version: Int
        var document: NoteDocument
        var linkedDocuments: [NoteDocument]?
        var resources: [PrivateResource]
    }

    private struct PrivateResource: Codable, Sendable {
        var id: UUID
        var hash: String
        var size: Int64
        var path: String { "resources/\(hash)" }
    }

    /// Writes the real shared-format archive. The destination must not exist.
    public static func export(document: NoteDocument,
                              store: NotesStore,
                              to destination: URL) async throws {
        do {
            try await NotesArchive.export(document: document, store: store, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NoteError {
            throw C07DataExchangeError.notesArchive(String(describing: error))
        } catch {
            throw C07DataExchangeError.notesArchive("export")
        }
    }

    /// Parses and fully verifies one archive into `stagingRoot`. The returned
    /// resource URLs stay valid until the caller removes that root.
    public static func parse(archiveURL: URL,
                             stagingRoot: URL,
                             expectedDocumentID: UUID?,
                             metadataTitle: String) throws -> C07ParsedNoteArchive {
        try C07FileSystem.ensureDirectory(stagingRoot)
        let stage = stagingRoot.appendingPathComponent(
            "note-\(UUID().uuidString)", isDirectory: true)
        var success = false
        defer { if !success { C07FileSystem.removeIfPresent(stage) } }
        try C07FileSystem.ensureDirectory(stage)
        let resourcesStage = stage.appendingPathComponent("resources", isDirectory: true)
        try C07FileSystem.ensureDirectory(resourcesStage)

        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .read) }
        catch { throw C07DataExchangeError.notesArchive("open") }

        var manifestData: Data?
        var resourceFiles: [String: (url: URL, size: Int64, sha256: String)] = [:]
        var seenPaths = Set<String>()
        var total: Int64 = 0
        var count = 0
        for entry in archive {
            if entry.type == .directory {
                var path = entry.path
                while path.hasSuffix("/") { path.removeLast() }
                do { _ = try C07Path.validateRelative(path) }
                catch { throw C07DataExchangeError.unsafePath(entry.path) }
                continue
            }
            guard entry.type == .file else {
                throw C07DataExchangeError.notesArchive("unsupportedEntryType")
            }
            count += 1
            guard count <= 20_001 else {
                throw C07DataExchangeError.notesArchive("tooManyEntries")
            }
            let path: String
            do { path = try C07Path.validateRelative(entry.path) }
            catch { throw C07DataExchangeError.unsafePath(entry.path) }
            guard seenPaths.insert(path).inserted else {
                throw C07DataExchangeError.duplicateEntry(path)
            }
            let size = try c07CheckedEntrySize(entry.uncompressedSize, path)
            guard size >= 0 else {
                throw C07DataExchangeError.notesArchive("entrySize")
            }
            if path == "manifest.json" {
                guard size <= C07DataExchangeLimits.maximumNestedNoteManifestBytes else {
                    throw C07DataExchangeError.entryTooLarge(path)
                }
                var data = Data()
                var readback: Int64 = 0
                do {
                    _ = try archive.extract(entry, skipCRC32: false) { chunk in
                        if Task.isCancelled { throw C07DataExchangeError.cancelled }
                        readback += Int64(chunk.count)
                        guard readback <= C07DataExchangeLimits.maximumNestedNoteManifestBytes else {
                            throw C07DataExchangeError.entryTooLarge(path)
                        }
                        data.append(chunk)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as C07DataExchangeError { throw error }
                catch { throw C07DataExchangeError.notesArchive("manifestExtract") }
                guard readback == size else {
                    throw C07DataExchangeError.sizeMismatch(path)
                }
                manifestData = data
                total += size
                guard total <= C07DataExchangeLimits.maximumNoteArchiveBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                continue
            }
            guard path.hasPrefix("resources/"),
                  path.split(separator: "/").count == 2 else {
                throw C07DataExchangeError.notesArchive("unexpectedEntry")
            }
            guard size <= C07DataExchangeLimits.maximumNoteResourceBytes else {
                throw C07DataExchangeError.entryTooLarge(path)
            }
            if size > C07DataExchangeLimits.compressionRatioProbeBytes,
               entry.compressedSize > 0 {
                guard Double(size) / Double(entry.compressedSize)
                        <= C07DataExchangeLimits.maximumCompressionRatio else {
                    throw C07DataExchangeError.notesArchive("compressionRatio")
                }
            }
            total += size
            guard total <= C07DataExchangeLimits.maximumNoteArchiveBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
            let fileName = String(path.dropFirst("resources/".count))
            guard fileName.count == 64, C07SHA256Hex.isSHA256(fileName) else {
                throw C07DataExchangeError.notesArchive("resourceName")
            }
            let stagedURL = resourcesStage.appendingPathComponent(fileName)
            guard FileManager.default.createFile(atPath: stagedURL.path, contents: nil) else {
                throw C07DataExchangeError.storageUnavailable("noteStageCreate")
            }
            let handle: FileHandle
            do { handle = try FileHandle(forWritingTo: stagedURL) }
            catch { throw C07DataExchangeError.storageUnavailable("noteStageOpen") }
            var hasher = SHA256Box()
            var readback: Int64 = 0
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    if Task.isCancelled { throw C07DataExchangeError.cancelled }
                    readback += Int64(chunk.count)
                    guard readback <= size else {
                        throw C07DataExchangeError.sizeMismatch(fileName)
                    }
                    hasher.update(chunk)
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch is CancellationError {
                try? handle.close()
                throw CancellationError()
            } catch let error as C07DataExchangeError {
                try? handle.close()
                throw error
            } catch {
                try? handle.close()
                throw C07DataExchangeError.notesArchive("resourceExtract")
            }
            guard readback == size else {
                throw C07DataExchangeError.sizeMismatch(fileName)
            }
            let digest = hasher.finalize()
            guard digest == fileName else {
                throw C07DataExchangeError.hashMismatch(fileName)
            }
            resourceFiles[fileName] = (stagedURL, size, digest)
        }
        guard let manifestData else {
            throw C07DataExchangeError.notesArchive("manifestMissing")
        }
        let manifest: PrivateManifest
        do {
            manifest = try JSONDecoder().decode(PrivateManifest.self, from: manifestData)
        } catch {
            throw C07DataExchangeError.notesArchive("manifestDecode")
        }
        guard (1...2).contains(manifest.version) else {
            throw C07DataExchangeError.notesArchive("version")
        }
        let linked = manifest.linkedDocuments ?? []
        let documents = [manifest.document] + linked
        let allResourceIDs = documents.reduce(into: Set<UUID>()) {
            $0.formUnion($1.resourceIDs)
        }
        guard documents.count <= 101,
              Set(documents.map(\.id)).count == documents.count,
              Set(linked.map(\.id)) == Set((manifest.document.linkedMindMaps ?? []).map(\.documentID)),
              linked.allSatisfy({ $0.kind == .mindMap && $0.deletedAt == nil }),
              manifest.version != 1 || (linked.isEmpty && (manifest.document.linkedMindMaps ?? []).isEmpty),
              manifest.resources.count <= 20_000,
              Set(manifest.resources.map(\.id)) == allResourceIDs,
              Set(manifest.resources.map(\.id)).count == manifest.resources.count,
              Set(manifest.resources.map(\.path)).count == manifest.resources.count,
              Set(manifest.resources.map(\.path)) == Set(resourceFiles.keys.map { "resources/\($0)" }) else {
            throw C07DataExchangeError.notesArchive("manifestIdentity")
        }
        if let expectedDocumentID, manifest.document.id != expectedDocumentID {
            throw C07DataExchangeError.notesArchive("documentIdentity")
        }
        guard !metadataTitle.isEmpty else {
            throw C07DataExchangeError.notesArchive("title")
        }
        for document in documents {
            do { try document.validate() }
            catch { throw C07DataExchangeError.notesArchive("documentValidation") }
        }
        var parsedResources: [C07ParsedNoteResource] = []
        for resource in manifest.resources {
            guard resource.hash.count == 64,
                  C07SHA256Hex.isSHA256(resource.hash),
                  resource.size >= 0,
                  resource.size <= C07DataExchangeLimits.maximumNoteResourceBytes,
                  let file = resourceFiles[resource.hash],
                  file.size == resource.size,
                  file.sha256 == resource.hash else {
                throw C07DataExchangeError.notesArchive("resourceDeclaration")
            }
            parsedResources.append(C07ParsedNoteResource(
                originalID: resource.id, sha256: resource.hash,
                byteCount: resource.size, stagedURL: file.url))
        }
        parsedResources.sort { $0.originalID.uuidString < $1.originalID.uuidString }
        let plans = documents.map {
            C07NoteDocumentPlan(original: $0, newDocumentID: UUID())
        }
        success = true
        return C07ParsedNoteArchive(
            rootOriginalID: manifest.document.id,
            metadataTitle: metadataTitle,
            documents: plans,
            resources: parsedResources,
            warnings: [])
    }
}

// MARK: - Identity remap (same contract as NotesArchive.importDocuments)

public enum C07NoteRemap {
    public static func remap(document original: NoteDocument,
                             newDocumentID: UUID,
                             newNotebookID: UUID?,
                             documentMap: [UUID: UUID],
                             resourceMap: [UUID: UUID]) throws -> NoteDocument {
        var document = original
        document.id = newDocumentID
        document.notebookID = newNotebookID
        document.deletedAt = nil

        func remapSource(_ source: NoteSourceReference?) -> NoteSourceReference? {
            guard var source else { return nil }
            if source.space == .notes, let id = documentMap[source.documentID] {
                source.documentID = id
                source.revision = 1
            }
            return source
        }
        func requireResource(_ id: UUID, _ label: String) throws -> UUID {
            guard let mapped = resourceMap[id] else {
                throw C07DataExchangeError.notesArchive("missingResource:\(label)")
            }
            return mapped
        }

        document.officeResourceID = try document.officeResourceID.map {
            try requireResource($0, "office")
        }
        document.officePreviewSourceID = try document.officePreviewSourceID.map {
            try requireResource($0, "officePreviewSource")
        }
        document.officePreviewResourceID = try document.officePreviewResourceID.map {
            try requireResource($0, "officePreview")
        }
        document.engineeringResourceID = try document.engineeringResourceID.map {
            try requireResource($0, "engineering")
        }
        document.coverResourceID = try document.coverResourceID.map {
            try requireResource($0, "cover")
        }
        if var links = document.linkedMindMaps {
            for index in links.indices {
                guard let mapped = documentMap[links[index].documentID] else {
                    throw C07DataExchangeError.notesArchive("linkedMapIdentity")
                }
                links[index].documentID = mapped
            }
            document.linkedMindMaps = links
        }
        for pageIndex in document.pages.indices {
            if let id = document.pages[pageIndex].backgroundResourceID {
                document.pages[pageIndex].backgroundResourceID =
                    try requireResource(id, "pageBackground")
            }
            if let id = document.pages[pageIndex].drawingResourceID {
                document.pages[pageIndex].drawingResourceID =
                    try requireResource(id, "pageDrawing")
            }
            for elementIndex in document.pages[pageIndex].elements.indices {
                if let id = document.pages[pageIndex].elements[elementIndex].resourceID {
                    document.pages[pageIndex].elements[elementIndex].resourceID =
                        try requireResource(id, "element")
                }
                document.pages[pageIndex].elements[elementIndex].source =
                    remapSource(document.pages[pageIndex].elements[elementIndex].source)
            }
        }
        for nodeIndex in document.nodes.indices {
            if let id = document.nodes[nodeIndex].imageResourceID {
                document.nodes[nodeIndex].imageResourceID =
                    try requireResource(id, "nodeImage")
            }
            document.nodes[nodeIndex].source = remapSource(document.nodes[nodeIndex].source)
            if var attachments = document.nodes[nodeIndex].attachments {
                for index in attachments.indices {
                    attachments[index].resourceID =
                        try requireResource(attachments[index].resourceID, "attachment")
                    attachments[index].source = remapSource(attachments[index].source)
                }
                document.nodes[nodeIndex].attachments = attachments
            }
        }
        do { try document.validate() }
        catch { throw C07DataExchangeError.notesArchive("remappedValidation") }
        return document
    }
}

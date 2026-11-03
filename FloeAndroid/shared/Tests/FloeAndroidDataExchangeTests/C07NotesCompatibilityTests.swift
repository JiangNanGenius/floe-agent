// SPDX-License-Identifier: MPL-2.0
//
// C07 cross-platform Notes compatibility tests. The fixture is produced by the
// REAL shared NotesArchive writer (same manifest/layout/checksums as the fixed
// iOS donor) and then read by the C07 parser and a real second NotesStore.
import XCTest
import Foundation
import ZIPFoundation
import Crypto
import FloeNotes
@testable import FloeAndroidDataExchange

final class C07NotesCompatibilityTests: XCTestCase {
    private final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("c07-notes-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func store(_ name: String) throws -> NotesStore {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return try NotesStore(root: url)
        }
        func write(_ path: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
    }

    func testRealIOSArchiveRoundTripUsesNewIdentities() async throws {
        let fixture = try Fixture()
        let sourceStore = try fixture.store("source")
        let bytes = Data("real-image-bytes".utf8)
        let source = try fixture.write("image.png", bytes)
        let resourceID = try await sourceStore.importResource(
            from: source, mediaType: "image/png")
        var rootDocument = NoteDocument(kind: .notebook, title: "Shared notes")
        rootDocument.pages[0].elements.append(
            NoteElement(kind: .image, resourceID: resourceID))
        let created = try await sourceStore.create(rootDocument)
        let archiveURL = fixture.root.appendingPathComponent("shared.floenote")
        try await C07NotesPackage.export(
            document: created, store: sourceStore, to: archiveURL)

        let parsed = try C07NotesPackage.parse(
            archiveURL: archiveURL,
            stagingRoot: fixture.root.appendingPathComponent("parsed"),
            expectedDocumentID: created.id,
            metadataTitle: created.title)
        XCTAssertEqual(parsed.documents.count, 1)
        XCTAssertEqual(parsed.resources.count, 1)
        XCTAssertNotEqual(parsed.documents[0].newDocumentID, created.id)

        let destination = try fixture.store("destination")
        var resourceMap: [UUID: UUID] = [:]
        for resource in parsed.resources {
            databaseCheck(resource.byteCount, bytes.count)
            resourceMap[resource.originalID] = try await destination.importResource(
                from: resource.stagedURL, mediaType: "application/octet-stream")
            XCTAssertTrue(fileBytes(at: resource.stagedURL) == bytes)
        }
        let documentMap = parsed.documentIDMap
        let remapped = try C07NoteRemap.remap(
            document: parsed.documents[0].original,
            newDocumentID: parsed.documents[0].newDocumentID,
            newNotebookID: nil,
            documentMap: documentMap,
            resourceMap: resourceMap)
        let createdCopy = try await destination.create(remapped)
        XCTAssertEqual(createdCopy.id, parsed.documents[0].newDocumentID)
        XCTAssertEqual(createdCopy.title, created.title)
        XCTAssertFalse(createdCopy.id == created.id)
        let pages = createdCopy.pages
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].elements.count, 1)
        XCTAssertEqual(pages[0].elements[0].kind, .image)
        XCTAssertNotNil(pages[0].elements[0].resourceID)
    }

    func testHandAuthoredDonorManifestLayoutIsAccepted() throws {
        // This fixture is assembled directly from the documented fixed-donor
        // layout rather than through the shared writer, so the reader is
        // tested against a donor-shaped manifest independently.
        let fixture = try Fixture()
        let resourceID = UUID()
        let resourceBytes = Data("donor-resource-bytes".utf8)
        let hash = SHA256.hash(data: resourceBytes)
            .map { String(format: "%02x", $0) }.joined()
        var document = NoteDocument(kind: .notebook, title: "Donor layout")
        document.pages[0].elements.append(
            NoteElement(kind: .image, resourceID: resourceID))
        let documentObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
                as? [String: Any])
        let manifest: [String: Any] = [
            "version": 2,
            "document": documentObject,
            "resources": [[
                "id": resourceID.uuidString,
                "hash": hash,
                "size": resourceBytes.count,
            ]],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])
        let archiveURL = fixture.root.appendingPathComponent("donor.floenote")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(
            with: "manifest.json", type: .file,
            uncompressedSize: Int64(manifestData.count),
            compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return manifestData.subdata(in: start..<min(start + size, manifestData.count))
            }
        try archive.addEntry(
            with: "resources/\(hash)", type: .file,
            uncompressedSize: Int64(resourceBytes.count),
            compressionMethod: .none) { position, size in
                let start = Int(position)
                return resourceBytes.subdata(in: start..<min(start + size, resourceBytes.count))
            }
        let parsed = try C07NotesPackage.parse(
            archiveURL: archiveURL,
            stagingRoot: fixture.root.appendingPathComponent("donor-parsed"),
            expectedDocumentID: document.id,
            metadataTitle: document.title)
        XCTAssertEqual(parsed.documents.count, 1)
        XCTAssertEqual(parsed.resources.count, 1)
        XCTAssertEqual(parsed.resources[0].sha256, hash)
        XCTAssertEqual(parsed.resources[0].byteCount, Int64(resourceBytes.count))
    }

    func testTamperedResourceHashIsRejected() async throws {
        let fixture = try Fixture()
        let store = try fixture.store("source")
        let source = try fixture.write("image.png", Data("hash-me".utf8))
        let resourceID = try await store.importResource(
            from: source, mediaType: "image/png")
        var document = NoteDocument(kind: .notebook, title: "Hash")
        document.pages[0].elements.append(
            NoteElement(kind: .image, resourceID: resourceID))
        let created = try await store.create(document)
        let original = fixture.root.appendingPathComponent("original.floenote")
        try await C07NotesPackage.export(document: created, store: store, to: original)

        let originalArchive = try Archive(url: original, accessMode: .read)
        guard let manifestEntry = originalArchive["manifest.json"] else {
            return XCTFail("fixture archive has no manifest")
        }
        var manifestData = Data()
        _ = try originalArchive.extract(manifestEntry) { manifestData.append($0) }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let resources = try XCTUnwrap(object["resources"] as? [[String: Any]])
        let hash = try XCTUnwrap(resources.first?["hash"] as? String)
        guard let resourceEntry = originalArchive["resources/\(hash)"] else {
            return XCTFail("fixture archive has no resource")
        }
        var resourceBytes = Data()
        _ = try originalArchive.extract(resourceEntry) { resourceBytes.append($0) }
        XCTAssertFalse(resourceBytes.isEmpty)
        resourceBytes[0] ^= 0xFF

        let tampered = fixture.root.appendingPathComponent("tampered.floenote")
        let archive = try Archive(url: tampered, accessMode: .create)
        try archive.addEntry(
            with: "manifest.json", type: .file,
            uncompressedSize: Int64(manifestData.count),
            compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return manifestData.subdata(in: start..<min(start + size, manifestData.count))
            }
        try archive.addEntry(
            with: "resources/\(hash)", type: .file,
            uncompressedSize: Int64(resourceBytes.count),
            compressionMethod: .none) { position, size in
                let start = Int(position)
                return resourceBytes.subdata(in: start..<min(start + size, resourceBytes.count))
            }
        do {
            _ = try C07NotesPackage.parse(
                archiveURL: tampered,
                stagingRoot: fixture.root.appendingPathComponent("tampered-stage"),
                expectedDocumentID: created.id,
                metadataTitle: created.title)
            XCTFail("tampered resource must be rejected")
        } catch let error as C07DataExchangeError {
            switch error {
            case .hashMismatch, .notesArchive, .sizeMismatch:
                break
            default:
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testFloecadStaysADirectoryPackageInBackup() async throws {
        let fixture = try Fixture()
        let projectID = UUID()
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        for path in ["plate.floecad/manifest.json",
                     "plate.floecad/document.json",
                     "plate.floecad/blobs/part.mesh"] {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let source = C07BackupSource(
            appSchemaVersion: 51,
            projects: [C07SourceProject(
                projectID: projectID, name: "CAD", origin: .retained,
                rootURL: project)],
            notebooks: [], notes: [])
        let destination = fixture.root.appendingPathComponent("cad.floebackup")
        let built = try await C07BackupBuilder.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("stage"))
        XCTAssertEqual(built.manifest.projects.first?.origin, .retained)
        let files = Set(built.manifest.projects.first?.files.map(\.relativePath) ?? [])
        XCTAssertTrue(files.contains("plate.floecad/manifest.json"))
        XCTAssertTrue(files.contains("plate.floecad/document.json"))
        XCTAssertTrue(files.contains("plate.floecad/blobs/part.mesh"))
        XCTAssertFalse(files.contains("plate.floecad"))
    }

    private func databaseCheck(_ lhs: Int64, _ rhs: Int) {
        XCTAssertEqual(lhs, Int64(rhs))
    }

    private func fileBytes(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

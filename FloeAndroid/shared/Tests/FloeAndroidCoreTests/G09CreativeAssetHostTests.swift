import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence

final class G09CreativeAssetHostTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?
    private var store: CreativeAssetStore?
    private var host: G09CreativeAssetHost?

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        store = nil
        host = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private func makeHost() async throws -> (RuntimeStorageRoot, G09CreativeAssetHost) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-asset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let assetStore = CreativeAssetStore(
            database: manager, reachabilityGuard: nil,
            deferPhysicalReclamation: true)
        store = assetStore
        let value = G09CreativeAssetHost(root: root, store: assetStore)
        host = value
        return (root, value)
    }

    private func stage(_ host: G09CreativeAssetHost, session: String,
                       bytes: Data, name: String = "pixel.png")
        throws -> (token: String, digest: String) {
        let token = "\(session).\(UUID().uuidString)"
        let url = try XCTUnwrap(host.incomingURL(token: token))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return (token, FloeDigest.sha256Hex(bytes))
    }

    func testContentAddressedIngestDedupeAndReferenceJournal() async throws {
        let (_, host) = try await makeHost()
        let session = "session-1"
        let bytes = Data("same-pixels".utf8)
        let first = try stage(host, session: session, bytes: bytes)
        let one = try await host.ingest(
            opID: "ingest-1", token: first.token, sessionToken: session,
            fileName: "pixel.png", mimeType: "image/png",
            byteCount: Int64(bytes.count), sha256: first.digest)
        XCTAssertFalse(one.deduplicated)
        XCTAssertEqual(one.asset.contentHash, first.digest)
        let materials = URL(fileURLWithPath: host.materialsDirectoryPath, isDirectory: true)
        let firstPath = materials.appendingPathComponent(
            try XCTUnwrap(one.asset.localRelativePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath.path))

        let second = try stage(host, session: session, bytes: bytes,
                               name: "copy.png")
        let two = try await host.ingest(
            opID: "ingest-2", token: second.token, sessionToken: session,
            fileName: "copy.png", mimeType: "image/png",
            byteCount: Int64(bytes.count), sha256: second.digest)
        XCTAssertTrue(two.deduplicated)
        XCTAssertEqual(two.asset.id, one.asset.id)

        let historical = CanvasAssetReference(
            id: one.asset.id, contentHash: one.asset.contentHash,
            localRelativePath: "Materials/\(try XCTUnwrap(one.asset.localRelativePath))",
            mimeType: "image/png", byteCount: one.asset.byteCount)
        try await host.validateAssetReference(historical)
        XCTAssertNotNil(host.materialsURL(
            relativePath: try XCTUnwrap(historical.localRelativePath)))

        let retry = try await host.ingest(
            opID: "ingest-2", token: second.token, sessionToken: session,
            fileName: "copy.png", mimeType: "image/png",
            byteCount: Int64(bytes.count), sha256: second.digest)
        XCTAssertTrue(retry.idempotent)
        XCTAssertEqual(retry.asset.id, one.asset.id)

        // Apply +1 then -1 through the journal and replay it. The SQLite
        // receipt prevents a double-apply.
        let root = URL(fileURLWithPath: host.materialsDirectoryPath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let storageRoot = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: root.path))
        let journal = G09CreativeRecovery(root: storageRoot)
        let canvasID = UUID()
        let ops = [
            G09AssetReferenceOperationDTO(opID: "ref-add", assetID: one.asset.id, delta: 1),
            G09AssetReferenceOperationDTO(opID: "ref-remove", assetID: one.asset.id, delta: -1),
        ]
        let applied = try await journal.apply(
            canvasID: canvasID, operations: ops, host: host)
        XCTAssertEqual(applied.applied, 2)
        let replayed = try await journal.apply(
            canvasID: canvasID, operations: ops, host: host)
        XCTAssertEqual(replayed.applied, 2)
        let assetStore = try XCTUnwrap(store)
        let record = try await assetStore.asset(id: one.asset.id)
        XCTAssertEqual(record?.referenceCount, 0)
    }

    func testDigestMismatchAndPathEscapeAreRefusedWithoutWritingMaterials() async throws {
        let (_, host) = try await makeHost()
        let session = "session-1"
        let bytes = Data("pixels".utf8)
        let staged = try stage(host, session: session, bytes: bytes)
        try? FileManager.default.createDirectory(
            atPath: host.materialsDirectoryPath, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(
            atPath: host.materialsDirectoryPath).count
        do {
            _ = try await host.ingest(
                opID: "mismatch", token: staged.token, sessionToken: session,
                fileName: "x.png", mimeType: "image/png",
                byteCount: Int64(bytes.count), sha256: String(repeating: "0", count: 64))
            XCTFail("digest mismatch must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "assetDigestMismatch")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: host.materialsDirectoryPath).count, before)

        XCTAssertNil(host.incomingURL(token: "../escape"))
        do {
            _ = try await host.ingest(
                opID: "escape", token: "../escape", sessionToken: session,
                fileName: "x.png", mimeType: "image/png",
                byteCount: Int64(bytes.count), sha256: staged.digest)
            XCTFail("path escape must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "assetStagingInvalid")
        }
    }
}

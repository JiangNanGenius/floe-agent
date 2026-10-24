// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkspace
@testable import FloeAndroidCore

private actor G04ProjectionTestAccess: G04WorkspaceAccessPort {
    let owner: G04WorkspaceOwner
    let service: WorkspaceFileService
    private var acquired = 0
    private var released = 0
    init(owner: G04WorkspaceOwner, root: URL) {
        self.owner = owner; service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }
    func acquire(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent, relativePath: String?) async throws -> G04WorkspaceAccessLease {
        guard owner == self.owner else { throw G04DocumentError.ownerChanged }
        acquired += 1
        return G04WorkspaceAccessLease(service: service, cancellation: CancellationToken(), release: { await self.finish() })
    }
    private func finish() { released += 1 }
    func counts() -> (Int, Int) { (acquired, released) }
}

private struct G04ProjectionFixture {
    let root: URL
    let owner: G04WorkspaceOwner
    let access: G04ProjectionTestAccess
    let recovery: G04ProjectionRecovery
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = ProcessInfo.processInfo.environment["FLOE_G04_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? package.appendingPathComponent(".build/test-fixtures/g04-projections")
        root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        owner = G04WorkspaceOwner(epoch: 71, taskID: UUID(), workspaceID: UUID())
        access = G04ProjectionTestAccess(owner: owner, root: root)
        recovery = G04ProjectionRecovery(epoch: owner.epoch, access: access)
    }
    func request(_ op: String, _ fields: [String: SettingsDomainV1.JSONValue]) throws -> G04WorkspaceWireRequest {
        var payload = fields
        payload["op"] = .string(op); payload["workspaceID"] = .string(owner.workspaceID.uuidString)
        payload["nativeEpoch"] = .string(String(owner.epoch))
        return try G04WorkspaceWireRequest(payload: .object(payload), command: "workspace.write")
    }
    func begin(_ bytes: Data, id: UUID) async throws -> DesignJSONValue {
        try await recovery.execute(request("beginProjectionRecovery", ["recoveryID": .string(id.uuidString),
            "sourcePath": .string("original.py"), "byteCount": .integer(Int64(bytes.count)),
            "sha256": .string(FloeDigest.sha256Hex(bytes))]), owner: owner)
    }
    func upload(_ bytes: Data, handle: String) async throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + G04WorkspaceDocumentSession.maximumChunkBytes)
            _ = try await recovery.execute(request("appendProjectionRecovery", ["handle": .string(handle),
                "offset": .integer(Int64(offset)), "bytes": .string(bytes.subdata(in: offset..<end).base64EncodedString())]), owner: owner)
            offset = end
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func g04ProjectionString(_ value: DesignJSONValue, _ key: String) throws -> String {
    guard case .object(let fields) = value, case .string(let text)? = fields[key] else {
        throw G04DocumentError.invalidTransfer
    }
    return text
}

@Suite("Unconfirmed projection recovery")
struct G04ProjectionRecoveryTests {
    @Test func fullUnicodeBytesCommitReadbackAndLostResponseRetryPreserveTheOriginal() async throws {
        let f = try G04ProjectionFixture(); defer { f.cleanup() }
        let original = f.root.appendingPathComponent("original.py")
        try Data("original".utf8).write(to: original)
        let bytes = Data(String(repeating: "中🙂\n", count: 150_000).utf8)
        let id = UUID()
        let handle = try g04ProjectionString(await f.begin(bytes, id: id), "handle")
        try await f.upload(bytes, handle: handle)
        let result = try await f.recovery.execute(f.request("commitProjectionRecovery", ["handle": .string(handle)]), owner: f.owner)
        let path = try g04ProjectionString(result, "path")
        #expect(try Data(contentsOf: f.root.appendingPathComponent(path)) == bytes)
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        let retried = try await f.begin(bytes, id: id)
        #expect(try g04ProjectionString(retried, "path") == path)
        #expect(try g04ProjectionString(retried, "sha256") == FloeDigest.sha256Hex(bytes))
        let counts = await f.access.counts(); #expect(counts.0 == counts.1)
    }

    @Test func recoveryDoesNotRequireAnAvailableEditorDocumentSlot() async throws {
        let f = try G04ProjectionFixture(); defer { f.cleanup() }
        let session = G04WorkspaceDocumentSession(owner: f.owner, access: f.access)
        for index in 0..<32 {
            let path = "doc-\(index).txt"
            try Data("base".utf8).write(to: f.root.appendingPathComponent(path))
            let opened = try await session.open(path)
            _ = try await session.edit(opened.documentID, revision: opened.revision,
                range: NSRange(location: 4, length: 0), replacement: " draft")
        }
        let bytes = Data("full unconfirmed text".utf8)
        let handle = try g04ProjectionString(await f.begin(bytes, id: UUID()), "handle")
        try await f.upload(bytes, handle: handle)
        _ = try await f.recovery.execute(f.request("commitProjectionRecovery", ["handle": .string(handle)]), owner: f.owner)
        let tabs = try await session.tabs()
        #expect(tabs.count == 32 && tabs.allSatisfy(\.dirty))
    }

    @Test func mismatchingUploadCannotCreateAFileOrClearTheOriginal() async throws {
        let f = try G04ProjectionFixture(); defer { f.cleanup() }
        let id = UUID(); let intended = Data("good".utf8)
        let handle = try g04ProjectionString(await f.begin(intended, id: id), "handle")
        try await f.upload(Data("bad!".utf8), handle: handle)
        do {
            _ = try await f.recovery.execute(f.request("commitProjectionRecovery", ["handle": .string(handle)]), owner: f.owner)
            Issue.record("Digest mismatch was accepted")
        } catch let error as G04DocumentError { #expect(error == .invalidTransfer) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Recovered Drafts/\(id.uuidString).py").path))
        _ = try await f.recovery.execute(f.request("cancelProjectionRecovery", ["handle": .string(handle)]), owner: f.owner)
        let counts = await f.access.counts(); #expect(counts.0 == counts.1)
    }

    @Test func existingDifferentBytesAreNeverOverwrittenAndForeignOwnerCannotAppend() async throws {
        let f = try G04ProjectionFixture(); defer { f.cleanup() }
        let id = UUID(); let bytes = Data("ours".utf8)
        let handle = try g04ProjectionString(await f.begin(bytes, id: id), "handle")
        let foreign = G04WorkspaceOwner(epoch: f.owner.epoch, taskID: UUID(), workspaceID: f.owner.workspaceID)
        do {
            _ = try await f.recovery.execute(f.request("appendProjectionRecovery", ["handle": .string(handle),
                "offset": .integer(0), "bytes": .string(bytes.base64EncodedString())]), owner: foreign)
            Issue.record("Foreign owner appended")
        } catch let error as G04DocumentError { #expect(error == .ownerChanged) }
        let path = f.root.appendingPathComponent("Recovered Drafts/\(id.uuidString).py")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("them".utf8).write(to: path)
        try await f.upload(bytes, handle: handle)
        do {
            _ = try await f.recovery.execute(f.request("commitProjectionRecovery", ["handle": .string(handle)]), owner: f.owner)
            Issue.record("Collision overwrote another file")
        } catch let error as G04DocumentError { #expect(error == .staleRevision) }
        #expect(try Data(contentsOf: path) == Data("them".utf8))
    }
}

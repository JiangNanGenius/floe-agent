// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Project import host contract and bounded asset loading")
struct ImportFlowTests {
    struct RecordingHost: GameProjectImportHost {
        var onRequest: @Sendable (GameProjectImportRequest) -> Void = { _ in }
        func importProjectContents(_ request: GameProjectImportRequest) async throws -> [GameEditDiagnostic] {
            onRequest(request)
            return []
        }
    }

    @Test("Session exposes the existing project identity to the import host")
    @MainActor
    func hostReceivesExistingProject() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "host")
        let projectRoot = try TestSupport.makeTemporaryDirectory("host-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .rpgMakerMV))
        #expect(session.projectImportHost == nil)

        let box = MutexBox<GameProjectImportRequest?>()
        session.projectImportHost = RecordingHost { request in box.value = request }
        let host = try #require(session.projectImportHost)
        let request = GameProjectImportRequest(projectID: session.projectID, owner: TestSupport.owner,
                                               baseRevision: session.expectedRevision, sources: [])
        let diagnostics = try await host.importProjectContents(request)
        #expect(diagnostics.isEmpty)
        let recorded = try #require(box.value)
        #expect(recorded.projectID == stored.projectID)
        #expect(recorded.owner == TestSupport.owner)
        #expect(recorded.baseRevision == stored.revision)
    }

    @Test("Asset byte loader reads files and enforces the byte bound")
    @MainActor
    func boundedLoader() async throws {
        let file = try TestSupport.makeTemporaryDirectory("loader").appendingPathComponent("blob.bin")
        try Data(repeating: 7, count: 1024).write(to: file)
        let data = try await GameAssetByteLoader.load(file)
        #expect(data.count == 1024)
        do {
            _ = try await GameAssetByteLoader.load(file, limit: 512)
            Issue.record("Over-limit load must fail")
        } catch {}
        do {
            _ = try await GameAssetByteLoader.load(file.appendingPathComponent("missing.bin"))
            Issue.record("Missing file must fail, not skip silently")
        } catch {}
    }

    @Test("Session asset import stays file-level; archives are the host's job")
    @MainActor
    func archiveIsNotUnpackedByComponent() async throws {
        // A ZIP picked through "Add Asset" lands as bytes (honest behavior);
        // unpacking is delegated to GameProjectImportHost by the UI layer.
        let sessionHolder = try await makeSession("zipasset")
        let session = sessionHolder
        let zipBytes = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02])
        let paths = try await session.importAssets([(name: "game.zip", bytes: zipBytes)])
        #expect(paths.first?.value == "game.zip")
        let bytes = try await session.documentBytes(at: paths[0])
        #expect(bytes == zipBytes) // preserved verbatim, no fake unpacking
    }

    private func makeSession(_ name: String) async throws -> GameEditingSession {
        let (_, repository) = try TestSupport.makeRepository(name: name)
        let projectRoot = try TestSupport.makeTemporaryDirectory(name + "-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        return try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
    }
}

final class MutexBox<Value: Sendable>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()
    init(_ value: Value) { storage = value }
    convenience init() where Value: ExpressibleByNilLiteral { self.init(nil) }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

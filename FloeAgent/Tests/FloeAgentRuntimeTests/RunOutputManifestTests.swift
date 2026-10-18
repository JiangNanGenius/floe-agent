import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

@Suite("FloeAgentRuntime.RunOutputManifest")
struct RunOutputManifestTests {
    private func fixture() async throws -> (SQLiteRunStore, UUID, UUID) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationID = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(.init(
            id: conversationID, title: "Synthetic output qualification",
            createdAt: Date(), updatedAt: Date()))
        let store = SQLiteRunStore(database: database)
        let first = UUID(), later = UUID()
        for runID in [first, later] {
            try await store.saveRun(.init(id: runID, conversationID: conversationID,
                                         state: "completed", goal: "Synthetic output",
                                         startedAt: Date(), endedAt: Date()))
        }
        return (store, first, later)
    }

    private func reference(runID: UUID, id: UUID = UUID()) -> ToolArtifactReference {
        .init(id: id, relativePath: "RunOutputs/\(runID.uuidString)/\(id.uuidString)/报告.txt",
              mimeType: "text/plain", byteCount: 12, sha256: String(repeating: "a", count: 64))
    }

    private func append(_ references: [ToolArtifactReference], to store: SQLiteRunStore,
                        runID: UUID, status: String = "ok") async throws {
        let encoded = String(decoding: try JSONEncoder().encode(references), as: UTF8.self)
        let payload = String(decoding: try JSONEncoder().encode([
            "status": status, "outputFilesJSON": encoded
        ]), as: UTF8.self)
        _ = try await store.appendEvent(runID: runID, kind: .toolResult, payloadJSON: payload)
    }

    @Test("Paged events return this run's declared files, not later-run files or evidence")
    func exactRunAcrossPages() async throws {
        let (store, runID, later) = try await fixture()
        let own = reference(runID: runID), other = reference(runID: later)
        for _ in 0..<205 {
            _ = try await store.appendEvent(runID: runID, kind: .status, payloadJSON: #"{"state":"streamingModel"}"#)
        }
        _ = try await store.appendEvent(runID: runID, kind: .toolResult,
                                        payloadJSON: #"{"status":"ok","summary":"created=unregistered.pdf","artifactRefsJSON":"[]"}"#)
        try await append([own], to: store, runID: runID)
        try await append([own], to: store, runID: runID)
        try await append([other], to: store, runID: later)
        #expect(try await RunOutputManifest.read(runID: runID, store: store) == [own])
        #expect(try await RunOutputManifest.read(runID: later, store: store) == [other])
    }

    @Test("Foreign-run references and conflicting repeated output identities fail closed")
    func mismatchedOwnershipAndCollision() async throws {
        let (store, runID, later) = try await fixture()
        try await append([reference(runID: later)], to: store, runID: runID)
        await #expect(throws: FloeError.self) { try await RunOutputManifest.read(runID: runID, store: store) }
        let own = reference(runID: later)
        var changed = own
        changed.byteCount += 1
        try await append([own], to: store, runID: later)
        try await append([changed], to: store, runID: later)
        await #expect(throws: FloeError.self) { try await RunOutputManifest.read(runID: later, store: store) }
    }

    @Test("Partial tool output is returned only when explicitly requested")
    func partialOutputIsExplicit() async throws {
        let (store, runID, _) = try await fixture()
        let own = reference(runID: runID)
        try await append([own], to: store, runID: runID, status: "cancelled")
        #expect(try await RunOutputManifest.read(runID: runID, store: store).isEmpty)
        #expect(try await RunOutputManifest.read(runID: runID, store: store, includePartial: true) == [own])
    }

    @Test("Only canonical snapshot paths and bounded metadata are accepted")
    func invalidMetadataRejected() throws {
        let runID = UUID()
        let own = reference(runID: runID)
        for path in ["Attachments/report.txt", "/" + own.relativePath,
                     own.relativePath.replacingOccurrences(of: "报告.txt", with: "../secret"),
                     own.relativePath.replacingOccurrences(of: "报告.txt", with: ".."),
                     "RunOutputs/\(runID.uuidString)/\(UUID().uuidString)/report.txt"] {
            var invalid = own
            invalid.relativePath = path
            #expect(throws: FloeError.self) { try RunOutputManifest.validate(invalid, runID: runID) }
        }
        var invalid = own
        invalid.byteCount = 256 * 1_024 * 1_024 + 1
        #expect(throws: FloeError.self) { try RunOutputManifest.validate(invalid, runID: runID) }
        invalid = own
        invalid.sha256 = "invalid"
        #expect(throws: FloeError.self) { try RunOutputManifest.validate(invalid, runID: runID) }
    }
}

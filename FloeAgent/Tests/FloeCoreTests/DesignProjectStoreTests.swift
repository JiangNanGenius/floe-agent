import Foundation
import Testing
@testable import FloeCore

@Suite("Design project store")
struct DesignProjectStoreTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func saveLoadRoundTrip() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesignProjectStore(rootURL: root)

        var project = DesignWorkflowEngine.createProject(
            canvasID: "canvas-1", contentType: .presentation,
            brief: DesignBrief(goal: "Q4 deck"), spec: DesignSpec(palette: ["#000000"])
        )
        let artifact = DesignArtifact(
            contentType: .presentation,
            canvasNodeID: "node-7",
            identity: DesignArtifactIdentity(name: "Deck", positionX: 0, positionY: 0, width: 100, height: 80)
        )
        DesignWorkflowEngine.addArtifact(artifact, to: &project)
        _ = try DesignWorkflowEngine.registerRevision(
            in: &project, artifactID: artifact.id, contentSHA256: "rev-1", origin: .generate
        )
        let url = try await store.save(project)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try await store.load(id: project.id)
        #expect(loaded.brief?.goal == "Q4 deck")
        #expect(loaded.artifacts.first?.canvasNodeID == "node-7")
        #expect(loaded.artifacts.first?.currentRevisionID != nil)
        #expect(loaded.spec?.palette == ["#000000"])
    }

    @Test func corruptFilesAreReportedNotDestroyed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesignProjectStore(rootURL: root)

        let valid = DesignWorkflowEngine.createProject(canvasID: nil, contentType: .image)
        _ = try await store.save(valid)
        // Write a non-JSON file where a project would be.
        let corruptURL = await store.projectURL(id: "broken")
        try Data("not json at all".utf8).write(to: corruptURL)

        let (projects, corrupt) = await store.loadAll()
        #expect(projects.count == 1)
        #expect(corrupt == ["broken"])
        // Quarantine moves it aside; the file is preserved.
        let moved = try await store.quarantine(id: "broken")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
        let data = try Data(contentsOf: moved)
        #expect(String(decoding: data, as: UTF8.self) == "not json at all")
    }

    @Test func newerSchemaIsRejectedWithoutOverwriting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesignProjectStore(rootURL: root)
        let url = await store.projectURL(id: "future")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = """
        {"schemaVersion": 99, "project": {"schemaVersion": 99, "id": "future", "contentType": "image",
        "artifacts": [], "feedback": [], "candidates": [], "createdAt": "2026-01-01T00:00:00Z",
        "updatedAt": "2026-01-01T00:00:00Z"}}
        """
        try Data(future.utf8).write(to: url)
        do {
            _ = try await store.load(id: "future")
            Issue.record("expected newerSchema")
        } catch let error as DesignStoreError {
            guard case .newerSchema(let found, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(found == 99)
        }
        // Original bytes are still there: nothing was overwritten.
        let data = try Data(contentsOf: url)
        #expect(String(decoding: data, as: UTF8.self) == future)
    }
}

@Suite("Design adapter capabilities")
struct DesignCapabilityTests {
    @Test func everyUnavailableOperationCarriesAReason() {
        let capability = DesignAdapterCapability(
            contentType: .video,
            available: [.importSource]
        )
        #expect(capability.supports(.importSource))
        #expect(!capability.supports(.verifiedExport))
        #expect(capability.reason(for: .importSource) == nil)
        for operation in DesignOperation.allCases where operation != .importSource {
            #expect(capability.reason(for: operation)?.isEmpty == false)
        }
    }

    @Test func disconnectedRegistryIsHonest() {
        let registry = DesignCapabilityRegistry.disconnected()
        for type in DesignContentType.allCases {
            let capability = registry.capability(for: type)
            #expect(capability.available.isEmpty)
            for operation in DesignOperation.allCases {
                #expect(registry.reason(operation, for: type)?.isEmpty == false)
            }
        }
        #expect(!registry.supports(.preview, for: .webpage))
    }

    @Test func onlyConnectedOperationsAreAdvertised() {
        let registry = DesignCapabilityRegistry(capabilities: [
            .webpage: DesignAdapterCapability(
                contentType: .webpage,
                available: [.importSource, .preview, .sourceExport],
                unavailableReasons: [.generate: "No webpage generator is connected"]
            )
        ])
        #expect(registry.supports(.preview, for: .webpage))
        #expect(registry.supports(.sourceExport, for: .webpage))
        #expect(!registry.supports(.generate, for: .webpage))
        #expect(registry.reason(.generate, for: .webpage) == "No webpage generator is connected")
        // Unlisted types stay disconnected.
        #expect(!registry.supports(.preview, for: .cad))
    }
}

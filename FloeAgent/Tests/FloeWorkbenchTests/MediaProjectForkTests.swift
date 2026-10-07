// FloeWorkbenchTests — persisted child-project forks (Build265 Canvas).
import Foundation
import Testing
import FloeCore
@testable import FloeWorkbench

@Suite("Media project forks")
struct MediaProjectForkTests {
    private func makeStore() -> MediaProjectStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-fork-tests-\(UUID().uuidString)", isDirectory: true)
        return MediaProjectStore(directory: directory)
    }

    private func project(name: String = "Edit") -> MediaProject {
        MediaProject(kind: .image, name: name, revision: 3,
                     assets: [MediaAssetReference(id: UUID(), kind: .image,
                                                  relativePath: "Materials/a.png",
                                                  originalName: "a.png", byteCount: 10,
                                                  contentHash: "hash-a")],
                     imageLayers: [ImageLayer(kind: .image, name: "Layer 1")],
                     ownerKind: "canvas", ownerID: UUID())
    }

    @Test("fork persists a new project with parent linkage and fresh history")
    func forkPersists() async throws {
        let store = makeStore()
        let parent = project()
        try await store.save(parent, expectedRevision: nil)
        let fork = try await store.forkProject(id: parent.id, nameSuffix: "variant")
        #expect(fork.id != parent.id)
        #expect(fork.parentProjectID == parent.id)
        #expect(fork.assets == parent.assets)
        #expect(fork.imageLayers == parent.imageLayers)
        #expect(fork.undoHistory.isEmpty && fork.redoHistory.isEmpty)
        let reloaded = try await store.loadProject(id: fork.id)
        #expect(reloaded?.parentProjectID == parent.id)
    }

    @Test("editing the fork never mutates the parent project")
    func forkIsolation() async throws {
        let store = makeStore()
        let parent = project()
        try await store.save(parent, expectedRevision: nil)
        var fork = try await store.forkProject(id: parent.id)
        fork.revision += 5
        fork.name = "Variant edited"
        fork.imageLayers = []
        try await store.save(fork, expectedRevision: fork.revision - 5)
        let reloadedParent = try await store.loadProject(id: parent.id)
        #expect(reloadedParent?.revision == parent.revision)
        #expect(reloadedParent?.name == parent.name)
        #expect(reloadedParent?.imageLayers.count == 1)
        let reloadedFork = try await store.loadProject(id: fork.id)
        #expect(reloadedFork?.revision == fork.revision)
        #expect(reloadedFork?.parentProjectID == parent.id)
    }

    @Test("forking an unknown project is a structured notFound")
    func forkMissing() async {
        let store = makeStore()
        await #expect(throws: FloeError.self) {
            _ = try await store.forkProject(id: UUID())
        }
    }
}

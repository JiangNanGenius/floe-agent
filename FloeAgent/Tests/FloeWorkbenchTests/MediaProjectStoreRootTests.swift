// FloeWorkbenchTests — the service-owned media store root identity.
//
// The app feed for the typed mutable-target contract's `mediaProject` store
// key must be the ACTUAL `MediaProjectStore` directory (the directory the
// store writes `media-project-<uuid>.json` records into), including a
// custom/injected root. These tests prove the accessor is the producer's own
// identity and that the canonical contract resolves to exactly the file the
// store writes — no second default-path calculator, no drift.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeWorkbench

@Suite("FloeWorkbench.MediaProjectStore root identity")
struct MediaProjectStoreRootTests {

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-store-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A custom store root is the producer identity the typed contract resolves")
    func customStoreRootMatchesTheProducerRecordPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root)
        let id = UUID()

        // The accessor reports the canonical actual directory…
        #expect(store.storeRootPath == root.standardizedFileURL.resolvingSymlinksInPath().path)
        // …and it is the same path the store itself derives its record URL
        // from (the real producer, not a parallel calculator).
        let producerPath = store.projectURL(id: id)
            .standardizedFileURL.resolvingSymlinksInPath().path
        #expect(producerPath.hasPrefix(store.storeRootPath + "/"))
        #expect(producerPath == store.storeRootPath
            + "/" + MediaProjectStore.projectFileName(id: id))

        // The typed contract, fed with the accessor value, pins EXACTLY the
        // producer's record for an apply/propose call.
        let resolved = try #require(TypedMutationContract.resolveMutableTargets(
            for: "media.project",
            arguments: ["action": "apply", "project_id": id.uuidString],
            workspaceRootURL: nil,
            serviceStorePaths: [TypedMutationContract.mediaProjectStoreKey: store.storeRootPath]
        ))
        #expect(resolved.count == 1)
        #expect(resolved.first?.path == producerPath)
        #expect(resolved.first?.role == .sourceWrite)

        let draft = try #require(TypedMutationContract.resolveMutableTargets(
            for: "media.project",
            arguments: ["action": "propose", "project_id": id.uuidString],
            workspaceRootURL: nil,
            serviceStorePaths: [TypedMutationContract.mediaProjectStoreKey: store.storeRootPath]
        ))
        #expect(draft.first?.path == producerPath)
        #expect(draft.first?.role == .draftTarget)
    }

    @Test("A missing store root or an invalid project id fails closed (unresolved)")
    func missingIdentityFailsClosed() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root)

        // No store root at all.
        #expect(TypedMutationContract.resolveMutableTargets(
            for: "media.project",
            arguments: ["action": "apply", "project_id": UUID().uuidString],
            workspaceRootURL: nil,
            serviceStorePaths: [:]
        ) == nil)
        // Invalid / missing project id.
        #expect(TypedMutationContract.resolveMutableTargets(
            for: "media.project",
            arguments: ["action": "apply", "project_id": "not-a-uuid"],
            workspaceRootURL: nil,
            serviceStorePaths: [TypedMutationContract.mediaProjectStoreKey: store.storeRootPath]
        ) == nil)
        #expect(TypedMutationContract.resolveMutableTargets(
            for: "media.project",
            arguments: ["action": "propose"],
            workspaceRootURL: nil,
            serviceStorePaths: [TypedMutationContract.mediaProjectStoreKey: store.storeRootPath]
        ) == nil)
    }
}

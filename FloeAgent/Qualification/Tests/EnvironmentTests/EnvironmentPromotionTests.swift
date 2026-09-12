import Foundation
import Testing
import FloeEnvironments

@Suite("Environment promotion")
struct EnvironmentPromotionTests {
    @Test func promotedFilesAndPackageDatabaseSurviveSourceRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let source = try await registry.ensureSessionContainer(conversationID: "chat", workspaceID: "project", workspaceRootPath: "/project")
        let sourceURL = roots.layerURL(id: source.id, kind: .session)
        var manifest = try #require(try LayerManifest.loadChecked(from: sourceURL))
        manifest.packages = [InstalledPackage(name: "sample", version: "1", layer: .session, files: ["usr/lib/sample.txt"])]
        try Data("promoted content".utf8).write(to: sourceURL.appendingPathComponent("usr/lib/sample.txt"))
        try manifest.write(to: sourceURL)
        let engine = ContainerPromote(roots: roots, registry: registry, cas: ContainerCAS(roots: roots))
        #expect(try await engine.promote(packageNames: ["sample"], from: source.id, to: .project) == ["sample"])
        #expect(try await engine.promote(packageNames: ["sample"], from: source.id, to: .project) == ["sample"])
        let target = roots.layerURL(id: try #require(source.parentID), kind: .project)
        #expect(try LayerManifest.loadChecked(from: sourceURL)?.packages.count == 1)
        try FileManager.default.removeItem(at: sourceURL)
        #expect(try Data(contentsOf: target.appendingPathComponent("usr/lib/sample.txt")) == Data("promoted content".utf8))
        #expect(LayerPackageDatabase.readStatus(at: target).first?.name == "sample")
        #expect(LayerPackageDatabase.readFileList(at: target, package: "sample") == ["usr/lib/sample.txt"])
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(EnvironmentFileTransaction.directoryName).path))
    }

    @Test func missingFileAndPathEscapeNeverMutateEitherLayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "one")
        let source = try await registry.ensureProjectContainer(workspaceID: "project", workspaceRootPath: "/project")
        let sourceURL = roots.layerURL(id: source.id, kind: .project)
        let targetBefore = try Data(contentsOf: roots.sharedURL.appendingPathComponent(LayerManifest.fileName))
        let engine = ContainerPromote(roots: roots, registry: registry, cas: ContainerCAS(roots: roots))
        for path in ["usr/lib/missing", "../escape"] {
            var manifest = try #require(try LayerManifest.loadChecked(from: sourceURL))
            manifest.packages = [InstalledPackage(name: "sample", version: "1", layer: .project, files: [path])]
            try manifest.write(to: sourceURL)
            let before = try Data(contentsOf: sourceURL.appendingPathComponent(LayerManifest.fileName))
            await #expect(throws: (any Error).self) { try await engine.promote(packageNames: ["sample"], from: source.id, to: .shared) }
            #expect(try Data(contentsOf: sourceURL.appendingPathComponent(LayerManifest.fileName)) == before)
            #expect(try Data(contentsOf: roots.sharedURL.appendingPathComponent(LayerManifest.fileName)) == targetBefore)
        }
    }
}

import Foundation
import Testing
import FloeEnvironments
import FloePackages

@Suite("Environment management API")
struct EnvironmentManagementTests {
    @Test func selectedEnvironmentHoldAndLifecycleNeverAffectOtherProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "test")
        try await registry.prepare()
        let a = try await registry.ensureProjectContainer(workspaceID: "a", workspaceRootPath: root.appendingPathComponent("a").path)
        let b = try await registry.ensureProjectContainer(workspaceID: "b", workspaceRootPath: root.appendingPathComponent("b").path)
        let lifecycle = ContainerLifecycle(roots: roots, registry: registry, cas: ContainerCAS(roots: roots),
            hooks: .init(stopSessions: { _ in }, cancelJobs: { _ in }, terminateWorkers: { _ in }))
        let engine = AptEngine(downloader: .init { _, _ in throw URLError(.notConnectedToInternet) })
        let service = EnvironmentManagementService(registry: registry, lifecycle: lifecycle, engine: engine)
        _ = try await service.managePackage(id: a.id, action: .hold("example"))
        #expect(try await service.packageReport(id: a.id).held == ["example"])
        #expect(try await service.packageReport(id: b.id).held.isEmpty)
        await #expect(throws: (any Error).self) { try await service.saveEnvironmentTemplate(id: a.id, name: "while-running") }
        try await service.stopEnvironment(id: a.id)
        try await service.saveEnvironmentTemplate(id: a.id, name: "saved-template")
        #expect(await registry.template(named: "saved-template") != nil)
        #expect(await registry.record(id: a.id)?.state == .stopped)
        #expect(await registry.record(id: b.id)?.state == .active)
        await #expect(throws: (any Error).self) { _ = try await service.managePackage(id: a.id, action: .unhold("example")) }
        await #expect(throws: (any Error).self) { _ = try await service.managePackage(id: "missing", action: .hold("example")) }
        try await service.resumeEnvironment(id: a.id)
        _ = try await service.managePackage(id: a.id, action: .unhold("example"))
        #expect(try await service.packageReport(id: a.id).held.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await service.managePackage(id: a.id, action: .refresh) }
        try await service.deleteEnvironment(id: a.id)
        #expect(await registry.record(id: a.id) == nil)
        #expect(await registry.record(id: b.id)?.state == .active)
    }

    @Test func inheritedPackagesAreSeparateAndReadOnlyInSelectedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "test")
        try await registry.prepare()
        let project = try await registry.ensureProjectContainer(workspaceID: "a", workspaceRootPath: root.appendingPathComponent("a").path)
        let session = try await registry.ensureSessionContainer(conversationID: "chat", workspaceID: "a", workspaceRootPath: root.appendingPathComponent("a").path)
        let layer = roots.layerURL(id: project.id, kind: .project)
        var manifest = try #require(try LayerManifest.loadChecked(from: layer))
        manifest.packages = [.init(name: "from-project", version: "1.0", layer: .project)]
        try manifest.write(to: layer)
        let lifecycle = ContainerLifecycle(roots: roots, registry: registry, cas: ContainerCAS(roots: roots))
        let service = EnvironmentManagementService(registry: registry, lifecycle: lifecycle,
            engine: AptEngine(downloader: .init { _, _ in throw URLError(.notConnectedToInternet) }))
        let report = try await service.packageReport(id: session.id)
        #expect(report.installed.isEmpty)
        #expect(report.inherited.map(\.name) == ["from-project"])
        await #expect(throws: (any Error).self) { _ = try await service.managePackage(id: session.id, action: .remove("from-project")) }
        #expect(try LayerManifest.loadChecked(from: layer)?.packages.map(\.name) == ["from-project"])
        try await registry.markRebuild(id: project.id, reason: "new base")
        await #expect(throws: (any Error).self) { _ = try await service.managePackage(id: session.id, action: .hold("example")) }
    }
}

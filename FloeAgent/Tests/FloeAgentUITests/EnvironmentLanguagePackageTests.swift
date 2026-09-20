#if canImport(UIKit)
import Foundation
import Testing
import FloeExecution
import FloeCore
import FloeEnvironments
import FloeTools
@testable import FloeApp

@Suite("Environment language dependency management", .serialized)
struct EnvironmentLanguagePackageTests {
    @Test func inventoryToleratesEmptyLegacyUninstallButRejectsLinkedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "inventory-test")
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        let project = try await registry.ensureProjectContainer(workspaceID: "inventory", workspaceRootPath: "/inventory")
        let preferences = EnvironmentLanguagePackageService(coordinator: coordinator, python: nil)
        #expect(try await preferences.nodeManagerSelection(environmentID: project.id).preference == .automatic)
        #expect(try await preferences.nodeManagerSelection(environmentID: project.id, set: .pnpm).resolved == .pnpm)
        let reopened = EnvironmentLanguagePackageService(coordinator: coordinator, python: nil)
        #expect(try await reopened.nodeManagerSelection(environmentID: project.id).preference == .pnpm)
        let site = roots.containerURL(id: project.id).appendingPathComponent("usr/lib/floe-python/site-packages")
        let remnant = site.appendingPathComponent("removed-1.0.dist-info")
        try FileManager.default.createDirectory(at: remnant, withIntermediateDirectories: true)
        let manager = EnvironmentLanguagePackageService(coordinator: coordinator, python: nil)
        #expect(try await manager.packages(environmentID: project.id, language: .python).isEmpty)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("linked-1.0.dist-info"), withDestinationURL: outside)
        do {
            _ = try await manager.packages(environmentID: project.id, language: .python)
            Issue.record("Inventory accepted a metadata directory outside its layer")
        } catch { /* The path guard rejects even an empty linked directory. */ }
    }
}
#endif

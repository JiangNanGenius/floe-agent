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

    @Test(.timeLimit(.minutes(5))) func installImportAndRemoveInSelectedEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "package-test")
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry)
        let first = try await registry.ensureProjectContainer(workspaceID: "first", workspaceRootPath: "/first")
        let second = try await registry.ensureProjectContainer(workspaceID: "second", workspaceRootPath: "/second")
        let python = try #require(CPythonServiceFactory.make())
        let manager = EnvironmentLanguagePackageService(coordinator: coordinator, python: ManagedPythonInstallService(python: python))
        for (language, specification, name) in [(EnvironmentLanguagePackageService.Language.python, "colorama==0.4.6", "colorama"), (.node, "is-number@7.0.0", "is-number")] {
            _ = try await manager.change(environmentID: second.id, language: language, specification: specification, remove: false)
            if language == .python {
                _ = try await manager.change(environmentID: second.id, language: .python, specification: "colorama==0.4.5", remove: false)
                _ = try await manager.change(environmentID: second.id, language: .python, specification: specification, remove: false)
            }
            let installed = try await manager.packages(environmentID: second.id, language: language)
            #expect(installed.contains { $0.name == name && $0.writable })
            #expect(try await manager.packages(environmentID: first.id, language: language).isEmpty)
            let lease = try await coordinator.acquireManagement(environmentID: second.id, cancellation: CancellationToken())
            let environment = try #require(lease.context.environment)
            if language == .python {
                let outcome = await python.run(.init(script: "import colorama; print(colorama.__version__)", timeout: 10,
                    pythonContext: ManagedPythonInstallService.executionContext(environment)), cancellation: nil)
                if case .ok(_, let stdout, _, _, _, _) = outcome { #expect(stdout.contains("0.4.6")) }
                else { Issue.record("Installed Python dependency could not be imported: \(outcome)") }
                let inspection = try await manager.pythonFromShell(environment: environment,
                    operation: ManagedPythonPackageSpecParser.parseShell(arguments: ["show", "colorama"]), cancellation: CancellationToken())
                #expect(inspection.contains("Version: 0.4.6"))
                _ = try await manager.pythonFromShell(environment: environment,
                    operation: ManagedPythonPackageSpecParser.parseShell(arguments: ["uninstall", "-y", "colorama"]), cancellation: CancellationToken())
                _ = try await manager.pythonFromShell(environment: environment,
                    operation: ManagedPythonPackageSpecParser.parseShell(arguments: ["install", "colorama==0.4.6"]), cancellation: CancellationToken())
            } else {
                let outcome = await IOSSystemNodeRuntime.shared.run(.init(entryScript: nil,
                    arguments: ["-e", "console.log(require('is-number')('42'))"], workingDirectory: root,
                    environment: environment.variables, timeout: 10), cancellation: nil)
                if case .exited(let code, let stdout, _, _, _) = outcome { #expect(code == 0 && stdout == "true\n") }
                else { Issue.record("Installed Node dependency could not be imported: \(outcome)") }
            }
            await lease.finish()
            _ = try await manager.change(environmentID: second.id, language: language, specification: name, remove: true)
            #expect(try await manager.packages(environmentID: second.id, language: language).contains { $0.name == name } == false)
        }
    }
}
#endif

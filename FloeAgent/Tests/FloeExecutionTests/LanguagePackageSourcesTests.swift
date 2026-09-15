import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

struct LanguagePackageSourcesTests {
    @Test func selectedNodeRegistryReachesBothManagersAndFailurePreservesGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try LanguagePackageSources(nodeRegistry: "https://packages.example.org/npm/").save(in: root)
        let runtime = RegistryRecordingRuntime()
        let installer = ManagedNodeInstallService(runtime: runtime, npmEntry: "/npm.js", pnpmEntry: "/pnpm.cjs")
        let environment = ToolEnvironment(id: "sources", writableLayerURL: root, layerURLs: [root], variables: [:])
        for manager in NodePackageManager.allCases {
            await #expect(throws: Error.self) {
                try await installer.change(environment, specification: "is-number@7.0.0", remove: false, manager: manager, cancellation: CancellationToken())
            }
            #expect(await runtime.arguments.contains("--registry=https://packages.example.org/npm/"))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("var/floe-node-transaction").path))
        }
    }
    @Test func sourcesPersistOnlyInSelectedEnvironmentAndRejectCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let custom = LanguagePackageSources(pythonIndex: "https://packages.example.org/python/simple", nodeRegistry: "https://packages.example.org/npm")
        try custom.save(in: first)
        #expect(try LanguagePackageSources.load(in: first).pythonIndex == "https://packages.example.org/python/simple/")
        #expect(try LanguagePackageSources.load(in: first).nodeRegistry == "https://packages.example.org/npm/")
        #expect(try LanguagePackageSources.load(in: second) == LanguagePackageSources())
        for url in ["http://packages.example.org", "https://user:secret@example.org", "https://example.org?token=private", "https://example.org/#fragment", "file:///tmp/packages"] {
            #expect(throws: Error.self) { try LanguagePackageSources(pythonIndex: url).save(in: first) }
        }
        #expect(try LanguagePackageSources.load(in: first) == custom.validated())
    }
    @Test func malformedOrEscapingSourceFileDoesNotSilentlyUseDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layer = root.appendingPathComponent("layer"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layer.appendingPathComponent("var"), withDestinationURL: outside)
        #expect(throws: Error.self) { try LanguagePackageSources().save(in: layer) }
        #expect(throws: Error.self) { try LanguagePackageSources.load(in: layer) }
        try Data("broken".utf8).write(to: outside.appendingPathComponent("language-package-sources.json"))
        try FileManager.default.removeItem(at: layer.appendingPathComponent("var"))
        try FileManager.default.moveItem(at: outside, to: layer.appendingPathComponent("var"))
        #expect(throws: Error.self) { try LanguagePackageSources.load(in: layer) }
    }
}

private actor RegistryRecordingRuntime: NodeRuntime {
    var arguments: [String] = []
    func run(_ request: NodeRunRequest, cancellation: CancellationToken?) async -> NodeRunOutcome {
        arguments = request.arguments
        return .failed(message: "Registry unavailable for recovery qualification")
    }
}

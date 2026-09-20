import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

struct LanguagePackageSourcesTests {
    @Test func legacyNodeTransactionRecoveryRestoresThePreviousGeneration() throws {
        // Phase 2: installs run the guest npm/pnpm (registry forwarding is
        // covered by LinuxGuestLanguagePackageTests); the host keeps only the
        // pure file recovery for native-era interrupted transactions.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transaction = root.appendingPathComponent("var/floe-node-transaction")
        let backup = transaction.appendingPathComponent("backup")
        let staged = root.appendingPathComponent("usr/lib/node_modules")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: backup.appendingPathComponent("marker.txt"))
        try Data("staged".utf8).write(to: staged.appendingPathComponent("marker.txt"))
        try Data(#"{"phase":"committing","hadOriginal":true}"#.utf8)
            .write(to: transaction.appendingPathComponent("journal.json"))
        let environment = ToolEnvironment(id: "sources", writableLayerURL: root, layerURLs: [root], variables: [:])
        try LegacyNodeInstallRecovery.recover(environment)
        #expect(!FileManager.default.fileExists(atPath: transaction.path))
        #expect(String(decoding: try Data(contentsOf: staged.appendingPathComponent("marker.txt")), as: UTF8.self) == "original")
        // No transaction: recovery is a no-op.
        try LegacyNodeInstallRecovery.recover(environment)
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

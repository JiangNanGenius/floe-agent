import Foundation
import Testing
import FloePackages

@Suite("Package transaction recovery")
struct PackageTransactionTests {
    @Test func interruptedWriteRestoresOldAndRemovesNewFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent("old"))
        let transaction = try PackageTransaction(root: root, paths: ["old", "new"])
        try transaction.write(Data("changed".utf8), to: "old")
        try transaction.write(Data("new".utf8), to: "new")
        #expect(try PackageTransaction.recover(root: root))
        #expect(try String(contentsOf: root.appendingPathComponent("old"), encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        #expect(try !PackageTransaction.recover(root: root))
    }

    @Test func recoveryValidatesAllBackupsBeforeChangingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] { try Data("old".utf8).write(to: root.appendingPathComponent(name)) }
        let transaction = try PackageTransaction(root: root, paths: ["a", "b"])
        for name in ["a", "b"] { try transaction.write(Data("new".utf8), to: name) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".floe-package-transaction/backup-0"))
        #expect(throws: (any Error).self) { try PackageTransaction.recover(root: root) }
        #expect(try String(contentsOf: root.appendingPathComponent("b"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".floe-package-transaction/journal.json").path))
    }

    @Test func recoveryRejectsSymlinkedJournalDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: outside.appendingPathComponent("evidence"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".floe-package-transaction"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try PackageTransaction.recover(root: root) }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("evidence").path))
    }

    @Test func committedFilesSurviveRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transaction = try PackageTransaction(root: root, paths: ["data/file"])
        try transaction.write(Data("committed".utf8), to: "data/file", mode: 0o755)
        try transaction.commit()
        #expect(try !PackageTransaction.recover(root: root))
        #expect(try String(contentsOf: root.appendingPathComponent("data/file"), encoding: .utf8) == "committed")
    }

    @Test func packagePathsRejectLinksAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        for path in ["../outside", "/outside", "link/outside", "a\nb", ".floe-package-transaction/journal.json"] {
            #expect(throws: (any Error).self) { try PackageTransaction(root: root, paths: [path]) }
        }
    }
}

@Suite("Package dependency constraints")
struct PackageDependencyTests {
    private func package(_ name: String, version: String, depends: String? = nil, conflicts: String? = nil) throws -> AptPackage {
        var control = Deb822.parse(stanza: "Package: \(name)\nVersion: \(version)\nArchitecture: all\nFilename: \(name).deb\nSHA256: \(String(repeating: "0", count: 64))\n")
        if let depends { control.set("Depends", depends) }
        if let conflicts { control.set("Conflicts", conflicts) }
        return try #require(AptPackage.parse(stanza: control, component: "main", repository: "https://example.invalid"))
    }
    @Test func choosesCompatibleVersionAndInstallsDependenciesFirst() throws {
        let packages = try [package("app", version: "1", depends: "lib (>= 2)"), package("lib", version: "1"), package("lib", version: "2")]
        let result = try PackageDependencyResolver.resolve(["app"], available: packages, installed: ["lib": "1"], architecture: "arm64")
        #expect(result.map(\.name) == ["lib", "app"])
        #expect(result.first?.version == "2")
    }
    @Test func explicitRequestUpgradesAndConflictsFail() throws {
        let packages = try [package("app", version: "2", conflicts: "other (>= 1)")]
        #expect(try PackageDependencyResolver.resolve(["app"], available: packages, installed: ["app": "1"], architecture: "arm64").first?.version == "2")
        #expect(throws: (any Error).self) { try PackageDependencyResolver.resolve(["app"], available: packages, installed: ["other": "1"], architecture: "arm64") }
    }
    @Test func alternativesAndConflictingVersionConstraints() throws {
        let packages = try [package("app", version: "1", depends: "missing | lib (>= 2)"), package("lib", version: "2"), package("old", version: "1", depends: "lib (<< 2)")]
        #expect(try PackageDependencyResolver.resolve(["app"], available: packages, installed: [:], architecture: "arm64").map(\.name) == ["lib", "app"])
        #expect(throws: (any Error).self) { try PackageDependencyResolver.resolve(["app", "old"], available: packages, installed: [:], architecture: "arm64") }
    }
}

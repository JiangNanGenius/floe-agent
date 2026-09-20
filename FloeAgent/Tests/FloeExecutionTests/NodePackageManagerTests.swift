import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("Node package managers", .serialized)
struct NodePackageManagerTests {
    @Test func selectionPreservesProjectAndReportsConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try NodePackageManagerPolicy.resolve(preference: .automatic, workspace: root) == .npm)
        let manifest = Data(#"{"packageManager":"pnpm@9.15.9"}"#.utf8)
        try manifest.write(to: root.appendingPathComponent("package.json"))
        try Data("lockfileVersion: '9.0'".utf8).write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        #expect(try NodePackageManagerPolicy.resolve(preference: .automatic, workspace: root) == .pnpm)
        try Data("{}".utf8).write(to: root.appendingPathComponent("package-lock.json"))
        #expect(throws: (any Error).self) { try NodePackageManagerPolicy.resolve(preference: .automatic, workspace: root) }
        #expect(try NodePackageManagerPolicy.resolve(preference: .npm, workspace: root) == .npm)
        #expect(try Data(contentsOf: root.appendingPathComponent("package.json")) == manifest)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("package-lock.json").path))
    }

    @Test func shellCommandsUseBoundedProjectDependenciesAndRejectLocationOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data(#"{"dependencies":{"is-number":"^7.0.0"},"devDependencies":{"is-odd":"3.0.1"}}"#.utf8)
        try manifest.write(to: root.appendingPathComponent("package.json"))
        let project = try #require(try NodePackageManagerPolicy.shellChange(arguments: ["install"], directory: root, workspace: root))
        #expect(project.specifications == ["is-number@^7.0.0", "is-odd@3.0.1"] && !project.remove)
        #expect(try Data(contentsOf: root.appendingPathComponent("package.json")) == manifest)
        let removal = try #require(try NodePackageManagerPolicy.shellChange(arguments: ["-g", "remove", "is-odd"], directory: root, workspace: root))
        #expect(removal.remove && removal.specifications == ["is-odd"])
        #expect(try NodePackageManagerPolicy.shellChange(arguments: ["--version"], directory: root, workspace: root) == nil)
        #expect(try NodePackageManagerPolicy.shellChange(arguments: ["run", "build"], directory: root, workspace: root) == nil)
        for arguments in [["install", "--prefix=/tmp", "is-odd"], ["--prefix", "/tmp", "install", "is-odd"],
                          ["ci"], ["add", "file:../secret"], ["install", "https://example.com/a.tgz"]] {
            #expect(throws: (any Error).self) { try NodePackageManagerPolicy.shellChange(arguments: arguments, directory: root, workspace: root) }
        }
        try NodePackageManagerPolicy.validateSpecification("@scope/example@>=1.2.0 <2 || ^3")
        let other = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try NodePackageManagerPolicy.shellChange(arguments: ["install"], directory: root, workspace: other) }
    }

}

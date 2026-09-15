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

    #if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOE_NETWORK_PACKAGE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func actualManagedNpmAndPnpmInstallSwitchRollbackAndRemove() async throws {
        var repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: repo.appendingPathComponent("FloeApp").path), repo.path != "/" { repo.deleteLastPathComponent() }
        let tools = repo.appendingPathComponent("FloeApp/Resources/NodeTools")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopNodePackageRuntime()
        let service = ManagedNodeInstallService(runtime: runtime, npmEntry: tools.appendingPathComponent("npm/bin/npm-cli.js").path,
            pnpmEntry: tools.appendingPathComponent("pnpm/bin/pnpm.cjs").path) { _, directory in
                ["HOME": root.path, "npm_config_cache": root.appendingPathComponent("cache").path,
                 "npm_config_store_dir": root.appendingPathComponent("pnpm-store").path, "PWD": directory.path]
            }
        let environment = ToolEnvironment(id: "qualified", writableLayerURL: root, layerURLs: [root], variables: [:])
        let modules = root.appendingPathComponent("usr/lib/node_modules")
        for manager in NodePackageManager.allCases {
            _ = try await service.change(environment, specifications: ["is-number@7.0.0", "is-odd@3.0.1"], remove: false, manager: manager, cancellation: CancellationToken())
            let outcome = await runtime.run(.init(entryScript: nil, arguments: ["-e", "console.log(require('is-number')(42) && require('is-odd')(3))"],
                workingDirectory: root, environment: ["NODE_PATH": modules.path]), cancellation: nil)
            guard case .exited(let code, let stdout, let stderr, _, _) = outcome else { Issue.record("No Node result"); return }
            #expect(code == 0 && stdout == "true\n", "\(stderr)")
            let installed = try Data(contentsOf: modules.appendingPathComponent("is-number/package.json"))
            await #expect(throws: (any Error).self) {
                try await service.change(environment, specification: "is-number@0.0.0-does-not-exist", remove: false, manager: manager, cancellation: CancellationToken())
            }
            #expect(try Data(contentsOf: modules.appendingPathComponent("is-number/package.json")) == installed)
            let lock = manager == .npm ? "package-lock.json" : "pnpm-lock.yaml"
            #expect(FileManager.default.fileExists(atPath: modules.appendingPathComponent(".floe-install/" + lock).path))
        }
        _ = try await service.change(environment, specifications: ["is-number", "is-odd"], remove: true, manager: .pnpm, cancellation: CancellationToken())
        #expect(!FileManager.default.fileExists(atPath: modules.appendingPathComponent("is-number").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("var/floe-node-transaction").path))
    }
    #endif
}

#if os(macOS)
/// Runs the pinned real CLI to qualify production staging/commit/recovery.
/// Host worker behavior has a separate node_host.test.cjs suite.
private struct DesktopNodePackageRuntime: NodeRuntime {
    func run(_ request: NodeRunRequest, cancellation: CancellationToken?) async -> NodeRunOutcome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let out = root.appendingPathComponent("stdout"), err = root.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            FileManager.default.createFile(atPath: err.path, contents: nil)
            let output = try FileHandle(forWritingTo: out), errors = try FileHandle(forWritingTo: err)
            defer { try? output.close(); try? errors.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node"] + (request.entryScript.map { [$0] } ?? []) + request.arguments
            process.currentDirectoryURL = request.workingDirectory
            process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].merging(request.environment) { _, value in value }
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(request.timeout)
            while process.isRunning {
                if cancellation?.isCancelled == true || Date() > deadline { process.terminate() }
                try await Task.sleep(for: .milliseconds(25))
            }
            return .exited(code: process.terminationStatus,
                stdout: try String(contentsOf: out, encoding: .utf8), stderr: try String(contentsOf: err, encoding: .utf8), durationMs: 0)
        } catch { return .failed(message: String(describing: error)) }
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameBuildKit
@testable import FloeGameExecutionBridge

@Suite("GameBuildHostBridge")
struct BuildHostBridgeTests {
    @Test("workspace commands run through the injected shell")
    func delegatesWorkspaceCommand() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let workspaceRoot = temp.url
        let shell = FakeExecutionShell(workspaceRoot: temp.url)
        let bridge = GameBuildHostBridge(shell: shell, contextProvider: {
            GameShellContext(workspaceRoot: workspaceRoot, environmentID: "linux-guest",
                             conversationID: UUID(), runID: UUID(),
                             executionBindingGeneration: 1)
        })
        let result = try await bridge.run(.init(executable: "echo", arguments: ["hello"], workingDirectory: "."))
        #expect(result.exitCode == 0)
        let commands = await shell.commands
        #expect(commands.last?.executable == "echo")
    }

    @Test("archive preflight verifies a real ZIP without a guest command")
    func archivePreflight() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let workspaceRoot = temp.url
        let content = temp.url.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: content.appendingPathComponent("index.html"))
        let archive = temp.url.appendingPathComponent("source.zip")
        _ = try GameArchiveExchange().archive(directory: content, to: archive)
        let shell = FakeExecutionShell(workspaceRoot: temp.url)
        let bridge = GameBuildHostBridge(shell: shell, contextProvider: {
            GameShellContext(workspaceRoot: workspaceRoot, environmentID: "linux-guest",
                             conversationID: UUID(), runID: UUID(),
                             executionBindingGeneration: 1)
        })
        let result = try await bridge.run(.init(executable: "unzip", arguments: ["-tq", archive.path]))
        #expect(result.exitCode == 0)
        let commands = await shell.commands
        #expect(commands.isEmpty)
    }
}

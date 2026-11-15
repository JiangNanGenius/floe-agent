// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGamePortableKit
@testable import FloeGameExecutionBridge

@Suite("GamePortableBuildBridge")
struct PortableBuildBridgeTests {
    private func request(temp: ExecutionTemporaryDirectory,
                         source: URL, resources: URL,
                         manifestURL: URL) throws -> GamePortableBuildRequest {
        let descriptor = try GamePortableProjectDescriptor(rootURL: source, revision: "rev-1")
        return try GamePortableBuildRequest(
            project: descriptor,
            outputURL: temp.url.appendingPathComponent("out"),
            resources: try GamePortablePreparedResources(
                rootURL: resources, manifestURL: manifestURL),
            sdkURL: nil, title: "Test", memoryBytes: 8_388_608)
    }

    @Test("runs a love.js plan through the guest and publishes the output")
    func lovePlan() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let workspaceRoot = temp.url
        let source = temp.url.appendingPathComponent("source")
        let resources = temp.url.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("print('hi')".utf8).write(to: source.appendingPathComponent("main.lua"))
        let cliURL = resources.appendingPathComponent("cli/index.js")
        try FileManager.default.createDirectory(at: cliURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("module.exports = 1".utf8).write(to: cliURL, options: .withoutOverwriting)
        let cliBytes = try Data(contentsOf: cliURL).count
        let cliSHA = try sha256(cliURL)
        let manifest = """
        {"schemaVersion":1,"id":"lovejs-11.4.1","pinID":"lovejs-11.4.1","engine":"love","runtimeID":"lovejs","version":"11.4.1",
         "notes":[],"files":[{"path":"cli/index.js","bytes":\(cliBytes),"sha256":"\(cliSHA)","executable":false}]}
        """
        let manifestURL = temp.url.appendingPathComponent("manifest.json")
        try Data(manifest.utf8).write(to: manifestURL)

        let shell = FakeExecutionShell(workspaceRoot: temp.url)
        let bridge = GamePortableBuildBridge(configuration: .init(
            shell: shell,
            shellContext: {
                GameShellContext(workspaceRoot: workspaceRoot, environmentID: "linux-guest",
                                 conversationID: UUID(), runID: UUID(),
                                 executionBindingGeneration: 1)
            }))
        let request = try request(temp: temp, source: source, resources: resources,
                                  manifestURL: manifestURL)
        let plan = try GamePortableBuildPlan(
            engine: .love, kind: .loveJSPackage,
            entry: try GameRelativePath("index.html"),
            steps: [
                .init(kind: .archiveSource, executable: nil, arguments: [],
                      outputs: ["floe-game.love"], note: "archive"),
                .init(kind: .runNode, executable: "node",
                      arguments: ["{{resources}}/cli/index.js", "{{output}}/floe-game.love",
                                  "{{output}}", "-c", "-t", "{{title}}", "-m", "{{memory}}"],
                      outputs: ["index.html"], note: "love.js")
            ],
            requiresExternalTool: true, resourceID: "lovejs-11.4.1",
            outputs: ["index.html"], notes: [])
        let result = try await bridge.execute(plan, request: request)
        #expect(result.entry.value == "index.html")
        #expect(FileManager.default.fileExists(atPath: request.outputURL.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: request.outputURL.appendingPathComponent("floe-game.love").path))
        let commands = await shell.commands
        let node = try #require(commands.first { $0.executable == "node" })
        #expect(node.arguments.allSatisfy { !$0.contains("{{") })
        #expect(node.arguments.contains { $0.hasPrefix("/workspace/") })
    }

    private func sha256(_ url: URL) throws -> String {
        GameDigest.sha256(try Data(contentsOf: url))
    }
}

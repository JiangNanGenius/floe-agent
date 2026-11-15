// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameBuildKit
import FloeGameRunKit
@testable import FloeGameExecutionBridge

final class ExecutionTemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-execution-tests-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
    func write(_ relative: String, _ text: String) throws {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .withoutOverwriting)
    }
}

actor FakeExecutionShell: GameShellRunning {
    enum Mode: Sendable { case succeed, fail, delay }
    private let workspaceRoot: URL
    private(set) var commands: [GameShellCommand] = []
    private let mode: Mode
    private let delay: Duration

    init(workspaceRoot: URL, mode: Mode = .succeed, delay: Duration = .milliseconds(50)) {
        self.workspaceRoot = workspaceRoot
        self.mode = mode
        self.delay = delay
    }

    func run(_ command: GameShellCommand, context: GameShellContext) async throws -> GameShellResult {
        commands.append(command)
        if mode == .delay { try await Task.sleep(for: delay) }
        if mode == .fail {
            return .init(exitCode: 2, stdout: Data(), stderr: Data("failure".utf8))
        }
        if command.arguments.contains("--export-release") {
            if let output = command.arguments.last {
                try writeGuestFile(output, html: "<!doctype html><title>godot</title>")
            }
        } else if command.executable == "node" || command.executable == "renpy.sh" {
            guard let output = command.arguments.first(where: { $0.hasSuffix("/out") }) else {
                return .init(exitCode: 3, stdout: Data(), stderr: Data("no output arg".utf8))
            }
            try writeGuestFile(output + "/index.html", html: "<!doctype html><title>portable</title>")
            try writeGuestFile(output + "/game.data", html: "data")
            try writeGuestFile(output + "/love.wasm", html: "wasm")
            try writeGuestFile(output + "/love.js", html: "js")
        }
        return .init(exitCode: 0, stdout: Data(), stderr: Data())
    }

    private func writeGuestFile(_ guestPath: String, html: String) throws {
        let prefix = "/workspace/"
        guard guestPath.hasPrefix(prefix) else {
            throw GameExecutionError.outputEscaped("test shell saw a non-guest path")
        }
        let relative = String(guestPath.dropFirst(prefix.count))
        let target = workspaceRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(html.utf8).write(to: target)
    }
}

struct FakeGitHubTokenProvider: GameBuildGitHubTokenProvider {
    let value: String?
    func token() async throws -> String? { value }
}

actor FakeSourcePublisher: GameBuildSourcePublisherPort {
    private(set) var snapshots: [GameBuildSourceSnapshot] = []
    private(set) var branches: [String] = []
    var publishedBranch: String?

    func publish(_ snapshot: GameBuildSourceSnapshot,
                 owner: String, repository: String, branch: String) async throws
        -> GameBuildRepositorySnapshot {
        snapshots.append(snapshot)
        branches.append(branch)
        return try .init(
            owner: owner, repository: repository,
            branch: publishedBranch ?? branch,
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: snapshot.digest, revision: snapshot.revision,
            gameRoot: snapshot.gameRoot,
            selectedSourceDigest: snapshot.selectedSourceDigest)
    }

    func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws
        -> GameBuildArtifactIdentity {
        throw GameBuildTransportError.artifactMissing
    }
}

actor FakeGitHubTransport: GameBuildGitHubActionsTransport {
    let workflow: GameBuildCIWorkflowRef
    let runID: Int64
    let runStatus: String
    let conclusion: String?
    var artifactsByRun: [Int64: [GameBuildCIArtifact]]
    var bytesByArtifact: [Int64: Data]
    private(set) var inputs: [String: String] = [:]
    private(set) var cancelled: [Int64] = []
    private var lastRef: String?

    init(workflow: GameBuildCIWorkflowRef, runID: Int64, runStatus: String,
         conclusion: String?, artifactsByRun: [Int64: [GameBuildCIArtifact]],
         bytesByArtifact: [Int64: Data]) {
        self.workflow = workflow
        self.runID = runID
        self.runStatus = runStatus
        self.conclusion = conclusion
        self.artifactsByRun = artifactsByRun
        self.bytesByArtifact = bytesByArtifact
    }

    func workflows(owner: String, repository: String, token: String)
        async throws -> [GameBuildCIWorkflowRef] { [workflow] }

    func workflowRuns(owner: String, repository: String, workflowID: Int64,
                      branch: String, event: String, token: String)
        async throws -> [GameBuildCIRun] {
        [.init(id: runID, workflowID: workflow.id, status: runStatus,
               conclusion: conclusion, headSHA: String(repeating: "b", count: 40),
               headBranch: branch, event: event, createdAt: Date(), htmlURL: nil)]
    }

    func run(owner: String, repository: String, runID: Int64, token: String)
        async throws -> GameBuildCIRun {
        .init(id: runID, workflowID: workflow.id, status: runStatus,
              conclusion: conclusion, headSHA: String(repeating: "b", count: 40),
              headBranch: lastRef, event: "workflow_dispatch", createdAt: Date(), htmlURL: nil)
    }

    func artifacts(owner: String, repository: String, runID: Int64, token: String)
        async throws -> [GameBuildCIArtifact] { artifactsByRun[runID] ?? [] }

    func downloadArtifact(owner: String, repository: String, runID: Int64,
                          artifactID: Int64, token: String, maximumBytes: Int)
        async throws -> Data {
        guard let data = bytesByArtifact[artifactID], data.count <= maximumBytes else {
            throw GameBuildCIError.artifact("missing test artifact")
        }
        return data
    }

    func triggerDispatch(owner: String, repository: String, workflowID: Int64,
                         ref: String, inputs: [String: String], token: String)
        async throws -> GameBuildCITrigger {
        self.inputs = inputs
        self.lastRef = ref
        return .init(runID: runID, htmlURL: nil)
    }

    func cancelRun(owner: String, repository: String, runID: Int64, token: String)
        async throws { cancelled.append(runID) }
}

enum ExecutionTestFixtures {
    static func zip(directory: URL) throws -> Data {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-fixture-" + UUID().uuidString.lowercased() + ".zip")
        defer { try? FileManager.default.removeItem(at: target) }
        _ = try GameArchiveExchange().archive(directory: directory, to: target)
        return try Data(contentsOf: target)
    }

    static func context(workspace: URL, projectID: UUID = UUID()) throws -> GameProjectContext {
        try GameProjectContext(projectID: projectID, owner: .space(recordID: projectID),
                               rootURL: workspace, savedRevision: "rev-1",
                               environmentID: "linux-guest")
    }

    static func authority(projectID: UUID, conversationID: UUID = UUID()) -> GameExecutionAuthority {
        .init(runID: UUID(), conversationID: conversationID,
              environmentID: "linux-guest", executionBindingGeneration: 7)
    }
}

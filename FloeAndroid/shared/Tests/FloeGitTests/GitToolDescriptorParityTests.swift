// SPDX-License-Identifier: MPL-2.0
//
// GitToolDescriptorParityTests — locks the Android tool mirror against the
// ORIGINAL public 3fd597b5 descriptor literals. Every string below is copied
// verbatim from FloeAgent/Sources/FloeGit/GitToolRegistration.swift at the
// pinned baseline; if the mirror ever renames a tool, loosens a schema,
// changes a risk label or drops a runner, this suite fails. No native Git
// call, no network, no credential.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeGit

@Suite("git.*/github.* descriptor parity with public 3fd597b5")
struct GitToolDescriptorParityTests {
    @Test("names are exactly the original set")
    func names() {
        #expect(GitStatusTool.name == "git.status")
        #expect(GitDiffTool.name == "git.diff")
        #expect(GitLogTool.name == "git.log")
        #expect(GitInitializeTool.name == "git.initialize")
        #expect(GitStageTool.name == "git.stage")
        #expect(GitCommitTool.name == "git.commit")
        #expect(GitCreateBranchTool.name == "git.createBranch")
        #expect(GitSwitchBranchTool.name == "git.switchBranch")
        #expect(GitFetchTool.name == "git.fetch")
        #expect(GitPullTool.name == "git.pull")
        #expect(GitPushTool.name == "git.push")
        #expect(GitHubRepositoriesTool.name == "github.repositories")
        #expect(GitHubCloneTool.name == "github.clone")
        #expect(GitHubCreateRepositoryTool.name == "github.createRepository")
    }

    @Test("descriptions are exactly the original strings")
    func descriptions() {
        #expect(GitStatusTool.toolDescription == "Inspect the current local workspace Git branch, remotes, changed files, branches, and recent commits. Read-only.")
        #expect(GitDiffTool.toolDescription == "Read the bounded unified Git diff for the workspace or one workspace-relative file.")
        #expect(GitLogTool.toolDescription == "Read recent commit history from the local workspace repository.")
        #expect(GitInitializeTool.toolDescription == "Initialize a real Git repository in the current local workspace. Local only; no remote account or author sign-in is required.")
        #expect(GitStageTool.toolDescription == "Stage all workspace changes, or a bounded list of workspace-relative paths, in the real Git index.")
        #expect(GitCommitTool.toolDescription == "Create a real local Git commit from staged changes using the connected GitHub identity when available, otherwise a local default identity. Does not push.")
        #expect(GitCreateBranchTool.toolDescription == "Create and switch to a new local Git branch without overwriting an existing branch.")
        #expect(GitSwitchBranchTool.toolDescription == "Switch to an existing local branch only when the workspace is clean; never discards changes.")
        #expect(GitFetchTool.toolDescription == "Fetch GitHub origin refs and objects without changing workspace files.")
        #expect(GitPullTool.toolDescription == "Perform a safe fast-forward-only pull from GitHub origin. Refuses dirty or diverged workspaces.")
        #expect(GitPushTool.toolDescription == "Push the current branch to its GitHub origin without force and without rewriting history.")
        #expect(GitHubRepositoriesTool.toolDescription == "List repositories accessible to the connected GitHub account. Read-only and never returns the credential.")
        #expect(GitHubCloneTool.toolDescription == "Clone a GitHub HTTPS repository into a new directory inside the current local workspace using in-memory Keychain authentication.")
        #expect(GitHubCreateRepositoryTool.toolDescription == "Create an empty repository in the connected GitHub account. Does not upload workspace files.")
    }

    @Test("parameter schemas are exactly the original literals")
    func schemas() {
        #expect(GitDiffTool.parametersJSON == #"{"type":"object","properties":{"path":{"type":"string","description":"Optional workspace-relative file path"}},"additionalProperties":false}"#)
        #expect(GitLogTool.parametersJSON == #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#)
        #expect(GitStageTool.parametersJSON == #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"maxItems":200,"description":"Omit to stage all changes"}},"additionalProperties":false}"#)
        #expect(GitCommitTool.parametersJSON == #"{"type":"object","properties":{"message":{"type":"string","minLength":1,"maxLength":8192}},"required":["message"],"additionalProperties":false}"#)
        #expect(GitCreateBranchTool.parametersJSON == #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":200}},"required":["name"],"additionalProperties":false}"#)
        #expect(GitSwitchBranchTool.parametersJSON == GitCreateBranchTool.parametersJSON)
        #expect(GitHubRepositoriesTool.parametersJSON == #"{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#)
        #expect(GitHubCloneTool.parametersJSON == #"{"type":"object","properties":{"cloneURL":{"type":"string","format":"uri"},"destination":{"type":"string","description":"New workspace-relative directory"}},"required":["cloneURL","destination"],"additionalProperties":false}"#)
        #expect(GitHubCreateRepositoryTool.parametersJSON == #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":100},"isPrivate":{"type":"boolean","default":true},"description":{"type":"string","maxLength":350}},"required":["name"],"additionalProperties":false}"#)
    }

    @Test("risk labels and effect flags are exactly the original sets")
    func riskAndEffects() {
        #expect(GitStatusTool.riskLabels == [.readsFiles])
        #expect(GitStatusTool.isSideEffecting == false)
        #expect(GitDiffTool.riskLabels == [.readsFiles])
        #expect(GitDiffTool.isSideEffecting == false)
        #expect(GitLogTool.riskLabels == [.readsFiles])
        #expect(GitLogTool.isSideEffecting == false)
        #expect(GitInitializeTool.riskLabels == [.writesFiles])
        #expect(GitInitializeTool.isSideEffecting == true)
        #expect(GitStageTool.riskLabels == [.writesFiles])
        #expect(GitStageTool.isSideEffecting == true)
        #expect(GitCommitTool.riskLabels == [.writesFiles])
        #expect(GitCommitTool.isSideEffecting == true)
        #expect(GitCreateBranchTool.riskLabels == [.writesFiles])
        #expect(GitCreateBranchTool.isSideEffecting == true)
        #expect(GitSwitchBranchTool.riskLabels == [.writesFiles])
        #expect(GitSwitchBranchTool.isSideEffecting == true)
        #expect(GitFetchTool.riskLabels == [.readsFiles, .networkAccess, .accessesCredentials])
        #expect(GitFetchTool.isSideEffecting == true)
        #expect(GitPullTool.riskLabels == [.writesFiles, .networkAccess, .accessesCredentials])
        #expect(GitPullTool.isSideEffecting == true)
        #expect(GitPushTool.riskLabels == [.networkAccess, .accessesCredentials, .modifiesRemoteSystem])
        #expect(GitPushTool.isSideEffecting == true)
        #expect(GitPushTool.requiresHostScope == false)
        #expect(GitHubRepositoriesTool.riskLabels == [.networkAccess, .accessesCredentials])
        #expect(GitHubRepositoriesTool.isSideEffecting == false)
        #expect(GitHubCloneTool.riskLabels == [.writesFiles, .networkAccess, .accessesCredentials])
        #expect(GitHubCloneTool.isSideEffecting == true)
        #expect(GitHubCreateRepositoryTool.riskLabels == [.networkAccess, .accessesCredentials, .modifiesRemoteSystem])
        #expect(GitHubCreateRepositoryTool.isSideEffecting == true)
        #expect(GitHubCreateRepositoryTool.requiresHostScope == false)
    }

    @Test("argument validation boundaries are preserved")
    func validation() throws {
        let stage = GitStageTool(environment: GitToolEnvironment(rootProvider: { nil }))
        #expect(throws: Never.self) {
            try stage.validate(.init(paths: (1...200).map { "file\($0)" }))
        }
        #expect(throws: (any Error).self) {
            try stage.validate(.init(paths: (1...201).map { "file\($0)" }))
        }
        let commit = GitCommitTool(environment: GitToolEnvironment(rootProvider: { nil }))
        #expect(throws: (any Error).self) {
            try commit.validate(.init(message: "   \n "))
        }
        #expect(throws: Never.self) {
            try commit.validate(.init(message: "real message"))
        }
        let clone = GitHubCloneTool(environment: GitToolEnvironment(rootProvider: { nil }))
        // The boundary is `URL(string:) != nil` exactly like the original
        // (GitHubActionsService.swift:331). Bare "words with spaces" PARSE
        // as relative references on both Foundation implementations, so the
        // invalid input must carry the space INSIDE the authority component:
        // "https://exa mple.com" is refused by Apple Foundation and by
        // swift-corelibs alike (host-probed against the pinned toolchain).
        #expect(throws: (any Error).self) {
            try clone.validate(.init(cloneURL: "https://exa mple.com", destination: "x"))
        }
        #expect(throws: Never.self) {
            try clone.validate(.init(cloneURL: "https://github.com/o/r.git", destination: "r"))
        }
    }

    @Test("registerGitTools binds all 14 runners on a fresh registry and the catalog")
    func registration() throws {
        let registry = ToolRunnerRegistry()
        let environment = registerGitTools(rootProvider: { nil }, registry: registry)
        _ = environment
        let names = [
            "git.status", "git.diff", "git.log", "git.initialize", "git.stage",
            "git.commit", "git.createBranch", "git.switchBranch", "git.fetch",
            "git.pull", "git.push", "github.repositories", "github.clone",
            "github.createRepository",
        ]
        for name in names {
            #expect(registry.runner(named: name) != nil, "runner \(name) missing")
            #expect(ToolCatalog.descriptor(named: name)?.name == name, "catalog \(name) missing")
        }
    }

    @Test("missing workspace root fails typed before any native call")
    func missingRootRejects() async throws {
        let tool = GitStatusTool(environment: GitToolEnvironment(rootProvider: { nil }))
        let context = ToolContext(
            runID: UUID(), scope: .local, workspaceRootURL: nil,
            cancellation: CancellationToken())
        do {
            _ = try await tool.execute(GitEmptyArguments(), context: context)
            Issue.record("expected notFound(workspace)")
        } catch let error as FloeError {
            guard case .notFound(let what) = error else {
                Issue.record("wrong FloeError case: \(error)")
                return
            }
            #expect(what == "workspace")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// GitCredentialSeamTests — offline contract suite for the Android leased
// credential seam (no Keychain, no RAM store, no real token, no network):
// fail-closed default, typed passthrough, typed propagation of vault errors,
// the auth-required tool rejection before any Git/network work, and the
// identity constants that must keep matching the shipped Kotlin vault.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeGit

private struct LeaseError: Error, Equatable {}

private actor FailingLease: GitHubCredentialLeasing {
    func leasedToken() async throws -> String? { throw LeaseError() }
}

private actor EchoLease: GitHubCredentialLeasing {
    private let value: String?
    init(value: String?) { self.value = value }
    func leasedToken() async throws -> String? { value }
}

private func makeContext(root: URL, allowed: [String] = []) -> ToolContext {
    ToolContext(
        runID: UUID(),
        scope: .local,
        workspaceRootURL: root,
        allowedWorkspacePaths: allowed,
        cancellation: CancellationToken()
    )
}

@Suite("GitHubCredentialStore Android lease")
struct GitHubCredentialStoreSeamTests {
    @Test("default store is fail-closed: reads nil, stores nothing")
    func unconfiguredReadsNil() async throws {
        let store = GitHubCredentialStore()
        #expect(try await store.token() == nil)
    }

    @Test("installed lease passes the value through unchanged")
    func leasePassthrough() async throws {
        let fake = EchoLease(value: "synthetic-lease-token-0123456789ab")
        let store = GitHubCredentialStore(lease: fake)
        #expect(try await store.token() == "synthetic-lease-token-0123456789ab")
    }

    @Test("vault errors propagate typed and are never swallowed into nil")
    func leaseErrorPropagates() async throws {
        let store = GitHubCredentialStore(lease: FailingLease())
        await #expect(throws: LeaseError.self) {
            _ = try await store.token()
        }
    }

    @Test("identity constants match the shipped Kotlin vault (one store, same reference)")
    func vaultIdentityConstants() {
        // GitHubCredentialStore.kt: SERVICE "org.floeagent.ios.github",
        // ACCOUNT "github.primary" — the Swift side must address the SAME
        // record; drifting these silently splits the vault in two.
        #expect(GitHubCredentialStore.service == "org.floeagent.ios.github")
        #expect(GitHubCredentialStore.account == "github.primary")
    }

    @Test("commit identity falls back to the local default without a connection")
    func localIdentityFallback() async throws {
        let environment = GitToolEnvironment(rootProvider: { nil })
        let identity = try await environment.identity()
        #expect(identity.name == "Floe")
        #expect(identity.email == "floe@local.floeagent")
    }

    @Test("push rejects without a credential BEFORE touching any repository")
    func pushRejectsWithoutCredential() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floegit-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The directory is NOT a repository on purpose: the typed credential
        // rejection must fire first, proving no libgit2 call is reached for
        // an unauthenticated push.
        let tool = GitPushTool(environment: GitToolEnvironment(rootProvider: { root }))
        do {
            _ = try await tool.execute(GitEmptyArguments(), context: makeContext(root: root))
            Issue.record("push must fail without a credential")
        } catch let error as FloeError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("wrong FloeError case: \(error)")
                return
            }
            #expect(message.contains("Connect GitHub in Settings"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("account-scoped remote tools reject without a credential")
    func repositoriesRejectWithoutCredential() async throws {
        let tool = GitHubRepositoriesTool(
            environment: GitToolEnvironment(rootProvider: { nil }))
        do {
            _ = try await tool.execute(
                GitHubRepositoriesTool.Arguments(limit: nil),
                context: makeContext(root: URL(fileURLWithPath: "/")))
            Issue.record("repositories must fail without a credential")
        } catch let error as FloeError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("wrong FloeError case: \(error)")
                return
            }
            #expect(message.contains("Connect GitHub"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("a token-restricted tool still refuses non-local scope")
    func nonLocalScopeRejected() async throws {
        var context = makeContext(root: URL(fileURLWithPath: "/"))
        context.scope = .host(UUID())
        let tool = GitStatusTool(environment: GitToolEnvironment(rootProvider: { nil }))
        do {
            _ = try await tool.execute(GitEmptyArguments(), context: context)
            Issue.record("host-scope local Git must be rejected")
        } catch let error as FloeError {
            guard case .validationFailed = error else {
                Issue.record("wrong FloeError case: \(error)")
                return
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

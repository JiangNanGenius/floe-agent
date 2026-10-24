// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGit

@Suite struct GitOfflineAuthorTests {
    private struct MustNotReadCredential: GitHubCredentialLeasing {
        enum UnexpectedRead: Error { case localCommitReadToken }
        func leasedToken() async throws -> String? { throw UnexpectedRead.localCommitReadToken }
    }

    @Test func localFallbackNeverReadsEvenConfiguredCredentialBackend() async throws {
        let environment = GitToolEnvironment(rootProvider: { nil },
            credentials: GitHubCredentialStore(lease: MustNotReadCredential()))
        let author = try await environment.identity()
        #expect(author.name == "Floe")
        #expect(author.email == "floe@local.floeagent")
    }

    @Test func alreadyKnownNativeAuthorNeedsNoNetworkOrVaultRead() async throws {
        let environment = GitToolEnvironment(rootProvider: { nil },
            credentials: GitHubCredentialStore(lease: MustNotReadCredential()),
            localAuthor: GitLocalAuthor(name: "Local Tester", email: "tester@example.invalid"))
        let author = try await environment.identity()
        #expect(author.name == "Local Tester")
        #expect(author.email == "tester@example.invalid")
    }
}

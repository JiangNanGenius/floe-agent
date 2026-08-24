#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeGit

@MainActor
final class SourceControlCenter: ObservableObject {
    @Published private(set) var snapshot = GitRepositorySnapshot(isRepository: false)
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var repositories: [GitHubRepository] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private unowned let environment: AppEnvironment
    private let git = LocalGitService()
    private let github = GitHubService()
    private let credentials = GitHubCredentialStore()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isGitHubConnected: Bool { account != nil }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    func loadConnection() async {
        do {
            guard let token = try credentials.token() else {
                account = nil
                repositories = []
                return
            }
            let loadedAccount = try await github.account(token: token)
            account = loadedAccount
            repositories = try await github.repositories(token: token)
            errorMessage = nil
        } catch {
            account = nil
            repositories = []
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    func connect(token: String) async throws {
        isBusy = true
        defer { isBusy = false }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let loadedAccount = try await github.account(token: value)
        let loadedRepositories = try await github.repositories(token: value)
        try credentials.save(token: value)
        account = loadedAccount
        repositories = loadedRepositories
        errorMessage = nil
    }

    func disconnect() throws {
        try credentials.delete()
        account = nil
        repositories = []
        errorMessage = nil
    }

    func refreshRepository() async {
        guard let root = environment.workspaceCenter.currentRootURL else {
            snapshot = GitRepositorySnapshot(isRepository: false)
            return
        }
        do {
            snapshot = try await git.snapshot(at: root)
            errorMessage = nil
        } catch {
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    func initializeRepository() async throws {
        guard let root = environment.workspaceCenter.currentRootURL else {
            throw FloeError.notFound("workspace")
        }
        let identity = try await gitIdentity()
        snapshot = try await git.initialize(
            at: root,
            authorName: identity.name,
            authorEmail: identity.email
        )
    }

    func stageAll() async throws {
        let root = try workspaceRoot()
        try await git.stageAll(at: root)
        snapshot = try await git.snapshot(at: root)
    }

    func commit(message: String) async throws {
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        _ = try await git.commit(
            at: root, message: message,
            authorName: identity.name, authorEmail: identity.email
        )
        snapshot = try await git.snapshot(at: root)
    }

    func fetch() async throws {
        let root = try workspaceRoot()
        try await git.fetch(at: root, token: try credentials.token())
        snapshot = try await git.snapshot(at: root)
    }

    func pull() async throws {
        let root = try workspaceRoot()
        try await git.pullFastForward(at: root, token: try credentials.token())
        snapshot = try await git.snapshot(at: root)
    }

    func push() async throws {
        let root = try workspaceRoot()
        guard let token = try credentials.token() else {
            throw FloeError.invalidConfiguration("Connect GitHub before pushing")
        }
        try await git.push(at: root, token: token)
        snapshot = try await git.snapshot(at: root)
    }

    func createBranch(name: String) async throws {
        let root = try workspaceRoot()
        try await git.createBranch(at: root, name: name)
        snapshot = try await git.snapshot(at: root)
    }

    func switchBranch(name: String) async throws {
        let root = try workspaceRoot()
        try await git.switchBranch(at: root, name: name)
        snapshot = try await git.snapshot(at: root)
    }

    func diff(path: String?) async throws -> String {
        try await git.diff(at: workspaceRoot(), path: path)
    }

    func clone(_ repository: GitHubRepository, destinationName: String? = nil) async throws {
        let root = try workspaceRoot()
        let name = destinationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (name?.isEmpty == false ? name : nil) ?? repository.name
        guard folder.range(of: #"^[A-Za-z0-9_.-]{1,120}$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Clone folder name is invalid")
        }
        try await git.clone(
            from: repository.cloneURL,
            to: root.appendingPathComponent(folder, isDirectory: true),
            token: try credentials.token()
        )
    }

    func createGitHubRepository(name: String, isPrivate: Bool, description: String?) async throws {
        guard let token = try credentials.token() else {
            throw FloeError.invalidConfiguration("Connect GitHub before creating a repository")
        }
        _ = try await github.createRepository(
            token: token, name: name, isPrivate: isPrivate, description: description
        )
        repositories = try await github.repositories(token: token)
    }

    private func workspaceRoot() throws -> URL {
        guard let root = environment.workspaceCenter.currentRootURL else {
            throw FloeError.notFound("workspace")
        }
        return root
    }

    private func gitIdentity() async throws -> (name: String, email: String) {
        if let account { return (account.name ?? account.login, "\(account.login)@users.noreply.github.com") }
        guard let token = try credentials.token() else {
            throw FloeError.invalidConfiguration("Connect GitHub to set the Git author identity")
        }
        let loaded = try await github.account(token: token)
        account = loaded
        return (loaded.name ?? loaded.login, "\(loaded.login)@users.noreply.github.com")
    }
}
#endif

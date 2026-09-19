#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeGit

@MainActor
final class SourceControlCenter: ObservableObject {
    @Published private(set) var snapshot = GitRepositorySnapshot(isRepository: false)
    /// The discovered Git repository root (an ancestor of the workspace root
    /// when the workspace is nested inside a repository or a worktree). All
    /// stage/commit/diff operations target this root; nil when the workspace
    /// is not a repository.
    @Published private(set) var repositoryRoot: URL?
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var repositories: [GitHubRepository] = []
    @Published private(set) var deviceAuthorization: GitHubDeviceAuthorization?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private unowned let environment: AppEnvironment
    private let git = LocalGitService()
    private let github = GitHubService()
    private let credentials = GitHubCredentialStore()
    private var deviceLoginTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isGitHubConnected: Bool { account != nil }
    var isDeviceLoginPending: Bool { deviceAuthorization != nil }
    /// True when the discovered repository root is an ancestor of the
    /// workspace root (a workspace nested inside a repository, or a linked
    /// worktree). The view surfaces the real root in that case.
    var isNestedRepository: Bool {
        guard let repositoryRoot else { return false }
        return repositoryRoot.standardizedFileURL
            != environment.workspaceCenter.currentRootURL?.standardizedFileURL
    }

    /// Skill updates use the existing connector credential without exposing it
    /// to the model, package, upgrade journal, or redirect destination.
    func skillRepositoryData(owner: String, repository: String, ref: String, path: String?, usesConnectorCredential: Bool = true) async throws -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var components = URLComponents(string: "https://api.github.com")!
        if let path {
            components.percentEncodedPath = "/repos/\(encoded(owner))/\(encoded(repository))/contents/" + path.split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
            components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        } else {
            components.percentEncodedPath = "/repos/\(encoded(owner))/\(encoded(repository))/commits/\(encoded(ref))"
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue(path == nil ? "application/vnd.github+json" : "application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        if usesConnectorCredential, let token = try credentials.token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: SkillGitHubNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FloeError.syncUnavailable("GitHub skill source unavailable. Check the repository, ref, path and connector access.")
        }
        var result = Data()
        let maximumBytes = path?.hasPrefix("skill-hub/packages/") == true ? 8_388_608 : 2_097_152
        for try await byte in stream {
            try Task.checkCancellation()
            guard result.count < maximumBytes else { throw FloeError.validationFailed("GitHub skill download exceeds its size limit") }
            result.append(byte)
        }
        return result
    }

    private final class SkillGitHubNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private var githubOAuthClientID: String? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "FLOEGitHubOAuthClientID"
        ) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

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

    /// Starts the OAuth device flow. `includeWorkflows` is an explicit opt-in
    /// for the `workflow` scope needed to install build templates; it defaults
    /// to `false`, and an existing credential is never upgraded silently — only
    /// a fresh sign-in can widen the granted scopes.
    func startDeviceLogin(includeWorkflows: Bool = false) async {
        guard !isBusy, deviceLoginTask == nil else { return }
        guard let clientID = githubOAuthClientID else {
            errorMessage = "此构建尚未配置 GitHub OAuth Client ID，请联系构建管理员；访问令牌登录仍可使用。"
            return
        }
        isBusy = true
        do {
            let authorization = try await github.beginDeviceAuthorization(
                clientID: clientID,
                includeWorkflows: includeWorkflows
            )
            deviceAuthorization = authorization
            errorMessage = nil
            isBusy = false
            deviceLoginTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let token = try await self.github.completeDeviceAuthorization(
                        authorization,
                        clientID: clientID
                    )
                    try Task.checkCancellation()
                    // GitHub requires identity to be revalidated for every new
                    // token before it can become the active local account.
                    let loadedAccount = try await self.github.account(token: token)
                    let loadedRepositories = try await self.github.repositories(token: token)
                    try self.credentials.save(token: token)
                    self.account = loadedAccount
                    self.repositories = loadedRepositories
                    self.deviceAuthorization = nil
                    self.errorMessage = nil
                } catch is CancellationError {
                    self.deviceAuthorization = nil
                } catch let error as FloeError where error == .cancelled {
                    self.deviceAuthorization = nil
                } catch {
                    self.deviceAuthorization = nil
                    self.errorMessage = SecretRedactor.redact(error.localizedDescription)
                }
                self.deviceLoginTask = nil
            }
        } catch {
            isBusy = false
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    func cancelDeviceLogin() {
        deviceLoginTask?.cancel()
        deviceLoginTask = nil
        deviceAuthorization = nil
        isBusy = false
    }

    func disconnect() throws {
        cancelDeviceLogin()
        try credentials.delete()
        account = nil
        repositories = []
        errorMessage = nil
    }

    func refreshRepository() async {
        guard let root = environment.workspaceCenter.currentRootURL else {
            snapshot = GitRepositorySnapshot(isRepository: false)
            repositoryRoot = nil
            return
        }
        do {
            snapshot = try await git.snapshot(at: root)
            repositoryRoot = snapshot.repositoryRoot
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

    func stage(paths: [String]) async throws {
        let root = try workspaceRoot()
        try await git.stage(paths: paths, at: root)
        snapshot = try await git.snapshot(at: root)
    }

    func unstage(paths: [String]) async throws {
        let root = try workspaceRoot()
        try await git.unstage(paths: paths, at: root)
        snapshot = try await git.snapshot(at: root)
    }

    /// Discards the selected file's changes after writing a private recovery
    /// copy (working tree plus staged bytes when `includeStaged`). The returned
    /// outcome carries the recovery path so the UI can offer it.
    func discard(paths: [String], includeStaged: Bool = false) async throws -> GitDiscardOutcome {
        let root = try workspaceRoot()
        let outcome = try await git.discard(paths: paths, at: root, includeStaged: includeStaged)
        snapshot = try await git.snapshot(at: root)
        return outcome
    }

    /// Staged-vs-HEAD diff (`git diff --cached`).
    func diffStaged(path: String?) async throws -> String {
        try await git.diffStaged(at: workspaceRoot(), path: path)
    }

    func merge(branch: String) async throws -> GitMergeOutcome {
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        let outcome = try await git.mergeRef(
            at: root, refName: "refs/heads/\(branch)",
            authorName: identity.name, authorEmail: identity.email
        )
        snapshot = try await git.snapshot(at: root)
        return outcome
    }

    /// Fetches then merges the upstream (ordinary pull with merge fallback).
    func pullMerge() async throws -> GitMergeOutcome {
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        let outcome = try await git.pullMerge(
            at: root, token: try credentials.token(),
            authorName: identity.name, authorEmail: identity.email
        )
        snapshot = try await git.snapshot(at: root)
        return outcome
    }

    func resolveConflict(path: String, content: String) async throws -> GitMergeOutcome {
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        let outcome = try await git.resolveConflict(
            at: root, path: path, content: content,
            authorName: identity.name, authorEmail: identity.email
        )
        snapshot = try await git.snapshot(at: root)
        return outcome
    }

    func abortMerge() async throws {
        let root = try workspaceRoot()
        try await git.abortMerge(at: root)
        snapshot = try await git.snapshot(at: root)
    }

    func isMerging() async throws -> Bool {
        try await git.isMerging(at: workspaceRoot())
    }

    /// Reads one conflicted file for the resolution editor. Path validation
    /// keeps the read inside the workspace root.
    func conflictFileContents(path: String) async throws -> String {
        let root = try workspaceRoot()
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("Git path must stay inside the workspace")
        }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw FloeError.validationFailed("Git path must stay inside the workspace")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw FloeError.validationFailed("冲突文件不是可编辑的 UTF-8 文本")
        }
        return text
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

    /// Operations stage/commit/diff against the discovered repository root so
    /// a workspace nested inside a repository (or a worktree) acts on the real
    /// repository; before the first refresh (or when not a repository) this is
    /// the workspace root itself.
    private func workspaceRoot() throws -> URL {
        guard let root = environment.workspaceCenter.currentRootURL else {
            throw FloeError.notFound("workspace")
        }
        return repositoryRoot ?? root
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

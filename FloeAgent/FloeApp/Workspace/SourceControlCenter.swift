#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeGit

/// Pure workspace-identity decision used by both the pinned source-control
/// pane (rendering/lock) and the mutation guard inside `perform(pinnedRoot:)`.
/// A nil pin means "follow the global current workspace" (the legacy
/// inspector behavior); a non-nil pin matches only the exact standardized
/// workspace root — discovering a repository above the workspace does not
/// change which workspace owns the pane.
enum SourceControlRootIdentity {
    static func matches(current: URL?, pinned: URL?) -> Bool {
        guard let pinned else { return true }
        guard let current else { return false }
        return current.standardizedFileURL == pinned.standardizedFileURL
    }
}

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
    private var repositoryChangeObserver: NSObjectProtocol?

    init(environment: AppEnvironment) {
        self.environment = environment
        observeRepositoryChanges()
    }

    // The observer is intentionally not removed: this center is an app-lifetime
    // object, its closure captures self weakly, and NotificationCenter keeps no
    // strong reference to the center. A deinit that touched the actor-isolated
    // token would be a Swift 6 isolation hazard for no benefit.

    /// Every host-side Git mutation (agent `git.*` tools, guest-triggered
    /// changes recorded by the host service, this center's own buttons) posts
    /// `floeGitRepositoryDidChange`; a mounted source-control pane therefore
    /// shows a newly initialized repository, new staged files and new commits
    /// immediately instead of waiting for a manual refresh or a remount.
    private func observeRepositoryChanges() {
        repositoryChangeObserver = NotificationCenter.default.addObserver(
            forName: .floeGitRepositoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let root = notification.userInfo?[GitRepositoryChange.rootKey] as? URL else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.changedRootAffectsActiveWorkspace(root) else { return }
                await self.refreshRepository()
            }
        }
    }

    /// True when a mutation under `changed` can change what the active
    /// workspace's source-control pane shows: the changed tree is the active
    /// workspace root, contains it (repository root above the workspace), is
    /// inside it, or is the repository root currently displayed.
    private func changedRootAffectsActiveWorkspace(_ changed: URL) -> Bool {
        let changedPath = changed.standardizedFileURL.path
        if let repositoryRoot, repositoryRoot.standardizedFileURL.path == changedPath { return true }
        guard let active = environment.workspaceCenter.currentRootURL?.standardizedFileURL.path else {
            return false
        }
        if changedPath == active { return true }
        if active.hasPrefix(changedPath + "/") { return true }
        if changedPath.hasPrefix(active + "/") { return true }
        return false
    }

    /// Re-reads the repository state when the app becomes active again: guest
    /// git (apt-installed inside Linux) writes through 9p and cannot post a
    /// host notification, so returning to the app is the bounded moment to
    /// pick those changes up.
    func refreshOnForeground() async {
        await refreshRepository()
    }

    var isGitHubConnected: Bool { account != nil }
    var isDeviceLoginPending: Bool { deviceAuthorization != nil }

    /// The workspace root the global center currently resolves its
    /// repository operations to. A host that pins a pane to a specific
    /// workspace compares this to its pinned root before allowing writes.
    var currentWorkspaceRoot: URL? { environment.workspaceCenter.currentRootURL }

    /// The observed workspace center a pinned pane needs to redraw on an
    /// A→B workspace switch.
    var boundWorkspaceCenter: WorkspaceCenter { environment.workspaceCenter }
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
        await perform(pinnedRoot: nil, operation)
    }

    /// Runs a UI mutation with a workspace-identity guard. A pane that is
    /// pinned to the workspace it was opened for passes that root; if the
    /// global current workspace has since switched (an async A→B change the
    /// disabled button alone cannot cover), the operation is refused before
    /// any Git service call and a bilingual error is recorded.
    func perform(
        pinnedRoot: URL?,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async {
        if !SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: pinnedRoot) {
            errorMessage = SecretRedactor.redact(IDELanguageRunText.t(
                "工作区已切换，已阻止对原仓库的操作。请重新打开该工作区的 IDE。",
                "The workspace switched; the operation on the previous repository was blocked. Reopen the IDE for that workspace."
            ))
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            // A switch during the await means the success belongs to A; do
            // not clear B's error state, and let B refresh its own snapshot.
            guard SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: pinnedRoot) else {
                await refreshRepository()
                return
            }
            errorMessage = nil
        } catch {
            // A's failure must not surface in B's pane after a switch.
            guard SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: pinnedRoot) else {
                await refreshRepository()
                return
            }
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    /// Exact-identity check used both by the pinned pane's rendering and by
    /// the mutation guard: only the standardized workspace root itself
    /// matches (a nested repository's discovered root is handled by the
    /// mutation methods, never by weakening which workspace owns the pane).
    func rootMatchesPinned(_ root: URL) -> Bool {
        SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: root)
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

    /// Monotonic refresh generation. Every call to `refreshRepository`
    /// captures the current workspace root and this generation; only the
    /// latest generation may publish. An earlier refresh (A) that finishes
    /// after a workspace switch to B is discarded instead of overwriting B's
    /// state — each call schedules its own snapshot rather than joining a
    /// stale in-flight task, so switching workspaces always schedules B.
    private var refreshGeneration: UInt64 = 0

    func refreshRepository() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let root = environment.workspaceCenter.currentRootURL else {
            snapshot = GitRepositorySnapshot(isRepository: false)
            repositoryRoot = nil
            return
        }
        do {
            let updated = try await git.snapshot(at: root)
            guard isCurrentRefresh(generation, root: root) else { return }
            snapshot = updated
            repositoryRoot = updated.repositoryRoot
            errorMessage = nil
        } catch {
            guard isCurrentRefresh(generation, root: root) else { return }
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    /// True while `generation` is still the newest refresh and the workspace
    /// still resolves to the same root the snapshot was taken for.
    private func isCurrentRefresh(_ generation: UInt64, root: URL) -> Bool {
        generation == refreshGeneration && environment.workspaceCenter.currentRootURL == root
    }

    /// Refreshes the published snapshot only while the workspace the mutation
    /// started for is still the current one. If the workspace switched A→B
    /// while a Git call was in flight, A's result is dropped and B gets its
    /// own refresh instead, so B's pane never renders A's state. The Git
    /// operation itself is neither retargeted nor reverted (it already ran).
    private func republishAfterMutation(workspaceRoot: URL) async throws {
        guard SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: workspaceRoot) else {
            await refreshRepository()
            return
        }
        let repoRoot = repositoryRoot ?? workspaceRoot
        let updated = try await git.snapshot(at: repoRoot)
        // Re-check after the snapshot await too: the switch may have landed
        // during this second round trip.
        guard SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: workspaceRoot) else {
            await refreshRepository()
            return
        }
        snapshot = updated
        repositoryRoot = updated.repositoryRoot
    }

    /// Local init stands alone: no GitHub sign-in is required and no remote
    /// identity is consulted. The author identity is configured per commit —
    /// the connected GitHub identity when present, otherwise a local default.
    func initializeRepository() async throws {
        guard let wsRoot = environment.workspaceCenter.currentRootURL else {
            throw FloeError.notFound("workspace")
        }
        let initialized = try await git.initialize(at: wsRoot)
        guard SourceControlRootIdentity.matches(current: currentWorkspaceRoot, pinned: wsRoot) else {
            await refreshRepository()
            return
        }
        snapshot = initialized
        repositoryRoot = snapshot.repositoryRoot
    }

    func stageAll() async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let repoRoot = try workspaceRoot()
        try await git.stageAll(at: repoRoot)
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func stage(paths: [String]) async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let repoRoot = try workspaceRoot()
        try await git.stage(paths: paths, at: repoRoot)
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func unstage(paths: [String]) async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let repoRoot = try workspaceRoot()
        try await git.unstage(paths: paths, at: repoRoot)
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    /// Discards the selected file's changes after writing a private recovery
    /// copy (working tree plus staged bytes when `includeStaged`). The returned
    /// outcome carries the recovery path so the UI can offer it.
    func discard(paths: [String], includeStaged: Bool = false) async throws -> GitDiscardOutcome {
        let wsRoot = try requiredWorkspaceRoot()
        let repoRoot = try workspaceRoot()
        let outcome = try await git.discard(paths: paths, at: repoRoot, includeStaged: includeStaged)
        try await republishAfterMutation(workspaceRoot: wsRoot)
        return outcome
    }

    /// Staged-vs-HEAD diff (`git diff --cached`).
    func diffStaged(path: String?) async throws -> String {
        try await git.diffStaged(at: workspaceRoot(), path: path)
    }

    func merge(branch: String) async throws -> GitMergeOutcome {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        let outcome = try await git.mergeRef(
            at: root, refName: "refs/heads/\(branch)",
            authorName: identity.name, authorEmail: identity.email
        )
        try await republishAfterMutation(workspaceRoot: wsRoot)
        return outcome
    }

    /// Fetches then merges the upstream (ordinary pull with merge fallback).
    func pullMerge() async throws -> GitMergeOutcome {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        let outcome = try await git.pullMerge(
            at: root, token: try credentials.token(),
            authorName: identity.name, authorEmail: identity.email
        )
        try await republishAfterMutation(workspaceRoot: wsRoot)
        return outcome
    }

    func resolveConflict(path: String, content: String) async throws -> GitMergeOutcome {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        let outcome = try await git.resolveConflict(
            at: root, path: path, content: content,
            authorName: identity.name, authorEmail: identity.email
        )
        try await republishAfterMutation(workspaceRoot: wsRoot)
        return outcome
    }

    func abortMerge() async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        try await git.abortMerge(at: root)
        try await republishAfterMutation(workspaceRoot: wsRoot)
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
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        let identity = try await gitIdentity()
        _ = try await git.commit(
            at: root, message: message,
            authorName: identity.name, authorEmail: identity.email
        )
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func fetch() async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        try await git.fetch(at: root, token: try credentials.token())
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func pull() async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        try await git.pullFastForward(at: root, token: try credentials.token())
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func push() async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        guard let token = try credentials.token() else {
            throw FloeError.invalidConfiguration("Connect GitHub before pushing")
        }
        try await git.push(at: root, token: token)
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func createBranch(name: String) async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        try await git.createBranch(at: root, name: name)
        try await republishAfterMutation(workspaceRoot: wsRoot)
    }

    func switchBranch(name: String) async throws {
        let wsRoot = try requiredWorkspaceRoot()
        let root = try workspaceRoot()
        try await git.switchBranch(at: root, name: name)
        try await republishAfterMutation(workspaceRoot: wsRoot)
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

    /// The workspace root itself (not the discovered repository root above
    /// it): the identity a pinned pane compares against after an await.
    private func requiredWorkspaceRoot() throws -> URL {
        guard let root = environment.workspaceCenter.currentRootURL else {
            throw FloeError.notFound("workspace")
        }
        return root
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

    /// Commit identity: the connected GitHub account when one exists, else a
    /// local default (`Floe <floe@local.floeagent>`) so local commits never
    /// depend on a remote account. Every commit still (re)configures the
    /// repository identity, so connecting GitHub later takes over from the
    /// next commit onward.
    static let localGitIdentity = (name: "Floe", email: "floe@local.floeagent")

    private func gitIdentity() async throws -> (name: String, email: String) {
        if let account { return (account.name ?? account.login, "\(account.login)@users.noreply.github.com") }
        guard let token = try credentials.token() else {
            return Self.localGitIdentity
        }
        let loaded = try await github.account(token: token)
        account = loaded
        return (loaded.name ?? loaded.login, "\(loaded.login)@users.noreply.github.com")
    }
}
#endif

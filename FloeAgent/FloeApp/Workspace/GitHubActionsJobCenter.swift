// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsJobCenter — the app-side coordinator for the IDE's GitHub
// Actions target. It is the SwiftUI-facing shell around
// `GitHubActionsJobEngine`, which owns the durable state machine. The center:
//
// * reads the GitHub token from the device Keychain (per call, never stored);
// * builds the explicit, policy-filtered recursive snapshot preview the user
//   reviews before anything is published;
// * installs a reviewed Floe template on the repository's default branch
//   (explicit, fast-forward only, never overwrites a divergent file);
// * forwards scene lifecycle to the engine with the originating window's
//   scene id, so one iPad window going inactive never stops another window's
//   run and a backgrounded app never keeps a local polling loop alive.
//
// No token, header or raw credential is ever written to a record.

#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeGit
import FloeWorkspace

/// The reviewable snapshot the user is about to publish. The UI shows this
/// list verbatim before dispatch; nothing outside it is uploaded.
struct GitHubActionsSnapshotPreview: Sendable, Equatable {
    let directory: String
    let manifest: IDEGitHubActionsSnapshotManifest

    var includedPaths: [String] { manifest.entries.map(\.path) }
    var totalBytes: Int { manifest.totalBytes }
}

/// Result of an explicit workflow install on a repository's default branch.
/// `workflow_dispatch` cannot discover a workflow that exists only on another
/// branch, so this step is required before a Floe template can run.
struct GitHubActionsWorkflowInstallResult: Sendable, Equatable {
    enum Outcome: String, Sendable, Equatable {
        case installed
        case alreadyInstalled
        /// A different file already occupies the path. Nothing was changed;
        /// `suggestedPath` is a Floe-owned alternative.
        case conflict
    }

    let outcome: Outcome
    let path: String
    let templateID: String
    let yaml: String
    let suggestedPath: String?
    /// Workspace-relative path when the caller asked to export the template.
    let exportedRelativePath: String?

    var isUsable: Bool { outcome == .installed || outcome == .alreadyInstalled }
}

@MainActor
final class GitHubActionsJobCenter: ObservableObject {
    static let shared = GitHubActionsJobCenter()

    @Published private(set) var records: [GitHubActionsJobRecord] = []
    @Published private(set) var repositories: [GitHubActionsRepositorySelection] = []
    @Published private(set) var account: GitHubAccount?
    @Published private(set) var isBusy = false
    @Published private(set) var snapshotPreview: GitHubActionsSnapshotPreview?
    @Published var errorMessage: String?

    private let credentials = GitHubCredentialStore()
    private let github = GitHubService()
    private let actions = GitHubActionsClient()
    private let store = GitHubActionsJobStore()
    private lazy var engine: GitHubActionsJobEngine = makeEngine()

    /// Maximum records refreshed at once by the shared engine.
    private let maximumConcurrentRefreshes = 3

    private init() {}

    // MARK: Engine wiring

    private func makeEngine() -> GitHubActionsJobEngine {
        let remote = CenterGitHubActionsRemote(actions: actions)
        let store = self.store
        let credentials = self.credentials
        let dependencies = GitHubActionsEngineDependencies(
            remote: remote,
            store: store,
            credentials: CenterCredentialProvider(store: credentials),
            clock: SystemGitHubActionsClock(),
            digest: { FloeDigest.sha256Hex($0) },
            redact: { SecretRedactor.redact($0) },
            commitArtifact: { data, relativePath, overwrite, workspaceRoot in
                try Self.commitArtifact(
                    data: data, relativePath: relativePath,
                    overwrite: overwrite, workspaceRoot: workspaceRoot
                )
            },
            publish: { [weak self] record in
                await MainActor.run { self?.publish(record) }
            },
            publishAll: { [weak self] records in
                await MainActor.run { self?.records = records }
            },
            reportError: { [weak self] message in
                await MainActor.run { self?.errorMessage = message }
            }
        )
        return GitHubActionsJobEngine(
            dependencies: dependencies,
            maximumConcurrentRefreshes: maximumConcurrentRefreshes
        )
    }

    // MARK: Connection

    func recover() async {
        await engine.recover()
    }

    func loadConnection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            guard let token = try credentials.token() else {
                account = nil; repositories = []
                return
            }
            let loadedAccount = try await github.account(token: token)
            let loadedRepositories = try await github.repositories(token: token)
            account = loadedAccount
            repositories = loadedRepositories.map {
                GitHubActionsRepositorySelection(
                    id: $0.id, fullName: $0.fullName,
                    defaultBranch: $0.defaultBranch, isPrivate: $0.isPrivate
                )
            }
            errorMessage = nil
        } catch {
            account = nil
            repositories = []
            errorMessage = SecretRedactor.redact(error.localizedDescription)
        }
    }

    // MARK: Snapshot preview

    /// Bounded, recursive snapshot of the chosen project root (the workspace
    /// root, plus the active file's directory when it differs). Every
    /// directory page is followed, but the walk is capped by the snapshot
    /// policy's file count and depth so a mistaken selection cannot become an
    /// accidental full-disk upload. Symbolic links, non-regular files, secret
    /// paths and oversized files are excluded before any hashing, so a huge
    /// file is never read just to be rejected.
    @discardableResult
    func buildSnapshotPreview(
        root: URL,
        activePath: String,
        fileService: WorkspaceFileService
    ) -> GitHubActionsSnapshotPreview? {
        guard !activePath.isEmpty,
              IDELanguageRunPolicy.isSafeWorkspaceRelativePath(activePath) else {
            snapshotPreview = nil
            return nil
        }
        let parent = (activePath as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "." : parent
        do {
            let guardResolver = WorkspacePathGuard(
                rootURL: root,
                maxReadBytes: IDEGitHubActionsSnapshotPolicy.maximumFileBytes,
                maxWriteBytes: IDEGitHubActionsSnapshotPolicy.maximumTotalBytes
            )
            var candidates: [IDEGitHubActionsSnapshotCandidate] = []
            var seen = Set<String>()
            // Project root is the primary root; the active file's directory is
            // added so a file outside the default root is not silently missed.
            for scanned in [".", directory] where !scanned.isEmpty {
                Self.collectSnapshotCandidates(
                    directory: scanned, depth: 0,
                    fileService: fileService, guardResolver: guardResolver,
                    candidates: &candidates, seen: &seen
                )
            }
            let manifest = try IDEGitHubActionsSnapshotPolicy.manifest(candidates: candidates)
            let preview = GitHubActionsSnapshotPreview(directory: directory, manifest: manifest)
            snapshotPreview = preview
            return preview
        } catch {
            snapshotPreview = nil
            errorMessage = SecretRedactor.redact(snapshotErrorText(error))
            return nil
        }
    }

    /// Bounded breadth-first walk. `listDirectory` pages at 200 entries, so the
    /// page token is followed to completion for each directory; recursion is
    /// capped by depth and by the absolute candidate cap.
    private static func collectSnapshotCandidates(
        directory: String,
        depth: Int,
        fileService: WorkspaceFileService,
        guardResolver: WorkspacePathGuard,
        candidates: inout [IDEGitHubActionsSnapshotCandidate],
        seen: inout Set<String>
    ) {
        guard depth <= IDEGitHubActionsSnapshotPolicy.maximumDirectoryDepth else { return }
        guard candidates.count <= IDEGitHubActionsSnapshotPolicy.maximumFileCount else { return }
        var pageToken: String?
        var pages = 0
        repeat {
            pages += 1
            guard pages <= IDEGitHubActionsSnapshotPolicy.maximumDirectoryPages else { return }
            let page: DirectoryPage
            do {
                page = try fileService.listDirectory(
                    directory, pageToken: pageToken,
                    includeDirectories: true, includeFiles: true
                )
            } catch {
                return
            }
            for node in page.entries {
                guard candidates.count <= IDEGitHubActionsSnapshotPolicy.maximumFileCount else { return }
                guard !seen.contains(node.relativePath) else { continue }
                if node.isDirectory {
                    if IDEGitHubActionsSnapshotPolicy.isSnapshotSkipDirectory(node.name) { continue }
                    seen.insert(node.relativePath)
                    collectSnapshotCandidates(
                        directory: node.relativePath, depth: depth + 1,
                        fileService: fileService, guardResolver: guardResolver,
                        candidates: &candidates, seen: &seen
                    )
                    continue
                }
                // Inspect light metadata first so a symlink or an oversized
                // file is rejected before any hashing/reading occurs.
                guard let properties = try? guardResolver.resolve(node.relativePath)
                    .resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
                    continue
                }
                if properties.isSymbolicLink == true {
                    seen.insert(node.relativePath)
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: false, isSymlink: true,
                        byteCount: 0, sha256: ""
                    ))
                    continue
                }
                guard properties.isRegularFile == true else { continue }
                let byteCount = Int(properties.fileSize ?? 0)
                seen.insert(node.relativePath)
                if byteCount > IDEGitHubActionsSnapshotPolicy.maximumFileBytes {
                    // Reject by size without reading or hashing the file.
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: true, isSymlink: false,
                        byteCount: byteCount, sha256: ""
                    ))
                    continue
                }
                guard let meta = try? fileService.metadata(node.relativePath) else { continue }
                if meta.isSymlink {
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: false, isSymlink: true,
                        byteCount: 0, sha256: ""
                    ))
                    continue
                }
                candidates.append(IDEGitHubActionsSnapshotCandidate(
                    path: node.relativePath, isRegularFile: !meta.isDirectory,
                    isSymlink: meta.isSymlink, byteCount: Int(meta.size), sha256: meta.sha256
                ))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
    }

    private func snapshotErrorText(_ error: Error) -> String {
        if let typed = error as? IDEGitHubActionsSnapshotError {
            switch typed {
            case .empty: return "快照为空：所选目录没有可上传的普通文件。 / Snapshot is empty: the directory has no eligible files."
            case .tooManyFiles(let limit): return "快照文件数超过上限 \(limit)。 / Snapshot exceeds \(limit) files."
            case .totalTooLarge(let limit): return "快照总大小超过上限 \(limit) 字节。 / Snapshot exceeds \(limit) bytes."
            }
        }
        return error.localizedDescription
    }

    /// A GitHub 403 on workflow setup almost always means the login lacks the
    /// `workflow` scope (or the fine-grained token lacks Workflows write). Turn
    /// the bare status into a concrete reconnect / PAT instruction instead of
    /// silently reporting "request failed (403)".
    nonisolated static func workflowErrorText(_ error: Error) -> String {
        if case GitHubActionsError.http(let status, let message) = error, status == 403 {
            return "GitHub 拒绝了此工作流请求（403）。请重新登录并开启“允许配置 GitHub Actions 工作流”，或使用具备 Contents、Actions 与 Workflows 写入权限的细粒度令牌。已有凭据在重新登录前保持不变。 / GitHub denied this workflow request (403). Reconnect GitHub with “Allow GitHub Actions workflow setup”, or use a fine-grained token with Contents, Actions and Workflows write access. Existing credentials are unchanged until you sign in again. (\(message))"
        }
        return error.localizedDescription
    }

    // MARK: Workflow installation (explicit user action)

    /// Commits a Floe workflow template to the repository's **default branch**.
    /// This is the only way a template becomes dispatchable, because GitHub
    /// only exposes `workflow_dispatch` workflows that exist on the default
    /// branch. The write is fast-forward only and never overwrites a file with
    /// different content: a collision returns `.conflict` with a suggested
    /// Floe-owned path and, when `workspaceRoot` is supplied, exports the YAML
    /// into the workspace for review instead of touching the repository.
    func installWorkflow(
        template: IDEGitHubActionsWorkflowTemplate,
        repository: GitHubActionsRepositorySelection,
        workspaceRoot: URL? = nil
    ) async -> GitHubActionsWorkflowInstallResult? {
        isBusy = true
        defer { isBusy = false }
        do {
            guard let token = try credentials.token() else {
                throw GitHubActionsError.invalidConfiguration("connect GitHub in Settings first")
            }
            guard repository.id != 0, !repository.repository.isEmpty else {
                throw GitHubActionsError.invalidConfiguration("no repository selected")
            }
            let branch = repository.defaultBranch
            let existingPaths = (try? await actions.workflowFilePaths(
                owner: repository.owner, repository: repository.repository,
                ref: branch, token: token
            )) ?? []
            let existing = try await actions.fileContent(
                owner: repository.owner, repository: repository.repository,
                path: template.workflowPath, ref: branch, token: token
            )
            let templateSHA = FloeDigest.sha256Hex(Data(template.yaml.utf8))
            let decision = IDEGitHubActionsWorkflowInstallationPolicy.decision(
                existingSHA256: existing.map { FloeDigest.sha256Hex($0) },
                templateSHA256: templateSHA,
                templatePath: template.workflowPath,
                existingPaths: existingPaths
            )
            switch decision {
            case .alreadyInstalled:
                errorMessage = nil
                return GitHubActionsWorkflowInstallResult(
                    outcome: .alreadyInstalled, path: template.workflowPath,
                    templateID: template.id, yaml: template.yaml,
                    suggestedPath: nil, exportedRelativePath: nil
                )
            case .conflict(let suggested):
                var exported: String?
                if let workspaceRoot {
                    exported = try exportTemplate(template, workspaceRoot: workspaceRoot)
                }
                errorMessage = SecretRedactor.redact(
                    "\(template.workflowPath) already exists on \(branch) with different content. Floe did not overwrite it; use \(suggested) or export the template."
                )
                return GitHubActionsWorkflowInstallResult(
                    outcome: .conflict, path: template.workflowPath,
                    templateID: template.id, yaml: template.yaml,
                    suggestedPath: suggested, exportedRelativePath: exported
                )
            case .install:
                try await commitWorkflowFile(
                    template.yaml, path: template.workflowPath, branch: branch,
                    message: "Floe IDE: install \(template.id) workflow",
                    repository: repository, token: token
                )
                errorMessage = nil
                return GitHubActionsWorkflowInstallResult(
                    outcome: .installed, path: template.workflowPath,
                    templateID: template.id, yaml: template.yaml,
                    suggestedPath: nil, exportedRelativePath: nil
                )
            }
        } catch {
            errorMessage = SecretRedactor.redact(Self.workflowErrorText(error))
            return nil
        }
    }

    /// Writes one file to a branch as a fast-forward commit. `force` is never
    /// set, so GitHub refuses a non-fast-forward update rather than moving a
    /// user's branch backwards.
    private func commitWorkflowFile(
        _ yaml: String, path: String, branch: String, message: String,
        repository: GitHubActionsRepositorySelection, token: String
    ) async throws {
        let baseSHA = try await actions.refSHA(
            owner: repository.owner, repository: repository.repository,
            branch: branch, token: token
        )
        let baseTree = try await actions.commitTreeSHA(
            owner: repository.owner, repository: repository.repository,
            commitSHA: baseSHA, token: token
        )
        let blob = try await actions.createBlob(
            owner: repository.owner, repository: repository.repository,
            content: Data(yaml.utf8).base64EncodedString(), token: token
        )
        let tree = try await actions.createTree(
            owner: repository.owner, repository: repository.repository,
            baseTreeSHA: baseTree,
            entries: [GitHubActionsTreeEntry(path: path, sha: blob)], token: token
        )
        let identity = try await github.account(token: token)
        let commit = try await actions.createCommit(
            owner: repository.owner, repository: repository.repository,
            message: message, treeSHA: tree, parentSHAs: [baseSHA],
            authorName: identity.name ?? identity.login,
            authorEmail: "\(identity.login)@users.noreply.github.com",
            date: Date(), token: token
        )
        try await actions.updateRef(
            owner: repository.owner, repository: repository.repository,
            branch: branch, sha: commit, token: token
        )
    }

    /// Exports the template into the workspace for manual review (no network).
    private func exportTemplate(
        _ template: IDEGitHubActionsWorkflowTemplate, workspaceRoot: URL
    ) throws -> String {
        let file = template.workflowPath.split(separator: "/").last.map(String.init)
            ?? template.fileName
        let relative = ".floe/workflows/\(file)"
        guard IDELanguageRunPolicy.isSafeWorkspaceRelativePath(relative) else {
            throw GitHubActionsError.invalidConfiguration("unsafe export path")
        }
        let guardResolver = WorkspacePathGuard(
            rootURL: workspaceRoot,
            maxReadBytes: IDEGitHubActionsWorkflowCatalog.maximumTemplateBytes,
            maxWriteBytes: IDEGitHubActionsWorkflowCatalog.maximumTemplateBytes
        )
        let resolved = try guardResolver.resolve(relative)
        try guardResolver.assertWritable(resolved)
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staging = resolved.appendingPathExtension("staging")
        try Data(template.yaml.utf8).write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: resolved.path) {
            _ = try FileManager.default.replaceItemAt(resolved, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: resolved)
        }
        return relative
    }

    /// Registered workflows, which are exactly the ones GitHub will accept a
    /// `workflow_dispatch` for (they exist on the default branch).
    func registeredWorkflows(
        repository: GitHubActionsRepositorySelection
    ) async -> [GitHubActionsWorkflow] {
        do {
            guard let token = try credentials.token() else { return [] }
            return try await actions.workflows(
                owner: repository.owner, repository: repository.repository, token: token
            )
        } catch {
            errorMessage = SecretRedactor.redact(Self.workflowErrorText(error))
            return []
        }
    }

    // MARK: Dispatch

    /// Publish the snapshot, dispatch the workflow and associate a run.
    /// `requestID` is the idempotency key; passing the same id again returns
    /// the existing record instead of dispatching twice.
    @discardableResult
    func dispatch(
        plan: IDEGitHubActionsRunPlan,
        manifest: IDEGitHubActionsSnapshotManifest,
        workspaceRoot: URL,
        workspaceID: UUID,
        environmentID: String? = nil,
        requestID: String = String(UUID().uuidString.prefix(12)).lowercased()
    ) async -> GitHubActionsJobRecord? {
        isBusy = true
        defer { isBusy = false }
        guard let workflowPath = plan.workflowPath,
              IDEGitHubActionsWorkflowCatalog.isWorkflowPath(workflowPath) else {
            errorMessage = "Select a registered workflow or install the Floe template on the repository's default branch first."
            return nil
        }
        guard plan.repository.id != 0 else {
            errorMessage = "Select a repository first."
            return nil
        }
        let runBranch = IDEGitHubActionsSnapshotPolicy.runBranch(runToken: requestID)
        let floeTemplate = template(for: plan)
        let isFloeTemplate = plan.installsTemplate && floeTemplate?.workflowPath == workflowPath
        let draft = GitHubActionsJobRecord(
            requestID: requestID,
            workspaceID: workspaceID,
            environmentID: environmentID,
            workspaceRootPath: workspaceRoot.path,
            languageID: plan.languageID,
            role: plan.role.rawValue,
            repositoryFullName: plan.repository.fullName,
            owner: plan.repository.owner,
            repository: plan.repository.repository,
            baseRef: plan.ref,
            runBranch: runBranch,
            workflowPath: workflowPath,
            installsTemplate: isFloeTemplate,
            expectedArtifactName: plan.expectedArtifactName,
            snapshotCommitSHA: nil,
            snapshotTreeSHA: nil,
            snapshotFiles: manifest.entries.map {
                GitHubActionsSnapshotEntryRecord(path: $0.path, byteCount: $0.byteCount, sha256: $0.sha256)
            },
            snapshotTotalBytes: manifest.totalBytes,
            state: .preparing
        )
        let actions = self.actions
        let github = self.github
        let defaultBranch = plan.repository.defaultBranch
        let baseRef = plan.ref
        let record = await engine.dispatch(
            draft: draft,
            workflowPath: workflowPath,
            inputs: plan.dispatchInputs,
            injectSnapshotInput: isFloeTemplate,
            resolveWorkflow: { owner, repository, path, token in
                for attempt in 0..<5 {
                    if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
                    let workflows = try await actions.workflows(owner: owner, repository: repository, token: token)
                    if let match = workflows.first(where: { $0.path == path }) { return match.id }
                }
                return nil
            },
            publishSnapshot: { record, token in
                try await Self.publishSnapshot(
                    record: record, manifest: manifest, workspaceRoot: workspaceRoot,
                    baseRef: baseRef, defaultBranch: defaultBranch,
                    actions: actions, github: github, token: token
                )
            }
        )
        if record == nil, errorMessage == nil {
            errorMessage = "GitHub Actions dispatch failed."
        }
        return record
    }

    /// Publishes exactly the reviewed manifest as a commit on the run-owned
    /// branch and returns its identity. Defined as a nonisolated static so the
    /// engine can call it off the main actor.
    nonisolated private static func publishSnapshot(
        record: GitHubActionsJobRecord,
        manifest: IDEGitHubActionsSnapshotManifest,
        workspaceRoot: URL,
        baseRef: String,
        defaultBranch: String,
        actions: GitHubActionsClient,
        github: GitHubService,
        token: String
    ) async throws -> GitHubActionsPublishedSnapshot {
        let baseSHA = try await actions.refSHA(
            owner: record.owner, repository: record.repository, branch: baseRef, token: token
        )
        let baseTreeSHA = try await actions.commitTreeSHA(
            owner: record.owner, repository: record.repository, commitSHA: baseSHA, token: token
        )
        let guardResolver = WorkspacePathGuard(
            rootURL: workspaceRoot,
            maxReadBytes: IDEGitHubActionsSnapshotPolicy.maximumFileBytes,
            maxWriteBytes: IDEGitHubActionsSnapshotPolicy.maximumTotalBytes
        )
        var treeEntries: [GitHubActionsTreeEntry] = []
        for entry in manifest.entries {
            let url = try guardResolver.resolve(entry.path)
            let data = try IDERunSourceReader.readRegularFile(
                at: url, maxBytes: IDEGitHubActionsSnapshotPolicy.maximumFileBytes
            )
            guard IDELanguageRunPolicy.sourceRevisionMatches(
                pinnedSHA256: entry.sha256, observedSHA256: FloeDigest.sha256Hex(data)
            ) else {
                throw GitHubActionsError.invalidConfiguration("snapshot file changed during publish: \(entry.path)")
            }
            let blobSHA = try await actions.createBlob(
                owner: record.owner, repository: record.repository,
                content: data.base64EncodedString(), token: token
            )
            treeEntries.append(GitHubActionsTreeEntry(path: entry.path, sha: blobSHA))
        }
        // Carry the workflow file on the run ref too, so a run branch built
        // from a non-default base branch still resolves it.
        if let workflowPath = record.workflowPath,
           let workflowData = try await actions.fileContent(
               owner: record.owner, repository: record.repository,
               path: workflowPath, ref: defaultBranch, token: token
           ) {
            let blobSHA = try await actions.createBlob(
                owner: record.owner, repository: record.repository,
                content: workflowData.base64EncodedString(), token: token
            )
            treeEntries.append(GitHubActionsTreeEntry(path: workflowPath, sha: blobSHA))
        }
        let treeSHA = try await actions.createTree(
            owner: record.owner, repository: record.repository,
            baseTreeSHA: baseTreeSHA, entries: treeEntries, token: token
        )
        let identity = try await github.account(token: token)
        let authorName = identity.name ?? identity.login
        let commitSHA = try await actions.createCommit(
            owner: record.owner, repository: record.repository,
            message: "Floe IDE snapshot \(record.requestID)",
            treeSHA: treeSHA, parentSHAs: [baseSHA],
            authorName: authorName,
            authorEmail: "\(identity.login)@users.noreply.github.com",
            date: Date(), token: token
        )
        try await actions.createRef(
            owner: record.owner, repository: record.repository,
            ref: "refs/heads/\(record.runBranch)", sha: commitSHA, token: token
        )
        return GitHubActionsPublishedSnapshot(commitSHA: commitSHA, treeSHA: treeSHA)
    }

    private func template(for plan: IDEGitHubActionsRunPlan) -> IDEGitHubActionsWorkflowTemplate? {
        IDEGitHubActionsWorkflowCatalog.template(
            languageID: plan.languageID, role: plan.role, platform: plan.runnerPlatform
        )
    }

    // MARK: Scene lifecycle

    /// A SwiftUI scene changed phase. `sceneID` is the window's stable identity;
    /// the engine starts polling only when the first scene becomes active and
    /// pauses only when the last active scene leaves the foreground.
    func scenePhaseChanged(active: Bool, sceneID: String) {
        Task { [weak self] in
            guard let self else { return }
            if active {
                await self.engine.sceneDidActivate(id: sceneID)
            } else {
                await self.engine.sceneDidDeactivate(id: sceneID)
            }
        }
    }

    func sceneDidDisappear(sceneID: String) {
        Task { [weak self] in await self?.engine.sceneDidDisappear(id: sceneID) }
    }

    /// Legacy single-scene entry point; kept so callers that do not track a
    /// window identity still behave correctly.
    func handleScenePhase(active: Bool) {
        scenePhaseChanged(active: active, sceneID: "app")
    }

    // MARK: Public refresh / cancel / logs / artifacts

    func refresh(recordID: UUID) async {
        isBusy = true
        defer { isBusy = false }
        _ = await engine.refreshOne(id: recordID, reason: .explicit)
    }

    /// Reconciles one record after a relaunch without dispatching anything.
    func reconcile(recordID: UUID) async {
        isBusy = true
        defer { isBusy = false }
        if let record = records.first(where: { $0.id == recordID }),
           IDEGitHubActionsReconciler.actions(for: record).contains(where: {
               if case .awaitingManualRedispatch = $0 { return true }
               return false
           }) {
            errorMessage = "No snapshot was published for this request. Nothing was dispatched; start a new run to continue."
        }
        _ = await engine.refreshOne(id: recordID, reason: .explicit)
    }

    func cancel(recordID: UUID) async {
        isBusy = true
        defer { isBusy = false }
        await engine.cancel(recordID: recordID)
    }

    func jobs(recordID: UUID) async -> [GitHubActionsJob] {
        do {
            guard let record = try await store.record(id: recordID),
                  let runID = record.runID,
                  let token = try credentials.token() else { return [] }
            return try await actions.jobs(
                owner: record.owner, repository: record.repository, runID: runID, token: token
            )
        } catch {
            errorMessage = SecretRedactor.redact(error.localizedDescription)
            return []
        }
    }

    func jobLog(recordID: UUID, jobID: Int64) async -> GitHubActionsLogSlice? {
        do {
            guard let record = try await store.record(id: recordID),
                  let token = try credentials.token() else { return nil }
            return try await actions.jobLog(
                owner: record.owner, repository: record.repository, jobID: jobID, token: token
            )
        } catch {
            errorMessage = SecretRedactor.redact(error.localizedDescription)
            return nil
        }
    }

    func loadArtifacts(recordID: UUID) async {
        await engine.loadArtifacts(recordID: recordID)
    }

    /// Downloads one artifact, verifies its SHA-256 and commits it through the
    /// workspace path guard. A failure leaves any existing file untouched, and
    /// the record keeps its download state across relaunches.
    @discardableResult
    func downloadArtifact(
        recordID: UUID, artifact: GitHubActionsArtifactRecord,
        workspaceRoot: URL, overwrite: Bool
    ) async -> GitHubActionsArtifactRecord? {
        isBusy = true
        defer { isBusy = false }
        let runID = records.first(where: { $0.id == recordID })?.runID ?? 0
        return await engine.downloadArtifact(
            recordID: recordID, artifactID: artifact.id,
            workspaceRunID: runID, workspaceRoot: workspaceRoot, overwrite: overwrite
        )
    }

    /// Verifies the downloaded bytes match the record's expected digest and
    /// commits them with a staged write, so a failure never clobbers a user
    /// file. Runs off the main actor because artifact bytes are large.
    nonisolated private static func commitArtifact(
        data: Data, relativePath: String, overwrite: Bool, workspaceRoot: URL
    ) throws -> String {
        let guardResolver = WorkspacePathGuard(
            rootURL: workspaceRoot,
            maxReadBytes: IDEGitHubActionsArtifactPolicy.maximumArtifactBytes,
            maxWriteBytes: IDEGitHubActionsArtifactPolicy.maximumArtifactBytes
        )
        let resolved = try guardResolver.resolve(relativePath)
        try guardResolver.assertWritable(resolved)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: resolved.path), !overwrite {
            throw GitHubActionsError.invalidConfiguration(
                "\(relativePath) already exists; enable overwrite to replace it"
            )
        }
        try fileManager.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staging = resolved.appendingPathExtension("staging")
        try data.write(to: staging, options: .atomic)
        if fileManager.fileExists(atPath: resolved.path) {
            _ = try fileManager.replaceItemAt(resolved, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: resolved)
        }
        return relativePath
    }

    func record(id: UUID) -> GitHubActionsJobRecord? {
        records.first { $0.id == id }
    }

    /// Workflow files that exist on `ref`, for an explicit user selection. An
    /// unavailable or unauthenticated state returns an empty list rather than
    /// pretending a workflow exists.
    func workflowPaths(repository: GitHubActionsRepositorySelection, ref: String) async -> [String] {
        do {
            guard let token = try credentials.token() else { return [] }
            return try await actions.workflowFilePaths(
                owner: repository.owner, repository: repository.repository, ref: ref, token: token
            )
        } catch {
            errorMessage = SecretRedactor.redact(error.localizedDescription)
            return []
        }
    }

    func records(workspaceID: UUID) -> [GitHubActionsJobRecord] {
        records.filter { $0.workspaceID == workspaceID }
    }

    /// Template for a language/role, exposed so the UI can show the exact YAML
    /// before it is installed on a run branch.
    func template(
        languageID: String, role: IDEGitHubActionsRunRole, platform: GitHubActionsRunnerPlatform
    ) -> IDEGitHubActionsWorkflowTemplate? {
        IDEGitHubActionsWorkflowCatalog.template(languageID: languageID, role: role, platform: platform)
    }

    func clearError() { errorMessage = nil }

    private func publish(_ record: GitHubActionsJobRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
    }
}

// MARK: - Credential seam

private struct CenterCredentialProvider: GitHubActionsTokenProviding {
    let store: GitHubCredentialStore
    func token() async throws -> String? { try store.token() }
}

// MARK: - Remote adapter (maps FloeGit onto the engine's transport-neutral API)

private struct CenterGitHubActionsRemote: GitHubActionsRemoteClient {
    let actions: GitHubActionsClient

    func queryRun(owner: String, repository: String, runID: Int64, token: String) async throws -> GitHubActionsRemoteRun {
        do {
            let run = try await actions.run(owner: owner, repository: repository, runID: runID, token: token)
            return Self.observe(run)
        } catch { throw Self.map(error) }
    }

    func associateRun(
        owner: String, repository: String, workflowID: Int64, ref: String, headSHA: String,
        dispatchedAt: Date, baselineRunIDs: [Int64], returnedRunID: Int64?,
        token: String, maxAttempts: Int, pollInterval: TimeInterval
    ) async throws -> GitHubActionsRemoteRun {
        let receipt = GitHubActionsDispatchReceipt(
            owner: owner, repository: repository, workflowID: workflowID, ref: ref,
            headSHA: headSHA, dispatchedAt: dispatchedAt,
            baselineRunIDs: Set(baselineRunIDs), returnedRunID: returnedRunID
        )
        do {
            let run = try await actions.associateRun(
                receipt, token: token, maxAttempts: maxAttempts, pollInterval: pollInterval
            )
            return Self.observe(run)
        } catch { throw Self.map(error) }
    }

    func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws {
        do {
            try await actions.cancelRun(owner: owner, repository: repository, runID: runID, token: token)
        } catch { throw Self.map(error) }
    }

    func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GitHubActionsRemoteArtifact] {
        do {
            return try await actions.artifacts(owner: owner, repository: repository, runID: runID, token: token)
                .map {
                    GitHubActionsRemoteArtifact(
                        id: $0.id, name: $0.name, sizeInBytes: $0.sizeInBytes,
                        expired: $0.expired, createdAt: $0.createdAt, expiresAt: $0.expiresAt,
                        digest: $0.digest
                    )
                }
        } catch { throw Self.map(error) }
    }

    func downloadArtifact(
        owner: String, repository: String, runID: Int64, artifactID: Int64,
        name: String, sizeInBytes: Int64, archiveURL: URL, token: String
    ) async throws -> GitHubActionsRemoteArtifactBytes {
        let artifact = GitHubActionsArtifact(
            id: artifactID, name: name, sizeInBytes: sizeInBytes, expired: false,
            archiveDownloadURL: archiveURL, createdAt: Date(), expiresAt: nil
        )
        do {
            let download = try await actions.downloadArtifact(artifact: artifact, token: token)
            return GitHubActionsRemoteArtifactBytes(
                data: download.data, suggestedFileName: download.suggestedFileName
            )
        } catch { throw Self.map(error) }
    }

    func dispatchBaseline(
        owner: String, repository: String, workflowID: Int64, branch: String, token: String
    ) async throws -> GitHubActionsRemoteBaseline {
        do {
            let baseline = try await actions.dispatchBaseline(
                owner: owner, repository: repository, workflowID: workflowID, branch: branch, token: token
            )
            return GitHubActionsRemoteBaseline(runIDs: baseline.runIDs.sorted(), capturedAt: baseline.capturedAt)
        } catch { throw Self.map(error) }
    }

    func triggerDispatch(
        owner: String, repository: String, workflowID: Int64, ref: String,
        inputs: [String: String], token: String
    ) async throws -> GitHubActionsRemoteTrigger {
        do {
            let trigger = try await actions.triggerDispatch(
                owner: owner, repository: repository, workflowID: workflowID,
                ref: ref, inputs: inputs, token: token
            )
            return GitHubActionsRemoteTrigger(runID: trigger.runID, htmlURL: trigger.htmlURL?.absoluteString)
        } catch { throw Self.map(error) }
    }

    private static func observe(_ run: GitHubActionsRun) -> GitHubActionsRemoteRun {
        GitHubActionsRemoteRun(
            id: run.id, status: run.status, conclusion: run.conclusion,
            htmlURL: run.htmlURL?.absoluteString
        )
    }

    static func map(_ error: Error) -> GitHubActionsEngineError {
        if GitHubActionsClient.isRateLimited(error) { return .rateLimited }
        if let typed = error as? GitHubActionsError {
            switch typed {
            case .invalidConfiguration(let detail): return .invalidConfiguration(detail)
            case .transport(let detail): return .transport(detail)
            case .http(let status, let message):
                if status == 403 {
                    return .invalidConfiguration(GitHubActionsJobCenter.workflowErrorText(typed))
                }
                return .http(status: status, message: message)
            case .decoding(let detail): return .transport("unexpected GitHub response: \(detail)")
            case .responseTooLarge(let limit): return .responseTooLarge(limit: limit)
            case .associationUnresolved(let detail): return .unresolved(detail)
            case .redirectWithoutLocation: return .transport("download redirect had no destination")
            }
        }
        return .transport(error.localizedDescription)
    }
}
#endif

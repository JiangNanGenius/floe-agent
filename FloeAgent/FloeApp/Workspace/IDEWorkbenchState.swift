// SPDX-License-Identifier: MPL-2.0
//
// IDEWorkbenchState.swift — run-flow companion to `IDEWorkbenchState`
// (declared in IDEWorkbenchWebView.swift). This file owns the observable
// controller that turns a pure `IDELanguageRunPolicy` plan into a dispatch
// into an owned execution session:
//
// * the snapshot is flushed first and a conflict aborts the run outright;
// * one attempt generation is created before the first await and compared
//   after every save/probe/stage await and before every side effect, so Stop
//   during preparation blocks the later dispatch and a delayed completion or
//   cleanup from an earlier attempt can never overwrite newer state;
// * the workspace, root, active path and saved source revision are captured
//   before the first await and re-checked after every save/probe/stage
//   await, so a concurrent workspace switch or edit cannot redirect a run;
// * local runs open a *run-owned* `ShellSessionCenter` session pinned to the
//   workspace root (cwd ".", explicit empty environment, explicit project
//   tool environment resolved and ownership-validated for this exact root).
//   The user's reused terminal is never written into, so a prior `cd` cannot
//   make a relative script resolve to the wrong file, and Ctrl-C only ever
//   interrupts this run's session. A routing/ownership failure fails closed
//   instead of opening the session against an unknown layer;
// * remote runs read the saved file through the resolved workspace guard with
//   a bounded allocation, prove its SHA-256 equals the pinned revision, and
//   stage the exact bytes through the host's Floe remote agent
//   (`IDERunSourceStager`: write marker + source, read back, compare SHA-256
//   and full bytes). An abort after staging but before the execution trap runs
//   a marker-guarded cleanup that only removes this attempt's own directory
//   and reports an unproven outcome instead of assuming success;
// * closing the SSH client on cancellation/timeout is not proof the remote
//   process exited or its trap ran, so the status distinguishes a stop
//   request from a confirmed remote completion.
//
// It deliberately contains no command construction: all argv/quoting lives in
// `IDELanguageRunPolicy`, and all transfer verification in
// `IDERunSourceStaging`.

#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeExecution
import FloeGit
import FloeSSH
import FloeTools
import FloeWorkspace

extension IDEWorkbenchState {
    /// True only when every dirty editor model has been written to disk and no
    /// unresolved conflict remains. The run button refuses to dispatch unless
    /// this holds, so a run never executes a stale snapshot.
    var isCleanForDispatch: Bool {
        ready && !saving && !dirty && conflict == nil
    }
}

/// User-facing run outcome. Reasons stay as typed values; the view localizes
/// them so no English string is baked into dispatch logic.
enum IDELanguageRunStatus: Sendable, Equatable {
    case idle
    /// A run is being prepared (snapshot, probe, staging) before anything is
    /// dispatched. Stop is available and invalidates this attempt.
    case preparing
    case blocked(IDELanguageRunUnavailableReason)
    case probeFailed(tool: String)
    case probeError
    case terminalUnavailable
    /// The project tool environment for the pinned workspace root could not be
    /// resolved (routing/ownership failure). The local run fails closed and no
    /// terminal session is opened against an unknown layer.
    case projectToolEnvironmentUnavailable
    case remoteHostUnavailable
    /// The paired host has no reachable Floe remote agent, so the verified
    /// staging transport is unavailable.
    case remoteStagingUnavailable
    /// Verified staging failed; carries the typed reason.
    case stagingFailed(IDERunStagingFailure)
    /// The run aborted before execution and the marker-guarded cleanup did not
    /// prove the outcome. The run-owned directory may remain and is named so
    /// the user can recover it manually; foreign data is never deleted.
    case stagingCleanupUnconfirmed(stagingRoot: String, stageFailure: IDERunStagingFailure?)
    case workspaceChanged
    case runningLocal
    case runningRemote
    /// Preparation was cancelled. Executable probes or source transfers may
    /// already have happened; this does not claim that a process was stopped.
    /// An in-flight local open is closed when its result becomes available.
    case cancelledPreparation
    /// The run-owned local session ended; `exitCode` is nil when the backend
    /// could not report one (an observed completion with unknown status).
    case finishedLocal(exitCode: Int32?)
    /// The bounded remote execution returned on the SSH channel; the exit code
    /// was observed.
    case finishedRemote(exitCode: Int32)
    /// The bounded remote execution exceeded its time budget and the SSH
    /// client was closed. Closing the client is not proof the remote child
    /// exited or that the run's cleanup trap ran.
    case remoteRunTimedOut
    /// The user stopped the run-owned local session.
    case stoppedLocal
    /// Cancellation was requested for the dispatched remote run (its SSH
    /// execution token was cancelled). The client close is only *observed*
    /// when the exec throws `SSHExecError.cancelled`; the remote process exit
    /// and the run's cleanup trap are never observed, so no "stopped" claim is
    /// made and the SSH close is not asserted merely from the token cancel.
    case stopRequestedRemote
    /// A GitHub Actions snapshot is being published and the workflow
    /// dispatched. The trigger is a remote API call, not a local process.
    case gitHubActionsPreparing
    /// The workflow was dispatched. `runID` is nil when GitHub's 204 carried
    /// no run id and association is still in progress; the durable record (not
    /// this transient status) is the source of truth.
    case gitHubActionsDispatched(runID: Int64?)
    /// The dispatch succeeded but no unique run could be associated yet. The
    /// snapshot and baseline are retained; no duplicate dispatch is made.
    case gitHubActionsAssociationPending
    /// A stop was requested. GitHub finalizes cancellation asynchronously, so
    /// the durable record keeps reconciling until the run is `cancelled`.
    case gitHubActionsCancelRequested
    /// A local GitHub Actions failure before/around dispatch; the durable
    /// record keeps the detail.
    case gitHubActionsFailed(String)
}

@MainActor
final class IDELanguageRunController: ObservableObject {
    @Published private(set) var hosts: [IDELanguageRunHost] = []
    @Published private(set) var capabilities = IDELanguageRunCapabilities()
    @Published var selection = IDELanguageRunSelection()
    @Published private(set) var plan: IDELanguageRunPlan = .unavailable(.noActiveFile)
    @Published private(set) var status: IDELanguageRunStatus = .idle
    @Published private(set) var dispatching = false
    @Published private(set) var dispatchedCommandLine: String?
    /// Bounded observed output of the current run (local session stream or
    /// the captured remote result), for the run terminal surface.
    @Published private(set) var runOutput = Data()
    @Published private(set) var localRunSessionID: String?

    /// GitHub Actions state is owned by the app-level `GitHubActionsJobCenter`
    /// so a dispatched run survives this controller (and the IDE view) being
    /// dismissed. The controller only tracks the record it started.
    let gitHubActions = GitHubActionsJobCenter.shared
    @Published private(set) var gitHubRepositories: [GitHubActionsRepositorySelection] = []
    @Published private(set) var gitHubWorkflowPaths: [String] = []
    @Published private(set) var gitHubActionsPreview: GitHubActionsSnapshotPreview?
    @Published private(set) var activeGitHubActionsRecordID: UUID?

    /// Set by the IDE so a successful dispatch can reveal the run-owned
    /// output surface. Used for both local and remote runs.
    var onRequestRunTerminal: (() -> Void)?

    private let workspaceID: UUID
    private let root: URL?
    private let center: WorkspaceCenter
    private weak var state: IDEWorkbenchState?
    private var runToken = "preview"
    /// Stable run identity for every session this controller owns. The shell
    /// center scopes signal/close to this ID, so an unrelated terminal session
    /// can never be interrupted.
    private let runID = UUID()
    private var localMonitor: Task<Void, Never>?
    /// Cancellation handle for the bounded remote execution. Owned by this
    /// controller; cancelling it never touches another host session.
    private var remoteCancellation: CancellationToken?
    /// Per-attempt cancellation for the whole preparation + run lifecycle.
    /// Created in `beginAttempt` before the first await and cancelled by
    /// `stop()`, so an in-flight probe, executable probe, verified transfer or
    /// session open observes the stop. A *new* dispatch creates a fresh token,
    /// so a superseded attempt's token can never affect a newer run.
    private var attemptCancellation: CancellationToken?
    private let maximumRunOutputBytes = 1024 * 1024
    /// Maximum source bytes staged for one remote run. Enforced before any
    /// allocation in `readPinnedSource` and again by the stager.
    private let maximumSourceBytes = 1_048_576
    /// Time budget for one remote compile+run. IDE Run is a finite
    /// execution; a user-owned preview service is a different feature and
    /// must not be started or killed here.
    private let remoteRunTimeout: TimeInterval = 900
    private let remoteRunMaxOutputBytes = 256 * 1024
    /// Monotonic per-dispatch generation. `beginAttempt` increments it; every
    /// asynchronous completion compares its captured generation before writing
    /// observable state, so an earlier attempt can never overwrite a newer one.
    private var generation = 0
    /// The attempt currently being prepared or executed.
    private var activeAttempt: IDELanguageRunAttempt?
    /// Generation for which the user requested a stop. Kept separate from
    /// `generation` so status/cleanup detail for the stopped attempt is still
    /// reported while a *new* dispatch (which increments `generation`) safely
    /// supersedes it.
    private var stopRequestedGeneration: Int?

    init(workspaceID: UUID, root: URL?, center: WorkspaceCenter, state: IDEWorkbenchState) {
        self.workspaceID = workspaceID
        self.root = root
        self.center = center
        self.state = state
    }

    deinit {
        // A closed IDE must not leave the monitor retaining this controller
        // or a remote execution running without an owner.
        localMonitor?.cancel()
        remoteCancellation?.cancel()
        attemptCancellation?.cancel()
    }

    var isRunning: Bool {
        switch status {
        case .runningLocal, .runningRemote,
             .gitHubActionsDispatched, .gitHubActionsAssociationPending:
            return true
        default:
            return false
        }
    }

    var isPreparing: Bool {
        if case .preparing = status { return true }
        return false
    }

    /// Stop is offered during preparation (nothing is dispatched yet) and
    /// during execution, so a run can always be invalidated before its side
    /// effects land.
    var canStop: Bool { isRunning || isPreparing }

    var canDispatch: Bool {
        guard plan.isAvailable, !dispatching, !isRunning, state?.activePath != nil else {
            return false
        }
        // A cloud run needs a dispatchable workflow. Installing the Floe
        // template on the default branch (or picking a registered one) is an
        // explicit step, so the Run button stays disabled until it is done.
        if case .githubActions = selection.target {
            return !(selection.target.gitHubActionsWorkflowPath ?? "").isEmpty
        }
        return true
    }

    /// The durable record for the GitHub Actions run this controller started,
    /// if any. The app-level center owns it, so it survives this sheet.
    var gitHubActiveRecord: GitHubActionsJobRecord? {
        guard let id = activeGitHubActionsRecordID else { return nil }
        return gitHubActions.record(id: id)
    }

    /// Every GitHub Actions record for this workspace, newest first.
    var gitHubWorkspaceRecords: [GitHubActionsJobRecord] {
        gitHubActions.records(workspaceID: workspaceID)
    }

    // MARK: Loading

    func prepare() async {
        await center.environment.remoteSessionCenter.loadHosts()
        let profiles = center.environment.remoteSessionCenter.hosts
        hosts = profiles.map { IDELanguageRunHost(id: $0.id, name: $0.displayName) }
        await refreshCapabilities()
        preselectConfiguredHostIfNeeded(profiles: profiles)
        refreshPlan()
    }

    /// Called when the run target changes. Selecting GitHub Actions loads the
    /// connected account's repositories and the reviewable snapshot; the
    /// existing local/SSH plan is untouched.
    func selectionDidChange() async {
        refreshPlan()
        if case .githubActions = selection.target {
            if gitHubRepositories.isEmpty {
                await gitHubActions.loadConnection()
                gitHubRepositories = gitHubActions.repositories
            }
            rebuildGitHubActionsPreview()
            await loadGitHubWorkflowPaths()
        } else {
            gitHubActionsPreview = nil
        }
    }

    private func rebuildGitHubActionsPreview() {
        // The file service is created only while a workspace root is open, so
        // its absence is the same "no preview yet" state as a missing root.
        guard let root,
              center.currentWorkspace?.id == workspaceID, center.currentRootURL == root,
              let path = state?.activePath, !path.isEmpty,
              let fileService = center.fileService else {
            gitHubActionsPreview = nil
            return
        }
        gitHubActionsPreview = gitHubActions.buildSnapshotPreview(
            root: root, activePath: path, fileService: fileService
        )
    }

    /// Loads the repository's registered workflows. These are exactly the ones
    /// GitHub accepts a `workflow_dispatch` for, because they exist on the
    /// default branch.
    func loadGitHubWorkflowPaths() async {
        guard let repository = selection.target.repository else {
            gitHubWorkflowPaths = []
            return
        }
        let registered = await gitHubActions.registeredWorkflows(repository: repository)
        gitHubWorkflowPaths = registered.map(\.path).sorted()
    }

    /// Explicit install of the Floe template for the active language on the
    /// selected repository's default branch. The whole default branch must
    /// grow a workflow file before `workflow_dispatch` can see it.
    func installGitHubWorkflowTemplate() async {
        guard let repository = selection.target.repository,
              let path = state?.activePath,
              let definition = IDELanguageRunPolicy.definition(forRelativePath: path),
              let role = IDELanguageRunPolicy.gitHubActionsRole(for: definition.id) else {
            return
        }
        let platform: GitHubActionsRunnerPlatform = definition.id == "swift" ? .macOS : .linux
        guard let template = gitHubActions.template(
            languageID: definition.id, role: role, platform: platform
        ) else { return }
        let result = await gitHubActions.installWorkflow(
            template: template, repository: repository, workspaceRoot: root
        )
        if let result, result.isUsable {
            setGitHubWorkflowPath(result.path)
            await loadGitHubWorkflowPaths()
        }
    }

    /// Current template for the active language, for the review/export UI.
    var gitHubTemplate: IDEGitHubActionsWorkflowTemplate? {
        guard let path = state?.activePath,
              let definition = IDELanguageRunPolicy.definition(forRelativePath: path),
              let role = IDELanguageRunPolicy.gitHubActionsRole(for: definition.id) else {
            return nil
        }
        let platform: GitHubActionsRunnerPlatform = definition.id == "swift" ? .macOS : .linux
        return gitHubActions.template(languageID: definition.id, role: role, platform: platform)
    }

    // MARK: GitHub Actions selection

    func setGitHubRepository(_ repository: GitHubActionsRepositorySelection) {
        selection.target = .githubActions(
            repository: repository,
            ref: selection.target.gitHubActionsRef,
            workflowPath: selection.target.gitHubActionsWorkflowPath
        )
    }

    func setGitHubRef(_ ref: String?) {
        guard let repository = selection.target.repository else { return }
        let trimmed = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        selection.target = .githubActions(
            repository: repository,
            ref: (trimmed?.isEmpty == false) ? trimmed : nil,
            workflowPath: selection.target.gitHubActionsWorkflowPath
        )
    }

    func setGitHubWorkflowPath(_ path: String?) {
        guard let repository = selection.target.repository else { return }
        selection.target = .githubActions(
            repository: repository,
            ref: selection.target.gitHubActionsRef,
            workflowPath: path
        )
    }

    func refreshGitHubRecord(_ recordID: UUID) async {
        await gitHubActions.refresh(recordID: recordID)
    }

    func reconcileGitHubRecord(_ recordID: UUID) async {
        await gitHubActions.reconcile(recordID: recordID)
    }

    func cancelGitHubRecord(_ recordID: UUID) async {
        await gitHubActions.cancel(recordID: recordID)
    }

    func loadGitHubArtifacts(_ recordID: UUID) async {
        await gitHubActions.loadArtifacts(recordID: recordID)
    }

    func gitHubJobLog(recordID: UUID, jobID: Int64) async -> GitHubActionsLogSlice? {
        await gitHubActions.jobLog(recordID: recordID, jobID: jobID)
    }

    func gitHubJobs(recordID: UUID) async -> [GitHubActionsJob] {
        await gitHubActions.jobs(recordID: recordID)
    }

    @discardableResult
    func downloadGitHubArtifact(
        recordID: UUID, artifact: GitHubActionsArtifactRecord, overwrite: Bool
    ) async -> GitHubActionsArtifactRecord? {
        guard let root else { return nil }
        return await gitHubActions.downloadArtifact(
            recordID: recordID, artifact: artifact, workspaceRoot: root, overwrite: overwrite
        )
    }

    func refreshCapabilities() async {
        var interpreters: Set<IDELanguageLocalInterpreter> = [.shell]
        let registry = FloeShellCommandRegistry.shared
        if registry.python != nil { interpreters.insert(.python3) }
        if IOSSystemNodeRuntime.shared.isAvailable { interpreters.insert(.node) }
        if let store = registry.wasm {
            // The catalog carries the canonical `floe-*` command; the bare
            // `lua` name is only the shell alias. Resolve the catalog identity
            // first, otherwise Lua is never reported as installed.
            let commands = store.catalog.packages.map(\.command)
            if let matched = IDELanguageRunPolicy.matchingWasmEntryCommand(for: .lua, catalogCommands: commands),
               let entry = store.catalog.packages.first(where: { $0.command == matched }) {
                let installed = await store.installedIDs()
                if installed.contains(entry.id) { interpreters.insert(.lua) }
            }
        }
        capabilities = IDELanguageRunCapabilities(
            localInterpreters: interpreters,
            mapping: mapping(for: selection.target.hostID)
        )
    }

    /// The workspace's `activeTarget` host is an explicit project setting, so
    /// when the active language has no usable local runtime we default the
    /// target to that pinned host — never to the first host in the list.
    private func preselectConfiguredHostIfNeeded(profiles: [RemoteHostProfile]) {
        guard case .local = selection.target,
              let path = state?.activePath,
              let definition = IDELanguageRunPolicy.definition(forRelativePath: path),
              let configuredID = center.currentWorkspace?.activeTarget.hostID,
              let profile = profiles.first(where: { $0.id == configuredID }) else { return }
        if let interpreter = definition.localInterpreter, capabilities.localInterpreters.contains(interpreter) {
            return
        }
        selection.target = .remote(hostID: profile.id, hostName: profile.displayName)
    }

    // MARK: Planning

    func refreshPlan() {
        capabilities.mapping = mapping(for: selection.target.hostID)
        plan = IDELanguageRunPolicy.plan(request())
    }

    private func request() -> IDELanguageRunRequest {
        IDELanguageRunRequest(
            relativePath: state?.activePath ?? "",
            selection: selection,
            capabilities: capabilities,
            runToken: runToken
        )
    }

    /// A configured project remote mapping is a cloud-workspace link on the
    /// selected host (host + remote path) whose `Cloud/<name>` marker lives in
    /// *this* pinned workspace root and owns the active file. A host match alone
    /// must never select another workspace's link, so the candidate list is
    /// built only while the pinned workspace/root is still current.
    private func mapping(for hostID: UUID?) -> IDELanguageRunRemoteMapping? {
        guard let hostID else { return nil }
        return IDELanguageRunPolicy.selectRemoteMapping(
            candidates: mappingCandidates(),
            hostID: hostID,
            activePath: state?.activePath ?? ""
        )
    }

    private func mappingCandidates() -> [IDELanguageRunMappingCandidate] {
        guard let root,
              center.currentWorkspace?.id == workspaceID,
              center.currentRootURL == root else { return [] }
        let cloudRoot = root.appendingPathComponent("Cloud", isDirectory: true)
        return center.cloudWorkspaceLinks.map { link in
            let marker = cloudRoot.appendingPathComponent(link.name, isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            return IDELanguageRunMappingCandidate(
                name: link.name,
                hostID: link.hostID,
                remotePath: link.remotePath,
                belongsToPinnedWorkspace: exists
            )
        }
    }

    // MARK: Dispatch

    func dispatch() async {
        guard !dispatching, let state else { return }
        guard let root else {
            status = .workspaceChanged
            return
        }
        guard center.currentWorkspace?.id == workspaceID, center.currentRootURL == root else {
            // The IDE pins one workspace; a changed global workspace must not
            // silently redirect a run.
            status = .workspaceChanged
            return
        }
        let path = state.activePath ?? ""
        guard !path.isEmpty else {
            plan = .unavailable(.noActiveFile)
            status = .blocked(.noActiveFile)
            return
        }

        dispatching = true
        defer { dispatching = false }

        // One attempt for the whole lifecycle: the generation is created
        // before the snapshot/save/probe/staging awaits, so a stop during
        // preparation invalidates every later side effect, and the per-attempt
        // token names this attempt's staging directory.
        let attempt = beginAttempt()
        status = .preparing

        // Identity captured before the first await. `sourceSHA256` stays nil
        // until the snapshot has actually been saved.
        let structural = pinnedContext()

        await refreshCapabilities()
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        refreshPlan()
        guard IDELanguageRunPolicy.contextDrift(initial: structural, current: pinnedContext()) == nil else {
            status = .workspaceChanged
            return
        }

        let hadConflict = state.conflict != nil
        let saved = await state.saveAll()
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        guard IDELanguageRunPolicy.contextDrift(initial: structural, current: pinnedContext()) == nil else {
            // The workspace, root or active file changed while the snapshot was
            // being written; the saved revision belongs elsewhere now.
            status = .workspaceChanged
            return
        }

        let decision = IDELanguageRunPolicy.dispatchDecision(
            plan: plan,
            snapshotSaved: saved && !state.dirty,
            hasUnresolvedConflict: hadConflict || state.conflict != nil
        )
        guard case .dispatch = decision else {
            if case .blocked(let reason) = decision { status = .blocked(reason) }
            return
        }

        // Revision observed after the save. Every later await re-checks it.
        let pinned = pinnedContextWithRevision()
        switch plan {
        case .local(_, let argv, _):
            await dispatchLocal(argv: argv, pinned: pinned, attempt: attempt)
        case .remote(let command, _):
            await dispatchRemote(command, pinned: pinned, attempt: attempt)
        case .githubActions(let gitHubPlan, _):
            await dispatchGitHubActions(gitHubPlan, attempt: attempt)
        case .unavailable(let reason):
            status = .blocked(reason)
        }
    }

    // MARK: GitHub Actions dispatch

    /// Publishes the reviewed snapshot (the sheet already showed it), triggers
    /// the workflow and hands ownership to the app-level
    /// `GitHubActionsJobCenter`. The durable record, not this controller, is
    /// the source of truth once the request id exists.
    private func dispatchGitHubActions(
        _ plan: IDEGitHubActionsRunPlan,
        attempt: IDELanguageRunAttempt
    ) async {
        guard let root, let state,
              center.currentWorkspace?.id == workspaceID, center.currentRootURL == root else {
            status = .workspaceChanged
            return
        }
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        guard let workflowPath = plan.workflowPath, !workflowPath.isEmpty else {
            // The template must be installed on the default branch (or an
            // existing registered workflow selected) before dispatch.
            status = .gitHubActionsFailed(
                IDELanguageRunText.t(
                    "请先选择已注册的工作流，或安装 Floe 模板到默认分支。",
                    "Select a registered workflow or install the Floe template on the default branch first."
                )
            )
            return
        }
        status = .gitHubActionsPreparing
        guard let fileService = center.fileService else {
            status = .gitHubActionsFailed(
                IDELanguageRunText.t(
                    "当前工作区文件服务不可用，无法发布云端快照。",
                    "The workspace file service is unavailable, so the cloud snapshot cannot be published."
                )
            )
            return
        }
        let preview = gitHubActions.buildSnapshotPreview(
            root: root, activePath: state.activePath ?? "", fileService: fileService
        )
        gitHubActionsPreview = preview
        guard let preview else {
            status = .gitHubActionsFailed(
                gitHubActions.errorMessage ?? "The snapshot could not be published."
            )
            return
        }
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        let requestID = String(UUID().uuidString.prefix(12)).lowercased()
        let record = await gitHubActions.dispatch(
            plan: plan, manifest: preview.manifest,
            workspaceRoot: root, workspaceID: workspaceID,
            // GitHub owns execution; workspaceID/root retain local ownership
            // without creating or guessing a local runtime environment.
            environmentID: nil,
            requestID: requestID
        )
        guard isCurrent(attempt) else { return }
        guard let record else {
            status = .gitHubActionsFailed(gitHubActions.errorMessage ?? "GitHub Actions dispatch failed.")
            return
        }
        activeGitHubActionsRecordID = record.id
        if record.runID != nil {
            status = .gitHubActionsDispatched(runID: record.runID)
        } else if record.state == .associationPending {
            status = .gitHubActionsAssociationPending
        } else {
            status = .gitHubActionsFailed(record.lastError ?? "GitHub Actions stopped before a run was created.")
        }
    }

    // MARK: Attempt identity

    private func beginAttempt() -> IDELanguageRunAttempt {
        generation += 1
        stopRequestedGeneration = nil
        let attempt = IDELanguageRunAttempt(
            generation: generation,
            runToken: String(UUID().uuidString.prefix(12)).lowercased()
        )
        runToken = attempt.runToken
        activeAttempt = attempt
        // A fresh cancellation token per attempt: cancelling an older stopped
        // attempt can never cancel a newer dispatch.
        attemptCancellation = CancellationToken()
        return attempt
    }

    /// True while `attempt` is still the live attempt. A handler that fails
    /// this check must not write status or touch owned resources.
    private func isCurrent(_ attempt: IDELanguageRunAttempt) -> Bool {
        IDELanguageRunPolicy.isCurrentAttempt(attempt, generation: generation)
    }

    private func isStopRequested(_ attempt: IDELanguageRunAttempt) -> Bool {
        stopRequestedGeneration == attempt.generation
    }

    private func finishAttempt(_ attempt: IDELanguageRunAttempt) {
        if isCurrent(attempt) { activeAttempt = nil }
    }

    private func dispatchLocal(
        argv: [String],
        pinned: IDELanguageRunPinnedContext,
        attempt: IDELanguageRunAttempt
    ) async {
        guard let root else { status = .workspaceChanged; return }
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        guard IDELanguageRunPolicy.contextDrift(initial: pinned, current: pinnedContextWithRevision()) == nil else {
            status = .workspaceChanged
            return
        }
        let line = IDELanguageRunPolicy.shellCommand(argv)
        // Resolve the project tool environment explicitly for THIS pinned
        // root (lookup-or-create, workspace-ownership validated by the
        // coordinator) instead of letting the session fall back to whatever
        // a default layer resolution would pick. A routing/ownership failure
        // fails closed here; only "no substrate configured" legitimately
        // yields nil.
        let resolution = await resolveProjectToolEnvironment(root: root)
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        let toolEnvironment: ToolEnvironment?
        switch resolution {
        case .resolved(let environment):
            toolEnvironment = environment
        case .routingFailed:
            status = .projectToolEnvironmentUnavailable
            return
        }
        // The environment lookup awaited: the workspace, pinned root, active
        // file or saved revision may have changed underneath. Re-check the
        // pinned context + revision *before* opening the session, not only
        // after, so a concurrent switch cannot open a terminal against a stale
        // root and a post-open cleanup never has to undo a redirect.
        guard IDELanguageRunPolicy.contextDrift(initial: pinned, current: pinnedContextWithRevision()) == nil else {
            status = .workspaceChanged
            return
        }
        let sessionID: String
        var initialOutput = Data()
        do {
            // Run-owned session pinned to the workspace root: cwd "." plus the
            // explicit rootURL means a relative script always resolves inside
            // this workspace, regardless of what the user's terminal cd'd to.
            let result = try await center.environment.shellSessionCenter.open(
                command: line,
                cwd: ".",
                environment: [:],
                columns: 100,
                rows: 30,
                runID: runID,
                rootURL: root,
                cancellation: attemptCancellation,
                forTerminal: true,
                toolEnvironment: toolEnvironment
            )
            sessionID = result.sessionID
            initialOutput = result.terminalOutput ?? Data(result.initialOutput.utf8)
        } catch {
            if isCurrent(attempt), !isStopRequested(attempt) { status = .terminalUnavailable }
            return
        }
        // The open awaited: the user may have stopped, or the workspace may
        // have changed underneath. Never leave the just-opened session running
        // against a stale root or a cancelled attempt.
        let stopped = isStopRequested(attempt)
        let current = isCurrent(attempt)
        let sameWorkspace = center.currentWorkspace?.id == workspaceID && center.currentRootURL == root
        guard current, !stopped, sameWorkspace,
              IDELanguageRunPolicy.contextDrift(initial: pinned, current: pinnedContextWithRevision()) == nil else {
            await center.environment.shellSessionCenter.signal(sessionID: sessionID, signal: .interrupt, runID: runID)
            await center.environment.shellSessionCenter.close(sessionID: sessionID, runID: runID)
            // Stop already published its own status; only drift reports here.
            if current, !stopped { status = .workspaceChanged }
            return
        }
        appendRunOutput(initialOutput)
        localRunSessionID = sessionID
        dispatchedCommandLine = line
        status = .runningLocal
        onRequestRunTerminal?()
        startLocalMonitor(sessionID: sessionID, attempt: attempt)
    }

    private enum ProjectToolEnvironmentResolution {
        /// Routing produced a concrete environment, or no substrate is
        /// configured at all (nil) which is the honest pre-existing behavior.
        case resolved(ToolEnvironment?)
        /// Routing was configured but failed (ownership/validation). Fail
        /// closed instead of opening a session against an unknown layer.
        case routingFailed
    }

    /// Looks up (or creates) the project tool environment owned by this exact
    /// workspace root, verifies the routing produced a concrete environment,
    /// and releases the verification lease. A routing/ownership error is
    /// surfaced as `.routingFailed`; it is never swallowed into "no layer".
    /// `ShellSessionCenter.open` re-acquires it by ID and re-validates that the
    /// environment belongs to this workspace, so a mismatched or foreign layer
    /// fails closed instead of silently receiving the run.
    private func resolveProjectToolEnvironment(root: URL) async -> ProjectToolEnvironmentResolution {
        let context = ToolContext(runID: runID, workspaceRootURL: root, cancellation: CancellationToken())
        do {
            let lease = try await ToolEnvironmentRouting.shared.acquire(context)
            let environment = lease.context.environment
            await lease.finish()
            return .resolved(environment)
        } catch {
            return .routingFailed
        }
    }

    /// Observes the run-owned session until the program exits, then reports the
    /// observed exit code. It never marks a run "running" without a live
    /// session, it never touches a session it does not own, and it drops every
    /// write that belongs to a superseded or stopped attempt.
    private func startLocalMonitor(sessionID: String, attempt: IDELanguageRunAttempt) {
        localMonitor?.cancel()
        localMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.isCurrent(attempt), !self.isStopRequested(attempt) else { return }
                do {
                    let result = try await self.center.environment.shellSessionCenter.exchange(
                        sessionID: sessionID,
                        input: nil,
                        waitMs: 60,
                        maxBytes: 64 * 1024,
                        runID: self.runID,
                        cancellation: nil,
                        forTerminal: true
                    )
                    guard self.isCurrent(attempt), !self.isStopRequested(attempt) else { return }
                    self.appendRunOutput(result.terminalOutput ?? Data(result.output.utf8))
                    if !result.alive {
                        if self.localRunSessionID == sessionID { self.localRunSessionID = nil }
                        self.status = .finishedLocal(exitCode: result.exitCode)
                        self.finishAttempt(attempt)
                        return
                    }
                } catch {
                    guard self.isCurrent(attempt), !self.isStopRequested(attempt) else { return }
                    if self.localRunSessionID == sessionID { self.localRunSessionID = nil }
                    self.status = .finishedLocal(exitCode: nil)
                    self.finishAttempt(attempt)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
        }
    }

    private func appendRunOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        runOutput.append(data)
        if runOutput.count > maximumRunOutputBytes {
            runOutput = Data(runOutput.suffix(maximumRunOutputBytes))
        }
    }

    /// Executes the staged remote run. Order of operations, each awaited and
    /// each followed by an identity/generation re-check where a side effect
    /// could land: executable probe → explicit saved-revision proof → exact-byte
    /// staging with read-back proof → SSH visibility probe → bounded,
    /// cancellable execution. Any abort after staging but before the execution
    /// trap is installed runs the marker-guarded cleanup, which removes only
    /// this attempt's own directory (or reports that it could not prove it).
    private func dispatchRemote(
        _ command: IDELanguageRunRemoteCommand,
        pinned: IDELanguageRunPinnedContext,
        attempt: IDELanguageRunAttempt
    ) async {
        // The probe is the only thing that may claim "executable present".
        // A resource download or a success string is not evidence.
        do {
            let probe = try await center.environment.sshCommandService.run(
                command: command.probeCommand,
                hostID: command.hostID,
                timeout: 12,
                maxOutputBytes: 4096,
                cancellation: attemptCancellation
            )
            guard isCurrent(attempt), !isStopRequested(attempt) else { return }
            guard probe.exitCode == 0 else {
                await abortRemote(.probeFailed(tool: command.probeTool), command: command, attempt: attempt)
                return
            }
        } catch {
            guard isCurrent(attempt), !isStopRequested(attempt) else { return }
            await abortRemote(.probeError, command: command, attempt: attempt)
            return
        }
        guard isCurrent(attempt), !isStopRequested(attempt) else { return }
        guard IDELanguageRunPolicy.contextDrift(initial: pinned, current: pinnedContextWithRevision()) == nil else {
            // The workspace or the just-saved file revision changed during the
            // probe; the staged bytes would no longer match the editor.
            await abortRemote(.workspaceChanged, command: command, attempt: attempt)
            return
        }

        // Read the exact saved bytes from the pinned root. Nothing is staged
        // here, so there is no remote cleanup to run on this failure.
        let source: Data
        do {
            source = try readPinnedSource(relativePath: pinned.relativePath)
        } catch let failure as IDERunStagingFailure {
            await abortRemote(.stagingFailed(failure), command: command, attempt: attempt)
            return
        } catch {
            await abortRemote(.stagingFailed(.sourceUnreadable), command: command, attempt: attempt)
            return
        }

        // Explicit revision proof: the bytes read now must equal the revision
        // captured immediately after the snapshot save, otherwise an edit
        // landed between save and staging and the run would execute unknown
        // source. Fails closed when no revision was pinned.
        guard IDELanguageRunPolicy.sourceRevisionMatches(
            pinnedSHA256: pinned.sourceSHA256,
            observedSHA256: FloeDigest.sha256Hex(source)
        ) else {
            await abortRemote(.workspaceChanged, command: command, attempt: attempt)
            return
        }

        let perAttemptCancellation = attemptCancellation
        let stager = IDERunSourceStager(
            transport: CloudWorkspaceStagingTransport(
                service: center.environment.cloudWorkspaceService,
                hostID: command.hostID
            ),
            maximumSourceBytes: maximumSourceBytes,
            sha256: { FloeDigest.sha256Hex($0) },
            checkCancellation: {
                // Foundation-only stager observes the app's per-attempt token
                // between transport reads/writes; stop cancels this exact token.
                if perAttemptCancellation?.isCancelled == true { throw CancellationError() }
            }
        )
        let stagingPlan: IDERunStagingPlan
        do {
            stagingPlan = try stager.plan(
                relativePath: pinned.relativePath,
                source: source,
                runToken: command.runToken
            )
        } catch let failure as IDERunStagingFailure {
            await abortRemote(.stagingFailed(failure), command: command, attempt: attempt)
            return
        } catch {
            await abortRemote(.stagingFailed(.invalidSourcePath), command: command, attempt: attempt)
            return
        }
        // Defense in depth: the command must name exactly the layout the
        // stager will write, otherwise the verified bytes and the executed
        // path could diverge.
        guard stagingPlan.paths.stagedSourcePath == command.stagedSourcePath,
              stagingPlan.paths.stagingRoot == command.stagingRoot,
              IDELanguageRunPolicy.sourceRevisionMatches(
                  pinnedSHA256: pinned.sourceSHA256,
                  observedSHA256: stagingPlan.expectedSHA256
              ) else {
            await abortRemote(.stagingFailed(.verificationFailed), command: command, attempt: attempt)
            return
        }

        // From here on a marker may exist remotely: any abort must run the
        // marker-guarded cleanup because the execution trap was not installed.
        do {
            _ = try await stager.stage(plan: stagingPlan, source: source)
        } catch is CancellationError {
            // The per-attempt token was cancelled between transport reads or
            // writes. The run was never dispatched, so this is a preparation
            // cancellation, not a network failure and not a remote stop. It
            // still goes through the marker-guarded cleanup because the marker
            // (or the source) may already have landed.
            await abortRemote(
                .cancelledPreparation, command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        } catch let failure as IDERunStagingFailure {
            await abortRemote(
                .stagingFailed(failure), command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: failure
            )
            return
        } catch {
            // The transport only throws untyped errors when the paired agent
            // or its tunnel is unreachable (verification failures are typed).
            await abortRemote(
                .remoteStagingUnavailable, command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        }

        guard isCurrent(attempt), !isStopRequested(attempt) else {
            await abortRemote(
                .cancelledPreparation, command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        }
        guard IDELanguageRunPolicy.contextDrift(initial: pinned, current: pinnedContextWithRevision()) == nil else {
            await abortRemote(
                .workspaceChanged, command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        }

        // Prove through the SSH shell — not just the tunnel — that the staged
        // file sits at the daemon's default cloud root the command will use.
        do {
            let visibility = try await center.environment.sshCommandService.run(
                command: command.visibilityProbeCommand,
                hostID: command.hostID,
                timeout: 12,
                maxOutputBytes: 4096,
                cancellation: perAttemptCancellation
            )
            guard isCurrent(attempt), !isStopRequested(attempt) else {
                await abortRemote(
                    .cancelledPreparation, command: command, attempt: attempt,
                    stagingAttempted: true, stageFailure: nil
                )
                return
            }
            guard visibility.exitCode == 0,
                  visibility.stdout.contains(IDERunStagingLayout.visibilityMarker) else {
                await abortRemote(
                    .stagingFailed(.notVisibleOnHost), command: command, attempt: attempt,
                    stagingAttempted: true, stageFailure: nil
                )
                return
            }
        } catch {
            guard isCurrent(attempt), !isStopRequested(attempt) else {
                await abortRemote(
                    .cancelledPreparation, command: command, attempt: attempt,
                    stagingAttempted: true, stageFailure: nil
                )
                return
            }
            await abortRemote(
                .stagingFailed(.notVisibleOnHost), command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        }
        guard isCurrent(attempt), !isStopRequested(attempt) else {
            await abortRemote(
                .cancelledPreparation, command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        }
        guard IDELanguageRunPolicy.contextDrift(initial: pinned, current: pinnedContextWithRevision()) == nil else {
            await abortRemote(
                .workspaceChanged, command: command, attempt: attempt,
                stagingAttempted: true, stageFailure: nil
            )
            return
        }

        // Dispatch. The trap owns cleanup from here; cancelling the SSH client
        // is not proof the remote process exited or the trap ran.
        let cancellation = CancellationToken()
        remoteCancellation = cancellation
        dispatchedCommandLine = command.shellCommand
        status = .runningRemote
        onRequestRunTerminal?()
        defer {
            if remoteCancellation === cancellation { remoteCancellation = nil }
            finishAttempt(attempt)
        }
        do {
            let result = try await center.environment.sshCommandService.run(
                command: command.shellCommand,
                hostID: command.hostID,
                timeout: remoteRunTimeout,
                maxOutputBytes: remoteRunMaxOutputBytes,
                cancellation: cancellation
            )
            guard isCurrent(attempt), !isStopRequested(attempt) else { return }
            appendRunOutput(Data(result.stdout.utf8))
            appendRunOutput(Data(result.stderr.utf8))
            status = .finishedRemote(exitCode: result.exitCode)
        } catch SSHExecError.cancelled {
            // The FloeSSH client was closed; the remote child's exit and the
            // trap's cleanup are unobserved. Never claim a confirmed stop.
            if isCurrent(attempt) { status = .stopRequestedRemote }
        } catch SSHExecError.timedOut {
            // Same honesty rule as cancellation: closing the client is not
            // proof the remote process or its cleanup trap ran.
            if isCurrent(attempt) { status = .remoteRunTimedOut }
        } catch {
            if isCurrent(attempt), !isStopRequested(attempt) { status = .remoteHostUnavailable }
        }
    }

    /// Marker-guarded cleanup for any abort after staging but before the
    /// execution trap exists. Staging is only attempted once a marker may have
    /// been written, so `stagingAttempted` gates it (a probe/read failure has
    /// nothing remote to clean). The command re-checks this attempt's token
    /// before deleting anything, and an unproven outcome is surfaced with the
    /// staging root so the user keeps the recovery detail instead of a false
    /// "cleaned" claim.
    private func abortRemote(
        _ desired: IDELanguageRunStatus,
        command: IDELanguageRunRemoteCommand,
        attempt: IDELanguageRunAttempt,
        stagingAttempted: Bool = false,
        stageFailure: IDERunStagingFailure? = nil
    ) async {
        var finalStatus = desired
        if stagingAttempted {
            let outcome = await cleanupStagedRun(
                stagingRoot: command.stagingRoot,
                runToken: command.runToken,
                hostID: command.hostID
            )
            if case .unconfirmed = outcome {
                finalStatus = .stagingCleanupUnconfirmed(
                    stagingRoot: command.stagingRoot,
                    stageFailure: stageFailure
                )
            }
        }
        guard isCurrent(attempt) else { return }
        status = finalStatus
        finishAttempt(attempt)
    }

    /// Runs the marker-guarded cleanup over the verified SSH command service.
    /// The command is bounded and independent of the run's own cancellation:
    /// it must still be attempted after the user stops, and it never touches a
    /// path whose marker does not carry this attempt's token.
    private func cleanupStagedRun(
        stagingRoot: String,
        runToken: String,
        hostID: UUID
    ) async -> IDERunStagingCleanupOutcome {
        do {
            let result = try await center.environment.sshCommandService.run(
                command: IDELanguageRunPolicy.stagingCleanupCommand(stagingRoot: stagingRoot, runToken: runToken),
                hostID: hostID,
                timeout: 15,
                maxOutputBytes: 4096
            )
            return IDELanguageRunPolicy.stagingCleanupOutcome(stdout: result.stdout, exitCode: result.exitCode)
        } catch {
            return .unconfirmed(detail: "cleanup command failed")
        }
    }

    /// Reads the exact bytes of the just-saved file from the pinned root. The
    /// path is resolved through `WorkspacePathGuard`, so a symlink that escapes
    /// the workspace or a non-regular target is rejected; the read is bounded
    /// at `maximumSourceBytes + 1` before any large allocation, so an
    /// externally grown file fails with the typed size reason.
    private func readPinnedSource(relativePath: String) throws -> Data {
        guard let root,
              IDELanguageRunPolicy.isSafeWorkspaceRelativePath(relativePath) else {
            throw IDERunStagingFailure.invalidSourcePath
        }
        let guardResolver = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maximumSourceBytes,
            maxWriteBytes: maximumSourceBytes
        )
        let url: URL
        do {
            url = try guardResolver.resolve(relativePath)
        } catch {
            // Absolute/traversal path, symlink escape, secret file or otherwise
            // invalid path: all fail closed before a byte is read.
            throw IDERunStagingFailure.invalidSourcePath
        }
        return try IDERunSourceReader.readRegularFile(at: url, maxBytes: maximumSourceBytes)
    }

    func stop() async {
        // A dispatched GitHub Actions run is owned by the app-level center and
        // keeps going on GitHub regardless of this controller. Cancel through
        // the durable record; the request is not a confirmed stop.
        if let recordID = activeGitHubActionsRecordID,
           let record = gitHubActions.record(id: recordID),
           !record.state.isTerminal {
            await gitHubActions.cancel(recordID: recordID)
            activeAttempt = nil
            status = .gitHubActionsCancelRequested
            return
        }
        guard let attempt = activeAttempt else { return }
        // Invalidate this attempt for every later await and side effect, and
        // cancel the per-attempt token so an in-flight probe/verified transfer/
        // session open observes the stop. A subsequent dispatch increments
        // `generation` and gets a fresh token, so a newer attempt is never
        // affected by this stop.
        stopRequestedGeneration = attempt.generation
        attemptCancellation?.cancel()
        localMonitor?.cancel()
        localMonitor = nil
        if let sessionID = localRunSessionID {
            localRunSessionID = nil
            // Scoped to this controller's runID: an unrelated reused terminal
            // session can never be interrupted.
            await center.environment.shellSessionCenter.signal(sessionID: sessionID, signal: .interrupt, runID: runID)
            await center.environment.shellSessionCenter.close(sessionID: sessionID, runID: runID)
            if isCurrent(attempt) { status = .stoppedLocal }
            return
        }
        if let cancellation = remoteCancellation {
            remoteCancellation = nil
            cancellation.cancel()
            // The token only requests cancellation of this run's SSH client.
            // The client close, the remote child's exit and the cleanup trap
            // are not observed here, so `.stopRequestedRemote` (not a
            // confirmed stop) is truthful; SSH close is only proven when the
            // exec throws `SSHExecError.cancelled`.
            if isCurrent(attempt) { status = .stopRequestedRemote }
            return
        }
        // Preparation can include probes, transfers or an in-flight open.
        // Report cancellation without asserting that a process already stopped;
        // the token and post-await checks close a late local session.
        if dispatching, isCurrent(attempt) {
            status = .cancelledPreparation
        }
    }

    // MARK: Identity

    private func pinnedContext() -> IDELanguageRunPinnedContext {
        IDELanguageRunPinnedContext(
            workspaceID: center.currentWorkspace?.id,
            rootPath: center.currentRootURL?.standardizedFileURL.path,
            relativePath: state?.activePath ?? "",
            sourceSHA256: nil
        )
    }

    private func pinnedContextWithRevision() -> IDELanguageRunPinnedContext {
        let current = pinnedContext()
        return IDELanguageRunPinnedContext(
            workspaceID: current.workspaceID,
            rootPath: current.rootPath,
            relativePath: current.relativePath,
            sourceSHA256: sourceRevisionSHA(relativePath: current.relativePath)
        )
    }

    private func sourceRevisionSHA(relativePath: String) -> String? {
        guard !relativePath.isEmpty, let service = center.fileService else { return nil }
        return (try? service.metadata(relativePath))?.sha256
    }
}

/// Production `IDERunStagingTransport` over the paired host's Floe remote
/// agent. The bearer token stays inside `CloudWorkspaceService`; this adapter
/// only sees bounded JSON responses. Paths are daemon-cloud-root-relative and
/// confined by the daemon's `resolve()`.
private struct CloudWorkspaceStagingTransport: IDERunStagingTransport {
    let service: CloudWorkspaceService
    let hostID: UUID

    private struct WriteResponse: Decodable {
        let sha256: String?
    }

    private struct ReadResponse: Decodable {
        let sha256: String
        let dataBase64: String

        private enum CodingKeys: String, CodingKey {
            case sha256
            case dataBase64 = "data_base64"
        }
    }

    func writeFile(relativePath: String, data: Data) async throws -> String {
        let response = try await service.request(
            hostID: hostID,
            method: "POST",
            endpoint: "v1/files/write",
            body: ["path": relativePath, "data_base64": data.base64EncodedString()]
        )
        guard let decoded = try? JSONDecoder().decode(WriteResponse.self, from: response),
              let sha = decoded.sha256, !sha.isEmpty else {
            throw IDERunStagingFailure.writeFailed
        }
        return sha
    }

    func readFile(relativePath: String) async throws -> (sha256: String, data: Data)? {
        let response: Data
        do {
            response = try await service.request(
                hostID: hostID,
                method: "GET",
                endpoint: "v1/files/read",
                queryPath: relativePath
            )
        } catch {
            // The daemon answers a missing file with a 400 whose detail names
            // the POSIX error. Only that case maps to "absent"; every other
            // failure propagates so it is never mistaken for a clean read.
            let message = error.localizedDescription
            if message.contains("No such file") || message.contains("Errno 2")
                || message.contains("not_found") {
                return nil
            }
            throw error
        }
        guard let decoded = try? JSONDecoder().decode(ReadResponse.self, from: response),
              let bytes = Data(base64Encoded: decoded.dataBase64) else {
            throw IDERunStagingFailure.verificationFailed
        }
        return (decoded.sha256, bytes)
    }
}

#endif

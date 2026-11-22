// SPDX-License-Identifier: MPL-2.0
//
// MacTaskTerminalInspector — task-bound terminal inspector for the Mac workbench.
//
// Mirrors the iPad task inspector's destination pattern (本地工作区 / 远程 SSH)
// on the mature AppKit PTY stack in FloeMacTerminal. The coordinator owns
// MacWorkspaceRootView and all workbench lifecycle; this file only exposes a
// small owner/store + one embeddable view, so integration is:
//
//   let store = MacTaskTerminalStore()            // held by the workbench owner
//   let owner = try store.owner(                  // one per task, keyed by task ID
//       taskID: conversation.id,
//       workspaceURL: authorizedWorkspaceRootURL  // existing directory the task owns
//   )
//   owner.admission = MyAdmission()               // optional OTA/Bridge lease hooks
//   MacTaskTerminalInspector(owner: owner)        // embed in the task inspector pane
//
// Lifecycle contract (coordinator integration contract):
// - Nothing starts until the user presses Start/Connect in the view.
// - The local session's working directory is fixed to the owned task root.
// - Two projects never share a session: the store keys owners by task ID.
// - Owner/store survive task navigation; they return true only after
//   CONFIRMED teardown, and a timed-out owner is RETAINED, never dropped.
// - Root change refuses replacement while the old owner is live; drain it
//   first with `await store.stopAndRemove(taskID:)` — no racing async shutdown.
// - `MacTaskTerminalAdmission` lets integration acquire a lease per session
//   start and release it on the session's actual terminal exit, so an open
//   terminal participates in App OTA/Bridge lifecycle.
// - Navigation is safe: the view detaches the terminal surface without
//   killing the child; sessions end via the close button, stop*(), or store
//   teardown only.

import Combine
import FloeMacTerminal
import Foundation
import SwiftUI

// MARK: - Admission

/// Integration-provided per-session admission/lease hooks.
///
/// Implemented by the workbench owner (e.g. BridgeUpdateActivity-style lease)
/// and injected as `MacTaskTerminalOwner.admission`. `acquire` runs before a
/// session starts and may throw to refuse (OTA in progress, task closed);
/// nothing launches when it throws. `release` runs when the child has
/// actually been reaped (confirmed exit), never on a timeout.
public protocol MacTaskTerminalAdmission: Sendable {
    func acquire(for destination: MacTaskTerminalDestination, taskID: UUID) async throws
    func release(for destination: MacTaskTerminalDestination, taskID: UUID) async
}

// MARK: - Owner

/// Owns the local and SSH terminal sessions for exactly one task.
///
/// Sessions are created up front but start only on explicit user action
/// (`startLocal()` / `startSSH(_:)` from the view, after the optional
/// admission acquire). Core ownership stops and measures them through
/// `stopLocal`/`stopSSH`/`stopAll` and `measure(kind:)`; stop methods return
/// true only after the child reap is confirmed.
@MainActor
public final class MacTaskTerminalOwner: ObservableObject {

    /// Identity of the task these sessions belong to.
    public let taskID: UUID

    /// The task-owned workspace root; the local shell always starts here.
    public let workspaceURL: URL

    /// Local-workspace interactive PTY session (starts in `workspaceURL`).
    fileprivate let localSession = MacTerminalSession()

    /// Remote SSH session (interactive OpenSSH to a user-supplied host).
    fileprivate let sshSession = MacTerminalSession()

    /// Optional admission/lease hooks injected by integration.
    public var admission: (any MacTaskTerminalAdmission)?

    /// When the local session was started, for uptime measurement.
    @Published public private(set) var localStartedAt: Date?
    /// When the SSH session was started, for uptime measurement.
    @Published public private(set) var sshStartedAt: Date?

    private var starting = Set<MacTaskTerminalDestination>()
    private var cancelledStarts = Set<MacTaskTerminalDestination>()
    private var exitWatches: [MacTaskTerminalDestination: Task<Void, Never>] = [:]
    private var stops: [MacTaskTerminalDestination: Task<Bool, Never>] = [:]
    private var isDraining = false

    public init(taskID: UUID, workspaceURL: URL) throws {
        self.taskID = taskID
        // Validate up front: an inspector must never be constructible for a
        // root the terminal could not actually start in. Scoped bookmark
        // resolution is the caller's job (existing root coordinates access).
        _ = try MacTerminalScope.validatedDirectory(workspaceURL.path)
        self.workspaceURL = workspaceURL
    }

    deinit {
        // Abandoned without stopAll(): best-effort teardown. The normal path
        // is `await stopAll()`, which also confirms the reap. Each session's
        // own isolated deinit is the final backstop; lease release still runs
        // from the exit-tracking tasks started at successful start.
        Task { @MainActor [localSession, sshSession] in
            await localSession.stop()
            await sshSession.stop()
        }
    }

    /// The owner remains bound to its folder until launches, stops and
    /// release of their installation leases have finished.
    public var hasLiveSession: Bool {
        !starting.isEmpty || !exitWatches.isEmpty || !stops.isEmpty
    }

    public func startLocal() async throws {
        try await start(kind: .local) {
            try localSession.start(scope: MacTerminalScope.validatedDirectory(workspaceURL.path))
        }
    }

    public func startSSH(_ host: MacSSHHost) async throws {
        try await start(kind: .ssh) { try sshSession.startSSH(host, scope: .home) }
    }

    private func start(kind: MacTaskTerminalDestination, launch: () throws -> Void) async throws {
        guard !isDraining, stops[kind] == nil, exitWatches[kind] == nil,
              starting.insert(kind).inserted else { return }
        defer { starting.remove(kind); cancelledStarts.remove(kind) }

        let session = session(kind: kind)
        let admission = self.admission
        let taskID = self.taskID
        try await admission?.acquire(for: kind, taskID: taskID)
        do {
            try Task.checkCancellation()
            guard !isDraining, !cancelledStarts.contains(kind) else { throw CancellationError() }
            try launch()
        } catch {
            await admission?.release(for: kind, taskID: taskID)
            throw error
        }

        setStartDate(Date(), for: kind)
        exitWatches[kind] = Task { @MainActor [weak self] in
            await session.termination
            guard case .exited = session.state else { return }
            await admission?.release(for: kind, taskID: taskID)
            self?.exitWatches[kind] = nil
            self?.setStartDate(nil, for: kind)
        }
    }

    private func setStartDate(_ date: Date?, for kind: MacTaskTerminalDestination) {
        switch kind {
        case .local: localStartedAt = date
        case .ssh: sshStartedAt = date
        }
    }

    @discardableResult
    public func stopLocal(timeout: Duration = .seconds(3)) async -> Bool {
        await stop(kind: .local, timeout: timeout)
    }

    @discardableResult
    public func stopSSH(timeout: Duration = .seconds(3)) async -> Bool {
        await stop(kind: .ssh, timeout: timeout)
    }

    private func stop(kind: MacTaskTerminalDestination, timeout: Duration) async -> Bool {
        if starting.contains(kind) {
            cancelledStarts.insert(kind)
            return false
        }
        if let stop = stops[kind] { return await stop.value }

        let session = session(kind: kind)
        let exitWatch = exitWatches[kind]
        let stop = Task { @MainActor in
            guard await session.close(timeout: timeout) else { return false }
            await exitWatch?.value
            return true
        }
        stops[kind] = stop
        let closed = await stop.value
        stops[kind] = nil
        return closed
    }

    /// Prevent a retained view from restarting a terminal while its owner is
    /// being removed from the store.
    fileprivate func retire(timeout: Duration) async -> Bool {
        guard !isDraining else { return false }
        isDraining = true
        let local = await stopLocal(timeout: timeout)
        let remote = await stopSSH(timeout: timeout)
        if local && remote { return true }
        isDraining = false
        return false
    }

    fileprivate func reset(_ kind: MacTaskTerminalDestination) {
        guard exitWatches[kind] == nil else { return }
        session(kind: kind).reset()
    }

    /// Point-in-time health snapshot for core ownership (no UI needed).
    public func measure(kind: MacTaskTerminalDestination) -> MacTaskTerminalMeasurement {
        switch kind {
        case .local:
            return MacTaskTerminalMeasurement(
                destination: kind,
                state: localSession.state,
                shellPID: localSession.shellPID,
                startedAt: localStartedAt
            )
        case .ssh:
            return MacTaskTerminalMeasurement(
                destination: kind,
                state: sshSession.state,
                shellPID: sshSession.shellPID,
                startedAt: sshStartedAt
            )
        }
    }

    /// Live session for a destination; the view renders it but never owns it.
    private func session(kind: MacTaskTerminalDestination) -> MacTerminalSession {
        switch kind {
        case .local: return localSession
        case .ssh: return sshSession
        }
    }
}

// MARK: - Measurement

/// Observable snapshot of one owned session, for stop/measure ownership.
public struct MacTaskTerminalMeasurement: Equatable, Sendable {
    public var destination: MacTaskTerminalDestination
    public var state: MacTerminalSessionState
    public var shellPID: pid_t?
    public var startedAt: Date?

    public var uptime: Duration? {
        guard let startedAt else { return nil }
        return .seconds(Date().timeIntervalSince(startedAt))
    }
}

// MARK: - Destination

/// Terminal destination selector, mirroring the iPad inspector's
/// 本地工作区 / 远程 SSH segmented control.
public enum MacTaskTerminalDestination: String, CaseIterable, Hashable, Sendable {
    case local
    case ssh

    public var title: String {
        switch self {
        case .local: return MacTaskTerminalCopy.t("本地工作区", "Local workspace")
        case .ssh: return MacTaskTerminalCopy.t("远程 SSH", "Remote SSH")
        }
    }
}

// MARK: - Store

public enum MacTaskTerminalStoreError: Error, Equatable, Sendable {
    /// An owner for this task exists with a different root and is still
    /// live. Drain it with `await stopAndRemove(taskID:)` and re-acquire;
    /// replacement never races an asynchronous old shutdown.
    case replacementRefused(UUID)

    public var message: String {
        switch self {
        case .replacementRefused(let id):
            return MacTaskTerminalCopy.t(
                "任务 \(id.uuidString) 的终端会话仍在运行，请先结束后再切换目录。",
                "Task \(id.uuidString) still has a live terminal session. Stop it before changing the folder."
            )
        }
    }
}

/// Workbench-level owner registry: one ``MacTaskTerminalOwner`` per task ID.
///
/// Keeps sessions independent across projects: two different task IDs always
/// get distinct owners and sessions. Owners survive navigation; teardown is
/// confirmed by the returned Bool, and timed-out owners stay in the store so
/// no child process is ever orphaned by dictionary removal.
@MainActor
public final class MacTaskTerminalStore: ObservableObject {

    public init() {}

    private var owners: [UUID: MacTaskTerminalOwner] = [:]

    public var activeTaskIDs: [UUID] { Array(owners.keys) }

    /// Returns the existing owner for `taskID` bound to `workspaceURL`, or
    /// creates one. A changed root with a live old owner throws
    /// ``MacTaskTerminalStoreError/replacementRefused(_:)`` — drain first via
    /// `await stopAndRemove(taskID:)`. A changed root with no live session
    /// replaces immediately (there is nothing to drain).
    public func owner(taskID: UUID, workspaceURL: URL) throws -> MacTaskTerminalOwner {
        if let existing = owners[taskID] {
            guard existing.workspaceURL != workspaceURL else { return existing }
            guard !existing.hasLiveSession else { throw MacTaskTerminalStoreError.replacementRefused(taskID) }
            owners[taskID] = nil
        }
        let owner = try MacTaskTerminalOwner(taskID: taskID, workspaceURL: workspaceURL)
        owners[taskID] = owner
        return owner
    }

    /// Stops the owner for a finished/closed task and forgets it. Returns
    /// true only after confirmed teardown; on timeout the owner is RETAINED
    /// and false is returned, so the child is never abandoned.
    @discardableResult
    public func stopAndRemove(taskID: UUID, timeout: Duration = .seconds(3)) async -> Bool {
        guard let owner = owners[taskID] else { return true }
        guard await owner.retire(timeout: timeout) else { return false }
        owners[taskID] = nil
        return true
    }

    /// Stops every owned session. Owners drained in time are removed; any
    /// timed-out owner stays in the store. True only when all drained.
    @discardableResult
    public func stopAll(timeout: Duration = .seconds(3)) async -> Bool {
        var allDrained = true
        let snapshot = owners
        for (id, owner) in snapshot {
            if await owner.retire(timeout: timeout) {
                owners[id] = nil
            } else {
                allDrained = false
            }
        }
        return allDrained
    }
}

// MARK: - Inspector view

/// Embeddable terminal inspector for one task: segmented 本地工作区 / 远程 SSH
/// destination picker, start-on-user-action only, explicit close, and no
/// lifecycle side effects on navigation (the owner keeps sessions alive).
public struct MacTaskTerminalInspector: View {

    @ObservedObject public var owner: MacTaskTerminalOwner
    @ObservedObject private var localSession: MacTerminalSession
    @ObservedObject private var sshSession: MacTerminalSession

    @State private var destination: MacTaskTerminalDestination = .local
    @State private var hostInput = ""
    @State private var userInput = ""
    @State private var portInput = ""
    @State private var startError: String?

    public init(owner: MacTaskTerminalOwner) {
        self.owner = owner
        self.localSession = owner.localSession
        self.sshSession = owner.sshSession
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker(MacTaskTerminalCopy.t("终端", "Terminal"), selection: $destination) {
                ForEach(MacTaskTerminalDestination.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("terminal.destination")
            switch destination {
            case .local:
                localPane
            case .ssh:
                sshEntryPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deliberately no .onDisappear stop: navigation detaches the surface
        // only; the owner ends sessions via the close button or stop*().
    }

    // MARK: Local workspace

    private var localPane: some View {
        VStack(spacing: 0) {
            switch localSession.state {
            case .idle:
                Form {
                    LabeledContent(MacTaskTerminalCopy.t("任务目录", "Task folder")) {
                        Text(owner.workspaceURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(MacTaskTerminalCopy.t("启动终端", "Start Terminal")) {
                            Task { await startLocalSession() }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                    if let startError {
                        Text(startError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
                .padding()
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .running, .stopping:
                runningChrome(kind: .local, session: localSession)
                Divider()
                MacTerminalSurface(session: localSession)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .exited(let code):
                exitedBanner(kind: .local, code: code)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startLocalSession() async {
        startError = nil
        do {
            try await owner.startLocal()
        } catch {
            startError = MacTaskTerminalCopy.t(
                "无法启动终端。请检查任务目录后重试。",
                "Could not start the terminal. Check the task folder and try again."
            )
        }
    }

    // MARK: Remote SSH

    private var sshEntryPane: some View {
        VStack(spacing: 0) {
            switch sshSession.state {
            case .idle:
                Form {
                    TextField(MacTaskTerminalCopy.t("主机", "Host"), text: $hostInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("terminal.ssh.host")
                    TextField(MacTaskTerminalCopy.t("用户名（可选）", "User (optional)"), text: $userInput)
                        .textFieldStyle(.roundedBorder)
                    TextField(MacTaskTerminalCopy.t("端口（可选）", "Port (optional)"), text: $portInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button(MacTaskTerminalCopy.t("连接", "Connect")) {
                            Task { await connectSSH() }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let startError {
                        Text(startError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(MacTaskTerminalCopy.t(
                        "使用系统 OpenSSH 连接。首次连接的主机密钥确认和密码输入会显示在终端中。",
                        "Connects with the system OpenSSH. Host-key confirmation and password entry appear in the terminal."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .padding()
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .running, .stopping:
                runningChrome(kind: .ssh, session: sshSession)
                Divider()
                MacTerminalSurface(session: sshSession)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .exited(let code):
                exitedBanner(kind: .ssh, code: code)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connectSSH() async {
        startError = nil
        do {
            let trimmedPort = portInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Int(trimmedPort)
            guard trimmedPort.isEmpty || port != nil else {
                startError = MacTaskTerminalCopy.t("请输入 1 到 65535 之间的端口号。", "Enter a port from 1 to 65535.")
                return
            }
            let host = try MacSSHHost.validated(
                host: hostInput,
                user: userInput.isEmpty ? nil : userInput,
                port: port
            )
            try await owner.startSSH(host)
        } catch let error as MacSSHHostValidationError {
            startError = error.message
        } catch {
            startError = MacTaskTerminalCopy.t(
                "无法启动 SSH。请检查主机地址后重试。",
                "Could not start SSH. Check the host address and try again."
            )
        }
    }

    // MARK: Chrome

    private func runningChrome(kind: MacTaskTerminalDestination, session: MacTerminalSession) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state == .running ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(chromeStatus(kind: kind, session: session))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                Task {
                    switch kind {
                    case .local: await owner.stopLocal()
                    case .ssh: await owner.stopSSH()
                    }
                }
            } label: {
                Text(MacTaskTerminalCopy.t("结束会话", "End Session"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func chromeStatus(kind: MacTaskTerminalDestination, session: MacTerminalSession) -> String {
        let fallback: String
        switch kind {
        case .local: fallback = MacTaskTerminalCopy.t("终端", "Terminal")
        case .ssh: fallback = MacTaskTerminalCopy.t("远程 SSH", "Remote SSH")
        }
        let title = session.terminalTitle.isEmpty ? fallback : session.terminalTitle
        switch session.state {
        case .running:
            if let cwd = session.currentDirectory {
                return "\(title) — \(cwd)"
            }
            return title
        case .stopping:
            return MacTaskTerminalCopy.t("正在结束…", "Ending…")
        default:
            return title
        }
    }

    // MARK: Exited

    private func exitedBanner(kind: MacTaskTerminalDestination, code: Int32?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.largeTitle)
            Text(exitText(code))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                owner.reset(kind)
            } label: {
                Text(MacTaskTerminalCopy.t("新建会话", "New Session"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitText(_ code: Int32?) -> String {
        switch code {
        case .some(let code):
            return MacTaskTerminalCopy.t("会话已结束，退出代码 \(code)", "Session ended with exit code \(code)")
        case .none:
            return MacTaskTerminalCopy.t("会话已结束", "Session ended")
        }
    }
}

// MARK: - Copy

private enum MacTaskTerminalCopy {
    static func t(_ zh: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "zh" ? zh : en
    }
}

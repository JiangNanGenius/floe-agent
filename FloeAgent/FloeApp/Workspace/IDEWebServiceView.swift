// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence

enum IDEWebServicePolicy {
    static func stateTitle(_ state: BackgroundJobState) -> String {
        if state == .cancelled { return IDELanguageRunText.t("服务已停止", "Service stopped") }
        // Build a dynamic key, not a LocalizedStringKey format interpolation.
        return FloeL10n.l("services.state." + state.rawValue)
    }

    static func runtime(for path: String?) -> String? {
        guard let path else { return nil }
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "static"
        case "py": return "python"
        case "js", "mjs", "cjs": return "node"
        case "sh", "bash": return "shell"
        default: return nil
        }
    }

    static func validPort(_ text: String) -> Int? {
        guard let port = Int(text), (1024...65535).contains(port) else { return nil }
        return port
    }
}

/// A UI caller of the same durable service lifecycle used by jobs.submit.
/// Closing the IDE only closes this observer, never the managed service.
struct IDEWebServiceView: View {
    let center: WorkspaceCenter
    @ObservedObject var state: IDEWorkbenchState
    let workspaceID: UUID
    let root: URL
    let entry: String?
    /// Routes a submitted (or already running) explicit service into the IDE's
    /// typed service terminal. The callback receives the exact durable job and
    /// its captured identity; it never guesses a port or page again.
    let onServiceStarted: ((IDEServiceRunLaunch) -> Void)?
    @State private var owners: [UUID] = []
    @State private var owner: UUID?
    @State private var port = "8080"
    @State private var busy = false
    @State private var failure: String?
    @State private var job: BackgroundJob?

    private var runtime: String? { IDEWebServicePolicy.runtime(for: entry) }
    private var isRunning: Bool { job.map { !$0.state.isTerminal } == true }
    private var unavailableReason: String? {
        if entry == nil { return IDELanguageRunText.t("请先打开文件。", "Open a file first.") }
        if runtime == nil { return IDELanguageRunText.t("此文件不能作为网页服务启动。", "This file cannot start a web service.") }
        if center.environment.backgroundJobService == nil {
            return IDELanguageRunText.t("网页服务暂不可用，请稍后重试。", "Web services are unavailable. Try again later.")
        }
        if owner == nil { return IDELanguageRunText.t("请选择所属任务，或创建一个运行任务。", "Choose an owning task or create one.") }
        if IDEWebServicePolicy.validPort(port) == nil {
            return IDELanguageRunText.t("请输入 1024–65535 的端口。", "Enter a port from 1024 to 65535.")
        }
        return nil
    }
    private var progress: LocalServiceProgress? {
        job?.progressJSON.flatMap { try? JSONDecoder().decode(LocalServiceProgress.self, from: $0) }
    }
    var body: some View {
        Form {
            Section {
                Text(entry ?? "")
                TextField(IDELanguageRunText.t("端口", "Port"), text: $port)
                    .keyboardType(.numberPad)
                    .disabled(busy || job.map { !$0.state.isTerminal } == true)
                    .accessibilityIdentifier("workspace.ide.service.port")
                if owners.count > 1 {
                    Picker(IDELanguageRunText.t("所属任务", "Owning task"), selection: $owner) {
                        Text(IDELanguageRunText.t("请选择", "Choose a task")).tag(UUID?.none)
                        ForEach(owners, id: \.self) { id in
                            Text(center.environment.conversationCenter.conversations.first(where: { $0.id == id })?.title ?? id.uuidString)
                                .tag(Optional(id))
                        }
                    }
                    .disabled(busy || job.map { !$0.state.isTerminal } == true)
                }
                if owners.isEmpty {
                    Button(IDELanguageRunText.t("创建运行任务", "Create a run task")) {
                        Task { await createOwner() }
                    }
                    .disabled(busy || isRunning)
                    .accessibilityIdentifier("workspace.ide.service.createTask")
                }
                Text(runtime == "static"
                     ? IDELanguageRunText.t("预览此页面及同目录资源。关闭窗口后服务继续运行。", "Preview this page and its nearby files. The service keeps running when this window closes.")
                     : IDELanguageRunText.t("脚本应监听所选端口。关闭窗口后服务继续运行。", "Your script should listen on the selected port. The service keeps running when this window closes."))
                    .font(.caption).foregroundStyle(.secondary)
                if !busy, !isRunning, let unavailableReason {
                    Text(unavailableReason).font(.callout).foregroundStyle(.secondary)
                }
                Button(IDELanguageRunText.t("启动网页服务", "Start web service")) {
                    Task { await start() }
                }
                .disabled(busy || isRunning || unavailableReason != nil)
                .accessibilityIdentifier("workspace.ide.service.start")
            }
            if busy { ProgressView() }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if let job {
                Section(IDELanguageRunText.t("服务状态与日志", "Service status and logs")) {
                    Text(IDEWebServicePolicy.stateTitle(job.state))
                    if job.state == .failed || job.state == .interrupted, let error = job.lastError {
                        Text(error).textSelection(.enabled)
                    }
                    if let progress {
                        if !progress.stdout.isEmpty || !progress.stderr.isEmpty {
                            DisclosureGroup("services.logs") {
                                Text(progress.stdout + "\n" + progress.stderr)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    // The service terminal (not this form) owns the browser
                    // action: it re-resolves the current ready endpoint at
                    // click and opens the existing in-app browser. This button
                    // only routes an already-observed job to that terminal.
                    if onServiceStarted != nil,
                       let owner,
                       let launch = serviceLaunch(for: job, conversationID: owner) {
                        Button(IDELanguageRunText.t("打开服务终端", "Open service terminal")) {
                            onServiceStarted?(launch)
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("workspace.ide.service.openTerminal")
                    }
                    if !job.state.isTerminal {
                        Button("services.stop", role: .destructive) {
                            Task {
                                do { self.job = try await center.environment.backgroundJobService?.cancel(id: job.id) }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(IDELanguageRunText.t("网页服务", "Web service"))
        .task {
            do {
                owners = try await SQLiteWorkspaceStore(database: center.environment.database).conversations(workspaceID: workspaceID)
                if owners.count == 1 { owner = owners[0] }
            } catch { failure = error.localizedDescription }
        }
        .task(id: owner) {
            guard let owner, job == nil, let entry else { return }
            do {
                let records = try await BackgroundJobStore(database: center.environment.database).jobs(conversationID: owner, limit: 100)
                let pinnedRoot = IDEServiceRunPolicy.standardizedPath(root.path)
                job = records.first { record in
                    guard record.targetTool == "exec.localService", !record.state.isTerminal,
                          let recordRoot = record.workspaceRootPath,
                          IDEServiceRunPolicy.standardizedPath(recordRoot) == pinnedRoot,
                          let args = try? JSONDecoder().decode(LocalServiceTool.Arguments.self, from: record.payloadJSON) else { return false }
                    return args.entry == entry
                }
            } catch { failure = error.localizedDescription }
        }
        .task(id: job?.id) {
            guard let id = job?.id else { return }
            while !Task.isCancelled {
                do {
                    job = try await BackgroundJobStore(database: center.environment.database).job(id: id)
                    if job?.state.isTerminal == true { return }
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch { failure = error.localizedDescription; return }
            }
        }
    }

    @MainActor private func createOwner() async {
        guard !busy, !isRunning, center.currentWorkspace?.id == workspaceID,
              center.currentRootURL == root else { return }
        busy = true; failure = nil
        defer { busy = false }
        do {
            let record = try await center.environment.conversationCenter.createConversation(
                title: IDELanguageRunText.t("网页预览", "Web preview"))
            try await center.ensureReviewConversationWorkspace(
                conversationID: record.id, workspaceID: workspaceID, title: record.title)
            owners = try await SQLiteWorkspaceStore(database: center.environment.database)
                .conversations(workspaceID: workspaceID)
            owner = record.id
        } catch { failure = error.localizedDescription }
    }

    @MainActor private func start() async {
        guard !busy, let owner, let runtime, let entry,
              let number = IDEWebServicePolicy.validPort(port),
              let service = center.environment.backgroundJobService else {
            failure = IDELanguageRunText.t("请输入 1024–65535 的端口并选择任务。", "Choose a task and a port from 1024 to 65535."); return
        }
        busy = true; failure = nil
        defer { busy = false }
        do {
            guard await state.saveAll(), state.activePath == entry,
                  center.currentWorkspace?.id == workspaceID, center.currentRootURL == root else {
                throw FloeError.validationFailed(IDELanguageRunText.t("文件未保存或工作区已改变。", "The file was not saved or the workspace changed."))
            }
            let allowed = try await SQLiteWorkspaceStore(database: center.environment.database).conversations(workspaceID: workspaceID)
            guard allowed.contains(owner) else { throw FloeError.validationFailed(IDELanguageRunText.t("该任务已无法访问这些文件。", "This task can no longer access these files.")) }
            let runID = UUID()
            let context = ToolContext(runID: runID, workspaceRootURL: root,
                                      cancellation: CancellationToken(), conversationID: owner)
            let lease = try await ToolEnvironmentRouting.shared.acquire(context)
            let environmentID = lease.context.environment?.id
            await lease.finish()
            guard let environmentID else { throw FloeError.validationFailed("No workspace execution environment") }
            guard center.currentWorkspace?.id == workspaceID, center.currentRootURL == root else {
                throw FloeError.validationFailed(IDELanguageRunText.t("工作区已更改，请重试。", "The workspace changed. Try again."))
            }
            let currentOwners = try await SQLiteWorkspaceStore(database: center.environment.database).conversations(workspaceID: workspaceID)
            guard currentOwners.contains(owner) else { throw FloeError.validationFailed(IDELanguageRunText.t("该任务已无法访问这些文件。", "This task can no longer access these files.")) }
            try await center.environment.runStore.saveRun(RunRecord(id: runID, conversationID: owner,
                state: "completed", goal: "IDE web service", startedAt: Date(), endedAt: Date()))
            try await center.environment.runStore.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: NativeServiceRunMetadata(runID: runID, conversationID: owner).payloadJSON())
            let directory = (entry as NSString).deletingLastPathComponent
            let args = LocalServiceTool.Arguments(runtime: runtime, entry: entry, arguments: [],
                                                 cwd: directory.isEmpty ? "." : directory, port: number)
            let submitted = try await service.submit(
                runID: runID, toolCallID: nil, targetTool: "exec.localService",
                payloadJSON: JSONEncoder().encode(args), scope: .local, workspaceRootURL: root,
                allowedWorkspacePaths: [], environmentID: environmentID, submissionSource: .nativeService
            )
            job = submitted
            // The submission awaited: resolve the pinned identity again before
            // routing. A changed workspace, root or task can never receive a
            // terminal for this service; the durable service itself keeps
            // running and remains visible in Services.
            guard submitted.conversationID == owner,
                  submitted.environmentID == environmentID,
                  let submittedRoot = submitted.workspaceRootPath,
                  IDEServiceRunPolicy.standardizedPath(submittedRoot)
                    == IDEServiceRunPolicy.standardizedPath(root.path),
                  center.currentWorkspace?.id == workspaceID,
                  center.currentRootURL == root,
                  let launch = serviceLaunch(
                    for: submitted, conversationID: owner
                  ) else {
                failure = IDELanguageRunText.t(
                    "服务已启动，但无法确认其当前工作区归属；请到“服务”中查看。",
                    "The service started, but its current workspace ownership could not be confirmed; check Services."
                )
                return
            }
            onServiceStarted?(launch)
        } catch { failure = error.localizedDescription }
    }

    /// Captures the durable job's actual runtime/entry/cwd/port and confirms it
    /// belongs to this form's pinned workspace, root and owning task. The form's
    /// current fields are never used as the route identity.
    private func serviceLaunch(
        for job: BackgroundJob, conversationID: UUID
    ) -> IDEServiceRunLaunch? {
        guard let identity = IDEServiceRunPolicy.identity(for: job, workspaceID: workspaceID),
              identity.conversationID == conversationID,
              identity.workspaceRootPath == IDEServiceRunPolicy.standardizedPath(root.path) else {
            return nil
        }
        return IDEServiceRunLaunch(identity: identity, job: job)
    }
}

#if DEBUG
/// DEBUG-only native acceptance fixture. It presents the REAL service terminal,
/// ordinary run terminal and in-app browser views over an in-memory fake
/// `exec.localService` job. It never opens the database, writes a workspace,
/// submits a durable job, calls a provider, or touches the microphone. The page
/// itself is served by the UI test process on loopback; this is UI evidence, not
/// proof of actual Linux guest-service execution.
enum IDERunWebPreviewFixture {
    static let launchArgument = "--ui-test-ide-web-preview-fixture"
    static let urlEnvironmentKey = "FLOE_IDE_WEB_PREVIEW_FIXTURE_URL"

    static var previewURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              arguments.contains(launchArgument),
              let raw = ProcessInfo.processInfo.environment[urlEnvironmentKey],
              let url = URL(string: raw),
              url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1",
              let port = url.port,
              (1024...65535).contains(port) else { return nil }
        return url
    }
}

@MainActor
struct IDERunWebPreviewFixtureHarness: View {
    private enum Screen: String, Identifiable {
        case service
        case run
        var id: String { rawValue }
    }

    @StateObject private var workbench: IDEWorkbenchState
    @StateObject private var runController: IDELanguageRunController
    @StateObject private var fixture: IDERunWebPreviewFixtureService
    @State private var presented: Screen?

    init(center: WorkspaceCenter, previewURL: URL) {
        let workbench = IDEWorkbenchState(files: nil)
        let runController = IDELanguageRunController(
            workspaceID: UUID(),
            root: FileManager.default.temporaryDirectory,
            center: center,
            state: workbench
        )
        let fixture = IDERunWebPreviewFixtureService(previewURL: previewURL)
        _workbench = StateObject(wrappedValue: workbench)
        _runController = StateObject(wrappedValue: runController)
        _fixture = StateObject(wrappedValue: fixture)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(IDELanguageRunText.t(
                        "仅用于 UI 验收：模拟的服务作业，不执行真实 Linux 服务。",
                        "UI acceptance only: a simulated service job; no real Linux service runs."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button {
                        presented = .service
                    } label: {
                        Label(IDELanguageRunText.t("服务终端", "Service terminal"), systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("fixture.serviceTerminal")
                    Button {
                        presented = .run
                    } label: {
                        Label(IDELanguageRunText.t("普通运行终端", "Ordinary run terminal"), systemImage: "terminal")
                    }
                    .accessibilityIdentifier("fixture.runTerminal")
                }
            }
            .navigationTitle("IDE Web Preview Fixture")
        }
        .sheet(item: $presented) { screen in
            switch screen {
            case .service:
                IDEServiceRunTerminalView(session: fixture.session)
            case .run:
                IDERunTerminalView(controller: runController)
            }
        }
    }
}

@MainActor
final class IDERunWebPreviewFixtureService: ObservableObject {
    let session: IDEServiceRunTerminalSession

    init(previewURL: URL) {
        let port = previewURL.port ?? 8080
        let entry = previewURL.lastPathComponent.isEmpty ? "index.html" : previewURL.lastPathComponent
        let arguments = LocalServiceTool.Arguments(
            runtime: "static", entry: entry, arguments: [], cwd: ".", port: port
        )
        let payload = (try? JSONEncoder().encode(arguments)) ?? Data()
        let conversationID = UUID(uuidString: "A7C0E2D4-1B3F-4C5D-8E6F-9012345678AB")!
        let jobID = UUID(uuidString: "B8D1F3E5-2C4A-4D6B-9F70-123456789ABC")!
        let runID = UUID(uuidString: "C9E2A4F6-3D5B-4E7C-A081-23456789ABCD")!
        let workspaceID = UUID(uuidString: "D0F3B5A7-4E6C-4F8D-B192-3456789ABCDE")!
        let rootPath = "/fixture/ide-web-preview"
        let progress = LocalServiceProgress(
            state: "running", runtime: "static", previewURL: previewURL.absoluteString,
            stdout: "fixture service ready\n", stderr: "", truncated: false
        )
        let job = BackgroundJob(
            id: jobID, conversationID: conversationID, runID: runID, kind: .tool,
            targetTool: "exec.localService", payloadJSON: payload, state: .running,
            progressJSON: try? JSONEncoder().encode(progress),
            workspaceRootPath: rootPath, environmentID: "ui-test-fixture"
        )
        let identity = IDEServiceRunIdentity(
            workspaceID: workspaceID, workspaceRootPath: rootPath,
            conversationID: conversationID, environmentID: "ui-test-fixture",
            runtime: "static", entry: entry, cwd: ".", port: port
        )
        let source = IDERunWebPreviewFixtureSource(job: job, progress: progress)
        session = IDEServiceRunTerminalSession(
            identity: identity, initialJob: job, source: source
        )
        BrowserURLPolicy.authorizeService(
            previewURL, owner: jobID, conversationID: conversationID
        )
    }
}

@MainActor
private final class IDERunWebPreviewFixtureSource: IDEServiceRunTerminalSource {
    private var job: BackgroundJob
    private var progress: LocalServiceProgress

    init(job: BackgroundJob, progress: LocalServiceProgress) {
        self.job = job
        self.progress = progress
    }

    func job(id: UUID) async throws -> BackgroundJob? {
        self.job.id == id ? self.job : nil
    }

    func jobs(conversationID: UUID) async throws -> [BackgroundJob] {
        job.conversationID == conversationID ? [job] : []
    }

    func cancel(id: UUID) async throws -> BackgroundJob {
        guard job.id == id else {
            throw FloeError.validationFailed("No fixture service owns that job ID")
        }
        job.state = .cancelled
        progress.state = "stopped"
        progress.previewURL = nil
        job.progressJSON = try? JSONEncoder().encode(progress)
        job.lastError = "Stop requested; fixture service stopped"
        BrowserURLPolicy.revokeService(owner: job.id)
        return job
    }
}
#endif
#endif

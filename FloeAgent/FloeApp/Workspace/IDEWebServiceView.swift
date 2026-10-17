// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence

enum IDEWebServicePolicy {
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
    @State private var owners: [UUID] = []
    @State private var owner: UUID?
    @State private var port = "8080"
    @State private var busy = false
    @State private var failure: String?
    @State private var job: BackgroundJob?
    @State private var preview = false

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
                    Text(LocalizedStringKey("services.state.\(job.state.rawValue)"))
                    if let error = job.lastError { Text(error).textSelection(.enabled) }
                    if let progress {
                        Text(progress.stdout + "\n" + progress.stderr)
                            .font(.caption.monospaced()).textSelection(.enabled)
                        if progress.state == "running", progress.previewURL != nil, !job.state.isTerminal {
                            Button("services.preview") { preview = true }
                        }
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
                job = records.first { record in
                    guard record.targetTool == "exec.localService", !record.state.isTerminal,
                          record.workspaceRootPath == root.path,
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
        .sheet(isPresented: $preview) {
            if let job { LocalServicePreview(job: job) }
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
            let directory = (entry as NSString).deletingLastPathComponent
            let args = LocalServiceTool.Arguments(runtime: runtime, entry: entry, arguments: [],
                                                 cwd: directory.isEmpty ? "." : directory, port: number)
            job = try await service.submit(runID: runID, toolCallID: nil, targetTool: "exec.localService",
                payloadJSON: JSONEncoder().encode(args), scope: .local, workspaceRootURL: root,
                allowedWorkspacePaths: [], environmentID: environmentID)
        } catch { failure = error.localizedDescription }
    }
}
#endif

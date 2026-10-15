#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import LocalAuthentication
import FloeCore
import FloeModels
import FloePersistence
import FloeExecution
import FloeAgentRuntime

// MARK: - Inspector-local presentation text
//
// New catalog keys are registered by the integration owner (see
// Local/Private/task-lifecycle-20261015/A/INTEGRATION.md). Until then the same
// bilingual text renders inline, so no raw dotted key can appear.

private enum TaskInspectorText {
    static let backgroundJobs = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.background_jobs",
        en: "Background jobs", zh: "后台作业")
    static let noBackgroundJobs = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.no_background_jobs",
        en: "No background jobs yet", zh: "暂无后台作业")
    static let cancelJob = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.cancel_job",
        en: "Cancel", zh: "取消")
    static let cancellationRequested = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.job_cancellation_requested",
        en: "Cancellation requested", zh: "已请求取消")
    static let loadMore = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.load_more_events",
        en: "Load more", zh: "加载更多")
    static let reload = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.reload",
        en: "Reload", zh: "重新加载")
    static let started = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.started",
        en: "Started", zh: "开始")
    static let childTranscript = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.child_transcript",
        en: "Transcript", zh: "记录")
    static let parentRun = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.parent_run",
        en: "Parent run", zh: "父运行")
    static let childLoadFailed = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.child_load_failed",
        en: "Could not load child sessions: %@", zh: "无法加载子会话：%@")
    static let transcriptLoadFailed = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.transcript_load_failed",
        en: "Could not load the child transcript: %@", zh: "无法加载子会话记录：%@")

    static let jobDetails = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.job_details",
        en: "Details", zh: "详细信息")
    static let jobSubmittedTool = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.job_submitted_tool",
        en: "Submitted tool:", zh: "提交工具：")
    static let jobIdentifier = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.job_identifier",
        en: "Task ID:", zh: "任务 ID：")

    /// User-facing title for a background task: the user's own purpose when
    /// present, otherwise what the task actually does — never the raw tool
    /// name (that stays in the Details disclosure and tool-facing logs).
    static func jobTitle(_ job: BackgroundJob) -> String {
        if let purpose = jobPurpose(job.payloadJSON), !purpose.isEmpty {
            return String(purpose.prefix(80))
        }
        let key: String
        let en: String
        let zh: String
        switch job.targetTool {
        case "exec.localPython": (key, en, zh) = ("run_python", "Run Python", "运行 Python")
        case "exec.shell": (key, en, zh) = ("run_command", "Run command", "运行命令")
        case "exec.localService": (key, en, zh) = ("start_service", "Start local service", "启动本地服务")
        case "network.download": (key, en, zh) = ("download", "Download file", "下载文件")
        case "network.http": (key, en, zh) = ("network", "Network request", "网络请求")
        case "web.fetch": (key, en, zh) = ("read_web", "Read web page", "读取网页")
        case "media.project": (key, en, zh) = ("media", "Export media", "导出媒体")
        case "video.edit", "video.interpolate", "video.superResolution":
            (key, en, zh) = ("video", "Process video", "处理视频")
        case "document.pdf.edit", "document.pdf.export":
            (key, en, zh) = ("pdf", "Process PDF", "处理 PDF")
        case "document.office.updateText", "document.office.edit":
            (key, en, zh) = ("office", "Process Office document", "处理 Office 文档")
        case "exec.javascript", "exec.wasm":
            (key, en, zh) = ("run_code", "Run code", "运行代码")
        default:
            (key, en, zh) = ("generic", "Background task", "后台任务")
        }
        return ChatBilingualCatalog.localized(
            key: "workbench.task_inspector_views.job_title.\(key)", en: en, zh: zh)
    }

    /// Optional short user-visible purpose persisted with the submit payload.
    static func jobPurpose(_ payloadJSON: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
              let purpose = object["purpose"] as? String else { return nil }
        return purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func jobStage(_ stage: NativeJobProgress.Stage) -> String {
        let key = "workbench.task_inspector_views.job_stage_\(stage.rawValue)"
        let texts: [NativeJobProgress.Stage: (en: String, zh: String)] = [
            .preparing: ("Preparing", "准备中"),
            .running: ("Running", "进行中"),
            .finalizing: ("Finalizing", "收尾中"),
            .verifying: ("Verifying", "校验中"),
            .cancelling: ("Cancelling", "取消中"),
        ]
        let text = texts[stage] ?? ("Running", "进行中")
        return ChatBilingualCatalog.localized(key: key, en: text.en, zh: text.zh)
    }

    /// Localized durable job state; the raw machine value never reaches the UI.
    static func jobState(_ state: BackgroundJobState) -> String {
        switch state {
        case .queued:
            ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.job_state_queued", en: "Queued", zh: "排队中")
        case .running:
            ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.job_state_running", en: "Running", zh: "进行中")
        case .completed:
            ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.job_state_completed", en: "Completed", zh: "已完成")
        case .failed:
            ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.job_state_failed", en: "Failed", zh: "失败")
        case .cancelled:
            ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.job_state_cancelled", en: "Cancelled", zh: "已取消")
        case .interrupted:
            ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.job_state_interrupted", en: "Interrupted", zh: "已中断")
        }
    }

    static func jobStateColor(_ state: BackgroundJobState) -> Color {
        switch state {
        case .queued, .cancelled, .interrupted: .secondary
        case .running: FloeTheme.primary
        case .completed: FloeTheme.success
        case .failed: FloeTheme.destructive
        }
    }

    static let noChildEvents = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.no_child_events",
        en: "No child records yet", zh: "暂无子会话记录")
    static let iterations = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.iterations",
        en: "Iterations", zh: "迭代")
    static let resultTruncated = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.result_truncated",
        en: "The stored result was explicitly truncated at the size bound.",
        zh: "存储结果已按大小上限显式截断。")
    static let viewFullOutput = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.view_full_output",
        en: "View full output", zh: "查看完整输出")
    static let outputUnavailable = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.output_unavailable",
        en: "The retained output is no longer available.", zh: "已保留的输出不再可用。")
    static let outputEnd = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.output_end",
        en: "End of the stored output.", zh: "已到存储输出的末尾。")
    static let outputChanged = ChatBilingualCatalog.localized(
        key: "workbench.task_inspector_views.output_changed",
        en: "The stored output changed after the job finished; showing what exists now.",
        zh: "任务完成后存储的输出已更改；此处显示当前内容。")
    static let waitingForBackgroundWork = ChatBilingualCatalog.localized(
        key: "state.waiting_for_background_work",
        en: "Waiting for background work", zh: "等待后台作业")

    /// Localized durable child state; the raw machine value never reaches the
    /// UI. `ChildRunState` is the lifecycle owner's vocabulary.
    static func childState(_ state: ChildRunState) -> String {
        childStateName(state.rawValue)
    }

    static func childStateName(_ raw: String) -> String {
        switch raw {
        case "registered":
            return FloeL10n.l("state.preparing")
        case "running":
            return FloeL10n.l("state.running")
        case "completed":
            return FloeL10n.l("state.completed")
        case "partial":
            return ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.child_state_partial",
                en: "Incomplete", zh: "未完成")
        case "budgetExhausted":
            return ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.child_state_budget_exhausted",
                en: "Budget exhausted", zh: "已达预算上限")
        case "cancelled":
            return ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.child_state_cancelled",
                en: "Cancelled", zh: "已取消")
        case "providerError":
            return ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.child_state_provider_error",
                en: "Provider error", zh: "服务商错误")
        case "toolError":
            return ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.child_state_tool_error",
                en: "Tool error", zh: "工具错误")
        case "interrupted":
            return ChatBilingualCatalog.localized(
                key: "workbench.task_inspector_views.child_state_interrupted",
                en: "Interrupted", zh: "已中断")
        default:
            return FloeL10n.l("state.unknown")
        }
    }

    static func childStateColor(_ state: ChildRunState) -> Color {
        switch state {
        case .registered, .running: FloeTheme.primary
        case .completed: FloeTheme.success
        case .partial, .budgetExhausted, .providerError, .toolError: FloeTheme.destructive
        case .cancelled, .interrupted: .secondary
        }
    }

    /// Localized `SubagentOutcome.Status` raw value carried by a `.result`
    /// entry; unknown values fall back to the honest unknown state.
    static func childResultStatus(_ raw: String) -> String {
        raw.isEmpty ? FloeL10n.l("state.unknown") : childStateName(raw)
    }
}

// MARK: - Progress (runs + background jobs)

struct TaskProgressInspectorView: View {
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var runs: [RunRecord] = []
    @State private var jobs: [BackgroundJob] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var cancelError: String?

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                        .accessibilityIdentifier("inspector.progress.error")
                }
            }
            if let cancelError {
                Section {
                    Text(cancelError)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                }
            }
            Section("chat.thread_detail_view.progress") {
                if runs.isEmpty && !isLoading {
                    Text("workbench.task_inspector_views.no_run_progress_yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    RunProgressRow(run: run)
                }
            }
            Section {
                if jobs.isEmpty && !isLoading {
                    Text(TaskInspectorText.noBackgroundJobs)
                        .foregroundStyle(.secondary)
                }
                ForEach(jobs) { job in
                    BackgroundJobInspectorRow(job: job) {
                        Task { await cancel(job) }
                    }
                }
            } header: {
                Text(TaskInspectorText.backgroundJobs)
            }
        }
        .navigationTitle("chat.thread_detail_view.progress")
        .refreshable { await load() }
        .task(id: conversationID) {
            await load()
            await pollWhileActive()
        }
    }

    /// Bounded visible-panel polling while a job or run is non-terminal, so
    /// the real phase/state stays current; stops on disappear and when
    /// nothing is active.
    private func pollWhileActive() async {
        while !Task.isCancelled {
            let hasActiveJob = jobs.contains { !$0.state.isTerminal }
            let hasActiveRun = runs.contains { !RunStateLocalizer.isTerminal($0.state)
                && $0.state != "checkpointed" }
            guard hasActiveJob || hasActiveRun else { return }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await load()
        }
    }

    private func load() async {
        guard let conversationID else {
            runs = []; jobs = []; loadError = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            runs = try await environment.runStore.runs(conversationID: conversationID)
        } catch {
            loadError = error.localizedDescription
            return
        }
        do {
            jobs = try await BackgroundJobStore(database: environment.database)
                .jobs(conversationID: conversationID)
        } catch {
            jobs = []
            loadError = error.localizedDescription
            return
        }
        loadError = nil
    }

    /// Cancellation is a durable REQUEST handled by the job service (queued
    /// work cancels directly; running work stays non-terminal until its
    /// processor acknowledges). The inspector never claims success itself.
    private func cancel(_ job: BackgroundJob) async {
        guard !job.state.isTerminal else { return }
        do {
            guard let service = environment.backgroundJobService else {
                cancelError = FloeL10n.l("chat.thread_detail_view_model.media_task_status_is_temporarily_unavailable")
                return
            }
            _ = try await service.cancel(id: job.id)
            cancelError = nil
            await load()
        } catch {
            cancelError = error.localizedDescription
        }
    }
}

/// One run row. A run parked because required background jobs are still
/// outstanding (`checkpointed` + `awaiting.finite.job:<ids>`) is presented as
/// WAITING — not as a completed task. A non-terminal run shows an
/// indeterminate spinner instead of an invented percentage.
private struct RunProgressRow: View {
    let run: RunRecord
    @EnvironmentObject private var environment: AppEnvironment
    @State private var waitingJobIdentifiers: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if waitingJobIdentifiers != nil {
                    Text(TaskInspectorText.waitingForBackgroundWork)
                } else {
                    Text(RunStateLocalizer.title(for: run.state))
                }
                Spacer()
                Text(run.startedAt, style: .time).foregroundStyle(.secondary)
            }
            if let waitingJobIdentifiers {
                Text(waitingJobIdentifiers)
                    .font(.caption)
                    .foregroundStyle(FloeTheme.pending)
                    .accessibilityIdentifier("inspector.run.waiting")
            } else if !RunStateLocalizer.isTerminal(run.state) {
                ProgressView().controlSize(.small)
            } else if run.state == "checkpointed" {
                // A non-dependency checkpoint is an ordinary paused run.
                ProgressView().controlSize(.small)
            }
            Text(run.goal).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.vertical, 4)
        .task(id: run.id) { await loadWaitingReason() }
    }

    /// The durable reason is on the run's terminal status event
    /// (`awaiting.finite.job:<jobIDs>`), written before the run parked.
    private func loadWaitingReason() async {
        guard run.state == "checkpointed" else {
            waitingJobIdentifiers = nil
            return
        }
        guard let events = try? await environment.runStore
            .recentEvents(runID: run.id, limit: 8) else { return }
        for event in events.reversed() where event.kind == .status {
            let payload = ConversationCenter.decodePayload(event.payloadJSON)
            guard let reason = payload["reason"],
                  reason.hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix) else { continue }
            let identifiers = reason
                .dropFirst(FloeAgentRuntime.dependencyWaitReasonPrefix.count)
                .drop { $0 == ":" }
                .split(separator: ",")
                .map { String($0.prefix(8)) }
            waitingJobIdentifiers = identifiers.isEmpty
                ? nil
                : identifiers.joined(separator: ", ")
            return
        }
    }
}

/// One durable background job: stage/phase, real units when the processor
/// reported them, result preview with explicit expansion, error text and the
/// cancellation control. Never a fabricated fraction.
private struct BackgroundJobInspectorRow: View {
    let job: BackgroundJob
    let onCancel: () -> Void
    @State private var resultExpanded = false
    @State private var showsFullOutput = false
    @State private var showsDetails = false

    private var progressDocument: NativeJobProgressDocument? {
        NativeJobProgressDocument.decode(job.progressJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(TaskInspectorText.jobTitle(job), systemImage: job.kind == .download ? "arrow.down.circle" : "gearshape.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(TaskInspectorText.jobState(job.state))
                    .font(.caption)
                    .foregroundStyle(TaskInspectorText.jobStateColor(job.state))
            }
            HStack(spacing: 8) {
                Text(job.createdAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let document = progressDocument {
                if let progress = document.progress {
                    HStack(spacing: 8) {
                        Text(TaskInspectorText.jobStage(progress.stage))
                        if let phase = progress.phase, !phase.isEmpty {
                            Text(phase).foregroundStyle(.secondary)
                        }
                        if let completed = progress.completedUnits,
                           let total = progress.totalUnits, total > 0 {
                            Text("\(completed)/\(total)").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else if !job.state.isTerminal {
                        ProgressView().controlSize(.small)
                    }
                    if let note = progress.note, !note.isEmpty {
                        Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if document.cancellationRequested == true, !job.state.isTerminal {
                    Text(TaskInspectorText.cancellationRequested)
                        .font(.caption)
                        .foregroundStyle(FloeTheme.pending)
                }
            } else if !job.state.isTerminal {
                ProgressView().controlSize(.small)
            }

            if let error = job.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .lineLimit(4)
            }
            if let result = job.resultSummary, !result.isEmpty {
                InspectorBoundedEvidence(text: result, isExpanded: $resultExpanded)
            }
            if job.outputPath != nil {
                // The complete retained output lives in the job's bounded
                // spool artifact; open it through the same guarded paging
                // reader the model's `jobs.result` uses instead of dumping the
                // whole file into this row.
                Button {
                    showsFullOutput = true
                } label: {
                    Label(TaskInspectorText.viewFullOutput, systemImage: "doc.text.magnifyingglass")
                }
                .font(.caption)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("inspector.job.fullOutput.\(job.id.uuidString)")
            }
            if let path = job.resultPath, !path.isEmpty {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Exact identifiers stay behind an explicitly opened disclosure;
            // the ordinary card shows only the user-facing title and state.
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TaskInspectorText.parentRun + " " + job.runID.uuidString)
                    Text(TaskInspectorText.jobSubmittedTool + " " + job.targetTool)
                    Text(TaskInspectorText.jobIdentifier + " " + job.id.uuidString)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .accessibilityIdentifier("inspector.job.details.\(job.id.uuidString)")
            } label: {
                Text(TaskInspectorText.jobDetails)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44, alignment: .leading)
            if !job.state.isTerminal {
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Text(TaskInspectorText.cancelJob)
                }
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("inspector.job.cancel.\(job.id.uuidString)")
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showsFullOutput) {
            JobOutputViewerSheet(job: job)
        }
    }
}

/// Read-only pager over the job's retained output artifact.
///
/// Every page is a bounded, UTF-8-safe window read through
/// `BackgroundJobOutputSpool.readPage` (the same reader the model's
/// `jobs.result` tool uses); the sheet never loads the whole file at once and
/// states the real completeness (a capped artifact is explicitly NOT the whole
/// output). Load failures are reported honestly instead of showing an empty
/// transcript.
private struct JobOutputViewerSheet: View {
    let job: BackgroundJob
    @Environment(\.dismiss) private var dismiss
    @State private var page: BackgroundJobOutputPage?
    @State private var loadedText = ""
    @State private var loadError: String?
    @State private var isLoading = false

    private let pageBytes = 16_384

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.destructive)
                            .accessibilityIdentifier("inspector.job.fullOutput.error")
                    }
                    Text(loadedText)
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    if let page,
                       page.nextOffset != nil {
                        Button {
                            Task { await load(offset: page.nextOffset ?? 0) }
                        } label: {
                            Text(TaskInspectorText.loadMore)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(isLoading)
                        .accessibilityIdentifier("inspector.job.fullOutput.nextPage")
                    } else if let page, page.nextOffset == nil {
                        Text(page.complete == false
                            ? TaskInspectorText.resultTruncated
                            : TaskInspectorText.outputEnd)
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                        if page.changedSinceRecorded {
                            Text(TaskInspectorText.outputChanged)
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(FloeTheme.pending)
                        }
                    }
                    if let path = job.resultPath, !path.isEmpty {
                        Text(path)
                            .font(FloeTheme.Typography.evidence)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle(TaskInspectorText.viewFullOutput)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "providers.save.done")) { dismiss() }
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
            }
            .task { await load(offset: 0) }
        }
    }

    private func load(offset: Int) async {
        isLoading = true
        defer { isLoading = false }
        guard let path = job.outputPath else {
            loadError = TaskInspectorText.outputUnavailable
            return
        }
        let loaded = BackgroundJobOutputSpool.readPage(
            jobID: job.id, path: path, offset: offset, maxBytes: pageBytes,
            recordedBytes: job.outputBytes)
        guard let loaded, let text = loaded.text else {
            if offset == 0 {
                loadError = TaskInspectorText.outputUnavailable
            } else {
                loadError = TaskInspectorText.outputEnd
            }
            return
        }
        loadError = nil
        page = loaded
        if offset == 0 {
            loadedText = text
        } else {
            loadedText += text
        }
    }
}

/// Pure, layout-free evidence-clamp policy shared by every bounded evidence
/// surface in the inspector.
///
/// A `lineLimit` clamp can hide content of a SHORT string too (any text that
/// wraps past the clamp), so an expand affordance may not be gated on a large
/// character count alone. The estimate is deliberately measured from the
/// string only — character count or explicit line breaks — never from
/// rendered geometry, so the historical geometry-feedback crash cannot return.
enum FloeBoundedEvidencePolicy {
    /// Character bound above which a wrapped result can hide behind a
    /// ~6-line clamp on any realistic compact width.
    static let defaultCharacterBound = 160

    static func clampedContentMayBeHidden(
        _ text: String,
        lineBound: Int,
        characterBound: Int = defaultCharacterBound
    ) -> Bool {
        if text.count > characterBound { return true }
        var breaks = 0
        for character in text where character == "\n" {
            breaks += 1
            if breaks >= lineBound { return true }
        }
        return false
    }
}

/// Bounded result preview with an explicit "show more" expansion; the durable
/// full output stays in the job record/artifact and is never truncated by the
/// view.
private struct InspectorBoundedEvidence: View {
    let text: String
    @Binding var isExpanded: Bool
    private let step = 8_192
    /// Explicit line-break bound of the collapsed clamp.
    private let collapsibleLineBound = 6

    var body: some View {
        let limit = isExpanded ? max(step, text.count) : step
        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        VStack(alignment: .leading, spacing: 2) {
            Text(String(text[..<end]))
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 6)
            if isExpanded || FloeBoundedEvidencePolicy.clampedContentMayBeHidden(
                text, lineBound: collapsibleLineBound) {
                Button(isExpanded
                    ? String(localized: "terminal.hide")
                    : TaskInspectorText.loadMore) {
                    isExpanded.toggle()
                }
                .font(.caption)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("inspector.evidence.toggle")
            }
        }
    }
}

// MARK: - Child agents (durable child runs + paged transcript)

struct ChildAgentsInspectorView: View {
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @State private var children: [ChildRunRecord] = []
    @State private var hasActiveParentRun = false
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            String(format: TaskInspectorText.childLoadFailed, loadError),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                        Button(TaskInspectorText.reload) {
                            Task { await load() }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("inspector.childAgents.error")
                }
            }
            if children.isEmpty && !isLoading && loadError == nil {
                ContentUnavailableView(
                    "workbench.task_inspector_views.no_sub_agents",
                    systemImage: "person.2.slash"
                )
            }
            ForEach(children) { child in
                NavigationLink(value: ChildAgentRoute(childRunID: child.id)) {
                    ChildAgentSessionRow(child: child)
                }
            }
        }
        .navigationTitle("chat.thread_detail_view.subagents")
        .navigationDestination(for: ChildAgentRoute.self) { route in
            ChildAgentDetailView(childRunID: route.childRunID)
        }
        .refreshable { await load() }
        .task(id: conversationID) {
            await load()
            await pollWhileActive()
        }
    }

    private func load() async {
        guard let conversationID else {
            children = []; hasActiveParentRun = false; loadError = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            // The lifecycle owner's typed store is the single source of truth;
            // the old hand-written `runs` join (with the never-existing
            // `budget_tokens` column and a swallowed error) is gone.
            children = try await SQLiteChildRunStore(database: environment.database)
                .children(conversationID: conversationID)
            let runs = (try? await environment.runStore.runs(conversationID: conversationID)) ?? []
            hasActiveParentRun = runs.contains { !RunStateLocalizer.isTerminal($0.state) }
            loadError = nil
        } catch {
            // Never swallow a failure: an unreadable store is reported, not
            // rendered as an empty "no sub-agents" state.
            children = []
            hasActiveParentRun = false
            loadError = error.localizedDescription
        }
    }

    /// Bounded visible-panel polling until every child is terminal. The panel
    /// stops polling on disappear (task cancellation) and while the
    /// conversation has no active run, so an idle inspector never refreshes
    /// in the background.
    private func pollWhileActive() async {
        while !Task.isCancelled {
            guard children.contains(where: { !$0.state.isTerminal }) || hasActiveParentRun else {
                return
            }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await load()
        }
    }
}

private struct ChildAgentRoute: Hashable {
    let childRunID: UUID
}

private struct ChildAgentSessionRow: View {
    let child: ChildRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(TaskInspectorText.childState(child.state), systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TaskInspectorText.childStateColor(child.state))
                Spacer()
                Text(child.startedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("\(TaskInspectorText.started) \(child.startedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("\(TaskInspectorText.iterations) \(child.iterationCount)")
                if !child.kind.isEmpty {
                    Text(child.kind)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        let summary = child.taskSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "delegate #\(child.childIndex)" : summary
    }
}

/// One child session: the durable record plus its paged transcript/tool/result
/// entries read through `SQLiteChildRunStore`, so reopening the app (or this
/// inspector) replays the real history instead of an in-memory copy. Live
/// state and new entries refresh through bounded polling while the child is
/// non-terminal.
struct ChildAgentDetailView: View {
    let childRunID: UUID

    @EnvironmentObject private var environment: AppEnvironment
    @State private var child: ChildRunRecord?
    @State private var entries: [ChildRunEntry] = []
    @State private var cursor = 0
    @State private var hasMorePage = false
    @State private var isLoadingPage = false
    @State private var loadError: String?

    private let pageSize = 80

    var body: some View {
        List {
            if let child {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(TaskInspectorText.childState(child.state), systemImage: "person.2")
                            .foregroundStyle(TaskInspectorText.childStateColor(child.state))
                        if !child.taskSummary.isEmpty {
                            Text(child.taskSummary).font(.subheadline)
                        }
                        if let error = child.errorText, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(FloeTheme.destructive)
                        }
                        HStack(spacing: 8) {
                            Text("\(TaskInspectorText.parentRun) \(String(child.parentRunID.uuidString.prefix(8)))")
                            Text("\(TaskInspectorText.iterations) \(child.iterationCount)")
                            if let endedAt = child.endedAt {
                                Text(endedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            String(format: TaskInspectorText.transcriptLoadFailed, loadError),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                        Button(TaskInspectorText.reload) {
                            Task { await reload() }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("inspector.childDetail.error")
                }
            }
            Section {
                if entries.isEmpty && !isLoadingPage && loadError == nil {
                    Text(TaskInspectorText.noChildEvents)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    ChildRunEntryRow(
                        entry: row.entry,
                        toolStatus: row.toolStatus,
                        toolOutput: row.toolOutput
                    )
                }
                if hasMorePage {
                    Button(TaskInspectorText.loadMore) {
                        Task { await loadNextPage() }
                    }
                    .disabled(isLoadingPage)
                    .frame(minHeight: 44)
                }
            } header: {
                Text(TaskInspectorText.childTranscript)
            }
        }
        .navigationTitle(TaskInspectorText.childTranscript)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel(TaskInspectorText.reload)
            }
        }
        .task(id: childRunID) {
            await reload()
            await pollWhileActive()
        }
    }

    private struct ChildTranscriptRow: Identifiable {
        let entry: ChildRunEntry
        let toolStatus: String?
        let toolOutput: String?
        var id: UUID { entry.id }
    }

    /// Pairs each tool request with its later result by call id within the
    /// loaded durable entries; the paired result row is folded into the
    /// request's evidence (no output shown twice, none dropped).
    private var rows: [ChildTranscriptRow] {
        var requestCallIDs = Set<String>()
        for entry in entries where entry.kind == .toolRequest {
            let payload = ConversationCenter.decodePayload(entry.payloadJSON)
            if let callID = payload["callID"], !callID.isEmpty { requestCallIDs.insert(callID) }
        }
        var resultsByCallID: [String: [String: String]] = [:]
        for entry in entries where entry.kind == .toolResult {
            let payload = ConversationCenter.decodePayload(entry.payloadJSON)
            if let callID = payload["callID"], !callID.isEmpty, requestCallIDs.contains(callID) {
                resultsByCallID[callID] = payload
            }
        }
        return entries.compactMap { entry in
            let payload = ConversationCenter.decodePayload(entry.payloadJSON)
            switch entry.kind {
            case .toolResult:
                if let callID = payload["callID"], !callID.isEmpty,
                   requestCallIDs.contains(callID) {
                    return nil
                }
                return ChildTranscriptRow(
                    entry: entry, toolStatus: payload["status"], toolOutput: nil)
            case .toolRequest:
                let callID = payload["callID"] ?? ""
                let result = resultsByCallID[callID]
                return ChildTranscriptRow(
                    entry: entry,
                    toolStatus: result?["status"] ?? "pending",
                    toolOutput: result?["output"])
            default:
                return ChildTranscriptRow(entry: entry, toolStatus: nil, toolOutput: nil)
            }
        }
    }

    private func reload() async {
        entries = []
        cursor = 0
        hasMorePage = false
        loadError = nil
        do {
            child = try await SQLiteChildRunStore(database: environment.database).child(id: childRunID)
        } catch {
            // A failed record read is reported, never silently blanked.
            loadError = error.localizedDescription
        }
        await loadNextPage()
    }

    /// Appends the next durable page. Paging is cursor-based on the store's
    /// per-child sequence, so a concurrent writer can only add rows the next
    /// call picks up (sequence gaps are legal).
    private func loadNextPage() async {
        guard !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        do {
            let page = try await SQLiteChildRunStore(database: environment.database)
                .entries(childRunID: childRunID, afterSequence: cursor, limit: pageSize)
            for entry in page.entries where !entries.contains(where: { $0.id == entry.id }) {
                entries.append(entry)
            }
            if let last = page.entries.last, last.sequence > cursor {
                cursor = last.sequence
            }
            // `nextSequence` is only returned when the store already knows
            // more rows exist; polling below handles later appends.
            hasMorePage = page.nextSequence != nil
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Bounded visible-panel polling while the child is non-terminal: refreshes
    /// both the durable record (state/iteration) and any newly appended
    /// entries, then stops as soon as the child reaches a terminal state.
    private func pollWhileActive() async {
        while !Task.isCancelled {
            do {
                child = try await SQLiteChildRunStore(database: environment.database)
                    .child(id: childRunID)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            guard let child, !child.state.isTerminal else { return }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await loadNextPage()
        }
    }
}

/// Renders one durable child transcript entry by kind. Tool request/result
/// pairs are matched by the caller (see `ChildTranscriptRow`) so one
/// invocation owns its input and output.
private struct ChildRunEntryRow: View {
    let entry: ChildRunEntry
    let toolStatus: String?
    let toolOutput: String?
    /// Explicit expansion for the bounded evidence surfaces: a child's final
    /// `.result` findings (up to 8 KiB durable) and any long message payload
    /// must be fully readable, not clipped at a dozen lines.
    @State private var evidenceExpanded = false

    var body: some View {
        switch entry.kind {
        case .message:
            let payload = Self.payload(entry.payloadJSON)
            if let text = payload["text"], !text.isEmpty {
                AssistantMessageView(text: text)
            } else {
                boundedEvidence(entry.payloadJSON)
            }
        case .toolRequest:
            let payload = Self.payload(entry.payloadJSON)
            ToolCallCardView(
                name: payload["tool"] ?? "tool",
                status: toolStatus ?? "pending",
                inputSummary: payload["arguments"],
                resultSummary: toolOutput
            )
        case .toolResult:
            let payload = Self.payload(entry.payloadJSON)
            ToolCallCardView(
                name: payload["tool"] ?? String(localized: "tool.result"),
                status: payload["status"] ?? "ok",
                resultSummary: payload["output"]
            )
        case .result:
            let payload = Self.payload(entry.payloadJSON)
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    TaskInspectorText.childResultStatus(payload["status"] ?? ""),
                    systemImage: "flag.checkered"
                )
                .font(.subheadline.weight(.semibold))
                if let findings = payload["findings"], !findings.isEmpty {
                    boundedEvidence(findings)
                }
                if let unfinished = payload["unfinished"], !unfinished.isEmpty {
                    Text(unfinished)
                        .font(.caption2)
                        .foregroundStyle(FloeTheme.pending)
                }
                if payload["truncated"] == "true" {
                    Text(TaskInspectorText.resultTruncated)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            let payload = Self.payload(entry.payloadJSON)
            Label(
                payload["message"] ?? entry.payloadJSON,
                systemImage: "exclamationmark.octagon"
            )
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(FloeTheme.destructive)
        case .state:
            let payload = Self.payload(entry.payloadJSON)
            Text(TaskInspectorText.childStateName(payload["state"] ?? entry.payloadJSON))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func boundedEvidence(_ text: String) -> some View {
        let lineBound = 12
        return VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(evidenceExpanded ? nil : lineBound)
                .frame(maxWidth: .infinity, alignment: .leading)
            if evidenceExpanded || FloeBoundedEvidencePolicy.clampedContentMayBeHidden(
                text, lineBound: lineBound) {
                Button(evidenceExpanded
                    ? String(localized: "terminal.hide")
                    : TaskInspectorText.loadMore) {
                    evidenceExpanded.toggle()
                }
                .font(.caption)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("inspector.childEntry.toggle")
            }
        }
    }

    private static func payload(_ json: String) -> [String: String] {
        ConversationCenter.decodePayload(json)
    }
}

struct TaskPermissionsInspectorView: View {
    let conversationID: UUID?
    var isLocalModel: Bool? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @State private var policy: TaskPolicy?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSave = false
    @State private var resolvedIsLocalModel = false

    var body: some View {
        Form {
            if policy != nil {
                Section("home.draft_task_permissions_sheet.approval_mode") {
                    Picker("workbench.task_inspector_views.this_task", selection: approvalModeBinding) {
                        Text("settings.agent_permissions_view.ask").tag(TaskApprovalMode.ask.rawValue)
                        Text("settings.agent_permissions_view.auto_approve").tag(TaskApprovalMode.automatic.rawValue)
                        Text("settings.agent_permissions_view.full_access")
                            .tag(TaskApprovalMode.fullAccess.rawValue)
                            .disabled(resolvedIsLocalModel)
                    }
                    .pickerStyle(.segmented)
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("workbench.task_inspector_views.task_settings") {
                    Picker("workbench.task_inspector_views.background_recovery", selection: binding(\.recoveryPolicy, fallback: .safePoint)) {
                        Text("workbench.task_inspector_views.auto_resume_from_safety_point").tag(TaskRecoveryPolicy.safePoint)
                        Text("workbench.task_inspector_views.always_retry_automatically").tag(TaskRecoveryPolicy.alwaysRetry)
                    }
                    Picker("workbench.task_inspector_views.notifications", selection: binding(\.notificationPolicy, fallback: .stages)) {
                        Text("media.media_editor_view.close").tag(TaskNotificationPolicy.off)
                        Text("workbench.task_inspector_views.completion_failure_only").tag(TaskNotificationPolicy.terminal)
                        Text("workbench.task_inspector_views.approvals_and_exceptions").tag(TaskNotificationPolicy.critical)
                        Text("workbench.task_inspector_views.stage_progress").tag(TaskNotificationPolicy.stages)
                    }
                }
                Section {
                    if isSaving {
                        Label("workspace.office_document_editor_view.saving", systemImage: "arrow.triangle.2.circlepath")
                    } else if didSave {
                        Label("workbench.task_inspector_views.saved_and_applied_to_the_current", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("workbench.task_inspector_views.changes_save_automatically_and_apply_to")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("workbench.task_inspector_views.the_task_remains_limited_by_workspace")
                }
            } else {
                ContentUnavailableView("workbench.task_inspector_views.choose_a_task", systemImage: "lock.shield")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("workspace.file_inspector_view.permissions")
        .task(id: conversationID) { await load() }
    }

    private var approvalModeBinding: Binding<String> {
        Binding<String>(
            get: { policy?.resolvedApprovalMode.rawValue ?? TaskApprovalMode.ask.rawValue },
            set: { value in
                if value == TaskApprovalMode.fullAccess.rawValue {
                    guard !resolvedIsLocalModel else { return }
                    Task { await authenticateFullAccess() }
                } else {
                    policy?.approvalMode = value
                    Task { await save() }
                }
            }
        )
    }

    private var modeExplanation: String {
        switch policy?.resolvedApprovalMode ?? .ask {
        case .ask: FloeL10n.l("home.draft_task_permissions_sheet.reads_run_automatically_side_effecting_actions")
        case .automatic: FloeL10n.l("workbench.task_inspector_views.routine_in_scope_steps_toward_the")
        case .fullAccess: FloeL10n.l("workbench.task_inspector_views.tools_for_this_task_run_automatically")
        }
    }

    private func authenticateFullAccess() async {
        guard !resolvedIsLocalModel else { return }
        do {
            let allowed = try await DeviceOwnerAuthenticator.authenticate(
                reason: FloeL10n.l("workbench.task_inspector_views.confirm_enabling_full_access_for_this")
            )
            if allowed {
                policy?.approvalMode = TaskApprovalMode.fullAccess.rawValue
                await save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<TaskPolicy, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { policy?[keyPath: keyPath] ?? fallback },
            set: { value in
                policy?[keyPath: keyPath] = value
                Task { await save() }
            }
        )
    }

    private func load() async {
        guard let conversationID else { policy = nil; return }
        let store = SQLiteWorkspaceStore(database: environment.database)
        policy = (try? await store.taskPolicy(conversationID: conversationID))
            ?? TaskPolicy(conversationID: conversationID)
        if let isLocalModel {
            resolvedIsLocalModel = isLocalModel
        } else if let modelID = (try? await environment.runStore
            .runs(conversationID: conversationID))?.first?.modelID {
            resolvedIsLocalModel = environment.conversationCenter
                .providerAndModel(modelID: modelID)?.0.kind == .local
        } else {
            resolvedIsLocalModel = false
        }
        if resolvedIsLocalModel,
           policy?.resolvedApprovalMode == .fullAccess {
            policy?.approvalMode = TaskApprovalMode.automatic.rawValue
        }
    }

    private func save() async {
        guard var policy else { return }
        isSaving = true
        defer { isSaving = false }
        policy.updatedAt = Date()
        // Defensive: a save that fails (e.g. the conversation row vanished
        // mid-edit, or the DB is momentarily locked) surfaces as an inline
        // error instead of crashing the inspector.
        do {
            try await environment.conversationCenter.updateTaskPolicy(policy)
            self.policy = policy
            errorMessage = nil
            didSave = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                didSave = false
            }
        } catch {
            errorMessage = error.localizedDescription
            FloeLogger(category: .app).error("taskPolicySaveFailed conversation=\(policy.conversationID.uuidString) error=\(error.localizedDescription)")
        }
    }
}
#endif

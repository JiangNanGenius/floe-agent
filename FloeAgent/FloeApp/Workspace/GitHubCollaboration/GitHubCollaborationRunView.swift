// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGit

struct GitHubCollaborationRunReader: Sendable {
    let client: GitHubCollaborationClient
    let repository: GitHubLinkRepositoryID
    let run: GitHubActionAttempt
    func jobs(token: String) async throws -> [GitHubActionsJob] {
        try await requireAttempt(token)
        let result = try await client.client.jobs(owner: repository.owner, repository: repository.name,
            runID: run.id, token: token, maxPages: 3)
        try await requireAttempt(token)
        try Task.checkCancellation()
        return result
    }
    func log(jobID: Int64, token: String) async throws -> GitHubActionsLogSlice {
        // Reopening a log retains the original run/attempt, not merely a job
        // id from a stale view. Only a job actually returned for it is read.
        guard try await jobs(token: token).contains(where: { $0.id == jobID }) else { throw GitHubLinkError.sourceChanged }
        let slice = try await client.client.jobLog(owner: repository.owner, repository: repository.name,
            jobID: jobID, token: token, maxBytes: 128 * 1024)
        try await requireAttempt(token)
        try Task.checkCancellation()
        return .init(text: SecretRedactor.redact(slice.text), truncated: slice.truncated, byteCount: slice.byteCount)
    }
    private func requireAttempt(_ token: String) async throws {
        let current = try await client.actionAttempt(repository, runID: run.id, token: token)
        guard current.id == run.id, current.runAttempt == run.runAttempt, current.headSHA == run.headSHA else { throw GitHubLinkError.sourceChanged }
    }
}

/// Uses the existing bounded Actions reader, without dispatching another run.
/// A rerun changing the selected attempt fences its jobs and logs.
struct GitHubCollaborationRunView: View {
    let center: GitHubCollaborationCenter
    let run: GitHubActionAttempt
    @State private var jobs: [GitHubActionsJob] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                LabeledContent(ghCollabText("运行", "Run"), value: "#\(run.id)")
                LabeledContent(ghCollabText("尝试次数", "Attempt"), value: String(run.runAttempt))
                Text(String(run.headSHA.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Section(ghCollabText("任务", "Jobs")) {
                ForEach(jobs) { job in
                    NavigationLink {
                        GitHubCollaborationLogView(center: center, run: run, job: job)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(job.name, systemImage: symbol(job))
                            Text(state(job)).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("github.collaboration.job.\(job.id)")
                }
                if loading { ProgressView(ghCollabText("正在读取任务", "Loading jobs")) }
                else if jobs.isEmpty && error == nil {
                    Text(ghCollabText("此运行尚无任务。", "No jobs are available for this run yet.")).foregroundStyle(.secondary)
                }
                if jobs.count >= 300 {
                    Text(ghCollabText("此处最多显示 300 个任务，其余可在 GitHub 查看。", "Up to 300 jobs are shown here. View additional jobs on GitHub."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { GitHubCollaborationNotice(message: error, retry: { Task { await load() } }) }
        }
        .navigationTitle(ghCollabText("运行任务", "Run jobs")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) {
            if let repositoryURL = ghCollabWebURL(center.scope.repository, []) {
                Link(ghCollabText("在 GitHub 打开", "Open on GitHub"),
                    destination: repositoryURL.appendingPathComponent("actions").appendingPathComponent("runs").appendingPathComponent(String(run.id)))
            }
        } }
        .task { await load() }.refreshable { await load() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.jobs")
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let reader = GitHubCollaborationRunReader(client: center.client, repository: center.scope.repository, run: run)
            jobs = try await reader.jobs(token: center.readToken())
        } catch is CancellationError { }
        catch { jobs = []; self.error = center.message(error) }
    }
    private func symbol(_ job: GitHubActionsJob) -> String {
        switch job.conclusion {
        case "success": "checkmark.circle"
        case "failure", "timed_out", "action_required": "xmark.circle"
        case "cancelled": "stop.circle"
        default: "clock"
        }
    }
    private func state(_ job: GitHubActionsJob) -> String {
        switch job.conclusion ?? job.status {
        case "success": ghCollabText("通过", "Passed")
        case "failure": ghCollabText("失败", "Failed")
        case "timed_out": ghCollabText("超时", "Timed out")
        case "action_required": ghCollabText("需要操作", "Action required")
        case "cancelled": ghCollabText("已取消", "Cancelled")
        case "skipped": ghCollabText("已跳过", "Skipped")
        case "neutral", "completed": ghCollabText("已完成", "Completed")
        case "in_progress": ghCollabText("运行中", "Running")
        default: ghCollabText("等待中", "Waiting")
        }
    }
}

private struct GitHubCollaborationLogView: View {
    let center: GitHubCollaborationCenter
    let run: GitHubActionAttempt
    let job: GitHubActionsJob
    @State private var log: String?
    @State private var truncated = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                if loading { ProgressView(ghCollabText("正在读取日志", "Loading log")) }
                if let error { GitHubCollaborationNotice(message: error, retry: { Task { await load() } }) }
                if let log {
                    if truncated { Text(ghCollabText("日志较长，此处显示前 128 KB。", "This log is long. The first 128 KB are shown."))
                            .font(.caption).foregroundStyle(.secondary) }
                    Text(log.isEmpty ? ghCollabText("此任务未返回日志。", "This job returned no log.") : log)
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.name).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.job.log")
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil; log = nil
        defer { loading = false }
        do {
            let reader = GitHubCollaborationRunReader(client: center.client, repository: center.scope.repository, run: run)
            let slice = try await reader.log(jobID: job.id, token: center.readToken())
            log = slice.text; truncated = slice.truncated
        } catch is CancellationError { }
        catch { self.error = center.message(error) }
    }
}
#endif

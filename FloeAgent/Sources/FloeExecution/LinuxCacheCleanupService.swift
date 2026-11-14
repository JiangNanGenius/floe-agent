// FloeExecution — service-owned Linux cache cleanup.
//
// The only execution path is a durable background job targeting the existing
// exec.shell runner in the task's explicitly bound Linux environment. The
// native service builds the exact bundled script payload; the model never
// supplies a command, path or environment variable. The job survives view
// dismissal, is cancellable through the existing job lifecycle, and a retry
// reconciles an existing job instead of replaying an unknown outcome.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

public struct LinuxCacheCleanupContext: Sendable {
    public var runID: UUID
    public var conversationID: UUID
    public var environmentID: String
    public var workspaceRootURL: URL?
    public var allowedWorkspacePaths: [String]
    public var cancellation: CancellationToken

    public init(
        runID: UUID,
        conversationID: UUID,
        environmentID: String,
        workspaceRootURL: URL?,
        allowedWorkspacePaths: [String],
        cancellation: CancellationToken
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.workspaceRootURL = workspaceRootURL
        self.allowedWorkspacePaths = allowedWorkspacePaths
        self.cancellation = cancellation
    }
}

public struct LinuxCacheCleanupCategoryReceipt: Codable, Sendable, Hashable {
    public var category: String
    public var status: String
    public var bytesBefore: Int64?
    public var bytesAfter: Int64?
    public var note: String?

    public init(category: String, status: String, bytesBefore: Int64?, bytesAfter: Int64?, note: String?) {
        self.category = category
        self.status = status
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.note = note
    }
}

public struct LinuxCacheCleanupReceipt: Codable, Sendable, Hashable {
    public var jobID: UUID?
    public var state: String
    public var mode: String
    public var categories: [String]
    public var reusedExisting: Bool
    public var reusedElsewhere: Bool
    public var needsInspection: Bool
    public var cancelled: Bool
    public var partial: Bool
    public var dfPath: String?
    public var dfAvailableBeforeBytes: Int64?
    public var dfAvailableAfterBytes: Int64?
    public var categoryResults: [LinuxCacheCleanupCategoryReceipt]
    public var rawSummary: String?
    public var error: String?
    public var repairGuidance: String?
    public var note: String?
    public var inspectionJobID: UUID?

    public init(
        jobID: UUID? = nil,
        state: String,
        mode: String,
        categories: [String],
        reusedExisting: Bool = false,
        reusedElsewhere: Bool = false,
        needsInspection: Bool = false,
        cancelled: Bool = false,
        partial: Bool = false,
        dfPath: String? = nil,
        dfAvailableBeforeBytes: Int64? = nil,
        dfAvailableAfterBytes: Int64? = nil,
        categoryResults: [LinuxCacheCleanupCategoryReceipt] = [],
        rawSummary: String? = nil,
        error: String? = nil,
        repairGuidance: String? = nil,
        note: String? = nil,
        inspectionJobID: UUID? = nil
    ) {
        self.jobID = jobID
        self.state = state
        self.mode = mode
        self.categories = categories
        self.reusedExisting = reusedExisting
        self.reusedElsewhere = reusedElsewhere
        self.needsInspection = needsInspection
        self.cancelled = cancelled
        self.partial = partial
        self.dfPath = dfPath
        self.dfAvailableBeforeBytes = dfAvailableBeforeBytes
        self.dfAvailableAfterBytes = dfAvailableAfterBytes
        self.categoryResults = categoryResults
        self.rawSummary = rawSummary
        self.error = error
        self.repairGuidance = repairGuidance
        self.note = note
        self.inspectionJobID = inspectionJobID
    }

    public var awaitingCompletion: Bool {
        ["queued", "running", "cancelling", "stopping"].contains(state)
    }

    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Compact text for the model and native-script transcript. It explicitly
    /// separates guest Linux free space from outer iPad physical space.
    public var modelSummary: String {
        var lines: [String] = []
        lines.append("Linux cache cleanup result (trusted native script; no provider/model receipt).")
        if let jobID { lines.append("jobID=\(jobID.uuidString)") }
        lines.append("state=\(state) mode=\(mode) categories=\(categories.joined(separator: ","))")
        if awaitingCompletion, let jobID {
            lines.append("Accepted only; no completed measurement/cleanup yet. Wait and read linux.cache.status with jobID=\(jobID.uuidString). Do not resubmit this operation.")
        }
        if let inspectionJobID { lines.append("fresh_inspection_jobID=\(inspectionJobID.uuidString)") }
        if reusedExisting { lines.append("reusedExisting=true (no duplicate job was started)") }
        if reusedElsewhere { lines.append("reusedElsewhere=true (another cleanup task owns the active job; no duplicate was started)") }
        if needsInspection { lines.append("needsInspection=true (inspect the existing job before retrying; nothing was replayed)") }
        if cancelled { lines.append("cancelled=true") }
        if partial { lines.append("partial=true") }
        if let dfPath { lines.append("guest_df_path=\(dfPath)") }
        let measurement = dfPath == "/floe/env" || dfPath == "/workspace" ? "shared_mount" : "guest"
        if let before = dfAvailableBeforeBytes { lines.append("\(measurement)_available_before_bytes=\(before)") }
        if let after = dfAvailableAfterBytes { lines.append("\(measurement)_available_after_bytes=\(after)") }
        if !awaitingCompletion, dfAvailableBeforeBytes == nil { lines.append("\(measurement)_available_before_bytes=unknown (measurement unavailable)") }
        for item in categoryResults {
            var line = "category \(item.category): status=\(item.status)"
            if let before = item.bytesBefore { line += " bytes_before=\(before)" }
            if let after = item.bytesAfter { line += " bytes_after=\(after)" }
            if let note = item.note, note != "none" { line += " note=\(note)" }
            lines.append(line)
        }
        if let error { lines.append("error=\(error)") }
        if let repairGuidance { lines.append("repair=\(repairGuidance)") }
        if let note { lines.append("note=\(note)") }
        lines.append("Guest Linux available bytes are not iPad physical space; deleting guest files can leave the outer disk allocation unchanged.")
        return lines.joined(separator: "\n")
    }
}

/// Line-oriented parser for the bundled script's bounded output. A missing
/// protocol banner or malformed numeric field yields nil rather than a
/// guessed success.
public enum LinuxCacheCleanupScriptResult {
    /// Unwrap only the real LocalShellTool success/exit envelope, never search
    /// arbitrary tool output for a banner. The service separately checks the
    /// exact bundled job payload, owner, environment, capture and digest.
    static func parseShellCapture(_ capture: String) -> LinuxCacheCleanupReceipt? {
        guard capture.utf8.count <= 65_536,
              let split = capture.range(of: "\n--- stdout ---\n") else { return nil }
        let header = String(capture[..<split.lowerBound])
        guard header.range(of: #"^exit=-?[0-9]+ durationMs=[0-9]+ cwd=[^\r\n]+$"#,
                           options: .regularExpression) != nil,
              !header.contains("Truncated"), !header.contains("status="),
              let first = header.split(separator: " ").first,
              let exit = Int32(first.dropFirst("exit=".count)) else { return nil }
        let remainder = String(capture[split.upperBound...])
        let stdout = remainder.components(separatedBy: "\n--- stderr ---\n").first ?? ""
        guard !stdout.contains("--- stdout ---"), var receipt = parse(stdout) else { return nil }
        if exit != 0, receipt.error == nil { receipt.error = "script_exit_\(exit)"; receipt.state = "failed" }
        return receipt
    }

    public static func parse(_ text: String) -> LinuxCacheCleanupReceipt? {
        guard text.utf8.count <= 65_536 else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first == "FLOE_LINUX_CLEANUP_V1" else { return nil }
        var fields: [String: String] = [:]
        var categories: [LinuxCacheCleanupCategoryReceipt] = []
        var seen = Set<String>()
        var hasSummary = false
        func number(_ raw: String?) -> Int64? { raw.flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil } }
        func validNumber(_ raw: String?) -> Bool { raw == "unknown" || number(raw) != nil }
        for line in lines.dropFirst() {
            if line.hasPrefix("category=") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                var item: [String: String] = [:]
                for part in parts {
                    guard let index = part.firstIndex(of: "=") else { return nil }
                    let key = String(part[..<index])
                    guard item[key] == nil else { return nil }
                    item[key] = String(part[part.index(after: index)...])
                }
                guard let category = item["category"], LinuxCacheCleanupCategory(rawValue: category) != nil || category == "all",
                      seen.insert(category).inserted, let status = item["status"],
                      validNumber(item["bytes_before"]), validNumber(item["bytes_after"]),
                      item["note"] != nil else { return nil }
                categories.append(LinuxCacheCleanupCategoryReceipt(
                    category: category,
                    status: status,
                    bytesBefore: number(item["bytes_before"]),
                    bytesAfter: number(item["bytes_after"]),
                    note: item["note"]
                ))
            } else if line.hasPrefix("summary ") {
                guard !hasSummary else { return nil }; hasSummary = true
            } else if let index = line.firstIndex(of: "=") {
                let key = String(line[..<index])
                guard fields[key] == nil else { return nil }
                fields[key] = String(line[line.index(after: index)...])
            } else { return nil }
        }
        let explicitFailure = fields["error"] != nil
        guard fields["schema"] == LinuxCacheCleanupScript.schema,
              let mode = fields["mode"], mode == "inspect" || mode == "clean",
              fields["cancelled"] == "0" || fields["cancelled"] == "1" || explicitFailure,
              (validNumber(fields["df_available_before_bytes"]) && validNumber(fields["df_available_after_bytes"])) || explicitFailure,
              hasSummary || explicitFailure,
              !categories.contains(where: { $0.category == "all" }) || fields["error"] == "cleanup_already_running" else { return nil }
        let cancelled = fields["cancelled"] == "1" || fields["error"] == "cancelled"
        let state = cancelled ? "cancelled" : fields["error"] == nil ? "completed" : "failed"
        return LinuxCacheCleanupReceipt(
            state: state,
            mode: mode,
            categories: categories.map(\.category),
            cancelled: cancelled,
            partial: fields["error"] == "partial_failure" || categories.contains { $0.status == "partial" },
            dfPath: fields["df_path"],
            dfAvailableBeforeBytes: number(fields["df_available_before_bytes"]),
            dfAvailableAfterBytes: number(fields["df_available_after_bytes"]),
            categoryResults: categories,
            rawSummary: text,
            error: fields["error"]
        )
    }
}

/// Maps runtime/preparation failures to an actionable environment-repair
/// message. It never resets storage, selects a catalog default or starts a
/// download-by-a-different-name.
public enum LinuxCacheCleanupEnvironmentRepair {
    public static func guidance(forMessage message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("shared linux maintenance workspace") {
            return FloeL10n.isChinese
                ? "无法打开共享 Linux 的清理工作目录。请在数据管理中重新开始清理。若仍无法打开，请提交诊断日志。"
                : "The shared Linux cleanup folder could not be opened. Start cleanup again from Data Management. If it still fails, send a diagnostic report."
        }
        let signals = [
            "unverified", "origin", "runtime", "image", "rebuild",
            "environment", "guest", "linux", "start", "not available",
            "not found", "unavailable", "运行环境", "来源", "镜像", "磁盘缺失"
        ]
        guard signals.contains(where: { lower.contains($0) }) else { return nil }
        return FloeL10n.isChinese
            ? "请打开 设置 → 执行环境，使用重新下载或保留资料重新创建环境的入口。本次清理没有重置磁盘、安装组件或改动已有资料。"
            : "Open Settings > Execution Environments and use the re-download or keep-data/new-environment action. This cleanup did not reset disk, install components or change existing data."
    }

    public static func guidance(for error: Error) -> String? {
        guidance(forMessage: error.localizedDescription)
    }
}

/// Native metadata that suppresses an unsolicited model follow-up when the
/// cleanup job finishes: the invoking tool already returns the actual result.
/// It grants no authority and is never model-minted.
public struct LinuxCacheCleanupRunMetadata: Sendable, Codable, Equatable {
    public enum Operation: String, Sendable, Codable { case inspect, clean, cancel }
    public let activity: String
    public let version: Int
    public let source: NativeJobSubmissionSource
    public let runID: UUID
    public let conversationID: UUID
    public let environmentID: String
    public let operation: Operation

    public init(runID: UUID, conversationID: UUID, environmentID: String, operation: Operation) {
        activity = "linuxCacheCleanup"
        version = 1
        source = .nativeService
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.operation = operation
    }

    public func payloadJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func matches(
        _ event: RunEventRecord,
        runID: UUID,
        conversationID: UUID,
        environmentID: String? = nil
    ) -> Bool {
        guard event.kind == .status, event.runID == runID,
              let data = event.payloadJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        guard value.activity == "linuxCacheCleanup", value.version == 1,
              value.source == .nativeService, value.runID == runID,
              value.conversationID == conversationID else { return false }
        if let environmentID { return value.environmentID == environmentID }
        return true
    }
}

public actor LinuxCacheCleanupService {
    public typealias ProfileResolver = @Sendable (UUID) async -> LinuxCacheCleanupTaskProfile?
    public typealias MetadataRecorder = @Sendable (UUID, LinuxCacheCleanupRunMetadata) async -> Void

    private let jobs: BackgroundJobService
    private let jobStore: BackgroundJobStore
    private let script: String
    private let profileResolver: ProfileResolver
    private let recordMetadata: MetadataRecorder
    private let outputRootURL: URL?
    static let inspectionFreshness: TimeInterval = 300
    /// Terminal jobs whose actual output was read in this process. An
    /// interrupted/failed job is never replayed without this readback.
    private var inspectedJobs = Set<UUID>()

    public init(
        jobs: BackgroundJobService,
        jobStore: BackgroundJobStore,
        script: String = LinuxCacheCleanupScript.source,
        profileResolver: @escaping ProfileResolver,
        recordMetadata: @escaping MetadataRecorder,
        outputRootURL: URL? = BackgroundJobOutputSpool.defaultRoot()
    ) {
        self.jobs = jobs
        self.jobStore = jobStore
        self.script = script
        self.profileResolver = profileResolver
        self.recordMetadata = recordMetadata
        self.outputRootURL = outputRootURL
    }

    // MARK: - Public operations

    public func inspect(
        context: LinuxCacheCleanupContext,
        categories: [LinuxCacheCleanupCategory]? = nil,
        onJobSubmitted: (@Sendable (UUID) async -> Void)? = nil
    ) async throws -> LinuxCacheCleanupReceipt {
        try await run(
            mode: "inspect",
            context: context,
            categories: categories ?? LinuxCacheCleanupCategory.defaultSafe,
            onJobSubmitted: onJobSubmitted
        )
    }

    public func clean(
        context: LinuxCacheCleanupContext,
        categories: [LinuxCacheCleanupCategory]? = nil,
        onJobSubmitted: (@Sendable (UUID) async -> Void)? = nil
    ) async throws -> LinuxCacheCleanupReceipt {
        try await requireProfile(context)
        let selected = categories ?? LinuxCacheCleanupCategory.defaultSafe
        let canonical = LinuxCacheCleanupCategory.canonical(selected).map(\.rawValue)
        // A replay of an already accepted clean keeps its original outcome.
        // Otherwise the optional native cleaner performs its own fresh inspect;
        // the AI's ordinary terminal workflow does not depend on this helper.
        let existing = try await jobStore.jobs(runID: context.runID, limit: 50)
        if existing.contains(where: { markerMatches($0) && $0.environmentID == context.environmentID
            && self.mode(of: $0) == "clean" && Set(self.categories(of: $0)) == Set(canonical)
            && (!$0.state.isTerminal || $0.state == .completed) }) {
            return try await run(mode: "clean", context: context, categories: selected, onJobSubmitted: onJobSubmitted)
        }
        let observed = try await inspect(context: context, categories: selected, onJobSubmitted: onJobSubmitted)
        guard observed.state == "completed", observed.mode == "inspect", observed.error == nil,
              !observed.cancelled, Set(observed.categoryResults.map(\.category)) == Set(canonical),
              let inspectionID = observed.jobID,
              let job = try await jobStore.job(id: inspectionID), isFreshInspection(job) else {
            var result = observed
            result.note = "No native clean was started. Wait for this inspection's real terminal result, or use the authorized guest terminal; inspection is optional for that workflow."
            return result
        }
        var result = try await run(
            mode: "clean",
            context: context,
            categories: selected,
            onJobSubmitted: onJobSubmitted,
            inspectionJobID: inspectionID
        )
        result.inspectionJobID = inspectionID
        return result
    }

    public func status(
        context: LinuxCacheCleanupContext,
        jobID: UUID
    ) async throws -> LinuxCacheCleanupReceipt {
        try await requireProfile(context)
        guard let job = try await ownedOrEnvironmentJob(jobID: jobID, context: context) else {
            throw FloeError.notFound("Linux cleanup job")
        }
        if job.state.isTerminal { inspectedJobs.insert(job.id) }
        return receipt(job: job, mode: mode(of: job), categories: categories(of: job))
    }

    public func cancel(
        context: LinuxCacheCleanupContext,
        jobID: UUID
    ) async throws -> LinuxCacheCleanupReceipt {
        try await requireProfile(context)
        guard let job = try await ownedOrEnvironmentJob(jobID: jobID, context: context),
              job.conversationID == context.conversationID else {
            throw FloeError.unauthorized
        }
        return try await cancelAndWait(job: job)
    }

    /// Fallback path: the native runner owns a run for the same conversation.
    public func cancel(
        jobID: UUID,
        conversationID: UUID,
        environmentID: String
    ) async throws -> LinuxCacheCleanupReceipt {
        guard let job = try await jobStore.job(id: jobID),
              job.conversationID == conversationID,
              job.environmentID == environmentID,
              markerMatches(job) else {
            throw FloeError.unauthorized
        }
        return try await cancelAndWait(job: job)
    }

    // MARK: - Core

    private func run(
        mode: String,
        context: LinuxCacheCleanupContext,
        categories: [LinuxCacheCleanupCategory],
        onJobSubmitted: (@Sendable (UUID) async -> Void)? = nil,
        inspectionJobID: UUID? = nil
    ) async throws -> LinuxCacheCleanupReceipt {
        try await requireProfile(context)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        guard !categories.contains(.scratch) else {
            throw FloeError.validationFailed("Scratch ownership is unverified; it is retained and cannot be cleaned")
        }
        let canonical = LinuxCacheCleanupCategory.canonical(categories)
        guard !canonical.isEmpty else {
            throw FloeError.validationFailed("Choose at least one cleanup category")
        }
        guard let workspace = context.workspaceRootURL else {
            throw FloeError.validationFailed("The cleanup task has no canonical workspace; reopen the task and retry")
        }
        let stableCategories = canonical.map(\.rawValue)

        // Same-run reconciliation first. A completed job is returned as the
        // actual result (a replayed call must not start a second cleanup); a
        // failed/interrupted job is returned for inspection. Only after that
        // readback does a new stable attempt id become possible.
        let allRunJobs = try await jobStore.jobs(runID: context.runID, limit: 50)
        let runJobs = allRunJobs.filter {
            markerMatches($0) && $0.environmentID == context.environmentID
                && self.mode(of: $0) == mode
                && Set(self.categories(of: $0)) == Set(stableCategories)
        }
        if let active = runJobs.first(where: { !$0.state.isTerminal }) {
            await onJobSubmitted?(active.id)
            return receipt(job: active, mode: mode, categories: stableCategories, reusedExisting: true)
        }
        if mode == "clean",
           let unknown = runJobs.first(where: {
               ($0.state == .interrupted || $0.state == .failed)
                   && !inspectedJobs.contains($0.id)
           }) {
            return inspectionReceipt(job: unknown)
        }
        if let completed = runJobs.first(where: { $0.state == .completed && (mode != "inspect" ||
            (isFreshInspection($0) && receipt(job: $0, mode: mode, categories: stableCategories).error == nil)) }) {
            await onJobSubmitted?(completed.id)
            return receipt(job: completed, mode: mode, categories: stableCategories, reusedExisting: true)
        }

        let attempt = runJobs.count
        let stableID = stableToolCallID(mode: mode, categories: canonical, attempt: attempt)
        if let existing = try await jobStore.job(runID: context.runID, toolCallID: stableID) {
            await onJobSubmitted?(existing.id)
            return receipt(job: existing, mode: mode, categories: stableCategories, reusedExisting: true)
        }

        let conversationJobs = try await jobStore.jobs(conversationID: context.conversationID, limit: 50)
        if let active = conversationJobs.first(where: {
            markerMatches($0) && $0.environmentID == context.environmentID && !$0.state.isTerminal
        }) {
            await onJobSubmitted?(active.id)
            return receipt(job: active, mode: self.mode(of: active), categories: self.categories(of: active),
                           reusedExisting: true)
        }
        if mode == "clean",
           let unknown = conversationJobs.first(where: {
               markerMatches($0) && $0.environmentID == context.environmentID
                   && ($0.state == .interrupted || $0.state == .failed)
                   && !inspectedJobs.contains($0.id)
           }) {
            return inspectionReceipt(job: unknown)
        }

        // One cleanup per environment across tasks. Do not submit a duplicate
        // because another visible task already owns an active job.
        let environmentJobs = try await jobStore.activeJobs(environmentID: context.environmentID)
        if let active = environmentJobs.first(where: {
            markerMatches($0) && $0.conversationID != context.conversationID
        }) {
            await onJobSubmitted?(active.id)
            return receipt(job: active, mode: self.mode(of: active), categories: self.categories(of: active),
                           reusedElsewhere: true)
        }

        if mode == "clean" {
            guard let inspectionJobID, let inspection = try await jobStore.job(id: inspectionJobID),
                  inspection.conversationID == context.conversationID,
                  inspection.environmentID == context.environmentID,
                  markerMatches(inspection), isFreshInspection(inspection),
                  Set(self.categories(of: inspection)) == Set(stableCategories),
                  receipt(job: inspection, mode: "inspect", categories: stableCategories).state == "completed",
                  receipt(job: inspection, mode: "inspect", categories: stableCategories).error == nil else {
                throw FloeError.validationFailed("A fresh verified inspection in this same cleanup task/environment is required by the optional native cleaner; use exec.shell for the normal terminal workflow")
            }
        }

        await recordMetadata(
            context.runID,
            LinuxCacheCleanupRunMetadata(
                runID: context.runID,
                conversationID: context.conversationID,
                environmentID: context.environmentID,
                operation: mode == "inspect" ? .inspect : .clean
            )
        )

        let payload = try Self.makePayload(
            script: script,
            mode: mode,
            categories: canonical,
            inspectionJobID: inspectionJobID
        )
        var job = try await jobs.submit(
            runID: context.runID,
            toolCallID: stableID,
            targetTool: "exec.shell",
            payloadJSON: payload,
            scope: .local,
            workspaceRootURL: workspace,
            allowedWorkspacePaths: context.allowedWorkspacePaths,
            environmentID: context.environmentID,
            allowedToolNames: ["exec.shell"],
            toolIdempotencyKey: "linux-cache-cleanup:\(context.conversationID.uuidString):\(stableID)",
            submissionSource: .nativeService,
            waitForCompletion: false
        )

        await onJobSubmitted?(job.id)
        do {
            job = try await waitForTerminal(id: job.id, cancellation: context.cancellation)
        } catch {
            let stopped = try? await requestStopAndWait(id: job.id)
            if context.cancellation.isCancelled || Task.isCancelled {
                let actual: BackgroundJob
                if let stopped {
                    actual = stopped
                } else {
                    actual = (try? await jobStore.job(id: job.id)) ?? job
                }
                return receipt(job: actual, mode: mode, categories: stableCategories,
                               cancelled: true,
                               note: "Stop was requested. The job's actual terminal state is reported; inspect partial output before another cleanup.")
            }
            throw error
        }
        return receipt(job: job, mode: mode, categories: stableCategories)
    }

    static func makePayload(
        script: String,
        mode: String,
        categories: [LinuxCacheCleanupCategory],
        inspectionJobID: UUID? = nil
    ) throws -> Data {
        guard !categories.contains(.scratch) else {
            throw FloeError.validationFailed("Scratch ownership is unverified; no cleanup payload was created")
        }
        guard mode == "inspect" || mode == "clean", !categories.isEmpty,
              LinuxCacheCleanupCategory.canonical(categories) == categories else {
            throw FloeError.validationFailed("Native cleanup requires a mode and canonical, non-duplicate cache categories")
        }
        struct Payload: Encodable {
            let script: String
            let env: [String: String]
            let maxOutputBytes: Int
            let timeoutPolicy: String
        }
        var env = [
            "FLOE_CLEANUP_SCHEMA": LinuxCacheCleanupScript.schema,
            "FLOE_CLEANUP_NATIVE": "1",
            "FLOE_CLEANUP_MODE": mode,
            "FLOE_CLEANUP_CATEGORIES": categories.map(\.rawValue).joined(separator: ",")
        ]
        if let inspectionJobID { env["FLOE_CLEANUP_INSPECTION_JOB_ID"] = inspectionJobID.uuidString }
        let value = Payload(
            script: script,
            env: env,
            maxOutputBytes: 262_144,
            timeoutPolicy: "advisory"
        )
        return try JSONEncoder().encode(value)
    }

    private func requireProfile(_ context: LinuxCacheCleanupContext) async throws {
        guard let profile = await profileResolver(context.conversationID),
              profile.isValid,
              profile.conversationID == context.conversationID,
              profile.environmentID == context.environmentID,
              profile.backend == .linuxVM else {
            throw FloeError.unauthorized
        }
    }

    private func stableToolCallID(
        mode: String,
        categories: [LinuxCacheCleanupCategory],
        attempt: Int
    ) -> String {
        "linux-cache-\(mode)-v1-" + categories.map(\.rawValue).joined(separator: "-")
            + "-attempt-\(max(0, attempt))"
    }

    private func inspectionReceipt(job: BackgroundJob) -> LinuxCacheCleanupReceipt {
        LinuxCacheCleanupReceipt(
            jobID: job.id,
            state: job.state.rawValue,
            mode: mode(of: job),
            categories: categories(of: job),
            needsInspection: true,
            error: job.lastError,
            repairGuidance: LinuxCacheCleanupEnvironmentRepair.guidance(
                forMessage: job.lastError ?? job.resultSummary ?? ""),
            note: "A previous cleanup job has an unknown or failed outcome. Read it with linux.cache.status and do not resubmit until you have inspected the actual result."
        )
    }

    private func ownedOrEnvironmentJob(
        jobID: UUID,
        context: LinuxCacheCleanupContext
    ) async throws -> BackgroundJob? {
        guard let job = try await jobStore.job(id: jobID),
              job.environmentID == context.environmentID,
              markerMatches(job) else { return nil }
        // Status is intentionally readable for a deduplicated job owned by a
        // sibling task in the SAME cleanup environment. It contains only
        // category/cache evidence; cancel remains conversation-scoped.
        return job
    }

    private func waitForTerminal(
        id: UUID,
        cancellation: CancellationToken
    ) async throws -> BackgroundJob {
        while true {
            try cancellation.throwIfCancelled()
            try Task.checkCancellation()
            guard let job = try await jobStore.job(id: id) else {
                throw BackgroundJobStoreError.missingJob(id)
            }
            if job.state.isTerminal { return job }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func requestStopAndWait(id: UUID) async throws -> BackgroundJob? {
        _ = try? await jobs.cancel(id: id)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let job = try await jobStore.job(id: id), job.state.isTerminal { return job }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return try await jobStore.job(id: id)
    }

    private func cancelAndWait(job: BackgroundJob) async throws -> LinuxCacheCleanupReceipt {
        if job.state.isTerminal {
            inspectedJobs.insert(job.id)
            return receipt(job: job, mode: mode(of: job), categories: categories(of: job))
        }
        let requested = try await jobs.cancel(id: job.id)
        let actual = (try? await requestStopAndWait(id: job.id)) ?? requested
        if actual.state.isTerminal { inspectedJobs.insert(actual.id) }
        return receipt(job: actual, mode: mode(of: actual), categories: categories(of: actual),
                       cancelled: actual.state == .cancelled,
                       note: actual.state.isTerminal
                           ? "The processor acknowledged the stop."
                           : "Stop requested; the job is still stopping. Do not start another cleanup until it is terminal.")
    }

    private func markerMatches(_ job: BackgroundJob) -> Bool {
        guard job.targetTool == "exec.shell",
              let object = try? JSONSerialization.jsonObject(with: job.payloadJSON) as? [String: Any],
              Set(object.keys) == Set(["script", "env", "maxOutputBytes", "timeoutPolicy"]),
              let body = object["script"] as? String,
              body == script || LinuxCacheCleanupScript.previousSourceDigests.contains(FloeDigest.sha256Hex(Data(body.utf8))),
              object["maxOutputBytes"] as? Int == 262_144, object["timeoutPolicy"] as? String == "advisory",
              let env = object["env"] as? [String: Any],
              Set(env.keys).isSubset(of: ["FLOE_CLEANUP_SCHEMA", "FLOE_CLEANUP_NATIVE", "FLOE_CLEANUP_MODE", "FLOE_CLEANUP_CATEGORIES", "FLOE_CLEANUP_INSPECTION_JOB_ID"]),
              env["FLOE_CLEANUP_SCHEMA"] as? String == LinuxCacheCleanupScript.schema,
              env["FLOE_CLEANUP_NATIVE"] as? String == "1",
              let mode = env["FLOE_CLEANUP_MODE"] as? String, mode == "inspect" || mode == "clean",
              let raw = env["FLOE_CLEANUP_CATEGORIES"] as? String,
              let values = LinuxCacheCleanupCategory.validated(rawValues: raw.split(separator: ",").map(String.init)),
              !values.isEmpty, values.map(\.rawValue).joined(separator: ",") == raw else { return false }
        if let raw = env["FLOE_CLEANUP_INSPECTION_JOB_ID"] {
            guard mode == "clean", let value = raw as? String, UUID(uuidString: value) != nil else { return false }
        }
        return true
    }

    private func isFreshInspection(_ job: BackgroundJob) -> Bool {
        guard job.state == .completed, mode(of: job) == "inspect", let ended = job.completedAt,
              let payload = try? JSONSerialization.jsonObject(with: job.payloadJSON) as? [String: Any],
              payload["script"] as? String == script else { return false }
        let age = Date().timeIntervalSince(ended)
        return age >= 0 && age <= Self.inspectionFreshness
    }

    /// Fixed helper output is small. Read at most 64 KiB in native UTF-8-safe
    /// pages from THIS job's canonical spool. A clipped/changed/foreign/missing
    /// artifact or a digest mismatch is unavailable, never a valid receipt.
    private func completeCapture(_ job: BackgroundJob) -> String? {
        guard job.state.isTerminal, let path = job.outputPath, let root = outputRootURL,
              let recorded = job.outputBytes, recorded > 0, recorded <= 65_536 + 1_024,
              let digest = job.resultDigest,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        var offset = 0, text = ""
        for _ in 0..<5 {
            guard let page = BackgroundJobOutputSpool.readPage(jobID: job.id, path: path,
                offset: offset, maxBytes: 16_384, root: root, recordedBytes: recorded),
                  page.available, page.complete == true, !page.captureTruncated,
                  !page.changedSinceRecorded, page.offset == offset, let value = page.text else { return nil }
            text += value
            guard text.utf8.count <= 65_536 else { return nil }
            guard let next = page.nextOffset else {
                return FloeDigest.sha256Hex(Data(text.utf8)) == digest ? text : nil
            }
            guard next > offset else { return nil }; offset = next
        }
        return nil
    }

    private func mode(of job: BackgroundJob) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: job.payloadJSON) as? [String: Any],
              let env = object["env"] as? [String: Any],
              let mode = env["FLOE_CLEANUP_MODE"] as? String,
              mode == "inspect" || mode == "clean" else { return "unknown" }
        return mode
    }

    private func categories(of job: BackgroundJob) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: job.payloadJSON) as? [String: Any],
              let env = object["env"] as? [String: Any],
              let raw = env["FLOE_CLEANUP_CATEGORIES"] as? String else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    private func receipt(
        job: BackgroundJob,
        mode: String,
        categories: [String],
        reusedExisting: Bool = false,
        reusedElsewhere: Bool = false,
        cancelled: Bool = false,
        note: String? = nil
    ) -> LinuxCacheCleanupReceipt {
        let raw = completeCapture(job)
        var parsed = raw.flatMap(LinuxCacheCleanupScriptResult.parseShellCapture)
        if let value = parsed, value.mode != mode || (value.state == "completed" && Set(value.categories) != Set(categories)) { parsed = nil }
        var result = parsed ?? LinuxCacheCleanupReceipt(
                state: job.state.rawValue,
                mode: mode,
                categories: categories,
                rawSummary: job.resultSummary,
                error: job.lastError
            )
        result.jobID = job.id
        if let object = try? JSONSerialization.jsonObject(with: job.payloadJSON) as? [String: Any],
           let env = object["env"] as? [String: String] {
            result.inspectionJobID = env["FLOE_CLEANUP_INSPECTION_JOB_ID"].flatMap(UUID.init(uuidString:))
        }
        result.state = job.state == .completed ? (parsed?.state ?? "failed") : job.state.rawValue
        if job.state == .completed, parsed == nil {
            result.error = "inspectionUnavailable: complete verified native-script output is unavailable or invalid. No measurements were inferred. Use exec.shell to inspect the saved guest."
            result.needsInspection = true
        }
        result.mode = mode
        result.categories = categories.isEmpty ? result.categories : categories
        result.reusedExisting = reusedExisting
        result.reusedElsewhere = reusedElsewhere
        result.cancelled = cancelled || result.cancelled || job.state == .cancelled
        result.partial = result.partial || job.state == .interrupted
        if (job.state == .interrupted || job.state == .failed),
           !inspectedJobs.contains(job.id) {
            result.needsInspection = true
        }
        if result.error == nil { result.error = job.lastError }
        result.repairGuidance = result.repairGuidance
            ?? LinuxCacheCleanupEnvironmentRepair.guidance(forMessage: (job.lastError ?? ""))
        if result.note == nil { result.note = note }
        return result
    }
}

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
        note: String? = nil
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
        if reusedExisting { lines.append("reusedExisting=true (no duplicate job was started)") }
        if reusedElsewhere { lines.append("reusedElsewhere=true (another cleanup task owns the active job; no duplicate was started)") }
        if needsInspection { lines.append("needsInspection=true (inspect the existing job before retrying; nothing was replayed)") }
        if cancelled { lines.append("cancelled=true") }
        if partial { lines.append("partial=true") }
        if let dfPath { lines.append("guest_df_path=\(dfPath)") }
        if let before = dfAvailableBeforeBytes { lines.append("guest_available_before_bytes=\(before)") }
        if let after = dfAvailableAfterBytes { lines.append("guest_available_after_bytes=\(after)") }
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
    public static func parse(_ text: String) -> LinuxCacheCleanupReceipt? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first == "FLOE_LINUX_CLEANUP_V1" else { return nil }
        var fields: [String: String] = [:]
        var categories: [LinuxCacheCleanupCategoryReceipt] = []
        for line in lines.dropFirst() {
            if line.hasPrefix("category=") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                var item: [String: String] = [:]
                for part in parts {
                    guard let index = part.firstIndex(of: "=") else { continue }
                    item[String(part[..<index])] = String(part[part.index(after: index)...])
                }
                guard let category = item["category"], let status = item["status"] else { return nil }
                categories.append(LinuxCacheCleanupCategoryReceipt(
                    category: category,
                    status: status,
                    bytesBefore: item["bytes_before"].flatMap { Int64($0) },
                    bytesAfter: item["bytes_after"].flatMap { Int64($0) },
                    note: item["note"]
                ))
            } else if let index = line.firstIndex(of: "=") {
                fields[String(line[..<index])] = String(line[line.index(after: index)...])
            }
        }
        let mode = fields["mode"] ?? "unknown"
        let state = fields["error"] == "cancelled" ? "cancelled" : "completed"
        return LinuxCacheCleanupReceipt(
            state: state,
            mode: mode,
            categories: categories.map(\.category),
            cancelled: fields["cancelled"] == "1" || fields["error"] == "cancelled",
            partial: fields["error"] == "partial_failure" || categories.contains { $0.status == "partial" },
            dfPath: fields["df_path"],
            dfAvailableBeforeBytes: fields["df_available_before_bytes"].flatMap { Int64($0) },
            dfAvailableAfterBytes: fields["df_available_after_bytes"].flatMap { Int64($0) },
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
        let signals = [
            "unverified", "origin", "runtime", "image", "rebuild",
            "environment", "guest", "linux", "start", "not available",
            "not found", "unavailable", "运行环境", "来源", "镜像", "磁盘缺失"
        ]
        guard signals.contains(where: { lower.contains($0) }) else { return nil }
        return FloeL10n.isChinese
            ? "请打开 设置 → 执行环境，检查共享 Linux 环境并使用现有修复入口。本次清理没有重置磁盘、安装组件或改动已有资料。"
            : "Open Settings > Execution Environments, inspect the shared Linux runtime and use its existing repair action. This cleanup did not reset disk, install components or change existing data."
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
    /// Terminal jobs whose actual output was read in this process. An
    /// interrupted/failed job is never replayed without this readback.
    private var inspectedJobs = Set<UUID>()

    public init(
        jobs: BackgroundJobService,
        jobStore: BackgroundJobStore,
        script: String = LinuxCacheCleanupScript.source,
        profileResolver: @escaping ProfileResolver,
        recordMetadata: @escaping MetadataRecorder
    ) {
        self.jobs = jobs
        self.jobStore = jobStore
        self.script = script
        self.profileResolver = profileResolver
        self.recordMetadata = recordMetadata
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
        try await run(
            mode: "clean",
            context: context,
            categories: categories ?? LinuxCacheCleanupCategory.defaultSafe,
            onJobSubmitted: onJobSubmitted
        )
    }

    public func status(
        context: LinuxCacheCleanupContext,
        jobID: UUID
    ) async throws -> LinuxCacheCleanupReceipt {
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
        onJobSubmitted: (@Sendable (UUID) async -> Void)? = nil
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
        if let completed = runJobs.first(where: { $0.state == .completed }) {
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
            categories: canonical
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
        categories: [LinuxCacheCleanupCategory]
    ) throws -> Data {
        guard !categories.contains(.scratch) else {
            throw FloeError.validationFailed("Scratch ownership is unverified; no cleanup payload was created")
        }
        struct Payload: Encodable {
            let script: String
            let env: [String: String]
            let maxOutputBytes: Int
            let timeoutPolicy: String
        }
        let value = Payload(
            script: script,
            env: [
                "FLOE_CLEANUP_SCHEMA": LinuxCacheCleanupScript.schema,
                "FLOE_CLEANUP_NATIVE": "1",
                "FLOE_CLEANUP_MODE": mode,
                "FLOE_CLEANUP_CATEGORIES": categories.map(\.rawValue).joined(separator: ",")
            ],
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
              let env = object["env"] as? [String: Any],
              env["FLOE_CLEANUP_SCHEMA"] as? String == LinuxCacheCleanupScript.schema,
              env["FLOE_CLEANUP_NATIVE"] as? String == "1" else { return false }
        return true
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
        let raw = job.resultSummary ?? job.lastError ?? ""
        var parsed = LinuxCacheCleanupScriptResult.parse(raw)
        if parsed == nil {
            parsed = LinuxCacheCleanupReceipt(
                state: job.state.rawValue,
                mode: mode,
                categories: categories,
                rawSummary: raw.isEmpty ? nil : raw,
                error: job.lastError
            )
        }
        var result = parsed ?? LinuxCacheCleanupReceipt(state: job.state.rawValue, mode: mode, categories: categories)
        result.jobID = job.id
        result.state = job.state.rawValue
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
            ?? LinuxCacheCleanupEnvironmentRepair.guidance(forMessage: raw + " " + (job.lastError ?? ""))
        if result.note == nil { result.note = note }
        return result
    }
}

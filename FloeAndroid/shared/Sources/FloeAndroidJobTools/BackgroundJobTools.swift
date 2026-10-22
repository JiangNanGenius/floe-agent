// FloeAndroidJobTools — Android platform mirror of the ORIGINAL
// FloeAgent/Sources/FloeExecution/Tools/BackgroundJobTools.swift
// (job-a16c9976985f40b2). Every statement is byte-equal to the original
// except the deltas below, each also delivered to Main in
// Local/Private/android-g03-20261022/r2/jobs-port/SOURCE_READY.json (Main
// appends the shared PROVENANCE.md entry during assembly; this lane does not
// edit that file):
//
//   J1 (honest Android admission): `JobsSubmitTool` gains ONE additive
//      trailing-defaulted init parameter `admittedTargets: Set<String>?`.
//      When non-nil, `validate` admits only those targets and the refusal
//      message names them. The raw registered entry still always submits
//      through `submissionSource: .runtime` with the runtime-issued
//      provenance fields of the exact call (byte-equal to the ORIGINAL;
//      nothing here synthesizes ToolContext.provenance). The static
//      description/schema text reflects what Android actually admits
//      (exec.shell jobs plus already-registered web targets) and REMOVES
//      the iOS-only exec.localService/media/document/video promises:
//      those tools are not registered here and jobs.submit must not
//      advertise them. The ORIGINAL static `supportedTargets` gate stays
//      reachable when `admittedTargets` is nil so the shared code keeps
//      the original default behavior for other builds.
//   J2 (explicit trusted spool root): `BackgroundJobOutputSpool.defaultRoot()`
//      is REMOVED. Every spool entry point (`canonicalArtifactURL`,
//      `isCanonicalArtifactPath`, `write`, `readPage`), `JobsResultTool.init`
//      and `registerBackgroundJobTools` now REQUIRE an explicit `root: URL` /
//      `outputRootURL: URL`. On Android the globalApplicationSupport
//      fallback must never silently pick an arbitrary location: Main injects
//      the one trusted, persistence-retention-managed job-output root at
//      composition. Bounds, atomic write, UTF-8 scalar-safe truncation,
//      structured footer, canonical-path confinement and age-prune rules
//      are byte-equal to the original.
//   J3 (runner-lookup split): `registerBackgroundJobTools` gains ONE
//      additive trailing-defaulted parameter `runnerLookup: ToolRunnerRegistry?`.
//      The jobs.* tools still register into `registry` (the shared runtime
//      registry the dispatcher sees); the BACKGROUND EXECUTION of a job
//      resolves its target runner from `runnerLookup ?? registry`. Android
//      composition passes a job-scoped registry whose exec.shell runner is
//      the ORIGINAL tool wrapped in the lease-reconcile wait extension
//      (ExecShellJobRunner.swift, this module) so a job never terminalizes
//      while the runtime-UID engine lease or a claimed start receipt is
//      still unreconciled. Foreground dispatch, descriptors and the shared
//      registry stay exactly the original path — no second tool surface.
//
// FloeExecution — jobs.* background task tools (original header).
// Interaction model mirrors the SSH guardian tools: submit returns a durable
// jobID immediately; status/result/cancel operate on that jobID later.

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

private func jobsOutput(_ payload: some Encodable) throws -> ToolExecutionOutput {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(payload)
    return ToolExecutionOutput(
        summary: String(decoding: data, as: UTF8.self),
        fullOutputSHA256: FloeDigest.sha256Hex(data),
        // The jobs.* envelope is an explicitly declared bounded exception
        // (ToolExecutionOutput clamps to 262_144); every field inside is
        // individually bounded and no identifier is ever truncated.
        maximumSummaryCharacters: 262_144
    )
}

private struct JobProgressView: Encodable {
    let stage: String
    let phase: String?
    let completedUnits: Int?
    let totalUnits: Int?
    let fraction: Double?
    let note: String?

    init(_ progress: NativeJobProgress) {
        stage = progress.stage.rawValue
        phase = progress.phase
        completedUnits = progress.completedUnits
        totalUnits = progress.totalUnits
        fraction = progress.fraction
        note = progress.note
    }
}

private struct JobOriginView: Encodable {
    let kind: String
    let childID: String?
    let rootTaskID: String?
    let submittedCallID: String?

    init(_ origin: NativeJobOrigin) {
        kind = origin.kind.rawValue
        childID = origin.childID?.uuidString
        rootTaskID = origin.rootTaskID?.uuidString
        submittedCallID = origin.submittedCallID
    }
}

private struct JobView: Encodable {
    let jobID: String
    let state: String
    let targetTool: String
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
    let hasResult: Bool
    /// Present only when the recorded artifact path names a file that still
    /// exists; a stale path is reported honestly as absent.
    let resultPath: String?
    let lastError: String?
    /// Raw progress document (bounded) for diagnostics.
    let progressJSON: String?
    /// True while a cancellation request is outstanding and the processor has
    /// not acknowledged yet; the job is still running.
    let cancelling: Bool
    let progress: JobProgressView?
    let origin: JobOriginView?
    let preparedOperationID: String?
    let frozenRevision: String?
    /// Exact byte count of the spooled full-output artifact, when one was
    /// written. Nil means only resultSummary survives.
    let outputBytes: Int?

    init(_ job: BackgroundJob) {
        jobID = job.id.uuidString
        state = job.state.rawValue
        targetTool = job.targetTool
        createdAt = ISO8601DateFormatter().string(from: job.createdAt)
        updatedAt = ISO8601DateFormatter().string(from: job.updatedAt)
        completedAt = job.completedAt.map { ISO8601DateFormatter().string(from: $0) }
        let verifiedPath = job.resultPath.flatMap { path -> String? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return path
        }
        resultPath = verifiedPath
        hasResult = job.resultSummary != nil || verifiedPath != nil
        lastError = job.lastError
        progressJSON = job.progressJSON.map { String(decoding: $0, as: UTF8.self) }
        let document = NativeJobProgressDocument.decode(job.progressJSON)
        cancelling = !job.state.isTerminal && (document?.cancellationRequested == true)
        progress = document?.progress.map(JobProgressView.init)
        origin = document?.origin.map(JobOriginView.init)
        preparedOperationID = document?.prepared?.operationID
        frozenRevision = document?.prepared?.frozenRevision
        outputBytes = job.outputBytes
    }
}

/// Service-owned spool for the FULL output of a finished job. One artifact
/// per job id under the EXPLICIT trusted root (J2 — this Android mirror has
/// no default root: the globalApplicationSupport fallback must never choose
/// a location here); bounded by construction (1 MiB per artifact) and
/// age-pruned on write so the spool cannot grow without bound. The file
/// holds job output the user/model already produced in this task — it is
/// bookkeeping, never a secret store. `jobs.result` reads it back in
/// UTF-8-safe pages.
public enum BackgroundJobOutputSpool {
    /// Hard cap per artifact (payload bytes; the structured footer is
    /// additional and bounded). Output beyond it is truncated with an
    /// explicit, STRUCTURED footer that records the original size — an
    /// artifact at the cap is never presented as the complete output.
    public static let maximumArtifactBytes = 1_048_576
    /// Artifacts older than this are pruned when a new artifact is written.
    public static let retentionSeconds: TimeInterval = 14 * 24 * 60 * 60

    /// Structured completeness metadata carried in the artifact footer.
    public struct Metadata: Sendable, Equatable {
        public var originalBytes: Int
        public var savedBytes: Int
        /// True when the payload was cut at the cap; the artifact then holds
        /// a bounded PREFIX, not the whole output.
        public var truncated: Bool

        public init(originalBytes: Int, savedBytes: Int, truncated: Bool) {
            self.originalBytes = originalBytes
            self.savedBytes = savedBytes
            self.truncated = truncated
        }
    }

    /// Footer grammar: one line at the very end of the artifact.
    static let footerPrefix = "[floe-job-output "
    static func footer(for metadata: Metadata) -> String {
        "\n\(footerPrefix)originalBytes=\(metadata.originalBytes)"
            + " savedBytes=\(metadata.savedBytes)"
            + " truncated=\(metadata.truncated)]\n"
    }

    // J2: `defaultRoot()` is REMOVED. Callers pass the explicit trusted root.

    /// The only path this spool ever writes or reads: the canonical root plus
    /// `<job-uuid>.txt`. A stored path outside it is never opened.
    public static func canonicalArtifactURL(jobID: UUID, root: URL) -> URL {
        root.appendingPathComponent("\(jobID.uuidString).txt")
    }

    /// True when `path` names this job's artifact inside the canonical root.
    /// Arbitrary stored paths, other jobs' files and anything outside the
    /// root are refused.
    public static func isCanonicalArtifactPath(
        _ path: String,
        jobID: UUID,
        root: URL
    ) -> Bool {
        let expected = root.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("\(jobID.uuidString).txt")
        let actual = URL(fileURLWithPath: path).standardizedFileURL
        return actual.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
    }

    /// Writes (atomically) the full bounded output and returns its path and
    /// the artifact's real byte size (payload + footer). Never throws an
    /// error that would fail the job: the caller treats nil as "summary
    /// only".
    public static func write(jobID: UUID, text: String, root: URL) -> (path: String, bytes: Int)? {
        let url = canonicalArtifactURL(jobID: jobID, root: root)
        let data = Data(text.utf8)
        var metadata: Metadata
        var payload: Data
        if data.count > maximumArtifactBytes {
            // Cut at a SCALAR boundary computed against the original buffer:
            // while the first EXCLUDED byte is a UTF-8 continuation byte, the
            // scalar that byte belongs to started before the cut, so the kept
            // prefix must shed that scalar's leading byte too. (The previous
            // form dropped trailing continuation bytes but could leave a
            // dangling leading byte — corrupting the last CJK/emoji scalar.)
            var end = maximumArtifactBytes
            while end > 0, (data[end] & 0xC0) == 0x80 { end -= 1 }
            payload = data.subdata(in: 0..<end)
            metadata = Metadata(originalBytes: data.count, savedBytes: end, truncated: true)
        } else {
            payload = data
            metadata = Metadata(originalBytes: data.count, savedBytes: data.count, truncated: false)
        }
        let footer = Data(footer(for: metadata).utf8)
        var artifact = payload
        artifact.append(footer)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try artifact.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        prune(root: root)
        return (url.path, artifact.count)
    }

    /// Reads ONLY the structured footer (bounded tail read) — never the whole
    /// artifact. Returns nil when the footer is absent (a legacy artifact or
    /// a changed file), so callers report the real bytes they can see.
    public static func readMetadata(
        path: String,
        jobID: UUID,
        root: URL
    ) -> Metadata? {
        guard isCanonicalArtifactPath(path, jobID: jobID, root: root) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailBytes = min(256, Int(size))
        guard tailBytes > 0 else { return nil }
        try? handle.seek(toOffset: UInt64(size) - UInt64(tailBytes))
        let readData: Data
        do { readData = try handle.read(upToCount: tailBytes) ?? Data() } catch { return nil }
        guard !readData.isEmpty else { return nil }
        // Byte-level search: the tail may start inside a multibyte scalar, so
        // the raw window is not required to be valid UTF-8. The footer itself
        // is ASCII by construction.
        guard let range = readData.range(of: Data(footerPrefix.utf8)),
              let closeIndex = readData[range.upperBound...].firstIndex(of: UInt8(ascii: "]")),
              let body = String(
                data: readData[range.upperBound..<closeIndex], encoding: .utf8)
        else { return nil }
        var values: [String: String] = [:]
        for field in body.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        guard let original = values["originalBytes"].flatMap(Int.init),
              let saved = values["savedBytes"].flatMap(Int.init),
              let truncated = values["truncated"].flatMap(Bool.init)
        else { return nil }
        return Metadata(originalBytes: original, savedBytes: saved, truncated: truncated)
    }

    /// Age-based retention. Called on write; a cheap best-effort scan.
    public static func prune(root: URL, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        for entry in entries {
            guard entry.pathExtension == "txt" else { continue }
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// One bounded, UTF-8-safe page of a job's canonical output artifact.
///
/// The reader opens ONLY the canonical owner path for the job, seeks to the
/// byte offset and reads one bounded window — never the whole file — so the
/// model-facing `jobs.result` tool and the app's read-only output viewer can
/// share the exact same bytes and completeness fields.
public struct BackgroundJobOutputPage: Sendable {
    public let available: Bool
    public let path: String?
    /// Bytes of the artifact as it exists right now (bounded prefix + footer).
    public let totalBytes: Int
    public let offset: Int
    public let pageBytes: Int
    public let nextOffset: Int?
    public let text: String?
    /// Structured completeness of the WHOLE artifact, read from its footer:
    /// `truncated == true` means the artifact itself is a capped prefix, so
    /// reaching the end of it is NOT proof the job's complete output was
    /// read. Nil when the footer is unavailable (legacy/changed file).
    public let complete: Bool?
    public let originalBytes: Int?
    /// True when the artifact's current size differs from the size recorded
    /// when the job finished (an external change or a partial write): the
    /// page still reports what is really there.
    public let changedSinceRecorded: Bool

    public init(
        available: Bool,
        path: String?,
        totalBytes: Int,
        offset: Int,
        pageBytes: Int,
        nextOffset: Int?,
        text: String?,
        complete: Bool?,
        originalBytes: Int?,
        changedSinceRecorded: Bool
    ) {
        self.available = available
        self.path = path
        self.totalBytes = totalBytes
        self.offset = offset
        self.pageBytes = pageBytes
        self.nextOffset = nextOffset
        self.text = text
        self.complete = complete
        self.originalBytes = originalBytes
        self.changedSinceRecorded = changedSinceRecorded
    }
}

public extension BackgroundJobOutputSpool {
    /// Reads ONE bounded page from the job's canonical artifact.
    ///
    /// Returns nil when the stored path is not the canonical owner path for
    /// this job, the file is missing/empty, or the requested offset lies
    /// beyond the payload (including a page for an artifact that was already
    /// fully covered). Pages cover the PAYLOAD only; the structured footer is
    /// reported as fields (`complete`/`originalBytes`), never as page text.
    static func readPage(
        jobID: UUID,
        path: String,
        offset: Int,
        maxBytes: Int,
        root: URL,
        recordedBytes: Int? = nil
    ) -> BackgroundJobOutputPage? {
        guard isCanonicalArtifactPath(path, jobID: jobID, root: root) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size > 0 else { return nil }
        let metadata = readMetadata(path: path, jobID: jobID, root: root)
        // Pages cover the PAYLOAD only: the structured footer is reported as
        // fields (complete/originalBytes), never as page text.
        let payloadBytes = min(size, metadata?.savedBytes ?? size)
        let start = min(max(0, offset), payloadBytes)
        let remaining = max(0, payloadBytes - start)
        guard remaining > 0 else { return nil }
        try? handle.seek(toOffset: UInt64(start))
        // BOUNDED read: only this page's window plus at most one max-length
        // scalar of lookahead for the trailing boundary decision.
        let windowData: Data
        do {
            // Never read past the payload end: the 4 lookahead bytes exist
            // only to settle a trailing scalar boundary and must not leak the
            // structured footer into page text.
            windowData = try handle.read(upToCount: min(maxBytes + 4, remaining)) ?? Data()
        } catch {
            return nil
        }
        guard !windowData.isEmpty else { return nil }
        let page = JobsResultTool.utf8Window(
            windowData, start: start, maxBytes: maxBytes, fileSize: payloadBytes)
        return BackgroundJobOutputPage(
            available: true,
            path: path,
            totalBytes: size,
            offset: page.start,
            pageBytes: page.byteCount,
            nextOffset: page.nextOffset,
            text: page.text,
            complete: metadata.map { !$0.truncated },
            originalBytes: metadata?.originalBytes,
            changedSinceRecorded: recordedBytes.map { $0 != size } ?? false)
    }
}

private func parseJobID(_ raw: String) throws -> UUID {
    guard let id = UUID(uuidString: raw) else {
        throw FloeError.validationFailed("jobID must be a UUID returned by jobs.submit")
    }
    return id
}

public struct JobsSubmitTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var tool: String
        /// JSON-encoded arguments object for the target tool.
        public var arguments: String
        public var purpose: String?
        /// Required by default: this task stays open (nonterminal) until the
        /// job reaches a terminal result — or, for a long-lived local
        /// service, until it is verifiably ready — and then continues in the
        /// SAME run with the completion evidence. `false` submits explicitly
        /// fire-and-forget work whose result is collected in a later turn.
        public var wait: Bool?
        public init(tool: String, arguments: String, purpose: String? = nil, wait: Bool? = nil) {
            self.tool = tool; self.arguments = arguments; self.purpose = purpose; self.wait = wait
        }
    }

    public static let name = "jobs.submit"
    // J1: Android-honest description. The iOS-only exec.localService,
    // network.download, video.*/media.project/document.* targets are NOT
    // advertised: they are not registered on Android and jobs.submit must
    // reflect actual capability. Admission at validate/submit time comes
    // from the injected registered+admitted set (see admittedTargets).
    public static let toolDescription = """
    Submit a long-running operation as a durable background job and return immediately with a jobID instead of blocking this task. \
    Admitted targets on Android are exactly the tools registered in this build that the job policy admits: \
    exec.shell (long Linux commands, builds, data processing and package work in the task's resolved Linux engine) and, when the \
    app registered them, web targets such as web.fetch. Other tools must run directly; an unregistered or unadmitted target is \
    refused at the call site before any job record exists. A delegated child may submit the SAME eligible targets through the \
    same effective parent capability ceiling; delegation itself (delegate/conversation.spawn) and main-run-only capabilities can \
    never be deferred, and a job never runs outside its frozen task/environment/workspace. Authorized operations that require an \
    adapter additionally require the runtime-issued approval of this exact jobs.submit call; a model-authored confirmation is \
    never authority. arguments is a JSON-encoded object for the target tool. Track progress with jobs.status, collect output \
    with jobs.result, stop it with jobs.cancel; completion is also announced automatically to this task only. Jobs for \
    exec.shell run on the real runtime-UID engine: a wait timeout or cancellation keeps the job NONTERMINAL until the engine \
    proves the lease release (or the workload is proven quiescent), and the durable record survives app relaunch — after a \
    process death an unfinished job is reconciled to an honest UNKNOWN interrupted state, never a fake success. By default \
    this task WAITS: the run stays open and continues in the same run with the job's result when the job finishes, so do not \
    end your reply with a promise to check later. Pass "wait": false only for explicitly detached work you will collect later. \
    Never submit a duplicate payload for the same purpose — one job is enough.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"tool":{"type":"string","description":"Target tool name. Admitted: the targets actually registered in this build that the job policy admits (exec.shell; web.fetch when registered)."},"arguments":{"type":"string","maxLength":65536,"description":"JSON-encoded arguments object for the target tool."},"purpose":{"type":"string","maxLength":240,"description":"Short human-visible reason for this job"},"wait":{"type":"boolean","description":"Default true: keep this task open until the job finishes and continue in the same run with the result. false = explicitly detached fire-and-forget work."}},"required":["tool","arguments"],"additionalProperties":false}"#
    // The real risk profile belongs to the named target; the union keeps
    // approval policy conservative because labels are compile-time static.
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesLocalCode, .readsFiles, .writesFiles, .deletesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: BackgroundJobService
    /// J1: when non-nil, the EXACT targets registered in this build and
    /// admitted by this service's policy. The ORIGINAL static
    /// `supportedTargets` remains the fallback for builds that do not
    /// inject an admission set.
    private let admittedTargets: Set<String>?
    public init(service: BackgroundJobService, admittedTargets: Set<String>? = nil) {
        self.service = service
        self.admittedTargets = admittedTargets
    }

    private var admittedForValidation: Set<String> {
        admittedTargets ?? BackgroundJobService.supportedTargets
    }

    /// Canonical JSON of the decoded jobs.submit arguments, in exactly the
    /// shape the runtime hashed when it minted this call's authority. Optional
    /// fields that were absent stay absent.
    public static func canonicalApprovedPayload(_ args: Arguments) throws -> Data {
        var object: [String: Any] = ["tool": args.tool, "arguments": args.arguments]
        if let purpose = args.purpose { object["purpose"] = purpose }
        if let wait = args.wait { object["wait"] = wait }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Mirrors `RuntimeAuthorityDigest.canonicalTarget` for this tool:
    /// `jobs.submit` is a workspace-wildcard mutating target, so the runtime
    /// resolves the canonical workspace root (or `*` when absent).
    public static func canonicalTarget(context: ToolContext) -> String {
        guard let root = context.workspaceRootURL else { return "workspace:*" }
        return "workspace:" + root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Builds the binding the runtime minted for this exact `jobs.submit`
    /// call. Throws only when the approved arguments cannot be canonicalized
    /// (itself a refusal, never a bypass).
    public static func runtimeAuthorityBinding(for args: Arguments, context: ToolContext) throws -> RuntimeAuthorityBinding {
        let payload = try canonicalApprovedPayload(args)
        return context.runtimeAuthorityBinding(
            toolName: name,
            operation: "job.submit",
            canonicalTarget: canonicalTarget(context: context),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: payload),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }

    public func validate(_ args: Arguments) throws {
        guard admittedForValidation.contains(args.tool) else {
            throw FloeError.validationFailed("Unsupported job target '\(args.tool)'; admitted in this build: \(admittedForValidation.sorted().joined(separator: ", "))")
        }
        guard let data = args.arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw FloeError.validationFailed("arguments must be a JSON-encoded object for the target tool")
        }
        if let purpose = args.purpose {
            guard purpose.utf8.count <= 240 else { throw FloeError.validationFailed("purpose must be at most 240 bytes") }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let payload = Data(args.arguments.utf8)
        // The runtime authority for THIS exact jobs.submit call is forwarded
        // to the service, which consumes it only for adapters that require a
        // prepared authorized operation and only for a NEW job (an idempotent
        // replay never re-consumes).
        let binding = try? Self.runtimeAuthorityBinding(for: args, context: context)
        let job = try await service.submit(
            runID: context.runID,
            toolCallID: context.toolCallID,
            targetTool: args.tool,
            payloadJSON: payload,
            scope: context.scope,
            workspaceRootURL: context.workspaceRootURL,
            allowedWorkspacePaths: context.allowedWorkspacePaths,
            environmentID: context.environmentID,
            allowedToolNames: context.allowedToolNames,
            callOrigin: context.callOrigin,
            childExecution: context.childExecution,
            toolIdempotencyKey: context.toolIdempotencyKey,
            approvalGrantID: context.approvalGrantID,
            runtimeAuthority: context.runtimeAuthority,
            runtimeAuthorityBinding: binding,
            // This is the RAW REGISTERED entry a reconstructed wrapper context
            // reaches; it must never inherit the in-process native-service
            // fallback. `.runtime` requires the runtime-issued nonnil call id
            // and the `jobs.submit` origin binding this exact call, so a
            // context with stripped provenance is refused before any record
            // or effect.
            submissionSource: .runtime,
            waitForCompletion: args.wait ?? true
        )
        struct Response: Encodable {
            let jobID: String
            let state: String
            let targetTool: String
            /// False when this call id already owned a job with different
            /// arguments: the ORIGINAL accepted payload is what runs.
            let payloadMatches: Bool
            let waitForCompletion: Bool
            let note: String
        }
        let payloadMatches = job.payloadJSON == payload
        let waits = args.wait ?? true
        let note = payloadMatches
            ? (waits
                ? "Job accepted. This task stays open until the job finishes and then continues in the SAME run with the result; use jobs.result for the full output if the announcement is ever lost."
                : "Job accepted as detached work. Do not resubmit the same payload; collect it later with jobs.status/jobs.result.")
            : "This call id already has an accepted job with DIFFERENT arguments; the original payload runs. Poll it with this jobID, or submit the changed operation under a new call id."
        return try jobsOutput(Response(
            jobID: job.id.uuidString,
            state: job.state.rawValue,
            targetTool: job.targetTool,
            payloadMatches: payloadMatches,
            waitForCompletion: waits,
            note: note
        ))
    }
}

public struct JobsStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.status"
    public static let toolDescription = "Check a background job's state (queued/running/completed/failed/cancelled/interrupted), the real processor progress (stage/phase/units when the owning service reports them), whether cancellation is still pending, who submitted it, and whether its result is ready. Poll no faster than every few seconds; completion is also announced automatically."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let job = try await service.ownedJob(id: parseJobID(args.jobID), runID: context.runID)
        return try jobsOutput(JobView(job))
    }
}

/// One page of a job's full spooled output. The page is UTF-8-safe and the
/// `nextOffset` cursor is stable, so a model whose earlier page was replaced
/// by context compression can keep paging from the exact same artifact.
private struct JobOutputPageView: Encodable {
    let available: Bool
    let path: String?
    /// Bytes of the artifact as it exists right now (bounded prefix + footer).
    let totalBytes: Int
    let offset: Int
    let pageBytes: Int
    let nextOffset: Int?
    let text: String?
    /// Structured completeness of the WHOLE artifact, read from its footer:
    /// `truncated == true` means the artifact itself is a capped prefix, so
    /// reaching the end of it is NOT proof the job's complete output was
    /// read. Nil when the footer is unavailable (legacy/changed file).
    let complete: Bool?
    let originalBytes: Int?
    /// True when the artifact's current size differs from the size recorded
    /// when the job finished (an external change or a partial write): the
    /// page still reports what is really there.
    let changedSinceRecorded: Bool

    /// Projection of the shared bounded page reader
    /// (`BackgroundJobOutputSpool.readPage`) into the tool's JSON response.
    init(_ page: BackgroundJobOutputPage) {
        available = page.available
        path = page.path
        totalBytes = page.totalBytes
        offset = page.offset
        pageBytes = page.pageBytes
        nextOffset = page.nextOffset
        text = page.text
        complete = page.complete
        originalBytes = page.originalBytes
        changedSinceRecorded = page.changedSinceRecorded
    }
}

public struct JobsResultTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        /// Byte offset into the full spooled output. Omit for the first page.
        public var offset: Int?
        /// Maximum bytes returned in this page (bounded; default 3000 so a
        /// page survives the runtime's model-compression threshold).
        public var maxBytes: Int?
        public init(jobID: String, offset: Int? = nil, maxBytes: Int? = nil) {
            self.jobID = jobID; self.offset = offset; self.maxBytes = maxBytes
        }
    }

    public static let name = "jobs.result"
    public static let toolDescription = "Fetch a background job's result. For a finished job this returns resultSummary AND, when the output was spooled, the first page of the stored output plus a nextOffset cursor: keep calling jobs.result with offset=nextOffset to read it in UTF-8-safe pages even after earlier pages have left the context. The response states COMPLETENESS: \"complete\":true means the whole output is stored; \"complete\":false means the artifact is itself a bounded prefix (originalBytes is reported) and reading its end is not the whole job output — do not rerun the job just for that; resultPath/workspace may hold a real file. resultPath is present only when the owning service actually wrote a file and it still exists. For a job that is still running this returns its state — wait for the automatic completion announcement instead of tight polling. When the process died mid-job the status is interrupted: the outcome is UNKNOWN, so inspect existing outputs read-only before explicitly resubmitting."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"},"offset":{"type":"integer","minimum":0,"description":"Byte offset into the full output; use the nextOffset from the previous page."},"maxBytes":{"type":"integer","minimum":256,"maximum":32000,"description":"Maximum bytes for this page (default 3000)."}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    /// Default page size stays below the runtime's 4096-character tool-result
    /// bound and the 2048-byte replay-compaction threshold, so a single page
    /// is never silently middle-compressed.
    static let defaultPageBytes = 3_000
    static let maximumPageBytes = 32_000

    private let service: BackgroundJobService
    /// Spool root. J2: REQUIRED and explicit — the ORIGINAL optional root
    /// with the Application Support fallback is removed on Android; Main
    /// injects the one trusted job-output root at composition and this tool
    /// (and only this tool's canonical confinement rules) read it back.
    private let outputRoot: URL

    public init(service: BackgroundJobService, outputRoot: URL) {
        self.service = service
        self.outputRoot = outputRoot
    }

    public func validate(_ args: Arguments) throws {
        _ = try parseJobID(args.jobID)
        if let offset = args.offset, offset < 0 { throw FloeError.validationFailed("offset must be >= 0") }
        if let maxBytes = args.maxBytes, maxBytes < 256 || maxBytes > Self.maximumPageBytes {
            throw FloeError.validationFailed("maxBytes must be between 256 and \(Self.maximumPageBytes)")
        }
    }

    /// UTF-8 safe slicing: the returned text never contains a replacement
    /// character introduced by the page boundary, and `nextOffset` always
    /// advances past a complete scalar.
    static func utf8Page(
        _ data: Data,
        start: Int,
        maxBytes: Int
    ) -> (text: String, start: Int, byteCount: Int, nextOffset: Int?) {
        let total = data.count
        var begin = min(max(0, start), total)
        while begin < total, (data[begin] & 0xC0) == 0x80 { begin += 1 }
        let end = scalarBoundaryEnd(data, proposed: min(begin + max(256, maxBytes), total))
        let slice = data.subdata(in: begin..<end)
        let nextOffset = end < total ? end : nil
        return (String(decoding: slice, as: UTF8.self), begin, slice.count, nextOffset)
    }

    /// UTF-8-safe window slice for a BOUNDED read: `window` holds bytes
    /// starting at absolute `start` (plus a few bytes of lookahead), and
    /// `fileSize` is the whole artifact size. The page never splits a scalar
    /// and `nextOffset` addresses the next unscanned byte.
    static func utf8Window(
        _ window: Data,
        start: Int,
        maxBytes: Int,
        fileSize: Int
    ) -> (text: String, start: Int, byteCount: Int, nextOffset: Int?) {
        var begin = 0
        while begin < window.count, (window[begin] & 0xC0) == 0x80 { begin += 1 }
        let end = scalarBoundaryEnd(window, proposed: min(begin + max(256, maxBytes), window.count))
        let slice = window.subdata(in: begin..<end)
        let absoluteStart = start + begin
        let absoluteEnd = start + end
        let nextOffset = absoluteEnd < fileSize ? absoluteEnd : nil
        return (String(decoding: slice, as: UTF8.self), absoluteStart, slice.count, nextOffset)
    }

    /// The largest scalar boundary at or before `proposed`.
    ///
    /// Mid-buffer: when the first EXCLUDED byte is a UTF-8 continuation byte,
    /// the scalar it belongs to started before the cut, so the boundary must
    /// shed that scalar's leading byte as well (this is what keeps a CJK or
    /// emoji scalar from being cut into a corrupt fragment). At EOF: a
    /// partial trailing scalar is dropped by its measured length, never by
    /// stripping continuation bytes until something remains.
    static func scalarBoundaryEnd(_ data: Data, proposed: Int) -> Int {
        var end = min(max(0, proposed), data.count)
        guard end > 0, end < data.count else {
            return end == data.count ? trimPartialTrailingScalar(data, end) : end
        }
        while end > 0, end < data.count, (data[end] & 0xC0) == 0x80 { end -= 1 }
        return end
    }

    private static func trimPartialTrailingScalar(_ data: Data, _ end: Int) -> Int {
        guard end > 0 else { return 0 }
        var lead = end - 1
        while lead > 0, (data[lead] & 0xC0) == 0x80 { lead -= 1 }
        let byte = data[lead]
        let expected: Int
        if byte & 0x80 == 0 { expected = 1 }
        else if byte & 0xE0 == 0xC0 { expected = 2 }
        else if byte & 0xF0 == 0xE0 { expected = 3 }
        else if byte & 0xF8 == 0xF0 { expected = 4 }
        else { expected = 1 }
        return (end - lead) < expected ? lead : end
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let job = try await service.ownedJob(id: parseJobID(args.jobID), runID: context.runID)
        struct Response: Encodable {
            let job: JobView
            let resultSummary: String?
            let resultDigest: String?
            let output: JobOutputPageView?
            let note: String?
        }
        let offset = max(0, args.offset ?? 0)
        let maxBytes = min(max(256, args.maxBytes ?? Self.defaultPageBytes), Self.maximumPageBytes)
        // J2: the explicit trusted root — no default-root resolution here.
        let root = outputRoot
        // The shared bounded page reader: only the canonical owner path for
        // THIS job is ever opened; a stored path outside the spool root (or
        // another job's artifact) reports as unavailable instead of being
        // read.
        let output = job.outputPath.flatMap { path in
            BackgroundJobOutputSpool.readPage(
                jobID: job.id, path: path, offset: offset, maxBytes: maxBytes,
                root: root, recordedBytes: job.outputBytes)
        }.map(JobOutputPageView.init)
        func pagingNote() -> String? {
            guard let output else { return nil }
            if let next = output.nextOffset {
                return "Output page: bytes \(output.offset)..<\(output.offset + output.pageBytes) of the \(output.totalBytes)-byte artifact. Call jobs.result with offset=\(next) for the next page; the artifact path is stable, so this paging keeps working even after earlier pages are dropped from context."
            }
            if output.complete == false {
                // Reaching the end of a CAPPED artifact is not proof the whole
                // job output was read: say exactly what is bounded.
                let original = output.originalBytes.map { "\($0)" } ?? "more than the cap"
                return "Output page: bytes \(output.offset)..<\(output.offset + output.pageBytes) of the \(output.totalBytes)-byte artifact. COMPLETENESS: this artifact is itself a bounded prefix (original output: \(original) bytes; cap \(BackgroundJobOutputSpool.maximumArtifactBytes) bytes), so this is the end of the artifact — NOT necessarily the whole job output. The remainder was not stored; inspect the job's resultPath/workspace if it wrote a file, and never rerun the job automatically."
            }
            if output.complete == true {
                return "Output page: bytes \(output.offset)..<\(output.offset + output.pageBytes) of \(output.totalBytes). This is the last page of the complete output."
            }
            return "Output page: bytes \(output.offset)..<\(output.offset + output.pageBytes) of \(output.totalBytes). The artifact footer was unreadable, so completeness could not be verified; treat this as the end of the stored artifact only."
        }

        func changeNote() -> String? {
            guard let output, output.changedSinceRecorded else { return nil }
            return "The artifact no longer matches the size recorded when the job finished (possibly pruned or changed); the page shows what actually exists now."
        }
        let note: String? = switch job.state {
        case .completed:
            if job.resultPath != nil && JobView(job).resultPath == nil {
                "The job completed, but its recorded result file is no longer present; resultSummary is what remains."
            } else if let pagingNote = pagingNote() {
                [pagingNote, changeNote()].compactMap { $0 }.joined(separator: " ")
            } else if job.resultSummary != nil {
                "Completed; the full output artifact is no longer available, so resultSummary is the recorded result."
            } else {
                nil
            }
        case .interrupted:
            (pagingNote().map { $0 + " " } ?? "")
                + "The process exited before this job finished, so its outcome is UNKNOWN — partial outputs may already exist. Inspect the workspace/output read-only first, then resubmit only what is still missing; do not blindly rerun."
        case .cancelled: "Job was cancelled after its processor stopped; no result is claimed complete. Check the workspace before retrying."
        case .failed: (pagingNote().map { $0 + " " } ?? "") + "Job failed; lastError carries the reason."
        case .queued, .running: JobView(job).cancelling
            ? "Cancellation has been requested; the processor is still stopping and cleaning up. The job is NOT terminal yet."
            : "Job is still \(job.state.rawValue); wait for the completion announcement or poll jobs.status every few seconds."
        }
        if let output, job.state == .completed, let next = output.nextOffset {
            // A completed job always tells the model that more remains.
            return try jobsOutput(Response(
                job: JobView(job),
                resultSummary: job.resultSummary,
                resultDigest: job.resultDigest,
                output: output,
                note: note.map { $0 + " More remains: read the next page with offset=\(next)." } ?? "More remains: read the next page with offset=\(next)."
            ))
        }
        return try jobsOutput(Response(
            job: JobView(job),
            resultSummary: job.resultSummary,
            resultDigest: job.resultDigest,
            output: output,
            note: note
        ))
    }
}

public struct JobsCancelTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.cancel"
    public static let toolDescription = "Cancel a queued or running background job. Cancellation is cooperative and truthful: a running job stays non-terminal (jobs.status reports cancelling=true) until its processor acknowledges and its cleanup completes, then it becomes cancelled. A job that already finished keeps its actual terminal state instead. A cancelled job's partial outputs are never claimed complete."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owned = try await service.ownedJob(id: parseJobID(args.jobID), runID: context.runID)
        let job = try await service.cancel(id: owned.id)
        return try jobsOutput(JobView(job))
    }
}

/// Registers the jobs.* tool group. Call after the target tools are
/// registered so submit-time availability checks see them.
/// - Parameters:
///   - adapters: service-owned prepared-operation adapters keyed by target
///     tool. An adapter with `requiresRuntimeAuthorization` consumes the
///     runtime authority for the exact submitting `jobs.submit` call at
///     submission. Android ships no adapters in this round; the parameter
///     keeps the ORIGINAL seam.
///   - runnerLookup: J3 — when set, the BACKGROUND EXECUTION resolves target
///     runners from this registry (Android passes the job-scoped registry
///     whose exec.shell runner is the lease-reconcile wait extension), while
///     the jobs.* tools themselves register into `registry` exactly like the
///     original. Nil keeps the original single-registry behavior.
///   - outputRootURL: J2 — REQUIRED explicit trusted spool root; the
///     original optional default (Application Support) is removed here.
/// - Returns: the service, so the app can reconcile interrupted jobs at
///   launch and observe terminal transitions for notifications.
@discardableResult
public func registerBackgroundJobTools(
    database: DatabaseManager,
    registry: ToolRunnerRegistry = .shared,
    policy: NativeJobActionPolicy = .default,
    adapters: [String: NativeJobServiceAdapter] = [:],
    onTerminal: @escaping @Sendable (BackgroundJob) async -> Void = { _ in },
    downloadHandler: (@Sendable (BackgroundJob, BackgroundJobDownloadContext) async throws -> Bool)? = nil,
    downloadCancelHandler: (@Sendable (UUID) async -> Void)? = nil,
    downloadTaskLiveness: (@Sendable (UUID) async -> Bool)? = nil,
    /// Spool root for full job output. J2: REQUIRED — Main injects the one
    /// trusted, retention-managed root; this module never derives a location.
    outputRootURL: URL,
    /// J3: registry the service uses to resolve a job's target runner.
    /// Nil uses `registry` exactly like the ORIGINAL.
    runnerLookup: ToolRunnerRegistry? = nil,
    advertise: Bool = true
) -> BackgroundJobService {
    let store = BackgroundJobStore(database: database)
    // Durable dependency edges are wired here, from the same database the
    // job store uses, so no caller has to remember a second registration:
    // a required job keeps its submitting run nonterminal even across a
    // relaunch, and a relaunch reconciles the edge honestly.
    let dependencyStore = SQLiteRunDependencyStore(database: database)
    let spoolRoot = outputRootURL
    let service = BackgroundJobService(
        store: store,
        registry: runnerLookup ?? registry,
        policy: policy,
        adapters: adapters,
        onTerminal: onTerminal,
        downloadHandler: downloadHandler,
        downloadCancelHandler: downloadCancelHandler,
        downloadTaskLiveness: downloadTaskLiveness,
        outputSpooler: { jobID, text in
            guard let spooled = BackgroundJobOutputSpool.write(jobID: jobID, text: text, root: spoolRoot) else {
                throw FloeError.validationFailed("Unable to spool the job output artifact")
            }
            return spooled
        },
        registerDependency: { jobID, runID, conversationID, kind in
            try? await dependencyStore.register(RunDependencyRecord(
                jobID: jobID, runID: runID, conversationID: conversationID, kind: kind))
        },
        resolveDependency: { jobID, state, note in
            _ = try? await dependencyStore.resolve(jobID: jobID, state: state, note: note)
        }
    )
    // J1: the admitted set is the policy's targets that ACTUALLY resolve a
    // runner in the job registry right now — jobs.submit honestly advertises
    // and admits only registered+admitted targets.
    let lookup = runnerLookup ?? registry
    var admitted: Set<String> = []
    for target in policy.supportedTargetNames where lookup.runner(named: target) != nil {
        admitted.insert(target)
    }
    if advertise {
        ToolCatalog.register(JobsSubmitTool.self)
        ToolCatalog.register(JobsStatusTool.self)
        ToolCatalog.register(JobsResultTool.self)
        ToolCatalog.register(JobsCancelTool.self)
        registry.register(JobsSubmitTool(service: service, admittedTargets: admitted))
        registry.register(JobsStatusTool(service: service))
        registry.register(JobsResultTool(service: service, outputRoot: spoolRoot))
        registry.register(JobsCancelTool(service: service))
    }
    return service
}

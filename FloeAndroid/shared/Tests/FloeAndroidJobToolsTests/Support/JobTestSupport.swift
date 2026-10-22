// SPDX-License-Identifier: MPL-2.0
//
// Authored-only test support for the FloeAndroidJobTools closure
// (job-a16c9976985f40b2). This file is NOT executed by the source-authoring
// job; it is host-runnable when Main adds the `FloeAndroidJobToolsTests`
// target to shared/Package.swift and compiles the cohort. All fixtures are
// synthetic: no device, no runtime component, no real engine, no provider
// key, no model call, no credentials. The fake transport is the ONLY engine
// stand-in; production code paths always consume the injected typed seam.

import XCTest
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeAndroidShellTools
import FloeAndroidJobTools

enum JobTestRoot {
    static func make(name: String = "workspace") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-job-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct StaticJobReadiness: LinuxShellReadiness {
    let qualified: Bool
    var isQualifiedForLinuxShell: Bool { qualified }
    var refusalGuidance: String { "test-guidance" }
}

/// Scripted fake of the typed engine transport for job tests. Mirrors the
/// frozen RuntimeWire v1 semantics ONLY as data (merged output pages,
/// monotonic cursor, stop-request-then-release ordering, leaseReleased as
/// the ONLY release proof). Nothing here executes anything.
final class FakeJobShellTransport: LinuxShellTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var starts: [LinuxShellStartRequest] = []
    private(set) var cancels: [LinuxShellCancelRequest] = []
    private(set) var pollTotal = 0
    private var perSessionPolls: [String: Int] = [:]

    /// Thrown by shellStart (the uncertain-start window: a CLAIMED request
    /// whose waiter expired / generation fenced while the engine may still
    /// prepare the process).
    var startError: Error?
    /// (sessionID, cursor, nthPollForSession) -> scripted page. nil pages
    /// fall back to `defaultRunning`.
    var pollScript: ((_ sessionID: String, _ cursor: UInt64, _ nth: Int) -> LinuxShellPollReply?)?
    /// Deterministic stop-driven release: once this many `shell.cancel`
    /// calls are recorded, every poll answers with the terminal page built
    /// from the fields below (engine truth ranks over local intent).
    private var releaseAfterCancels: Int?
    private var releaseCancelled = true
    private var releaseStopReason: String? = "user-stop"
    private var releaseExitCode: Int32?
    private var releaseTermSig: Int32?

    func scriptReleaseAfterCancels(_ count: Int, cancelled: Bool = true,
                                   stopReason: String? = "user-stop",
                                   exit: Int32? = nil, termSig: Int32? = nil) {
        lock.lock()
        releaseAfterCancels = count
        releaseCancelled = cancelled
        releaseStopReason = stopReason
        releaseExitCode = exit
        releaseTermSig = termSig
        lock.unlock()
    }

    var recordedStartCount: Int { lock.lock(); defer { lock.unlock() }; return starts.count }
    var recordedCancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancels.count }
    var recordedPollTotal: Int { lock.lock(); defer { lock.unlock() }; return pollTotal }

    func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply {
        let (error, index) = recordStartLocked(request)
        if let error { throw error }
        return LinuxShellStartReply(sessionID: "lease-\(index)-\(request.runID.uuidString)",
                                    environmentID: request.environmentID ?? "linux.local")
    }

    /// Swift 6 noasync-safe: the NSLock critical section is a SYNCHRONOUS
    /// helper; the async transport method only calls it.
    private func recordStartLocked(_ request: LinuxShellStartRequest) -> (Error?, Int) {
        lock.lock(); defer { lock.unlock() }
        starts.append(request)
        return (startError, starts.count)
    }

    struct PollSnapshot {
        let nth: Int
        let scripted: ((String, UInt64, Int) -> LinuxShellPollReply?)?
        let releaseReady: Bool
        let releaseCancelled: Bool
        let releaseStopReason: String?
        let releaseExitCode: Int32?
        let releaseTermSig: Int32?
    }

    private func pollStateLocked(_ request: LinuxShellPollRequest) -> PollSnapshot {
        lock.lock(); defer { lock.unlock() }
        pollTotal += 1
        let nth = (perSessionPolls[request.sessionID] ?? 0) + 1
        perSessionPolls[request.sessionID] = nth
        let releaseGate = releaseAfterCancels
        let releaseReady = releaseGate.map { cancels.count >= $0 } ?? false
        return PollSnapshot(nth: nth, scripted: pollScript, releaseReady: releaseReady,
                            releaseCancelled: releaseCancelled,
                            releaseStopReason: releaseStopReason,
                            releaseExitCode: releaseExitCode,
                            releaseTermSig: releaseTermSig)
    }

    func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply {
        let snapshot = pollStateLocked(request)
        let nth = snapshot.nth
        let scripted = snapshot.scripted
        let releaseReady = snapshot.releaseReady
        let releaseCancelled = snapshot.releaseCancelled
        let releaseStopReason = snapshot.releaseStopReason
        let releaseExitCode = snapshot.releaseExitCode
        let releaseTermSig = snapshot.releaseTermSig
        if releaseReady {
            return Self.page(session: request.sessionID, cursor: request.cursor, text: "",
                             state: .terminated, released: true,
                             cancelled: releaseCancelled, stopReason: releaseStopReason,
                             exit: releaseExitCode, termSig: releaseTermSig)
        }
        if let scripted, let reply = scripted(request.sessionID, request.cursor, nth) {
            return reply
        }
        return Self.page(session: request.sessionID, cursor: request.cursor, text: "")
    }

    func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply {
        LinuxShellInputReply(acceptedBytes: request.bytes.count)
    }

    func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply {
        LinuxShellResizeReply(resized: true)
    }

    func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply {
        recordCancelLocked(request)
        return LinuxShellCancelReply(state: "stop_requested")
    }

    private func recordCancelLocked(_ request: LinuxShellCancelRequest) {
        lock.lock(); cancels.append(request); lock.unlock()
    }

    static func page(session: String, cursor: UInt64, text: String,
                     more: Bool = false, state: LinuxShellSessionState = .running,
                     released: Bool = false, cancelled: Bool = false, stopReason: String? = nil,
                     exit: Int32? = nil, termSig: Int32? = nil, waitErrno: Int32? = nil,
                     gap: Int = 0, dropped: Int = 0,
                     workspaceStatus: String? = "synced", workspaceRecoveryRef: String? = nil) -> LinuxShellPollReply {
        let bytes = Data(text.utf8)
        return LinuxShellPollReply(sessionID: session, mergedOutput: bytes,
                                   cursor: cursor + UInt64(bytes.count),
                                   gapBytes: gap, more: more, droppedBytes: dropped,
                                   state: state, leaseReleased: released,
                                   cancelled: cancelled, stopReason: stopReason,
                                   exitCode: exit, termSig: termSig, waitErrno: waitErrno,
                                   workspaceStatus: workspaceStatus, workspaceRecoveryRef: workspaceRecoveryRef)
    }
}

/// Deterministic settlement gate stand-in for the trusted host. The answers
/// are consumed in order; afterwards the fallback applies (default
/// `.unconfirmed` — a test that expects settlement MUST script it, exactly
/// like production: the adapter never infers a terminal from silence).
final class ScriptedJobGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [JobShellSettlement]
    private let fallback: JobShellSettlement
    private(set) var queries: [JobShellSettlementQuery] = []

    init(answers: [JobShellSettlement] = [], fallback: JobShellSettlement = .unconfirmed(reason: "scripted")) {
        self.remaining = answers
        self.fallback = fallback
    }

    func answer(for query: JobShellSettlementQuery) -> JobShellSettlement {
        lock.lock()
        queries.append(query)
        let settlement: JobShellSettlement
        if remaining.isEmpty { settlement = fallback }
        else { settlement = remaining.removeFirst() }
        lock.unlock()
        return settlement
    }

    var queryCount: Int { lock.lock(); defer { lock.unlock() }; return queries.count }
    var recordedQueries: [JobShellSettlementQuery] { lock.lock(); defer { lock.unlock() }; return queries }
}

/// Builds the ORIGINAL exec.shell chain (LocalShellService ->
/// AndroidLinuxShellBackend) over the fake transport and returns its shared-
/// registry-shaped AnyAgentTool, mirroring how G02 composition exposes it.
func makeExecShellInner(root: URL)
    -> (backend: AndroidLinuxShellBackend, transport: FakeJobShellTransport, inner: AnyAgentTool) {
    let transport = FakeJobShellTransport()
    let backend = AndroidLinuxShellBackend(
        transport: transport,
        readiness: StaticJobReadiness(qualified: true),
        configuration: AndroidLinuxShellBackend.Configuration(
            pollIntervalNanos: 2_000_000,
            releaseGrace: 0.25,
            stdinWriteRetries: 4,
            reconcileIntervalNanos: 20_000_000,
            reconcileObservation: 30))
    let service = LocalShellService(backend: backend, rootProvider: { root })
    let registry = ToolRunnerRegistry()
    registry.register(LocalShellTool(shell: service))
    guard let inner = registry.runner(named: "exec.shell") else {
        preconditionFailure("exec.shell runner must exist in the test registry")
    }
    return (backend, transport, inner)
}

func makeExecShellRunner(
    root: URL,
    gate: ScriptedJobGate,
    index: JobLiveWorkIndex,
    ceiling: TimeInterval = 5
) -> (transport: FakeJobShellTransport, backend: AndroidLinuxShellBackend, runner: AnyAgentTool) {
    let (backend, transport, inner) = makeExecShellInner(root: root)
    let wrapper = ExecShellJobRunner(
        inner: inner,
        backend: backend,
        transport: transport,
        gate: { query in gate.answer(for: query) },
        index: index,
        configuration: ExecShellJobRunnerConfiguration(
            pollIntervalNanos: 5_000_000,
            queryIntervalNanos: 10_000_000,
            maxQueryIntervalNanos: 50_000_000,
            reconcileCeiling: ceiling))
    return (transport, backend, wrapper.makeRunner())
}

func jobPayload(_ command: String = "sleep 30", timeout: Double = 0.1) -> Data {
    let object: [String: Any] = ["command": command, "timeout": timeout]
    return try! JSONSerialization.data(withJSONObject: object)
}

/// The ORIGINAL job-context shape the service builds (trusted frozen
/// identity; the `jobs.` call-id prefix is what selects the background
/// timeout ceiling).
func jobContext(runID: UUID, jobID: UUID, root: URL,
                cancellation: CancellationToken,
                taskProgress: (any TaskProgressReporting)? = nil) -> ToolContext {
    ToolContext(runID: runID,
                toolCallID: "jobs.\(jobID.uuidString)",
                toolIdempotencyKey: "job:\(jobID.uuidString)",
                scope: .local,
                workspaceRootURL: root,
                allowedWorkspacePaths: [],
                cancellation: cancellation,
                environmentID: "linux.local",
                conversationID: UUID(),
                taskProgress: taskProgress)
}

/// Wait until a condition holds, polling cooperatively (bounded).
func jobWaitUntil(timeoutMillis: Int = 3_000, _ condition: () async -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(timeoutMillis) &* 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Progress recorder double for the durable-reporting assertions.
final class RecordingJobProgress: TaskProgressReporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var updates: [TaskProgressUpdate] = []
    func report(_ update: TaskProgressUpdate) async {
        appendUpdateLocked(update)
    }

    private func appendUpdateLocked(_ update: TaskProgressUpdate) {
        lock.lock(); updates.append(update); lock.unlock()
    }
    var recorded: [TaskProgressUpdate] { lock.lock(); defer { lock.unlock() }; return updates }
}

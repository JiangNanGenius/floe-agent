// FloeAndroidJobTools — exec.shell JOB runner with real engine-terminal
// verification (job-a16c9976985f40b2).
//
// WHY THIS EXISTS. The ORIGINAL BackgroundJobService settles a job's terminal
// state when the target runner's processor RETURNS. On iOS that was sound:
// the exec.shell backend killed the guest process on its own timeout, so a
// return meant the work was really done. On Android the shell executes in the
// SEPARATE-UID runtime engine through the owned mailbox: the delivered
// backend may hand back `.timedOut`/`.cancelled`/lease-retained `.failed`
// while the remote workload is STILL OWNED (lease unreleased, or a CLAIMED
// `shell.start` receipt whose preparation/process may still exist — the
// uncertain-start window Main documented 2026-10-22). The ORIGINAL durable
// semantics are: cancellation is a REQUEST until the processor acknowledges
// with cleanup; an unproven outcome is UNKNOWN, never a fake success.
//
// THIS RUNNER IS THE ACKNOWLEDGMENT, NOT A SECOND EXECUTION SYSTEM:
// * it wraps the ORIGINAL exec.shell AnyAgentTool from the shared registry
//   (same descriptor, same validate/preflight, same LocalShellService
//   authority) and runs it UNCHANGED as the processor;
// * when the original dispatch already returned an engine-PROVEN terminal
//   (`exited`/`blocked`/`notStarted` and any release-ranked `timedOut`,
//   `cancelled` or real-exit outcome the backend produced AFTER
//   `leaseReleased`), its output passes through BYTE-IDENTICAL;
// * only when the local wait ended with the engine STILL OWNED — a session
//   visible in `AndroidLinuxShellBackend.ownedSessions(runID:)` (active or
//   reconciliation, per Main's fixed ledger semantics), or the uncertain-
//   start window with no visible session — does the processor EXTEND:
//   1. poll the engine lease directly through the typed transport
//      (`shell.poll`, read-only cursor snapshots; the merged-output bytes
//      after the handoff are NOT recoverable and are never pretended: the
//      settled output says so), until `leaseReleased` proves the terminal
//      fields, mapping the engine truth with the SAME ranking the delivered
//      backend uses (waitErrno != 0 is never benign; `cancelled` + stop
//      reason outrank local intent; a released lease WITHOUT `cancelled` is
//      a real exit — a job that finished first keeps its actual result);
//   2. when no session is visible (claimed-start receipt not yet resolved,
//      or the mailbox generation was fenced under it) consult the REQUIRED
//      Main settlement gate — the host pump that retains the exact request
//      receipt, never replays, requests the real startup-window stop and
//      defers FAILURE completion until UID recovery/quiescence proves idle
//      or `session.leaseReleased`. The gate answers `.released`, `.quiescent`
//      or `.unconfirmed`; `.unconfirmed` KEEPS the job nonterminal (the
//      processor does not return). There is NO default gate and NO stub-true
//      answer in this module: composition refuses to register jobs without
//      an injected gate.
//   3. if neither the engine poll nor the gate proves settlement within the
//      bounded reconciliation ceiling, the processor throws
//      `NativeJobSafetyFailure` (UnsafeResourceStateError): the ORIGINAL
//      service records an honest "unsafe resource state (not a clean
//      cancellation)" failure — never a fake completion, never a claimed
//      clean cancellation, and the lease/receipt ownership notes survive for
//      Main's census + the durable launch-reconciliation path.
// * a job token cancelled DURING the extended wait routes the REAL stop:
//   `shell.cancel` for the exact visible engine session through the typed
//   transport, and the settlement query with `cancellationRequested` for
//   the startup-window receipt (the pump accepts the exact pending
//   requestID during startup) — lifecycle cancellation never stops at the
//   Swift token;
// * the live-work index counts the FULL extended span, so the Core FGS
//   projection sees exactly the processors whose real cleanup is still
//   outstanding — a stored "running" row without a processor here is not
//   live work.
//
// Foreground dispatch is untouched: this wrapper lives ONLY in the job-scoped
// registry that BackgroundJobService resolves target runners from (mirror
// delta J3). The shared registry still holds the original exec.shell tool.

import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

/// What the ORIGINAL dispatch intended when it handed back an unproven
/// terminal; derived from the tool's own exit vocabulary (124 timedOut /
/// 130 cancelled / 125 engine-failure), never from model text.
public enum JobShellWaitIntent: String, Sendable, Equatable {
    case timedOut
    case userCancelled
    case unclassified
}

/// Query handed to the trusted Main settlement gate for the uncertain-start
/// / post-fence window. Identities only; never command lines or output.
public struct JobShellSettlementQuery: Sendable, Equatable {
    public var runID: UUID
    public var jobID: UUID?
    public var toolCallID: String?
    /// Engine lease id last observed in the backend's owned-session snapshot
    /// (nil when the start receipt never resolved into a visible session).
    public var lastKnownSessionID: String?
    public var intent: JobShellWaitIntent
    /// True when the job's cancellation token became cancelled during the
    /// extended wait: the pump must request the REAL startup-window stop for
    /// the exact pending requestID (and keep ownership until it proves).
    public var cancellationRequested: Bool

    public init(runID: UUID, jobID: UUID?, toolCallID: String?,
                lastKnownSessionID: String?, intent: JobShellWaitIntent,
                cancellationRequested: Bool) {
        self.runID = runID
        self.jobID = jobID
        self.toolCallID = toolCallID
        self.lastKnownSessionID = lastKnownSessionID
        self.intent = intent
        self.cancellationRequested = cancellationRequested
    }
}

/// The gate's ONLY three honest answers. Anything that has not been PROVEN
/// is `.unconfirmed` and the job stays nonterminal.
public enum JobShellSettlement: Sendable, Equatable {
    /// The engine release is proven with its terminal fields (same ranking
    /// vocabulary as the typed poll reply).
    case released(sessionID: String, cancelled: Bool, stopReason: String?,
                  exitCode: Int32?, termSig: Int32?, waitErrno: Int32?,
                  workspaceStatus: String? = nil, workspaceRecoveryRef: String? = nil)
    /// Whole-UID quiescence is proven: no live workload remains. The command
    /// TERMINAL itself may be unobserved — this never claims a success.
    case quiescent(note: String)
    /// Cleanup/release NOT proven right now; the adapter keeps waiting.
    case unconfirmed(reason: String)
}

/// The REQUIRED trusted-host settlement gate (no default, never stubbed here).
public typealias JobShellSettlementGate =
    @Sendable (JobShellSettlementQuery) async -> JobShellSettlement

public struct ExecShellJobRunnerConfiguration: Sendable {
    /// Cadence for direct engine-lease polls while a session is visible.
    public var pollIntervalNanos: UInt64
    /// Base cadence for backend-session snapshot re-probes and gate queries
    /// (grows geometrically up to `maxQueryIntervalNanos`).
    public var queryIntervalNanos: UInt64
    public var maxQueryIntervalNanos: UInt64
    /// Hard ceiling of the extended wait. Beyond it the processor throws
    /// `NativeJobSafetyFailure` — ownership (lease/receipt) stays retained
    /// for Main's census and the durable launch-recovery path; the job is
    /// never falsely acknowledged. Default mirrors the delivered backend's
    /// releaseGrace (30s) + reconcileObservation (30min) with one full
    /// engine deadline of margin.
    public var reconcileCeiling: TimeInterval

    public init(
        pollIntervalNanos: UInt64 = 500_000_000,
        queryIntervalNanos: UInt64 = 1_000_000_000,
        maxQueryIntervalNanos: UInt64 = 5_000_000_000,
        reconcileCeiling: TimeInterval = 3_600
    ) {
        self.pollIntervalNanos = pollIntervalNanos
        self.queryIntervalNanos = queryIntervalNanos
        self.maxQueryIntervalNanos = maxQueryIntervalNanos
        self.reconcileCeiling = reconcileCeiling
    }
}

public struct ExecShellJobRunner: Sendable {
    public static let toolName = "exec.shell"

    private let inner: AnyAgentTool
    private let backend: AndroidLinuxShellBackend
    private let transport: any LinuxShellTransport
    private let gate: JobShellSettlementGate
    private let index: JobLiveWorkIndex
    private let configuration: ExecShellJobRunnerConfiguration

    /// Wrap the ORIGINAL exec.shell runner. The returned AnyAgentTool keeps
    /// the inner descriptor, validation and submit-time preflight BYTE-EQUAL
    /// (the job-scoped registry exposes exactly the original tool surface).
    public init(
        inner: AnyAgentTool,
        backend: AndroidLinuxShellBackend,
        transport: any LinuxShellTransport,
        // G03-native-integration compile repair 3: the gate is a function-typed
        // parameter that THIS struct stores; Swift 6 requires explicit
        // @escaping (the typealias carries @Sendable, which does not imply it).
        gate: @escaping JobShellSettlementGate,
        index: JobLiveWorkIndex,
        configuration: ExecShellJobRunnerConfiguration = ExecShellJobRunnerConfiguration()
    ) {
        precondition(inner.descriptor.name == Self.toolName,
                     "ExecShellJobRunner must wrap the original exec.shell runner")
        self.inner = inner
        self.backend = backend
        self.transport = transport
        self.gate = gate
        self.index = index
        self.configuration = configuration
    }

    public func makeRunner() -> AnyAgentTool {
        AnyAgentTool(
            descriptor: inner.descriptor,
            run: { [self] argumentsJSON, context in
                try await self.execute(argumentsJSON: argumentsJSON, context: context)
            },
            validateArguments: inner.validateArguments,
            preflightSubmission: inner.preflightSubmission
        )
    }

    private func execute(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        let jobID = JobProcessorIdentity.jobID(fromToolCallID: context.toolCallID)
        if let jobID { try await index.begin(jobID: jobID, targetTool: Self.toolName) }
        do {
            let output = try await inner.run(argumentsJSON, context)
            // Task cancellation requests stop; it must not cancel the
            // transport queries/backoff needed to prove actual cleanup.
            // The original processor awaits and owns this complete span.
            let reconciled = try await Task.detached { [self] in
                try await settleIfNeeded(output: output, context: context, jobID: jobID)
            }.value
            if let jobID { await index.settle(jobID: jobID) }
            return reconciled
        } catch {
            // A real throw settles the LIVE view (the processor is done in
            // THIS process); lease/receipt ownership notes were already
            // carried by NativeJobSafetyFailure or the durable stores.
            if let jobID { await index.settle(jobID: jobID) }
            throw error
        }
    }

    /// Returns the original output UNCHANGED when the dispatch already ended
    /// engine-proven; otherwise extends the processor until the engine (or
    /// the REQUIRED Main gate) proves the real terminal / quiescence, and
    /// never before that.
    private func settleIfNeeded(
        output: ToolExecutionOutput,
        context: ToolContext,
        jobID: UUID?
    ) async throws -> ToolExecutionOutput {
        guard let exit = output.exitStatus else { return output }
        let intent: JobShellWaitIntent
        switch exit {
        case 124: intent = .timedOut
        case 130: intent = .userCancelled
        case 125: intent = .unclassified
        default:
            // `exited` (any code) is produced by the delivered backend ONLY
            // after `leaseReleased` proved the real terminal; `blocked`/
            // `notStarted` never reached the engine at all. Byte pass-through.
            return output
        }
        let owned = await backend.ownedSessions(runID: context.runID)
        if owned.isEmpty {
            switch intent {
            case .timedOut, .userCancelled:
                // A timedOut/cancelled answer with NOTHING owned means the
                // terminal was engine-ranked on a proven release (either by
                // the waiter itself or by the backend's reconciliation task
                // before this probe). The delivered output already carries
                // the engine truth — pass it through byte-identical.
                return output
            case .unclassified:
                // Engine failure answer with nothing visible owned: exactly
                // the uncertain-START window (a CLAIMED `shell.start` receipt
                // whose preparation/process may still exist) or a local
                // refusal. The REQUIRED gate is the only channel that knows
                // which: `.quiescent` proves nothing ran / no unresolved
                // receipt; `.released` carries the terminal fields;
                // `.unconfirmed` KEEPS the job nonterminal. A possibly-live
                // claimed start NEVER passes through unexamined.
                break
            }
        }
        // Extended wait: the job processor has NOT returned until settlement
        // is proven. Report real (non-percentaged) progress into the durable
        // record via the ORIGINAL taskProgress channel.
        await context.taskProgress?.report(TaskProgressUpdate(
            stage: context.cancellation.isCancelled ? "cancelling" : "running",
            phase: "engineLeaseReconcile",
            note: "local wait ended while the runtime engine workload is still owned; waiting for the lease release or quiescence proof before settling the job"))
        let started = Date()
        var watch = owned.first.map { ($0.engineSessionID, $0.cursor) }
        var stopIssuedForSession: String? = nil
        var lastKnownSessionID: String? = watch?.0
        var queryInterval = configuration.queryIntervalNanos
        while Date().timeIntervalSince(started) < configuration.reconcileCeiling {
            let effectiveIntent: JobShellWaitIntent =
                context.cancellation.isCancelled ? .userCancelled : intent
            if var watchEntry = watch {
                // A job cancellation arriving during the wait must route the
                // REAL stop for the exact live session, once.
                if context.cancellation.isCancelled, stopIssuedForSession != watchEntry.0 {
                    stopIssuedForSession = watchEntry.0
                    _ = try? await transport.shellCancel(LinuxShellCancelRequest(sessionID: watchEntry.0))
                }
                do {
                    let page = try await transport.shellPoll(
                        LinuxShellPollRequest(sessionID: watchEntry.0,
                                              cursor: watchEntry.1,
                                              maxBytes: 1))
                    if page.leaseReleased {
                        return mappedRelease(original: output, sessionID: watchEntry.0,
                                             cancelled: page.cancelled, stopReason: page.stopReason,
                                             exitCode: page.exitCode, termSig: page.termSig,
                                             waitErrno: page.waitErrno,
                                             workspaceStatus: page.workspaceStatus, workspaceRecoveryRef: page.workspaceRecoveryRef,
                                             intent: intent, context: context)
                    }
                    watchEntry.1 = page.cursor
                    watch = watchEntry
                    lastKnownSessionID = watchEntry.0
                } catch let error as LinuxShellTransportError {
                    switch error {
                    case .hostFenced, .notBound:
                        // The mailbox generation is gone; the Kotlin pump
                        // still retains the exact receipt. The gate below
                        // carries that truth.
                        watch = nil
                    default:
                        // remoteFailed / replyMalformed / saturated /
                        // waitBudgetExpired: the session answer is no
                        // longer trustworthy here — ask the gate once,
                        // then keep watching if unconfirmed.
                        let settlement = await gate(query(context: context, jobID: jobID,
                                                          lastKnownSessionID: lastKnownSessionID,
                                                          intent: effectiveIntent))
                        switch settlement {
                        case .released(let sessionID, let cancelled, let stopReason,
                                        let exitCode, let termSig, let waitErrno, let workspaceStatus, let workspaceRecoveryRef):
                            return mappedRelease(original: output, sessionID: sessionID,
                                                 cancelled: cancelled, stopReason: stopReason,
                                                 exitCode: exitCode, termSig: termSig,
                                                 waitErrno: waitErrno, workspaceStatus: workspaceStatus, workspaceRecoveryRef: workspaceRecoveryRef,
                                                 intent: intent, context: context)
                        case .quiescent(let note):
                            return settleQuiescent(original: output, intent: effectiveIntent,
                                                   note: note, context: context)
                        case .unconfirmed:
                            break
                        }
                    }
                } catch {
                    // Unknown non-transport error: keep polling; the
                    // reconciliation ceiling bounds this path.
                }
                try? await Task.sleep(nanoseconds: configuration.pollIntervalNanos)
            } else {
                // No visible session: uncertain-start (claimed receipt that
                // never resolved into a session) or post-fence settlement.
                let settlement = await gate(query(context: context, jobID: jobID,
                                                  lastKnownSessionID: lastKnownSessionID,
                                                  intent: effectiveIntent))
                switch settlement {
                case .released(let sessionID, let cancelled, let stopReason,
                                let exitCode, let termSig, let waitErrno, let workspaceStatus, let workspaceRecoveryRef):
                    return mappedRelease(original: output, sessionID: sessionID,
                                         cancelled: cancelled, stopReason: stopReason,
                                         exitCode: exitCode, termSig: termSig,
                                         waitErrno: waitErrno, workspaceStatus: workspaceStatus, workspaceRecoveryRef: workspaceRecoveryRef,
                                                 intent: intent, context: context)
                case .quiescent(let note):
                    return settleQuiescent(original: output, intent: effectiveIntent,
                                           note: note, context: context)
                case .unconfirmed:
                    break
                }
                try? await Task.sleep(nanoseconds: queryInterval)
                queryInterval = min(configuration.maxQueryIntervalNanos, queryInterval * 2)
            }
        }
        throw NativeJobSafetyFailure(
            reason: "exec.shell job engine settlement could not be proven within the bounded "
                + "reconciliation window (sessionHint=\(lastKnownSessionID ?? "none")); the runtime "
                + "lease/receipt ownership is retained for the host census and the durable launch "
                + "recovery path; nothing was replayed, assumed or reported as a clean stop")
    }

    private func query(
        context: ToolContext,
        jobID: UUID?,
        lastKnownSessionID: String?,
        intent: JobShellWaitIntent
    ) -> JobShellSettlementQuery {
        JobShellSettlementQuery(
            runID: context.runID,
            jobID: jobID,
            toolCallID: context.toolCallID,
            lastKnownSessionID: lastKnownSessionID,
            intent: intent,
            cancellationRequested: context.cancellation.isCancelled)
    }

    /// Engine-truth mapping with the SAME ranking the delivered backend uses:
    /// waitErrno != 0 is never benign; `cancelled` + stop reason outrank the
    /// local intent; a released lease WITHOUT `cancelled` is a real exit.
    /// Local intents here are `cancel = context.cancellation.isCancelled`
    /// and `timeout = intent == .timedOut` — exactly the backend's
    /// `cancelIntent`/`timeoutIntent` pair.
    private func mappedRelease(
        original: ToolExecutionOutput,
        sessionID: String,
        cancelled: Bool,
        stopReason: String?,
        exitCode: Int32?,
        termSig: Int32?,
        waitErrno: Int32?,
        workspaceStatus: String?,
        workspaceRecoveryRef: String?,
        intent: JobShellWaitIntent,
        context: ToolContext
    ) -> ToolExecutionOutput {
        var section = "\n--- engine terminal (reconciled after local wait) ---\n"
            + "leaseReleased=true session=\(sessionID) cancelled=\(cancelled)"
            + " stopReason=\(stopReason ?? "nil")"
            + " exitCode=\(exitCode.map { "\($0)" } ?? "nil")"
            + " termSig=\(termSig.map { "\($0)" } ?? "nil")"
            + " waitErrno=\(waitErrno.map { "\($0)" } ?? "nil")\n"
            + "note: merged PTY output beyond what the local wait collected is not recoverable; "
            + "inspect existing outputs read-only before resubmitting."
        let base = original.summary
        let terminal: (text: String, exit: Int32)
        if let waitErrno, waitErrno != 0 {
            terminal = ("status=engineWaitError waitErrno=\(waitErrno)", 125)
        } else if cancelled {
            switch stopReason {
            case "timeout":
                terminal = ("status=timedOut engineTruth=timeoutStop leaseReleased=true", 124)
            case "user-stop":
                terminal = ("status=cancelled engineTruth=userStop leaseReleased=true", 130)
            case "start-binding-failed":
                terminal = ("status=failed engineTruth=startBindingFailed leaseReleased=true", 125)
            case .some(let code):
                if context.cancellation.isCancelled {
                    terminal = ("status=cancelled engineTruth=cancelled stopReason=\(code)", 130)
                } else {
                    terminal = ("status=failed engineTruth=cancelled unknownStopReason=\(code)", 125)
                }
            case nil:
                // Defensive: cancelled without a reason code. Only a tracked
                // local intent may classify it (backend-exact ranking).
                if context.cancellation.isCancelled {
                    terminal = ("status=cancelled engineTruth=cancelled stopReason=absent", 130)
                } else if intent == .timedOut {
                    terminal = ("status=timedOut engineTruth=cancelled stopReason=absent", 124)
                } else {
                    terminal = ("status=cancelled engineTruth=cancelled stopReason=absent", 130)
                }
            }
        } else {
            // Released WITHOUT cancelled is a real exit even when a local
            // stop raced it — the actual result is reported, never masked.
            let code: Int32
            if let termSig, termSig > 0 { code = 128 + termSig }
            else { code = exitCode ?? -1 }
            terminal = ("status=reconciledExit leaseReleased=true exit=\(code)", code)
        }
        section += "workspace=\(workspaceStatus ?? "unknown")"
            + (workspaceRecoveryRef.map { " recovery=\($0)" } ?? "") + "\n"
        if !cancelled && workspaceStatus != "synced" {
            section += "settled: file changes were not confirmed saved; real process exit is recorded above.\n"
            return ToolExecutionOutput(digesting: base + section, exitStatus: 125)
        }
        section += "settled: \(terminal.text)\n"
        return ToolExecutionOutput(digesting: base + section, exitStatus: terminal.exit)
    }

    /// Quiescence proven by the host census without a command terminal:
    /// the local-wait answer stands, plus the honest note. Never a success.
    private func settleQuiescent(
        original: ToolExecutionOutput,
        intent: JobShellWaitIntent,
        note: String,
        context: ToolContext
    ) -> ToolExecutionOutput {
        let acknowledge: String
        switch intent {
        case .userCancelled:
            acknowledge = "cancellation acknowledged: engine census proves no live workload remains"
        case .timedOut:
            acknowledge = context.cancellation.isCancelled
                ? "cancellation acknowledged: engine census proves no live workload remains"
                : "deadline reached; engine census proves no live workload remains"
        case .unclassified:
            acknowledge = "engine census proves no live workload remains"
        }
        let text = original.summary
            + "\n--- engine settlement (reconciled) ---\nquiescent=true \(acknowledge)"
            + "\ncommand terminal unobserved: outcome is NOT claimed successful; inspect existing outputs read-only.\n"
            + "note: \(String(note.prefix(512)))\n"
        return ToolExecutionOutput(digesting: text, exitStatus: original.exitStatus ?? 125)
    }
}

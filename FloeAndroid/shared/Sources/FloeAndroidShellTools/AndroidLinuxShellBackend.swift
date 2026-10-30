// FloeAndroidShellTools — Android-owned `LocalShellBackend` over the typed
// runtime-UID Linux engine transport (job-1bd4fcce5eca4856).
//
// Contract honesty:
// * NOTHING here ever runs a host command. Every engine touch is a typed
//   call on the injected `LinuxShellTransport` (Core mailbox in production;
//   fakes in tests). Component selection, paths, leases and native
//   completion are engine-owned, never caller/model fields.
// * Owner routing is explicit and fail-closed: a missing run identity or
//   an unqualified readiness refuses work. The projectID is the
//   deterministic SHA256-derived UUID of the TRUSTED canonical Core
//   workspace root (LinuxShellProjectMapping); runID, conversationID and
//   environmentID survive unchanged from the original service/context
//   path. A conversation is never inferred from session text.
// * The engine runs ONE local workload globally at first. This backend
//   mirrors the original process-wide run gate: a one-shot run that cannot
//   take the gate within `gateTimeout` reports `.notStarted` (never a fake
//   timeout), and a session open is rejected. The gate is released only
//   when the engine proves `leaseReleased` — EOF != exit; a cancelled or
//   timed-out local wait requests the remote stop and RETAINS ownership
//   for reconciliation until the real release (or a generation fence).
// * Merged PTY output: the engine never splits stdout/stderr. The backend
//   reports merged bytes as the output with an EMPTY stderr and honest
//   truncation/gap metadata — no invented split. Backend-generated
//   metadata (for example a stdin-write errno) is labelled, never merged
//   into engine bytes.
// * Terminal truth ordering: the engine's own terminal fields outrank the
//   local intent. A released lease with `cancelled` + `stopReason` maps to
//   the honest outcome (`timeout` -> .timedOut, `user-stop` -> .cancelled,
//   `start-binding-failed` -> .failed); a released lease WITHOUT
//   `cancelled` is a real exit (.exited with the engine code) even if a
//   local stop request had raced it. A timed-out/cancelled LOCAL wait is
//   NOT proof the remote exited: ownership stays until `leaseReleased`.
// * Explicit per-run caller `env` maps ride the typed start request and
//   mailbox UNCHANGED, but ONLY after passing the engine's own bounds
//   (<=32 entries, engine key shape, no PROOT_*/FLOE_* or authority-owned
//   HOME/TMPDIR keys, no NUL, <=32 KiB combined bytes). A breach fails
//   closed locally instead of silently dropping entries; the Main process
//   environment and stored credentials are never injected here.
// * Stdin reality (two engine descriptor modes; documented platform delta
//   versus the ios_system pipe): interactive input keeps the legacy PTY
//   path — `openSession` omits `stdinDelivery`, so the engine defaults to
//   "pty" and the canonical-mode Ctrl-D (0x04) byte stays the line
//   discipline's EOF for exchange sessions. One-shot `run` selects the
//   trusted `stdinDelivery:"pipe"` start: data rides `shell.input` base64
//   pages (<=16 KiB with acceptedBytes/partial cursor) and stdin ALWAYS
//   ends with exactly one EMPTY page commanding the engine's descriptor
//   close (`stdinEof closed|closed-idempotent|failed|rejected`) —
//   including nil/empty stdin. A 0x04 byte in pipe stdin is ordinary data;
//   the deleted EOT emulation must never return. EOF is NOT an exit: the
//   lease releases only on `leaseReleased` with the real terminal.
// * Signals: INT rides the PTY 0x03 byte (the line discipline raises
//   SIGINT for the foreground group — the faithful PTY equivalent of the
//   original cooperative interrupt). TERM and KILL both map to the ONE
//   engine-owned stop (`shell.cancel`: transport stop + whole-UID census
//   proof). There is no kill-by-name surface to fake.

import Foundation
import FloeCore
import FloeTools

public actor AndroidLinuxShellBackend: LocalShellBackend {

    public struct Configuration: Sendable {
        /// Poll cadence while a one-shot run is active (bounded backoff).
        public var pollIntervalNanos: UInt64
        /// Ceiling past the effective timeout/stop request before the local
        /// wait answers honestly and hands the lease to reconciliation.
        public var releaseGrace: TimeInterval
        /// Ceiling on stdin write backpressure retries for one chunk.
        public var stdinWriteRetries: Int
        /// Reconciliation cadence for retained (cancelled/timed-out) leases.
        public var reconcileIntervalNanos: UInt64
        /// Reconciliation stays observable for this long before it is only
        /// reported via `unreconciledSessions()` (never forgotten silently).
        public var reconcileObservation: TimeInterval
        /// Engine deadline handed to interactive `shell.start` sessions:
        /// interactive lifetime is owned by the session center's 30-minute
        /// sliding expiry; the engine ceiling matches it.
        public var interactiveEngineDeadline: TimeInterval

        public init(
            pollIntervalNanos: UInt64 = 50_000_000,
            releaseGrace: TimeInterval = 30,
            stdinWriteRetries: Int = 64,
            reconcileIntervalNanos: UInt64 = 500_000_000,
            reconcileObservation: TimeInterval = 30 * 60,
            interactiveEngineDeadline: TimeInterval = 30 * 60
        ) {
            self.pollIntervalNanos = pollIntervalNanos
            self.releaseGrace = releaseGrace
            self.stdinWriteRetries = stdinWriteRetries
            self.reconcileIntervalNanos = reconcileIntervalNanos
            self.reconcileObservation = reconcileObservation
            self.interactiveEngineDeadline = interactiveEngineDeadline
        }
    }

    /// One live engine session known to this backend, keyed by the ORIGINAL
    /// runtime-issued session token (client-scoped session token / center
    /// sessionID). The engine's own lease id is stored inside.
    public struct EngineSession: Sendable, Equatable {
        public var sessionKey: String
        public var engineSessionID: String
        public var environmentID: String
        /// Trusted owner identities threaded from the ORIGINAL
        /// service/context path (never model-supplied); used by the Core
        /// facade's owned-work ledger for run-scoped reconciliation.
        public var runID: UUID?
        public var conversationID: UUID?
        public var cursor: UInt64
        public var bytesRead: Int
        public var bytesWritten: Int
        public var state: LinuxShellSessionState
        public var leaseReleased: Bool
        /// Engine truth once terminal: the terminal came from a proven stop.
        public var cancelled: Bool
        /// Fixed engine service stop code once cancelled; rides unchanged.
        public var stopReason: String?
        public var workspaceStatus: String? = nil
        public var workspaceRecoveryRef: String? = nil
        /// OPTIONAL per-execution recovery projection proven by the engine's
        /// OWN terminal envelope (identity-bound session key + run echo).
        /// Never fabricated; stays nil for legacy/unobserved results.
        public var workspaceRecovery: LinuxShellWorkspaceRecovery? = nil
        /// Real engine terminal fields, present ONLY once the engine reaped
        /// the root child (EOF/stop-request alone never fills them).
        public var exitCode: Int32?
        public var termSig: Int32?
        /// True once a stop was REQUESTED (cancel/timeout); it is NOT a
        /// proven stop until `leaseReleased` arrives with the real terminal.
        public var stopRequested: Bool

        /// The exit status surfaced to the original outcome/DTO vocabulary:
        /// 128+signal for a signalled terminal (POSIX shell convention,
        /// documented), the real code otherwise, nil until terminal.
        public var reportedExit: Int32? {
            guard leaseReleased else { return nil }
            if let termSig, termSig > 0 { return 128 + termSig }
            return exitCode
        }
    }

    private struct SessionRecord {
        var engine: EngineSession
        /// Reconciliation start time when the local wait handed the lease
        /// over (EOF/timeout/fence); nil while a live waiter owns it.
        var reconcilingSince: Date?
    }

    private struct StdinOutcome: Sendable {
        var accepted: Int
        var errnoCode: Int32?
    }

    private let transport: any LinuxShellTransport
    private let readiness: any LinuxShellReadiness
    private let configuration: Configuration

    /// The single engine slot (mirrors the original process-wide gate).
    /// Holders are unique per dispatch so two same-token one-shot runs can
    /// never re-enter each other's gate.
    private var gateHolder: String?
    private var sessions: [String: SessionRecord] = [:]
    /// G07.1 terminal04: bounded client-visible phase composition of the MOST
    /// RECENT one-shot dispatch this backend measured (closed vocabulary +
    /// integers, ≤512 bytes). Diagnostic only; it never feeds admission, an
    /// outcome or a lease. Cleared at the start of every dispatch, so a run
    /// that fails BEFORE any phase was measured journals NO composition
    /// instead of a previous run's timing.
    private var lastRunPhaseReport: String?

    public init(
        transport: any LinuxShellTransport,
        readiness: any LinuxShellReadiness = UnqualifiedLinuxShellReadiness(),
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.readiness = readiness
        self.configuration = configuration
    }

    /// Bounded phase composition of the MOST RECENT one-shot run (client
    /// half: gate/start/stdin/run/settle). `nil` until a run was dispatched on
    /// this backend. Read-only diagnostics: it carries no command text, path,
    /// identifier or output, and reading it changes no state.
    public func lastRunPhaseDiagnostics() -> String? { lastRunPhaseReport }

    /// Trusted observation for the facade/Main reconciliation surface:
    /// leases whose real release has not been proven yet. Model code never
    /// calls this; it carries identifiers only, never command payloads.
    public func unreconciledSessions() -> [EngineSession] {
        sessions.values.compactMap { record in
            record.reconcilingSince != nil && !record.engine.leaseReleased
                ? record.engine : nil
        }
    }

    /// Includes active sessions as well as detached stop reconciliation.
    public func ownedSessions() -> [EngineSession] {
        sessions.values.map(\.engine).filter { !$0.leaseReleased }
    }

    public func ownedSessions(runID: UUID) -> [EngineSession] {
        ownedSessions().filter { $0.runID == runID }
    }

    public func isEngineSlotBusy() -> Bool { gateHolder != nil }

    /// Owner-scoped reconciliation view for the trusted facade ledger.
    public func unreconciledSessions(runID: UUID) -> [EngineSession] {
        unreconciledSessions().filter { $0.runID == runID }
    }

    // MARK: - LocalShellBackend: one-shot run

    public func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        await executeRun(request, cancellation: cancellation).0
    }

    /// G07.1 terminal04: the outcome and the phase composition of the SAME
    /// dispatch, returned together from ONE actor call. This is what the
    /// journal attributes; the `last` accessor below is only for a diagnostic
    /// UI read.
    public func runReportingPhases(_ request: ShellRunRequest,
                                   cancellation: CancellationToken?) async -> ShellRunReport {
        let (outcome, phases) = await executeRun(request, cancellation: cancellation)
        lastRunPhaseReport = phases
        return ShellRunReport(outcome: outcome, phaseTimings: phases)
    }

    private func executeRun(_ request: ShellRunRequest,
                            cancellation: CancellationToken?) async -> (ShellRunOutcome, String?) {
        // Fail-closed owner routing: the engine payload requires runID and
        // a canonical project root; nothing is guessed.
        guard let runID = request.runID else {
            return (.failed(message: "Linux shell requires an explicit run owner; no run context was supplied (fail closed)"), nil)
        }
        guard readiness.isQualifiedForLinuxShell else {
            return (.failed(message: readiness.refusalGuidance), nil)
        }
        guard request.command.utf8.count <= 16 * 1024, !request.command.contains("\0") else {
            return (.failed(message: "command exceeds the engine 16 KiB bound or contains NUL"), nil)
        }
        if let refusal = LinuxShellStartRequest.environmentRefusal(request.environment) {
            return (.failed(message: "Linux engine bounds rejected the requested env before dispatch: \(refusal)"), nil)
        }

        // Unique per-dispatch gate/record key so a concurrent same-token
        // one-shot can never share or steal the slot bookkeeping.
        let holdKey = "run:" + request.sessionID + ":" + UUID().uuidString.lowercased()
        let started = Date()
        // G07.1 terminal04: bounded client-visible phase composition for THIS
        // dispatch. Diagnostic only — every deadline/outcome/lease rule below
        // is unchanged; `started` (wall clock) keeps its ORIGINAL position
        // and its ORIGINAL meaning for `durationMs` and the local deadline.
        // The composition is returned WITH the outcome (never stored globally
        // for attribution), so a concurrent/denied dispatch can never be
        // journaled against another call's timing.
        var phases = TerminalLatencyPhases(originNanos: TerminalLatencyPhases.now())
        guard await acquireGate(heldBy: holdKey, timeout: request.gateTimeout, cancellation: cancellation) else {
            phases.mark(.gate, at: TerminalLatencyPhases.now())
            let cancelled = cancellation?.isCancelled == true || Task.isCancelled
            if cancelled { return (.cancelled, phases.render(terminal: .cancelled)) }
            // The engine slot is still owned (or being reconciled): nothing
            // of this command ran. Distinct from a timeout, exactly as the
            // original contract documents.
            return (.notStarted(reason: "the single runtime-UID Linux workload slot is occupied (another command or session still holds the engine lease); nothing was started"),
                    phases.render(terminal: .notStarted))
        }
        phases.mark(.gate, at: TerminalLatencyPhases.now())

        let start = LinuxShellStartRequest(
            projectID: LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: request.rootURL),
            runID: runID,
            conversationID: request.conversationID,
            environmentID: request.toolEnvironment?.id,
            command: request.command,
            cwd: request.cwd,
            environment: request.environment,
            rows: 24,
            columns: 80,
            timeoutSeconds: request.timeout,
            hostToolCallID: request.toolCallID,
            // Trusted one-shot adapter ONLY: the engine re-describes this
            // job's stdin as a dedicated pipe (stdout/stderr stay on the
            // PTY slave) whose sole EOF is the descriptor close commanded
            // below. Interactive `openSession` never sets this.
            stdinDelivery: .pipe
        )
        let reply: LinuxShellStartReply
        do {
            reply = try await transport.shellStart(start)
        } catch {
            releaseGate(heldBy: holdKey)
            phases.mark(.start, at: TerminalLatencyPhases.now())
            return (.failed(message: describeTransportError(error)), phases.render(terminal: .failed))
        }
        phases.mark(.start, at: TerminalLatencyPhases.now())
        var engine = EngineSession(sessionKey: holdKey,
                                   engineSessionID: reply.sessionID,
                                   environmentID: reply.environmentID,
                                   runID: runID,
                                   conversationID: request.conversationID,
                                   cursor: 0, bytesRead: 0, bytesWritten: 0,
                                   state: .running, leaseReleased: false,
                                   cancelled: false, stopReason: nil,
                                   exitCode: nil, termSig: nil, stopRequested: false)
        sessions[holdKey] = SessionRecord(engine: engine, reconcilingSince: nil)

        // One-shot pipe stdin: explicit caller data rides <=16 KiB
        // shell.input pages first (accepted/partial cursor preserved by
        // writeInput), then EXACTLY ONE trailing EMPTY page commands the
        // real descriptor EOF — ALWAYS, including nil/empty stdin, which is
        // precisely the baseline hang defect. The old EOT (0x04) emulation
        // is deleted: on a pipe it is ordinary data, not EOF. EOF is not an
        // exit and never releases the lease: the poll loop below still
        // settles only on the engine's `leaseReleased` terminal proof.
        var stdinFailureNote: String?
        if let stdin = request.stdin, !stdin.isEmpty {
            let outcome = await writeInput(sessionKey: holdKey, data: Data(stdin.utf8),
                                           cancellation: cancellation)
            engine.bytesWritten += outcome.accepted
            sessions[holdKey] = SessionRecord(engine: engine, reconcilingSince: nil)
            if let code = outcome.errnoCode {
                stdinFailureNote = "stdin write incomplete after \(outcome.accepted) accepted bytes (engine/local code \(code))"
            }
        }
        if let eofNote = await sendStdinEof(sessionKey: holdKey) {
            stdinFailureNote = stdinFailureNote.map { "\($0); \(eofNote)" } ?? eofNote
        }
        phases.mark(.stdin, at: TerminalLatencyPhases.now())

        // Closes the diagnostic composition at the REAL return point and
        // returns it for THIS call's report. Diagnostic only: `durationMs`
        // below keeps its ORIGINAL `started` origin and meaning.
        func closePhases(_ terminal: TerminalLatencyPhases.Terminal) -> String {
            phases.mark(.settle, at: TerminalLatencyPhases.now())
            return phases.render(terminal: terminal)
        }

        var merged = Data()
        var truncated = false
        var gapSeen = false
        var cancelIntent = false
        var timeoutIntent = false
        var stopIssuedAt: Date?
        let deadline = started.addingTimeInterval(request.timeout)

        while true {
            if !cancelIntent, cancellation?.isCancelled == true || Task.isCancelled {
                cancelIntent = true
                engine.stopRequested = true
                stopIssuedAt = Date()
                sessions[holdKey] = SessionRecord(engine: engine, reconcilingSince: nil)
                _ = try? await transport.shellCancel(LinuxShellCancelRequest(sessionID: engine.engineSessionID))
            }
            if !timeoutIntent, !cancelIntent, Date() >= deadline {
                // The engine pump enforces its own deadline too; the local
                // stop request guarantees the request even if the pump is
                // between iterations. A stop is only a REQUEST here.
                timeoutIntent = true
                engine.stopRequested = true
                stopIssuedAt = Date()
                sessions[holdKey] = SessionRecord(engine: engine, reconcilingSince: nil)
                _ = try? await transport.shellCancel(LinuxShellCancelRequest(sessionID: engine.engineSessionID))
            }
            let ceiling = max(deadline, stopIssuedAt ?? deadline)
                .addingTimeInterval(configuration.releaseGrace)
            if Date() >= ceiling {
                // Bounded local wait: the remote lease may still be live.
                // Hand ownership to reconciliation instead of pretending.
                handoffReconciliation(holdKey)
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                phases.mark(.run, at: TerminalLatencyPhases.now())
                if cancelIntent { return (.cancelled, closePhases(.cancelled)) }
                if timeoutIntent {
                    return (.timedOut(partialStdout: String(decoding: merged, as: UTF8.self),
                                      partialStderr: stdinFailureNote.map { "[metadata] \($0)" } ?? "",
                                      durationMs: durationMs),
                            closePhases(.timedOut))
                }
                return (.failed(message: "engine lease retained: the stop/exit could not be proven within the bounded wait; the lease stays owned for reconciliation and nothing was replayed or assumed"),
                        closePhases(.failed))
            }
            let page: LinuxShellPollReply
            do {
                page = try await transport.shellPoll(
                    LinuxShellPollRequest(sessionID: engine.engineSessionID,
                                          cursor: engine.cursor,
                                          maxBytes: 16_384))
            } catch {
                // The wait broke but the engine lease may still be live:
                // retain ownership for reconciliation exactly like the
                // cancellation rules require.
                handoffReconciliation(holdKey)
                let message = describeTransportError(error)
                phases.mark(.run, at: TerminalLatencyPhases.now())
                if cancelIntent { return (.cancelled, closePhases(.cancelled)) }
                if timeoutIntent {
                    return (.timedOut(partialStdout: String(decoding: merged, as: UTF8.self),
                                      partialStderr: "",
                                      durationMs: Int(Date().timeIntervalSince(started) * 1000)),
                            closePhases(.timedOut))
                }
                return (.failed(message: message), closePhases(.failed))
            }
            let room = max(0, request.maxOutputBytes - merged.count)
            if page.mergedOutput.count > room {
                if room > 0 { merged.append(page.mergedOutput.prefix(room)) }
                truncated = true
            } else {
                merged.append(page.mergedOutput)
            }
            engine.cursor = page.cursor
            engine.bytesRead += page.mergedOutput.count
            if page.gapBytes > 0 || page.droppedBytes > 0 { gapSeen = true }
            engine.state = page.state
            engine.leaseReleased = page.leaseReleased
            engine.cancelled = page.cancelled
            engine.stopReason = page.stopReason ?? engine.stopReason
            engine.workspaceStatus = page.workspaceStatus ?? engine.workspaceStatus
            engine.workspaceRecoveryRef = page.workspaceRecoveryRef ?? engine.workspaceRecoveryRef
            engine.workspaceRecovery = page.workspaceRecovery ?? engine.workspaceRecovery
            engine.exitCode = page.exitCode ?? engine.exitCode
            engine.termSig = page.termSig ?? engine.termSig
            sessions[holdKey] = SessionRecord(engine: engine, reconcilingSince: nil)

            if page.leaseReleased {
                // Real terminal proven by the engine (whole-UID quiescence;
                // the runtime releases the lease exactly once after finish()).
                // G07.1 terminal04: the release wait ends HERE; its span
                // covers process execution plus the engine's own stop proof
                // and workspace export (both engine-owned, see
                // `unobserved` in the rendered diagnostics).
                phases.mark(.run, at: TerminalLatencyPhases.now())
                sessions.removeValue(forKey: holdKey)
                releaseGate(heldBy: holdKey)
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let mergedText = String(decoding: merged, as: UTF8.self)
                var metaErr = stdinFailureNote.map { "[metadata] \($0)" } ?? ""
                // The REAL digest-CAS success case: a normal completed turn
                // may STILL have preserved diverged prior bytes (the import
                // swapped them into the owner-marked journal, installed the
                // Core baseline, and the export then settled synced). The
                // SAME bounded evidence surfaces through the EXISTING
                // labelled backend-metadata stderr channel — ordinary
                // success stays success, no failure is fabricated, no reader
                // authority is added, and unobserved metadata stays absent.
                if page.workspaceStatus == "synced",
                   let evidence = page.workspaceRecovery, evidence.preservedUnsynced > 0,
                   let detail = evidence.evidenceText {
                    let note = "[recovery-evidence]\n" + detail
                    metaErr = metaErr.isEmpty ? note : metaErr + "\n" + note
                }
                if page.workspaceStatus != "synced" {
                    // Concise actionable state first; bounded technical
                    // evidence rides BELOW it as explicit tool-card detail
                    // (relative paths, digests, counters — no host paths).
                    // Absent/unobserved metadata changes NOTHING here.
                    let recovery = page.workspaceRecoveryRef.map { " Recovery: \($0)." } ?? ""
                    var message = "Workspace changes were not fully saved (\(page.workspaceStatus ?? "unknown"))." + recovery
                    if let evidence = page.workspaceRecovery, evidence.hasActionableEvidence {
                        if let summary = evidence.recoverableSummary { message += " " + summary }
                        if let detail = evidence.evidenceText { message += "\n" + detail }
                    }
                    return (.failed(message: message
                        + (mergedText.isEmpty ? "" : "\n" + mergedText)), closePhases(.failed))
                }
                if page.cancelled {
                    // Engine truth outranks the local intent: a cancelled
                    // remote is NOT an exited process. The stop reason is a
                    // fixed service code; unknown codes surface honestly.
                    switch page.stopReason {
                    case "timeout":
                        return (.timedOut(partialStdout: mergedText, partialStderr: metaErr,
                                          durationMs: durationMs), closePhases(.timedOut))
                    case "user-stop":
                        return (.cancelled, closePhases(.cancelled))
                    case "start-binding-failed":
                        return (.failed(message: "the engine could not bind the spawned process (stopReason=start-binding-failed); the stop itself is proven by the released lease"),
                                closePhases(.failed))
                    case .some(let code):
                        if cancelIntent { return (.cancelled, closePhases(.cancelled)) }
                        return (.failed(message: "engine cancelled terminal with unknown stopReason='\(code)'; no outcome was assumed"),
                                closePhases(.failed))
                    case nil:
                        // Defensive: cancelled without a reason code. Only a
                        // tracked local intent may classify it.
                        if timeoutIntent {
                            return (.timedOut(partialStdout: mergedText, partialStderr: metaErr,
                                              durationMs: durationMs), closePhases(.timedOut))
                        }
                        return (.cancelled, closePhases(.cancelled))
                    }
                }
                if let waitErrno = page.waitErrno, waitErrno != 0 {
                    // A waitpid error is never reported as a benign exit or
                    // "still running" (engine ExitResult contract).
                    return (.failed(message: "engine wait error waitErrno=\(waitErrno)"
                                    + (stdinFailureNote.map { "; \($0)" } ?? "")),
                            closePhases(.failed))
                }
                let code = engine.reportedExit ?? -1
                return (.exited(code: code,
                                stdout: mergedText,
                                stderr: metaErr,
                                truncated: truncated || gapSeen,
                                stderrTruncated: false,
                                durationMs: durationMs),
                        closePhases(.exited))
            }
            // G07.1 terminal04 confirmed redundant-wait repair: a page that
            // BOTH reports more buffered bytes at the engine AND delivered
            // bytes into our bounded buffer means the next page is ready NOW,
            // so the fixed inter-poll sleep only delays an already-available
            // bounded read. Skip it exactly then. Every other page — idle, or
            // a discarding poll where the caller's output cap is already
            // reached — keeps the ORIGINAL cadence, so no busy loop is
            // introduced. The deadline/cancellation checks at the top of every
            // iteration are unchanged: nothing about the timeout, lease, exit,
            // cancellation or export contract moves.
            let buffered = page.more && !page.mergedOutput.isEmpty && room > 0
            if !buffered {
                try? await Task.sleep(nanoseconds: configuration.pollIntervalNanos)
            }
        }
    }

    // MARK: - LocalShellBackend: interactive sessions

    public func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        guard let runID = request.runID else {
            throw FloeError.invalidConfiguration("Linux shell sessions require an explicit run owner (fail closed)")
        }
        guard readiness.isQualifiedForLinuxShell else {
            throw FloeError.invalidConfiguration(readiness.refusalGuidance)
        }
        guard request.command.utf8.count <= 16 * 1024, !request.command.contains("\0") else {
            throw FloeError.validationFailed("command exceeds the engine 16 KiB bound or contains NUL")
        }
        if let refusal = LinuxShellStartRequest.environmentRefusal(request.environment) {
            throw FloeError.validationFailed("Linux engine bounds rejected the requested env before dispatch: \(refusal)")
        }
        // `prepareLinuxIfMissing` is NOT a download trigger on Android:
        // installation is the Main-owned setup surface (engine install.*
        // ops + specialUse FGS), never a model-path side effect from
        // shell.open. Component selection/paths/leases stay engine-owned;
        // an unqualified engine refuses above.
        guard await acquireGate(heldBy: request.sessionID, timeout: request.gateTimeout,
                                cancellation: cancellation) else {
            try cancellation?.throwIfCancelled()
            throw FloeError.validationFailed("the single Linux workload slot is occupied; close the running session or wait for the command to finish")
        }
        let start = LinuxShellStartRequest(
            projectID: LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: request.rootURL),
            runID: runID,
            conversationID: request.conversationID,
            environmentID: request.toolEnvironment?.id,
            // Empty selects the engine's interactive shell (the original
            // contract's `sh` default, engine-side reality).
            command: request.command.isEmpty ? "exec /bin/sh" : request.command,
            cwd: request.cwd,
            environment: request.environment,
            rows: request.rows,
            columns: request.columns,
            timeoutSeconds: configuration.interactiveEngineDeadline,
            // G04-R2: the trusted UI operation lease identity (interactive
            // terminal / LSP opens mint their workspace grant against it).
            // nil for every other open — payload stays byte-for-byte.
            hostOperationID: request.workspaceOperationID?.uuidString,
            // stdinDelivery intentionally UNSET: an interactive session
            // rides the legacy PTY input path (engine default "pty"). The
            // wire key is omitted entirely (never null), so canonical
            // Ctrl-D/Ctrl-C semantics, exchange paging and R1/R2 session
            // contracts are byte-identical to before.
        )
        let reply: LinuxShellStartReply
        do {
            reply = try await transport.shellStart(start)
        } catch {
            releaseGate(heldBy: request.sessionID)
            throw mapBackendError(error)
        }
        var engine = EngineSession(sessionKey: request.sessionID,
                                   engineSessionID: reply.sessionID,
                                   environmentID: reply.environmentID,
                                   runID: runID,
                                   conversationID: request.conversationID,
                                   cursor: 0, bytesRead: 0, bytesWritten: 0,
                                   state: .running, leaseReleased: false,
                                   cancelled: false, stopReason: nil,
                                   exitCode: nil, termSig: nil, stopRequested: false)
        sessions[request.sessionID] = SessionRecord(engine: engine, reconcilingSince: nil)
        // Brief bounded initial drain so the first prompt/program output
        // reaches the caller (the original open() returned initial output).
        var initial = Data()
        let initialDeadline = Date().addingTimeInterval(0.75)
        while Date() < initialDeadline {
            do {
                let page = try await transport.shellPoll(
                    LinuxShellPollRequest(sessionID: engine.engineSessionID,
                                          cursor: engine.cursor, maxBytes: 16_384))
                initial.append(page.mergedOutput)
                engine.cursor = page.cursor
                engine.bytesRead += page.mergedOutput.count
                engine.state = page.state
                engine.leaseReleased = page.leaseReleased
                engine.cancelled = page.cancelled
                engine.stopReason = page.stopReason ?? engine.stopReason
            engine.workspaceStatus = page.workspaceStatus ?? engine.workspaceStatus
            engine.workspaceRecoveryRef = page.workspaceRecoveryRef ?? engine.workspaceRecoveryRef
                engine.workspaceRecovery = page.workspaceRecovery ?? engine.workspaceRecovery
                engine.exitCode = page.exitCode ?? engine.exitCode
                engine.termSig = page.termSig ?? engine.termSig
                sessions[request.sessionID] = SessionRecord(engine: engine, reconcilingSince: nil)
                if page.leaseReleased || (!initial.isEmpty && !page.more) { break }
            } catch {
                // Initial drain failure must not lose a live lease.
                handoffReconciliation(request.sessionID)
                throw mapBackendError(error)
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        if engine.leaseReleased {
            // The program died immediately: tear the slot down here; the
            // center treats a non-alive open as its own close path.
            sessions.removeValue(forKey: request.sessionID)
            releaseGate(heldBy: request.sessionID)
        }
        let text = String(decoding: initial, as: UTF8.self)
        return ShellOpenResult(
            sessionID: request.sessionID,
            initialOutput: text,
            alive: !engine.leaseReleased,
            terminalOutput: initial.isEmpty ? nil : initial
        )
    }

    public func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        guard var record = sessions[request.sessionID] else {
            throw FloeError.notFound("Unknown or expired shell session \(request.sessionID)")
        }
        var engine = record.engine
        if cancellation?.isCancelled == true || Task.isCancelled {
            throw CancellationError()
        }
        var written = 0
        var writeErrno: Int32?
        if let input = request.input, !input.isEmpty {
            let outcome = await writeInput(sessionKey: request.sessionID,
                                           data: Data(input.utf8),
                                           cancellation: cancellation)
            written = outcome.accepted
            writeErrno = outcome.errnoCode
            engine.bytesWritten += written
            record.engine = engine
            sessions[request.sessionID] = record
        }
        // Collect output within the caller's bounded wait window.
        var collected = Data()
        let waitMs = max(50, min(request.waitMs, 30_000))
        let deadline = Date().addingTimeInterval(TimeInterval(waitMs) / 1000.0)
        var gapSeen = false
        var droppedSeen = false
        while true {
            if cancellation?.isCancelled == true || Task.isCancelled {
                record.engine = engine
                sessions[request.sessionID] = record
                throw CancellationError()
            }
            let remaining = max(1, request.maxBytes - collected.count)
            let page: LinuxShellPollReply
            do {
                page = try await transport.shellPoll(
                    LinuxShellPollRequest(sessionID: engine.engineSessionID,
                                          cursor: engine.cursor,
                                          maxBytes: min(16_384, remaining)))
            } catch {
                handoffReconciliation(request.sessionID)
                throw mapBackendError(error)
            }
            collected.append(page.mergedOutput)
            engine.cursor = page.cursor
            engine.bytesRead += page.mergedOutput.count
            engine.state = page.state
            engine.leaseReleased = page.leaseReleased
            engine.cancelled = page.cancelled
            engine.stopReason = page.stopReason ?? engine.stopReason
            engine.workspaceStatus = page.workspaceStatus ?? engine.workspaceStatus
            engine.workspaceRecoveryRef = page.workspaceRecoveryRef ?? engine.workspaceRecoveryRef
            engine.workspaceRecovery = page.workspaceRecovery ?? engine.workspaceRecovery
            engine.exitCode = page.exitCode ?? engine.exitCode
            engine.termSig = page.termSig ?? engine.termSig
            if page.gapBytes > 0 { gapSeen = true }
            if page.droppedBytes > 0 { droppedSeen = true }
            record.engine = engine
            sessions[request.sessionID] = record
            if page.leaseReleased || !page.more || !collected.isEmpty || Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: min(100_000_000, configuration.pollIntervalNanos))
        }
        if engine.leaseReleased {
            // The session truly ended: release the gate. exitCode only ever
            // comes from the engine's real terminal fields (EOF != exit).
            sessions.removeValue(forKey: request.sessionID)
            releaseGate(heldBy: request.sessionID)
        }
        var failureParts: [String] = []
        if engine.leaseReleased, engine.workspaceStatus != "synced" {
            let recovery = engine.workspaceRecoveryRef.map { " recovery=\($0)" } ?? ""
            failureParts.append("workspace-not-saved status=\(engine.workspaceStatus ?? "unknown")" + recovery)
        }
        if engine.leaseReleased, engine.cancelled {
            // Honest metadata: a stopped remote is NOT an exited process.
            failureParts.append("engine-stopped reason=\(engine.stopReason ?? "unknown")")
        }
        if let code = writeErrno { failureParts.append("stdin-write-incomplete code=\(code) acceptedBytes=\(written)") }
        if gapSeen || droppedSeen {
            failureParts.append("output-window-overflow (unread bytes were ring-dropped; the cursor kept advancing)")
        }
        // Bounded per-execution recovery evidence trails as the explicitly-
        // opened tool-detail block (nil metadata keeps this byte-identical
        // to before; the first lines above stay unchanged).
        if engine.leaseReleased, engine.workspaceStatus != "synced",
           let evidence = engine.workspaceRecovery, evidence.hasActionableEvidence,
           let detail = evidence.evidenceText {
            failureParts.append("recovery-evidence\n" + detail)
        }
        let failure = failureParts.isEmpty ? nil : failureParts.joined(separator: "; ")
        return ShellExchangeResult(
            output: String(decoding: collected, as: UTF8.self),
            alive: !engine.leaseReleased,
            exitCode: engine.reportedExit,
            cancelled: engine.cancelled,
            terminalOutput: collected.isEmpty ? nil : collected,
            failure: failure,
            bytesRead: engine.bytesRead,
            bytesWritten: engine.bytesWritten,
            // The engine publishes this ONLY with a released terminal, after
            // its whole-UID stop proof and workspace export. Never synthesize
            // a receipt for a still-live page.
            workspaceStatus: engine.leaseReleased ? engine.workspaceStatus : nil
        )
    }

    public func closeSession(sessionID: String) async {
        guard let record = sessions[sessionID] else { return }
        guard !record.engine.leaseReleased else {
            _ = sessions.removeValue(forKey: sessionID)  // already truly gone
            releaseGate(heldBy: sessionID)
            return
        }
        // Engine stop is a REQUEST; ownership stays until the release proof.
        var engine = record.engine
        engine.stopRequested = true
        sessions[sessionID] = SessionRecord(engine: engine, reconcilingSince: Date())
        do {
            _ = try await transport.shellCancel(LinuxShellCancelRequest(sessionID: engine.engineSessionID))
        } catch {
            // Fenced/failed transport: retain for reconciliation; never
            // invent a release.
        }
        scheduleReconciliation(sessionKey: sessionID, engineSessionID: engine.engineSessionID)
    }

    public func signalSession(sessionID: String, signal: ShellSignal) async {
        guard let record = sessions[sessionID], !record.engine.leaseReleased else { return }
        switch signal {
        case .interrupt:
            // Real PTY Ctrl-C: the engine PTY's line discipline raises
            // SIGINT for the foreground process group.
            _ = await writeInput(sessionKey: sessionID, data: Data([0x03]), cancellation: nil)
        case .terminate, .kill:
            // The engine exposes exactly ONE owned stop (transport stop +
            // whole-UID census proof); TERM and KILL both map to it. A stop
            // request is not a proven stop: ownership stays until release.
            var engine = record.engine
            engine.stopRequested = true
            sessions[sessionID] = SessionRecord(engine: engine, reconcilingSince: Date())
            do {
                _ = try await transport.shellCancel(LinuxShellCancelRequest(sessionID: engine.engineSessionID))
            } catch {
                // keep ownership for reconciliation
            }
            scheduleReconciliation(sessionKey: sessionID, engineSessionID: engine.engineSessionID)
        }
    }

    /// Requests the SAME one owned engine stop as `.terminate` while the
    /// caller keeps observing THIS session entry. The terminal (and the
    /// runtime workspace export receipt that rides only on its released page)
    /// is delivered through the caller's `exchangeSession`; NO detached
    /// reconciliation consumes or drops it first. A transport failure keeps
    /// the entry owned for the caller's own fault/retirement reconciliation
    /// (`closeSession` still schedules one when that ownership is handed back).
    public func requestStopForSettlement(sessionID: String) async {
        guard let record = sessions[sessionID], !record.engine.leaseReleased else { return }
        var engine = record.engine
        engine.stopRequested = true
        sessions[sessionID] = SessionRecord(engine: engine, reconcilingSince: Date())
        do {
            _ = try await transport.shellCancel(LinuxShellCancelRequest(sessionID: engine.engineSessionID))
        } catch {
            // Keep ownership; the caller's exchange/retirement reconciles.
        }
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard let record = sessions[sessionID], !record.engine.leaseReleased else { return }
        _ = try? await transport.shellResize(
            LinuxShellResizeRequest(sessionID: record.engine.engineSessionID,
                                    rows: rows, columns: columns))
    }

    // MARK: - Internals

    /// Writes DATA bytes in engine-bounded base64 pages with bounded
    /// backpressure retries. Returns honestly how many bytes were ACCEPTED;
    /// a failed write surfaces the engine errno instead of pretending
    /// success. Local codes: -2 backpressure ceiling, -3 transport failure,
    /// -4 no-progress data reply, -1 unknown session key (nothing was
    /// written).
    /// Engine reply vocabulary (applied SupervisedPtyJob/LinuxRuntime
    /// Operations pump + stdin-eof-patch CONTRACT): `acceptedBytes` is the
    /// progress cursor and `errno` rides on `partial` replies too. EAGAIN
    /// (11) means "no room right now" after the engine's OWN bounded retry
    /// budget: the caller must re-send only the remainder from the cursor
    /// under this loop's own budget — never duplicating, never silently
    /// dropping the tail. Any other non-zero errno (EPIPE 32, EBADF 9, …)
    /// is an honest terminal failure with accepted bytes kept accounted.
    /// This loop is for stdin DATA only: the one-shot EOF command routes
    /// through `sendStdinEof`, because its `acceptedBytes == 0 && !partial`
    /// no-progress guard exists for data pages and would misfire on the
    /// EOF page (whose reply legitimately accepts zero bytes).
    private func writeInput(sessionKey: String, data: Data,
                            cancellation: CancellationToken?) async -> StdinOutcome {
        guard let engine = sessions[sessionKey]?.engine else {
            return StdinOutcome(accepted: 0, errnoCode: -1)
        }
        var sent = 0
        var retries = 0
        while sent < data.count {
            if cancellation?.isCancelled == true || Task.isCancelled {
                return StdinOutcome(accepted: sent, errnoCode: nil)
            }
            let chunk = data.subdata(in: sent..<min(sent + 16_384, data.count))
            var chunkPos = 0
            while chunkPos < chunk.count {
                let request = LinuxShellInputRequest(
                    sessionID: engine.engineSessionID,
                    bytes: chunk.subdata(in: chunkPos..<chunk.count))
                do {
                    let reply = try await transport.shellInput(request)
                    chunkPos += reply.acceptedBytes
                    sent += reply.acceptedBytes
                    if let code = reply.errnoCode, code != 0, code != 11 {
                        // EPIPE/EBADF/etc: honest terminal failure; the
                        // accepted cursor stays reported so the note counts
                        // real bytes. EAGAIN (11) is NOT terminal here — it
                        // is the engine's "retry the remainder later" cursor.
                        return StdinOutcome(accepted: sent, errnoCode: code)
                    }
                    if reply.acceptedBytes == 0 && !reply.partial && reply.errnoCode != 11 {
                        return StdinOutcome(accepted: sent, errnoCode: -4)  // no-progress guard
                    }
                    if reply.partial || reply.errnoCode == 11 {
                        retries += 1
                        if retries > configuration.stdinWriteRetries {
                            return StdinOutcome(accepted: sent, errnoCode: -2)
                        }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    } else {
                        retries = 0
                    }
                } catch {
                    return StdinOutcome(accepted: sent, errnoCode: -3)
                }
            }
        }
        return StdinOutcome(accepted: sent, errnoCode: nil)
    }

    /// Commands the one-shot pipe descriptor EOF: exactly ONE EMPTY
    /// `shell.input` page (zero bytes are the intentional EOF command,
    /// never stdin data). Deliberately bypasses `writeInput`'s paging loop.
    /// Returns nil only when the engine CONFIRMED the close
    /// (`closed`/`closed-idempotent`); every other answer yields an honest
    /// note — never an invented delivery success. The command never waits
    /// for output, never releases the lease and never substitutes an exit:
    /// a command that already terminated is reported as rejected by the
    /// engine (its lifecycle owns the write end), and the real terminal
    /// evidence still settles through the poll loop's `leaseReleased` proof.
    private func sendStdinEof(sessionKey: String) async -> String? {
        guard let engine = sessions[sessionKey]?.engine else {
            return "stdin EOF not sent (session record is gone; nothing was closed)"
        }
        do {
            let reply = try await transport.shellInput(
                LinuxShellInputRequest(sessionID: engine.engineSessionID,
                                       bytes: Data()))
            switch reply.stdinEof {
            case "closed", "closed-idempotent":
                return nil
            case "failed":
                let errnoText = reply.errnoCode.map { " errno=\($0)" } ?? ""
                return "stdin EOF close failed at the engine\(errnoText)"
            case "rejected":
                // Not RUNNING (the command already exited or a stop owns
                // it) or not a pipe session: the engine lifecycle closes
                // the write end, and that close is never re-labelled as a
                // delivered EOF command. The outcome below stays honest.
                let reason = reply.stdinEofReason ?? reply.errnoCode.map { "errno=\($0)" }
                let reasonText = reason.map { " reason=\($0)" } ?? ""
                return "stdin EOF was not accepted as a command (engine rejected\(reasonText)); the lifecycle owns the descriptor"
            case .some(let raw):
                return "stdin EOF reply unknown (stdinEof='\(raw)'); no delivery was assumed"
            case nil:
                return "stdin EOF unconfirmed (reply carried no stdinEof state); no delivery was assumed"
            }
        } catch {
            return "stdin EOF request failed (\(describeTransportError(error)))"
        }
    }

    /// Bounded wait for the single engine slot (mirrors the original
    /// process-wide run gate semantics exactly).
    private func acquireGate(heldBy key: String, timeout: TimeInterval,
                             cancellation: CancellationToken?) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if gateHolder == nil {
                gateHolder = key
                return true
            }
            if cancellation?.isCancelled == true || Task.isCancelled || Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: configuration.pollIntervalNanos)
        }
    }

    private func releaseGate(heldBy key: String) {
        if gateHolder == key { gateHolder = nil }
    }

    private func handoffReconciliation(_ sessionKey: String) {
        guard var record = sessions[sessionKey] else { return }
        record.reconcilingSince = record.reconcilingSince ?? Date()
        sessions[sessionKey] = record
        scheduleReconciliation(sessionKey: sessionKey,
                               engineSessionID: record.engine.engineSessionID)
    }

    /// Retains ownership: keeps polling ONLY for the release proof and
    /// frees the gate exactly when the engine says `leaseReleased`. Never
    /// frees capacity by timer, never assumes a stop.
    private func scheduleReconciliation(sessionKey: String, engineSessionID: String) {
        let cursor = sessions[sessionKey]?.engine.cursor ?? 0
        Task { [self, transport, configuration] in
            let started = Date()
            var lastCursor = cursor
            while true {
                do {
                    let page = try await transport.shellPoll(
                        LinuxShellPollRequest(sessionID: engineSessionID,
                                              cursor: lastCursor, maxBytes: 1))
                    lastCursor = page.cursor
                    await markReconciled(sessionKey: sessionKey,
                                         released: page.leaseReleased,
                                         state: page.state,
                                         exitCode: page.exitCode,
                                         termSig: page.termSig,
                                         cancelled: page.cancelled,
                                         stopReason: page.stopReason,
                                         cursor: page.cursor)
                    if page.leaseReleased { return }
                } catch {
                    // Fenced/unknown: keep the entry observable and free the
                    // LOCAL slot only for a generation fence (below); this
                    // retry loop stops and the facade/Main census owns the
                    // long tail.
                    await markReconciledFenced(sessionKey: sessionKey)
                    return
                }
                if Date().timeIntervalSince(started) > configuration.reconcileObservation { return }
                try? await Task.sleep(nanoseconds: configuration.reconcileIntervalNanos)
            }
        }
    }

    private func markReconciled(sessionKey: String, released: Bool,
                                state: LinuxShellSessionState,
                                exitCode: Int32?, termSig: Int32?,
                                cancelled: Bool, stopReason: String?,
                                cursor: UInt64) {
        guard var record = sessions[sessionKey] else { return }
        record.engine.state = state
        record.engine.leaseReleased = released
        record.engine.cursor = cursor
        record.engine.cancelled = cancelled
        record.engine.stopReason = stopReason ?? record.engine.stopReason
        record.engine.exitCode = exitCode ?? record.engine.exitCode
        record.engine.termSig = termSig ?? record.engine.termSig
        if released {
            sessions.removeValue(forKey: sessionKey)
            releaseGate(heldBy: sessionKey)
        } else {
            sessions[sessionKey] = record
        }
    }

    private func markReconciledFenced(sessionKey: String) {
        // The transport generation died: keep the session entry visible to
        // `unreconciledSessions()` but free the local slot — a NEW runtime
        // generation re-proves quiescence before admitting anything
        // (`recoverBeforeAdmission` in the engine), so a stale local gate
        // must never block a fresh generation.
        guard var record = sessions[sessionKey] else { return }
        record.reconcilingSince = record.reconcilingSince ?? Date()
        sessions[sessionKey] = record
        releaseGate(heldBy: sessionKey)
    }

    private func describeTransportError(_ error: Error) -> String {
        switch error {
        case LinuxShellTransportError.notBound:
            return "the runtime engine transport is not bound (open the runtime setup; nothing was executed and no host fallback was used)"
        case LinuxShellTransportError.saturated:
            return "the engine request mailbox is saturated (backpressure; nothing was queued for this call)"
        case LinuxShellTransportError.payloadTooLarge:
            return "the request exceeded the frozen 64 KiB engine wire bound"
        case LinuxShellTransportError.remoteFailed(let code):
            return "engine reported the request failed (code=\(code))"
        case LinuxShellTransportError.remoteFailedWithRestore(let code, let restore):
            // G03-R3 failed-start receipt handoff (job-150dee8e1ed14ba1):
            // the SAME concise first line the legacy failure shows, then the
            // bounded technical evidence in the explicitly-opened tool
            // failure detail — the ORIGINAL import transaction's own
            // measured reverse-restore counters, re-bound to this exact
            // session/run by the trusted host pump before it settled the
            // claim. Relative identities and counts only: no paths, no
            // content, no args, no raw errors. Absent evidence NEVER lands
            // here (the legacy case above stays byte-identical).
            return "engine reported the request failed (code=\(code))\n" + restore.evidenceText
        case LinuxShellTransportError.replyMalformed:
            return "the engine reply frame could not be decoded; no outcome was assumed"
        case LinuxShellTransportError.hostFenced:
            return "the runtime generation was fenced (disconnect/stop); work is not replayed and leases stay unreconciled"
        case LinuxShellTransportError.waitBudgetExpired:
            return "the bounded local wait expired before settlement; the engine request may still be live — ownership stays under reconciliation and nothing was assumed"
        default:
            return "engine transport error: \(String(describing: type(of: error)))"
        }
    }

    private func mapBackendError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let floe = error as? FloeError { return floe }
        return FloeError.invalidConfiguration(describeTransportError(error))
    }
}

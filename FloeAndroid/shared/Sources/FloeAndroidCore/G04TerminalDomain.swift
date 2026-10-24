// SPDX-License-Identifier: MPL-2.0
//
// G04TerminalDomain — the REAL embedded terminal ownership domain for
// Android (job-dda32d23d55e4460, decision D3). This is the Android mirror of
// the ORIGINAL app-lifetime terminal owner semantics
// (FloeApp/Terminal/LocalTerminalView.swift @ 3fd597b5: LocalTerminalStore /
// LocalTerminalOwner / TerminalPollCadence), rebuilt over the ORIGINAL
// Android execution authority, NOT over a new runtime:
//
//  * Execution/session/environment/workspace authority remains the existing
//    services: `RuntimeFacadeLinuxBindings.shared.components.sessions`
//    (ShellSessionCenter) -> `AndroidLinuxShellBackend` ->
//    `MailboxLinuxShellTransport` -> `LinuxShellMailbox` -> the trusted
//    Kotlin engine pump -> the runtime-UID Linux engine. Nothing here owns
//    a process, mints an epoch, installs a package, or shells out locally.
//  * Session identity is the SAME native-issued UI identity the original
//    iOS local terminal uses (`LocalTerminalOwner.id` passed as `runID`
//    with `forTerminal: true`): a trusted interaction/session identity,
//    NEVER a fabricated model Run. No fake model run is inserted anywhere,
//    and `BridgeV3.taskExecution` scope is never required or invented for
//    an idle UI terminal.
//  * Conversation authority: every open attaches the ACTUAL ORIGINAL
//    conversation `.conversation` owned-work receipt through
//    `FacadeRunDomain.beginG04WorkspaceOperation` BEFORE the engine awaits,
//    keeps it attached until the real session/IO settlement, and the
//    ORIGINAL deletion fence / retirement cancel the receipt (which the
//    pump observes and drives through the original close/reconciliation
//    path — a cancelled lease is a REQUEST, never a proven stop).
//  * Durable admission: the conversation must exist in the installed
//    cluster store with `purpose == .ordinary` (temporary chat has no
//    persisted row and is barred by construction), the workspace binding
//    must match the ORIGINAL persisted `PrivateTasks/<uuid>` shape through
//    `LinuxWorkspaceAuthority.resolveWorkspace(conversationID:)`, and the
//    environment resolves through the ORIGINAL registry path with the real
//    workspace root. No first-project or temp-directory fallback exists
//    here.
//  * Sessions SURVIVE view reconstruction: only an explicit close, task
//    deletion, Root retirement or engine-proven exit tears a session down.
//    Pump tasks are owned by this store, never by a view.
//  * Raw PTY bytes are forwarded unsanitized through the bounded host
//    output channel (`terminalOutput`), exactly like the iOS owner feeds
//    SwiftTerm. The sanitized model `output` string is never presented as
//    terminal truth. Ctrl-C is an ETX byte riding the ordered input stream
//    (the PTY line discipline raises SIGINT for the foreground group and
//    the shell survives), the explicit signal path is reserved for
//    session-terminate intent — both copied from the original semantics.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

// MARK: - Limits

public enum G04TerminalLimits {
    /// One interactive terminal per exact conversation (the iOS owner store
    /// is one per workspace; a second interactive pane per task would just
    /// fight the single engine slot). A `.run` session may coexist while an
    /// interactive session exists only when the engine slot is free — the
    /// backend gate refuses the second open honestly (`.notStarted`/policy
    /// refusal), never a fake queue.
    public static let maximumSessionsPerConversation = 1
    /// Global live UI (terminal + run) sessions owned by this domain.
    public static let maximumLiveSessions = 4
    /// Bounded per-session raw output ring handed to the host between
    /// claims (matches the iOS owner's 256 KiB presentation bound). When
    /// the UI lags, the OLDEST unconsumed chunks roll over and the typed
    /// status event carries the cumulative rolled-over byte count — never a
    /// silent loss.
    public static let maximumRingBytes = 256 * 1024
    /// Cap on live queued chunks per session (ring-full accounting).
    public static let maximumQueuedChunks = 32
    /// Bounded input queue per session (the iOS owner's paste guard).
    public static let maximumPendingInputBytes = 64 * 1024
    /// Per-write exchange input cap (the engine stdin page reality; the
    /// backend pages larger data, the owner chunks at the same bound).
    public static let inputWriteBytes = 64 * 1024
    /// Bounded exchange window mirroring the iOS local terminal loop.
    public static let exchangeWaitMillis = 50
    /// One open attempt's total budget before a typed fault is surfaced
    /// (the engine start budget is shorter; this is the outer guard).
    public static let openBudgetSeconds: Double = 150
    /// Re-check pacing when the pump is otherwise idle (mirrors the iOS
    /// owner's busyDelay of 20 ms).
    public static let busyDelayNanos: UInt64 = 20_000_000
    /// Session lifetime ceiling for an untouched interactive terminal.
    /// The center's sliding expiry (30 min) stays authoritative; this is
    /// only the observable-activity watchdog that reports it honestly.
    public static let idleRecheckNanos: UInt64 = 50_000_000
}

// MARK: - Typed phase

/// The closed terminal status vocabulary surfaced to the trusted host and
/// the App pane. `exited`/`stopped` are ONLY ever produced from engine
/// truth (`leaseReleased` terminal fields); a local timeout is `waiting`
/// plus honest detail, never a fake exit.
public enum G04TerminalPhase: String, Sendable, Equatable {
    case closed
    case starting
    case running
    case waitingOutput      // alive, program has written nothing yet
    case exited             // real exit proven by the engine terminal
    case stopped            // proven stop (cancelled terminal, reason rides)
    case fault              // typed transport/backend refusal
}

public enum G04TerminalSessionPurpose: Sendable, Equatable {
    case interactive
    case run(runID: String, display: String)
}

// MARK: - Poll cadence (port of the ORIGINAL TerminalPollCadence)

/// Cadence for the terminal pump loop. One exchange already blocks up to
/// its `waitMs` engine-side, so the loop only adds pacing when the guest is
/// quiet: no delay at all while input was sent or output arrived (echo and
/// sustained output then drain at transport speed), and a short bounded
/// backoff while idle. Byte-for-byte the ORIGINAL iOS
/// `TerminalPollCadence` semantics (LocalTerminalView.swift @ 3fd597b5).
public struct G04TerminalPollCadence: Sendable {
    public private(set) var idleRounds = 0
    public private(set) var inactiveRounds = 0

    public init() {}

    /// Delay after one completed exchange.
    public mutating func delayAfterExchange(sentInput: Bool, bytesRead: Int) -> UInt64 {
        if sentInput || bytesRead > 0 {
            idleRounds = 0
            return 0
        }
        idleRounds += 1
        return UInt64(min(10 * idleRounds, 100)) * 1_000_000
    }

    /// Delay while the guest is not live.
    public mutating func delayWhileInactive(opening: Bool, exchangeInFlight: Bool) -> UInt64 {
        if opening || exchangeInFlight {
            inactiveRounds = 0
            return busyDelay
        }
        inactiveRounds += 1
        return UInt64(min(20 * inactiveRounds, 150)) * 1_000_000
    }

    public mutating func noteLive() { inactiveRounds = 0 }

    public var busyDelay: UInt64 { 20_000_000 }
}

// MARK: - Event sink (implemented by the host mailbox)

/// The bounded egress the store/server use to reach the trusted Kotlin
/// host. Control events are JSON objects; raw PTY bytes ride the separate
/// output channel. No implementation may block the caller: a full ring
/// rolls over the oldest chunk and counts it (typed, never silent).
public protocol G04TerminalEventSink: Sendable {
    func emitControl(_ object: [String: Any])
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data)
}

// MARK: - Session record

private final class TerminalSessionRecord: @unchecked Sendable {
    let sessionToken: String          // == center sessionID (lowercased UUID)
    let ownerRunID: UUID              // native-issued UI identity (NEVER a model run)
    let conversationID: UUID
    let workspaceID: UUID
    let purpose: G04TerminalSessionPurpose
    let requestID: String
    let cancellation: CancellationToken
    let receipt: G04WorkspaceOwnedOperation

    // Mutated only under the store actor's isolation (this class is a plain
    // box held by the actor; @unchecked Sendable is sound because access is
    // actor-serialized).
    var alive: Bool = true
    var phase: G04TerminalPhase = .starting
    var seq: Int64 = 0
    var ring: [(seq: Int64, bytes: Data)] = []
    var ringBytes = 0
    var rolledOverBytes = 0
    var pendingInput = Data()
    var columns = 80
    var rows = 24
    var exitCode: Int32?
    var stopReason: String?
    var faultCode: String?
    var lastRunToolchain: String?

    init(sessionToken: String, ownerRunID: UUID, conversationID: UUID, workspaceID: UUID,
         purpose: G04TerminalSessionPurpose, requestID: String,
         cancellation: CancellationToken, receipt: G04WorkspaceOwnedOperation) {
        self.sessionToken = sessionToken; self.ownerRunID = ownerRunID
        self.conversationID = conversationID; self.workspaceID = workspaceID
        self.purpose = purpose; self.requestID = requestID
        self.cancellation = cancellation; self.receipt = receipt
    }
}

// MARK: - Refusal codes

public enum G04TerminalCode: String, Sendable, Equatable {
    case retired
    case ownerChanged
    case purposeNotOrdinary
    case workspaceUnbound
    case engineUnqualified
    case saturated
    case sessionUnknown
    case sessionOwnerMismatch
    case tooLarge
    case notStarted
    case backendFailed
    case toolchainMissing
}

// MARK: - The store

public actor G04TerminalStore {
    public let epoch: UInt64
    private let sink: any G04TerminalEventSink
    private var sessions: [String: TerminalSessionRecord] = [:]
    private var byConversation: [UUID: [String]] = [:]
    private var pumpTasks: [String: Task<Void, Never>] = [:]
    private var retired = false

    public init(epoch: UInt64, sink: any G04TerminalEventSink) {
        self.epoch = epoch
        self.sink = sink
    }

    // MARK: Durable admission (ORIGINAL stores; fail closed)

    /// Validates the conversation/workspace pair through the SAME original
    /// authorities before any engine touch, and returns the trusted root.
    private func admit(conversationID: UUID, expectedWorkspaceID: UUID?) async
        -> (workspaceID: UUID, rootURL: URL)? {
        guard !retired, G02NativeRootEpoch.readback() == epoch,
              let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return nil }
        guard let conversation = try? await installed.cluster.conversationStore
            .conversation(id: conversationID), conversation.purpose == .ordinary else { return nil }
        guard let binding = await LinuxWorkspaceAuthority.resolveWorkspace(conversationID: conversationID)
        else { return nil }
        if let expectedWorkspaceID, expectedWorkspaceID != binding.workspaceID { return nil }
        return (binding.workspaceID, binding.rootURL)
    }

    private var components: LinuxShellComponents? { RuntimeFacadeLinuxBindings.shared.components }

    private func status(_ record: TerminalSessionRecord, extra: [String: Any] = [:]) {
        var object: [String: Any] = [
            "type": "terminalStatus",
            "sessionToken": record.sessionToken,
            "conversationID": record.conversationID.uuidString,
            "workspaceID": record.workspaceID.uuidString,
            "phase": record.phase.rawValue,
            "purpose": record.purpose.purposeTag,
            "runID": record.purpose.runTag ?? "",
            "requestID": record.requestID,
            "rolledOverBytes": record.rolledOverBytes,
        ]
        if let exitCode = record.exitCode { object["exitCode"] = Int(exitCode) }
        if let stopReason = record.stopReason { object["stopReason"] = stopReason }
        if let faultCode = record.faultCode { object["faultCode"] = faultCode }
        for (key, value) in extra { object[key] = value }
        sink.emitControl(object)
    }

    /// Phase changes are reported once per transition (streaming layout
    /// stability); identical repeats never re-emit.
    private func updatePhase(_ record: TerminalSessionRecord, _ phase: G04TerminalPhase) {
        guard record.phase != phase else { return }
        record.phase = phase
        status(record)
    }

    // MARK: Run (language run policy over the ORIGINAL session path)

    /// Executes the CURRENTLY SAVED draft through the ORIGINAL
    /// exec.session/shell machinery, exactly like the iOS Run button ran the
    /// saved snapshot: the draft must be clean (saved) or the call refuses
    /// with `unsavedDraft` — the renderer NEVER smuggles RAM bytes past the
    /// native save CAS. The plan comes from `G04LanguageRunPolicy` (a closed
    /// table ported from the ORIGINAL IDELanguageRunPolicy); the argv is
    /// element-by-element quoted, and the guest toolchain probe is the SAME
    /// `command -v` pattern the original required of its remote plan.
    func runDraft(conversationID: UUID, workspaceID expectedWorkspaceID: UUID?,
                  relativePath: String, languageID: String, requestID: String) async {
        guard !retired, G02NativeRootEpoch.readback() == epoch else {
            reply(requestID, ok: false, code: .retired); return
        }
        guard let (workspaceID, _) = await admit(conversationID: conversationID,
                                                 expectedWorkspaceID: expectedWorkspaceID) else {
            reply(requestID, ok: false, code: .workspaceUnbound); return
        }
        // Saved-only rule, checked against the ORIGINAL document authority.
        let authority = G04TerminalRuntimeRegistry.shared.authority(epoch: epoch)
        if let authority {
            let tabs = try? await authority.tabs(taskID: conversationID, workspaceID: workspaceID)
            if let matching = tabs?.first(where: { $0.relativePath == relativePath }), matching.dirty {
                reply(requestID, ok: false, code: .backendFailed, reason: "unsavedDraft")
                return
            }
        }
        let command: String
        do {
            command = try G04LanguageRunPolicy.startCommand(languageID: languageID, relativePath: relativePath)
        } catch let failure as G04LanguageRunPolicy.Failure {
            switch failure {
            case .unsupportedLanguage: reply(requestID, ok: false, code: .backendFailed, reason: "unsupportedLanguage")
            case .invalidPath: reply(requestID, ok: false, code: .backendFailed, reason: "invalidPath")
            }
            return
        }
        guard let components, RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else {
            reply(requestID, ok: false, code: .engineUnqualified); return
        }
        if await components.backend.isEngineSlotBusy() {
            // The single engine slot is occupied: nothing was started, and
            // no queue is fabricated (ORIGINAL .notStarted semantics).
            reply(requestID, ok: false, code: .notStarted, reason: "engineSlotBusy")
            return
        }
        let runIdentity = UUID()
        await open(conversationID: conversationID, workspaceID: workspaceID,
                   purpose: .run(runID: runIdentity.uuidString, display: languageID),
                   command: command, cwd: ".", columns: 80, rows: 24, requestID: requestID)
    }

    // MARK: Open

    /// Opens the conversation's interactive terminal (or a run session).
    /// Attaches the ORIGINAL `.conversation` receipt BEFORE the awaited
    /// `shell.start`, and the pump keeps it until real settlement.
    func open(conversationID: UUID, workspaceID expectedWorkspaceID: UUID?,
              purpose: G04TerminalSessionPurpose, command: String, cwd: String,
              columns: Int, rows: Int, requestID: String) async {
        guard !retired, G02NativeRootEpoch.readback() == epoch else {
            reply(requestID, ok: false, code: .retired); return
        }
        guard let (workspaceID, rootURL) = await admit(conversationID: conversationID,
                                                       expectedWorkspaceID: expectedWorkspaceID) else {
            let code = await conversationPurposeRefused(conversationID) ? G04TerminalCode.purposeNotOrdinary
                : G04TerminalCode.workspaceUnbound
            reply(requestID, ok: false, code: code); return
        }
        guard let components, RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else {
            // Honest availability: until the TRUSTED readiness ingress says
            // the engine is qualified, an interactive terminal refuses with
            // guidance — it NEVER falls back to a host shell or a fake text
            // log, and never "advertises" a pane that cannot run.
            reply(requestID, ok: false, code: .engineUnqualified); return
        }
        let conversationSessions = byConversation[conversationID] ?? []
        if purpose == .interactive,
           conversationSessions.contains(where: { sessions[$0]?.purpose.isInteractive == true && sessions[$0]?.alive == true }) {
            reply(requestID, ok: false, code: .saturated, reason: "interactiveTerminalAlreadyOpen"); return
        }
        guard sessions.count < G04TerminalLimits.maximumLiveSessions else {
            reply(requestID, ok: false, code: .saturated, reason: "uiSessionsSaturated"); return
        }
        guard let (runDomain, _) = RunDomainFacade.current(epoch: epoch),
              let receipt = await runDomain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                                       expectedEpoch: epoch) else {
            reply(requestID, ok: false, code: .retired); return
        }
        let ownerRunID = UUID()   // native-issued UI interaction identity
        // The owner identity is registered BEFORE the await so a late
        // settlement always finds its exact record; the engine call keeps
        // the receipt attached until its real terminal.
        do {
            let result = try await components.sessions.open(
                command: command,            // "" => engine interactive shell default
                cwd: cwd,
                environment: [:],
                columns: max(20, min(columns, 500)),
                rows: max(5, min(rows, 200)),
                runID: ownerRunID,           // UI identity, NOT a model Run
                rootURL: rootURL,
                cancellation: receipt.cancellation,
                forTerminal: true,           // ORIGINAL terminal semantics: raw bytes + no forced prepare
                toolEnvironment: nil,        // ORIGINAL persisted workspace binding resolves the layer
                clientSessionID: nil,        // ORIGINAL nil-owner = existing UI terminals
                conversationID: conversationID)
            let record = TerminalSessionRecord(sessionToken: result.sessionID, ownerRunID: ownerRunID,
                                               conversationID: conversationID, workspaceID: workspaceID,
                                               purpose: purpose, requestID: requestID,
                                               cancellation: receipt.cancellation, receipt: receipt)
            record.columns = max(20, min(columns, 500))
            record.rows = max(5, min(rows, 200))
            record.phase = result.alive ? .running : .closed
            record.alive = result.alive
            register(record)
            reply(requestID, ok: true, extra: ["sessionToken": result.sessionID])
            if let raw = result.terminalOutput, !raw.isEmpty {
                publishOutput(record: record, bytes: raw)
            }
            status(record)
            if result.alive {
                startPump(sessionToken: result.sessionID)
            } else {
                // Immediate-exit program: the engine already proved the
                // terminal; settle the receipt exactly once.
                record.phase = .exited
                await finishSession(sessionToken: result.sessionID, reason: "exited-immediately")
            }
        } catch {
            // The open never produced a session: release the receipt.
            await runDomain.endG04WorkspaceOperation(receipt)
            reply(requestID, ok: false, code: .backendFailed, reason: Self.faultToken(error))
        }
    }

    private func conversationPurposeRefused(_ conversationID: UUID) async -> Bool {
        guard let installed = G02RuntimeComposition.shared.installedComposition else { return false }
        guard let conversation = try? await installed.cluster.conversationStore
            .conversation(id: conversationID) else { return false }
        return conversation.purpose != .ordinary
    }

    private func register(_ record: TerminalSessionRecord) {
        sessions[record.sessionToken] = record
        byConversation[record.conversationID, default: []].append(record.sessionToken)
    }

    // MARK: Pump (view-independent; store-owned task)

    private func startPump(sessionToken: String) {
        guard pumpTasks[sessionToken] == nil else { return }
        pumpTasks[sessionToken] = Task { [weak self] in
            await self?.pump(sessionToken: sessionToken)
        }
    }

    private func pump(sessionToken: String) async {
        var cadence = G04TerminalPollCadence()
        guard let record = sessions[sessionToken] else { return }
        guard let components else { await settleFault(sessionToken, code: .engineUnqualified); return }
        while !Task.isCancelled {
            guard let record = sessions[sessionToken] else { return }
            if record.cancellation.isCancelled {
                // The ORIGINAL deletion fence / retirement cancelled the
                // receipt: request the honest close path NOW (a stop is a
                // request) and stay owned until the engine proves release.
                await requestCloseOfCancelled(sessionToken: sessionToken)
                return
            }
            if record.alive, exchangeSlotAllows(record) {
                cadence.noteLive()
                var input = record.pendingInput
                record.pendingInput.removeAll(keepingCapacity: true)
                let inputText: String? = input.isEmpty ? nil : String(decoding: input, as: UTF8.self)
                do {
                    let result = try await components.sessions.exchange(
                        sessionID: sessionToken,
                        input: inputText,
                        waitMs: G04TerminalLimits.exchangeWaitMillis,
                        maxBytes: G04TerminalLimits.inputWriteBytes,
                        runID: record.ownerRunID,
                        cancellation: record.cancellation,
                        forTerminal: true,
                        clientSessionID: nil)
                    guard sessions[sessionToken] === record else { return }
                    if let raw = result.terminalOutput, !raw.isEmpty {
                        publishOutput(record: record, bytes: raw)
                    }
                    record.alive = result.alive
                    if !result.alive {
                        record.exitCode = result.exitCode
                        if let failure = result.failure { record.faultCode = Self.faultToken(failure) }
                        record.phase = result.exitCode != nil ? .exited : .stopped
                        status(record)
                        await finishSession(sessionToken: sessionToken, reason: "engine-terminal")
                        return
                    } else {
                        updatePhase(record, result.bytesRead == 0 ? .waitingOutput : .running)
                    }
                    let sentInput = inputText != nil
                    let delay = cadence.delayAfterExchange(sentInput: sentInput, bytesRead: result.bytesRead)
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    continue
                } catch is CancellationError {
                    // Cooperative cancellation of THIS pump is not a
                    // disconnect: the session stays owned (ORIGINAL rule).
                    return
                } catch {
                    guard sessions[sessionToken] === record else { return }
                    record.alive = false
                    record.faultCode = Self.faultToken(error)
                    record.phase = .fault
                    status(record)
                    await finishSession(sessionToken: sessionToken, reason: "backend-error")
                    return
                }
            } else {
                let delay = cadence.delayWhileInactive(opening: false, exchangeInFlight: false)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func exchangeSlotAllows(_ record: TerminalSessionRecord) -> Bool { record.alive }

    // MARK: Output ring

    /// Publishes one raw PTY chunk: queued for the host with the bounded
    /// rollover accounting (typed, cumulative, never silent).
    private func publishOutput(record: TerminalSessionRecord, bytes: Data) {
        record.seq &+= 1
        record.ring.append((seq: record.seq, bytes: bytes))
        record.ringBytes += bytes.count
        while record.ringBytes > G04TerminalLimits.maximumRingBytes
                || record.ring.count > G04TerminalLimits.maximumQueuedChunks {
            guard let oldest = record.ring.first else { break }
            record.ring.removeFirst()
            record.ringBytes -= oldest.bytes.count
            record.rolledOverBytes += oldest.bytes.count
        }
        drainRing(record: record)
    }

    private func drainRing(record: TerminalSessionRecord) {
        while let head = record.ring.first {
            sink.emitOutput(sessionToken: record.sessionToken, seq: head.seq, bytes: head.bytes)
            record.ring.removeFirst()
            record.ringBytes -= head.bytes.count
        }
    }

    // MARK: Actions

    func input(sessionToken: String, bytes: Data, requestID: String) {
        guard let record = sessions[sessionToken] else {
            reply(requestID, ok: false, code: .sessionUnknown); return
        }
        guard record.alive else { reply(requestID, ok: false, code: .sessionUnknown); return }
        guard record.pendingInput.count + bytes.count <= G04TerminalLimits.maximumPendingInputBytes else {
            reply(requestID, ok: false, code: .tooLarge, reason: "pendingInputOverflow"); return
        }
        record.pendingInput.append(bytes)
        reply(requestID, ok: true)
    }

    func interrupt(sessionToken: String, requestID: String) {
        // The interrupt KEY is a real ETX byte riding the ordered input
        // stream (line discipline raises SIGINT for the foreground group,
        // the interactive shell survives) — the ORIGINAL iOS owner rule.
        input(sessionToken: sessionToken, bytes: Data([0x03]), requestID: requestID)
    }

    func resize(sessionToken: String, columns: Int, rows: Int, requestID: String) async {
        guard let record = sessions[sessionToken], record.alive else {
            reply(requestID, ok: false, code: .sessionUnknown); return
        }
        let clampedColumns = max(20, min(columns, 500))
        let clampedRows = max(5, min(rows, 200))
        record.columns = clampedColumns
        record.rows = clampedRows
        if let components {
            await components.sessions.resize(sessionID: sessionToken, columns: clampedColumns,
                                             rows: clampedRows, runID: record.ownerRunID,
                                             clientSessionID: nil)
        }
        reply(requestID, ok: true)
    }

    func close(sessionToken: String, requestID: String) async {
        guard let record = sessions[sessionToken] else {
            reply(requestID, ok: false, code: .sessionUnknown); return
        }
        reply(requestID, ok: true)
        await finishSession(sessionToken: sessionToken, reason: "explicit-close")
        // finishSession requests the engine close; the pump's own
        // cancellation only ends the pump task, the record settles here.
        pumpTasks[sessionToken]?.cancel()
        pumpTasks[sessionToken] = nil
        record.alive = false
        record.phase = .closed
        status(record)
    }

    func attach(sessionToken: String, requestID: String) {
        // View (re)attachment: NEVER a navigation, NEVER a restart, NEVER a
        // process signal. The service-owned session keeps running; the host
        // renderer keeps its own emulator snapshot, so nothing replays.
        guard let record = sessions[sessionToken] else {
            reply(requestID, ok: false, code: .sessionUnknown); return
        }
        drainRing(record: record)
        status(record)
        reply(requestID, ok: true)
    }

    func statusSnapshot(conversationID: UUID, requestID: String) async {
        guard let (_, root) = await admit(conversationID: conversationID, expectedWorkspaceID: nil) else {
            reply(requestID, ok: false, code: .workspaceUnbound); return
        }
        let tokens = byConversation[conversationID] ?? []
        let states: [[String: Any]] = tokens.compactMap { token in
            guard let record = sessions[token] else { return nil }
            var object: [String: Any] = [
                "sessionToken": token,
                "phase": record.phase.rawValue,
                "purpose": record.purpose.purposeTag,
                "runID": record.purpose.runTag ?? "",
                "columns": record.columns, "rows": record.rows,
            ]
            if let exitCode = record.exitCode { object["exitCode"] = Int(exitCode) }
            if let stopReason = record.stopReason { object["stopReason"] = stopReason }
            if let faultCode = record.faultCode { object["faultCode"] = faultCode }
            return object
        }
        reply(requestID, ok: true, extra: ["sessions": states,
                                           "qualified": RuntimeFacadeLinuxBindings.shared.isCapabilityQualified])
        _ = root
    }

    // MARK: Settlement

    /// Requests the ORIGINAL close path (engine stop REQUEST + lease
    /// retention) and detaches the receipt only AFTER
    /// `ShellSessionCenter.close` has run the backend teardown. A cancelled
    /// deletion fence follows the same path; neither fabricates a stop.
    private func finishSession(sessionToken: String, reason: String) async {
        guard let record = sessions[sessionToken] else { return }
        sessions.removeValue(forKey: sessionToken)
        byConversation[record.conversationID]?.removeAll { $0 == sessionToken }
        if byConversation[record.conversationID]?.isEmpty == true { byConversation.removeValue(forKey: record.conversationID) }
        if let components {
            await components.sessions.close(sessionID: sessionToken, runID: record.ownerRunID,
                                            clientSessionID: nil)
        }
        if let (runDomain, _) = RunDomainFacade.current(epoch: epoch) {
            await runDomain.endG04WorkspaceOperation(record.receipt)
        }
        pumpTasks[sessionToken]?.cancel()
        pumpTasks[sessionToken] = nil
    }

    private func requestCloseOfCancelled(sessionToken: String) async {
        guard let record = sessions[sessionToken] else { return }
        record.alive = false
        record.phase = .stopped
        record.stopReason = "lifecycle-cancelled"
        status(record)
        await finishSession(sessionToken: sessionToken, reason: "lifecycle-cancelled")
    }

    private func settleFault(_ sessionToken: String, code: G04TerminalCode) async {
        guard let record = sessions[sessionToken] else { return }
        record.alive = false
        record.phase = .fault
        record.faultCode = code.rawValue
        status(record)
        await finishSession(sessionToken: sessionToken, reason: code.rawValue)
    }

    // MARK: Retire

    /// Exact-epoch teardown by the host API on bind replacement/retirement:
    /// requests closes for every live UI session through the ORIGINAL path
    /// (the engine's reconciliation owns the long tail; a stop REQUEST is
    /// never reported as a proven stop).
    func retire() async {
        guard !retired else { return }
        retired = true
        for token in Array(sessions.keys) {
            await requestCloseOfCancelled(sessionToken: token)
        }
    }

    // MARK: Reply helper

    private func reply(_ requestID: String, ok: Bool, code: G04TerminalCode? = nil,
                       reason: String? = nil, extra: [String: Any] = [:]) {
        var object: [String: Any] = ["type": "actionReply", "requestID": requestID, "ok": ok]
        if let code { object["code"] = code.rawValue }
        if let reason { object["reason"] = reason }
        for (key, value) in extra { object[key] = value }
        sink.emitControl(object)
    }

    static func faultToken(_ error: Any) -> String {
        if let typed = error as? LinuxShellTransportError {
            switch typed {
            case .notBound: return "engineUnbound"
            case .saturated: return "mailboxSaturated"
            case .payloadTooLarge: return "payloadTooLarge"
            case .remoteFailed(let code): return "engineFailed:" + Self.token(code)
            case .remoteFailedWithRestore(let code, _): return "engineFailed:" + Self.token(code)
            case .replyMalformed: return "engineReplyMalformed"
            case .hostFenced: return "engineFenced"
            case .waitBudgetExpired: return "engineBudgetExpired"
            }
        }
        if error is CancellationError { return "cancelled" }
        let text = String(describing: error)
        return Self.token(text.count > 128 ? String(text.prefix(128)) : text)
    }

    private static let tokenAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-.")
    static func token(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar in
            tokenAllowed.contains(scalar) ? Character(scalar) : Character("_")
        }
        return String(scalars)
    }
}

// MARK: - Small records helpers

extension G04TerminalSessionPurpose {
    var isInteractive: Bool { if case .interactive = self { return true }; return false }
    var purposeTag: String {
        switch self { case .interactive: return "interactive"; case .run: return "run" }
    }
    var runTag: String? {
        switch self { case .interactive: return nil; case .run(let id, _): return id }
    }
}

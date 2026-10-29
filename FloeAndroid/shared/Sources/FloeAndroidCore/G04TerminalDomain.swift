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
// Owned-slot admission vocabulary (Main ruling 2026-10-28): FloeAndroidCore
// already depends on FloeAgentRuntime, so this is an existing module edge.
import FloeAgentRuntime

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
    /// Set by ONE explicit user Close. It never settles the session by
    /// itself: the pump still waits for the engine's REAL terminal (and its
    /// workspace export receipt) and only then may report `.closed`.
    var closeRequested = false

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
        // G05-R3 run-less first entry: the editor's explicit Run button shares
        // the terminal's gate, so it prepares the readiness facts itself
        // instead of waiting for somebody to send a message. This MUST precede
        // the ORIGINAL admit(): a genuinely fresh ordinary task has no binding
        // yet, so admitting first would refuse before the genuine binding can
        // be created. No model run is manufactured to unlock it and a warm
        // lane is a fast no-op; a typed refusal is a HARD refusal (no global
        // readiness override).
        switch await prepareFirstEntry(conversationID: conversationID,
                                       expectedWorkspaceID: expectedWorkspaceID) {
        case .proceed: break
        case .refuse(let code, let token):
            reply(requestID, ok: false, code: code, reason: token); return
        }
        // Re-prove the exact conversation/workspace AFTER the awaited prepare.
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

    // MARK: Run-less first entry (G05-R3, job-e2e7d046b63744cc)

    /// Service-owned retention tasks: one per first-entry preparation whose
    /// physical settlement was NOT proven when its waiter completed (an
    /// uncertain/cancelled/`close_retained` reply, a budget expiry, a fence or
    /// a still-claimed ticket). Tracked by this store (never by a view) and
    /// deliberately NOT cancelled by `retire()`: neither a cancelled waiter nor
    /// a generation fence is physical settlement, so the receipt stays attached
    /// until the host's own ownership table reports this identity released.
    private var firstEntryRetentions: [UUID: Task<Void, Never>] = [:]

    /// Diagnostic/test truth: how many first-entry ownership retentions this
    /// store still holds (a claimed ticket whose real settlement has not been
    /// observed yet). Gates nothing.
    var firstEntryRetentionCount: Int { firstEntryRetentions.count }

    /// Prepares one EXPLICIT human terminal/run action's first entry WITHOUT a
    /// model, provider or run, and answers whether the caller may continue.
    ///
    /// Two real gaps block a fresh generation, and both are closed here:
    ///  1. a genuinely NEW ordinary task has NO workspace binding row — the
    ///     production conversation store is constructed with
    ///     `bindsNewConversationsToDefaultWorkspace = false`
    ///     (RuntimeFacadeConversations.swift:2627) and `create` assigns
    ///     ownership only when that flag is true (:3347, :3376) — so
    ///     `LinuxWorkspaceAuthority.resolveWorkspace(conversationID:)` answers
    ///     nil and the `admit` below could never reach a readiness step;
    ///  2. the two receipt-backed readiness facts (`workspaceMappingSynced`,
    ///     `leaseAuthorityQualified`) were produced only by the first ordinary
    ///     MODEL run's preflight (`RuntimeFacadeRunAssembly.makeService`), so a
    ///     no-provider user never qualified and the terminal refused.
    ///
    /// The binding is created through the SAME genuine ordinary workflow the
    /// D14 `workspace.activate` command uses (`G04WorkspaceFacade.activate` ->
    /// `SQLiteWorkspaceStore.ensureWorkspace(conversationID:title:)`: the
    /// ORIGINAL canonical `.privateTask` / `PrivateTasks/<conversationID>`
    /// ownership row inside the store's own serialized write transaction), with
    /// the same canonical bounded title projection — never a first-project or
    /// temp-directory guess, never a temporary/notes/foreign identity, never a
    /// fabricated run row, and an existing association is returned untouched.
    ///
    /// Ownership discipline: ONE real `.conversation` operation lease
    /// (`beginG04WorkspaceOperation`, registered with the ORIGINAL workspace
    /// authority under a native-issued UI identity) covers this action's own
    /// durable write and its NON-EXECUTING host preflight. It is discharged
    /// exactly once, and ONLY on proven physical settlement: neither this
    /// waiter's completion (a budget expiry or a cancellation releases the
    /// waiter while a CLAIMED ticket stays owned), nor the host's completion of
    /// the claim (`unavailable`/`cancelled`/`close_retained` are answered while
    /// the pump's reconciliation may still own real IO), nor a generation fence
    /// (the ORIGINAL fence contract keeps owned workers and remote leases alive)
    /// counts. So the release needs the host's OWN asserted fact
    /// (`ownershipReleased`) or an explicit per-request observation of the
    /// pump's ownership table, and a store-owned task — never a view task, never
    /// a global drain, never an elapsed-time success — holds the lease until
    /// then. Every step is re-fenced against the exact Root generation, this
    /// store's retirement and the lease's own cancellation after its await, and
    /// the caller re-runs the ORIGINAL `admit` afterwards, so nothing opens
    /// late.
    ///
    /// Anything this step cannot repair answers `.proceed`, so the ORIGINAL
    /// admission below produces its ORIGINAL honest refusal: no new code is
    /// invented here and nothing that could not open before may open now.
    /// Internal (never a host entry point): the authored regression pins its
    /// fail-closed shape with no installed composition, exactly like the
    /// pump's `mappingIndexDigest` seam.
    func prepareFirstEntry(conversationID: UUID,
                           expectedWorkspaceID: UUID?) async -> G04TerminalFirstUseAdmission.Verdict {
        guard !retired, G02NativeRootEpoch.readback() == epoch,
              let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return .proceed }
        // Real reads only, then the PURE eligibility rule: a durable ORDINARY
        // conversation of THIS exact generation, its actual ownership row (or a
        // proven absence) and no foreign workspace expectation. A temporary
        // chat has no persisted row by design; notes/foreign identities, a dead
        // generation, an unreadable ownership row and an explicit foreign
        // expectation all keep the ORIGINAL admission and its ORIGINAL refusal,
        // so nothing here can widen what may open or write a row it must not.
        let conversation = try? await installed.cluster.conversationStore
            .conversation(id: conversationID)
        var bindingKnown = false
        var alreadyBound = false
        do {
            alreadyBound = try await installed.cluster.workspaceStore
                .workspaceID(conversationID: conversationID) != nil
            bindingKnown = true
        } catch {
            bindingKnown = false
        }
        let bound: Bool
        switch G04TerminalFirstUseRule.bindingEligibility(
            conversationPersisted: conversation != nil,
            purposeOrdinary: conversation?.purpose == .ordinary,
            generationLive: !retired && G02NativeRootEpoch.readback() == epoch && installed.epoch == epoch,
            bindingKnown: bindingKnown,
            alreadyBound: alreadyBound,
            foreignWorkspaceExpectation: expectedWorkspaceID != nil) {
        case .notEligible:
            return .proceed
        case .alreadyBound:
            bound = true
        case .eligible:
            bound = false
        }
        let readiness = G04TerminalFirstUseRule.decision(
            fields: LinuxReadinessIngress.shared.derivedFields(),
            capabilityQualified: RuntimeFacadeLinuxBindings.shared.isCapabilityQualified)
        var needsPreflight = false
        switch readiness {
        case .prepare:
            needsPreflight = true
        case .skipAlreadyQualified:
            if bound { return .proceed }          // fully warm: nothing to do
        case .refuse(let code):
            // Without the five transport/rootfs/workload prerequisites nothing
            // can execute, so no durable row is written for a lane that cannot
            // run; an unbound task keeps its ORIGINAL workspace refusal.
            guard bound else { return .proceed }
            return G04TerminalFirstUseAdmission.verdict(code: code)
        }
        guard let (runDomain, _) = RunDomainFacade.current(epoch: epoch),
              let receipt = await runDomain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                                       expectedEpoch: epoch) else {
            return G04TerminalFirstUseAdmission.verdict(code: .leaseUnavailable)
        }
        let uiRunID = UUID()   // native-issued UI identity, NEVER a model run
        guard LinuxWorkspaceAuthority.registerWorkspaceOperation(receipt, epoch: epoch,
                                                                 uiRunID: uiRunID) else {
            await runDomain.endG04WorkspaceOperation(receipt)
            return G04TerminalFirstUseAdmission.verdict(code: .operationRegistrationRefused)
        }
        // Close the drain race BEFORE any SQLite/host await can settle: the
        // ORIGINAL shell drain must see this receipt from operation admission
        // until its exact physical release. Registering only after an
        // uncertain reply would leave a mailbox-empty window in which stop /
        // Root replacement could fence the sole observation channel.
        RuntimeFacadeLinuxBindings.shared.retainFirstEntryOwnership(receipt.operationID)
        var bindingFailure: G04TerminalFirstUseCode?
        if !bound {
            bindingFailure = await ensureOrdinaryTaskWorkspace(conversationID: conversationID,
                                                               title: conversation?.title ?? "",
                                                               receipt: receipt,
                                                               runDomain: runDomain)
        }
        var outcome: G04TerminalFirstUse.Outcome?
        if bindingFailure == nil, needsPreflight {
            outcome = await G04TerminalFirstUse.prepare(epoch: epoch,
                                                        conversationID: conversationID,
                                                        operationID: receipt.operationID,
                                                        uiRunID: uiRunID)
        }
        // Release exactly once, bound to the host's OWN physical-settlement
        // fact — never to this waiter's completion, and never to a completed
        // claim alone: the pump answers uncertain/cancelled/`close_retained`
        // while it may still own the real import/export IO, and a generation
        // fence explicitly does not end owned workers. A retained claim keeps
        // the operation mapping and the conversation receipt attached under a
        // store-owned task that observes the pump's own ownership table.
        let ownership = G04TerminalFirstUseOwnership(
            request: outcome?.request,
            hostOwnershipReleased: outcome?.hostOwnershipReleased ?? false) {
            LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: receipt.operationID)
            await runDomain.endG04WorkspaceOperation(receipt)
            // Only AFTER the REAL operation receipt ended may the original
            // stop/drain/fence path stop seeing this first-use owner.
            RuntimeFacadeLinuxBindings.shared.releaseFirstEntryOwnership(receipt.operationID)
        }
        if ownership.mustRetain {
            retainFirstEntryOwnership(ownership, operationID: receipt.operationID,
                                      uiRunID: uiRunID, conversationID: conversationID,
                                      queryEpoch: epoch)
        } else {
            _ = await ownership.releaseOnce()
        }
        // Re-fence the EXACT generation/store/task truth after every await.
        guard !retired, G02NativeRootEpoch.readback() == epoch else {
            return G04TerminalFirstUseAdmission.verdict(code: .generationMoved)
        }
        guard !receipt.cancellation.isCancelled else {
            return G04TerminalFirstUseAdmission.verdict(code: .leaseCancelled)
        }
        if let bindingFailure {
            return G04TerminalFirstUseAdmission.verdict(code: bindingFailure)
        }
        guard let outcome else {
            // Only the binding was missing and it is now genuine: proceed on
            // Core's OWN live qualification (re-read here, never assumed).
            return RuntimeFacadeLinuxBindings.shared.isCapabilityQualified
                ? .proceed
                : G04TerminalFirstUseAdmission.verdict(code: .capabilityNotQualified)
        }
        return G04TerminalFirstUseAdmission.verdict(
            outcome: outcome,
            capabilityQualified: RuntimeFacadeLinuxBindings.shared.isCapabilityQualified)
    }

    /// Creates the genuine persisted private-task workspace binding for ONE
    /// ordinary conversation, run-less, under the caller's live operation
    /// lease. Nil when the binding already existed (untouched) or was really
    /// created; otherwise the bounded refusal token. The ORIGINAL store's own
    /// serialized write transaction owns atomicity: a thrown error leaves no
    /// row and no partial write (the same rollback guarantee the D14 command
    /// relies on).
    private func ensureOrdinaryTaskWorkspace(conversationID: UUID, title: String,
                                             receipt: G04WorkspaceOwnedOperation,
                                             runDomain: FacadeRunDomain) async -> G04TerminalFirstUseCode? {
        guard !retired, G02NativeRootEpoch.readback() == epoch,
              let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return .generationMoved }
        let store = installed.cluster.workspaceStore
        do {
            // An existing association is returned untouched — never re-pointed,
            // never switched to a guessed private/first project.
            if try await store.workspaceID(conversationID: conversationID) != nil { return nil }
            try receipt.cancellation.throwIfCancelled()
            _ = try await store.ensureWorkspace(
                conversationID: conversationID,
                title: G04TerminalFirstUse.canonicalWorkspaceTitle(title))
            // The lease must still be live AFTER the write (the ORIGINAL D14
            // re-validation): a deletion fence or retirement that landed
            // mid-transaction is answered honestly instead of being spent.
            guard await runDomain.validateG04WorkspaceOperation(receipt) else { return .leaseCancelled }
            return nil
        } catch is CancellationError {
            return .leaseCancelled
        } catch {
            return .workspaceBindingFailed
        }
    }

    /// Registers one store-owned retention task (never a view task, never a
    /// global mailbox drain, never an elapsed-time release): it holds the
    /// operation mapping + conversation receipt until the host's OWN ownership
    /// table reports this exact identity released, then releases exactly once
    /// and clears its entry. Bounded polls of one pure-read observation; a
    /// fence, a failed observation or a cancellation RETAIN, and `retire()`
    /// deliberately does not cancel these tasks — the original fence contract
    /// keeps owned workers and remote leases alive until real release.
    private func retainFirstEntryOwnership(_ ownership: G04TerminalFirstUseOwnership,
                                           operationID: UUID, uiRunID: UUID,
                                           conversationID: UUID, queryEpoch: UInt64) {
        let task = Task.detached(priority: .utility) { [weak self] in
            let observed = await ownership.settleByObservation {
                await G04TerminalFirstUse.observeOwnership(operationID: operationID,
                                                           uiRunID: uiRunID,
                                                           conversationID: conversationID,
                                                           queryEpoch: queryEpoch)
            }
            // `.released` is returned ONLY after the exactly-once release
            // closure (including the drain gate) completed. Unexpected task
            // cancellation keeps BOTH the local and global ownership markers
            // fail-closed instead of silently opening a drain gap.
            if observed == .released {
                await self?.forgetFirstEntryRetention(operationID: operationID)
            }
        }
        firstEntryRetentions[operationID] = task
        // Released while the task was being registered: keep the table honest
        // instead of retaining a finished task.
        if !ownership.mustRetain { firstEntryRetentions[operationID] = nil }
    }

    private func forgetFirstEntryRetention(operationID: UUID) {
        firstEntryRetentions[operationID] = nil
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
        // G05-R3 run-less FIRST ENTRY (job-e2e7d046b63744cc): THIS explicit
        // human terminal action prepares its own genuine task workspace
        // binding and/or the two receipt-backed readiness facts — no message,
        // no provider, no model run and no fabricated run row. A fast no-op
        // when both already exist (warm re-entry never re-imports), and a typed
        // refusal is a HARD refusal: no global readiness truth may override a
        // cancelled, fenced, expired or refused preparation of THIS action.
        switch await prepareFirstEntry(conversationID: conversationID,
                                       expectedWorkspaceID: expectedWorkspaceID) {
        case .proceed: break
        case .refuse(let code, let token):
            reply(requestID, ok: false, code: code, reason: token); return
        }
        // The ORIGINAL admission now runs AFTER that await on every path, so it
        // is also the re-fence of the exact Root generation, this store's
        // retirement, the durable ordinary conversation row and the resolved
        // workspace binding.
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
            // log, and never "advertises" a pane that cannot run. Defensive
            // re-read: the first entry above already carried its precise token.
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
        if await components.backend.isEngineSlotBusy() {
            // G04-R2 single-workload truth (the same honest pre-check the run
            // lane makes): the gate is held by a live language server or
            // program run, so NOTHING is minted, registered or dispatched.
            // The refusal names the exact condition instead of waiting the
            // gate timeout and collapsing into a generic backendFailed
            // (ORIGINAL .notStarted truth; never a queue, never a lie).
            reply(requestID, ok: false, code: .saturated, reason: "engineSlotBusy")
            return
        }
        guard let (runDomain, _) = RunDomainFacade.current(epoch: epoch),
              let receipt = await runDomain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                                       expectedEpoch: epoch) else {
            reply(requestID, ok: false, code: .retired); return
        }
        let ownerRunID = UUID()   // native-issued UI interaction identity
        // G04-R2 operation-owned admission (Main contract 2026-10-25): the
        // workspace grant for this explicit UI action mints ONLY against the
        // REAL receipt lease registered here — the authority re-checks the
        // registry token, the domain's fences/cancellation and the ORIGINAL
        // conversation-ownership row on mint, open and every transaction.
        // A registration refusal (not installed / generation moved / live
        // table saturated) is an honest refusal BEFORE any dispatch: the
        // receipt is released and nothing starts. No model Run is fabricated.
        let operationGrantID = receipt.operationID
        guard LinuxWorkspaceAuthority.registerWorkspaceOperation(receipt, epoch: epoch,
                                                                 uiRunID: ownerRunID) else {
            await runDomain.endG04WorkspaceOperation(receipt)
            reply(requestID, ok: false, code: .retired)
            return
        }
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
                conversationID: conversationID,
                workspaceOperationID: operationGrantID)
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
            // The open never produced a session: clear the exact operation
            // mapping and release the receipt (writeback truth unchanged —
            // nothing is completed, nothing is fabricated).
            LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: operationGrantID)
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
                        record.phase = Self.settledPhase(closeRequested: record.closeRequested,
                                                         cancelled: result.cancelled,
                                                         exitCode: result.exitCode,
                                                         workspaceStatus: result.workspaceStatus)
                        if record.closeRequested, record.phase == .fault {
                            // The engine's real terminal landed, but its OWN
                            // workspace export did not settle synced. Name the
                            // receipt fact: never a fake closed/saved state.
                            record.faultCode = Self.closeExportFaultToken(result.workspaceStatus)
                        } else if record.phase == .closed {
                            // An expected user-stop note is not a fault once
                            // the release AND the export receipt are real.
                            record.faultCode = nil
                        }
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
        guard record.alive && !record.closeRequested else {
            reply(requestID, ok: false, code: .sessionUnknown); return
        }
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
        guard let record = sessions[sessionToken], record.alive, !record.closeRequested else {
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

    /// Accepts ONE manual Close as a stop REQUEST, never as a settlement.
    ///
    /// The session and its registered workspace-operation lease stay OWNED
    /// until the store pump observes the engine's real terminal
    /// (`leaseReleased`). That terminal is published only after the runtime's
    /// whole-UID stop proof AND its workspace export, so the operation lease
    /// must stay live through it: retiring the receipt here (the previous
    /// behavior) revoked the grant currency while the runtime's asynchronous
    /// stop lane was still exporting, `EXPORT_BEGIN` refused with
    /// `runCurrency`, and the user's guest files never reached the native
    /// workspace (G06 manual-close regression). A failed/absent export is
    /// reported as a typed FAULT by the pump, never a fake CLOSED.
    func close(sessionToken: String, requestID: String) async {
        guard let record = sessions[sessionToken] else {
            reply(requestID, ok: false, code: .sessionUnknown); return
        }
        guard !record.closeRequested else {
            reply(requestID, ok: true); return
        }
        record.closeRequested = true
        // The user ended the interaction: queued keystrokes must not be
        // written into a stopping shell (the old immediate teardown dropped
        // them with the pump task).
        record.pendingInput.removeAll(keepingCapacity: true)
        reply(requestID, ok: true)
        guard let components else {
            // No engine is bound any more: nothing can be requested and no
            // export can be awaited. The typed fault releases the exact lease.
            await settleFault(sessionToken, code: .engineUnqualified)
            return
        }
        _ = await components.sessions.requestStopForSettlement(
            sessionID: sessionToken, runID: record.ownerRunID, clientSessionID: nil)
        // The service-owned pump's next REAL terminal (or a typed fault)
        // settles this record through finishSession; nothing is fabricated.
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

    // MARK: Owned-slot conflict truth (model admission gate)

    /// Trusted host fact for the runtime's admission gate (Main ruling
    /// 2026-10-28): the LIVE interactive terminal THIS conversation owns,
    /// when that exact session is the workload the engine still holds a lease
    /// for. This store is the ORIGINAL session owner, so the answer comes from
    /// its own table plus the backend's real lease truth — never from a
    /// projection, a guess or another conversation's session.
    ///
    /// It is a pure observation: nothing is stopped, killed, retried, queued
    /// or granted here, and a `.run` (language/run-draft) session is never
    /// reported as a manual terminal. Nil is the honest answer for an
    /// unbound/retired generation, an unqualified engine, a free slot, an
    /// already-released lease and a conversation with no live terminal — so
    /// the ordinary approval path is unchanged whenever there is no conflict.
    func interactiveTerminalHoldingEngineSlot(
        conversationID: UUID
    ) async -> LinuxEngineSlotConflict? {
        guard !retired, G02NativeRootEpoch.readback() == epoch else { return nil }
        guard let components else { return nil }
        let liveInteractive = (byConversation[conversationID] ?? []).filter { token in
            guard let record = sessions[token] else { return false }
            return record.purpose.isInteractive && record.alive
        }
        guard !liveInteractive.isEmpty else { return nil }
        // Both reads are the backend's own truth: `ownedSessions()` lists the
        // leases whose REAL release is not proven yet, and `isEngineSlotBusy()`
        // is the single-slot gate itself. Requiring both means a session the
        // engine already released (or a gate freed by a generation fence) is
        // never presented as a live conflict.
        let ownedKeys = await components.backend.ownedSessions().map(\.sessionKey)
        let slotBusy = await components.backend.isEngineSlotBusy()
        // Ownership is re-proven AFTER those two suspensions and immediately
        // before the fact is published: this actor can be retired, or the Root
        // generation replaced, while either read is in flight — and the
        // composition registry's own register/retire runs outside its mailbox
        // lock, so the registry epoch alone is not this store's ownership
        // proof. A moved-on generation publishes nothing (fail closed).
        guard !retired, G02NativeRootEpoch.readback() == epoch else { return nil }
        // The session table is re-read too: a token that settled during the
        // await is no longer this conversation's live terminal.
        let stillLive = liveInteractive.filter { token in
            guard let record = sessions[token] else { return false }
            return record.purpose.isInteractive && record.alive
        }
        return LinuxEngineSlotConflictRule.conflict(
            conversationID: conversationID,
            nativeEpoch: epoch,
            liveInteractiveSessionTokens: stillLive,
            engineSlotBusy: slotBusy,
            ownedEngineSessionKeys: ownedKeys
        )
    }

    // MARK: Settlement

    /// Settlement: detaches the receipt and its operation mapping ONLY once
    /// the terminal is real — an engine-proven exit/stop (the pump calls this
    /// after `leaseReleased`, which the runtime publishes only after its
    /// whole-UID stop proof and workspace export), a typed fault, or a
    /// lifecycle cancellation/fence. The explicit manual Close never calls
    /// this directly: it requests the owned stop and leaves the session and
    /// its operation lease to the pump's real terminal. A cancelled deletion
    /// fence keeps the ORIGINAL request-then-retire path; it fabricates no
    /// stop and claims no export.
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
        // G04-R2: the operation mapping ends exactly with its real lease
        // (settle/stop/exit/fault/cancel/retirement all route here).
        LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: record.receipt.operationID)
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

    /// Closed-set phase decision for a REAL engine terminal (never a timer).
    /// A manual Close is `closed` ONLY when the engine proved a STOP and the
    /// runtime's OWN workspace export receipt says `synced`; a refused,
    /// conflicted, aborted or absent export is a typed fault, never a fake
    /// closed/saved state. A real (non-cancelled) exit always keeps `exited`;
    /// an engine-proven stop the user did not request keeps the historical
    /// exit-code/stop mapping.
    static func settledPhase(closeRequested: Bool, cancelled: Bool,
                             exitCode: Int32?, workspaceStatus: String?) -> G04TerminalPhase {
        if closeRequested, cancelled {
            return workspaceStatus == "synced" ? .closed : .fault
        }
        return exitCode != nil ? .exited : .stopped
    }

    /// Bounded fault token for a manual close whose real workspace export did
    /// not settle synced. Names the receipt fact only (no path, digest or
    /// reply body) and stays inside the closed wire vocabulary.
    static func closeExportFaultToken(_ workspaceStatus: String?) -> String {
        switch workspaceStatus {
        case "conflict": return "workspaceExportConflict"
        case "aborted": return "workspaceExportAborted"
        case "error": return "workspaceExportFailed"
        case "unknown": return "workspaceExportUnknown"
        default: return "workspaceExportUnconfirmed"
        }
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

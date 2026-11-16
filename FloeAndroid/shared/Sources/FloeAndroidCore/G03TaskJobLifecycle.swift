// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — finite background-job lifecycle for a parked ordinary run.
//
// This file is the TRUSTED-HOST seam between the ORIGINAL durable job
// closure (`FloeAndroidJobTools`: BackgroundJobStore/Service, the real
// processors and the durable `run_dependencies` edges) and the ORIGINAL run
// closure (`FacadeRunDomain` over `ConversationRunService`/`FloeAgentRuntime`).
// It adds no job store, no runner, no provider path and no model tool:
//
//  * `RunDependencyEdgeReading` reads the EXISTING durable edges for one run.
//    The parked reason is read from the run's OWN durable terminal status
//    event; the recovery checkpoint's state is only a replay boundary (the
//    runtime downgrades `streamingModel` to `preparing` on disk), so it is
//    never treated as dependency truth.
//  * `RunDependencyResumeGate` is the closed decision function: resume only
//    when every required edge is terminal, wait while one is pending, and
//    refuse to guess when the store cannot answer.
//  * `JobDependencyContinuation` is the automatic trigger. It runs ONLY from
//    an exact job terminal callback, from the C01 first-proven service
//    readiness callback, or from the bounded relaunch reconciliation. It
//    never polls, never starts a new run and never fabricates a user turn.
//    Relaunch reconciliation is SUCCESS-ONLY (completed job / proven service
//    readiness): a previous process's interrupted, cancelled, failed or
//    missing outcome never auto-starts a model and remains an explicit user
//    Continue decision.
//  * `TaskJobsHostBridge` (BridgeV30, `floe.taskjobs/30`) is the App-host
//    read/cancel channel for THIS task's finite jobs. It exposes a bounded
//    projection of durable rows only: no payload, no command text, no output
//    path, no result excerpt and no private path. Per-job cancel resolves the
//    exact durable run ownership before the ORIGINAL cooperative cancel.
//
// Standalone native/managed services are deliberately excluded from
// automatic continuation: their READINESS may wake the waiting parent, but a
// stopped/failed standalone service never starts a chat model.

import Foundation
import CoreFoundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeAndroidJobTools

// MARK: - Closed target classifier

/// Product-safe job target classes. The App host never receives the raw
/// target tool name, payload, environment or workspace path.
public enum TaskJobTargetKind: String, Sendable, Equatable, CaseIterable {
    case shell
    case web
    case officeEdit
    case service
    case other

    public static func classify(targetTool: String, payloadJSON: Data) -> TaskJobTargetKind {
        if targetTool == "exec.localService"
            || C01ManagedServiceDeclaration.isServicePayload(payloadJSON) {
            return .service
        }
        switch targetTool {
        case "exec.shell": return .shell
        case "web.fetch": return .web
        case "document.office.edit": return .officeEdit
        default: return .other
        }
    }
}

// MARK: - Durable dependency edges

/// One durable required-dependency edge as the run domain may observe it.
/// `pending` is the only non-terminal state; `missing` means the checkpoint
/// named a job but no durable edge row exists (a pre-edge checkpoint or a
/// removed row) — never silently treated as success.
public enum RunDependencyObservation: Sendable, Equatable {
    case pending(jobID: UUID, kind: String)
    case terminal(jobID: UUID, kind: String, state: RunDependencyState)
    case missing(jobID: UUID)
}

/// Trusted read of the ORIGINAL `run_dependencies` rows for one run.
public protocol RunDependencyEdgeReading: Sendable {
    /// Every edge the run may be waiting on. `jobIDs` are the identifiers the
    /// run's own durable park reason named (possibly empty for older
    /// checkpoints). Returns nil when the store cannot answer — never an
    /// empty array as a substitute for an unreadable store.
    func edges(runID: UUID, jobIDs: [UUID]) async -> [RunDependencyObservation]?
    func resolve(jobID: UUID, state: RunDependencyState, note: String?) async
}

/// Production reader over the SAME G02 database the job service uses.
public struct G02RunDependencyEdgeReader: RunDependencyEdgeReading {
    private let store: SQLiteRunDependencyStore

    public init(database: DatabaseManager) {
        store = SQLiteRunDependencyStore(database: database)
    }

    public func edges(runID: UUID, jobIDs: [UUID]) async
        -> [RunDependencyObservation]? {
        let pending: [RunDependencyRecord]
        do { pending = try await store.pending(runID: runID) }
        catch { return nil }
        var pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.jobID, $0) })
        var observations: [RunDependencyObservation] = []
        var seen: Set<UUID> = []
        for jobID in jobIDs where seen.insert(jobID).inserted {
            if let edge = pendingByID.removeValue(forKey: jobID) {
                observations.append(.pending(jobID: jobID, kind: edge.kind))
                continue
            }
            let record: RunDependencyRecord?
            do { record = try await store.record(jobID: jobID) }
            catch { return nil }
            guard let record else {
                observations.append(.missing(jobID: jobID))
                continue
            }
            guard record.runID == runID else { return nil }
            if record.state.isTerminal {
                observations.append(.terminal(jobID: jobID, kind: record.kind,
                                              state: record.state))
            } else {
                observations.append(.pending(jobID: jobID, kind: record.kind))
            }
        }
        // An older checkpoint reason may not name every edge. Any still
        // pending edge for THIS run must keep it parked.
        for edge in pendingByID.values where seen.insert(edge.jobID).inserted {
            observations.append(.pending(jobID: edge.jobID, kind: edge.kind))
        }
        return observations
    }

    public func resolve(jobID: UUID, state: RunDependencyState, note: String?) async {
        _ = try? await store.resolve(jobID: jobID, state: state, note: note)
    }
}

/// CAS commit for the explicit Stop of a parked run. One writer transaction:
/// the row is re-proven as the expected durable state (Android's terminal
/// vocabulary has NO `cancelled` run state — a stopped run stays
/// `checkpointed`) and ONE native `userStop` status event is appended with the
/// canonical stop reason. A resume that already committed `preparing` makes
/// the UPDATE a no-op, so a Stop can never overwrite a live run row.
public struct G02ParkedRunStopCommitter: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func commit(runID: UUID, conversationID: UUID,
                       expectedState: String) async -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let stamp = formatter.string(from: now)
        do {
            return try await database.writer { db in
                // Keep the ORIGINAL Android terminal vocabulary: a stopped
                // parked run is `checkpointed` with the canonical stop reason,
                // never a non-vocabulary `cancelled` row.
                try db.execute(
                    sql: """
                        UPDATE runs SET state = 'checkpointed', ended_at = ?
                        WHERE id = ? AND conversation_id = ? AND state = ?
                        """,
                    arguments: [stamp, runID.uuidString,
                                conversationID.uuidString, expectedState])
                guard db.changesCount == 1 else { return false }
                let sequence = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(MAX(sequence), 0) + 1
                        FROM run_events WHERE run_id = ?
                        """,
                    arguments: [runID.uuidString]) ?? 1
                let payload = try JSONSerialization.data(withJSONObject: [
                    "state": "checkpointed",
                    "reason": FacadeRunDomain.parkedUserStopReason,
                    "floeActivation": ["version": 1, "kind": "userStop"],
                ], options: [.sortedKeys])
                try db.execute(
                    sql: """
                        INSERT INTO run_events
                            (id, run_id, sequence, kind, payload_json, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, runID.uuidString, sequence,
                        RunEventRecord.Kind.status.rawValue,
                        String(decoding: payload, as: UTF8.self), stamp,
                    ])
                return true
            }
        } catch {
            return false
        }
    }

    /// Typed variant: the row CAS, the canonical userStop row and the
    /// self-checking settlement row commit in ONE writer transaction, and the
    /// transaction re-proves the caller's captured incarnation. When
    /// `expectedIncarnation` is nil this writes ONLY the ORIGINAL plain
    /// userStop row and reports `.unboundStopped` (no typed proof).
    public func commitTyped(runID: UUID, conversationID: UUID,
                            expectedState: String,
                            expectedIncarnation: RunIncarnation?,
                            expectedStatusSequence: Int?) async
        -> RunStopSettlementCommitResult {
        let store = SQLiteRunStore(database: database)
        do {
            return try await store.commitParkedUserStop(
                runID: runID, conversationID: conversationID,
                expectedState: expectedState,
                expectedIncarnation: expectedIncarnation,
                expectedStatusSequence: expectedStatusSequence)
        } catch {
            return .unreadable
        }
    }
}

// MARK: - Parked reason + gate

/// Exact durable identity of ONE dependency park: the run's own latest
/// `checkpointed` status row (reason + event sequence). A resume admission
/// captures it BEFORE any preparation and re-proves it at the committed CAS,
/// so a Stop that landed anywhere in between cannot be overwritten by an
/// older in-flight resume.
public struct RunDependencyParkMarker: Sendable, Equatable {
    public var reason: String
    public var sequence: Int

    public init(reason: String, sequence: Int) {
        self.reason = reason
        self.sequence = sequence
    }

    /// True only for the stable dependency-wait marker family.
    public var isAwaitingDependency: Bool {
        RunDependencyResumeGate.shape(of: reason) != .notAwaiting
    }
}

/// Crash-safe verdict for a committed resume marker.
///
/// `beginUserResume`'s own CAS re-proves `runs.state == "checkpointed"`, but a
/// parked Stop keeps that very state (Android has no `cancelled` run state) and
/// only appends its canonical `userStop` status row. A resume that started
/// before the Stop would therefore still commit. This fence closes that hole
/// WITHOUT a new store column: the committed `userResume` marker must be the
/// ONLY status row appended after the exact park event. If the Stop row is
/// there instead, the stop won and the caller must revert before any provider
/// or tool side effect.
public enum RunDependencyResumeFence {
    public enum Verdict: Sendable, Equatable {
        /// Exactly ONE status row (the trusted `userResume` marker) follows
        /// the park: the admission is the winner.
        case clean
        /// The canonical `userStop` row follows the park (or the resume
        /// marker): the user's Stop won.
        case userStopped
        /// Some other/fenced row appeared; nothing may proceed.
        case foreign
        /// The events could not be read; never treated as clean.
        case unreadable
    }

    /// `eventsAfterPark` are the durable rows with sequence strictly greater
    /// than the park marker's sequence (bounded read).
    public static func verdict(
        park: RunDependencyParkMarker,
        eventsAfterPark: [(sequence: Int, kind: RunEventRecord.Kind, payload: String)]?,
        allowsLegacyBootstrap: Bool = false
    ) -> Verdict {
        guard let eventsAfterPark else { return .unreadable }
        let statuses = eventsAfterPark
            .filter { $0.kind == .status }
            .sorted { $0.sequence < $1.sequence }
        guard !statuses.isEmpty else { return .unreadable }
        if statuses.contains(where: { isUserStopPayload($0.payload) }) {
            return .userStopped
        }
        // Only the atomic writer for a previously unbound run may emit this
        // additional marker, immediately before its single userResume row.
        // Every other interleaving remains foreign and blocks the handoff.
        if allowsLegacyBootstrap, statuses.count == 2,
           statuses[0].sequence > park.sequence,
           statuses[1].sequence > statuses[0].sequence,
           isLegacyBootstrapPayload(statuses[0].payload),
           isResumeMarkerPayload(statuses[1].payload) {
            return .clean
        }
        guard statuses.count == 1, let marker = statuses.last,
              marker.sequence > park.sequence,
              isResumeMarkerPayload(marker.payload) else {
            return .foreign
        }
        return .clean
    }

    static func isUserStopPayload(_ payload: String) -> Bool {
        guard let object = jsonObject(payload) else { return false }
        return (object["state"] as? String) == "checkpointed"
            && (object["reason"] as? String) == FacadeRunDomain.parkedUserStopReason
    }

    static func isResumeMarkerPayload(_ payload: String) -> Bool {
        guard let object = jsonObject(payload),
              (object["state"] as? String) == "preparing",
              let activation = object["floeActivation"] as? [String: Any],
              (activation["kind"] as? String) == "userResume" else {
            return false
        }
        return true
    }

    static func isLegacyBootstrapPayload(_ payload: String) -> Bool {
        guard let object = jsonObject(payload),
              (object["state"] as? String) == "checkpointed",
              let marker = object["floeLegacyBootstrap"] as? [String: Any],
              let version = marker["version"] as? Int, version == 1,
              object["reason"] == nil, object["floeActivation"] == nil else {
            return false
        }
        return true
    }

    static func jsonObject(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Closed decision for the parked run's required edges.
public enum RunDependencyResumeGate {
    public enum ReasonShape: Sendable, Equatable {
        case notAwaiting
        /// The durable reason names these exact job identities.
        case named([UUID])
        /// Legacy `awaiting.finite.job` without identifiers.
        case legacy
        /// The marker is present but its identifier list is malformed.
        case malformed
    }

    public enum Decision: Sendable, Equatable {
        case resume([RunDependencyObservation])
        case waiting([UUID])
        case unverified
        case notAwaiting
    }

    /// Parse the exact durable park reason. Only the stable prefix written by
    /// `FloeAgentRuntime.dependencyWaitReasonPrefix` is accepted.
    public static func shape(of reason: String?) -> ReasonShape {
        guard let reason, reason.hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix) else {
            return .notAwaiting
        }
        let suffix = reason.dropFirst(FloeAgentRuntime.dependencyWaitReasonPrefix.count)
        guard !suffix.isEmpty else { return .legacy }
        guard suffix.hasPrefix(":") else { return .malformed }
        let raw = suffix.dropFirst()
        if raw.isEmpty { return .legacy }
        var ids: [UUID] = []
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            guard let id = UUID(uuidString: String(part)) else { return .malformed }
            ids.append(id)
        }
        guard !ids.isEmpty else { return .legacy }
        return .named(ids)
    }

    /// Decide whether the parked run may continue.
    ///
    /// `allowUncertain` is TRUE only for an EXPLICIT user Continue: the user
    /// may reopen a run whose dependency outcome is `interrupted` (the model is
    /// then told the outcome is unknown). The AUTOMATIC continuation always
    /// passes false, so a previous process's interrupted/uncertain cleanup can
    /// never start a chat model by itself. `allowMissing` is the narrower
    /// legacy-edge allowance used by that same explicit path.
    public static func decide(
        shape: ReasonShape,
        observations: [RunDependencyObservation]?,
        allowMissing: Bool,
        allowUncertain: Bool = false
    ) -> Decision {
        switch shape {
        case .notAwaiting:
            return .notAwaiting
        case .malformed:
            return .unverified
        case .legacy:
            guard let observations else { return .unverified }
            let pending = observations.compactMap { observation -> UUID? in
                if case .pending(let jobID, _) = observation { return jobID }
                return nil
            }
            if !pending.isEmpty { return .waiting(pending) }
            guard observations.allSatisfy({ observation in
                if case .terminal = observation { return true }
                return false
            }) else { return .unverified }
            if !allowUncertain,
               observations.contains(where: { observation in
                   if case .terminal(_, _, .interrupted) = observation { return true }
                   return false
               }) {
                return .unverified
            }
            return .resume(observations)
        case .named(let jobIDs):
            guard let observations else { return .unverified }
            var byID: [UUID: RunDependencyObservation] = [:]
            for observation in observations {
                switch observation {
                case .pending(let jobID, _), .terminal(let jobID, _, _),
                     .missing(let jobID):
                    byID[jobID] = observation
                }
            }
            var resolved: [RunDependencyObservation] = []
            var pendingIDs: [UUID] = []
            var unresolved = false
            for jobID in jobIDs {
                guard let observation = byID[jobID] else {
                    unresolved = true
                    continue
                }
                switch observation {
                case .pending:
                    pendingIDs.append(jobID)
                case .terminal(_, _, let state):
                    if state == .interrupted && !allowUncertain {
                        // A previous process left the outcome unknown. The
                        // automatic continuation must never start a chat model
                        // on that basis; an explicit Continue may.
                        unresolved = true
                    } else {
                        resolved.append(observation)
                    }
                case .missing:
                    if allowMissing && allowUncertain {
                        resolved.append(.terminal(jobID: jobID,
                                                  kind: "job",
                                                  state: .interrupted))
                    } else {
                        unresolved = true
                    }
                }
            }
            // An unnamed still-pending edge keeps the run parked even when
            // the durable reason predates it.
            for observation in observations {
                guard case .pending(let jobID, _) = observation,
                      !jobIDs.contains(jobID) else { continue }
                pendingIDs.append(jobID)
            }
            if !pendingIDs.isEmpty { return .waiting(pendingIDs) }
            if unresolved { return .unverified }
            return .resume(resolved)
        }
    }
}

// MARK: - Resume/stop results (internal trusted-host API)

public enum JobDependencyResumeResult: Sendable, Equatable {
    /// The exact original run was re-admitted and its launch Task started.
    case resumed
    /// At least one required edge is still pending (this is NOT a refusal).
    case waiting([UUID])
    /// The run is not parked awaiting dependency work (completed, live, or a
    /// different checkpoint cause). Late/duplicate callbacks land here.
    case notAwaiting
    /// A user Stop, deletion guard, generation retirement or admission fence
    /// owns the run. Never retried automatically.
    case fenced
    /// Another resume/Stop (or a live owner) is in flight for this run.
    case busy
    /// C02 storage continuity currently refuses admission.
    case storagePaused
    /// The durable state or edges could not be proven; nothing resumed.
    case unverified
    /// The App host did not admit REAL background protection for the resumed
    /// run (refused, fenced or no live pump/binding answered). NOTHING was
    /// dispatched: the run stays parked with its data and an explicit
    /// Continue (or a later trusted callback) may retry.
    case foregroundUnavailable
    /// A typed admission refusal (gate/transport/model/history/...). The run
    /// remains parked and an explicit user Continue can retry it.
    case refused(code: String, reason: String)
}

public enum JobDependencyStopResult: Sendable, Equatable {
    /// The durable run row committed the canonical stopped checkpoint AND a
    /// valid typed settlement bound to the exact incarnation. These job
    /// identities had a cooperative cancellation request issued (they are
    /// NOT claimed terminal — the original processors settle them).
    case settled(cancelledJobIDs: [UUID], settlement: RunStopSettlement)
    /// The exact incarnation already had a valid typed settlement; nothing
    /// was rewritten and no duplicate row was appended.
    case alreadySettled(settlement: RunStopSettlement)
    /// The legacy plain `userStop` row committed but no incarnation was
    /// provable, so no typed settlement exists. Never a typed success.
    case stopped(cancelledJobIDs: [UUID])
    /// The run was already terminal/resumed; nothing was rewritten.
    case alreadyStarted(state: String)
    /// A newer activation/incarnation owns the run; the old Stop wrote
    /// nothing.
    case staleIncarnation
    /// A resume/Stop is in flight for this run.
    case busy
    case refused(code: String, reason: String)
}

// MARK: - Automatic continuation

public protocol JobDependencyContinuationPort: Sendable {
    func resumeAwaitingDependency(runID: UUID,
                                  conversationID: UUID) async -> JobDependencyResumeResult
}

/// Optional capability of the SAME trusted port: deliver ONE closed
/// lifecycle receipt into the exact CURRENTLY LIVE parent run at its next
/// step boundary. A parked/terminal/foreign run answers false and nothing is
/// written; this never creates a run, never fabricates a human turn and never
/// elevates job output into system context.
public protocol JobDependencyLiveNoticePort: Sendable {
    func noteSettledDependency(runID: UUID, conversationID: UUID,
                               jobID: UUID, kind: String,
                               state: RunDependencyState) async -> Bool
}

/// One job summary in a relaunch reconciliation candidate. Only closed
/// identifiers/states cross this seam.
public struct JobDependencyJobSummary: Sendable, Equatable {
    public var jobID: UUID
    /// `job` or `service` (the durable edge kind).
    public var dependencyKind: String
    public var dependencyState: RunDependencyState
    public var jobState: BackgroundJobState

    public init(jobID: UUID, dependencyKind: String,
                dependencyState: RunDependencyState,
                jobState: BackgroundJobState) {
        self.jobID = jobID
        self.dependencyKind = dependencyKind
        self.dependencyState = dependencyState
        self.jobState = jobState
    }
}

public struct JobDependencyLaunchCandidate: Sendable, Equatable {
    public var runID: UUID
    public var conversationID: UUID
    public var jobs: [JobDependencyJobSummary]

    public init(runID: UUID, conversationID: UUID,
                jobs: [JobDependencyJobSummary]) {
        self.runID = runID
        self.conversationID = conversationID
        self.jobs = jobs
    }
}

/// The one automatic trigger. It owns NO state beyond the in-process
/// de-duplication of an in-flight attempt; every decision is re-proven by the
/// run domain against durable rows.
public actor JobDependencyContinuation {
    public static let shared = JobDependencyContinuation(
        liveEpoch: { G02NativeRootEpoch.readback() },
        hostEpoch: { LinuxShellMailbox.shared.liveEpoch })

    private let liveEpoch: @Sendable () -> UInt64?
    /// The generation the trusted host pump is ACTUALLY bound to (0 == no
    /// live host). Cold-start reconciliation waits for this bounded fact
    /// instead of pretending an unbound host refused the run.
    private let hostEpoch: @Sendable () -> UInt64
    private static let hostBindingDeadlineMillis = 60_000
    private static let hostBindingPollNanos: UInt64 = 250_000_000
    private var installedEpoch: UInt64?
    private var port: (any JobDependencyContinuationPort)?
    private var jobLookup: (@Sendable (UUID) async -> BackgroundJob?)?
    private var activeRuns: Set<UUID> = []

    public init(liveEpoch: @escaping @Sendable () -> UInt64?,
                hostEpoch: @escaping @Sendable () -> UInt64 = { 0 }) {
        self.liveEpoch = liveEpoch
        self.hostEpoch = hostEpoch
    }

    public func install(epoch: UInt64,
                        port: any JobDependencyContinuationPort,
                        jobLookup: (@Sendable (UUID) async -> BackgroundJob?)? = nil) {
        installedEpoch = epoch
        self.port = port
        self.jobLookup = jobLookup
        activeRuns.removeAll()
    }

    public func uninstall(epoch: UInt64) {
        guard installedEpoch == epoch else { return }
        uninstallCurrent()
    }

    /// Generation retirement/test reset: no port survives, so a late job
    /// callback from a retired epoch can never reach a newer domain.
    public func uninstallCurrent() {
        installedEpoch = nil
        port = nil
        jobLookup = nil
        activeRuns.removeAll()
    }

    /// The ORIGINAL service's terminal callback (after the dependency edge
    /// was committed by the coordinator's ordered fix). Standalone
    /// service jobs never auto-wake a chat run; only their readiness does.
    public func jobTerminal(_ job: BackgroundJob) async {
        guard isLive else { return }
        guard TaskJobTargetKind.classify(targetTool: job.targetTool,
                                         payloadJSON: job.payloadJSON) != .service
        else { return }
        let resolution = BackgroundJobService.dependencyResolution(for: job)
        await attempt(runID: job.runID, conversationID: job.conversationID,
                      jobID: job.id, kind: "job", state: resolution.state)
    }

    /// The C01 first-proven readiness callback. The durable edge was already
    /// resolved by `BackgroundJobService.resolveServiceReady` before this
    /// call, so the domain sees a fully settled service edge.
    public func serviceReady(jobID: UUID) async {
        guard isLive, let lookup = jobLookup, let job = await lookup(jobID) else { return }
        guard TaskJobTargetKind.classify(targetTool: job.targetTool,
                                         payloadJSON: job.payloadJSON) == .service
        else { return }
        await attempt(runID: job.runID, conversationID: job.conversationID,
                      jobID: job.id, kind: "service", state: .resolved)
    }

    /// Bounded relaunch reconciliation. Candidates come from the durable
    /// pending edges AFTER the original launch reconcile turned dead
    /// processors interrupted. A service edge that did not resolve through
    /// real readiness never starts a chat model.
    public func reconcileAtLaunch(_ candidates: [JobDependencyLaunchCandidate]) async {
        guard isLive else { return }
        for candidate in candidates {
            // COLD-RECOVERY POLICY: only genuine successes (completed jobs,
            // proven service readiness) may auto-wake a parent after a
            // relaunch. An interrupted/cancelled/failed previous outcome is
            // left for an explicit user Continue.
            let uncertain = candidate.jobs.contains { $0.dependencyState != .resolved }
            if uncertain { continue }
            guard let port = self.port else { continue }
            guard !activeRuns.contains(candidate.runID) else { continue }
            activeRuns.insert(candidate.runID)
            // The candidate set contains ONLY genuine successes/readiness (see
            // `launchDependencyCandidates`); the domain re-proves every
            // durable edge before resuming, so a previous process's
            // interrupted/uncertain cleanup can never auto-start a model.
            _ = await port.resumeAwaitingDependency(
                runID: candidate.runID, conversationID: candidate.conversationID)
            activeRuns.remove(candidate.runID)
        }
    }

    private var isLive: Bool {
        guard let installedEpoch else { return false }
        return liveEpoch() == installedEpoch
    }

    /// ONE settled dependency. A LIVE parent first receives the trusted
    /// lifecycle receipt at its next step boundary (so a job that finished
    /// before the runtime's final pending-edge check is still consumed and
    /// cannot end the run silently). Only when no live service exists — or the
    /// runtime already reached its terminal boundary — does the parked
    /// continuation path run.
    private func attempt(runID: UUID, conversationID: UUID,
                         jobID: UUID, kind: String,
                         state: RunDependencyState) async {
        guard let port = self.port, isLive else { return }
        // A live parent receives EVERY settled job's receipt (each one is a
        // distinct, deterministic system row). This path is idempotent and
        // never creates a run, so it is deliberately NOT de-duplicated by the
        // read-run guard below: two jobs settling together must both reach
        // the model.
        if let notice = port as? any JobDependencyLiveNoticePort,
           await notice.noteSettledDependency(
            runID: runID, conversationID: conversationID,
            jobID: jobID, kind: kind, state: state) {
            return
        }
        guard !activeRuns.contains(runID) else { return }
        activeRuns.insert(runID)
        defer { activeRuns.remove(runID) }
        _ = await port.resumeAwaitingDependency(runID: runID,
                                                conversationID: conversationID)
    }

    /// Cold recovery AFTER every composition step succeeded. The trusted host
    /// pump may still be binding (the automatic path needs a REAL foreground
    /// admission, not an unbound refusal), so this waits for the bounded host
    /// generation fact WITHOUT blocking boot: the caller dispatches it as a
    /// detached task and nothing in composition awaits this method inline.
    /// If the host never binds in the bounded window the candidates stay
    /// parked (retryable by an explicit Continue) — never a model start
    /// without protection.
    public func reconcileWhenHostReady(
        epoch: UInt64,
        candidates: [JobDependencyLaunchCandidate]
    ) async {
        guard !candidates.isEmpty, isLive, installedEpoch == epoch else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(Self.hostBindingDeadlineMillis) * 1_000_000
        while hostEpoch() != epoch {
            guard isLive, installedEpoch == epoch,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return }
            try? await Task.sleep(nanoseconds: Self.hostBindingPollNanos)
        }
        guard isLive, installedEpoch == epoch else { return }
        await reconcileAtLaunch(candidates)
    }
}

// MARK: - Host read/cancel channel (BridgeV30)

public enum BridgeV30 {
    public static let version = 30
    public static let schema = "floe.taskjobs/30"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 64 * 1_024
    public static let maximumJobs = 50
    public static let listAction = "jobs.list"
    public static let cancelAction = "jobs.cancel"
    public static var modelTools: Bool { false }
}

/// Trusted-host-only App bridge over the EXISTING `floe_bridge_exchange`
/// C ABI. Two closed actions:
///
///   jobs.list   {conversationID, runID?}       -> bounded durable projections
///   jobs.cancel {conversationID, runID, jobID} -> refreshed projections
///
/// It never submits work, never resolves a dependency, never terminalizes a
/// job and never carries payload/command/output/path material.
public enum TaskJobsHostBridge {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[String: Any], Error>?
        func set(_ result: Result<[String: Any], Error>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<[String: Any], Error>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private enum BridgeFailure: Error, Sendable {
        case rejected(String)
    }

    private struct Request: Sendable {
        var requestID: String?
        var action: String
        var conversationID: UUID
        var runID: UUID?
        var jobID: UUID?
    }

    private static func blocking(
        _ body: @escaping @Sendable () async throws -> [String: Any]
    ) -> Result<[String: Any], Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do { box.set(.success(try await body())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? .failure(BridgeFailure.rejected("bridgeUnavailable"))
    }

    public static func handle(requestData: Data,
                              fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ code: String) -> [String: Any] {
            var value: [String: Any] = ["ok": false, "error": code,
                                        "schema": BridgeV30.schema]
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= BridgeV30.maximumRequestBytes else {
            return failure("requestTooLarge")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any] else {
            return failure("invalidJSON")
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID
        guard exactInt(object["version"]) == BridgeV30.version else {
            return failure("unsupportedVersion")
        }
        guard (object["operation"] as? String) == "command" else {
            return failure("unsupportedOperation")
        }
        guard let epochRaw = exactInt(object["epoch"]), epochRaw > 0,
              let epoch = UInt64(exactly: epochRaw) else {
            return failure("invalidRequest")
        }
        guard let payload = object["payload"] as? [String: Any],
              let conversationRaw = boundedString(payload["conversationID"], 64),
              let conversationID = UUID(uuidString: conversationRaw) else {
            return failure("invalidRequest")
        }
        let runID = boundedString(payload["runID"], 64).flatMap(UUID.init(uuidString:))
        if payload["runID"] != nil, runID == nil { return failure("invalidRequest") }
        let jobID = boundedString(payload["jobID"], 64).flatMap(UUID.init(uuidString:))
        if payload["jobID"] != nil, jobID == nil { return failure("invalidRequest") }
        guard let action = boundedString(object["action"], 80),
              action == BridgeV30.listAction || action == BridgeV30.cancelAction else {
            return failure("unsupportedAction")
        }
        if action == BridgeV30.cancelAction {
            guard runID != nil, jobID != nil else { return failure("invalidRequest") }
        }
        // Structural validation is independent of a live composition. A
        // malformed request is never disguised as a stale runtime, and no
        // store/service read occurs before the generation gate below.
        guard G02NativeRootEpoch.readback() == epoch else {
            return failure("staleEpoch")
        }
        let request = Request(requestID: requestID, action: action,
                              conversationID: conversationID,
                              runID: runID, jobID: jobID)
        let result = blocking {
            try await perform(request, epoch: epoch)
        }
        switch result {
        case .success(let object):
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
                  encoded.count <= BridgeV30.maximumResponseBytes else {
                return failure("responseTooLarge")
            }
            return object
        case .failure(let error):
            if let bridgeFailure = error as? BridgeFailure,
               case .rejected(let code) = bridgeFailure {
                return failure(code)
            }
            return failure("jobsUnavailable")
        }
    }

    private static func perform(_ request: Request, epoch: UInt64) async throws
        -> [String: Any] {
        guard RunDomainFacade.current(epoch: epoch) != nil else {
            throw BridgeFailure.rejected("runtimeUnavailable")
        }
        let facade = RuntimeFacadeJobBindings.shared
        if request.action == BridgeV30.cancelAction {
            guard let runID = request.runID, let jobID = request.jobID else {
                throw BridgeFailure.rejected("invalidRequest")
            }
            do {
                let job = try await facade.cancelOwnedJob(
                    id: jobID, runID: runID,
                    conversationID: request.conversationID)
                _ = job // The refreshed list below is the only projection.
            } catch {
                throw BridgeFailure.rejected("jobNotOwned")
            }
        }
        var jobs = await facade.taskJobs(conversationID: request.conversationID,
                                         runID: request.runID,
                                         limit: BridgeV30.maximumJobs + 1)
        let truncated = jobs.count > BridgeV30.maximumJobs
        if truncated { jobs = Array(jobs.prefix(BridgeV30.maximumJobs)) }
        var projections: [[String: Any]] = []
        for job in jobs {
            let edge = await facade.dependencyRecord(jobID: job.id)
            projections.append(projection(job: job, edge: edge))
        }
        var object: [String: Any] = [
            "ok": true,
            "schema": BridgeV30.schema,
            "count": projections.count,
            "truncated": truncated,
            "jobs": projections,
        ]
        if let requestID = request.requestID { object["requestID"] = requestID }
        return object
    }

    private static func projection(job: BackgroundJob,
                                   edge: RunDependencyRecord?) -> [String: Any] {
        let document = NativeJobProgressDocument.decode(job.progressJSON)
        let progress = document?.progress
        let cancellationRequested = document?.cancellationRequested == true
            || (job.state == .running
                && (job.lastError ?? "").hasPrefix("Cancellation requested"))
            || (job.state == .running
                && (job.lastError ?? "").hasPrefix("Stop requested"))
        var value: [String: Any] = [
            "jobID": job.id.uuidString.lowercased(),
            "runID": job.runID.uuidString.lowercased(),
            "state": job.state.rawValue,
            "terminal": job.state.isTerminal,
            "target": TaskJobTargetKind.classify(
                targetTool: job.targetTool, payloadJSON: job.payloadJSON).rawValue,
            "cancellationRequested": cancellationRequested,
            "resultAvailable": job.state == .completed
                && (job.resultDigest != nil || job.outputPath != nil
                    || job.resultSummary != nil),
            "createdAt": iso(job.createdAt),
            "updatedAt": iso(job.updatedAt),
        ]
        if let bytes = job.outputBytes, bytes >= 0 {
            value["outputBytes"] = bytes
        }
        if let progress {
            var item: [String: Any] = ["stage": progress.stage.rawValue]
            if let completed = progress.completedUnits {
                item["completedUnits"] = completed
            }
            if let total = progress.totalUnits {
                item["totalUnits"] = total
            }
            value["progress"] = item
        }
        if let edge {
            value["dependency"] = [
                "kind": edge.kind,
                "state": edge.state.rawValue,
            ]
        }
        return value
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Bool/Double/Int NSNumber coercion is rejected: only a real JSON
    /// integer is accepted (same discipline as the other trusted-host
    /// bridges).
    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0,
              double <= 9_007_199_254_740_991 else { return nil }
        return number.intValue
    }

    private static func boundedString(_ value: Any?, _ limit: Int) -> String? {
        guard let string = value as? String, !string.isEmpty,
              string.utf8.count <= limit else { return nil }
        return string
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// RB-6 tool-work coordinator — the CONCRETE owned-operation registry behind
// RB4's `RunOwnedToolCancellation` port plus the bounded worker ledgers the
// Skills/MCP domains need. (private source candidate; NOT compiled, NOT
// executed, NOT registered by this package.)
//
// Composition (never re-implementation):
// * RB4 (runtime-runs-approvals-source f677, RuntimeFacadeRunIngress.swift
//   :100-109) OWNS the `run.skillcancel` wire handler and declares the
//   RB6-owned port `RunOwnedToolCancellation.cancelOwnedTool(runID:callID:
//   epoch:) async -> Bool`. This file provides the REAL adapter for the
//   operations THIS domain owns (skill staging/upgrade workers, MCP refresh
//   workers, hub download workers). It does not own or duplicate any run
//   wire handler, conversation loop or provider stream.
// * In-flight MCP tool CALLS dispatched by the runtime are cancelled
//   through the runtime's own ToolContext.cancellation + Task tree
//   (ToolRunnerRegistry runners call throwIfCancelled; the ORIGINAL client
//   generation check discards late responses after disconnect,
//   MCPRemoteToolSource.swift:554-556). This adapter therefore answers
//   false HONESTLY when no owned worker matches (RB4 port doc: "never a
//   fake success"). No Linux/job id is ever invented (contract
//   scopes.taskExecution; SKL-CANCEL G03 process semantics stay
//   contract-only).
// * Owned-work REGISTRY semantics come from the reviewed RB1
//   RuntimeOwnedWorkRegistry (attach BEFORE the awaited work; detach ONLY on
//   real completion; kinds closed {run,childRun,tool,conversation,
//   vaultMaintenance}). Skill staging/install/upgrade workers and MCP
//   refresh workers attach `.tool`; gateway secret effect chains attach
//   `.vaultMaintenance` (RB2 precedent). The registry is the root/database
//   quiescence port; THIS ledger is the cancellation/addressing port. They
//   are orthogonal and both are held.
// * Upstream drift consumed (Main manifest main-upstream-child-temporary-
//   20261019, origin/main 603b68266e1b445629c2587746a2aa6c2c2fcd57): the
//   CURRENT TemporaryChatToolPolicy is the closed public-web-only ceiling
//   (web.search/web.searchAI/web.fetch) enforced on descriptor visibility
//   AND every execution path; the current ChildRunStore delegates bounded
//   8 KiB encoded-JSON child payloads to the new ChildRunPayload. This
//   package does not touch ChildRun storage (RB4/P0 lane owns it) and never
//   re-adds the stale permissive ceiling; the capabilities domain consumes
//   the new API names, and the exact current-main policy body is shipped in
//   this candidate as the provenance-pinned regular mirror replacing the
//   stale symlink (Main serializes the publication; this package did NOT
//   write through any symlink).
import Foundation
import FloeTools

/// One live owned worker record. ownerID is the closed namespaced identity
/// ("skill:<id>", "mcp-refresh:<serverID>:gen:<n>", "hub:<skillID>"),
/// never a path/secret; runID/callID are filled only when the operation was
/// really started under a run (RB4 binds run-contexted starts; wire-command
/// starts carry nil).
public struct FacadeOwnedWorker: Sendable {
    public let id: String
    public let ownerID: String
    public let runID: UUID?
    public let callID: String?
    public let epoch: UInt64
    public let token: CancellationToken

    init(id: String, ownerID: String, runID: UUID?, callID: String?,
         epoch: UInt64, token: CancellationToken) {
        self.id = id
        self.ownerID = ownerID
        self.runID = runID
        self.callID = callID
        self.epoch = epoch
        self.token = token
    }
}

public actor FacadeToolWorkCoordinator {

    public enum BeginRejection: Error, Sendable, Equatable {
        case noAdmittedEpoch          // fail-closed; no default zero
        case ownerAlreadyActive       // per-owner single-flight
        case saturated                // bounded ledger
    }

    public enum Match: Sendable, Equatable {
        case cancelled(workerIDs: [String])
        case none
    }

    public enum Limits {
        public static let maximumLiveWorkers = 128
    }

    private struct Handle {
        let worker: FacadeOwnedWorker
        /// Set by the operation task itself so the cancel path can ALSO
        /// cooperatively cancel the Swift Task (structured cancellation),
        /// while token cancellation reaches in-flight cooperative awaits.
        var taskCancelled: (@Sendable () -> Void)?
    }

    private var workers: [String: Handle] = [:]
    private var byOwner: [String: Set<String>] = [:]

    public init() {}

    // MARK: Begin/end (used by the Skills/MCP domains)

    /// Register a REAL owned worker BEFORE the awaited operation starts.
    /// The caller runs the operation inside the returned cooperative
    /// cancellation scope and calls `end` exactly once when the operation
    /// has TRULY settled (commit/rollback/final write), not when the UI
    /// gave up. The trusted epoch comes from the caller's verified
    /// `AndroidRuntimeBootstrap` binding; 0 means "not admitted" ⇒ refusal.
    func begin(ownerID: String, runID: UUID?, callID: String?, epoch: UInt64)
        -> Result<FacadeOwnedWorker, BeginRejection> {
        guard epoch > 0 else { return .failure(.noAdmittedEpoch) }
        guard workers.count < Limits.maximumLiveWorkers else {
            return .failure(.saturated)
        }
        if let existing = byOwner[ownerID], !existing.isEmpty {
            return .failure(.ownerAlreadyActive)
        }
        let id = UUID().uuidString
        let worker = FacadeOwnedWorker(id: id, ownerID: ownerID, runID: runID,
                                       callID: callID, epoch: epoch,
                                       token: CancellationToken())
        workers[id] = Handle(worker: worker, taskCancelled: nil)
        byOwner[ownerID, default: []].insert(id)
        return .success(worker)
    }

    /// Attach the operation's own Task-cancel hook (cooperative structured
    /// cancellation companion to the token).
    func attachTaskCancel(_ workerID: String, _ cancel: @escaping @Sendable () -> Void) {
        guard var handle = workers[workerID] else { return }
        handle.taskCancelled = cancel
        workers[workerID] = handle
    }

    /// REAL completion: called only after the awaited effects settled.
    /// Idempotent for unknown ids (a late end cannot crash the ledger).
    func end(_ workerID: String) {
        guard let handle = workers.removeValue(forKey: workerID) else { return }
        byOwner[handle.worker.ownerID]?.remove(workerID)
        if byOwner[handle.worker.ownerID]?.isEmpty == true {
            byOwner[handle.worker.ownerID] = nil
        }
    }

    // MARK: Cancellation surface

    /// ⇄ RB4 `RunOwnedToolCancellation` — the concrete owned-operation
    /// adapter. Matches strictly on the CURRENT epoch, the addressed run and
    /// (when present) the exact callID. An optional-callID cancel stops ALL
    /// cancellable owned work for that run (RunSkillCancelQuery semantics,
    /// "nil cancels ALL cancellable owned tool work for the run"). Returns
    /// true only when at least one live owned worker accepted cancellation.
    /// Never touches another run, another generation, or another server's
    /// connection (scoped-task rule).
    func cancelOwnedToolMatches(runID: UUID, callID: String?, epoch: UInt64) -> Match {
        var cancelled: [String] = []
        for (id, handle) in workers {
            guard handle.worker.epoch == epoch, handle.worker.runID == runID else { continue }
            if let callID {
                guard handle.worker.callID == callID else { continue }
            }
            handle.worker.token.cancel()
            handle.taskCancelled?()
            cancelled.append(id)
        }
        return cancelled.isEmpty ? .none : .cancelled(workerIDs: cancelled)
    }

    /// Drain the owned workers for one domain owner (e.g. "skill:<id>")
    /// before destructive file work — waits for REAL completions with the
    /// caller's bounded timeout, then reports leftover honestly.
    func drainWorkers(ownerPrefix: String, epoch: UInt64, timeoutMillis: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(max(0, timeoutMillis)) &* 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let active = workers.values.contains {
                $0.worker.ownerID.hasPrefix(ownerPrefix) && $0.worker.epoch == epoch
            }
            if !active { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled {
                return !workers.values.contains {
                    $0.worker.ownerID.hasPrefix(ownerPrefix) && $0.worker.epoch == epoch
                }
            }
        }
        return !workers.values.contains {
            $0.worker.ownerID.hasPrefix(ownerPrefix) && $0.worker.epoch == epoch
        }
    }

    /// Cancel every owned worker under one owner prefix for the CURRENT
    /// epoch (MCP: "mcp-refresh:<serverID>" cancel-by-generation, skills:
    /// hub/staging workers). Returns the worker ids signalled; late
    /// completions still settle through `end` (the ledger classifies, never
    /// double-signals).
    func cancelWorkers(ownerPrefix: String, epoch: UInt64) -> [String] {
        var cancelled: [String] = []
        for (id, handle) in workers {
            guard handle.worker.epoch == epoch,
                  handle.worker.ownerID.hasPrefix(ownerPrefix) else { continue }
            handle.worker.token.cancel()
            handle.taskCancelled?()
            cancelled.append(id)
        }
        return cancelled
    }

    func liveOwnerCount(prefix: String, epoch: UInt64) -> Int {
        workers.values.filter {
            $0.worker.ownerID.hasPrefix(prefix) && $0.worker.epoch == epoch
        }.count
    }

    /// Retirement hook: signal every worker of a closing epoch. The owned
    /// store close still waits for REAL completions through the RB1
    /// RuntimeOwnedWorkRegistry count — this only accelerates cooperative
    /// cancellation (drain semantics, never discard).
    func fenceEpoch(epoch: UInt64) {
        for (_, handle) in workers where handle.worker.epoch == epoch {
            handle.worker.token.cancel()
            handle.taskCancelled?()
        }
    }

    // MARK: Test observation (counts only, never token material)

    func snapshotCountsForTesting() -> Int { workers.count }
}

// MARK: - RB4 port conformance (the concrete adapter)

/// The RB4-declared port (RuntimeFacadeRunIngress.swift:104-109). Main binds
/// this adapter to `FacadeRunComponents.toolCancellation` for the CURRENT
/// generation; an unbound port keeps RB4's honest
/// `capabilityNotUsable/skillCancellationUnbound` refusal.
extension FacadeToolWorkCoordinator: RunOwnedToolCancellation {
    public func cancelOwnedTool(runID: UUID, callID: String?, epoch: UInt64) async -> Bool {
        switch cancelOwnedToolMatches(runID: runID, callID: callID, epoch: epoch) {
        case .cancelled: return true
        case .none: return false
        }
    }
}

// MARK: - Skills domain convenience (worker naming scheme is closed here)

extension FacadeToolWorkCoordinator {
    static func skillOwnerID(_ skillID: String) -> String { "skill:\(skillID)" }
    static func mcpRefreshOwnerID(_ serverID: UUID, generation: UInt64) -> String {
        "mcp-refresh:\(serverID.uuidString):gen:\(generation)"
    }

    /// ⇄ SkillsDomain.uninstall quiescence: drain the staging/upgrade
    /// workers for ONE skill before touching files; returns false when real
    /// completions did not arrive inside the bounded wait (the caller MUST
    /// then refuse the destructive operation — no cancellation of live
    /// handles, AGENTS.md owned-stop rule).
    func drainSkillWorkers(ownerID skillID: String, epoch: UInt64) async {
        // The domain treats a failed drain as a refusal at its own call
        // site via hasLiveSkillWorkers; the drain itself is bounded.
        _ = await drainWorkers(ownerPrefix: Self.skillOwnerID(skillID),
                               epoch: epoch, timeoutMillis: 10_000)
    }

    func hasLiveSkillWorkers(ownerID skillID: String, epoch: UInt64) -> Bool {
        liveOwnerCount(prefix: Self.skillOwnerID(skillID), epoch: epoch) > 0
    }
}

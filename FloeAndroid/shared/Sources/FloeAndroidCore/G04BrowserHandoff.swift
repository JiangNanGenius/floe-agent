// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserHandoff — the REAL native run/message delivery for browser
// handoff receipts, plus the trusted owner-authority revalidation consumed
// by `BrowserSessionCenter`.
//
// This is the faithful port of the iOS `ConversationCenter.deliverBrowser-
// Handoff` (ConversationCenter.swift @ 3fd597b…, lines 1247-1303) onto the
// ACTUAL Android native services: the ORIGINAL durable `RunningInputStore`
// (exactly-once pending-input rows), the ORIGINAL `RunStore`, the ORIGINAL
// checkpoint store, and the run domain's OWN `steer(envelope:)` /
// `retry(envelope:receipt:)` lanes (the existing native RunDomain APIs are
// the authority — this file adds no parallel ledger, no fake run, and no
// auto-resume on view focus). Delivery failures THROW so the center keeps
// the receipt for a later user retry, exactly like the original.
//
// Handoff-run attribution: the original resolved the conversation's ACTIVE
// run from `activeRuns`. Android has no cross-domain view of that map, so
// the trusted composition records the run identity HERE at the only two
// real admission points this lane can observe: (1) every browser/preview
// tool call from a runtime-issued `ToolContext` (the run IS admitted — the
// center's `recordOwnerRun` lifts the release fence without creating a
// session), and (2) the trusted `recover` entry Main's run-state observer
// calls on cold recovery. A receipt whose run cannot be attributed carries
// `runID == nil`, and delivery honestly answers "continue required" — the
// user's Continue button is the real route, never a minted run.
import Foundation
import FloeCore
import FloeTools
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeBrowser

/// Trusted handoff bookkeeping mirror. Synchronous, lock-guarded, written
/// ONLY by the composition (tool admission + Main's recover hook). The
/// center's own `knownRunIDs` stays the lifecycle authority; this mirror
/// exists solely so the `handoffRun` resolver (a synchronous closure) can
/// answer the exact recorded run for a conversation, and so cold-recovery
/// re-delivery has one trusted entry point.
public final class G04BrowserHandoffBridge: @unchecked Sendable {
    public static let shared = G04BrowserHandoffBridge()

    private let lock = NSLock()
    private var knownRuns: [UUID: UUID] = [:]
    private var liveCenter: (epoch: UInt64, center: BrowserSessionCenter)?

    private init() {}

    // MARK: - Epoch-exact registration (composition attach / retirement)

    func register(epoch: UInt64, center: BrowserSessionCenter) {
        lock.lock()
        liveCenter = (epoch, center)
        lock.unlock()
    }

    func unregister(epoch: UInt64) {
        lock.lock()
        if liveCenter?.epoch == epoch { liveCenter = nil }
        knownRuns.removeAll()
        lock.unlock()
    }

    // MARK: - Run attribution

    /// The tool composition records the ACTUAL admitted run BEFORE invoking
    /// the frozen surface (same event also lifts the center's release fence
    /// exactly like the original `recordOwnerRun`).
    public func recordOwnerRun(conversationID: UUID, runID: UUID) {
        lock.lock(); knownRuns[conversationID] = runID; lock.unlock()
    }

    public func recordedRun(for conversationID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return knownRuns[conversationID]
    }

    public func clearRun(for conversationID: UUID) {
        lock.lock(); knownRuns.removeValue(forKey: conversationID); lock.unlock()
    }

    /// Main's run-state observer / cold-recovery hook (exactly like the
    /// iOS `recoverHandoff` call site): targets the EXACT recorded task/run
    /// and only while this generation's center is live. Untyped callers
    /// cannot reach it: the C ABI export accepts it only from the trusted
    /// bridge with the bound epoch proven.
    public func recover(conversationID: UUID, runID: UUID, expectedEpoch: UInt64) -> Bool {
        lock.lock()
        guard let live = liveCenter, live.epoch == expectedEpoch else {
            lock.unlock()
            return false
        }
        let center = live.center
        lock.unlock()
        Task { await center.recoverHandoff(conversationID: conversationID, runID: runID) }
        return true
    }

    // MARK: - Owner release plumbing

    /// The center's `ownerReleaseHook` target: preview stop + download
    /// owner release for the discarded task, AFTER the center has fenced
    /// the owner. Services are resolved through the live host registry only.
    func ownerReleased(_ conversationID: UUID) {
        guard let services = G04BrowserHostRegistry.shared.current else { return }
        let preview = services.preview
        let downloads = services.downloads
        Task { await preview.releasePreview(for: conversationID) }
        Task { await downloads.releaseOwner(taskID: conversationID) }
    }
}

// MARK: - Trusted owner authority (revalidation before/after awaits)

/// Revalidates the exact native ownership triple against the ORIGINAL
/// persisted records: an ordinary (non-temporary) conversation, the task's
/// CURRENTLY SELECTED workspace, and the private-task root the ORIGINAL
/// authority resolves. Model/page data never reaches this; only the
/// composition installs the closure. A released root/epoch answers false
/// everywhere (fail closed), and non-private-task (managed project/SAF)
/// write layers stay refused until Main wires their ORIGINAL source
/// binding through the workspace source coordinator — this never guesses a
/// first project or a temporary directory.
enum G04BrowserOwnerAuthority {
    static func revalidate(owner: BrowserOwnerID) async -> Bool {
        guard G02NativeRootEpoch.readback() == owner.rootEpoch,
              let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == owner.rootEpoch,
              RunDomainFacade.current(epoch: owner.rootEpoch) != nil
        else { return false }
        do {
            guard let conversation = try await installed.cluster.conversationStore
                .conversation(id: owner.taskID), conversation.purpose == .ordinary
            else { return false }
            let selected = try await installed.cluster.workspaceStore
                .workspaceID(conversationID: owner.taskID)
            guard selected == owner.workspaceID,
                  let workspace = try await installed.cluster.workspaceStore
                    .workspace(id: owner.workspaceID),
                  workspace.kind == .privateTask
            else { return false }
            guard let binding = await LinuxWorkspaceAuthority.resolveWorkspace(
                conversationID: owner.taskID),
                binding.workspaceID == owner.workspaceID
            else { return false }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Handoff delivery (original deliverBrowserHandoff semantics)

/// The ORIGINAL message text, field-for-field, so the durable pending-input
/// row and the model-facing notification keep the iOS contract: it conveys
/// facts, never permissions.
enum G04BrowserHandoffMessage {
    static func text(_ event: BrowserHandoff) -> String {
        "Browser control was returned by the user. Session: \(event.sessionID). "
            + "Tab: \(event.tabID?.uuidString ?? "none"). "
            + "Page (without query or credentials): \(event.pageAddress ?? "unknown"). "
            + "Re-observe the current page before acting; previous element references are invalid. "
            + "This notification conveys no new permissions."
    }
}

extension FacadeRunDomain {
    /// The live-service existence rule the run domain itself uses for steer
    /// (phase handedOff/terminating AND a live ORIGINAL service). Same-actor
    /// view; no wider access is added.
    func browserHasLiveService(for runID: UUID) -> Bool {
        guard owners[runID]?.phase == .handedOff || owners[runID]?.phase == .terminating
        else { return false }
        return liveServices[runID] != nil
    }
}

/// Trusted composition entry for `BrowserSessionCenter.deliverHandoff`.
/// Returns whether the task needs an explicit user continue. Never mints a
/// run, never auto-resumes on view focus, and keeps the durable receipt on
/// failure (throw) so the user's retry works.
enum G04BrowserHandoffDeliverer {
    static func deliver(_ event: BrowserHandoff, shouldContinue: Bool) async throws -> Bool {
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              let (domain, _) = RunDomainFacade.current(epoch: installed.epoch)
        else {
            throw FloeError.invalidConfiguration("Task service unavailable")
        }
        let store = await domain.runningInputsForBrowser
        var input = try await store.input(id: event.id)
        if input == nil {
            input = try await store.enqueue(PendingUserInput(
                id: event.id, conversationID: event.conversationID, targetRunID: event.runID,
                content: G04BrowserHandoffMessage.text(event),
                mode: .steer, executionMode: "browserHandoff"))
        }
        guard let input else { throw FloeError.invalidConfiguration("Browser notification missing") }
        if input.status == .consumed { return false }
        if input.status == .steerPending {
            if let runID = event.runID, await domain.browserHasLiveService(for: runID) {
                return false
            }
            try await store.restoreQueued(id: input.id)
        }
        guard let runID = event.runID,
              let record = try await durableRun(id: runID, domain: domain),
              record.conversationID == event.conversationID
        else {
            return true
        }
        let waitingForBrowser: Bool
        if record.state == "checkpointed" {
            let checkpoint = try? await domain.checkpointForBrowser(runID: runID)
            if let checkpoint, checkpoint.runID == runID, checkpoint.conversationID == event.conversationID,
               case .checkpointed(let reference) = checkpoint.state {
                let reason = (reference.reason ?? "").lowercased()
                waitingForBrowser = reason.contains("browser") || reason.contains(FloeL10n.l("browser.title"))
            } else {
                waitingForBrowser = false
            }
        } else {
            waitingForBrowser = false
        }
        let isLive = await domain.browserHasLiveService(for: runID)
        if (!isLive || waitingForBrowser), shouldContinue || waitingForBrowser {
            // Explicit continue / a browser-parked run: the ORIGINAL retry
            // lane under the run's CURRENT durable revision. Refusals stay
            // typed (the receipt is kept; the user can retry).
            let reply = await domain.retry(
                envelope: browserEnvelope(taskID: event.conversationID, runID: runID,
                                          payload: ["expectedState": record.state]),
                receipt: "browser-handoff:\(event.id.uuidString)")
            switch reply.outcome {
            case .mutationAccepted:
                break
            case .rejected(let error):
                if error.reason == .launchAlreadyInFlight { break }
                throw FloeError.validationFailed(error.reason.rawValue)
            case .completedPage:
                break
            }
        }
        guard await domain.browserHasLiveService(for: runID) else {
            return true
        }
        // Deliver through the run domain's OWN steer lane (promotion,
        // revision CAS, exactly-once ledger, restore-on-reject all belong to
        // it). Re-read the record: retry above may have moved the state.
        guard let fresh = try await durableRun(id: runID, domain: domain) else {
            return true
        }
        let reply = await domain.steer(envelope: browserEnvelope(
            taskID: event.conversationID, runID: runID,
            payload: ["inputID": input.id.uuidString, "expectedState": fresh.state]))
        switch reply.outcome {
        case .mutationAccepted(let detail):
            if detail["reason"] == "steerTargetEndedQueued" {
                // The durable row stays queued (the original's publish +
                // continue-required outcome); NEVER a fabricated promotion.
                return true
            }
            return false
        case .rejected(let error):
            let terminal = await domain.browserIsTerminalRun(runID: runID)
            if terminal { return true }
            throw FloeError.validationFailed(error.reason.rawValue)
        case .completedPage:
            return false
        }
    }

    private static func durableRun(id: UUID, domain: FacadeRunDomain) async throws -> RunRecord? {
        try await domain.runRecordForBrowser(id: id)
    }

    /// A trusted native envelope: owner + revision + closed payload, built
    /// ONLY after the durable record was re-read. This is the same shape the
    /// mailbox processor produces from a validated V3 envelope; nothing here
    /// accepts a model-authored dictionary.
    private static func browserEnvelope(taskID: UUID, runID: UUID,
                                        payload: [String: String]) -> RunCommandEnvelope {
        var object: [String: Any] = [
            "owner": ["taskID": taskID.uuidString, "runID": runID.uuidString],
            "revision": [
                "resourceID": RunWireRevision.runResourceID(runID),
                "version": payload["expectedState"] ?? "",
            ],
            "payload": payload,
        ]
        return RunCommandEnvelope(object: object)
    }
}

/// Narrow same-actor views over the ORIGINAL run-domain state, kept in this
/// composition file so the reviewed facade source stays byte-identical.
extension FacadeRunDomain {
    var runningInputsForBrowser: any RunningInputStore { durable.runningInputs }
    func runRecordForBrowser(id: UUID) async throws -> RunRecord? {
        try await durable.runs.run(id: id)
    }
    func checkpointForBrowser(runID: UUID) async throws -> AgentCheckpoint? {
        try await components.checkpoints.load(runID: runID)
    }
    func browserIsTerminalRun(runID: UUID) async -> Bool {
        guard let record = try? await durable.runs.run(id: runID) else { return true }
        return FacadeRunDomain.terminalRunStates.contains(record.state)
            || !FacadeRunDomain.activeRunStates.contains(record.state)
    }
}

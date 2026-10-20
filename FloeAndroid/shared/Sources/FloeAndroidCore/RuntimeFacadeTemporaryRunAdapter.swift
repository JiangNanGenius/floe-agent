// SPDX-License-Identifier: MPL-2.0
//
// RB-5 temporary session — the ONLY production implementation of the
// REQUIRED `TemporaryRunDomainPort`, composed over the documented RB4 seam
// (private source candidate; NOT compiled, NOT executed).
//
// ─────────────────────────────────────────────────────────────────────────
// RB4 RECONCILIATION POINT (job-f6772d4de1584403, runtime-runs-approvals-
// source). This is the ONE file in the RB5 package that references RB4-owned
// public types (`RunStartQuery`, `RunPersistenceBundle`,
// `RunExecutionIdentity`, `RunDomainReply`, `RunDomainError`). Main
// reconciles the finalized RB4 API before publication; when the final shape
// changes, ONLY this file (plus the install glue) changes.
//
// Exact consumed seam (RB4 RuntimeFacadeRuns.swift:574-620 + its temporary-
// seam header :74-84):
//   `FacadeRunDomain.start(query:conversationTitle:receipt:conversationID:
//                          bundleOverride:)`
// — the explicit immutable `RunPersistenceBundle` with
//   `identity == .temporary` and the ORIGINAL Ephemeral* stores MUST reach
//   the service BEFORE its first await (frozen identity, never re-inferred
//   from durable rows afterwards).
//
// RB4 requirements this composition depends on (handoff checklist — RB4's
// own package owns the implementation; RB5 never fakes it):
//   T1. Wire handlers for run.start/run.startTask never pass
//       `bundleOverride`; the temporary presentation reaches `start` ONLY
//       through this port, with `conversationID: nil` (create-intent shape)
//       so the durable `ordinaryExists` proof is skipped and
//       `EphemeralRunLaunchStore.prepare` performs the real hosted-identity
//       validation (`Launch identity does not match the temporary session`
//       is the original fail-closed rule).
//   T2. For `bundle.identity == .temporary`, `createdConversation` in the
//       prepared result must NOT trigger any durable workspace/settings/
//       title side effect: the virtual private `WorkspaceRecord` stays
//       in-RAM exactly like the original ephemeral launch store guarantees.
//   T3. Service assembly sets `Configuration.temporaryReadOnly = true` and
//       intersects `hostToolCeiling` with the frozen public-web ceiling
//       (never widening); the credential normalizer stays nil ONLY for
//       temporary (original policy), and captured-secret ordinary refusal
//       semantics keep their vault-bound form for ordinary runs.
//   T4. Intelligence/memory/personalization feed hooks NEVER fire from a
//       temporary bundle (RB4 header already states this; the frozen
//       provenance in the Keep receipt is the cross-package truth).
//   T5. Explicit cancellation: the `cancel` closure below is bound by the
//       host glue to the ORIGINAL `ConversationRunService.cancel()` +
//       owned-task cancellation for the exact run id; RB4 detaches its RB1
//       tokens only at REAL completion/final writes — never here.
// ─────────────────────────────────────────────────────────────────────────
import Foundation

public struct RuntimeFacadeTemporaryRunAdapter: TemporaryRunDomainPort {

    /// The REAL RB4 launch entry, injected by the host glue over the live
    /// generation's `FacadeRunDomain` actor. Never a noop, never a
    /// simulated stream: no binding means no adapter, which means the RB5
    /// install refuses and `temp` presentation stays typed-unavailable.
    public typealias Launch = @Sendable (
        _ query: RunStartQuery,
        _ conversationTitle: String,
        _ receipt: String?,
        _ conversationID: UUID?,
        _ bundleOverride: RunPersistenceBundle
    ) async -> RunDomainReply

    /// Explicit owned-run cancel dispatch for one temporary run id (T5).
    public typealias Cancel = @Sendable (_ runID: UUID, _ epoch: UInt64) async -> Void

    /// Live-ownership observation over the run domain's real ownership map.
    public typealias HasLive = @Sendable (_ runID: UUID, _ epoch: UInt64) async -> Bool

    /// Resolves the selected model into the ORIGINAL provider/model pair
    /// for a launch (the trusted host's model-route authority; nil when
    /// the route is not configured — the launch is then refused typed,
    /// never guessed or defaulted to a first provider).
    public typealias ModelRoute = @Sendable (_ preferredModelID: UUID?) async
        -> (providerID: UUID, modelID: UUID)?

    public let epoch: UInt64
    private let launch: Launch
    private let cancel: Cancel
    private let hasLive: HasLive
    private let modelRoute: ModelRoute
    /// Session ownership proof into the RB5 domain (anti-TOCTOU across the
    /// await: the launch is admitted only while the SAME incarnation is
    /// live; enforced by the caller-side re-check in
    /// `FacadeTemporaryDomain.temporaryLaunch` — the adapter keeps the
    /// invariant documented, it does not duplicate the tombstone).

    public init(epoch: UInt64, launch: @escaping Launch,
                cancel: @escaping Cancel, hasLive: @escaping HasLive,
                modelRoute: @escaping ModelRoute) {
        self.epoch = epoch
        self.launch = launch
        self.cancel = cancel
        self.hasLive = hasLive
        self.modelRoute = modelRoute
    }

    // MARK: TemporaryRunDomainPort

    public func launchTemporary(_ request: TemporaryLaunchRequest) async
        -> TemporaryLaunchReply {
        // Immutable temporary identity + the ORIGINAL ephemeral bundle,
        // assembled here and handed to `start` before its first await.
        let bundle = RunPersistenceBundle(
            identity: .temporary,
            conversations: request.stores.conversations,
            runs: request.stores.runs,
            runningInputs: request.stores.runningInputs,
            launches: request.stores.launches,
            childRuns: nil,      // RB5 decision: children stay in-memory
                                 // (original DelegateTool semantics; no
                                 // durable child rows while temporary)
            intelligence: nil)   // goal mode refused at admission (T2)
        guard let mode = RunLaunchMode(rawValue: request.mode),
              mode != .goal else {
            return .refused(TemporaryDomainError(.capabilityUnavailable,
                                                 .goalModeUnsupportedStore))
        }
        guard let pair = await modelRoute(request.preferredModelID) else {
            return .refused(TemporaryDomainError(.needsConfiguration,
                                                 .modelRouteUnresolved))
        }
        // Goal mode without an intelligence store is refused HERE and in
        // the domain before this point; the ephemeral launch store also
        // fails a mode it does not know (original validation).
        var query = RunStartQuery(
            conversationID: request.conversationID,
            goal: request.goal,
            mode: mode,
            providerID: pair.providerID,
            modelID: pair.modelID)
        // The frozen per-session public-web ceiling rides the ORIGINAL
        // host-authored ceiling slot (intersection-only; the runtime still
        // re-validates EVERY main/child call through
        // Configuration.temporaryReadOnly — the ceiling is not the fence).
        query.hostToolCeiling = request.frozenToolCeiling.sorted(by: <)

        let reply = await launch(query, "", request.receipt,
                                 nil, bundle)   // T1: create-intent shape
        switch reply.outcome {
        case .mutationAccepted(let detail):
            guard let raw = detail["runID"], let runID = UUID(uuidString: raw),
                  detail["launched"] == "true" else {
                // A success string without the REAL minted run id is not a
                // launch — classify, never trust.
                return .refused(TemporaryDomainError(.internalError, .internal))
            }
            return .launched(runID: runID)
        case .rejected(let error):
            return .refused(Self.mapRunRefusal(error))
        case .completedPage:
            // Launch never answers with a page; shape violation is typed.
            return .refused(TemporaryDomainError(.internalError, .internal))
        }
    }

    public func cancelTemporaryRun(conversationID: UUID, incarnation: UUID,
                                   runID: UUID, epoch: UInt64) async {
        // Dispatch-only (see port contract): the run owner performs its own
        // explicit service close and detaches its owned-work tokens after
        // the REAL final writes. We never detach on its behalf and never
        // wait with a timeout.
        await cancel(runID, epoch)
    }

    public func hasLiveTemporaryRun(conversationID: UUID, incarnation: UUID,
                                    runID: UUID) async -> Bool {
        // Honest observation of the run domain's REAL ownership map for
        // the exact run id under the accepted epoch. Never used for
        // fencing — the synchronous tombstone is the authority.
        await hasLive(runID, epoch)
    }

    /// Closed mapping of an RB4 launch refusal into the temporary domain's
    /// typed vocabulary (the host glue round-trips it back to the run
    /// command's terminal; nothing here silences or reclassifies upward).
    static func mapRunRefusal(_ error: RunDomainError) -> TemporaryDomainError {
        switch error.code {
        case .sessionFenced:
            return TemporaryDomainError(.invalidState, .generationRetired)
        case .needsConfiguration:
            return TemporaryDomainError(.needsConfiguration, .runDomainUnbound)
        case .unsupportedRole, .capabilityNotUsable:
            return TemporaryDomainError(.capabilityUnavailable, .ceilingEmpty)
        case .persistenceUnavailable:
            return TemporaryDomainError(.persistenceUnavailable, .storeWriteFailed)
        case .invalidState:
            return TemporaryDomainError(.invalidState, .payloadInvalid)
        case .duplicateInFlight:
            return TemporaryDomainError(.duplicateInFlight, .keepAlreadyInFlight)
        case .notFound, .staleRevision:
            // The hosted conversation is proven by the ephemeral launch
            // store; a notFound here means the RAM identity vanished —
            // the session was destroyed across the await.
            return TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)
        case .credentialUnavailable, .transportUnavailable, .gateFailClosed,
             .payloadTooLarge, .internalError:
            return TemporaryDomainError(.capabilityUnavailable, .ceilingEmpty)
        }
    }
}

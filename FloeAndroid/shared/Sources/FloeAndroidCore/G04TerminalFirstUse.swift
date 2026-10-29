// SPDX-License-Identifier: MPL-2.0
//
// G04TerminalFirstUse — RUN-LESS first-use workspace preparation for one
// EXPLICIT human terminal action (Android G05-R3, job-e2e7d046b63744cc).
//
// Evidence status, stated truthfully: the gap below is SOURCE-confirmed (Main
// review 2026-10-28, `r3/linux-product80/HANDOFF.md`, and the accepted83
// limitation "Fresh/no-provider/runless terminal entry still needs actual App
// check"). It has NOT been reproduced on a fresh no-provider device by this
// lane, and nothing here claims a device result.
//
// The gap: a genuinely new ordinary task has NO workspace binding row
// (production `RuntimeFacadeConversations` is built with
// `bindsNewConversationsToDefaultWorkspace = false` and `create` assigns
// ownership only when that flag is true), and the two receipt-backed readiness
// facts `workspaceMappingSynced` / `leaseAuthorityQualified` are produced ONLY
// by the first ordinary MODEL run's preflight
// (`FacadeRunDomain.linuxWorkspaceFirstUsePreflight`, whose sole invocation is
// `makeService` after run preparation). So a no-provider user can install
// everything and still never open a terminal: `G04TerminalStore.open` refuses
// before it ever reaches `beginG04WorkspaceOperation`.
//
// What this file adds — and what it deliberately does NOT add:
//  * The producer is the SAME trusted host work over the ORIGINAL
//    `LinuxShellMailbox` (no new Core ABI entry, no model route, no parallel
//    mailbox, no new public/model-visible tool): operation
//    `host.terminalWorkspacePreflight` carries the trusted UI operation-lease
//    identity the Swift host registered in-process for THIS explicit action,
//    the native-issued UI interaction identity, the real conversation and the
//    accepted Root epoch. The host performs the SAME NON-EXECUTING
//    import/faithful-mirror export preflight on the ORIGINAL grant/lease
//    authorities (`CoreWorkspaceGrant.create(trustedOperationID:)`, the G04-R2
//    operation-scoped mint the interactive terminal's own `shell.start`
//    already uses), ingests the real mapping + lease facts and activates
//    registration. Nothing here spawns a process, installs a package, shells
//    out locally, probes the guest or executes a command.
//  * A model Run is NEVER fabricated: no run row, no run-store write, no
//    `BridgeV3.taskExecution` scope, no provider or model configuration read.
//    This lane's host reply carries NO `runID` key at all, so a native-issued
//    UI identity can never be mistaken for a model run.
//  * No echo trust: a `ready` reply qualifies nothing by itself. Core re-reads
//    its OWN live ingress (`derivedFields()` mapping + lease) AND
//    `RuntimeFacadeLinuxBindings.shared.isCapabilityQualified`.
//  * Warm re-entry does nothing: when the two produced facts already live, the
//    rule answers `skipAlreadyQualified` and NO request is submitted.
//  * PHYSICAL ownership, not waiter completion (Main review 2026-10-28):
//    `LinuxShellMailbox`'s continuation — and even the host's `complete` of a
//    claim — can happen while the pump still owns real import/export IO
//    (`unavailable`/`cancelled` are answered BEFORE its own reconciliation
//    proves the peer terminal; `close_retained` answers with a failed drained
//    grant close; `close()`/`bind()` drop claimed tickets while the ORIGINAL
//    fence contract says owned workers are NOT ended and remote leases stay
//    owned). So the lease is discharged ONLY by the host's OWN asserted
//    physical-settlement fact (`ownershipReleased`) or by an explicit
//    per-request observation of the pump's ownership table
//    (`host.terminalPreflightOwnership`, a pure read). Bare absence, a fence,
//    an evicted ring entry, elapsed time and cancellation all RETAIN; only a
//    sticky host completion or an exact owned -> released sequence proves the
//    same host entry really settled.
//  * No widening: the five prerequisites still gate the attempt, the scoped
//    grant / real operation-lease registries are used exactly as they are,
//    request + Root-epoch binding is unchanged, and every refusal is inert and
//    retained (the next explicit action issues its own bounded request; there
//    is no hidden retry loop here).
import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

// MARK: - Closed refusal vocabulary

/// The bounded tokens this lane can answer. They ride the EXISTING terminal
/// `actionReply.reason` field (the pane shows one short sentence and puts the
/// token in its opened details), so every member is short printable ASCII and
/// none carries a path, digest, command or reply body.
public enum G04TerminalFirstUseCode: String, Sendable, Equatable {
    /// No live accepted Root generation to prepare against.
    case epochNotLive
    /// The five transport/rootfs/workload prerequisites are not all live: the
    /// honest answer is "finish the runtime setup", never a bootstrap guess.
    case prerequisitesUnverified
    /// The two produced facts already live but the composed/injected readiness
    /// still says no: a preparation round trip cannot add anything, so none is
    /// submitted (no redundant import).
    case capabilityNotQualified
    /// `beginG04WorkspaceOperation` refused (retirement/global fence, the
    /// task's delete guard, or the owned-work registry): no real conversation
    /// lease, no preparation.
    case leaseUnavailable
    /// `LinuxWorkspaceAuthority.registerWorkspaceOperation` refused (authority
    /// not installed, generation moved, foreign token epoch, live table full).
    case operationRegistrationRefused
    /// The ORIGINAL store refused the genuine private-task workspace binding.
    /// Its own serialized transaction rolled back: no row, no partial write,
    /// no guessed location.
    case workspaceBindingFailed
    /// Defensive: our own closed request could not be built.
    case requestMalformed
    /// Mailbox not bound to an accepted epoch.
    case engineUnbound
    /// Mailbox bounds exceeded: the request definitely did not reach the host.
    case mailboxSaturated
    /// The typed request could not fit the frozen wire bound.
    case payloadTooLarge
    /// The mailbox generation was fenced while this request waited.
    case engineFenced
    /// The bounded wait expired. The claimed ticket — and therefore this
    /// action's grant/receipt — stays owned until its REAL settlement.
    case budgetExpired
    /// The host answered `unavailable`; `detail` carries its bounded token.
    case hostUnavailable
    /// The host answered `cancelled`, or this action was cancelled.
    case cancelled
    /// The reply described a different operation/generation: discarded.
    case replyIdentityMismatch
    /// The reply was not a well-formed frame for this lane.
    case replyMalformed
    /// The host reported ready but Core's OWN live state disagrees.
    case unqualifiedAfterPreflight
    /// The Root generation moved while the preparation was in flight.
    case generationMoved
    /// The conversation lease was cancelled (task deletion fence / retirement)
    /// while the preparation was in flight: nothing may open afterwards.
    case leaseCancelled
}

// MARK: - Pure admission rule

/// The single decision point for "does THIS explicit action need a run-less
/// first-use preparation?". Pure and total so the authored regressions pin the
/// real production seam (warm reuse, honest prerequisites, no redundant
/// import) instead of mirroring strings.
public enum G04TerminalFirstUseRule {

    public enum Decision: Sendable, Equatable {
        /// The lane is live and qualified: reuse it, submit nothing.
        case skipAlreadyQualified
        /// Prerequisites are live and only the two receipt-backed facts are
        /// missing: one bounded NON-EXECUTING preparation is allowed.
        case prepare
        /// Nothing may be attempted; the token says why, honestly.
        case refuse(G04TerminalFirstUseCode)
    }

    /// `fields` is the live derived ingress snapshot; `capabilityQualified` is
    /// the SAME single authority the terminal admission reads
    /// (`RuntimeFacadeLinuxBindings.isCapabilityQualified`).
    public static func decision(fields: LinuxShellQualificationFields,
                                capabilityQualified: Bool) -> Decision {
        if fields.workspaceMappingSynced && fields.leaseAuthorityQualified {
            // Both produced facts already live. Either the lane is qualified
            // (warm reuse) or some OTHER composition/readiness truth is
            // missing — preparing again could not change either answer, so no
            // request is submitted.
            return capabilityQualified
                ? .skipAlreadyQualified
                : .refuse(.capabilityNotQualified)
        }
        // The FIVE prerequisites are what a preparation consumes; mapping and
        // lease are what it PRODUCES, so they must not gate it.
        guard fields.runtimeUidBoundaryVerified, fields.engineConnected,
              fields.mailboxEpochBound, fields.rootfsQualified,
              fields.singleWorkloadContractAcknowledged else {
            return .refuse(.prerequisitesUnverified)
        }
        return .prepare
    }

    // MARK: Genuine workspace-binding eligibility

    public enum BindingEligibility: Sendable, Equatable {
        /// A durable ORDINARY conversation of the exact live generation with no
        /// binding yet: the genuine private-task workspace may be created
        /// through the ORIGINAL store operation.
        case eligible
        /// A real binding already exists: it is returned untouched, never
        /// re-pointed, never replaced by a guessed layer.
        case alreadyBound
        /// Nothing may be written or prepared here (a temporary chat has no
        /// persisted row by design; notes/foreign identities, a dead
        /// generation, an unreadable ownership row and an explicit foreign
        /// workspace expectation all land here). The caller keeps the ORIGINAL
        /// admission and its ORIGINAL honest refusal.
        case notEligible
    }

    /// Pure eligibility for the run-less creation of the genuine persisted
    /// private-task binding. Every input is a real read from the ORIGINAL
    /// stores/generation authority; nothing is inferred and there is no
    /// first-project, temp-directory or fabricated-run branch at all.
    public static func bindingEligibility(conversationPersisted: Bool,
                                          purposeOrdinary: Bool,
                                          generationLive: Bool,
                                          bindingKnown: Bool,
                                          alreadyBound: Bool,
                                          foreignWorkspaceExpectation: Bool) -> BindingEligibility {
        guard conversationPersisted, purposeOrdinary, generationLive else { return .notEligible }
        guard bindingKnown, !foreignWorkspaceExpectation else { return .notEligible }
        return alreadyBound ? .alreadyBound : .eligible
    }
}

// MARK: - Closed request shapes

/// The request grammar for the run-less preparation. CLOSED: exactly these four
/// keys, no `environmentID` (the terminal resolves its layer from the ORIGINAL
/// persisted workspace binding and this lane never guesses an environment), no
/// command, no path and no model/provider field.
public enum G04TerminalFirstUseRequest {
    /// The trusted INTERNAL host operation name (ORIGINAL mailbox lifecycle).
    public static let operation = "host.terminalWorkspacePreflight"
    public static let closedKeys: Set<String> =
        ["operationID", "uiRunID", "conversationID", "rootEpoch"]

    /// Deterministic sorted-key encoding, or nil when the identity is unusable
    /// (epoch 0). Canonical UPPER-CASE `UUID.uuidString` bytes only — the same
    /// grammar the host fences with `isCanonicalUUID`.
    public static func payload(operationID: UUID, uiRunID: UUID,
                               conversationID: UUID, rootEpoch: UInt64) -> Data? {
        guard rootEpoch > 0 else { return nil }
        let request: [String: Any] = [
            "operationID": operationID.uuidString,
            "uiRunID": uiRunID.uuidString,
            "conversationID": conversationID.uuidString,
            "rootEpoch": rootEpoch,
        ]
        guard Set(request.keys) == closedKeys,
              JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request,
                                                      options: [.sortedKeys]) else { return nil }
        return data
    }
}

/// The pure-read ownership observation for ONE exact preparation identity. It
/// asks the trusted host whether its OWN preflight ownership table still holds
/// this identity — the only honest way to learn that real import/export IO
/// finished after an uncertain reply, a released waiter or a generation fence.
/// It carries the same closed four keys; `rootEpoch` is the ENTRY's epoch (the
/// identity being asked about), which need not be the live one.
public enum G04TerminalFirstUseOwnershipQuery {
    public static let operation = "host.terminalPreflightOwnership"
    public static let closedKeys: Set<String> = G04TerminalFirstUseRequest.closedKeys

    public static func payload(operationID: UUID, uiRunID: UUID,
                               conversationID: UUID, queryEpoch: UInt64) -> Data? {
        G04TerminalFirstUseRequest.payload(operationID: operationID, uiRunID: uiRunID,
                                           conversationID: conversationID, rootEpoch: queryEpoch)
    }

    public enum Answer: Sendable, Equatable {
        /// The host's own table no longer holds this identity: the real IO
        /// settled (or its ownership was really discharged).
        case released
        /// Still owned: real IO may be in flight. Retain.
        case owned
        /// No trustworthy answer (refusal, fence, malformed, unmatched echo).
        /// Retain — never a release on absence.
        case unobservable
    }

    /// Strict, total parse. BOTH answers echo THIS exact identity and ENTRY
    /// epoch. A bare `released` is not accepted: table absence can otherwise
    /// mean "the original request has not registered yet". The ownership
    /// holder additionally requires either the original claim's sticky
    /// host-settled fact or a prior exact `owned` observation before absence
    /// may release anything.
    public static func parse(_ data: Data,
                             maximumFrameBytes: Int,
                             operationID: UUID,
                             uiRunID: UUID,
                             conversationID: UUID,
                             queryEpoch: UInt64) -> Answer {
        guard data.count <= maximumFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String,
              (object["queryEpoch"] as? NSNumber)?.uint64Value == queryEpoch,
              (object["operationID"] as? String) == operationID.uuidString,
              (object["uiRunID"] as? String) == uiRunID.uuidString,
              (object["conversationID"] as? String) == conversationID.uuidString else {
            return .unobservable
        }
        switch status {
        case "released": return .released
        case "owned": return .owned
        default: return .unobservable
        }
    }
}

// MARK: - Strict reply parsing

/// The reply grammar, parsed strictly and totally. A reply that describes
/// another operation, another generation or an unmeasured digest is
/// `replyIdentityMismatch`/`replyMalformed` — it can never qualify this action.
public enum G04TerminalFirstUseReply {

    public enum Outcome: Sendable, Equatable {
        /// The host reported ready AND echoed this exact identity with real
        /// measured digests. This alone qualifies nothing: the caller must
        /// re-read Core's own live state. `ownershipReleased` is the host's OWN
        /// physical-settlement assertion (a `ready` reply is only produced
        /// after its drained grant close really succeeded).
        case ready(indexDigest: String, leaseDigest: String, ownershipReleased: Bool)
        /// Typed host refusal; `detail` is the host's own bounded token and
        /// `ownershipReleased` says whether the host really discharged its
        /// ownership (false keeps the lease attached).
        case refused(detail: String, ownershipReleased: Bool)
        /// The host reported this request cancelled.
        case cancelled(ownershipReleased: Bool)
        /// Anything else.
        case malformed(G04TerminalFirstUseCode)
    }

    public static func parse(_ data: Data,
                             maximumFrameBytes: Int,
                             expectedEpoch: UInt64,
                             operationID: UUID,
                             uiRunID: UUID,
                             conversationID: UUID) -> Outcome {
        guard data.count <= maximumFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed(.replyMalformed)
        }
        // Identity + generation FIRST: a frame for another operation, another
        // task or an older Root is discarded whatever its status says.
        guard (object["rootEpoch"] as? NSNumber)?.uint64Value == expectedEpoch,
              (object["operationID"] as? String) == operationID.uuidString,
              (object["uiRunID"] as? String) == uiRunID.uuidString,
              (object["conversationID"] as? String) == conversationID.uuidString else {
            return .malformed(.replyIdentityMismatch)
        }
        // STRICT bool, fail closed: a missing or non-bool ownership fact is
        // treated as NOT released, so an older/foreign host can never discharge
        // a lease by omission.
        let released = (object["ownershipReleased"] as? Bool) == true
        switch object["status"] as? String {
        case "ready":
            guard let indexDigest = object["workspaceIndexDigest"] as? String,
                  isHex64(indexDigest),
                  let leaseDigest = object["leaseProofDigest"] as? String,
                  isHex64(leaseDigest),
                  (object["shellRegistered"] as? Bool) == true else {
                return .malformed(.replyMalformed)
            }
            return .ready(indexDigest: indexDigest, leaseDigest: leaseDigest,
                          ownershipReleased: released)
        case "cancelled":
            return .cancelled(ownershipReleased: released)
        case "unavailable":
            return .refused(detail: boundedToken(object["reason"] as? String),
                            ownershipReleased: released)
        default:
            return .malformed(.replyMalformed)
        }
    }

    /// The host's own bounded stage grammar (<=32 characters from the closed
    /// token alphabet); anything else degrades to a fixed token instead of
    /// riding free text.
    static func boundedToken(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.count <= 32 else { return "hostUnavailable" }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "hostUnavailable"
        }
        return raw
    }

    static func isHex64(_ text: String) -> Bool {
        text.count == 64
            && text.unicodeScalars.allSatisfy { $0.properties.isHexDigit }
    }
}

// MARK: - Pure release rule

/// WHEN one preparation's ownership (the registered UI operation mapping plus
/// the real `.conversation` receipt) may be discharged. Pure and total, and
/// deliberately one-sided: only a PROVEN physical end releases.
public enum G04TerminalFirstUseReleaseRule {

    public enum Decision: Sendable, Equatable {
        case releaseNow
        case retainAndObserve
    }

    /// `settlement` is the mailbox's own per-ticket truth (nil when nothing was
    /// ever submitted); `hostOwnershipReleased` is the host's asserted
    /// physical-settlement fact from its reply (false when there was no reply,
    /// an uncertain reply, or a reply without the fact).
    public static func decision(settlement: LinuxShellMailboxRequest.Settlement?,
                                hostOwnershipReleased: Bool) -> Decision {
        switch settlement {
        case .none:
            // Nothing was ever submitted: no host ownership can exist.
            return .releaseNow
        case .retiredUnclaimed:
            // Provably never reached the host (retired while queued).
            return .releaseNow
        case .hostSettled:
            // The host answered this exact claim. Only its OWN physical fact
            // discharges the lease: `unavailable`/`cancelled`/`close_retained`
            // are answered while the pump may still own the reconciliation.
            return hostOwnershipReleased ? .releaseNow : .retainAndObserve
        case .live:
            // The mailbox still owns the ticket: real IO may be in flight.
            return .retainAndObserve
        case .generationFenced:
            // `close()`/`bind()` drop claimed tickets, and the ORIGINAL fence
            // contract states owned workers are NOT ended and remote leases
            // stay owned until real release. A fence is not settlement.
            return .retainAndObserve
        case .unknown:
            // Gone without a recorded terminal while the same generation is
            // live (an evicted ring entry): absence is not evidence.
            return .retainAndObserve
        }
    }
}

// MARK: - Exactly-once ownership over physical settlement

/// Holds ONE preparation's ownership — the registered UI operation mapping and
/// the real `.conversation` receipt — until the host's OWN physical settlement
/// is observed, then releases exactly once.
///
/// This is the primitive Main's 2026-10-28 review required. A released waiter
/// is not settlement; a completed claim is not settlement either (the pump
/// answers uncertain/cancelled/`close_retained` before its reconciliation
/// proves the peer terminal); and a generation fence explicitly does not end
/// owned workers. So the release is tied to the host's asserted fact and, when
/// that fact is absent or negative, to an explicit per-request observation of
/// the pump's ownership table. No global drain, no elapsed-time success, no
/// view-owned task, no fabricated stop and no readiness bit is touched here.
public final class G04TerminalFirstUseOwnership: @unchecked Sendable {

    /// One observation of the host's own ownership table.
    public enum Observation: Sendable, Equatable {
        case released
        case owned
        case unobservable
    }

    /// The two release steps in the ORIGINAL order: the workspace-authority
    /// operation mapping first, then the domain conversation lease. Production
    /// passes `LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID:)`
    /// and `FacadeRunDomain.endG04WorkspaceOperation(receipt)`; both are
    /// idempotent, and this type guarantees they run exactly once.
    public typealias Release = @Sendable () async -> Void
    public typealias Observe = @Sendable () async -> Observation

    private let lock = NSLock()
    private var performed = false
    /// Sticky proof that the host's OWN table really held this exact identity.
    /// A later exact `released` absence can then only be that entry's drained
    /// removal, never the pre-registration empty-table race.
    private var observedOwned = false
    private let release: Release

    /// The submitted request whose ticket state feeds the release rule, or nil
    /// when nothing was ever submitted (a pre-submit refusal).
    public let request: LinuxShellMailboxRequest?
    /// The host's OWN physical-settlement assertion, exactly as parsed
    /// (fail-closed false when absent).
    public let hostOwnershipReleased: Bool

    public init(request: LinuxShellMailboxRequest?,
                hostOwnershipReleased: Bool,
                release: @escaping Release) {
        self.request = request
        self.hostOwnershipReleased = hostOwnershipReleased
        self.release = release
    }

    /// Synchronous claim-once (the accepted90 shape): the lock is NEVER held
    /// across an await, so Swift 6 object compilation cannot reject it.
    private func claimRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if performed { return false }
        performed = true
        return true
    }

    /// Releases exactly once. True only for the call that actually performed
    /// it, so a caller can prove single release; WHEN to release is decided by
    /// [decision], ONCE is this type's job.
    public func releaseOnce() async -> Bool {
        guard claimRelease() else { return false }
        await release()
        return true
    }

    private func hasReleased() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return performed
    }

    private func noteOwnedObservation() {
        lock.lock()
        observedOwned = true
        lock.unlock()
    }

    /// Empty-table absence is meaningful ONLY after this request was really
    /// represented on the host. Two independent proofs are accepted:
    ///  1. the ORIGINAL mailbox claim is sticky host-settled; or
    ///  2. an earlier pure read observed this exact entry `owned`.
    /// Without either, `released` can be the dangerous pre-registration race.
    private func canReleaseOnObservedAbsence() -> Bool {
        lock.lock()
        let owned = observedOwned
        lock.unlock()
        return owned || request?.settlement == .hostSettled
    }

    /// The pure retention decision for RIGHT NOW.
    public var decision: G04TerminalFirstUseReleaseRule.Decision {
        if hasReleased() { return .releaseNow }
        return G04TerminalFirstUseReleaseRule.decision(settlement: request?.settlement,
                                                       hostOwnershipReleased: hostOwnershipReleased)
    }

    public var mustRetain: Bool { decision == .retainAndObserve }

    /// Retains until physical release is proven, then releases exactly once.
    /// Bounded polls; never releases on elapsed time, a generation fence, an
    /// evicted ring entry, a failed observation or a cancellation. In
    /// particular a bare empty-table answer cannot win the pre-registration
    /// race: release needs sticky host completion or an `owned -> released`
    /// sequence for the same exact host entry. `.released` is returned ONLY
    /// after the release closure ran; cancellation returns `.unobservable`.
    public func settleByObservation(
        pollMillis: Int = G04TerminalFirstUse.ownershipPollMillis,
        observe: Observe
    ) async -> Observation {
        while true {
            if decision == .releaseNow {
                _ = await releaseOnce()
                return .released
            }
            if Task.isCancelled { return .unobservable }
            let observed = await observe()
            switch observed {
            case .owned:
                noteOwnedObservation()
            case .released:
                if canReleaseOnObservedAbsence() {
                    _ = await releaseOnce()
                    return .released
                }
                // Premature/foreign absence: retain and keep observing.
            case .unobservable:
                break
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(max(1, pollMillis)) &* 1_000_000)
            } catch {
                // Cancellation of the WAIT: keep ownership (never a release on
                // an unproven transition).
                return .unobservable
            }
        }
    }
}

// MARK: - Caller admission verdict

/// The caller's admission decision after one preparation attempt. Pure and
/// total, and deliberately strict in one direction: a typed preparation
/// refusal is a HARD refusal. The global capability answer may NOT override it
/// — a concurrent model run can qualify the lane while THIS action's lease was
/// cancelled, its generation moved or its wait expired, and opening on that
/// truth would spend an identity this action no longer owns.
public enum G04TerminalFirstUseAdmission {

    public enum Verdict: Sendable, Equatable {
        /// The caller may continue into the ORIGINAL backend (after its own
        /// re-fence of Root/store/task/workspace).
        case proceed
        /// Hard refusal: the existing closed terminal code plus the bounded
        /// first-use token for the pane's details fold.
        case refuse(G04TerminalCode, token: String)
    }

    public static func verdict(outcome: G04TerminalFirstUse.Outcome,
                               capabilityQualified: Bool) -> Verdict {
        if outcome.kind == .refused, let code = outcome.code {
            return .refuse(terminalCode(for: code), token: outcome.token ?? code.rawValue)
        }
        // Proceed only on Core's OWN live qualification, which the caller reads
        // again itself; this is the defensive second read, never an echo.
        guard capabilityQualified else {
            return .refuse(.engineUnqualified,
                           token: G04TerminalFirstUseCode.unqualifiedAfterPreflight.rawValue)
        }
        return .proceed
    }

    /// The hard-refusal verdict for a preparation that never reached the
    /// mailbox (a pre-submit rule, lease, registration or binding refusal).
    public static func verdict(code: G04TerminalFirstUseCode) -> Verdict {
        .refuse(terminalCode(for: code), token: code.rawValue)
    }

    /// Maps one bounded first-use token onto the EXISTING closed terminal
    /// refusal vocabulary (no new host/UI code): a fence or cancellation of
    /// THIS action is the retired truth, a refused genuine workspace binding is
    /// the ORIGINAL unbound truth, and everything else is honest engine
    /// unavailability carrying the precise token in `reason`.
    public static func terminalCode(for code: G04TerminalFirstUseCode) -> G04TerminalCode {
        switch code {
        case .generationMoved, .leaseCancelled: return .retired
        case .workspaceBindingFailed: return .workspaceUnbound
        default: return .engineUnqualified
        }
    }
}

// MARK: - The bounded round trip

/// One bounded NON-EXECUTING preparation round trip for one explicit human
/// terminal action. All authority reads are the REAL production singletons;
/// the injectable seams exist so the authored regressions can prove the
/// ordering truth (a `ready` echo with unqualified own state is refused; a
/// transport failure never qualifies; an uncertain reply keeps ownership)
/// without a JNI library or a device.
public enum G04TerminalFirstUse {

    /// 45 s. Bounded on purpose: one explicit open then still fits the host's
    /// 165 s `terminalOpen` action wait even when the following `shell.start`
    /// consumes its full 120 s mailbox budget. An expiry is an honest typed
    /// `budgetExpired` refusal the user can retry — the claimed ticket keeps
    /// the ORIGINAL mailbox ownership discipline, and nothing is fabricated.
    public static let preflightBudgetMillis = 45_000

    /// Short bounded wait for the pure-read ownership observation.
    public static let ownershipQueryBudgetMillis = 10_000

    /// Retention poll cadence while the host still owns the preparation. One
    /// second lets the ORIGINAL 15 s stopAndDrain observe a real settled entry
    /// and release its receipt before fencing the only proof channel, without
    /// a busy loop. There is deliberately NO total cap: ownership ends on the
    /// host's own asserted settlement or on an observed release, exactly like
    /// the pump's own preflight reconciliation, so a budget can never detach a
    /// lease while real host IO is in flight.
    public static let ownershipPollMillis = 1_000

    /// The SAME canonical bounded title projection the ORIGINAL D14 launch
    /// ownership statement applies (`G04WorkspaceFacade.conversationTitle` ->
    /// `SQLiteWorkspaceStore.ensureWorkspace`): trimmed, 80-character prefix,
    /// empty -> "Chat". Exposed as a pure function so the authored regression
    /// pins the genuine creation's identity instead of a copy; it never
    /// derives a name from a path, a run or an environment.
    public static func canonicalWorkspaceTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chat" : String(trimmed.prefix(80))
    }

    public struct Outcome: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Core's own live state is qualified now: the caller may continue
            /// into the ORIGINAL backend.
            case qualified
            /// Nothing was submitted because the lane was already warm.
            case skippedAlreadyQualified
            /// Nothing qualified; `code` (and `detail` for a host refusal) say
            /// exactly why. The caller must refuse honestly.
            case refused
        }
        public let kind: Kind
        public let code: G04TerminalFirstUseCode?
        public let detail: String?
        /// The submitted request, when one exists. Its per-ticket state feeds
        /// the release rule; a still-owned claim means real host IO may run.
        public let request: LinuxShellMailboxRequest?
        /// The host's OWN physical-settlement assertion (fail-closed false).
        public let hostOwnershipReleased: Bool

        static func refused(_ code: G04TerminalFirstUseCode,
                            detail: String? = nil,
                            request: LinuxShellMailboxRequest? = nil,
                            hostOwnershipReleased: Bool = false) -> Outcome {
            Outcome(kind: .refused, code: code, detail: detail,
                    request: request, hostOwnershipReleased: hostOwnershipReleased)
        }

        public var isReady: Bool { kind != .refused }
        /// The bounded token surfaced to the pane's details fold.
        public var token: String? {
            switch kind {
            case .refused: return detail ?? code?.rawValue
            default: return nil
            }
        }
        /// The pure release decision for this attempt's ownership.
        public var releaseDecision: G04TerminalFirstUseReleaseRule.Decision {
            G04TerminalFirstUseReleaseRule.decision(settlement: request?.settlement,
                                                    hostOwnershipReleased: hostOwnershipReleased)
        }
    }

    /// Submits the closed request over the ORIGINAL mailbox, parses the reply
    /// strictly, and then re-reads Core's OWN live qualification. Never
    /// retries, never widens a grant, never marks a readiness bit. The outcome
    /// carries the request handle and the host's physical-ownership fact so the
    /// caller can hold its lease until real settlement.
    /// Internal (module + @testable regression only): its default arguments
    /// reference internal mailbox/ingress members, so no public API is widened.
    static func prepare(
        epoch: UInt64,
        conversationID: UUID,
        operationID: UUID,
        uiRunID: UUID,
        liveEpoch: @escaping @Sendable () -> UInt64? = { LinuxReadinessIngress.liveAcceptedEpoch() },
        readiness: @escaping @Sendable () -> G04TerminalFirstUseRule.Decision = {
            G04TerminalFirstUseRule.decision(
                fields: LinuxReadinessIngress.shared.derivedFields(),
                capabilityQualified: RuntimeFacadeLinuxBindings.shared.isCapabilityQualified)
        },
        beginRequest: @escaping @Sendable (_ operation: String, _ payload: Data)
            throws -> LinuxShellMailboxRequest = { operation, payload in
                try LinuxShellMailbox.shared.beginRequest(operation: operation, payload: payload)
            },
        awaitReply: @escaping @Sendable (LinuxShellMailboxRequest, Int) async throws -> Data = {
            request, budgetMillis in
            try await LinuxShellMailbox.shared.awaitReply(request, timeoutMillis: budgetMillis)
        },
        ownStateQualified: @escaping @Sendable () -> Bool = {
            let fields = LinuxReadinessIngress.shared.derivedFields()
            return fields.workspaceMappingSynced && fields.leaseAuthorityQualified
                && RuntimeFacadeLinuxBindings.shared.isCapabilityQualified
        }
    ) async -> Outcome {
        guard epoch > 0, let live = liveEpoch(), live == epoch else {
            return .refused(.epochNotLive)
        }
        switch readiness() {
        case .skipAlreadyQualified:
            return Outcome(kind: .skippedAlreadyQualified, code: nil, detail: nil,
                           request: nil, hostOwnershipReleased: false)
        case .refuse(let code):
            return .refused(code)
        case .prepare:
            break
        }
        guard let payload = G04TerminalFirstUseRequest.payload(operationID: operationID,
                                                              uiRunID: uiRunID,
                                                              conversationID: conversationID,
                                                              rootEpoch: live) else {
            return .refused(.requestMalformed)
        }
        // Two steps, on purpose: the handle must exist BEFORE the wait, so a
        // thrown budget/cancellation/fence still leaves the caller holding the
        // real per-ticket ownership truth. An ENQUEUE failure proves nothing
        // crossed (no ticket exists), so it carries no handle.
        let request: LinuxShellMailboxRequest
        do {
            request = try beginRequest(G04TerminalFirstUseRequest.operation, payload)
        } catch let error as LinuxShellTransportError {
            switch error {
            case .notBound: return .refused(.engineUnbound)
            case .saturated: return .refused(.mailboxSaturated)
            case .payloadTooLarge: return .refused(.payloadTooLarge)
            case .hostFenced: return .refused(.engineFenced)
            case .waitBudgetExpired: return .refused(.budgetExpired)
            case .remoteFailed(let code):
                return .refused(.hostUnavailable, detail: G04TerminalFirstUseReply.boundedToken(code))
            case .remoteFailedWithRestore(let code, _):
                return .refused(.hostUnavailable, detail: G04TerminalFirstUseReply.boundedToken(code))
            case .replyMalformed: return .refused(.replyMalformed)
            }
        } catch {
            return .refused(.requestMalformed)
        }
        let reply: Data
        do {
            reply = try await awaitReply(request, preflightBudgetMillis)
        } catch let error as LinuxShellTransportError {
            // The ticket exists: ownership stays observable and is discharged
            // only by the host's own settlement fact or an observed release.
            switch error {
            case .notBound: return .refused(.engineUnbound, request: request)
            case .saturated: return .refused(.mailboxSaturated, request: request)
            case .payloadTooLarge: return .refused(.payloadTooLarge, request: request)
            case .hostFenced: return .refused(.engineFenced, request: request)
            case .waitBudgetExpired: return .refused(.budgetExpired, request: request)
            case .remoteFailed(let code):
                return .refused(.hostUnavailable,
                                detail: G04TerminalFirstUseReply.boundedToken(code), request: request)
            case .remoteFailedWithRestore(let code, _):
                return .refused(.hostUnavailable,
                                detail: G04TerminalFirstUseReply.boundedToken(code), request: request)
            case .replyMalformed: return .refused(.replyMalformed, request: request)
            }
        } catch is CancellationError {
            return .refused(.cancelled, request: request)
        } catch {
            return .refused(.hostUnavailable, detail: "unexpected", request: request)
        }
        switch G04TerminalFirstUseReply.parse(
            reply,
            maximumFrameBytes: LinuxShellMailboxLimits.maximumFrameBytes,
            expectedEpoch: live,
            operationID: operationID,
            uiRunID: uiRunID,
            conversationID: conversationID) {
        case .ready(_, _, let released):
            // NO echo success: the ONLY qualification is Core's own live read.
            guard ownStateQualified() else {
                return .refused(.unqualifiedAfterPreflight, request: request,
                                hostOwnershipReleased: released)
            }
            return Outcome(kind: .qualified, code: nil, detail: nil,
                           request: request, hostOwnershipReleased: released)
        case .refused(let detail, let released):
            return .refused(.hostUnavailable, detail: detail, request: request,
                            hostOwnershipReleased: released)
        case .cancelled(let released):
            return .refused(.cancelled, request: request, hostOwnershipReleased: released)
        case .malformed(let code):
            // A malformed frame proves nothing about the host's ownership:
            // fail closed and retain.
            return .refused(code, request: request, hostOwnershipReleased: false)
        }
    }

    /// One bounded pure-read observation of the host's OWN preflight ownership
    /// table for this exact identity. Production submits through the ORIGINAL
    /// mailbox; any refusal, fence, malformed frame or unmatched echo answers
    /// `.unobservable`, which RETAINS.
    /// Internal for the same reason as [prepare].
    static func observeOwnership(
        operationID: UUID,
        uiRunID: UUID,
        conversationID: UUID,
        queryEpoch: UInt64,
        submit: @escaping @Sendable (_ operation: String, _ payload: Data, _ budgetMillis: Int)
            async throws -> Data = { operation, payload, budgetMillis in
                try await LinuxShellMailbox.shared.submit(operation: operation, payload: payload,
                                                          timeoutMillis: budgetMillis)
            }
    ) async -> G04TerminalFirstUseOwnership.Observation {
        guard let payload = G04TerminalFirstUseOwnershipQuery.payload(operationID: operationID,
                                                                     uiRunID: uiRunID,
                                                                     conversationID: conversationID,
                                                                     queryEpoch: queryEpoch) else {
            return .unobservable
        }
        let reply: Data
        do {
            reply = try await submit(G04TerminalFirstUseOwnershipQuery.operation, payload,
                                     ownershipQueryBudgetMillis)
        } catch {
            return .unobservable
        }
        let answer = G04TerminalFirstUseOwnershipQuery.parse(
            reply,
            maximumFrameBytes: LinuxShellMailboxLimits.maximumFrameBytes,
            operationID: operationID,
            uiRunID: uiRunID,
            conversationID: conversationID,
            queryEpoch: queryEpoch)
        // The strict parser's closed Answer and the ownership holder's
        // Observation are deliberately separate public types (the parser is
        // also exercised directly by the preflight contract). Map the three
        // closed cases one-to-one; there is no fourth state and no release by
        // absence.
        switch answer {
        case .released: return .released
        case .owned: return .owned
        case .unobservable: return .unobservable
        }
    }
}

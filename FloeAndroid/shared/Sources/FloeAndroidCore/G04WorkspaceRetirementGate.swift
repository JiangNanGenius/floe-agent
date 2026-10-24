// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 workspace retirement preservation gate.
//
// Lifecycle truth (Main review 2026-10-24): at `composition.beginRetirement`
// the bootstrap is ALREADY `.draining`, so `RuntimeOwnedWorkRegistry`
// refuses new attaches — a dirty-draft recovery attempted there can neither
// run under a real lease nor hold the drain. A process-RAM "honest pending"
// list is NOT a cross-process-death proof and must never be presented as one.
//
// This gate is the narrow ORIGINAL lifecycle hook that fixes exactly that:
//
//   1. `prepare(epoch:)` runs SYNCHRONOUSLY before the shutdown-adoption
//      state lock (both the trusted `shutdown(...)` control and the public
//      `system.shutdown` command), at the last instant owned-work attach is
//      still legal (phase is still `.starting`). It attaches ONE REAL
//      `.conversation` token — ownerID `workspace-retirement:<epoch>` — only
//      when the workspace extension is actually attached for that epoch.
//   2. `runShutdownJob` / `runPublicShutdown` then drive
//      `G02RuntimeComposition.runRetirementPreservationIO(epoch:)` BEFORE
//      the first `waitForLifecycleDrain` pass. The workspace facade performs
//      the actual durable preservation (ORIGINAL `Recovered Edits/`
//      content-addressed copy + independent read-back digest) for every
//      dirty draft while that single token remains attached — so the EXISTING
//      RB1 drain predicate (`mailbox idle AND registry count == 0`) cannot
//      report a clean drain while any promised draft byte is unproven.
//   3. When every draft settles VERIFIED the token is detached like any
//      real owned work and the close proceeds. When any preservation cannot
//      settle, the token STAYS attached: the original bounded drain then
//      times out into `retirementPending = .shutdownTimeout` /
//      `failedDrainPending`, ownership (database + root) is retained, and
//      the EXISTING `scheduleRetirementWatch` retry re-runs the SAME control
//      — which re-invokes this IO driver, re-attempting preservation. There
//      is no timeout detach, no fake counter, no success claim, and nothing
//      is silently dropped. Explicit successful conversation deletion is
//      honored by DISCARDING that carry (never resurrecting deleted bytes).
//
// Single-consumer semantics: `claim(epoch:)` hands the attached lease to
// exactly one driver pass; `release(epoch:)` is exact-token and idempotent.
// A real close is possible only after the verified pass releases the
// exact token; neither a timer nor a rejected competing producer may clear
// an adopted preservation obligation.
import Foundation
import FloeCore

public final class G04WorkspaceRetirementGate: @unchecked Sendable {
    public static let shared = G04WorkspaceRetirementGate()

    private struct Entry {
        let token: RuntimeOwnedWorkToken
        var claimed = false
        var released = false
        var adopted = false
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]

    private init() {}

    /// True while a lease is ATTACHED but not yet released; the
    /// adoption-time caller may only roll back what it just attached.
    public var hasAnyPendingLeaseForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { !$0.released }
    }

    /// Outcome of an adoption-time prepare attempt.
    public enum Outcome: Sendable, Equatable {
        case attached      // THIS call created the lease (may roll it back)
        case existing      // an adoption already owns the lease
        case notRequired   // no attached extension owes preservation
        case refused       // required lease unavailable; shutdown must refuse
    }

    /// Synchronous adoption-time attach. `.attached` only when a REAL
    /// owned-work token was created by THIS call (only then may the caller
    /// roll it back on a rejected adoption). `.existing` when an adoption
    /// already owns the lease for this epoch. Registry refusal (already
    /// draining / saturated / invalid) leaves no state behind and returns
    /// `.refused` — a required preservation cannot be admitted, so the
    /// shutdown must refuse without closing the root.
    public func prepare(epoch: UInt64) -> Outcome {
        lock.lock()
        if entries[epoch] != nil { lock.unlock(); return .existing }
        lock.unlock()
        let ownerID = "workspace-retirement:" + String(epoch)
        guard case .attached(let token) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: .conversation, ownerID: ownerID) else {
            return .refused
        }
        lock.lock()
        if entries[epoch] == nil {
            entries[epoch] = Entry(token: token)
            lock.unlock()
            return .attached
        }
        // Racing prepare (two adoption paths for the same epoch): the first
        // entry wins; the surplus token is exact-detached now.
        lock.unlock()
        _ = RuntimeOwnedWorkRegistry.shared.detach(token)
        return .existing
    }


    /// Set while the existing lifecycle state lock accepts a shutdown.
    /// A competing rejected request cannot roll back the winner's lease.
    func markAdopted(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[epoch] else { return }
        entry.adopted = true; entries[epoch] = entry
    }

    @discardableResult
    func rollbackUnadopted(epoch: UInt64) -> Bool {
        lock.lock()
        guard let entry = entries[epoch], !entry.adopted, !entry.claimed else {
            lock.unlock(); return false
        }
        entries[epoch] = nil
        lock.unlock()
        return RuntimeOwnedWorkRegistry.shared.detach(entry.token)
    }

    /// One driver pass claims the lease (at most once until release).
    public func claim(epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[epoch], !entry.claimed, !entry.released else { return false }
        entry.claimed = true
        entries[epoch] = entry
        return true
    }

    /// Exact-token release after ACTUAL verified preservation settled.
    /// Returns false when no lease exists or it was already released.
    @discardableResult
    public func release(epoch: UInt64) -> Bool {
        lock.lock()
        guard var entry = entries[epoch], !entry.released else { lock.unlock(); return false }
        entry.released = true
        let token = entry.token
        entries[epoch] = nil
        lock.unlock()
        return RuntimeOwnedWorkRegistry.shared.detach(token)
    }

    /// A generation whose retirement failed to preserve everything keeps
    /// this true so the drain keeps waiting on the real token; the watch
    /// retry re-claims it for the next attempt.
    public func hasPendingLease(epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[epoch], !entry.released else { return false }
        return entry.claimed
    }

    /// Retry re-drive: the bounded watch mints a fresh control for the SAME
    /// generation; the next driver pass re-claims the still-attached lease.
    public func rearmForRetry(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[epoch], !entry.released, entry.claimed else { return }
        entry.claimed = false
        entries[epoch] = entry
    }

    public var pendingEpochsForTesting: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.sorted()
    }

    /// TEST-ONLY producer cleanup, wired from `G02RuntimeComposition
    /// .resetForTesting`'s existing ownership-reset discipline: a suite
    /// that resets the globals without a real close must not strand gate
    /// leases (each entry's token is exact-detached — the same producer
    /// ownership cleanup the run-domain/staging lanes already perform).
    /// Production never calls this; real releases flow through verified
    /// preservation only.
    func resetForTesting() {
        lock.lock()
        let tokens = entries.values.map(\.token)
        entries.removeAll()
        lock.unlock()
        for token in tokens { _ = RuntimeOwnedWorkRegistry.shared.detach(token) }
    }
}

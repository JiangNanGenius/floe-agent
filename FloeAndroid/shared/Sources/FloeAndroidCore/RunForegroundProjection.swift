// SPDX-License-Identifier: MPL-2.0
//
// G03 Core foreground live-work projection + change signal — narrow
// TRUSTED-HOST ingress only.
//
// Authority (settled architecture): the Core foreground service may be
// promoted ONLY for actual owned work. The ORIGINAL live-work ledger is
// RuntimeOwnedWorkRegistry (RB1): every real run/childRun/tool/conversation
// and vaultMaintenance attaches BEFORE the awaited work and detaches only
// at REAL settlement, under the CURRENT accepted native root epoch, with
// the bootstrap's existing admission fencing. This file projects THAT
// ledger's per-epoch counts and offers a sync-only change signal for the
// Kotlin host's RunForegroundBinding; it adds no new ledger, no schema and
// no second job database, and it changes nothing.
//
// Discipline (mirrors G02NativeRootEpoch, the reviewed narrow reader):
//  * C ABI `@_cdecl` private trusted-host ingress ONLY — NOT a v3 command,
//    NOT a tool, NOT model-reachable; no model tool registration anywhere
//    here; there is no arbitrary root/epoch fallback.
//  * Snapshot reads are lock-only and synchronous:
//    `AndroidRuntimeBootstrap.currentPumps()` (one state lock) plus
//    `RuntimeOwnedWorkRegistry.countsByKind(for:)` (one NSLock). No I/O,
//    no store query, no await; safe from the host's JNI/worker thread
//    without nesting into mailbox or UI locks.
//  * The change signal NEVER reads the registry under its own condition
//    lock; Main alone invokes `notifyOwnedWorkChanged()` from the existing
//    registry attach/detach paths AFTER the registry lock is released, and
//    owns the JNI/host observer loop. The bounded wait (max 1 s) is
//    event-driven waiting, never an always-busy poller, and it never
//    acquires foreground from counts by itself.
//  * Fail closed: with no live generation (nil pumps — never starting,
//    draining or retired) the snapshot reader returns `notInstalled`; the
//    host MUST treat that as unknown and never as zero-work truth. Counts
//    carry no owner ids, receipts, tokens, paths or secrets.
//
// Wire contract with the Kotlin parser (`RunForegroundWire` in
// core/runlifecycle, pinned there by RunForegroundWireTest): booleans are
// strictly `1`/`0`; any drift must make the host read UNKNOWN, never a
// silent mis-parse.
//
// This source is NOT compiled/executed by the authoring package; the
// serialized native cohort freezes the original Git bytes plus overlays
// and owns the actual build/link smoke, including the JNI translation
// unit that exposes `floe_run_foreground_snapshot` and
// `floe_run_foreground_wait_change` (see SOURCE_READY).
import Foundation

/// Snapshot of the REAL owned-work ledger for the CURRENT accepted epoch.
/// Counts only — an unknown generation is represented by the ABSENCE of
/// a snapshot (nil), never by a zero-filled truth.
public struct RunForegroundLiveWork: Sendable {
    public let epoch: UInt64
    public let storeReady: Bool
    public let admissionFenced: Bool
    public let runCount: Int
    public let childRunCount: Int
    public let toolCount: Int
    public let conversationCount: Int
    public let vaultMaintenanceCount: Int
}

public enum RunForegroundProjection {

    /// The live owned-work ledger under the CURRENT accepted root epoch,
    /// or nil when no non-retiring generation exists (fail closed; the
    /// bootstrap already refuses 0-as-epoch elsewhere and this reader
    /// keeps the same rule).
    public static func snapshot() -> RunForegroundLiveWork? {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(), pumps.epoch > 0 else {
            return nil
        }
        let counts = RuntimeOwnedWorkRegistry.shared.countsByKind(for: pumps.epoch)
        return RunForegroundLiveWork(
            epoch: pumps.epoch,
            storeReady: pumps.storeReady,
            admissionFenced: pumps.mailbox.isAdmissionFenced,
            runCount: counts[RuntimeOwnedWorkKind.run.rawValue] ?? 0,
            childRunCount: counts[RuntimeOwnedWorkKind.childRun.rawValue] ?? 0,
            toolCount: counts[RuntimeOwnedWorkKind.tool.rawValue] ?? 0,
            conversationCount: counts[RuntimeOwnedWorkKind.conversation.rawValue] ?? 0,
            vaultMaintenanceCount: counts[RuntimeOwnedWorkKind.vaultMaintenance.rawValue] ?? 0
        )
    }

    /// The single ASCII wire the trusted host parses strictly (any
    /// malformed field == unknown host-side; nothing is defaulted).
    static func serialize(_ work: RunForegroundLiveWork) -> String {
        "epoch=\(work.epoch);storeReady=\(work.storeReady ? 1 : 0);"
        + "admissionFenced=\(work.admissionFenced ? 1 : 0);"
        + "run=\(work.runCount);childRun=\(work.childRunCount);"
        + "tool=\(work.toolCount);conversation=\(work.conversationCount);"
        + "vaultMaintenance=\(work.vaultMaintenanceCount)"
    }

    /// Fixed upper bound: 64-bit epoch (20) + three booleans + five
    /// bounded counts (registry cap is 256, so 3 digits each) + keys/
    /// separators. A generous 256-byte cap keeps the JNI copy trivial.
    public static let maximumLineBytes = 256
}

// MARK: - Trusted-host snapshot readback (published ingress #1)

/// `floe_run_foreground_snapshot(outBuffer, capacity) -> Int32`
///
/// Returns the number of ASCII bytes written (positive, NUL-terminated)
/// on success, or the shared negative status codes: `invalidArguments`
/// for a bad buffer/capacity contract, `bufferTooSmall` when the caller's
/// buffer cannot fit the line (caller must retry with at least
/// `RunForegroundProjection.maximumLineBytes` + 1), and `notInstalled`
/// when no live generation exists — which the host MUST read as unknown
/// and never as "no owned work".
@_cdecl("floe_run_foreground_snapshot")
public func floeRunForegroundSnapshot(
    _ outBuffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard capacity >= 0, let outBuffer else {
        return RuntimeFacadeStatus.invalidArguments
    }
    guard let work = RunForegroundProjection.snapshot() else {
        return RuntimeFacadeStatus.notInstalled
    }
    let text = RunForegroundProjection.serialize(work)
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity), bytes.count <= RunForegroundProjection.maximumLineBytes else {
        return RuntimeFacadeStatus.bufferTooSmall
    }
    for (index, byte) in bytes.enumerated() { outBuffer[index] = CChar(bitPattern: byte) }
    outBuffer[bytes.count] = 0
    return Int32(bytes.count)
}

// MARK: - Owned-work change signal (sync-only; Main-invoked)

/// The monotonic change sequence lives behind ONE private NSCondition.
/// `notifyOwnedWorkChanged()` is SYNC-ONLY: it increments the sequence and
/// broadcasts; it NEVER reads or snapshots the owned-work registry under
/// its own condition lock. Main alone calls it from the existing
/// `RuntimeOwnedWorkRegistry` attach/detach paths AFTER releasing the
/// registry lock, so no lock nesting exists between the lifecycle, the
/// registry and this condition, and the broadcast never blocks attach.
private let foregroundChangeCondition = NSCondition()
// G03-native-integration compile repair 5: Swift 6 flags lock-guarded global
// mutable state. Every read/write of this counter happens ONLY while
// foregroundChangeCondition is held (see currentChangeSequence(),
// notifyOwnedWorkChanged() and waitForChange below); the annotation states
// that discipline to the compiler without introducing a parallel lock.
private nonisolated(unsafe) var foregroundChangeSequence: UInt64 = 0

private func currentChangeSequence() -> UInt64 {
    foregroundChangeCondition.lock()
    let current = foregroundChangeSequence
    foregroundChangeCondition.unlock()
    return current
}

public enum RunForegroundChange {

    /// Increment + broadcast only (see rule above). Safe from any thread
    /// that already holds NO registry/lifecycle lock.
    public static func notifyOwnedWorkChanged() {
        foregroundChangeCondition.lock()
        foregroundChangeSequence &+= 1
        foregroundChangeCondition.broadcast()
        foregroundChangeCondition.unlock()
    }

    /// Bounded waiter used by the private C ABI. Returns the CURRENT
    /// sequence. Comparison contract for the host observer:
    ///  * returned > `after` — at least one real owned-work change is
    ///    known; the host reads the snapshot and reconciles leases.
    ///  * returned == `after` — the bounded wait expired without an
    ///    observed change; the host re-checks its epoch/fence and loops.
    ///  * returned < `after` — the signal state was replaced (process or
    ///    generation restart reset the counter); the host must re-read the
    ///    snapshot and REBASE its observation, never assume "no changes".
    /// The wait is capped at 1000 ms by contract regardless of the
    /// argument, so a stranded waiter re-evaluates instead of blocking
    /// forever. This is event-driven waiting, NOT an always-busy poller.
    static func waitForChange(after: UInt64, timeoutMillis: Int32) -> UInt64 {
        let boundedMillis = min(max(0, Int(timeoutMillis)), 1_000)
        foregroundChangeCondition.lock()
        if foregroundChangeSequence != after {
            // Already changed (>) or rebased after a restart (<): answer
            // immediately; waiting would be a lie.
            let current = foregroundChangeSequence
            foregroundChangeCondition.unlock()
            return current
        }
        let deadline = Date(timeIntervalSinceNow: Double(boundedMillis) / 1_000.0)
        while foregroundChangeSequence == after && Date() < deadline {
            if boundedMillis == 0 { break }
            _ = foregroundChangeCondition.wait(until: deadline)
        }
        let current = foregroundChangeSequence
        foregroundChangeCondition.unlock()
        return current
    }

    /// Positive Int64 range for the JNI boundary (monotonic practical
    /// counter; saturates honestly rather than wrapping).
    static func int64(_ sequence: UInt64) -> Int64 {
        sequence > UInt64(Int64.max) ? Int64.max : Int64(sequence)
    }

    /// Current sequence without waiting (host initialization/rebasing).
    static var sequence: UInt64 { currentChangeSequence() }
}

// MARK: - Trusted-host wait ingress (published ingress #2; Main observer)

/// `floe_run_foreground_wait_change(after, timeoutMillis) -> Int64`
///
/// Bounded (max 1 s) event wait on the owned-work change sequence. The
/// Main-owned JNI/host observer loop decides re-invocation, snapshot
/// reads and lease reconciliation; this ingress never acquires foreground,
/// never reads counts, and never returns "work zero" truth by itself.
/// A negative `after` is answered with the CURRENT sequence so the host
/// rebases immediately rather than dead-waiting on an invalid observation
/// base.
@_cdecl("floe_run_foreground_wait_change")
public func floeRunForegroundWaitChange(
    _ after: Int64,
    _ timeoutMillis: Int32
) -> Int64 {
    guard after >= 0 else {
        return RunForegroundChange.int64(RunForegroundChange.sequence)
    }
    return RunForegroundChange.int64(
        RunForegroundChange.waitForChange(after: UInt64(after), timeoutMillis: timeoutMillis)
    )
}

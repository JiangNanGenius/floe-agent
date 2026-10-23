// FloeAndroidJobTools — REAL job-processor ownership index (job-a16c9976985f40b2).
//
// A RAM-only, process-scoped observation of background jobs whose processor
// is ACTUALLY executing inside this process right now. It exists so the
// trusted host (Core FGS lane, lifecycle drain) can project honest on-work
// start/settled signals:
//
// * ONLY real processor ownership counts. A durable store row that says
//   "running" after a process death is NOT live work: this index starts
//   empty on every launch, and the ORIGINAL durable recovery path
//   (`BackgroundJobService.reconcileInterruptedOnLaunch`) turns those rows
//   into honest `interrupted`/UNKNOWN outcomes.
// * This is NOT a job store and NOT a second job authority:
//   BackgroundJobStore/BackgroundJobService remain the only durable record.
//   The index holds identifiers and counts only — never payloads, commands
//   or output.
// * Entries are added by the job-scoped runner wrappers EXACTLY around the
//   awaited processor dispatch (`inner.run` start → real settle or throw),
//   so a shell job whose engine lease is still unreconciled keeps its entry
//   until the lease-reconcile wait extension acknowledges (see
//   ExecShellJobRunner.swift).

import Foundation
import FloeCore
// G03-native-integration compile repair 2: AnyAgentTool (descriptor/run/
// validateArguments/preflightSubmission) is defined in the ORIGINAL FloeTools
// ToolRunnerRegistry public main blob; makeJobTrackedRunner needs it in scope.
import FloeTools

/// One live job processor observation (identities only; never payloads).
public struct JobLiveWorkEntry: Sendable, Equatable {
    public let jobID: UUID
    public let targetTool: String
    public let startedAt: Date

    public init(jobID: UUID, targetTool: String, startedAt: Date) {
        self.jobID = jobID
        self.targetTool = targetTool
        self.startedAt = startedAt
    }
}

/// Trusted host delegate for REAL job-processor ownership transitions
/// (start / true settle, including a settle-by-ceiling-safety-failure throw).
/// The Core FGS lane can attach/detach owned work (e.g. kind `tool` in the
/// RuntimeOwnedWorkRegistry) from exactly these events: they fire ONLY
/// around a processor ACTUALLY executing in this process — a durable
/// "running" row after process death never produces a started callback
/// before a fresh dispatch exists.
public protocol JobProcessorOwnershipDelegate: Sendable {
    func jobProcessorStarted(jobID: UUID, targetTool: String) async throws
    func jobProcessorSettled(jobID: UUID) async
}

/// Synchronous storage for the host delegate. Composition sets it BEFORE
/// `register()` returns (Main's serialized order: compose → register), so
/// there is no task-scheduling race in which an early dispatch could miss
/// the delegate; the actor only ever READS it at processing time.
public final class JobProcessorOwnershipBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: JobProcessorOwnershipDelegate?

    public init(_ initial: JobProcessorOwnershipDelegate? = nil) {
        value = initial
    }

    public func set(_ delegate: JobProcessorOwnershipDelegate?) {
        lock.lock(); value = delegate; lock.unlock()
    }

    public var current: JobProcessorOwnershipDelegate? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

public actor JobLiveWorkIndex {
    private var entries: [UUID: JobLiveWorkEntry] = [:]
    private var observer: (@Sendable (Int) async -> Void)?
    private let ownership: JobProcessorOwnershipBox

    public init(ownership: JobProcessorOwnershipBox = JobProcessorOwnershipBox()) {
        self.ownership = ownership
    }

    /// Trusted host hook: called after every begin/settle with the new live
    /// count. The FGS lane re-reads `live()`/`isIdle()` from the callback;
    /// setting a new observer never fakes a transition (no synthetic call).
    public func setObserver(_ observer: (@Sendable (Int) async -> Void)?) {
        self.observer = observer
    }

    public func begin(jobID: UUID, targetTool: String) async throws {
        // Idempotent re-begin keeps the FIRST start time (a retried wrapper
        // must not look like newer work than the durable record claims).
        guard entries[jobID] == nil else {
            let count = entries.count
            if let observer { Task { await observer(count) } }
            return
        }
        entries[jobID] = JobLiveWorkEntry(jobID: jobID, targetTool: targetTool, startedAt: Date())
        let count = entries.count
        if let observer { Task { await observer(count) } }
        if let delegate = ownership.current {
            do { try await delegate.jobProcessorStarted(jobID: jobID, targetTool: targetTool) }
            catch { entries.removeValue(forKey: jobID); throw error }
        }
    }

    /// Real settle: removes the entry. Idempotent (a late second settle is
    /// a no-op, never a negative count).
    public func settle(jobID: UUID) {
        guard entries.removeValue(forKey: jobID) != nil else { return }
        let count = entries.count
        if let observer { Task { await observer(count) } }
        if let delegate = ownership.current {
            Task { await delegate.jobProcessorSettled(jobID: jobID) }
        }
    }

    public func live() -> [JobLiveWorkEntry] {
        entries.values.sorted { $0.startedAt < $1.startedAt }
    }

    public var count: Int { entries.count }

    public func isIdle() -> Bool { entries.isEmpty }

    /// Bounded honest drain: true only when the index is EMPTY within the
    /// window. Never claims drained on timeout (the caller keeps ownership
    /// of the leftovers it observes via `live()`).
    public func waitForIdle(timeoutMillis: Int) async -> Bool {
        guard !entries.isEmpty else { return true }
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMillis)) / 1000.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if entries.isEmpty { return true }
            if Task.isCancelled { return entries.isEmpty }
        }
        return entries.isEmpty
    }
}

/// Parses the durable job identity out of the ORIGINAL job-context call id
/// shape `jobs.<UUID>` (set by BackgroundJobService.start — the trusted
/// frozen identity, never a model string). Anything else returns nil:
/// tracking never guesses a job, and a non-job context is simply untracked.
public enum JobProcessorIdentity {
    public static func jobID(fromToolCallID toolCallID: String?) -> UUID? {
        guard let toolCallID, toolCallID.hasPrefix("jobs.") else { return nil }
        return UUID(uuidString: String(toolCallID.dropFirst("jobs.".count)))
    }

    /// The INVERSE of `jobID(fromToolCallID:)`: the ORIGINAL durable
    /// processor call identity the service freezes for a job row's
    /// ToolContext (`BackgroundJobService.start`). Canonical uppercase
    /// `jobs.<UUID uuidString>` — owner UUID strings ride UNCHANGED through
    /// the grant lane (the same rule as the shell mailbox and the grant
    /// identity echo), so every consumer re-derives the expected identity
    /// from the ORIGINAL proven row instead of trusting a wire-echoed
    /// variant, and a lowercase or foreign-shape claim is a mismatch,
    /// never a near-hit. (G03-R3 jobs grant admission: this is the ONE
    /// grammar definition; `LinuxWorkspaceAuthority` session-open job
    /// fence and the service producer both use it.)
    public static func callID(jobID: UUID) -> String {
        "jobs." + jobID.uuidString
    }
}

/// Wraps a job-target runner so the live index counts EXACTLY the real
/// processor span (dispatch start → true settle/throw). Used for every
/// admitted target; the exec.shell wrapper (ExecShellJobRunner) layers the
/// lease-reconcile wait on top of the same begin/settle discipline.
public func makeJobTrackedRunner(
    inner: AnyAgentTool,
    index: JobLiveWorkIndex
) -> AnyAgentTool {
    AnyAgentTool(
        descriptor: inner.descriptor,
        run: { argumentsJSON, context in
            let jobID = JobProcessorIdentity.jobID(fromToolCallID: context.toolCallID)
            if let jobID { try await index.begin(jobID: jobID, targetTool: inner.descriptor.name) }
            do {
                let output = try await inner.run(argumentsJSON, context)
                if let jobID { await index.settle(jobID: jobID) }
                return output
            } catch {
                if let jobID { await index.settle(jobID: jobID) }
                throw error
            }
        },
        validateArguments: inner.validateArguments,
        preflightSubmission: inner.preflightSubmission
    )
}

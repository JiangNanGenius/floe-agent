// FloeExecutionTests — BackgroundJobService integration of the one-time
// long-run duration advisory: arming on real tool jobs only, group-owned
// phase handoff (one advisory per trusted native operation, no threshold
// reset, no duplicates), liveness answers, the best-effort durable marker,
// and the guarantee that the advisory path NEVER changes job state.

import Foundation
import Testing
import FloeTools
import FloeCore
@testable import FloePersistence
@testable import FloeExecution

private actor JobTestSleepGate {
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private(set) var requested: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async -> Bool {
        requested.append(seconds)
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    var waiterCount: Int { waiters.count }
    func releaseAll(_ result: Bool) {
        let pending = Array(waiters.values)
        waiters = [:]
        for continuation in pending { continuation.resume(returning: result) }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
}

private actor JobMilestoneCollector {
    private(set) var milestones: [LongRunAdvisoryMilestone] = []
    func add(_ milestone: LongRunAdvisoryMilestone) { milestones.append(milestone) }
    var count: Int { milestones.count }
    var first: LongRunAdvisoryMilestone? { milestones.first }
}

@Suite("Background job duration advisory")
struct BackgroundJobDurationReminderTests {
    private func fixture() async throws -> (DatabaseManager, UUID, UUID) {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let conversation = UUID(), run = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES (?, 'Advisory', ?, ?)
                """, arguments: [conversation.uuidString, now, now])
            try db.execute(sql: """
                INSERT INTO runs (id, conversation_id, state, goal, started_at)
                VALUES (?, ?, 'running', 'Test', ?)
                """, arguments: [run.uuidString, conversation.uuidString, now])
        }
        return (db, conversation, run)
    }

    /// One registered fake target: `{"fast":true}` completes immediately,
    /// anything else blocks cooperatively until cancelled (a real long job).
    private func makeRegistry(targets: [String]) -> ToolRunnerRegistry {
        let registry = ToolRunnerRegistry()
        for name in targets {
            registry.register(AnyAgentTool(
                descriptor: ToolCatalog.Descriptor(
                    name: name, toolDescription: "advisory test target",
                    parametersJSON: #"{"type":"object"}"#, riskLabels: [], isSideEffecting: true
                )
            ) { payload, context in
                let fast = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["fast"] as? Bool ?? false
                if fast {
                    return ToolExecutionOutput(digesting: "done", exitStatus: 0, capturedOutput: "done")
                }
                while true {
                    try context.cancellation.throwIfCancelled()
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            })
        }
        return registry
    }

    private func makeService(
        db: DatabaseManager,
        gate: JobTestSleepGate,
        collector: JobMilestoneCollector,
        targets: [String] = ["exec.shell", "network.download", "exec.localService"]
    ) -> BackgroundJobService {
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        return BackgroundJobService(
            store: BackgroundJobStore(database: db),
            registry: makeRegistry(targets: targets),
            durationReminder: reminder
        )
    }

    private func waitFor(timeout: TimeInterval = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    @discardableResult
    private func submit(
        _ service: BackgroundJobService,
        run: UUID,
        callID: String,
        target: String = "exec.shell",
        payload: [String: Any] = [:],
        group: UUID? = nil
    ) async throws -> BackgroundJob {
        try await service.submit(
            runID: run, toolCallID: callID, targetTool: target,
            payloadJSON: JSONSerialization.data(withJSONObject: payload),
            scope: .local, workspaceRootURL: nil, allowedWorkspacePaths: [],
            submissionSource: .nativeService, waitForCompletion: false,
            advisoryGroupID: group
        )
    }

    @Test("A running job arms the advisory; firing it never changes job state; cancel still drains to terminal")
    func runningJobAdvisoryIsObserveOnly() async throws {
        let (db, _, run) = try await fixture()
        let gate = JobTestSleepGate()
        let collector = JobMilestoneCollector()
        let service = makeService(db: db, gate: gate, collector: collector)
        let job = try await submit(service, run: run, callID: "adv-1")
        // Armed exactly once for this job while it really runs.
        #expect(await waitFor { await gate.waiterCount == 1 })
        #expect(await waitFor { (try? await service.job(id: job.id))?.state == .running })
        // 600 elapsed: one advisory for the job's own key.
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 1 })
        #expect(await collector.first?.ownershipKey == "job.\(job.id.uuidString)")
        #expect(await collector.first?.jobID == job.id)
        // Liveness is true and the durable marker lands WITHOUT any state,
        // output or cancellation change: the advisory is observe-only.
        #expect(await service.advisoryTargetIsLive(jobID: job.id, advisoryGroupID: nil))
        await service.markDurationAdvisoryEnqueued(jobID: job.id, at: Date())
        let marked = try #require(try await service.job(id: job.id))
        #expect(marked.state == .running)
        #expect(marked.lastError == nil)
        #expect(NativeJobProgressDocument.decode(marked.progressJSON)?.durationAdvisoryEnqueuedAt != nil)
        // Real cancellation still drains to the honest terminal state, and a
        // repeated tick after terminal never produces a second advisory.
        _ = try await service.cancel(id: job.id)
        #expect(await waitFor { (try? await service.job(id: job.id))?.state.isTerminal == true })
        #expect((try? await service.job(id: job.id))?.state == .cancelled)
        #expect(await service.advisoryTargetIsLive(jobID: job.id, advisoryGroupID: nil) == false)
        await gate.releaseAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 1)
    }

    @Test("A job that finishes before the threshold disarms and never advises")
    func finishedJobNeverAdvises() async throws {
        let (db, _, run) = try await fixture()
        let gate = JobTestSleepGate()
        let collector = JobMilestoneCollector()
        let service = makeService(db: db, gate: gate, collector: collector)
        let job = try await submit(service, run: run, callID: "adv-fast", payload: ["fast": true])
        #expect(await waitFor { (try? await service.job(id: job.id))?.state == .completed })
        #expect(await waitFor { await gate.waiterCount == 0 })
        await gate.releaseAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 0)
        // A post-terminal marker write is a no-op, never a state change.
        await service.markDurationAdvisoryEnqueued(jobID: job.id, at: Date())
        let finished = try #require(try await service.job(id: job.id))
        #expect(finished.state == .completed)
        #expect(NativeJobProgressDocument.decode(finished.progressJSON)?.durationAdvisoryEnqueuedAt == nil)
    }

    @Test("Phases of one trusted native group share ONE advisory: no threshold reset, no duplicates")
    func groupedPhasesShareOneAdvisory() async throws {
        let (db, _, run) = try await fixture()
        let gate = JobTestSleepGate()
        let collector = JobMilestoneCollector()
        let service = makeService(db: db, gate: gate, collector: collector)
        let group = UUID()
        let phase1 = try await submit(service, run: run, callID: "phase-1", group: group)
        #expect(await waitFor { await gate.waiterCount == 1 })
        // Phase handoff: the next bound phase job re-begins the SAME key.
        let phase2 = try await submit(service, run: run, callID: "phase-2", group: group)
        #expect(await waitFor { (try? await service.job(id: phase2.id))?.state == .running })
        #expect(await gate.waiterCount == 1)          // one timer, not two
        #expect(await gate.requested == [600])         // measured from phase 1
        // Phase 1 ends while phase 2 runs: the group stays live (a handoff
        // gap never reads as finished).
        _ = try await service.cancel(id: phase1.id)
        #expect(await waitFor { (try? await service.job(id: phase1.id))?.state.isTerminal == true })
        #expect(await service.advisoryTargetIsLive(jobID: phase1.id, advisoryGroupID: group))
        // ONE advisory for the whole operation, under the group key.
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 1 })
        #expect(await collector.first?.ownershipKey == "job.\(group.uuidString)")
        #expect(await collector.first?.advisoryGroupID == group)
        // A terminal owner invalidates its reminder even while a member
        // still drains. Releasing a reminder lease must not stop that job.
        await service.releaseAdvisoryGroupLease(groupID: group)
        #expect(await service.advisoryTargetIsLive(jobID: phase1.id, advisoryGroupID: group) == false)
        #expect(await service.advisoryKeyIsLive(group) == false)
        #expect(try await service.job(id: phase2.id)?.state == .running)
        _ = try await service.cancel(id: phase2.id)
        #expect(await waitFor { (try? await service.job(id: phase2.id))?.state.isTerminal == true })
        await gate.releaseAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 1)
        // The group identity persisted on both rows.
        #expect(try await service.job(id: phase1.id)?.advisoryGroupID == group)
        #expect(try await service.job(id: phase2.id)?.advisoryGroupID == group)
    }

    @Test("The trusted operation lease keeps group liveness across a phase-handoff gap; release ends it")
    func groupLeaseCoversHandoffGap() async throws {
        let (db, _, run) = try await fixture()
        let gate = JobTestSleepGate()
        let collector = JobMilestoneCollector()
        let service = makeService(db: db, gate: gate, collector: collector)
        let group = UUID()
        let phase1 = try await submit(service, run: run, callID: "gap-1", group: group)
        #expect(await waitFor { await gate.waiterCount == 1 })
        // The grouped native submit acquired the operation lease.
        #expect(await service.holdsAdvisoryGroupLease(groupID: group))
        // Phase 1 is terminal and the next phase is NOT yet submitted: the
        // real handoff gap. The lease — not member inference — keeps the
        // operation live, so a fired advisory is delivered instead of being
        // silently swallowed by the one-shot fired key.
        _ = try await service.cancel(id: phase1.id)
        #expect(await waitFor { (try? await service.job(id: phase1.id))?.state.isTerminal == true })
        #expect(await service.advisoryTargetIsLive(jobID: phase1.id, advisoryGroupID: group))
        #expect(await service.advisoryKeyIsLive(group))
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 1 })
        #expect(await collector.first?.ownershipKey == "job.\(group.uuidString)")
        // The owner releases the lease at the operation's terminal close.
        await service.releaseAdvisoryGroupLease(groupID: group)
        #expect(await service.holdsAdvisoryGroupLease(groupID: group) == false)
        #expect(await service.advisoryTargetIsLive(jobID: phase1.id, advisoryGroupID: group) == false)
        #expect(await service.advisoryKeyIsLive(group) == false)
        // The fired key never re-fires: a late re-begin cannot produce a
        // second advisory for the closed operation.
        await gate.releaseAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 1)
    }

    @Test("A runtime/model submission can never bind advisory group ownership")
    func runtimeSubmissionCannotBindGroup() async throws {
        let (db, _, run) = try await fixture()
        let gate = JobTestSleepGate()
        let collector = JobMilestoneCollector()
        let service = makeService(db: db, gate: gate, collector: collector)
        await #expect(throws: (any Error).self) {
            try await service.submit(
                runID: run, toolCallID: "smuggled", targetTool: "exec.shell",
                payloadJSON: JSONSerialization.data(withJSONObject: ["fast": true]),
                scope: .local, workspaceRootURL: nil, allowedWorkspacePaths: [],
                submissionSource: .runtime, waitForCompletion: false,
                advisoryGroupID: UUID()
            )
        }
    }

    @Test("Download and local-service jobs never arm the advisory")
    func downloadsAndServicesDoNotArm() async throws {
        let (db, _, run) = try await fixture()
        let gate = JobTestSleepGate()
        let collector = JobMilestoneCollector()
        let service = makeService(db: db, gate: gate, collector: collector)
        let download = try await submit(service, run: run, callID: "adv-dl", target: "network.download")
        let localService = try await submit(service, run: run, callID: "adv-svc", target: "exec.localService")
        #expect(await waitFor { (try? await service.job(id: download.id))?.state == .running })
        #expect(await waitFor { (try? await service.job(id: localService.id))?.state == .running })
        // Both run (blocking fakes) but neither arms a duration advisory:
        // downloads are system-owned across relaunch and local services are
        // indefinite by design with their own ready/terminal notifications.
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(await gate.waiterCount == 0)
        #expect(await collector.count == 0)
        _ = try await service.cancel(id: download.id)
        _ = try await service.cancel(id: localService.id)
        #expect(await waitFor { (try? await service.job(id: download.id))?.state.isTerminal == true })
        #expect(await waitFor { (try? await service.job(id: localService.id))?.state.isTerminal == true })
        await gate.releaseAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 0)
    }
}

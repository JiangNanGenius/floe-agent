import Foundation
import FloeCore
import FloeModels
import FloeTools

/// Trusted dispatch identity. App adapters derive the native owner ONLY from
/// this runtime-created value, never from tool arguments or a timer title.
public struct AgentWaitOwner: Sendable, Codable, Hashable {
    public var conversationID: UUID
    public var runID: UUID
    public var callID: String
    public var clientSessionID: String?
    public init(conversationID: UUID, runID: UUID, callID: String, clientSessionID: String? = nil) {
        self.conversationID = conversationID; self.runID = runID
        self.callID = callID; self.clientSessionID = clientSessionID
    }
}

/// Exact ledger incarnation, frozen after an authorized native status read.
public struct AgentWaitNativeTimerBinding: Sendable, Codable, Hashable {
    public var alarmID: UUID
    public var ownerTaskID: UUID?
    public var producerRunID: UUID
    public var producerCallID: String
    public var creationReceiptID: UUID
    public var payloadDigest: String
    public var createdAt: Date
    public init(alarmID: UUID, ownerTaskID: UUID?, producerRunID: UUID,
                producerCallID: String, creationReceiptID: UUID,
                payloadDigest: String, createdAt: Date) {
        self.alarmID = alarmID; self.ownerTaskID = ownerTaskID
        self.producerRunID = producerRunID; self.producerCallID = producerCallID
        self.creationReceiptID = creationReceiptID; self.payloadDigest = payloadDigest
        self.createdAt = createdAt
    }
    public func isOwned(by owner: AgentWaitOwner) -> Bool {
        ownerTaskID == owner.conversationID
    }
}

/// Fields are a projection of the existing ledger/native readback. Missing
/// state/timeline remains unknown. No duration-based synthetic firing event.
public struct AgentWaitNativeTimerObservation: Sendable, Hashable {
    public var binding: AgentWaitNativeTimerBinding
    public var ledgerState: String
    public var preservedNativeState: String?
    public var nativeState: String?
    public var fireDate: Date?
    public var totalDuration: TimeInterval?
    public var previousElapsed: TimeInterval?
    public var startDate: Date?
    public var timelineFingerprint: String?
    public var revision: UInt64
    public init(binding: AgentWaitNativeTimerBinding, ledgerState: String,
                preservedNativeState: String? = nil, nativeState: String? = nil,
                fireDate: Date? = nil, totalDuration: TimeInterval? = nil,
                previousElapsed: TimeInterval? = nil, startDate: Date? = nil,
                timelineFingerprint: String? = nil, revision: UInt64) {
        self.binding = binding; self.ledgerState = ledgerState
        self.preservedNativeState = preservedNativeState; self.nativeState = nativeState
        self.fireDate = fireDate; self.totalDuration = totalDuration
        self.previousElapsed = previousElapsed; self.startDate = startDate
        self.timelineFingerprint = timelineFingerprint; self.revision = revision
    }
    public var hasFiredProof: Bool {
        nativeState == "alerting" || preservedNativeState == "alerting"
    }
}

/// Thin injection of the SAME SystemAlarmService; no second observer/store.
public struct AgentWaitNativeTimerBridge: Sendable {
    public var status: @Sendable (AgentWaitOwner, UUID) async throws -> AgentWaitNativeTimerObservation
    public var updates: @Sendable () async -> AsyncStream<Void>
    public init(status: @escaping @Sendable (AgentWaitOwner, UUID) async throws -> AgentWaitNativeTimerObservation,
                updates: @escaping @Sendable () async -> AsyncStream<Void>) {
        self.status = status; self.updates = updates
    }
}

/// Injectable native suspension clock. Production uses cancellable Task.sleep;
/// focused tests advance the same deadline without wall-clock polling.
public struct AgentWaitClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleepUntil: @Sendable (Date) async throws -> Void
    public init(now: @escaping @Sendable () -> Date,
                sleepUntil: @escaping @Sendable (Date) async throws -> Void) {
        self.now = now; self.sleepUntil = sleepUntil
    }
    public static let continuous = AgentWaitClock(now: { Date() }, sleepUntil: { deadline in
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        try Task.checkCancellation()
    })
}

public struct AgentWaitReceipt: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable { case completed, interrupted, cancelled }
    public var waitID: UUID
    public var continuationInputID: UUID
    public var status: Status
    public var remainingSeconds: TimeInterval?
    public var reason: String?
    public var settledAt: Date

    func output() throws -> ToolExecutionOutput {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self),
                                   fullOutputSHA256: FloeDigest.sha256Hex(data))
    }
}

/// Additive checkpoint payload; it is the sole durable wait truth. Ordinary
/// job dependencies stay in their existing store and never receive alarm IDs.
public struct AgentWaitRecord: Sendable, Codable, Hashable {
    public var owner: AgentWaitOwner
    public var waitID: UUID
    public var continuationInputID: UUID
    public var request: RuntimeWaitRequest
    public var startedAt: Date
    public var deadline: Date?
    public var nativeBinding: AgentWaitNativeTimerBinding?
    public var receipt: AgentWaitReceipt?
    public var continuationConsumed: Bool?

    public init(owner: AgentWaitOwner, request: RuntimeWaitRequest, now: Date,
                nativeBinding: AgentWaitNativeTimerBinding? = nil) throws {
        try request.validate()
        self.owner = owner; self.request = request; self.startedAt = now
        self.waitID = UUID(); self.continuationInputID = UUID()
        self.deadline = request.seconds.map { now.addingTimeInterval($0) }
        self.nativeBinding = nativeBinding
        self.continuationConsumed = false
    }
    public func remaining(at now: Date) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }
    func settle(_ status: AgentWaitReceipt.Status, at now: Date, reason: String? = nil) -> AgentWaitReceipt {
        AgentWaitReceipt(waitID: waitID, continuationInputID: continuationInputID, status: status,
                         remainingSeconds: remaining(at: now), reason: reason, settledAt: now)
    }
}

/// Runtime-produced positive wake proof. Never Codable and no public
/// initializer: model arguments cannot impersonate a native completion.
public struct AgentWaitWake: Sendable {
    public let owner: AgentWaitOwner
    public let waitID: UUID
    public let inputID: UUID
    public let receipt: AgentWaitReceipt
}

/// Cold recovery uses the exact checkpoint, not a generic job lookup. The
/// app still rechecks conversation/run ownership immediately before resume.
public enum AgentWaitRecovery {
    public static let markerPrefix = "awaiting.finite.job.task.wait"

    public static func hasWaitingMarker(_ checkpoint: AgentCheckpoint) -> Bool {
        guard case .checkpointed(let reference) = checkpoint.state else { return false }
        return reference.reason?.hasPrefix(markerPrefix + ":") == true
    }

    /// The host saves this under its original run/file fence when a parked
    /// task is stopped. No native timer cancellation authority is acquired.
    public static func cancelling(_ checkpoint: AgentCheckpoint, at now: Date = Date()) -> AgentCheckpoint {
        var stopped = checkpoint
        stopped.runtimeWaits = checkpoint.runtimeWaits?.map { record in
            var copy = record
            if copy.receipt == nil { copy.receipt = copy.settle(.cancelled, at: now, reason: "The task was stopped.") }
            return copy
        }
        stopped.state = .checkpointed(.init(reason: "The task was stopped."))
        return stopped
    }

    public static func pending(in checkpoint: AgentCheckpoint) -> [AgentWaitRecord] {
        let paired = Set(checkpoint.pendingToolResults.map(\.callID))
        return (checkpoint.runtimeWaits ?? []).filter { record in
            record.owner.runID == checkpoint.runID && record.owner.conversationID == checkpoint.conversationID
                && !paired.contains(record.owner.callID) && (record.receipt == nil || record.receipt?.status == .completed)
                && checkpoint.pendingToolCalls.contains { call in call.id == record.owner.callID && call.toolName == AgentWaitTool.name }
        }
    }

    static func validatedRecords(in checkpoint: AgentCheckpoint, runID: UUID,
                                 conversationID: UUID) throws -> [String: AgentWaitRecord] {
        var records: [String: AgentWaitRecord] = [:]
        for var record in checkpoint.runtimeWaits ?? [] {
            guard checkpoint.runID == runID, checkpoint.conversationID == conversationID,
                  record.owner.runID == runID, record.owner.conversationID == conversationID,
                  records[record.owner.callID] == nil,
                  let call = checkpoint.pendingToolCalls.first(where: { $0.id == record.owner.callID }),
                  call.toolName == AgentWaitTool.name,
                  let arguments = try? JSONDecoder().decode(RuntimeWaitRequest.self, from: call.argumentsJSON),
                  arguments == record.request else { throw AgentWaitError.identityChanged }
            try record.request.validate()
            if let seconds = record.request.seconds {
                guard let deadline = record.deadline,
                      abs(deadline.timeIntervalSince(record.startedAt) - seconds) < 0.001,
                      record.nativeBinding == nil else { throw AgentWaitError.identityChanged }
            } else {
                guard record.deadline == nil, let binding = record.nativeBinding,
                      binding.alarmID == record.request.alarmID,
                      binding.isOwned(by: record.owner) else { throw AgentWaitError.identityChanged }
            }
            if let receipt = record.receipt {
                guard receipt.waitID == record.waitID,
                      receipt.continuationInputID == record.continuationInputID else {
                    throw AgentWaitError.identityChanged
                }
            }
            if checkpoint.messages.contains(where: { $0.id == record.continuationInputID && $0.role == "user" }) {
                record.continuationConsumed = true
            }
            records[record.owner.callID] = record
        }
        return records
    }

    /// One bounded, independently cancellable native subscription or sleep.
    /// This does not enqueue input, launch a run, or create a scheduled task.
    public static func wakes(in checkpoint: AgentCheckpoint,
                             clock: AgentWaitClock = .continuous,
                             native: AgentWaitNativeTimerBridge? = nil) -> AsyncThrowingStream<AgentWaitWake, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let records = try validatedRecords(in: checkpoint, runID: checkpoint.runID,
                                                       conversationID: checkpoint.conversationID)
                    let pendingIDs = Set(pending(in: checkpoint).map(\.waitID))
                    try await withThrowingTaskGroup(of: AgentWaitWake.self) { group in
                        for record in records.values where pendingIDs.contains(record.waitID) {
                            group.addTask {
                                let receipt = try await AgentWaitSuspension.wait(record: record, clock: clock, native: native)
                                try Task.checkCancellation()
                                return AgentWaitWake(owner: record.owner, waitID: record.waitID,
                                                     inputID: record.continuationInputID, receipt: receipt)
                            }
                        }
                        while let wake = try await group.next() {
                            if wake.receipt.status != .cancelled { continuation.yield(wake) }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum AgentWaitError: Error, Sendable, LocalizedError {
    case unavailable, identityChanged, timerCancelled, timerUnknown, updatesEnded
    public var errorDescription: String? {
        switch self {
        case .unavailable: FloeL10n.isChinese ? "当前任务无法等待，请在普通任务中重试。" : "Waiting is unavailable in this task. Try a regular task."
        case .identityChanged: FloeL10n.isChinese ? "等待状态已变化，请检查当前任务后重试。" : "The saved wait changed. Check the task and try again."
        case .timerCancelled: FloeL10n.isChinese ? "计时器已在响铃前取消。" : "The timer was cancelled before ringing."
        case .timerUnknown: FloeL10n.isChinese ? "无法确认计时器状态，请检查后再继续。" : "The timer's state is unavailable. Check it before continuing."
        case .updatesEnded: FloeL10n.isChinese ? "计时器更新已中断，请打开任务重新检查。" : "Timer updates stopped. Open the task to check it again."
        }
    }
}

enum AgentWaitSuspension {
    static func wait(record: AgentWaitRecord, clock: AgentWaitClock,
                     native: AgentWaitNativeTimerBridge?) async throws -> AgentWaitReceipt {
        if let receipt = record.receipt { return receipt }
        try Task.checkCancellation()
        if let deadline = record.deadline {
            while clock.now() < deadline {
                try await clock.sleepUntil(deadline)
                try Task.checkCancellation()
            }
            return record.settle(.completed, at: clock.now())
        }
        guard let native, let alarmID = record.request.alarmID,
              let binding = record.nativeBinding, binding.isOwned(by: record.owner) else {
            throw AgentWaitError.unavailable
        }
        // Subscribe BEFORE reading so a transition between read/subscription
        // cannot be lost. Each native service subscription is independently owned.
        let updates = await native.updates()
        var iterator = updates.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            let observed = try await native.status(record.owner, alarmID)
            guard observed.binding == binding else { throw AgentWaitError.identityChanged }
            if observed.hasFiredProof { return record.settle(.completed, at: clock.now()) }
            if observed.ledgerState == "cancelled" { throw AgentWaitError.timerCancelled }
            guard observed.nativeState != nil else { throw AgentWaitError.timerUnknown }
            guard await iterator.next() != nil else {
                try Task.checkCancellation()
                throw AgentWaitError.updatesEnded
            }
        }
    }
}

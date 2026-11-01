import CoreFoundation
import Foundation

/// Process/scene liveness is diagnostic evidence only. It never changes the
/// logical lifecycle, readiness, one-shot dispatch or command ownership.
///
/// Two independent beats make a silent stop distinguishable:
///  * the main-run-loop timer proves that the MainActor/main queue is being
///    serviced;
///  * the dispatch timer proves that the process still runs even while the
///    MainActor is blocked inside an XCTest/UIKit call.
///
/// A beat from another PID is always stale for the current process; a missing
/// timestamp is unknown, never current. A stale ready marker therefore cannot
/// be described as a healthy engine.
public enum BridgeLivenessPolicy {
    public static let schema = 1
    public static let mainBeatIntervalSeconds: TimeInterval = 4
    public static let dispatchBeatIntervalSeconds: TimeInterval = 4
    public static let currentAgeSeconds: TimeInterval = 8
    public static let futureToleranceSeconds: TimeInterval = 5
    public static let maximumAgeSeconds: TimeInterval = 86_400
    public static let maximumTransitions = 24
    public static let maximumFileBytes = 65_536
    public static let note = "Service-owned scheduling evidence only; not a readiness or process-alive assertion."
}

public enum BridgeBeatFreshness: String, Codable, Sendable, CaseIterable {
    case current
    case stale
    case missing
    case unknown
}

/// Bounded, typed freshness for one heartbeat source. The age is recomputed
/// when the status is read, so a last-known beat is never presented as current.
public struct BridgeLivenessBeatStatus: Codable, Equatable, Sendable {
    public var present: Bool
    public var count: UInt64
    public var processIdentifier: Int32
    public var isCurrentProcess: Bool
    public var lastBeatAt: String?
    public var ageMilliseconds: Int?
    public var freshness: BridgeBeatFreshness
    public var source: String

    public init(
        present: Bool,
        count: UInt64,
        processIdentifier: Int32,
        isCurrentProcess: Bool,
        lastBeatAt: String?,
        ageMilliseconds: Int?,
        freshness: BridgeBeatFreshness,
        source: String
    ) {
        self.present = present
        self.count = count
        self.processIdentifier = processIdentifier
        self.isCurrentProcess = isCurrentProcess
        self.lastBeatAt = lastBeatAt
        self.ageMilliseconds = ageMilliseconds
        self.freshness = freshness
        self.source = source
    }

    public static func mainThread(
        record: [String: Any]?,
        now: Date = Date(),
        currentProcessIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) -> BridgeLivenessBeatStatus {
        evaluate(
            record: record,
            countKey: "count",
            lastBeatKey: "lastBeatAt",
            defaultSource: "main-runloop-timer",
            now: now,
            currentProcessIdentifier: currentProcessIdentifier
        )
    }

    public static func dispatch(
        record: [String: Any]?,
        now: Date = Date(),
        currentProcessIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) -> BridgeLivenessBeatStatus {
        evaluate(
            record: record,
            countKey: "count",
            lastBeatKey: "lastBeatAt",
            defaultSource: "process-liveness-dispatch-timer",
            now: now,
            currentProcessIdentifier: currentProcessIdentifier
        )
    }

    public static func engineHeartbeat(
        record: [String: Any]?,
        now: Date = Date(),
        currentProcessIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) -> BridgeLivenessBeatStatus {
        evaluate(
            record: record,
            countKey: "heartbeatCount",
            lastBeatKey: "lastHeartbeatAt",
            defaultSource: "BridgeCore test engine dispatch timer",
            now: now,
            currentProcessIdentifier: currentProcessIdentifier
        )
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "present": present,
            "count": count,
            "isCurrentProcess": isCurrentProcess,
            "freshness": freshness.rawValue,
            "source": source,
        ]
        if processIdentifier > 0 { value["processIdentifier"] = processIdentifier }
        if let lastBeatAt { value["lastBeatAt"] = lastBeatAt }
        if let ageMilliseconds { value["ageMilliseconds"] = ageMilliseconds }
        return value
    }

    private static func evaluate(
        record: [String: Any]?,
        countKey: String,
        lastBeatKey: String,
        defaultSource: String,
        now: Date,
        currentProcessIdentifier: Int32
    ) -> BridgeLivenessBeatStatus {
        guard let record else {
            return BridgeLivenessBeatStatus(
                present: false,
                count: 0,
                processIdentifier: -1,
                isCurrentProcess: false,
                lastBeatAt: nil,
                ageMilliseconds: nil,
                freshness: .missing,
                source: defaultSource
            )
        }
        let processIdentifier = int32(record["processIdentifier"]) ?? -1
        let count = uint64(record[countKey]) ?? 0
        let lastBeatAt = record[lastBeatKey] as? String
        let source = (record["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultSource
        let present = processIdentifier > 0 || count > 0 || lastBeatAt != nil
        let isCurrentProcess = processIdentifier > 0 && processIdentifier == currentProcessIdentifier

        guard present else {
            return BridgeLivenessBeatStatus(
                present: false,
                count: 0,
                processIdentifier: processIdentifier,
                isCurrentProcess: false,
                lastBeatAt: lastBeatAt,
                ageMilliseconds: nil,
                freshness: .missing,
                source: source
            )
        }

        // A record owned by another process is historical evidence, never a
        // current beat for this PID, even when its timestamp looks new.
        guard isCurrentProcess else {
            return BridgeLivenessBeatStatus(
                present: true,
                count: count,
                processIdentifier: processIdentifier,
                isCurrentProcess: false,
                lastBeatAt: lastBeatAt,
                ageMilliseconds: timestampAgeMilliseconds(lastBeatAt, now: now),
                freshness: .stale,
                source: source
            )
        }

        guard let lastBeatAt else {
            return BridgeLivenessBeatStatus(
                present: true,
                count: count,
                processIdentifier: processIdentifier,
                isCurrentProcess: true,
                lastBeatAt: nil,
                ageMilliseconds: nil,
                freshness: .unknown,
                source: source
            )
        }
        guard let age = timestampAgeMilliseconds(lastBeatAt, now: now) else {
            return BridgeLivenessBeatStatus(
                present: true,
                count: count,
                processIdentifier: processIdentifier,
                isCurrentProcess: true,
                lastBeatAt: lastBeatAt,
                ageMilliseconds: nil,
                freshness: .unknown,
                source: source
            )
        }
        let freshness: BridgeBeatFreshness = age <= Int(BridgeLivenessPolicy.currentAgeSeconds * 1000)
            ? .current
            : .stale
        return BridgeLivenessBeatStatus(
            present: true,
            count: count,
            processIdentifier: processIdentifier,
            isCurrentProcess: true,
            lastBeatAt: lastBeatAt,
            ageMilliseconds: age,
            freshness: freshness,
            source: source
        )
    }

    private static func timestampAgeMilliseconds(_ raw: String?, now: Date) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: raw)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: raw)
        }
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite else { return nil }
        if seconds < -BridgeLivenessPolicy.futureToleranceSeconds { return nil }
        let clamped = min(max(seconds, 0), BridgeLivenessPolicy.maximumAgeSeconds)
        return Int(clamped * 1000)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.uint64Value
        }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    private static func int32(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.int32Value
        }
        if let string = value as? String { return Int32(string) }
        return nil
    }
}

/// One bounded scene/app transition. The PID is repeated so an old process's
/// history cannot be confused with the current process.
public struct BridgeLivenessTransition: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var at: String
    public var processIdentifier: Int32
    public var source: String
    public var name: String
    public var applicationState: String?
    public var sceneState: String?

    public init(
        sequence: UInt64,
        at: String,
        processIdentifier: Int32,
        source: String,
        name: String,
        applicationState: String? = nil,
        sceneState: String? = nil
    ) {
        self.sequence = sequence
        self.at = at
        self.processIdentifier = processIdentifier
        self.source = source
        self.name = name
        self.applicationState = applicationState
        self.sceneState = sceneState
    }

    public init?(dictionary: [String: Any]) {
        guard let sequence = (dictionary["sequence"] as? NSNumber)?.uint64Value,
              let at = dictionary["at"] as? String,
              !at.isEmpty,
              let processIdentifier = (dictionary["processIdentifier"] as? NSNumber)?.int32Value,
              processIdentifier > 0,
              let source = dictionary["source"] as? String,
              !source.isEmpty,
              let name = dictionary["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        self.sequence = sequence
        self.at = at
        self.processIdentifier = processIdentifier
        self.source = source
        self.name = name
        self.applicationState = dictionary["applicationState"] as? String
        self.sceneState = dictionary["sceneState"] as? String
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "sequence": sequence,
            "at": at,
            "processIdentifier": processIdentifier,
            "source": source,
            "name": name,
        ]
        if let applicationState { value["applicationState"] = applicationState }
        if let sceneState { value["sceneState"] = sceneState }
        return value
    }
}

/// Fixed-size transition history. Old entries are dropped, never accumulated.
public struct BridgeLivenessTransitionLog: Equatable, Sendable {
    public private(set) var transitions: [BridgeLivenessTransition] = []

    public init() {}

    public mutating func append(_ transition: BridgeLivenessTransition) {
        transitions.append(transition)
        let overflow = transitions.count - BridgeLivenessPolicy.maximumTransitions
        if overflow > 0 {
            transitions.removeFirst(overflow)
        }
    }

    public var dictionaries: [[String: Any]] {
        transitions.map { $0.dictionary() }
    }

    public static func parse(_ raw: Any?, currentProcessIdentifier: Int32) -> [BridgeLivenessTransition] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        let parsed = rows.suffix(64).compactMap(BridgeLivenessTransition.init(dictionary:))
            .filter { $0.processIdentifier == currentProcessIdentifier }
        return Array(parsed.suffix(BridgeLivenessPolicy.maximumTransitions))
    }
}

/// Observable protected-data availability. This is deliberately not a
/// lock-state or causal claim: iOS exposes a protection state, not a lock
/// reason, and a change can be caused by several system events.
public enum BridgeProtectedDataPolicy {
    public static let note = "Observable protected-data availability only; not a definitive lock-state or causal claim."
}

public struct BridgeProtectedDataStatus: Codable, Equatable, Sendable {
    public var observed: Bool
    public var isCurrentProcess: Bool
    public var processIdentifier: Int32
    public var initialAvailable: Bool?
    public var currentAvailable: Bool?
    public var observedAt: String?
    public var lastEvent: String?
    public var lastEventAt: String?
    public var didBecomeAvailableCount: UInt64
    public var willBecomeUnavailableCount: UInt64
    public var note: String

    public init(
        observed: Bool,
        isCurrentProcess: Bool,
        processIdentifier: Int32,
        initialAvailable: Bool? = nil,
        currentAvailable: Bool? = nil,
        observedAt: String? = nil,
        lastEvent: String? = nil,
        lastEventAt: String? = nil,
        didBecomeAvailableCount: UInt64 = 0,
        willBecomeUnavailableCount: UInt64 = 0,
        note: String = BridgeProtectedDataPolicy.note
    ) {
        self.observed = observed
        self.isCurrentProcess = isCurrentProcess
        self.processIdentifier = processIdentifier
        self.initialAvailable = initialAvailable
        self.currentAvailable = currentAvailable
        self.observedAt = observedAt
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.didBecomeAvailableCount = didBecomeAvailableCount
        self.willBecomeUnavailableCount = willBecomeUnavailableCount
        self.note = note
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "observed": observed,
            "isCurrentProcess": isCurrentProcess,
            "didBecomeAvailableCount": didBecomeAvailableCount,
            "willBecomeUnavailableCount": willBecomeUnavailableCount,
            "note": note,
        ]
        if processIdentifier > 0 { value["processIdentifier"] = processIdentifier }
        if let initialAvailable { value["initialAvailable"] = initialAvailable }
        if let currentAvailable { value["currentAvailable"] = currentAvailable }
        if let observedAt { value["observedAt"] = observedAt }
        if let lastEvent { value["lastEvent"] = lastEvent }
        if let lastEventAt { value["lastEventAt"] = lastEventAt }
        return value
    }

    public static func parse(
        _ record: [String: Any]?,
        currentProcessIdentifier: Int32
    ) -> BridgeProtectedDataStatus {
        guard let record else {
            return BridgeProtectedDataStatus(
                observed: false,
                isCurrentProcess: false,
                processIdentifier: -1
            )
        }
        let processIdentifier = (record["processIdentifier"] as? NSNumber)?.int32Value ?? -1
        guard processIdentifier == currentProcessIdentifier, processIdentifier > 0 else {
            // A previous process's protection state is historical evidence;
            // do not present it as the current state.
            return BridgeProtectedDataStatus(
                observed: false,
                isCurrentProcess: false,
                processIdentifier: processIdentifier
            )
        }
        let initialAvailable = record["initialAvailable"] as? Bool
        let currentAvailable = record["currentAvailable"] as? Bool
        let didBecome = (record["didBecomeAvailableCount"] as? NSNumber)?.uint64Value ?? 0
        let willBecome = (record["willBecomeUnavailableCount"] as? NSNumber)?.uint64Value ?? 0
        let observed = initialAvailable != nil || currentAvailable != nil ||
            didBecome > 0 || willBecome > 0
        return BridgeProtectedDataStatus(
            observed: observed,
            isCurrentProcess: true,
            processIdentifier: processIdentifier,
            initialAvailable: initialAvailable,
            currentAvailable: currentAvailable,
            observedAt: record["observedAt"] as? String,
            lastEvent: record["lastEvent"] as? String,
            lastEventAt: record["lastEventAt"] as? String,
            didBecomeAvailableCount: didBecome,
            willBecomeUnavailableCount: willBecome
        )
    }
}

/// Derived health is intentionally separate from the logical lifecycle. A
/// `ready` snapshot is not called healthy unless the live beats for the same
/// PID are current.
public enum BridgeLivenessHealth: String, Codable, Sendable {
    case idle
    case starting
    case healthy
    case readyUnconfirmed = "ready-unconfirmed"
    case stopped
    case failed
    case unknown
}

public struct BridgeLivenessStatus: Codable, Equatable, Sendable {
    public var schema: Int
    public var currentProcessIdentifier: Int32
    public var recordProcessIdentifier: Int32
    public var recordIsCurrentProcess: Bool
    public var applicationState: String
    public var sceneState: String
    public var applicationStateIsCurrent: Bool
    public var stateObservedAt: String?
    public var mainThread: BridgeLivenessBeatStatus
    public var dispatch: BridgeLivenessBeatStatus
    public var engineHeartbeat: BridgeLivenessBeatStatus
    public var protectedData: BridgeProtectedDataStatus
    public var processScheduling: BridgeBeatFreshness
    public var mainThreadResponsive: BridgeBeatFreshness
    public var health: BridgeLivenessHealth
    public var healthReason: String
    public var transitions: [BridgeLivenessTransition]
    public var note: String

    public init(
        schema: Int = BridgeLivenessPolicy.schema,
        currentProcessIdentifier: Int32,
        recordProcessIdentifier: Int32,
        recordIsCurrentProcess: Bool,
        applicationState: String,
        sceneState: String,
        applicationStateIsCurrent: Bool,
        stateObservedAt: String?,
        mainThread: BridgeLivenessBeatStatus,
        dispatch: BridgeLivenessBeatStatus,
        engineHeartbeat: BridgeLivenessBeatStatus,
        protectedData: BridgeProtectedDataStatus,
        processScheduling: BridgeBeatFreshness,
        mainThreadResponsive: BridgeBeatFreshness,
        health: BridgeLivenessHealth,
        healthReason: String,
        transitions: [BridgeLivenessTransition] = [],
        note: String = BridgeLivenessPolicy.note
    ) {
        self.schema = schema
        self.currentProcessIdentifier = currentProcessIdentifier
        self.recordProcessIdentifier = recordProcessIdentifier
        self.recordIsCurrentProcess = recordIsCurrentProcess
        self.applicationState = applicationState
        self.sceneState = sceneState
        self.applicationStateIsCurrent = applicationStateIsCurrent
        self.stateObservedAt = stateObservedAt
        self.mainThread = mainThread
        self.dispatch = dispatch
        self.engineHeartbeat = engineHeartbeat
        self.protectedData = protectedData
        self.processScheduling = processScheduling
        self.mainThreadResponsive = mainThreadResponsive
        self.health = health
        self.healthReason = healthReason
        self.transitions = transitions
        self.note = note
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "currentProcessIdentifier": currentProcessIdentifier,
            "recordIsCurrentProcess": recordIsCurrentProcess,
            "applicationState": applicationState,
            "sceneState": sceneState,
            "applicationStateIsCurrent": applicationStateIsCurrent,
            "mainThreadBeat": mainThread.dictionary(),
            "dispatchBeat": dispatch.dictionary(),
            "engineHeartbeat": engineHeartbeat.dictionary(),
            "protectedData": protectedData.dictionary(),
            "processScheduling": processScheduling.rawValue,
            "mainThreadResponsive": mainThreadResponsive.rawValue,
            "health": health.rawValue,
            "healthReason": healthReason,
            "transitions": transitions.map { $0.dictionary() },
            "note": note,
        ]
        if recordProcessIdentifier > 0 { value["recordProcessIdentifier"] = recordProcessIdentifier }
        if let stateObservedAt { value["stateObservedAt"] = stateObservedAt }
        return value
    }

    public static func evaluate(
        snapshot: BridgeSnapshot,
        liveness: [String: Any]?,
        engineHeartbeat: [String: Any]?,
        now: Date = Date(),
        currentProcessIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) -> BridgeLivenessStatus {
        let recordProcessIdentifier = (liveness?["processIdentifier"] as? NSNumber)?.int32Value ?? -1
        let recordIsCurrentProcess = recordProcessIdentifier > 0 &&
            recordProcessIdentifier == currentProcessIdentifier
        let mainBeat = BridgeLivenessBeatStatus.mainThread(
            record: liveness?["mainThreadBeat"] as? [String: Any],
            now: now,
            currentProcessIdentifier: currentProcessIdentifier
        )
        let dispatchBeat = BridgeLivenessBeatStatus.dispatch(
            record: liveness?["dispatchBeat"] as? [String: Any],
            now: now,
            currentProcessIdentifier: currentProcessIdentifier
        )
        let engineBeat = BridgeLivenessBeatStatus.engineHeartbeat(
            record: engineHeartbeat,
            now: now,
            currentProcessIdentifier: currentProcessIdentifier
        )
        let protectedData = BridgeProtectedDataStatus.parse(
            liveness?["protectedData"] as? [String: Any],
            currentProcessIdentifier: currentProcessIdentifier
        )

        let applicationState = recordIsCurrentProcess
            ? (liveness?["applicationState"] as? String ?? "unknown")
            : "unknown"
        let sceneState = recordIsCurrentProcess
            ? (liveness?["sceneState"] as? String ?? "unknown")
            : "unknown"
        let stateObservedAt = recordIsCurrentProcess
            ? (liveness?["stateObservedAt"] as? String)
            : nil
        let transitions = recordIsCurrentProcess
            ? BridgeLivenessTransitionLog.parse(
                liveness?["transitions"],
                currentProcessIdentifier: currentProcessIdentifier
            )
            : []

        let (health, reason) = deriveHealth(
            snapshot: snapshot,
            recordIsCurrentProcess: recordIsCurrentProcess,
            recordProcessIdentifier: recordProcessIdentifier,
            mainBeat: mainBeat,
            dispatchBeat: dispatchBeat,
            engineBeat: engineBeat,
            currentProcessIdentifier: currentProcessIdentifier
        )

        return BridgeLivenessStatus(
            currentProcessIdentifier: currentProcessIdentifier,
            recordProcessIdentifier: recordProcessIdentifier,
            recordIsCurrentProcess: recordIsCurrentProcess,
            applicationState: applicationState,
            sceneState: sceneState,
            applicationStateIsCurrent: recordIsCurrentProcess && mainBeat.freshness == .current,
            stateObservedAt: stateObservedAt,
            mainThread: mainBeat,
            dispatch: dispatchBeat,
            engineHeartbeat: engineBeat,
            protectedData: protectedData,
            processScheduling: dispatchBeat.freshness,
            mainThreadResponsive: mainBeat.freshness,
            health: health,
            healthReason: reason,
            transitions: transitions
        )
    }

    private static func deriveHealth(
        snapshot: BridgeSnapshot,
        recordIsCurrentProcess: Bool,
        recordProcessIdentifier: Int32,
        mainBeat: BridgeLivenessBeatStatus,
        dispatchBeat: BridgeLivenessBeatStatus,
        engineBeat: BridgeLivenessBeatStatus,
        currentProcessIdentifier: Int32
    ) -> (BridgeLivenessHealth, String) {
        if snapshot.terminalFault {
            return (.failed, "terminal-fault")
        }
        if snapshot.phase == .failed {
            return (.failed, "phase-failed")
        }
        if snapshot.phase.isActive {
            return (.starting, "phase-\(snapshot.phase.rawValue)")
        }
        if snapshot.phase == .idle {
            return (.idle, "phase-idle")
        }
        if snapshot.phase == .stopped {
            return (.stopped, "phase-stopped")
        }
        guard snapshot.phase == .ready else {
            return (.unknown, "phase-\(snapshot.phase.rawValue)")
        }
        guard snapshot.serviceRunning, snapshot.engineEntryObserved, snapshot.engineRunning else {
            return (.readyUnconfirmed, "ready-marker-without-running-engine")
        }
        guard snapshot.enginePid == currentProcessIdentifier else {
            return (.readyUnconfirmed, "engine-pid-mismatch")
        }
        guard recordIsCurrentProcess else {
            return (
                .readyUnconfirmed,
                recordProcessIdentifier > 0 ? "liveness-record-foreign-pid" : "liveness-missing"
            )
        }
        guard mainBeat.freshness == .current else {
            return (.readyUnconfirmed, "main-thread-\(mainBeat.freshness.rawValue)")
        }
        guard dispatchBeat.freshness == .current else {
            return (.readyUnconfirmed, "dispatch-\(dispatchBeat.freshness.rawValue)")
        }
        guard engineBeat.freshness == .current else {
            return (.readyUnconfirmed, "engine-heartbeat-\(engineBeat.freshness.rawValue)")
        }
        return (.healthy, "all-heartbeats-current")
    }
}

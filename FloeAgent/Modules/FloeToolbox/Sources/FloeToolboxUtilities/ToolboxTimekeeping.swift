import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ToolboxTimekeepingError: Error, Equatable, Sendable {
    case invalid, limit, corruptArchive, staleArchive
}

/// Continuous time includes suspension and sleep. Wall time is retained only
/// for recovery when continuity cannot be established after a process restart.
public struct ToolboxTimeSample: Codable, Equatable, Sendable {
    public var wall: Date
    public var continuous: Double
    public var process: UUID
    public init(wall: Date, continuous: Double, process: UUID) {
        self.wall = wall; self.continuous = continuous; self.process = process
    }
    private static let processID = UUID()
    #if canImport(Darwin)
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    #endif
    public static var now: Self {
        #if canImport(Darwin)
        Self(wall: Date(), continuous: Double(mach_continuous_time()) * secondsPerTick, process: processID)
        #else
        Self(wall: Date(), continuous: ProcessInfo.processInfo.systemUptime, process: processID)
        #endif
    }
    public var isValid: Bool { wall.timeIntervalSince1970.isFinite && continuous.isFinite && continuous >= 0 }
    public func elapsed(since start: Self) -> (seconds: Double, continuous: Bool) {
        let matchingClock = process == start.process ||
            abs((wall.timeIntervalSince1970 - continuous) - (start.wall.timeIntervalSince1970 - start.continuous)) <= 5
        if matchingClock, continuous >= start.continuous {
            return (continuous - start.continuous, true)
        }
        return (max(0, wall.timeIntervalSince(start.wall)), false)
    }
}

public struct ToolboxStopwatchLap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var elapsed: Double
    public var split: Double
    public init(elapsed: Double, split: Double) { id = UUID(); self.elapsed = elapsed; self.split = split }
}

public struct ToolboxStopwatch: Codable, Equatable, Sendable {
    public static let maximumLaps = 200
    public static let maximumElapsed = 366.0 * 86_400
    public var accumulated: Double = 0
    public var started: ToolboxTimeSample?
    public var laps: [ToolboxStopwatchLap] = []
    public init() {}
    public var running: Bool { started != nil }
    public func elapsed(at now: ToolboxTimeSample) -> Double {
        min(Self.maximumElapsed, accumulated + (started.map { now.elapsed(since: $0).seconds } ?? 0))
    }
    public mutating func start(at now: ToolboxTimeSample) {
        guard started == nil, now.isValid, accumulated < Self.maximumElapsed else { return }
        started = now
    }
    public mutating func pause(at now: ToolboxTimeSample) { accumulated = elapsed(at: now); started = nil }
    public mutating func reset() { self = Self() }
    public mutating func lap(at now: ToolboxTimeSample) throws {
        guard running else { throw ToolboxTimekeepingError.invalid }
        guard laps.count < Self.maximumLaps else { throw ToolboxTimekeepingError.limit }
        let value = elapsed(at: now)
        laps.append(.init(elapsed: value, split: max(0, value - (laps.last?.elapsed ?? 0))))
    }
    public var isValid: Bool {
        guard accumulated.isFinite, (0...Self.maximumElapsed).contains(accumulated),
              started?.isValid != false, laps.count <= Self.maximumLaps,
              Set(laps.map(\.id)).count == laps.count else { return false }
        var previous = 0.0
        for lap in laps {
            guard lap.elapsed.isFinite, lap.split.isFinite, lap.elapsed >= previous,
                  lap.elapsed <= Self.maximumElapsed, lap.split >= 0,
                  abs(lap.split - (lap.elapsed - previous)) < 0.01 else { return false }
            previous = lap.elapsed
        }
        return started != nil || (laps.last?.elapsed ?? 0) <= accumulated + 0.01
    }
}

public enum ToolboxCountdownPhase: String, Codable, Sendable { case paused, running, finished }

/// Plain values keep the toolbox independent of the host's alarm framework.
public enum ToolboxTimerAlarmAction: String, Codable, Sendable { case refresh, start, pause, resume, reset, restart }
public struct ToolboxTimerAlarmRequest: Sendable {
    public var timerID: UUID
    public var generation: UInt64
    public var label: String
    public var remaining: Double
    public var isRunning: Bool
    public var action: ToolboxTimerAlarmAction
    public init(timerID: UUID, generation: UInt64, label: String, remaining: Double, action: ToolboxTimerAlarmAction, isRunning: Bool = true) {
        self.timerID = timerID; self.generation = generation; self.label = label
        self.remaining = remaining; self.action = action; self.isRunning = isRunning
    }
}
public struct ToolboxTimerAlarmState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case running, paused, alerting, stopped, unverified }
    public var timerID: UUID
    public var generation: UInt64
    public var phase: Phase
    public var remaining: Double?
    public var observedAt: Date
    public init(timerID: UUID, generation: UInt64, phase: Phase, remaining: Double?, observedAt: Date = Date()) {
        self.timerID = timerID; self.generation = generation; self.phase = phase
        self.remaining = remaining; self.observedAt = observedAt
    }
}
public struct ToolboxCountdown: Codable, Equatable, Sendable, Identifiable {
    public static let maximumDuration = 31.0 * 86_400
    public var id: UUID
    public var label: String
    public var duration: Double
    public var retained: Double
    public var started: ToolboxTimeSample?
    public var phase: ToolboxCountdownPhase
    public var reminder = false
    public var generation: UInt64 = 0
    /// An explicit action survives a crash between saving the clock and
    /// confirming the native operation. Refresh never replaces that intent.
    public var pendingAlarmAction: ToolboxTimerAlarmAction?
    public init(label: String, duration: Double, now: ToolboxTimeSample, running: Bool = true) throws {
        id = UUID(); self.label = label; self.duration = duration; retained = duration
        started = running ? now : nil; phase = running ? .running : .paused
        guard isValid else { throw ToolboxTimekeepingError.invalid }
    }
    public func remaining(at now: ToolboxTimeSample) -> Double {
        max(0, retained - (started.map { now.elapsed(since: $0).seconds } ?? 0))
    }
    public mutating func pause(at now: ToolboxTimeSample) {
        retained = remaining(at: now); started = nil
        phase = retained > 0 ? .paused : .finished; generation += 1
    }
    public mutating func resume(at now: ToolboxTimeSample) {
        guard phase == .paused, retained > 0, now.isValid else { return }
        started = now; phase = .running; generation += 1
    }
    public mutating func reset() { retained = duration; started = nil; phase = .paused; generation += 1 }
    public mutating func finishIfNeeded(at now: ToolboxTimeSample) -> Bool {
        guard phase == .running, remaining(at: now) <= 0 else { return false }
        retained = 0; started = nil; phase = .finished; generation += 1; return true
    }
    public var isValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.utf8.count <= 256 &&
        !label.contains("\0") && duration.isFinite && duration > 0 && duration <= Self.maximumDuration &&
        retained.isFinite && (0...duration).contains(retained) && started?.isValid != false &&
        (phase == .running) == (started != nil) && (phase != .finished || retained == 0) &&
        generation < UInt64.max - 1_000_000
    }
}

public struct ToolboxTimekeepingArchive: Codable, Equatable, Sendable {
    public static let maximumTimers = 12
    public var version = 1
    public var revision: UInt64 = 0
    public var stopwatch = ToolboxStopwatch()
    public var timers: [ToolboxCountdown] = []
    public var clockReview = false
    public init() {}
    public var isValid: Bool {
        version == 1 && revision < UInt64.max - 1_000_000 && stopwatch.isValid &&
        timers.count <= Self.maximumTimers && Set(timers.map(\.id)).count == timers.count && timers.allSatisfy(\.isValid)
    }
    /// Reboot or a clock discontinuity during process absence is uncertain:
    /// recover a bounded value, pause it and ask the user to check it.
    public mutating func recover(at now: ToolboxTimeSample) {
        if let start = stopwatch.started, !now.elapsed(since: start).continuous {
            stopwatch.pause(at: now); clockReview = true
        }
        for i in timers.indices {
            // AlarmKit owns enabled timers across process death and reboot.
            // Reconcile its actual state before changing a local generation.
            if timers[i].reminder { continue }
            if let start = timers[i].started, !now.elapsed(since: start).continuous {
                timers[i].pause(at: now); clockReview = true
            } else { _ = timers[i].finishIfNeeded(at: now) }
        }
    }
}

public actor ToolboxTimekeepingStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ToolboxTimekeepingArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 524_288 else { throw ToolboxTimekeepingError.corruptArchive }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value: ToolboxTimekeepingArchive
        do { value = try decoder.decode(ToolboxTimekeepingArchive.self, from: Data(contentsOf: url)) }
        catch { throw ToolboxTimekeepingError.corruptArchive }
        guard value.isValid else { throw ToolboxTimekeepingError.corruptArchive }
        return value
    }
    public func save(_ value: ToolboxTimekeepingArchive) throws {
        guard value.isValid else { throw ToolboxTimekeepingError.invalid }
        let existing = try load() // Preserve a corrupt archive until it can be recovered.
        guard value.revision >= existing.revision else { throw ToolboxTimekeepingError.staleArchive }
        try commit(value)
    }
    /// Explicit user recovery keeps the original bytes before replacing them.
    public func rebuildPreservingOriginal() throws -> ToolboxTimekeepingArchive {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("state-recovery-" + UUID().uuidString + ".json")
            try manager.copyItem(at: url, to: backup)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: backup.path)
            #endif
        }
        let empty = ToolboxTimekeepingArchive()
        try commit(empty)
        return empty
    }
    private func commit(_ value: ToolboxTimekeepingArchive) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard data.count <= 524_288 else { throw ToolboxTimekeepingError.limit }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum ToolboxTimeText {
    public static func duration(_ seconds: Double, hundredths: Bool = false) -> String {
        let value = max(0, min(ToolboxStopwatch.maximumElapsed, seconds.isFinite ? seconds : 0))
        let total = Int(value)
        let text = String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        return hundredths ? text + String(format: ".%02d", Int(value * 100) % 100) : text
    }
}

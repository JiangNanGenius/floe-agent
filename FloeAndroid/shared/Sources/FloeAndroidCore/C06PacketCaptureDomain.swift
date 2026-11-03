// SPDX-License-Identifier: MPL-2.0
//
// C06 — live packet capture contract.
//
// The Android App host owns the real VpnService/root broker data plane. This
// Swift domain owns the closed wire vocabulary, owner/limit validation, and a
// deterministic session registry used to prove monotonic capture state before
// the App publishes a terminal result. It never captures, forwards, reads a
// file or invents a root capability.
import Foundation

public enum C06CaptureWire {
    public static let version = 10
    public static let schema = "floe.capture/10"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 65_536
    public static let operations: [String] = [
        "handshake",
        "c06.capture.begin",
        "c06.capture.update",
        "c06.capture.finish",
        "c06.capture.status",
        "c06.capture.cancelAll",
    ]
}

public struct C06CaptureError: Error, Equatable, Sendable {
    public let code: String
    public let reason: String

    public init(_ code: String, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public static let invalidRequest = C06CaptureError("invalidRequest", "request")
    public static let requestTooLarge = C06CaptureError("requestTooLarge", "requestBytes")
    public static let unsupportedOperation = C06CaptureError("unsupportedOperation", "operation")
    public static let invalidOwner = C06CaptureError("invalidOwner", "owner")
    public static let invalidMode = C06CaptureError("invalidMode", "mode")
    public static let invalidLimits = C06CaptureError("invalidLimits", "limits")
    public static let invalidPhase = C06CaptureError("invalidPhase", "phase")
    public static let sessionLimit = C06CaptureError("sessionLimit", "session")
    public static let staleSession = C06CaptureError("staleSession", "session")
    public static let counterRegression = C06CaptureError("counterRegression", "counters")
    public static let invalidAnalysis = C06CaptureError("invalidAnalysis", "analysisID")
    public static let invalidSnapshot = C06CaptureError("invalidSnapshot", "snapshot")
}

public enum C06CaptureMode: String, CaseIterable, Sendable, Equatable {
    case vpn
    case root
}

public enum C06CapturePhase: String, Sendable, Equatable {
    case consentRequired
    case starting
    case running
    case stopping
    case finalizing
    case completed
    case failed
    case unsupported
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .unsupported, .cancelled: return true
        default: return false
        }
    }

    public var isCollecting: Bool {
        self == .running || self == .stopping
    }

    /// Closed phase transitions for host-reported snapshots.
    public func canTransition(to next: C06CapturePhase) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.consentRequired, .starting), (.consentRequired, .cancelled):
            return true
        case (.starting, .running), (.starting, .failed), (.starting, .cancelled):
            return true
        case (.running, .stopping), (.running, .failed):
            return true
        case (.stopping, .finalizing), (.stopping, .failed), (.stopping, .cancelled):
            return true
        case (.finalizing, .completed), (.finalizing, .failed):
            return true
        default:
            return false
        }
    }
}

public enum C06CaptureLimits {
    public static let vpnDurationMillis: Int64 = 15 * 60 * 1_000
    public static let rootDurationMillis: Int64 = 5 * 60 * 1_000
    public static let maximumBytes: Int64 = 128 * 1024 * 1024
    public static let maximumPackets: Int64 = 2_000_000
    public static let maximumOwnerBytes = 128
    public static let maximumFailureBytes = 240
    public static let maximumLimitations = 16

    public static func durationLimit(for mode: C06CaptureMode) -> Int64 {
        mode == .root ? rootDurationMillis : vpnDurationMillis
    }
}

public struct C06CaptureOwner: Equatable, Sendable {
    public let ownerID: String
    public let nativeEpoch: Int64
    public let taskID: String?
    public let runID: String?
    public let workspaceID: String?
    public let projectID: String?
    public let environmentID: String?
    public let jobID: String?

    public init(ownerID: String, nativeEpoch: Int64, taskID: String? = nil,
                runID: String? = nil, workspaceID: String? = nil,
                projectID: String? = nil, environmentID: String? = nil,
                jobID: String? = nil) throws {
        guard C06CaptureOwner.bounded(ownerID), nativeEpoch > 0 else {
            throw C06CaptureError.invalidOwner
        }
        for value in [taskID, runID, workspaceID, projectID, environmentID, jobID] {
            if let value, !C06CaptureOwner.bounded(value) { throw C06CaptureError.invalidOwner }
        }
        self.ownerID = ownerID
        self.nativeEpoch = nativeEpoch
        self.taskID = taskID
        self.runID = runID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.environmentID = environmentID
        self.jobID = jobID
    }

    public static func parse(_ value: Any?) throws -> C06CaptureOwner {
        guard let object = value as? [String: Any],
              let ownerID = c06String(object["ownerId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
              let epoch = c06Int64(object["nativeEpoch"]) else {
            throw C06CaptureError.invalidOwner
        }
        return try C06CaptureOwner(
            ownerID: ownerID,
            nativeEpoch: epoch,
            taskID: c06String(object["taskId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
            runID: c06String(object["runId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
            workspaceID: c06String(object["workspaceId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
            projectID: c06String(object["projectId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
            environmentID: c06String(object["environmentId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
            jobID: c06String(object["jobId"], maxBytes: C06CaptureLimits.maximumOwnerBytes),
        )
    }

    public var wire: [String: Any] {
        var value: [String: Any] = ["ownerId": ownerID, "nativeEpoch": nativeEpoch]
        if let taskID { value["taskId"] = taskID }
        if let runID { value["runId"] = runID }
        if let workspaceID { value["workspaceId"] = workspaceID }
        if let projectID { value["projectId"] = projectID }
        if let environmentID { value["environmentId"] = environmentID }
        if let jobID { value["jobId"] = jobID }
        return value
    }

    private static func bounded(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= C06CaptureLimits.maximumOwnerBytes &&
            value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}

public struct C06CaptureRequest: Equatable, Sendable {
    public let owner: C06CaptureOwner
    public let mode: C06CaptureMode
    public let detailed: Bool
    public let durationMillis: Int64
    public let maxBytes: Int64
    public let maxPackets: Int64
    public let mtu: Int
    public let sessionName: String

    public init(owner: C06CaptureOwner, mode: C06CaptureMode, detailed: Bool,
                durationMillis: Int64, maxBytes: Int64, maxPackets: Int64,
                mtu: Int = 1_500, sessionName: String = "Floe capture") throws {
        guard durationMillis > 0,
              durationMillis <= C06CaptureLimits.durationLimit(for: mode),
              maxBytes > 0, maxBytes <= C06CaptureLimits.maximumBytes,
              maxPackets > 0, maxPackets <= C06CaptureLimits.maximumPackets,
              (576...9_000).contains(mtu),
              !sessionName.isEmpty, sessionName.utf8.count <= 64 else {
            throw C06CaptureError.invalidLimits
        }
        self.owner = owner
        self.mode = mode
        self.detailed = detailed
        self.durationMillis = durationMillis
        self.maxBytes = maxBytes
        self.maxPackets = maxPackets
        self.mtu = mtu
        self.sessionName = sessionName
    }

    public static func parse(_ value: Any?) throws -> C06CaptureRequest {
        guard let object = value as? [String: Any],
              let modeValue = c06String(object["mode"], maxBytes: 16),
              let mode = C06CaptureMode(rawValue: modeValue),
              let duration = c06Int64(object["durationMillis"]),
              let maxBytes = c06Int64(object["maxBytes"]),
              let maxPackets = c06Int64(object["maxPackets"]) else {
            throw C06CaptureError.invalidRequest
        }
        return try C06CaptureRequest(
            owner: try C06CaptureOwner.parse(object["owner"]),
            mode: mode,
            detailed: (object["detailed"] as? Bool) ?? false,
            durationMillis: duration,
            maxBytes: maxBytes,
            maxPackets: maxPackets,
            mtu: c06Int(object["mtu"]) ?? 1_500,
            sessionName: c06String(object["sessionName"], maxBytes: 64) ?? "Floe capture",
        )
    }

    public var wire: [String: Any] {
        [
            "owner": owner.wire,
            "mode": mode.rawValue,
            "detailed": detailed,
            "durationMillis": durationMillis,
            "maxBytes": maxBytes,
            "maxPackets": maxPackets,
            "mtu": mtu,
            "sessionName": sessionName,
        ]
    }
}

public struct C06CaptureSnapshot: Equatable, Sendable {
    public let sessionID: String
    public let phase: C06CapturePhase
    public let capturedPackets: Int64
    public let capturedBytes: Int64
    public let droppedPackets: Int64
    public let analysisID: String?
    public let rawCaptureID: String?
    public let endReason: String?
    public let failureCode: String?
    public let stopRequested: Bool
    public let limitations: [String]

    public init(sessionID: String, phase: C06CapturePhase,
                capturedPackets: Int64, capturedBytes: Int64,
                droppedPackets: Int64, analysisID: String? = nil,
                rawCaptureID: String? = nil, endReason: String? = nil,
                failureCode: String? = nil, stopRequested: Bool = false,
                limitations: [String] = []) throws {
        guard UUID(uuidString: sessionID) != nil,
              capturedPackets >= 0, capturedBytes >= 0, droppedPackets >= 0,
              limitations.count <= C06CaptureLimits.maximumLimitations,
              limitations.allSatisfy({ $0.utf8.count <= C06CaptureLimits.maximumFailureBytes }),
              failureCode == nil || C06CaptureSnapshot.validCode(failureCode!) else {
            throw C06CaptureError.invalidSnapshot
        }
        if let analysisID, UUID(uuidString: analysisID) == nil {
            throw C06CaptureError.invalidAnalysis
        }
        self.sessionID = sessionID
        self.phase = phase
        self.capturedPackets = capturedPackets
        self.capturedBytes = capturedBytes
        self.droppedPackets = droppedPackets
        self.analysisID = analysisID
        self.rawCaptureID = rawCaptureID
        self.endReason = endReason
        self.failureCode = failureCode
        self.stopRequested = stopRequested
        self.limitations = limitations
    }

    public static func parse(_ value: Any?) throws -> C06CaptureSnapshot {
        guard let object = value as? [String: Any],
              let sessionID = c06String(object["sessionId"], maxBytes: 64),
              let phaseValue = c06String(object["phase"], maxBytes: 24),
              let phase = C06CapturePhase(rawValue: phaseValue),
              let packets = c06Int64(object["capturedPackets"]),
              let bytes = c06Int64(object["capturedBytes"]),
              let dropped = c06Int64(object["droppedPackets"]) else {
            throw C06CaptureError.invalidRequest
        }
        let limitations = (object["limitations"] as? [Any])?
            .compactMap { c06String($0, maxBytes: C06CaptureLimits.maximumFailureBytes) } ?? []
        return try C06CaptureSnapshot(
            sessionID: sessionID,
            phase: phase,
            capturedPackets: packets,
            capturedBytes: bytes,
            droppedPackets: dropped,
            analysisID: c06String(object["analysisId"], maxBytes: 64),
            rawCaptureID: c06String(object["rawCaptureId"], maxBytes: 64),
            endReason: c06String(object["endReason"], maxBytes: 64),
            failureCode: c06String(object["failureCode"], maxBytes: 64),
            stopRequested: (object["stopRequested"] as? Bool) ?? false,
            limitations: limitations,
        )
    }

    public var wire: [String: Any] {
        var value: [String: Any] = [
            "sessionId": sessionID,
            "phase": phase.rawValue,
            "capturedPackets": capturedPackets,
            "capturedBytes": capturedBytes,
            "droppedPackets": droppedPackets,
            "stopRequested": stopRequested,
            "limitations": limitations,
        ]
        if let analysisID { value["analysisId"] = analysisID }
        if let rawCaptureID { value["rawCaptureId"] = rawCaptureID }
        if let endReason { value["endReason"] = endReason }
        if let failureCode { value["failureCode"] = failureCode }
        return value
    }

    private static func validCode(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }
}

public struct C06RootPolicy: Equatable, Sendable {
    public let available: Bool
    public let code: String?
    public let helperID: String?
    public let helperPath: String?

    public init(available: Bool, code: String? = nil, helperID: String? = nil,
                helperPath: String? = nil) throws {
        guard available == (code == nil) else { throw C06CaptureError.invalidRequest }
        if let helperPath, !helperPath.hasPrefix("/") { throw C06CaptureError.invalidRequest }
        self.available = available
        self.code = code
        self.helperID = helperID
        self.helperPath = helperPath
    }

    public static func evaluate(playBuild: Bool, rootEnabled: Bool,
                                helperPath: String?) -> C06RootPolicy {
        if playBuild {
            return try! C06RootPolicy(available: false, code: "playBuild")
        }
        if !rootEnabled {
            return try! C06RootPolicy(available: false, code: "rootNotEnabled")
        }
        if helperPath == nil || !helperPath!.hasPrefix("/") {
            return try! C06RootPolicy(available: false, code: "helperUnavailable")
        }
        return try! C06RootPolicy(available: true, helperID: "tcpdump-v1", helperPath: helperPath)
    }

    public var wire: [String: Any] {
        var value: [String: Any] = ["available": available]
        if let code { value["code"] = code }
        if let helperID { value["helperId"] = helperID }
        if let helperPath { value["helperPath"] = helperPath }
        return value
    }
}

/// One in-memory contract registry. It is not the capture data plane; it
/// rejects non-monotonic or impossible host snapshots before the App can show
/// a completed capture. The real Kotlin host remains the execution authority.
public final class C06CaptureRegistry: @unchecked Sendable {
    public static let shared = C06CaptureRegistry()

    private struct Entry {
        let request: C06CaptureRequest
        var snapshot: C06CaptureSnapshot
        let sequence: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextSequence = 0

    public init() {}

    public func begin(_ request: C06CaptureRequest) throws -> C06CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries.values where !entry.snapshot.phase.isTerminal {
            throw C06CaptureError.sessionLimit
        }
        let sessionID = UUID().uuidString
        let snapshot = try C06CaptureSnapshot(
            sessionID: sessionID,
            phase: request.mode == .root ? .starting : .consentRequired,
            capturedPackets: 0,
            capturedBytes: 0,
            droppedPackets: 0,
        )
        nextSequence += 1
        entries[sessionID] = Entry(request: request, snapshot: snapshot, sequence: nextSequence)
        return snapshot
    }

    public func update(_ snapshot: C06CaptureSnapshot) throws -> C06CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[snapshot.sessionID] else {
            throw C06CaptureError.staleSession
        }
        let previous = entry.snapshot
        guard !previous.phase.isTerminal else { throw C06CaptureError.invalidPhase }
        guard previous.phase.canTransition(to: snapshot.phase) else {
            throw C06CaptureError.invalidPhase
        }
        guard snapshot.capturedPackets >= previous.capturedPackets,
              snapshot.capturedBytes >= previous.capturedBytes,
              snapshot.droppedPackets >= previous.droppedPackets else {
            throw C06CaptureError.counterRegression
        }
        if snapshot.phase == .completed || snapshot.phase == .failed ||
            snapshot.phase == .unsupported || snapshot.phase == .cancelled {
            throw C06CaptureError.invalidPhase
        }
        if previous.phase == .running && snapshot.phase == .running && snapshot.stopRequested {
            throw C06CaptureError.invalidPhase
        }
        if previous.stopRequested && !snapshot.stopRequested {
            throw C06CaptureError.invalidPhase
        }
        entry.snapshot = snapshot
        entries[snapshot.sessionID] = entry
        return snapshot
    }

    public func finish(_ snapshot: C06CaptureSnapshot) throws -> C06CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[snapshot.sessionID] else {
            throw C06CaptureError.staleSession
        }
        guard snapshot.phase.isTerminal, entry.snapshot.stopRequested else {
            throw C06CaptureError.invalidPhase
        }
        guard entry.snapshot.phase != .finalizing || snapshot.phase == .completed ||
            snapshot.phase == .failed else {
            throw C06CaptureError.invalidPhase
        }
        guard snapshot.capturedPackets >= entry.snapshot.capturedPackets,
              snapshot.capturedBytes >= entry.snapshot.capturedBytes,
              snapshot.droppedPackets >= entry.snapshot.droppedPackets else {
            throw C06CaptureError.counterRegression
        }
        if snapshot.phase == .completed && snapshot.analysisID == nil {
            throw C06CaptureError.invalidAnalysis
        }
        entry.snapshot = snapshot
        entries[snapshot.sessionID] = entry
        return snapshot
    }

    /// A cancel request is not a stopped state. The terminal snapshot still
    /// has to arrive through finish().
    @discardableResult
    public func requestCancel(sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[sessionID], !entry.snapshot.phase.isTerminal else {
            return false
        }
        let current = entry.snapshot
        entry.snapshot = try! C06CaptureSnapshot(
            sessionID: current.sessionID,
            phase: current.phase,
            capturedPackets: current.capturedPackets,
            capturedBytes: current.capturedBytes,
            droppedPackets: current.droppedPackets,
            analysisID: current.analysisID,
            rawCaptureID: current.rawCaptureID,
            endReason: current.endReason,
            failureCode: current.failureCode,
            stopRequested: true,
            limitations: current.limitations,
        )
        entries[sessionID] = entry
        return true
    }

    public func cancelAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let ids = entries.compactMap { id, entry in
            entry.snapshot.phase.isTerminal ? nil : id
        }
        var cancelled = 0
        for id in ids where requestCancelLocked(id) {
            cancelled += 1
        }
        return cancelled
    }

    public func snapshot(sessionID: String) -> C06CaptureSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return entries[sessionID]?.snapshot
    }

    public func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { !$0.snapshot.phase.isTerminal }.count
    }

    public func activeSnapshots() -> [C06CaptureSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values
            .sorted { $0.sequence < $1.sequence }
            .map(\.snapshot)
            .filter { !$0.phase.isTerminal }
    }

    public func reset() {
        lock.lock()
        entries.removeAll()
        nextSequence = 0
        lock.unlock()
    }

    private func requestCancelLocked(_ sessionID: String) -> Bool {
        guard var entry = entries[sessionID], !entry.snapshot.phase.isTerminal else {
            return false
        }
        let current = entry.snapshot
        entry.snapshot = try! C06CaptureSnapshot(
            sessionID: current.sessionID,
            phase: current.phase,
            capturedPackets: current.capturedPackets,
            capturedBytes: current.capturedBytes,
            droppedPackets: current.droppedPackets,
            analysisID: current.analysisID,
            rawCaptureID: current.rawCaptureID,
            endReason: current.endReason,
            failureCode: current.failureCode,
            stopRequested: true,
            limitations: current.limitations,
        )
        entries[sessionID] = entry
        return true
    }
}

func c06String(_ value: Any?, maxBytes: Int) -> String? {
    guard let text = value as? String, !text.isEmpty,
          text.utf8.count <= maxBytes else { return nil }
    return text
}

func c06Int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
}

func c06Int64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return nil
}

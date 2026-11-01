import Foundation

public enum BridgeTunnelSnapshotPolicy {
    public static let schema = 1
    public static let maximumPayloadBytes = 8_192
    public static let stalenessSeconds: TimeInterval = 10
    public static let requestTimeoutSeconds: TimeInterval = 1.5
    public static let sampleIntervalSeconds: TimeInterval = 2
    public static let maximumSampleSeconds: TimeInterval = 1_800
    public static let maximumUptimeSeconds: Double = 366 * 24 * 60 * 60
    public static let note = "Read from the existing PacketTunnelProvider.handleAppMessage snapshot. Counters are packet counts, not payload bytes; no packet content is read."
}

public enum BridgeTunnelSnapshotState: String, Codable, Sendable {
    case none
    case available
    case timeout
    case unavailable
}

/// Why no provider snapshot was produced. Fixed categories only; never a raw
/// error description that might contain an address or platform detail.
public enum BridgeTunnelSnapshotUnavailable: String, Codable, Sendable {
    case noConfiguration = "no-configuration"
    case notConnected = "not-connected"
    case notProviderSession = "not-provider-session"
    case sendFailed = "send-failed"
    case messageFailed = "message-failed"
    case malformedResponse = "malformed-response"
}

public enum BridgeTunnelProviderSnapshotRead: Equatable, Sendable {
    case available(BridgeTunnelProviderSnapshot)
    case timeout
    case unavailable(BridgeTunnelSnapshotUnavailable)
}

/// Strictly validated readback of the extension's existing app-message
/// snapshot. The parser fails closed on a wrong schema, a missing field, a
/// foreign tunnel address pair, an inconsistent counter or an oversized
/// payload; a malformed response is never presented as a tunnel state.
public struct BridgeTunnelProviderSnapshot: Codable, Equatable, Sendable {
    public var schema: Int
    public var epoch: UInt64
    public var startedAt: String?
    public var uptimeSeconds: Double?
    public var readLoopActive: Bool
    public var shouldRun: Bool
    public var received: UInt64
    public var reflected: UInt64
    public var rejected: UInt64
    public var fragments: UInt64
    public var lastRejection: String?
    public var receivedAt: String

    public init(
        schema: Int = BridgeTunnelSnapshotPolicy.schema,
        epoch: UInt64,
        startedAt: String? = nil,
        uptimeSeconds: Double? = nil,
        readLoopActive: Bool,
        shouldRun: Bool,
        received: UInt64,
        reflected: UInt64,
        rejected: UInt64,
        fragments: UInt64,
        lastRejection: String? = nil,
        receivedAt: String
    ) {
        self.schema = schema
        self.epoch = epoch
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.readLoopActive = readLoopActive
        self.shouldRun = shouldRun
        self.received = received
        self.reflected = reflected
        self.rejected = rejected
        self.fragments = fragments
        self.lastRejection = lastRejection
        self.receivedAt = receivedAt
    }

    public static func parse(_ data: Data, receivedAt: Date = Date()) -> BridgeTunnelProviderSnapshot? {
        guard data.count <= BridgeTunnelSnapshotPolicy.maximumPayloadBytes else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        guard let schema = integer(root["schema"]), schema == BridgeTunnelSnapshotPolicy.schema else {
            return nil
        }
        guard let epoch = unsigned(root["epoch"]), epoch > 0 else { return nil }
        guard let readLoopActive = boolean(root["readLoopActive"]),
              let shouldRun = boolean(root["shouldRun"]) else { return nil }
        guard let reflector = root["reflector"] as? [String: Any] else { return nil }
        guard let received = unsigned(reflector["received"]),
              let reflected = unsigned(reflector["reflected"]),
              let rejected = unsigned(reflector["rejected"]),
              let fragments = unsigned(reflector["fragments"]) else { return nil }
        // Each packet increments `received` and exactly one of reflected or
        // rejected, and only a rejected fragment increments `fragments`.
        guard reflected <= received, rejected <= received, fragments <= rejected else {
            return nil
        }
        guard reflector["interfaceAddress"] as? String == BridgeTransport.interfaceAddress,
              reflector["peerAddress"] as? String == BridgeTransport.peerAddress else {
            return nil
        }

        var startedAt: String?
        if let raw = root["startedAt"] {
            guard let text = raw as? String, text.utf8.count <= 64 else { return nil }
            startedAt = text.isEmpty ? nil : text
        }
        var uptimeSeconds: Double?
        if let raw = root["uptimeSeconds"] {
            guard let value = finiteDouble(raw),
                  value >= 0,
                  value <= BridgeTunnelSnapshotPolicy.maximumUptimeSeconds else {
                return nil
            }
            uptimeSeconds = value
        }
        var lastRejection: String?
        if let raw = reflector["lastRejection"] {
            guard let text = raw as? String,
                  !text.isEmpty,
                  text.utf8.count <= 32,
                  BridgeAtomicFile.safeIdentifier(text) == text else {
                return nil
            }
            lastRejection = text
        }

        return BridgeTunnelProviderSnapshot(
            epoch: epoch,
            startedAt: startedAt,
            uptimeSeconds: uptimeSeconds,
            readLoopActive: readLoopActive,
            shouldRun: shouldRun,
            received: received,
            reflected: reflected,
            rejected: rejected,
            fragments: fragments,
            lastRejection: lastRejection,
            receivedAt: BridgeClock.timestamp(receivedAt)
        )
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "epoch": epoch,
            "readLoopActive": readLoopActive,
            "shouldRun": shouldRun,
            "received": received,
            "reflected": reflected,
            "rejected": rejected,
            "fragments": fragments,
            "receivedAt": receivedAt,
            "interfaceAddress": BridgeTransport.interfaceAddress,
            "peerAddress": BridgeTransport.peerAddress,
        ]
        if let startedAt { value["startedAt"] = startedAt }
        if let uptimeSeconds { value["uptimeSeconds"] = uptimeSeconds }
        if let lastRejection { value["lastRejection"] = lastRejection }
        return value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        // Only small integral values are valid here (the extension schema is
        // 1). Bounding well below Int.max avoids a Double-to-Int trap.
        guard double.isFinite,
              double.rounded() == double,
              abs(double) <= 1_000_000_000 else { return nil }
        return Int(double)
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double <= 9_007_199_254_740_992,
              double.rounded() == double else { return nil }
        return UInt64(double)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

/// Latest/short-lived tunnel counter status exposed in `/v1/status`.
public struct BridgeTunnelSnapshotStatus: Codable, Equatable, Sendable {
    public var schema: Int
    public var state: BridgeTunnelSnapshotState
    public var sequence: UInt64
    public var samples: Int
    public var samplerHostPid: Int32
    public var samplerIsCurrentProcess: Bool
    public var probeGeneration: UInt64
    public var attemptedAt: String?
    public var ageMilliseconds: Int?
    public var stale: Bool
    public var errorCategory: String?
    public var snapshot: BridgeTunnelProviderSnapshot?
    public var snapshotAgeMilliseconds: Int?
    public var snapshotStale: Bool
    public var note: String

    public init(
        schema: Int = 1,
        state: BridgeTunnelSnapshotState,
        sequence: UInt64,
        samples: Int,
        samplerHostPid: Int32,
        samplerIsCurrentProcess: Bool,
        probeGeneration: UInt64,
        attemptedAt: String? = nil,
        ageMilliseconds: Int? = nil,
        stale: Bool = false,
        errorCategory: String? = nil,
        snapshot: BridgeTunnelProviderSnapshot? = nil,
        snapshotAgeMilliseconds: Int? = nil,
        snapshotStale: Bool = false,
        note: String = BridgeTunnelSnapshotPolicy.note
    ) {
        self.schema = schema
        self.state = state
        self.sequence = sequence
        self.samples = samples
        self.samplerHostPid = samplerHostPid
        self.samplerIsCurrentProcess = samplerIsCurrentProcess
        self.probeGeneration = probeGeneration
        self.attemptedAt = attemptedAt
        self.ageMilliseconds = ageMilliseconds
        self.stale = stale
        self.errorCategory = errorCategory
        self.snapshot = snapshot
        self.snapshotAgeMilliseconds = snapshotAgeMilliseconds
        self.snapshotStale = snapshotStale
        self.note = note
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "state": state.rawValue,
            "sequence": sequence,
            "samples": samples,
            "samplerHostPid": samplerHostPid,
            "samplerIsCurrentProcess": samplerIsCurrentProcess,
            "probeGeneration": probeGeneration,
            "stale": stale,
            "snapshotStale": snapshotStale,
            "note": note,
        ]
        if let attemptedAt { value["attemptedAt"] = attemptedAt }
        if let ageMilliseconds { value["ageMilliseconds"] = ageMilliseconds }
        if let errorCategory { value["errorCategory"] = errorCategory }
        if let snapshot { value["snapshot"] = snapshot.dictionary() }
        if let snapshotAgeMilliseconds { value["snapshotAgeMilliseconds"] = snapshotAgeMilliseconds }
        return value
    }
}

/// Process-wide store for the newest accepted tunnel snapshot sample.
///
/// One sampler request is in flight at a time; a result carrying an older
/// sequence is ignored so a late callback or an old timeout cannot overwrite a
/// newer observation. Staleness is computed when the status is read, so a
/// last-known snapshot is never presented as current.
public final class BridgeTunnelSnapshotStore: @unchecked Sendable {
    public static let shared = BridgeTunnelSnapshotStore()

    private let lock = NSLock()
    private var issuedSequence: UInt64 = 0
    private var acceptedSequence: UInt64 = 0
    private var attempted: Date?
    private var resultAt: Date?
    private var state: BridgeTunnelSnapshotState = .none
    private var errorCategory: String?
    private var lastSnapshot: BridgeTunnelProviderSnapshot?
    private var lastSnapshotAt: Date?
    private var samples = 0
    private var samplerHostPid: Int32 = 0
    private var probeGeneration: UInt64 = 0

    public init() {}

    @discardableResult
    public func beginRequest(
        hostPid: Int32,
        generation: UInt64,
        at date: Date = Date()
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        issuedSequence &+= 1
        samplerHostPid = hostPid
        probeGeneration = generation
        attempted = date
        return issuedSequence
    }

    /// Records one completed sample. Only monotonic, already-issued sequences
    /// are accepted; everything else is a late or fabricated result.
    @discardableResult
    public func record(
        _ read: BridgeTunnelProviderSnapshotRead,
        sequence: UInt64,
        at date: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > acceptedSequence, sequence <= issuedSequence else { return false }
        acceptedSequence = sequence
        resultAt = date
        samples &+= 1
        switch read {
        case .available(let snapshot):
            state = .available
            errorCategory = nil
            lastSnapshot = snapshot
            lastSnapshotAt = date
        case .timeout:
            state = .timeout
            errorCategory = "deadline"
        case .unavailable(let reason):
            state = .unavailable
            errorCategory = reason.rawValue
        }
        return true
    }

    public func status(
        at now: Date = Date(),
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) -> BridgeTunnelSnapshotStatus {
        lock.lock()
        defer { lock.unlock() }
        let age = resultAt.map { milliseconds(from: $0, to: now) }
        let snapshotAge = lastSnapshotAt.map { milliseconds(from: $0, to: now) }
        return BridgeTunnelSnapshotStatus(
            state: state,
            sequence: acceptedSequence,
            samples: samples,
            samplerHostPid: samplerHostPid,
            samplerIsCurrentProcess: samplerHostPid == processIdentifier,
            probeGeneration: probeGeneration,
            attemptedAt: attempted.map { BridgeClock.timestamp($0) },
            ageMilliseconds: age,
            stale: age.map { $0 > Int(BridgeTunnelSnapshotPolicy.stalenessSeconds * 1000) } ?? false,
            errorCategory: errorCategory,
            snapshot: lastSnapshot,
            snapshotAgeMilliseconds: snapshotAge,
            snapshotStale: snapshotAge.map {
                $0 > Int(BridgeTunnelSnapshotPolicy.stalenessSeconds * 1000)
            } ?? false
        )
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite else { return 0 }
        return max(0, Int(min(seconds, 86_400) * 1000))
    }
}

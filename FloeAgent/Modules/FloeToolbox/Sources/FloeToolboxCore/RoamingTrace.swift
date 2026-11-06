import Foundation

public enum RoamingWiFiStatus: String, Codable, Sendable { case wifi, notWiFi, unavailable, notObserved }
public enum RoamingProbeResult: Codable, Equatable, Sendable {
    case reply(milliseconds: Double), timeout, notAttempted
}
/// Measurements supplied by the host's authorized Wi-Fi and reachability services.
/// Missing identity or signal stays missing; an NWPath update is not an AP handoff.
public struct RoamingObservation: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let uptime: TimeInterval
    public let status: RoamingWiFiStatus
    public let ssid: String?
    public let bssid: String?
    public let signalDBM: Int?
    public let probe: RoamingProbeResult
    public init(timestamp: Date = Date(), uptime: TimeInterval, status: RoamingWiFiStatus,
                ssid: String? = nil, bssid: String? = nil, signalDBM: Int? = nil,
                probe: RoamingProbeResult = .notAttempted) {
        self.timestamp = timestamp; self.uptime = uptime; self.status = status
        self.ssid = ssid; self.bssid = bssid?.lowercased(); self.signalDBM = signalDBM; self.probe = probe
    }
    func validate() throws {
        guard timestamp.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0,
              (ssid?.utf8.count ?? 0) <= 32 else { throw ToolboxError.invalid("Wi-Fi observation") }
        if let bssid {
            let parts = bssid.split(separator:":",omittingEmptySubsequences:false)
            guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }),
                  bssid.lowercased() != "00:00:00:00:00:00", bssid.lowercased() != "ff:ff:ff:ff:ff:ff" else {
                throw ToolboxError.invalid("BSSID")
            }
        }
        if let signalDBM, !(-127 ... -1).contains(signalDBM) { throw ToolboxError.invalid("measured RSSI") }
        if status != .wifi, ssid != nil || bssid != nil || signalDBM != nil { throw ToolboxError.invalid("Wi-Fi status and identity") }
        if case .reply(let ms) = probe, !ms.isFinite || ms < 0 || ms > 600_000 { throw ToolboxError.invalid("probe latency") }
    }
}
public struct RoamingConfiguration: Codable, Equatable, Sendable {
    public let target: String
    public let identityInterval: TimeInterval
    public let probeInterval: TimeInterval
    public let maximumSamples: Int
    public let maximumEvents: Int
    public init(target: String, identityInterval: TimeInterval = 1, probeInterval: TimeInterval = 1,
                maximumSamples: Int = 1800, maximumEvents: Int = 256) throws {
        self.target = target; self.identityInterval = identityInterval; self.probeInterval = probeInterval
        self.maximumSamples = maximumSamples; self.maximumEvents = maximumEvents
        try validate()
    }
    func validate() throws {
        guard !target.isEmpty, target.utf8.count <= 253,
              !target.contains(where:{ "@/\\?#".contains($0) || $0.isWhitespace }),
              !target.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
              identityInterval.isFinite, (0.1...60).contains(identityInterval), probeInterval.isFinite,
              (0.1...60).contains(probeInterval), (2...10_000).contains(maximumSamples),
              (1...2000).contains(maximumEvents) else { throw ToolboxError.invalid("roaming configuration") }
    }
}
public struct RoamingSample: Codable, Equatable, Sendable, Identifiable {
    public let sequence: UInt64
    public let observation: RoamingObservation
    public var id: UInt64 { sequence }
    public func captureEvent() throws -> CaptureEvent {
        CaptureEvent(bytes:try JSONEncoder().encode(self),direction:.observation,layer:.applicationBytes,
            timestamp:observation.timestamp,notes:["Wi-Fi roaming observation; not a captured network packet"])
    }
}
public struct RoamingEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case accessPointChanged, networkChanged, identityUnavailable, identityRestored, observationGap
    }
    public let sequence: UInt64
    public let kind: Kind
    public let observedAt: Date
    public let previousObservedAt: Date?
    public let fromBSSID: String?
    public let toBSSID: String?
    public var id: String { "\(sequence):\(kind.rawValue)" }
}
public struct RoamingSnapshot: Codable, Equatable, Sendable {
    public let configuration: RoamingConfiguration
    public let samples: [RoamingSample]
    public let events: [RoamingEvent]
    public let droppedSamples: UInt64
    public let droppedEvents: UInt64
    public let totalAccessPointChanges: UInt64
    /// Metrics refer to retained samples; unavailable probes are excluded from the denominator.
    public var probesSent: Int { samples.filter { $0.observation.probe != .notAttempted }.count }
    public var probesLost: Int { samples.filter { $0.observation.probe == .timeout }.count }
    public var packetLoss: Double? { probesSent == 0 ? nil : Double(probesLost)/Double(probesSent) }
    public var meanLatencyMilliseconds: Double? {
        let values = samples.compactMap { sample -> Double? in
            if case let .reply(ms) = sample.observation.probe { ms } else { nil }
        }
        return values.isEmpty ? nil : values.reduce(0,+)/Double(values.count)
    }
}

/// Pure bounded recorder. The host owns polling, task/session cancellation and persistence.
/// Call captureEvent() on accepted samples and persist with the existing CaptureJournal.
public struct RoamingTrace: Sendable {
    public let configuration: RoamingConfiguration
    private var samples: [RoamingSample] = []
    private var events: [RoamingEvent] = []
    private var nextSequence: UInt64 = 1
    private var lastIdentityObservation: RoamingObservation?
    private var droppedSamples: UInt64 = 0, droppedEvents: UInt64 = 0, totalChanges: UInt64 = 0
    public init(configuration: RoamingConfiguration) throws { try configuration.validate(); self.configuration = configuration }
    public var snapshot: RoamingSnapshot {
        RoamingSnapshot(configuration:configuration,samples:samples,events:events,droppedSamples:droppedSamples,
            droppedEvents:droppedEvents,totalAccessPointChanges:totalChanges)
    }
    public mutating func append(_ observation: RoamingObservation) throws -> RoamingSample {
        try observation.validate()
        guard nextSequence < UInt64.max else { throw ToolboxError.limit("roaming sequence") }
        if let previous = samples.last?.observation, observation.uptime < previous.uptime { throw ToolboxError.invalid("nonmonotonic observation") }
        let old = lastIdentityObservation
        var additions: [RoamingEvent] = []
        func add(_ kind: RoamingEvent.Kind) {
            additions.append(RoamingEvent(sequence:nextSequence,kind:kind,observedAt:observation.timestamp,
                previousObservedAt:old?.timestamp,fromBSSID:old?.bssid,toBSSID:observation.bssid))
        }
        if observation.status != .notObserved {
            let known = observation.status == .wifi && observation.bssid != nil
            let wasKnown = old?.status == .wifi && old?.bssid != nil
            let gap = old.map { observation.uptime - $0.uptime > configuration.identityInterval * 2.5 } ?? false
            if gap { add(.observationGap) }
            if !known, old == nil || wasKnown { add(.identityUnavailable) }
            else if known, old != nil, !wasKnown { add(.identityRestored) }
            if !gap, let old, old.status == .wifi, observation.status == .wifi,
               let previousSSID = old.ssid, let currentSSID = observation.ssid {
                if previousSSID != currentSSID { add(.networkChanged) }
                else if let previous = old.bssid, let current = observation.bssid, previous.lowercased() != current.lowercased() {
                    add(.accessPointChanged)
                }
            }
        }
        let changeCount = UInt64(additions.filter { $0.kind == .accessPointChanged }.count)
        let sampleDrop = max(0,samples.count+1-configuration.maximumSamples)
        let eventDrop = max(0,events.count+additions.count-configuration.maximumEvents)
        guard totalChanges <= UInt64.max-changeCount, droppedSamples <= UInt64.max-UInt64(sampleDrop),
              droppedEvents <= UInt64.max-UInt64(eventDrop) else { throw ToolboxError.limit("roaming counters") }
        let sample = RoamingSample(sequence:nextSequence,observation:observation)
        samples.append(sample); events.append(contentsOf:additions)
        if observation.status != .notObserved { lastIdentityObservation = observation }
        if sampleDrop > 0 { samples.removeFirst(sampleDrop) }; if eventDrop > 0 { events.removeFirst(eventDrop) }
        nextSequence += 1; droppedSamples += UInt64(sampleDrop); droppedEvents += UInt64(eventDrop); totalChanges += changeCount
        return sample
    }
}

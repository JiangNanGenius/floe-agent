import Foundation
import CoreLocation
#if os(macOS)
import CoreWLAN
#endif
import FloeToolboxCore
import FloeToolboxDiagnostics

public enum MacWiFiPermissionStatus: String, Equatable, Sendable {
    case notDetermined, denied, restricted, authorizedWhenInUse, authorizedAlways, unknown
}

public struct MacWiFiPermissionSnapshot: Equatable, Sendable {
    public let status: MacWiFiPermissionStatus
    public let locationServicesEnabled: Bool
    public let canReadIdentity: Bool
    public let detail: String

    public init(status: MacWiFiPermissionStatus, locationServicesEnabled: Bool,
                canReadIdentity: Bool, detail: String) {
        self.status = status
        self.locationServicesEnabled = locationServicesEnabled
        self.canReadIdentity = canReadIdentity
        self.detail = detail
    }

    public static let unknown = MacWiFiPermissionSnapshot(
        status: .unknown, locationServicesEnabled: false, canReadIdentity: false,
        detail: "Location authorization could not be determined.")
}

public enum MacWiFiIdentityState: String, Equatable, Sendable {
    /// SSID and BSSID were returned by CoreWLAN.
    case observed
    /// CoreWLAN is available but Location Services is not authorized.
    case permissionRequired
    /// Permission is authorized, but the system did not return a usable AP identity.
    case systemDidNotProvideIdentity
    /// No Wi-Fi interface is available.
    case unavailable
    /// The Wi-Fi interface is powered off.
    case notConnected
}

/// One live read. Missing identity or RSSI stays missing; nothing is derived
/// from NWPath or a nearby network.
public struct MacWiFiObservation: Equatable, Sendable {
    public let status: RoamingWiFiStatus
    public let interfaceName: String?
    public let powerOn: Bool?
    public let ssid: String?
    public let bssid: String?
    public let signalDBM: Int?
    public let noiseDBM: Int?
    public let channel: Int?
    public let identityState: MacWiFiIdentityState
    public let permission: MacWiFiPermissionSnapshot

    public init(status: RoamingWiFiStatus, interfaceName: String? = nil, powerOn: Bool? = nil,
                ssid: String? = nil, bssid: String? = nil, signalDBM: Int? = nil,
                noiseDBM: Int? = nil, channel: Int? = nil,
                identityState: MacWiFiIdentityState, permission: MacWiFiPermissionSnapshot) {
        self.status = status
        self.interfaceName = interfaceName
        self.powerOn = powerOn
        self.ssid = ssid
        self.bssid = bssid
        self.signalDBM = signalDBM
        self.noiseDBM = noiseDBM
        self.channel = channel
        self.identityState = identityState
        self.permission = permission
    }

    /// The shared RoamingSampler accepts this compact identity. Identity is
    /// stripped unless the status is actually Wi-Fi.
    public var roamingIdentity: WiFiIdentity {
        guard status == .wifi else { return WiFiIdentity(status: status) }
        return WiFiIdentity(status: .wifi, ssid: ssid, bssid: bssid, signalDBM: signalDBM)
    }
}

public protocol MacWiFiProviding: Sendable {
    func permission() async -> MacWiFiPermissionSnapshot
    func observe() async -> MacWiFiObservation
    /// Best-effort current primary Wi-Fi gateway from the existing shared
    /// path service. Nil means "not provided", never a synthesized .1 address.
    func gateway() async -> String?
}

/// Read-only authorization probe. This type never requests permission.
/// CoreLocation manager access is kept on the main actor; iOS/macOS expect a
/// run-loop-affine manager even for a status read.
public enum MacWiFiPermissionProbe {
    public static func current() async -> MacWiFiPermissionSnapshot {
        await MainActor.run { readCurrent() }
    }

    static func currentGuarded(isCurrent: @escaping @Sendable () -> Bool) async throws -> MacWiFiPermissionSnapshot {
        try await guardedRead(isCurrent: isCurrent, read: { readCurrent() })
    }

    static func guardedRead(isCurrent: @escaping @Sendable () -> Bool,
                            read: @escaping @MainActor @Sendable () -> MacWiFiPermissionSnapshot) async throws -> MacWiFiPermissionSnapshot {
        try await MainActor.run {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            return read()
        }
    }

    private static func readCurrent() -> MacWiFiPermissionSnapshot {
        let servicesEnabled = CLLocationManager.locationServicesEnabled()
        let manager = CLLocationManager()
        let status: MacWiFiPermissionStatus
        switch manager.authorizationStatus {
        case .notDetermined: status = .notDetermined
        case .restricted: status = .restricted
        case .denied: status = .denied
        case .authorizedAlways: status = .authorizedAlways
        case .authorizedWhenInUse: status = .authorizedWhenInUse
        @unknown default: status = .unknown
        }
        let authorized = status == .authorizedAlways || status == .authorizedWhenInUse
        let canRead = servicesEnabled && authorized
        let detail: String
        if !servicesEnabled {
            detail = "Location Services is disabled for this Mac."
        } else if !authorized {
            detail = "Location Services authorization is required to read SSID/BSSID."
        } else {
            detail = "Location Services authorization allows SSID/BSSID reads when CoreWLAN supplies them."
        }
        return .init(status: status, locationServicesEnabled: servicesEnabled,
                     canReadIdentity: canRead, detail: detail)
    }

    static func validBSSID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.lowercased()
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (97...102).contains($0)
              } }),
              normalized != "00:00:00:00:00:00",
              normalized != "ff:ff:ff:ff:ff:ff" else { return nil }
        return normalized
    }
}

/// Live CoreWLAN reader. It reports the interface even when Wi-Fi is not the
/// primary route; it never substitutes an NWPath observation for an AP
/// identity and never invents RSSI.
public struct CoreWLANWiFiProvider: MacWiFiProviding {
    public init() {}

    public func permission() async -> MacWiFiPermissionSnapshot {
        await MacWiFiPermissionProbe.current()
    }

    public func observe() async -> MacWiFiObservation {
        let permission = await MacWiFiPermissionProbe.current()
        return await MainActor.run { Self.readObservation(permission) }
    }

    /// The manual host uses this guarded variant. The permission lookup can
    /// suspend; recheck its operation gate synchronously on MainActor in the
    /// same turn as the CoreWLAN read, so a prior cancellation cannot start it.
    func observeGuarded(isCurrent: @escaping @Sendable () -> Bool) async throws -> MacWiFiObservation {
        try await MacWiFiGuardedRead.run(isCurrent: isCurrent,
            permission: { try await MacWiFiPermissionProbe.currentGuarded(isCurrent: isCurrent) },
            read: { Self.readObservation($0) })
    }

    @MainActor
    private static func readObservation(_ permission: MacWiFiPermissionSnapshot) -> MacWiFiObservation {
        #if os(macOS)
        guard let interface = CWWiFiClient.shared().interface() else {
            return .init(status: .unavailable, identityState: .unavailable, permission: permission)
        }
        let power = interface.powerOn()
        guard power else {
            return .init(status: .notWiFi, interfaceName: interface.interfaceName, powerOn: false,
                         identityState: .notConnected, permission: permission)
        }
        guard permission.canReadIdentity else {
            return .init(status: .wifi, interfaceName: interface.interfaceName, powerOn: true,
                         identityState: .permissionRequired, permission: permission)
        }
        let ssid = interface.ssid().flatMap { $0.utf8.count <= 128 ? $0 : nil }
        let bssid = MacWiFiPermissionProbe.validBSSID(interface.bssid())
        let rssiValue = interface.rssiValue()
        let noiseValue = interface.noiseMeasurement()
        let signal = (-127 ... -1).contains(rssiValue) ? rssiValue : nil
        let noise = (-127 ... -1).contains(noiseValue) ? noiseValue : nil
        let channel = interface.wlanChannel()?.channelNumber
        let state: MacWiFiIdentityState = (ssid != nil || bssid != nil) ? .observed : .systemDidNotProvideIdentity
        return .init(status: .wifi, interfaceName: interface.interfaceName, powerOn: true,
                     ssid: ssid, bssid: bssid, signalDBM: signal, noiseDBM: noise,
                     channel: channel, identityState: state, permission: permission)
        #else
        return .init(status: .unavailable, identityState: .unavailable, permission: permission)
        #endif
    }

    public func gateway() async -> String? {
        try? await WiFiGatewayService.current()
    }
}

enum MacWiFiGuardedRead {
    static func run(isCurrent: @escaping @Sendable () -> Bool,
                    permission: @escaping @Sendable () async throws -> MacWiFiPermissionSnapshot,
                    read: @escaping @MainActor @Sendable (MacWiFiPermissionSnapshot) -> MacWiFiObservation) async throws -> MacWiFiObservation {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let value = try await permission()
        return try await MainActor.run {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            return read(value)
        }
    }
}

/// One user-owned roaming trace. It reuses the shared RoamingSampler and
/// CaptureJournal; the probe is the shared ICMP implementation fenced by this
/// session's own gate.
public actor MacRoamingSession {
    public nonisolated let lease: SessionLease
    public nonisolated let journal: CaptureJournal
    private let authorize: DiagnosticAuthorizer
    private let wifi: any MacWiFiProviding
    private let configuration: RoamingConfiguration
    private let diagnostics: DiagnosticService
    private let gate: MacRunGate
    private let sampler: RoamingSampler
    private var started = false
    private var closed = false

    public init(lease: SessionLease, configuration: RoamingConfiguration,
                journal: CaptureJournal, wifi: any MacWiFiProviding,
                authorize: @escaping DiagnosticAuthorizer) throws {
        guard journal.ownerID == lease.ownerID, journal.captureID == lease.sessionID else {
            throw ToolboxError.invalid("roaming ownership")
        }
        let gate = MacRunGate(lease: lease)
        let diagnostics = DiagnosticService(lease: lease,
            authorize: { expected, _, _ in gate.allow(expected) })
        self.lease = lease
        self.journal = journal
        self.authorize = authorize
        self.wifi = wifi
        self.configuration = configuration
        self.gate = gate
        self.diagnostics = diagnostics
        self.sampler = try RoamingSampler(lease: lease, configuration: configuration, journal: journal,
            identity: {
                let value = await wifi.observe()
                return value.roamingIdentity
            },
            probe: { target in
                guard let observation = try await diagnostics.ping(target: target, count: 1).first else {
                    return .timeout
                }
                if case .reply(let milliseconds) = observation.status {
                    return .reply(milliseconds: milliseconds)
                }
                return .timeout
            },
            authorize: { expected, _, _ in gate.allow(expected) })
    }

    public func start() async throws {
        guard !closed else { throw ToolboxError.staleSession }
        guard !started else { throw ToolboxError.invalid("roaming already started") }
        guard try await authorize(lease, configuration.target, .ping) else { throw ToolboxError.denied }
        guard !closed, gate.isOpen else { throw ToolboxError.staleSession }
        try await sampler.start()
        started = true
    }

    public func stop() async {
        started = false
        await sampler.stop()
    }

    public func snapshot() async -> RoamingSnapshot { await sampler.snapshot() }
    public func state() async -> (running: Bool, error: String?) { await sampler.state() }

    /// Ends the trace and the ICMP service. Late identity/probe results are
    /// fenced by the sampler's run identity and this gate.
    public func close() async {
        guard !closed else { return }
        closed = true
        gate.close()
        started = false
        await sampler.stop()
        await diagnostics.stop()
    }
}

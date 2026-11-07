import Foundation
@preconcurrency import Network
import FloeToolboxCore
#if os(iOS)
import NetworkExtension
#elseif os(macOS)
import CoreWLAN
#endif

public struct WiFiIdentity: Equatable, Sendable {
    public let status: RoamingWiFiStatus
    public let ssid: String?
    public let bssid: String?
    public let signalDBM: Int?
    public init(status: RoamingWiFiStatus, ssid: String? = nil, bssid: String? = nil, signalDBM: Int? = nil) {
        self.status = status; self.ssid = ssid; self.bssid = bssid; self.signalDBM = signalDBM
    }
}
private final class PathResult: @unchecked Sendable {
    let gate = WiFiCompletion<Bool>()
    let monitor = NWPathMonitor()
    func read() async throws -> Bool {
        monitor.pathUpdateHandler = { [gate] path in gate.finish(.success(path.usesInterfaceType(.wifi))) }
        monitor.start(queue:DispatchQueue(label:"floe.toolbox.wifi-path")); defer { monitor.cancel() }
        return try await gate.wait(seconds:2)
    }
}

/// Read the Wi-Fi path's actual router addresses. A subnet-derived .1 address
/// is not evidence of a gateway; cellular or unavailable Wi-Fi stays absent.
public enum WiFiGatewayService {
    public static func current() async throws -> String? {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let gate = WiFiCompletion<String?>()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { gate.finish(.success(nil)); return }
            let addresses = path.gateways.compactMap { endpoint -> (String, Bool)? in
                guard case .hostPort(let host, _) = endpoint else { return nil }
                switch host {
                case .ipv4(let address): return (String(describing: address), true)
                case .ipv6(let address): return (String(describing: address), false)
                default: return nil
                }
            }
            gate.finish(.success(addresses.first(where: { $0.1 })?.0 ?? addresses.first?.0))
        }
        monitor.start(queue: DispatchQueue(label: "floe.toolbox.wifi-gateway"))
        defer { monitor.cancel() }
        return try await gate.wait(seconds: 3)
    }
}
private final class WiFiCompletion<T:Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Result<T,any Error>?
    private var waiter: CheckedContinuation<T,any Error>?
    func finish(_ value: Result<T,any Error>) {
        lock.lock(); guard self.value == nil else { lock.unlock(); return }; self.value = value
        let waiter = self.waiter; self.waiter = nil; lock.unlock(); waiter?.resume(with:value)
    }
    func wait(seconds: Double) async throws -> T {
        let timer = Task { do { try await Task.sleep(for:.seconds(seconds)); finish(.failure(DiagnosticError.timedOut)) } catch {} }; defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock(); if let value { lock.unlock(); continuation.resume(with:value) } else { waiter = continuation; lock.unlock() }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}
public enum WiFiObservationService {
    /// The host checks existing location/Wi-Fi authorization and capabilities. This method
    /// never asks for permission, installs a profile or manufactures RSSI from NWPath.
    public static func current(mayReadIdentity: Bool) async throws -> WiFiIdentity {
        guard try await PathResult().read() else { return WiFiIdentity(status:.notWiFi) }
        guard mayReadIdentity else { return WiFiIdentity(status:.wifi) }
        #if os(iOS)
        let gate = WiFiCompletion<WiFiIdentity>()
        NEHotspotNetwork.fetchCurrent { network in
            gate.finish(.success(WiFiIdentity(status:.wifi,ssid:network?.ssid,bssid:network?.bssid)))
        }
        return try await gate.wait(seconds:3) // Ordinary apps cannot interpret signalStrength as measured RSSI.
        #elseif os(macOS)
        guard let interface = CWWiFiClient.shared().interface() else { return WiFiIdentity(status:.unavailable) }
        let rssi = interface.rssiValue()
        return WiFiIdentity(status:.wifi,ssid:interface.ssid(),bssid:interface.bssid(),signalDBM:(-127 ... -1).contains(rssi) ? rssi : nil)
        #else
        return WiFiIdentity(status:.unavailable)
        #endif
    }
}
public struct BonjourService: Hashable, Sendable {
    public let name: String; public let type: String; public let domain: String
}
public enum BonjourDiscovery {
    public static func browse(type: String, seconds: Double = 3, maximumResults: Int = 256) async throws -> [BonjourService] {
        guard seconds.isFinite, (0.1...30).contains(seconds), (1...1000).contains(maximumResults),
              type.utf8.count <= 64, type.hasPrefix("_"), type.hasSuffix("._tcp") || type.hasSuffix("._udp"),
              type.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw DiagnosticError.invalid("Bonjour service type") }
        let browser = NWBrowser(for:.bonjour(type:type,domain:"local."),using:.tcp)
        let box = BonjourResults(maximum:maximumResults), gate = WiFiCompletion<[BonjourService]>()
        browser.browseResultsChangedHandler = { results,_ in
            let values = results.compactMap { result -> BonjourService? in
                guard case .service(let name,let type,let domain,_) = result.endpoint,
                      name.utf8.count <= 256, domain.utf8.count <= 256 else { return nil }
                return BonjourService(name:name,type:type,domain:domain)
            }
            if !box.replace(values) { gate.finish(.failure(DiagnosticError.invalid("Bonjour result limit"))) }
        }
        browser.stateUpdateHandler = { state in if case .failed = state { gate.finish(.failure(DiagnosticError.system("Bonjour unavailable"))) } }
        browser.start(queue:DispatchQueue(label:"floe.toolbox.bonjour")); defer { browser.cancel() }
        let timer = Task { do { try await Task.sleep(for:.seconds(seconds)); gate.finish(.success(box.snapshot())) } catch {} }; defer { timer.cancel() }
        return try await gate.wait(seconds:seconds+1)
    }
}
private final class BonjourResults: @unchecked Sendable {
    private let lock = NSLock(); private var values: [BonjourService] = []; let maximum: Int
    init(maximum: Int) { self.maximum = maximum }
    func replace(_ values: [BonjourService]) -> Bool { lock.lock(); defer { lock.unlock() }; guard values.count <= maximum else { return false }; self.values = values; return true }
    func snapshot() -> [BonjourService] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.name < $1.name } }
}

/// Service-owned independent samplers. Stopping fences late provider replies; starting a new
/// run never changes the immutable target or turns probe latency into an AP observation.
public actor RoamingSampler {
    public typealias IdentityProvider = @Sendable () async throws -> WiFiIdentity
    public typealias ProbeProvider = @Sendable (String) async throws -> RoamingProbeResult
    public nonisolated let lease: SessionLease
    private let journal: CaptureJournal
    private let identity: IdentityProvider
    private let probe: ProbeProvider
    private let authorize: DiagnosticAuthorizer
    private var trace: RoamingTrace
    private var runID: UUID?
    private var identityTask: Task<Void,Never>?
    private var probeTask: Task<Void,Never>?
    private var lastError: String?
    public init(lease: SessionLease, configuration: RoamingConfiguration, journal: CaptureJournal,
                identity: @escaping IdentityProvider, probe: @escaping ProbeProvider, authorize: @escaping DiagnosticAuthorizer) throws {
        guard journal.ownerID == lease.ownerID, journal.captureID == lease.sessionID else { throw DiagnosticError.invalid("roaming ownership") }
        self.lease = lease; self.journal = journal; self.identity = identity; self.probe = probe; self.authorize = authorize
        trace = try RoamingTrace(configuration:configuration)
    }
    public func start() async throws {
        guard runID == nil, identityTask == nil, probeTask == nil else { throw DiagnosticError.busy }
        let id = UUID(); runID = id
        do {
            guard try await authorize(lease,trace.configuration.target,.ping), runID == id, !Task.isCancelled else { throw DiagnosticError.denied }
            trace = try RoamingTrace(configuration:trace.configuration); lastError = nil
            identityTask = Task { await self.sampleIdentity(id) }; probeTask = Task { await self.sampleProbe(id) }
        } catch { if runID == id { runID = nil }; throw error }
    }
    public func stop() { runID = nil; identityTask?.cancel(); probeTask?.cancel() }
    public func snapshot() -> RoamingSnapshot { trace.snapshot }
    public func state() -> (running:Bool,error:String?) { (runID != nil,lastError) }
    private func sampleIdentity(_ id: UUID) async {
        defer { identityTask = nil }
        do {
            while runID == id, !Task.isCancelled {
                let value = try await identity()
                guard runID == id, !Task.isCancelled else { return }
                try await record(RoamingObservation(uptime:ProcessInfo.processInfo.systemUptime,status:value.status,ssid:value.ssid,bssid:value.bssid,signalDBM:value.signalDBM),run:id)
                try await Task.sleep(for:.seconds(trace.configuration.identityInterval))
            }
        } catch { if runID == id, !Task.isCancelled { lastError = "Wi-Fi observation unavailable"; stop() } }
    }
    private func sampleProbe(_ id: UUID) async {
        defer { probeTask = nil }
        do {
            while runID == id, !Task.isCancelled {
                let value = try await probe(trace.configuration.target)
                guard runID == id, !Task.isCancelled else { return }
                try await record(RoamingObservation(uptime:ProcessInfo.processInfo.systemUptime,status:.notObserved,probe:value),run:id)
                try await Task.sleep(for:.seconds(trace.configuration.probeInterval))
            }
        } catch { if runID == id, !Task.isCancelled { lastError = "Connectivity probe unavailable"; stop() } }
    }
    private func record(_ observation: RoamingObservation, run: UUID) async throws {
        guard runID == run, !Task.isCancelled else { return }
        let sample = try trace.append(observation); var event = try sample.captureEvent(); event.notes.append("Run: "+run.uuidString)
        try await journal.append([event])
    }
}

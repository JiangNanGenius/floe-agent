// SPDX-License-Identifier: MPL-2.0
//
// Shared bounded LAN discovery core: scope, service model, scan report,
// status classification and the merge/resolve engine for the Toolbox `.lan`
// path and the `network.scanLAN` AI adapter (RQ33). One set of semantics,
// one engine. The live NWBrowser/DNS-SD browsing and resolution lives in the
// existing `FloeExecution.LANDiscoveryService` and is injected through the
// `LANDiscoveryProbe` seam — this module never browses on its own.
//
// Discovery is Bonjour/mDNS browsing over the service types the app actually
// declares in `NSBonjourServices`. iOS returns nothing for undeclared types,
// so those are reported as out-of-scope instead of pretending an empty scan
// proved "no devices". Address/port come from DNS-SD resolution only; an
// unresolved service never shows a fabricated IP or port, and a device
// without a Bonjour broadcast is never claimed or marked offline.

import Foundation

// MARK: - Scope

/// Presets shown in the Toolbox UI. Every preset list stays inside
/// `LANDiscoveryScope.declaredBonjourTypes`.
public enum LANDiscoveryPreset: String, CaseIterable, Sendable, Identifiable {
    case all, home, print, av, computers, web, custom
    public var id: String { rawValue }
}

/// The browsable discovery scope mirrors the app's `NSBonjourServices`
/// declarations in `project.yml`. If a type is added there, add it here.
public enum LANDiscoveryScope {
    public static let declaredBonjourTypes: [String] = [
        "_airplay._tcp", "_afpovertcp._tcp", "_googlecast._tcp", "_hap._tcp",
        "_home-assistant._tcp", "_http._tcp", "_https._tcp", "_ipp._tcp",
        "_ipps._tcp", "_printer._tcp", "_raop._tcp", "_rfb._tcp",
        "_sftp-ssh._tcp", "_smb._tcp", "_uscan._tcp", "_workstation._tcp"
    ]

    public static func types(for preset: LANDiscoveryPreset) -> [String] {
        switch preset {
        case .all: return declaredBonjourTypes
        case .home: return ["_hap._tcp", "_home-assistant._tcp"]
        case .print: return ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_uscan._tcp"]
        case .av: return ["_airplay._tcp", "_googlecast._tcp", "_raop._tcp"]
        case .computers: return ["_afpovertcp._tcp", "_rfb._tcp", "_sftp-ssh._tcp", "_smb._tcp", "_workstation._tcp"]
        case .web: return ["_http._tcp", "_https._tcp"]
        case .custom: return []
        }
    }

    /// Accepts only syntactically valid, declared types. Everything else is
    /// returned as rejected so callers can distinguish a typo/out-of-scope
    /// request from an empty-but-permitted scan.
    public static func normalize(_ requested: [String]) -> (accepted: [String], rejected: [String]) {
        var accepted: Set<String> = [], rejected: Set<String> = []
        let permitted = Set(declaredBonjourTypes)
        for raw in requested {
            let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "." }))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            if isPlausibleType(value), permitted.contains(value) { accepted.insert(value) }
            else { rejected.insert(String((value.isEmpty ? raw : value).prefix(64))) }
        }
        return (accepted.sorted(), rejected.sorted())
    }

    public static func isPlausibleType(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.hasPrefix("_")
            && (value.hasSuffix("._tcp") || value.hasSuffix("._udp"))
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
}

// MARK: - Observations and report

public struct LANDiscoveredService: Hashable, Sendable {
    public let name: String
    public let serviceType: String
    public let domain: String
    public internal(set) var interfaces: [String]
    /// Actual Network interface indices observed during browsing, not inferred from names.
    public internal(set) var interfaceIndices: [UInt32]
    /// DNS-SD service target hostname, only after a successful resolve.
    public internal(set) var targetHost: String?
    /// DNS-SD service port, only after a successful resolve.
    public internal(set) var port: Int?
    /// Resolved address literals; empty means unresolved, never fabricated.
    public internal(set) var addresses: [String]

    public init(name: String, serviceType: String, domain: String, interfaces: [String] = [],
                interfaceIndices: [UInt32] = [], targetHost: String? = nil, port: Int? = nil, addresses: [String] = []) {
        self.name = name; self.serviceType = serviceType; self.domain = domain
        self.interfaces = interfaces; self.interfaceIndices = Array(Set(interfaceIndices.filter { $0 > 0 }).sorted().prefix(4)); self.targetHost = targetHost; self.port = port
        self.addresses = addresses
    }
    public var key: String { "\(name)|\(serviceType)|\(domain)" }
    public var resolved: Bool { targetHost != nil && port != nil }
    /// Best verified reachable text: an IP literal first, then the resolved
    /// service target name. Empty when neither was obtained.
    public var displayAddress: String { addresses.first ?? targetHost ?? "" }
    public var displayPort: String { port.map(String.init) ?? "" }
}

public enum LANScanStatus: Equatable, Sendable {
    case foundDevices
    /// Browsing reached ready on a usable path with zero services:
    /// honest "no advertised devices", not a permission claim.
    case noDevices
    /// The system blocked browsing (waiting/failed state, likely local
    /// network permission or no usable route). Never reported as "no devices".
    case permissionUncertain
    /// Historical API spelling; means no usable Wi-Fi or wired local-network path.
    case noWiFiPath
    /// Every requested type was outside the declared discovery scope.
    case outOfScopeOnly
}

public enum LANDiscoveryEvent: Sendable {
    case serviceFound(LANDiscoveredService)
    case serviceResolved(LANDiscoveredService)
    case note(String)
}

public struct LANScanReport: Sendable {
    public let services: [LANDiscoveredService]
    public let browsedTypes: [String]
    public let rejectedTypes: [String]
    public let status: LANScanStatus
    public let notes: [String]
    public let truncated: Bool
    public let unresolvedCount: Int
    public let elapsedSeconds: Double

    public init(services: [LANDiscoveredService], browsedTypes: [String], rejectedTypes: [String],
                status: LANScanStatus, notes: [String], truncated: Bool, unresolvedCount: Int,
                elapsedSeconds: Double) {
        self.services = services; self.browsedTypes = browsedTypes; self.rejectedTypes = rejectedTypes
        self.status = status; self.notes = notes; self.truncated = truncated
        self.unresolvedCount = unresolvedCount; self.elapsedSeconds = elapsedSeconds
    }
}

// MARK: - Probe seam (production NWBrowser/DNS-SD or scripted test data)

public struct LANBrowseOutcome: Sendable {
    public let sawReady: Bool
    /// Non-nil when the system reported a blocking waiting/failed state.
    public let blockedReason: String?
    public init(sawReady: Bool, blockedReason: String?) { self.sawReady = sawReady; self.blockedReason = blockedReason }
}

public struct LANDiscoveryProbe: Sendable {
    /// Historical label retained for callers. The live probe accepts Wi-Fi and wired Ethernet.
    public var wifiAvailable: @Sendable (_ timeout: TimeInterval) async -> Bool
    /// Browses one type for the given window. The sink receives the latest
    /// full service set on each change; the engine merges and dedupes.
    public var browse: @Sendable (_ type: String, _ window: TimeInterval,
        _ sink: @escaping @Sendable ([LANDiscoveredService]) -> Void) async -> LANBrowseOutcome
    /// Resolves one service to target/port/addresses within the timeout.
    /// Nil fields mean "not obtained" — the caller must not invent values.
    public var resolve: @Sendable (_ service: LANDiscoveredService, _ timeout: TimeInterval)
        async -> (host: String?, port: Int?, addresses: [String], note: String?)

    public init(wifiAvailable: @escaping @Sendable (TimeInterval) async -> Bool,
                browse: @escaping @Sendable (String, TimeInterval, @escaping @Sendable ([LANDiscoveredService]) -> Void) async -> LANBrowseOutcome,
                resolve: @escaping @Sendable (LANDiscoveredService, TimeInterval) async -> (host: String?, port: Int?, addresses: [String], note: String?)) {
        self.wifiAvailable = wifiAvailable; self.browse = browse; self.resolve = resolve
    }
}

// MARK: - Engine

public enum LANDiscoveryEngine {
    public struct Request: Sendable {
        public let requestedTypes: [String]
        public let browseSeconds: Double
        public let resolveSeconds: Double
        public let maximumServices: Int
        public let maximumResolved: Int
        public init(requestedTypes: [String], browseSeconds: Double = 8, resolveSeconds: Double = 4,
                    maximumServices: Int = 256, maximumResolved: Int = 96) throws {
            guard browseSeconds.isFinite, (0.5...30).contains(browseSeconds),
                  resolveSeconds.isFinite, (0.5...15).contains(resolveSeconds),
                  (1...256).contains(maximumServices), (1...256).contains(maximumResolved),
                  !requestedTypes.isEmpty, requestedTypes.count <= 64
            else { throw DiagnosticError.invalid("LAN scan bounds") }
            self.requestedTypes = requestedTypes; self.browseSeconds = browseSeconds
            self.resolveSeconds = resolveSeconds; self.maximumServices = maximumServices
            self.maximumResolved = maximumResolved
        }
    }

    /// Runs one bounded multi-type scan through the injected probe (live
    /// NWBrowser/DNS-SD browsing lives in FloeExecution's LANDiscoveryService;
    /// tests inject scripted data). Cancelling the surrounding task stops the
    /// scan promptly.
    public static func scan(_ request: Request, probe: LANDiscoveryProbe,
                            onEvent: (@Sendable (LANDiscoveryEvent) -> Void)? = nil) async throws -> LANScanReport {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        let (accepted, rejected) = LANDiscoveryScope.normalize(request.requestedTypes)
        if accepted.isEmpty {
            return LANScanReport(services: [], browsedTypes: [], rejectedTypes: rejected,
                status: .outOfScopeOnly,
                notes: ["Requested types are outside the app-declared Bonjour scope: " + rejected.joined(separator: ", ")],
                truncated: false, unresolvedCount: 0, elapsedSeconds: measured(start))
        }
        let localNetwork = await probe.wifiAvailable(2)
        try Task.checkCancellation()
        if !localNetwork {
            return LANScanReport(services: [], browsedTypes: accepted, rejectedTypes: rejected,
                status: .noWiFiPath,
                notes: ["No satisfied local-network path; connect to the same Wi-Fi or wired network as the devices."],
                truncated: false, unresolvedCount: 0, elapsedSeconds: measured(start))
        }

        let box = ResultBox(maximum: request.maximumServices)
        var outcomes: [(type: String, outcome: LANBrowseOutcome)] = []
        outcomes.reserveCapacity(accepted.count)
        await withTaskGroup(of: (String, LANBrowseOutcome).self) { group in
            for type in accepted {
                group.addTask {
                    let outcome = await probe.browse(type, request.browseSeconds) { latest in
                        for service in box.merge(latest) { onEvent?(.serviceFound(service)) }
                    }
                    return (type, outcome)
                }
            }
            for await result in group { outcomes.append(result) }
        }
        try Task.checkCancellation()

        var notes: [String] = []
        if !rejected.isEmpty {
            notes.append("Skipped (outside declared discovery scope): " + rejected.joined(separator: ", "))
        }

        if box.snapshot().contains(where: { !$0.resolved }) {
            await resolvePhase(box: box, request: request, probe: probe, onEvent: onEvent, notes: &notes)
            try Task.checkCancellation()
        }

        let services = box.snapshot()
        let blocked = outcomes.compactMap { item -> String? in
            guard let reason = item.outcome.blockedReason else { return nil }
            return "\(item.type): \(reason)"
        }
        let status: LANScanStatus
        if !services.isEmpty {
            status = .foundDevices
            if !blocked.isEmpty {
                notes.append("Some service types did not complete: " + blocked.joined(separator: "; "))
            }
        } else if !blocked.isEmpty {
            status = .permissionUncertain
            notes.append(contentsOf: blocked)
        } else if outcomes.allSatisfy({ $0.outcome.sawReady }) {
            status = .noDevices
        } else {
            // No services, no explicit block and no confirmed ready browse:
            // stay honest instead of claiming the network is empty.
            status = .permissionUncertain
            notes.append("Browsing did not reach a ready state within the window.")
        }
        if box.truncatedReached {
            notes.append("Result limit reached; showing the first \(request.maximumServices) services.")
        }
        let unresolved = services.filter { !$0.resolved }.count
        if unresolved > 0 { notes.append("\(unresolved) service(s) did not resolve to an address/port.") }
        return LANScanReport(services: services, browsedTypes: accepted, rejectedTypes: rejected,
            status: status, notes: notes, truncated: box.truncatedReached,
            unresolvedCount: unresolved, elapsedSeconds: measured(start))
    }

    private static func resolvePhase(box: ResultBox, request: Request, probe: LANDiscoveryProbe,
                                     onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?,
                                     notes: inout [String]) async {
        let pending = box.snapshot().filter { !$0.resolved }
        let windowStart = ContinuousClock.now
        let chosen = Array(pending.prefix(request.maximumResolved))
        if pending.count > chosen.count {
            notes.append("Address resolution limited to \(chosen.count) of \(pending.count) services.")
        }
        for batchStart in stride(from: 0, to: chosen.count, by: 12) {
            if Task.isCancelled { break }
            if measured(windowStart) >= request.resolveSeconds {
                notes.append("Address resolution window ended; some services stay unresolved.")
                break
            }
            let batch = Array(chosen[batchStart..<min(batchStart + 12, chosen.count)])
            let remaining = max(0.4, request.resolveSeconds - measured(windowStart))
            await withTaskGroup(of: (String, (host: String?, port: Int?, addresses: [String], note: String?)).self) { group in
                for service in batch {
                    group.addTask {
                        let result = await probe.resolve(service, min(3, remaining))
                        return (service.key, result)
                    }
                }
                for await (key, result) in group {
                    if let updated = box.applyResolution(key: key, host: result.host, port: result.port, addresses: result.addresses) {
                        onEvent?(.serviceResolved(updated))
                    }
                    if let note = result.note { notes.append(note) }
                }
            }
        }
    }

    /// Thread-safe, bounded merge/replace collector for one scan.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var services: [String: LANDiscoveredService] = [:]
        private var order: [String] = []
        private let maximum: Int
        private var truncated = false
        var truncatedReached: Bool { lock.lock(); defer { lock.unlock() }; return truncated }
        init(maximum: Int) { self.maximum = maximum }
        /// Returns services newly added by this update (for events).
        func merge(_ latest: [LANDiscoveredService]) -> [LANDiscoveredService] {
            lock.lock(); defer { lock.unlock() }
            var added: [LANDiscoveredService] = []
            for incoming in latest.prefix(512) {
                guard incoming.name.utf8.count <= 256, incoming.domain.utf8.count <= 256 else { continue }
                if let existing = services[incoming.key] {
                    var merged = existing
                    merged.interfaces = Array(Set(existing.interfaces + incoming.interfaces).sorted().prefix(4))
                    merged.interfaceIndices = Array(Set(existing.interfaceIndices + incoming.interfaceIndices).filter { $0 > 0 }.sorted().prefix(4))
                    services[incoming.key] = merged
                    continue
                }
                if services.count >= maximum { truncated = true; continue }
                var stored = incoming
                stored.interfaces = Array(incoming.interfaces.prefix(4))
                services[incoming.key] = stored
                order.append(incoming.key)
                added.append(stored)
            }
            return added
        }
        func applyResolution(key: String, host: String?, port: Int?, addresses: [String]) -> LANDiscoveredService? {
            lock.lock(); defer { lock.unlock() }
            guard var service = services[key], service.targetHost == nil else { return nil }
            if let host, host.utf8.count <= 253 { service.targetHost = host }
            if let port, (1...65535).contains(port) { service.port = port }
            service.addresses = Array(addresses.prefix(8))
            services[key] = service
            return service
        }
        func snapshot() -> [LANDiscoveredService] {
            lock.lock(); defer { lock.unlock() }
            return order.compactMap { services[$0] }.sorted {
                if $0.serviceType != $1.serviceType { return $0.serviceType < $1.serviceType }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    static func measured(_ start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

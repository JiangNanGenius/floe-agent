// FloeExecution — Bonjour/mDNS LAN device discovery (RQ33 closure).
//
// This is the one existing LAN discovery service. It now owns the live
// browsing/resolution path (NWBrowser + DNS-SD) and drives it through the
// shared bounded core in FloeToolboxDiagnostics.LANDiscoveryEngine, so the
// AI tool `network.scanLAN` and the Toolbox `.lan` page (which receives this
// probe from the app host) share one scope, one permission semantics and one
// error taxonomy. No fabricated data: unresolved services never claim an
// address or port; empty-but-complete scans say "no advertised services in
// scope"; blocked browsing surfaces a typed error instead of an empty list.

import Foundation
import Darwin
@preconcurrency import Network
import dnssd
import FloeCore
import FloeToolboxDiagnostics

/// One discovered LAN service. `port == 0` with empty `addresses` means the
/// browse-only record did not resolve; callers must present it as unresolved
/// rather than as a usable endpoint.
public struct LANDiscoveryResult: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(name)-\(host)-\(port)" }
    public let name: String
    public let host: String
    public let port: Int
    public let serviceType: String
    public let domain: String
    /// Verified address literals (possibly empty when resolution failed).
    public let addresses: [String]

    public init(name: String, host: String, port: Int, serviceType: String, domain: String, addresses: [String] = []) {
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
        self.domain = domain
        self.addresses = addresses
    }

    public var isAddressResolved: Bool { !addresses.isEmpty && port > 0 }

    private enum CodingKeys: String, CodingKey {
        case name, host, port, serviceType, domain, addresses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        serviceType = try container.decode(String.self, forKey: .serviceType)
        domain = try container.decode(String.self, forKey: .domain)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(serviceType, forKey: .serviceType)
        try container.encode(domain, forKey: .domain)
        try container.encode(addresses, forKey: .addresses)
    }
}

/// The existing LAN discovery service: same public surface, one live
/// implementation now shared with the Toolbox `.lan` seam.
public struct LANDiscoveryService: Sendable {
    /// Mirrors the app-declared Bonjour scope (LANDiscoveryScope and the
    /// `NSBonjourServices` list in project.yml).
    public static var permittedServiceTypes: [String] { LANDiscoveryScope.declaredBonjourTypes }

    public init() {}

    /// Internal seam so focused tests drive the real classification with
    /// scripted scan reports while production uses the live probe.
    init(scan: @escaping @Sendable (LANDiscoveryEngine.Request, LANDiscoveryProbe) async throws -> LANScanReport) {
        self.scanOverride = scan
    }

    private var scanOverride: (@Sendable (LANDiscoveryEngine.Request, LANDiscoveryProbe) async throws -> LANScanReport)?

    public static func normalizedServiceTypes(_ requested: [String]?) throws -> [String] {
        let values = requested ?? permittedServiceTypes
        guard !values.isEmpty, values.count <= permittedServiceTypes.count else {
            throw FloeError.validationFailed("Choose between 1 and \(permittedServiceTypes.count) Bonjour service types")
        }
        let (accepted, rejected) = LANDiscoveryScope.normalize(values)
        guard rejected.isEmpty else {
            throw FloeError.validationFailed(FloeL10n.l("execution.l_a_n_discovery_service.lan_scanning_currently_supports_only_these", permittedServiceTypes.joined(separator: ", "))
            )
        }
        return accepted
    }

    /// The live browse/resolve implementation used by both LAN paths.
    public static var liveProbe: LANDiscoveryProbe { .landLive }

    /// Discovers devices advertising the given service types on the current
    /// local network. `timeoutSeconds` is the total budget: roughly three
    /// quarters for browsing and the rest for bounded address/port
    /// resolution. Cancelling the surrounding task stops the scan promptly.
    public func discover(
        serviceTypes: [String] = permittedServiceTypes,
        timeoutSeconds: Int = 5
    ) async throws -> [LANDiscoveryResult] {
        let normalized = try Self.normalizedServiceTypes(serviceTypes)
        let budget = min(max(Double(timeoutSeconds), 1), 30)
        let request = try LANDiscoveryEngine.Request(
            requestedTypes: normalized,
            browseSeconds: min(25, max(1, budget * 0.8)),
            resolveSeconds: min(10, max(0.5, budget * 0.2)))
        let report: LANScanReport
        if let scanOverride {
            report = try await scanOverride(request, Self.liveProbe)
        } else {
            report = try await LANDiscoveryEngine.scan(request, probe: Self.liveProbe)
        }
        switch report.status {
        case .permissionUncertain, .noWiFiPath:
            if report.services.isEmpty {
                let detail = report.notes.first ?? "browsing did not complete"
                throw FloeError.syncUnavailable(
                    "Local-network discovery did not complete (\(detail)). If no permission prompt appeared, enable Settings → Floe → Local Network, join the same local network as the devices, and retry. An empty scan while permission is granted only means no advertising services were found in the browsed scope."
                )
            }
        case .foundDevices, .noDevices, .outOfScopeOnly:
            break
        }
        return report.services.map { service in
            let host = service.addresses.first ?? service.targetHost
                ?? "\(service.name).\(service.serviceType).\(service.domain)"
            let domain = service.interfaces.first.map { "\(service.domain) [\($0)]" } ?? service.domain
            return LANDiscoveryResult(
                name: service.name,
                host: host,
                port: service.port ?? 0,
                serviceType: service.serviceType,
                domain: domain,
                addresses: service.addresses
            )
        }
    }
}

// MARK: - Live LAN probe (the only NWBrowser/DNS-SD implementation)

private extension LANDiscoveryProbe {
    static var landLive: LANDiscoveryProbe {
        LANDiscoveryProbe(
            wifiAvailable: { timeout in await LANLocalPath.available(timeout: timeout) },
            browse: { type, window, sink in await LANBonjourBrowser.browse(type: type, window: window, sink: sink) },
            resolve: { service, timeout in await LANResolver.resolve(service, timeout: timeout) }
        )
    }
}

/// Gate shared by the bounded live probe paths (first finish wins; bounded
/// wait with cancellation).
final class LANGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?
    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }
    func settledValue() -> T? {
        lock.lock(); defer { lock.unlock() }
        if case .success(let value)? = result { return value }
        return nil
    }
    func wait(seconds: Double) async throws -> T {
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)); finish(.failure(DiagnosticError.timedOut)) } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) }
                else { waiter = continuation; lock.unlock() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }
}

private enum LANLocalPath {
    /// `false` only when the local-network path read definitively reports unsatisfied
    /// within the grace window; ambiguity falls through to browsing, whose
    /// states classify permission/path problems honestly afterwards.
    static func available(timeout: TimeInterval) async -> Bool {
        let monitor = NWPathMonitor()
        let gate = LANGate<Bool>()
        monitor.pathUpdateHandler = { path in
            let hasLAN = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            gate.finish(.success(path.status == .satisfied && hasLAN))
        }
        monitor.start(queue: DispatchQueue(label: "org.floeagent.lan-path"))
        defer { monitor.cancel() }
        do { return try await gate.wait(seconds: timeout) }
        catch { return gate.settledValue() ?? true }
    }
}

/// One bounded NWBrowser run per service type. Mutable state is lock-guarded;
/// Network callbacks arrive on `queue` and teardown is re-issued there.
private enum LANBonjourBrowser {
    private final class Session: @unchecked Sendable {
        let gate = LANGate<LANBrowseOutcome>()
        private let lock = NSLock()
        private var browser: NWBrowser?
        private var sawReady = false
        private var blocked: String?
        func attach(_ browser: NWBrowser) { lock.lock(); self.browser = browser; lock.unlock() }
        func noteReady() { lock.lock(); sawReady = true; lock.unlock() }
        func noteBlocked(_ reason: String) { lock.lock(); if blocked == nil { blocked = reason }; lock.unlock() }
        func outcome() -> LANBrowseOutcome {
            lock.lock(); defer { lock.unlock() }
            return LANBrowseOutcome(sawReady: sawReady, blockedReason: blocked)
        }
        // Always called on the browser queue. Break Session → browser → handler → Session.
        func cancelBrowser() {
            lock.lock(); let browser = self.browser; self.browser = nil; lock.unlock()
            browser?.stateUpdateHandler = nil
            browser?.browseResultsChangedHandler = nil
            browser?.cancel()
        }
        static func ingest(_ results: Set<NWBrowser.Result>) -> [LANDiscoveredService] {
            results.compactMap { result in
                guard case .service(let name, let serviceType, let domain, _) = result.endpoint else { return nil }
                let interfaces = result.interfaces.compactMap { interface -> String? in "\(interface)" }.prefix(4)
                let indices = result.interfaces.compactMap { UInt32(exactly: $0.index) }
                return LANDiscoveredService(name: name, serviceType: serviceType, domain: domain,
                    interfaces: Array(interfaces), interfaceIndices: indices)
            }
        }
    }

    static func browse(type: String, window: TimeInterval,
                       sink: @escaping @Sendable ([LANDiscoveredService]) -> Void) async -> LANBrowseOutcome {
        let queue = DispatchQueue(label: "org.floeagent.lan-browse")
        let session = Session()
        return await withTaskCancellationHandler {
            queue.async {
                let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
                session.attach(browser)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .ready: session.noteReady()
                    case .waiting(let error): session.noteBlocked("waiting: \(error.localizedDescription)")
                    case .failed(let error):
                        session.noteBlocked("failed: \(error.localizedDescription)")
                        session.cancelBrowser()
                        session.gate.finish(.success(session.outcome()))
                    default: break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    sink(Session.ingest(results))
                }
                browser.start(queue: queue)
                queue.asyncAfter(deadline: .now() + window) {
                    session.cancelBrowser()
                    session.gate.finish(.success(session.outcome()))
                }
            }
            do { return try await session.gate.wait(seconds: window + 2) }
            catch {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    queue.async { session.cancelBrowser(); waiter.resume() }
                }
                return session.gate.settledValue() ?? session.outcome()
            }
        } onCancel: {
            queue.async {
                session.cancelBrowser()
                session.gate.finish(.success(session.outcome()))
            }
        }
    }
}

/// Bounded address/port resolution via DNSServiceResolve + address records.
/// Nothing is reported as resolved unless DNS-SD actually answered.
private enum LANResolver {
    static func resolve(_ service: LANDiscoveredService, timeout: TimeInterval) async
        -> (host: String?, port: Int?, addresses: [String], note: String?) {
        let budget = max(0.3, min(3, timeout))
        let start = ContinuousClock.now
        let interfaceIndex = service.interfaceIndices.first ?? 0
        do {
            let (target, port) = try await LANResolveQuery.run(name: service.name, type: service.serviceType,
                domain: service.domain, interfaceIndex: interfaceIndex, timeout: budget)
            var addresses: [String] = []
            for recordType in [DNSRecordType.a, DNSRecordType.aaaa] {
                guard addresses.count < 8 else { break }
                let elapsed = LANElapsed.measured(start)
                let remaining = budget - elapsed
                guard remaining > 0.2 else { break }
                if let records = try? await LANAddressQuery.run(name: target, type: recordType,
                    interfaceIndex: interfaceIndex, timeout: min(1.5, remaining)) {
                    addresses.append(contentsOf: records.prefix(4))
                }
            }
            return (target, port, Array(addresses.prefix(8)), nil)
        } catch is CancellationError {
            return (nil, nil, [], nil)
        } catch let error as DiagnosticError {
            switch error {
            case .timedOut:
                return (nil, nil, [], "resolve timed out for \(service.name) (\(service.serviceType))")
            default:
                return (nil, nil, [], "resolve did not complete for \(service.name) (\(service.serviceType))")
            }
        } catch {
            return (nil, nil, [], "resolve did not complete for \(service.name) (\(service.serviceType))")
        }
    }
}

enum LANElapsed {
    static func measured(_ start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Bounded DNSServiceResolve with deallocation on its owning queue.
private final class LANResolveQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.floeagent.lan-resolve")
    private var reference: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var requestedName = ""
    private let gate = LANGate<(String, Int)>()

    static func run(name: String, type: String, domain: String, interfaceIndex: UInt32, timeout: Double) async throws -> (String, Int) {
        let query = LANResolveQuery()
        do {
            let value = try await query.execute(name: name, type: type, domain: domain, interfaceIndex: interfaceIndex, timeout: timeout)
            await query.stop()
            return value
        } catch {
            await query.stop()
            throw error
        }
    }

    private func execute(name: String, type: String, domain: String, interfaceIndex: UInt32, timeout: Double) async throws -> (String, Int) {
        queue.async { [self] in
            requestedName = name
            let error = DNSServiceResolve(&reference, 0, interfaceIndex, name, type, domain, {
                _, flags, _, error, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let query = Unmanaged<LANResolveQuery>.fromOpaque(context).takeUnretainedValue()
                if error != kDNSServiceErr_NoError {
                    query.gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: error, name: query.requestedName, type: .a)))
                    return
                }
                guard flags & UInt32(kDNSServiceFlagsMoreComing) == 0, let hostTarget else { return }
                let target = String(cString: hostTarget).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard target.utf8.count <= 253, !target.utf8.isEmpty else {
                    query.gate.finish(.failure(DiagnosticError.invalid("resolve target")))
                    return
                }
                query.gate.finish(.success((target, Int(UInt16(bigEndian: port)))))
            }, Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError else {
                gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: error, name: name, type: .a)))
                return
            }
            guard let reference else {
                gate.finish(.failure(DiagnosticError.system("resolve returned no service reference")))
                return
            }
            let descriptor = DNSServiceRefSockFD(reference)
            guard descriptor >= 0 else {
                gate.finish(.failure(DiagnosticError.system("resolve unavailable")))
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in
                guard let self, let reference = self.reference else { return }
                let result = DNSServiceProcessResult(reference)
                if result != 0 {
                    self.gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: result, name: self.requestedName, type: .a)))
                }
            }
            source.resume()
        }
        do {
            let value = try await gate.wait(seconds: timeout)
            await stop()
            return value
        } catch {
            await stop()
            throw error
        }
    }

    private func stop() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                source?.cancel(); source = nil
                if let reference { DNSServiceRefDeallocate(reference) }
                reference = nil
                waiter.resume()
            }
        }
    }
}

/// Bounded A/AAAA lookup for a resolved service target, same queue-owned
/// shape as LANResolveQuery. Returns presentation strings only.
private final class LANAddressQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.floeagent.lan-address")
    private var reference: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var records: [String] = []
    private var requestedName = ""
    private let gate = LANGate<[String]>()

    static func run(name: String, type: DNSRecordType, interfaceIndex: UInt32, timeout: Double) async throws -> [String] {
        let query = LANAddressQuery()
        do {
            let value = try await query.execute(name: name, type: type, interfaceIndex: interfaceIndex, timeout: timeout)
            await query.stop()
            return value
        } catch {
            await query.stop()
            throw error
        }
    }

    private func execute(name: String, type: DNSRecordType, interfaceIndex: UInt32, timeout: Double) async throws -> [String] {
        queue.async { [self] in
            requestedName = name
            let error = DNSServiceQueryRecord(&reference, UInt32(kDNSServiceFlagsReturnIntermediates), interfaceIndex, name,
                type.rawValue, UInt16(kDNSServiceClass_IN), {
                _, flags, interfaceIndex, error, _, _, _, length, data, _, context in
                guard let context else { return }
                let query = Unmanaged<LANAddressQuery>.fromOpaque(context).takeUnretainedValue()
                if error != kDNSServiceErr_NoError {
                    query.gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: error, name: query.requestedName, type: .a)))
                    return
                }
                guard flags & UInt32(kDNSServiceFlagsAdd) != 0, let data, Int(length) == 4 || Int(length) == 16 else { return }
                let buffer = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: Int(length)))
                let presentation: String? = buffer.withUnsafeBytes { raw in
                    var text = [CChar](repeating: 0, count: Int(length == 4 ? INET_ADDRSTRLEN : INET6_ADDRSTRLEN))
                    if length == 4 {
                        var address = in_addr()
                        withUnsafeMutableBytes(of: &address) { addressBuffer in raw.copyBytes(to: addressBuffer) }
                        return inet_ntop(AF_INET, &address, &text, socklen_t(text.count)).map { String(cString: $0) }
                    } else {
                        var address = in6_addr()
                        withUnsafeMutableBytes(of: &address) { addressBuffer in raw.copyBytes(to: addressBuffer) }
                        return inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)).map { String(cString: $0) }
                    }
                }
                if let presentation, query.records.count < 8 {
                    // Link-local IPv6 needs its actually observed interface to remain usable.
                    let scoped = presentation.lowercased().hasPrefix("fe80:") && interfaceIndex > 0 ? presentation + "%\(interfaceIndex)" : presentation
                    if !query.records.contains(scoped) { query.records.append(scoped) }
                }
                if flags & UInt32(kDNSServiceFlagsMoreComing) == 0 { query.gate.finish(.success(query.records)) }
            }, Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError else {
                gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: error, name: name, type: type)))
                return
            }
            guard let reference else {
                gate.finish(.failure(DiagnosticError.system("address query returned no reference")))
                return
            }
            let descriptor = DNSServiceRefSockFD(reference)
            guard descriptor >= 0 else {
                gate.finish(.failure(DiagnosticError.system("address query unavailable")))
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in
                guard let self, let reference = self.reference else { return }
                let result = DNSServiceProcessResult(reference)
                if result != 0 {
                    self.gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: result, name: self.requestedName, type: .a)))
                }
            }
            source.resume()
        }
        do {
            let value = try await gate.wait(seconds: timeout)
            await stop()
            return value
        } catch {
            await stop()
            throw error
        }
    }

    private func stop() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                source?.cancel(); source = nil
                if let reference { DNSServiceRefDeallocate(reference) }
                reference = nil
                waiter.resume()
            }
        }
    }
}

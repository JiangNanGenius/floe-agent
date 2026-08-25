// FloeExecution — Bonjour/mDNS LAN device discovery.
//
// Scans the local network for mDNS-advertised services (Home Assistant,
// printers, smart devices) using NWBrowser. Returns a list of discovered
// devices with name, host, port, and service type. This is the iOS-native
// replacement for arp scanning (which iOS sandbox does not permit).

import Foundation
import Network
import FloeCore

/// One discovered LAN device.
public struct LANDiscoveryResult: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(name)-\(host)-\(port)" }
    public let name: String
    public let host: String
    public let port: Int
    public let serviceType: String
    public let domain: String

    public init(name: String, host: String, port: Int, serviceType: String, domain: String) {
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
        self.domain = domain
    }
}

/// Thread-safe collector for NWBrowser results.
private actor ResultCollector {
    private var results: [String: LANDiscoveryResult] = [:]
    private var failures: [String] = []
    private var connections: [RetainedConnection] = []
    private var stopped = false

    func upsert(_ result: LANDiscoveryResult, key: String) {
        results[key] = result
    }

    func get() -> [LANDiscoveryResult] {
        Array(results.values)
    }

    func recordFailure(_ message: String) {
        failures.append(message)
    }

    func failureSummary() -> String? {
        failures.first
    }

    func retain(_ connection: RetainedConnection) {
        guard !stopped else {
            connection.value.cancel()
            return
        }
        connections.append(connection)
    }

    func cancelConnections() {
        stopped = true
        connections.forEach { $0.value.cancel() }
        connections.removeAll()
    }
}

/// Network.framework reference types do not declare Sendable even though all
/// access below is confined to the discovery queue. This wrapper lets the
/// collector retain resolver connections until the bounded scan ends.
private final class RetainedConnection: @unchecked Sendable {
    let value: NWConnection

    init(_ value: NWConnection) {
        self.value = value
    }
}

/// Scans the local network for mDNS services.
public struct LANDiscoveryService: Sendable {
    public static let permittedServiceTypes = [
        "_home-assistant._tcp",
        "_http._tcp",
        "_printer._tcp",
        "_ipp._tcp",
        "_airplay._tcp",
        "_raop._tcp"
    ]

    public init() {}

    public static func normalizedServiceTypes(_ requested: [String]?) throws -> [String] {
        let values = requested ?? permittedServiceTypes
        guard !values.isEmpty, values.count <= permittedServiceTypes.count else {
            throw FloeError.validationFailed("Choose between 1 and \(permittedServiceTypes.count) Bonjour service types")
        }
        let normalized = values.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "." }))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
        }
        let permitted = Set(permittedServiceTypes)
        guard normalized.allSatisfy(permitted.contains) else {
            throw FloeError.validationFailed(
                "This build can scan only its declared Bonjour service types: \(permittedServiceTypes.joined(separator: ", "))"
            )
        }
        return Array(Set(normalized)).sorted()
    }

    /// Discovers devices advertising the given service types on the local
    /// network. `serviceTypes` defaults to common smart-home/HA types.
    /// `timeoutSeconds` caps the scan duration.
    public func discover(
        serviceTypes: [String] = permittedServiceTypes,
        timeoutSeconds: Int = 5
    ) async throws -> [LANDiscoveryResult] {
        let normalizedTypes = try Self.normalizedServiceTypes(serviceTypes)
        let collector = ResultCollector()
        let queue = DispatchQueue(label: "org.floeagent.landiscovery")
        var browsers: [NWBrowser] = []

        for serviceType in normalizedTypes {
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error):
                    // Local Network privacy denial is normally reported as a
                    // waiting DNS policy error, not `.failed`. Preserve it so
                    // an empty scan explains the permission problem instead
                    // of incorrectly claiming that no devices exist.
                    Task { await collector.recordFailure("\(serviceType): \(error.localizedDescription)") }
                case .failed(let error):
                    Task { await collector.recordFailure("\(serviceType): \(error.localizedDescription)") }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { newResults, _ in
                for result in newResults {
                    if case .service(let name, let type, let domain, let interface) = result.endpoint {
                        let serviceHost = "\(name).\(type).\(domain)"
                        let resultKey = "\(name)|\(type)|\(domain)"
                        Task {
                            await collector.upsert(LANDiscoveryResult(
                                name: name,
                                host: serviceHost,
                                port: 0,
                                serviceType: type,
                                domain: interface.map { "\(domain) [\($0)]" } ?? domain
                            ), key: resultKey)
                        }

                        // NWBrowser returns a Bonjour service endpoint, not
                        // the usable host/port promised by the tool. Resolve
                        // it with a bounded TCP connection and replace the
                        // fallback service name when resolution succeeds.
                        let connection = NWConnection(to: result.endpoint, using: .tcp)
                        let retained = RetainedConnection(connection)
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                                    Task {
                                        await collector.upsert(LANDiscoveryResult(
                                            name: name,
                                            host: "\(host)",
                                            port: Int(port.rawValue),
                                            serviceType: type,
                                            domain: interface.map { "\(domain) [\($0)]" } ?? domain
                                        ), key: resultKey)
                                    }
                                }
                                connection.cancel()
                            case .failed, .cancelled:
                                connection.cancel()
                            default:
                                break
                            }
                        }
                        Task { await collector.retain(retained) }
                        connection.start(queue: queue)
                    }
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
        defer { browsers.forEach { $0.cancel() } }
        do {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            try Task.checkCancellation()
        } catch {
            await collector.cancelConnections()
            throw error
        }
        await collector.cancelConnections()

        let allResults = await collector.get()
        let unique = allResults.sorted { lhs, rhs in
                if lhs.serviceType != rhs.serviceType { return lhs.serviceType < rhs.serviceType }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        if unique.isEmpty, let failure = await collector.failureSummary() {
            throw FloeError.syncUnavailable(
                "Local-network discovery was denied or unavailable (\(failure)). Enable Local Network access for Floe in Settings and try again."
            )
        }
        return unique
    }
}

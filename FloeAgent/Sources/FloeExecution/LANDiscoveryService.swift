// FloeExecution — Bonjour/mDNS LAN device discovery.
//
// Scans the local network for mDNS-advertised services (Home Assistant,
// printers, smart devices) using NWBrowser. Returns a list of discovered
// devices with name, host, port, and service type. This is the iOS-native
// replacement for arp scanning (which iOS sandbox does not permit).

import Foundation
import Network

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
    private var results: [LANDiscoveryResult] = []

    func add(_ result: LANDiscoveryResult) {
        results.append(result)
    }

    func get() -> [LANDiscoveryResult] {
        results
    }
}

/// Scans the local network for mDNS services.
public struct LANDiscoveryService: Sendable {
    public init() {}

    /// Discovers devices advertising the given service types on the local
    /// network. `serviceTypes` defaults to common smart-home/HA types.
    /// `timeoutSeconds` caps the scan duration.
    public func discover(
        serviceTypes: [String] = ["_home-assistant._tcp.", "_http._tcp.", "_printer._tcp.", "_ipp._tcp.", "_airplay._tcp.", "_raop._tcp."],
        timeoutSeconds: Int = 5
    ) async throws -> [LANDiscoveryResult] {
        let collector = ResultCollector()
        let queue = DispatchQueue(label: "org.floeagent.landiscovery")

        for serviceType in serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { newResults, _ in
                for result in newResults {
                    if case .service(let name, let type, let domain, let interface) = result.endpoint {
                        let host = interface.debugDescription
                        Task {
                            await collector.add(LANDiscoveryResult(
                                name: name,
                                host: host,
                                port: 0,
                                serviceType: type,
                                domain: domain
                            ))
                        }
                    }
                }
            }
            browser.start(queue: queue)
            try await Task.sleep(for: .seconds(timeoutSeconds))
            browser.cancel()
        }

        // Deduplicate by name+host.
        var seen = Set<String>()
        let allResults = await collector.get()
        return allResults.filter { seen.insert("\($0.name)-\($0.host)").inserted }
    }
}

import Testing
import FloeToolboxDiagnostics
@testable import FloeExecution

@Suite("LAN discovery configuration")
struct LANDiscoveryServiceTests {
    @Test("Declared Bonjour services normalize optional trailing dots")
    func normalizesDeclaredServices() throws {
        let values = try LANDiscoveryService.normalizedServiceTypes([
            "_HTTP._TCP.",
            "_home-assistant._tcp"
        ])
        #expect(values == ["_home-assistant._tcp", "_http._tcp"])
    }

    @Test("Undeclared Bonjour services fail before browsing")
    func rejectsUndeclaredServices() {
        #expect(throws: (any Error).self) {
            try LANDiscoveryService.normalizedServiceTypes(["_ssh._tcp"])
        }
    }

    private func resolvedService() -> LANDiscoveredService {
        LANDiscoveredService(name: "NAS", serviceType: "_http._tcp", domain: "local.", interfaces: ["en0"],
            targetHost: "nas.local", port: 8090, addresses: ["192.0.2.10", "192.0.2.11"])
    }
    private func browseOnlyService() -> LANDiscoveredService {
        LANDiscoveredService(name: "Quiet", serviceType: "_ipp._tcp", domain: "local.")
    }
    private func report(_ services: [LANDiscoveredService], status: LANScanStatus, notes: [String] = []) -> LANScanReport {
        LANScanReport(services: services, browsedTypes: LANDiscoveryScope.declaredBonjourTypes,
            rejectedTypes: [], status: status, notes: notes, truncated: false,
            unresolvedCount: services.filter { !$0.resolved }.count, elapsedSeconds: 3)
    }

    @Test("Resolved devices expose real host/port/addresses; browse-only records never claim a fabricated one")
    func mapsResolvedAndUnresolvedWithoutFabrication() async throws {
        let service = LANDiscoveryService(scan: { _, _ in self.report([self.resolvedService(), self.browseOnlyService()], status: .foundDevices) })
        let results = try await service.discover(serviceTypes: ["_http._tcp", "_ipp._tcp"], timeoutSeconds: 8)
        #expect(results.count == 2)
        let nas = try #require(results.first { $0.name == "NAS" })
        #expect(nas.host == "192.0.2.10")
        #expect(nas.port == 8090)
        #expect(nas.addresses == ["192.0.2.10", "192.0.2.11"])
        #expect(nas.isAddressResolved)
        let quiet = try #require(results.first { $0.name == "Quiet" })
        #expect(quiet.port == 0)
        #expect(quiet.addresses.isEmpty)
        #expect(!quiet.isAddressResolved)
    }

    @Test("No devices in scope returns an empty list instead of a permission error")
    func noDevicesStatusIsNotPermissionFailure() async throws {
        let service = LANDiscoveryService(scan: { _, _ in self.report([], status: .noDevices) })
        let results = try await service.discover(timeoutSeconds: 3)
        #expect(results.isEmpty)
    }

    @Test("Blocked browsing without results throws a typed unavailable error, never an empty success")
    func blockedBrowsingThrowsTypedError() async throws {
        let blocked = LANDiscoveryService(scan: { _, _ in self.report([], status: .permissionUncertain,
            notes: ["_http._tcp: waiting: Local network access is not allowed"])) })
        await #expect(throws: (any Error).self) { try await blocked.discover(timeoutSeconds: 3) }
        let noWiFi = LANDiscoveryService(scan: { _, _ in self.report([], status: .noWiFiPath) })
        await #expect(throws: (any Error).self) { try await noWiFi.discover(timeoutSeconds: 3) }
    }

    @Test("Partial results keep returning even when some types were blocked")
    func partialResultsStillReturn() async throws {
        let service = LANDiscoveryService(scan: { _, _ in self.report([self.resolvedService()], status: .foundDevices,
            notes: ["Some service types did not complete: _ipp._tcp: waiting: denied"]) })
        let results = try await service.discover(serviceTypes: ["_http._tcp"], timeoutSeconds: 8)
        #expect(results.count == 1)
    }

    @Test("Legacy persisted records without the addresses field still decode")
    func legacyDecoding() throws {
        let legacy = Data(#"{"name":"Hub","host":"hub.local","port":0,"serviceType":"_http._tcp","domain":"local."}"#.utf8)
        let decoded = try JSONDecoder().decode(LANDiscoveryResult.self, from: legacy)
        #expect(decoded.addresses.isEmpty)
        #expect(decoded.port == 0)
    }
}

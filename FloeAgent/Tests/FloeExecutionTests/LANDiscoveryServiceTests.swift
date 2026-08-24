import Testing
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
}

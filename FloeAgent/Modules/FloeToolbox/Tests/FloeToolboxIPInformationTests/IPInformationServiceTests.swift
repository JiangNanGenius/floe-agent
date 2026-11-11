// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeToolboxIPInformation

private actor IPTestGate {
    private(set) var entered = false
    private var released = false
    func pause() async {
        entered = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !released && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func open() { released = true }
}

@Suite("IP database service lifecycle", .serialized)
struct IPInformationServiceTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ip-service-" + UUID().uuidString) }
    private func install(_ service: IPInformationService, label: String = "fixture-a") async throws -> IPDatabaseMetadata {
        let id = try await service.startImport(city: fixture("GeoIP2-City-Test.mmdb"), asn: fixture("GeoLite2-ASN-Test.mmdb"),
            versionLabel: label, source: "MaxMind test data", attribution: "MaxMind-DB test data, MIT")
        return try await service.waitForUpdate(id)
    }
    private func entered(_ gate: IPTestGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
    }

    @Test func numericClassificationExcludesLocalReservedAndMappedPrivateWithoutDNS() throws {
        for address in ["0.0.0.0", "10.1.2.3", "100.64.1.1", "127.0.0.1", "169.254.1.1", "172.16.2.3", "192.168.0.1",
                        "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.1.1.1", "255.255.255.255",
                        "::", "::1", "::ffff:192.168.1.1", "fd00::1", "fe80::1", "2001:db8::1", "3fff::1", "ff02::1"] {
            #expect(try IPAddressClassification.classify(address) == .localOrSpecialUse)
        }
        for address in ["1.1.1.1", "8.8.8.8", "192.0.0.9", "2001:218::1", "2001:4860:4860::8888", "::ffff:8.8.8.8"] {
            #expect(try IPAddressClassification.classify(address) == .publicInternet)
        }
        #expect(throws: (any Error).self) { try IPAddressClassification.classify("example.com") }
        #expect(throws: (any Error).self) { try IPAddressClassification.classify("999.1.1.1") }
    }

    @Test func realMMDBImportLookupMissingFieldAndReopenRemainBoundToVersion() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder)
        let metadata = try await install(service)
        #expect(metadata.city.databaseType.contains("City") && metadata.asn.databaseType.contains("ASN"))
        #expect(metadata.attribution == "MaxMind-DB test data, MIT")
        let v4Value = try await service.lookup("214.78.120.1")
        let v4 = try #require(v4Value)
        let v6Value = try await service.lookup("2001:218::1")
        let v6 = try #require(v6Value)
        let asnValue = try await service.lookup("1.0.0.1")
        let asn = try #require(asnValue)
        let absentValue = try await service.lookup("12.81.96.1")
        let absent = try #require(absentValue)
        #expect(v4.countryCode == "US" && v6.countryCode == "JP")
        #expect(asn.autonomousSystemNumber == 15169 && absent.organization == nil)
        #expect(v4.datasetVersion == metadata.datasetVersion)
        let reopened = try IPInformationService(storageRoot: folder)
        #expect(await reopened.currentVersion() == metadata.datasetVersion)
        #expect(try await reopened.lookup("1.0.0.1")?.autonomousSystemNumber == 15169)
        #expect(try await service.lookup("192.168.1.1") == nil)
        #expect(try await service.lookup("1.0.0.1", expectedVersion: "stale") == nil)
        let provider = service.tracerouteProvider()
        #expect(try await provider.information(for: "1.0.0.1")?.autonomousSystemNumber == 15169)
    }

    @Test func concurrentCanonicalLookupsCoalesceAndCopyAddressForEachCaller() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder); _ = try await install(service)
        let gate = IPTestGate(); await service.testHooks(beforeLookup: { await gate.pause() })
        defer { Task { await gate.open() } }
        let first = Task { try await service.lookup("1.0.0.1") }
        try await entered(gate)
        let second = Task { try await service.lookup("::ffff:1.0.0.1") }
        try await Task.sleep(for: .milliseconds(20)); await gate.open()
        let a = try await first.value, b = try await second.value
        #expect(a?.address == "1.0.0.1" && b?.address == "::ffff:1.0.0.1")
        #expect(a?.autonomousSystemNumber == 15169 && b?.autonomousSystemNumber == 15169)
        #expect(await service.readerLookups == 1)
        _ = try await service.lookup("1.0.0.1")
        #expect(await service.readerLookups == 1)
    }

    @Test func swapDuringAnActualMappedReadFencesTheOldVersionAndClearsCache() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder); let old = try await install(service)
        let gate = IPTestGate(); await service.testHooks(beforeLookup: { await gate.pause() })
        defer { Task { await gate.open() } }
        let pending = Task { try await service.lookup("214.78.120.1", expectedVersion: old.datasetVersion) }
        try await entered(gate)
        _ = try await install(service, label: "fixture-b")
        let fresh = try await install(service, label: "fixture-c")
        #expect(fresh.datasetVersion != old.datasetVersion)
        let oldDirectory = folder.appendingPathComponent("Snapshots/" + old.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: oldDirectory.path))
        await gate.open()
        #expect(try await pending.value == nil)
        #expect(try await service.lookup("214.78.120.1", expectedVersion: fresh.datasetVersion)?.countryCode == "US")
        #expect(await service.readerLookups == 2)
        _ = try await install(service, label: "fixture-d")
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Snapshots").path).count == 2)
    }

    @Test func explicitCancellationJoinsThePreparedWorkerAndKeepsTheOldPointer() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder); let old = try await install(service)
        let gate = IPTestGate(); await service.testHooks(beforeCommit: { await gate.pause() })
        defer { Task { await gate.open() } }
        let id = try await service.startImport(city: fixture("GeoIP2-City-Test.mmdb"), asn: fixture("GeoLite2-ASN-Test.mmdb"), versionLabel: "cancelled")
        try await entered(gate); await service.cancelUpdate(id); await gate.open()
        await #expect(throws: (any Error).self) { _ = try await service.waitForUpdate(id) }
        #expect(await service.currentVersion() == old.datasetVersion)
        #expect(await service.state().phase == .cancelled)
        let reopened = try IPInformationService(storageRoot: folder)
        #expect(await reopened.currentVersion() == old.datasetVersion)
    }

    @Test func corruptWrongTypeAndOversizedImportsPreserveTheWorkingPair() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder); let old = try await install(service)
        for name in ["GeoIP2-City-Test-Invalid-Node-Count.mmdb", "GeoIP2-City-Test-Broken-Double-Format.mmdb",
                     "MaxMind-DB-test-broken-pointers-24.mmdb", "GeoLite2-ASN-Test.mmdb"] {
            let id = try await service.startImport(city: fixture(name), asn: fixture("GeoLite2-ASN-Test.mmdb"), versionLabel: "invalid")
            await #expect(throws: (any Error).self) { _ = try await service.waitForUpdate(id) }
            #expect(await service.currentVersion() == old.datasetVersion)
        }
        let huge = folder.appendingPathComponent("oversized.mmdb")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let file = try FileHandle(forWritingTo: huge); try file.truncate(atOffset: IPDatabaseStorage.maximumDatabaseBytes + 1); try file.close()
        let id = try await service.startImport(city: huge, asn: fixture("GeoLite2-ASN-Test.mmdb"), versionLabel: "too-big")
        await #expect(throws: (any Error).self) { _ = try await service.waitForUpdate(id) }
        #expect(await service.currentVersion() == old.datasetVersion)
    }

    @Test func failedDownloadKeepsCurrentDataAndNeverBuildsIPQueryURLs() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder, download: { url, _, _ in
            #expect(url.host == "download.db-ip.com" && url.query == nil && url.path.contains(".mmdb.gz"))
            throw IPInformationError.invalidDownload
        })
        let old = try await install(service)
        let id = try await service.startDefaultUpdate()
        await #expect(throws: (any Error).self) { _ = try await service.waitForUpdate(id) }
        #expect(await service.currentVersion() == old.datasetVersion)
        #expect(await service.state().phase == .failed)
        #expect(try await service.lookup("::ffff:10.0.0.1") == nil)
    }
}

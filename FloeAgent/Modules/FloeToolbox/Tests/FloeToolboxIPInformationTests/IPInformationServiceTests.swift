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

    /// Mutates a copy of the pinned small City fixture without changing MMDB
    /// offsets. Every assertion still goes through the real C reader/service.
    private func changedCity(in folder: URL, replacing original: Data, with replacement: Data) throws -> URL {
        try #require(!original.isEmpty && original.count == replacement.count)
        var bytes = try Data(contentsOf: fixture("GeoIP2-City-Test.mmdb"))
        var cursor = bytes.startIndex
        var replacements = 0
        while let range = bytes.range(of: original, in: cursor..<bytes.endIndex) {
            bytes.replaceSubrange(range, with: replacement)
            cursor = range.upperBound
            replacements += 1
        }
        try #require(replacements > 0)
        let target = folder.appendingPathComponent("city-variant-" + UUID().uuidString + ".mmdb")
        try bytes.write(to: target, options: .withoutOverwriting)
        return target
    }

    private func mmdbDouble(_ value: Double) -> Data {
        var bits = value.bitPattern.bigEndian
        // MMDB double: type 3, exactly eight payload bytes.
        return Data([0x68]) + withUnsafeBytes(of: &bits) { Data($0) }
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
        #expect(v4.latitude == 32.7405 && v4.longitude == -117.0935 && v4.accuracyRadiusKilometers == 100)
        #expect(v6.latitude == 35.68536 && v6.longitude == 139.75309 && v6.accuracyRadiusKilometers == 100)
        #expect(asn.autonomousSystemNumber == 15169 && absent.organization == nil)
        #expect(asn.latitude == nil && asn.longitude == nil && asn.accuracyRadiusKilometers == nil)
        #expect(absent.latitude == nil && absent.longitude == nil && absent.accuracyRadiusKilometers == nil)
        #expect(v4.datasetVersion == metadata.datasetVersion)
        let reopened = try IPInformationService(storageRoot: folder)
        #expect(await reopened.currentVersion() == metadata.datasetVersion)
        #expect(try await reopened.lookup("1.0.0.1")?.autonomousSystemNumber == 15169)
        #expect(try await reopened.lookup("214.78.120.1")?.longitude == -117.0935)
        #expect(try await service.lookup("192.168.1.1") == nil)
        #expect(try await service.lookup("1.0.0.1", expectedVersion: "stale") == nil)
        let provider = service.tracerouteProvider()
        #expect(try await provider.information(for: "1.0.0.1")?.autonomousSystemNumber == 15169)
    }

    @Test func realCityCoordinatesSurviveCanonicalCacheAndProviderMapping() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder)
        let metadata = try await install(service)
        let original = try await service.lookup("214.78.120.1")
        let mapped = try await service.lookup("::ffff:214.78.120.1")
        #expect(original?.latitude == 32.7405 && original?.longitude == -117.0935)
        #expect(mapped?.address == "::ffff:214.78.120.1")
        #expect(mapped?.latitude == original?.latitude && mapped?.longitude == original?.longitude)
        #expect(mapped?.accuracyRadiusKilometers == 100)
        #expect(mapped?.source == metadata.source && mapped?.datasetVersion == metadata.datasetVersion)
        #expect(await service.readerLookups == 1)
        let information = try await service.tracerouteProvider().information(for: "::ffff:214.78.120.1")
        #expect(information?.latitude == 32.7405 && information?.longitude == -117.0935)
        #expect(information?.accuracyRadiusKilometers == 100)
        #expect(information?.source == metadata.source && information?.datasetVersion == metadata.datasetVersion)
        #expect(await service.readerLookups == 1)
    }

    @Test func incompleteCityCoordinatesAndMissingAccuracyNeverGainDefaults() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder)
        for field in ["latitude", "longitude", "accuracy_radius"] {
            let key = Data(field.utf8)
            let city = try changedCity(in: folder, replacing: key, with: Data(repeating: 0x78, count: key.count))
            let id = try await service.startImport(city: city, asn: fixture("GeoLite2-ASN-Test.mmdb"),
                versionLabel: "missing-" + field)
            _ = try await service.waitForUpdate(id)
            let record = try #require(try await service.lookup("214.78.120.1"))
            #expect(record.countryCode == "US")
            if field == "accuracy_radius" {
                #expect(record.latitude == 32.7405 && record.longitude == -117.0935)
            } else {
                #expect(record.latitude == nil && record.longitude == nil)
            }
            #expect(record.accuracyRadiusKilometers == nil)
        }
    }

    @Test func nonfiniteOutOfRangeAndWrongTypeCityCoordinatesAreNotPublished() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let service = try IPInformationService(storageRoot: folder)
        let changes: [(Double, Double)] = [
            (32.7405, .nan), (32.7405, .infinity), (32.7405, 91), (32.7405, -91),
            (-117.0935, 181), (-117.0935, -181)
        ]
        for (index, pair) in changes.enumerated() {
            let city = try changedCity(in: folder, replacing: mmdbDouble(pair.0), with: mmdbDouble(pair.1))
            let id = try await service.startImport(city: city, asn: fixture("GeoLite2-ASN-Test.mmdb"),
                versionLabel: "invalid-coordinate-\(index)")
            _ = try await service.waitForUpdate(id)
            let record = try #require(try await service.lookup("214.78.120.1"))
            #expect(record.countryCode == "US")
            #expect(record.latitude == nil && record.longitude == nil && record.accuracyRadiusKilometers == nil)
        }
        var wrongType = mmdbDouble(32.7405)
        wrongType[wrongType.startIndex] = 0x88 // valid MMDB bytes value, invalid coordinate type
        let city = try changedCity(in: folder, replacing: mmdbDouble(32.7405), with: wrongType)
        let id = try await service.startImport(city: city, asn: fixture("GeoLite2-ASN-Test.mmdb"),
            versionLabel: "wrong-coordinate-type")
        _ = try await service.waitForUpdate(id)
        await #expect(throws: IPInformationError.invalidDatabase) { _ = try await service.lookup("214.78.120.1") }
    }

    @Test func recordCoordinateValidationRequiresAPairAndRetainsOnlyRealOptionalAccuracy() {
        func record(_ latitude: Double?, _ longitude: Double?, _ radius: Double? = nil) -> IPInformationRecord {
            IPInformationRecord(address: "214.78.120.1", countryCode: "US", country: "United States",
                region: nil, city: nil, autonomousSystemNumber: nil, organization: nil, networkPrefixLength: nil,
                source: "validation fixture", datasetVersion: "fixture",
                latitude: latitude, longitude: longitude, accuracyRadiusKilometers: radius)
        }
        let invalidPairs: [(Double?, Double?)] = [(nil, 1), (1, nil), (.nan, 1), (1, .infinity),
                                                (-90.01, 1), (90.01, 1), (1, -180.01), (1, 180.01)]
        for pair in invalidPairs {
            let value = record(pair.0, pair.1, 100)
            #expect(value.latitude == nil && value.longitude == nil && value.accuracyRadiusKilometers == nil)
            #expect(value.countryCode == "US")
        }
        for pair in [(-90.0, -180.0), (90, 180), (0, 0)] {
            let value = record(pair.0, pair.1)
            #expect(value.latitude == pair.0 && value.longitude == pair.1)
            #expect(value.accuracyRadiusKilometers == nil)
        }
        for invalidRadius in [-1.0, .nan, .infinity] {
            let value = record(32.7405, -117.0935, invalidRadius)
            #expect(value.latitude == 32.7405 && value.longitude == -117.0935)
            #expect(value.accuracyRadiusKilometers == nil)
        }
        #expect(record(0, 0, 0).accuracyRadiusKilometers == 0)
        let absent = record(nil, nil)
        #expect(absent.latitude == nil && absent.longitude == nil && absent.accuracyRadiusKilometers == nil)
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

// SPDX-License-Identifier: MPL-2.0
//
// Authored-only regressions for the G07.1 network diagnostics module.
// NOT executed by this lane (Main runs the combined batch). No sockets, no
// Android runtime, no device and no credentials: every fixture is synthetic
// JSON shaped exactly like the frozen `NetworkObservationV1` envelope.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidNetwork

final class NetworkToolTests: XCTestCase {

    private let operationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    // MARK: - Request v1

    func testStatusRequestIsCanonicalVersion1Object() throws {
        let request = try NetworkToolRequest.status(operationID: operationID)
        XCTAssertEqual(request.method, .status)
        XCTAssertLessThanOrEqual(request.requestJSON.count, NetworkToolLimits.maximumRequestBytes)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.requestJSON) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(object["method"] as? String, "network.status")
        let arguments = try XCTUnwrap(object["arguments"] as? [String: Any])
        XCTAssertTrue(arguments.isEmpty)
    }

    func testPingClampsCountAndTimeout() throws {
        let request = try NetworkToolRequest.ping(
            host: "example.com", count: 99, timeoutMs: 999_999, operationID: operationID)
        let arguments = try argumentsObject(request)
        XCTAssertEqual(arguments["count"] as? Int, 10)
        XCTAssertEqual(arguments["timeoutMs"] as? Int, 30_000)
        XCTAssertEqual(arguments["host"] as? String, "example.com")
    }

    func testDNSDefaultsAndRecordType() throws {
        let request = try NetworkToolRequest.dnsLookup(
            host: "example.com", recordType: "aaaa", timeoutMs: nil, operationID: operationID)
        let arguments = try argumentsObject(request)
        XCTAssertEqual(arguments["recordType"] as? String, "AAAA")
        XCTAssertEqual(arguments["timeoutMs"] as? Int, 5_000)
    }

    func testHTTPKeepsCleartextForTypedUnsupportedAndBoundsRedirects() throws {
        let request = try NetworkToolRequest.http(
            url: "http://example.com/path", timeoutMs: nil, maxRedirects: 99,
            operationID: operationID)
        let arguments = try argumentsObject(request)
        XCTAssertEqual(arguments["url"] as? String, "http://example.com/path")
        XCTAssertEqual(arguments["maxRedirects"] as? Int, 10)
        XCTAssertEqual(arguments["timeoutMs"] as? Int, 10_000)
    }

    func testRejectsStructuralBadArguments() {
        XCTAssertThrowsError(try NetworkToolRequest.tcpProbe(
            host: "example.com", port: 0, timeoutMs: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("port"))
        }
        XCTAssertThrowsError(try NetworkToolRequest.ping(
            host: "https://example.com", count: 4, timeoutMs: nil))
        XCTAssertThrowsError(try NetworkToolRequest.ping(
            host: "user@example.com", count: 4, timeoutMs: nil))
        XCTAssertThrowsError(try NetworkToolRequest.http(
            url: "https://user:secret@example.com/", timeoutMs: nil, maxRedirects: nil))
        XCTAssertThrowsError(try NetworkToolRequest.http(
            url: "file:///etc/passwd", timeoutMs: nil, maxRedirects: nil))
        XCTAssertThrowsError(try NetworkToolRequest.dnsLookup(
            host: "example.com", recordType: "MX", timeoutMs: nil))
    }

    func testDeniesMetadataUnspecifiedAndMulticast() {
        XCTAssertThrowsError(try NetworkToolRequest.dnsLookup(
            host: "169.254.169.254", recordType: nil, timeoutMs: nil))
        XCTAssertThrowsError(try NetworkToolRequest.tcpProbe(
            host: "metadata.google.internal", port: 80, timeoutMs: nil))
        XCTAssertThrowsError(try NetworkToolRequest.ping(
            host: "0.0.0.0", count: 1, timeoutMs: nil))
        XCTAssertThrowsError(try NetworkToolRequest.ping(
            host: "224.0.0.1", count: 1, timeoutMs: nil))
        XCTAssertThrowsError(try NetworkToolRequest.ping(
            host: "ff02::1", count: 1, timeoutMs: nil))
        // Deliberate private diagnostics remain permitted; the service
        // re-resolves and re-checks the real route.
        XCTAssertNoThrow(try NetworkToolRequest.tcpProbe(
            host: "192.168.1.10", port: 8_080, timeoutMs: nil))
        XCTAssertNoThrow(try NetworkToolRequest.tcpProbe(
            host: "fe80::1", port: 443, timeoutMs: nil))
    }

    func testRequestBytesAreBounded() {
        let huge = String(repeating: "a", count: 20_000)
        XCTAssertThrowsError(try NetworkToolRequest.make(
            method: .dnsLookup, operationID: operationID,
            arguments: ["host": .string(huge)]))
    }

    func testStatusArgumentsRejectUnknownFields() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            NetworkStatusTool.Arguments.self,
            from: Data(#"{"extra":1}"#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(
            NetworkStatusTool.Arguments.self, from: Data("{}".utf8)))
    }

    // MARK: - Observation decode / validation

    func testDecodesTypedWifiScanObservation() throws {
        let request = try NetworkToolRequest.wifiScan(
            refresh: true, operationID: operationID)
        let observation = try NetworkObservationV1.decode(
            wifiFixture(), expecting: request)
        XCTAssertEqual(observation.version, 1)
        XCTAssertEqual(observation.status, .ok)
        XCTAssertEqual(observation.source, "phone")
        XCTAssertEqual(observation.method, .wifiScan)
        XCTAssertEqual(observation.cacheAgeMs, 1_200)
        XCTAssertEqual(observation.network.typeName, "WIFI")
        XCTAssertEqual(observation.network.transports, ["WIFI"])
        XCTAssertEqual(observation.network.interfaceName, "wlan0")
        XCTAssertEqual(observation.network.linkAddresses, ["192.168.1.10/24"])
        let scan = try XCTUnwrap(observation.observations.wifiScan)
        XCTAssertEqual(scan.accessPoints.count, 1)
        XCTAssertEqual(scan.accessPoints[0].ssid, "HomeNet")
        XCTAssertEqual(scan.accessPoints[0].resolvedChannel, 6)
        XCTAssertEqual(scan.accessPoints[0].resolvedBand, "2.4GHz")
        XCTAssertEqual(scan.accessPoints[0].rssiDbm, -47)
    }

    func testRejectsCrossWiredObservationIdentity() throws {
        let request = try NetworkToolRequest.wifiScan(refresh: false, operationID: operationID)
        let wrongOperation = try observationFixture(operationID: UUID(), method: "network.wifiScan")
        XCTAssertThrowsError(try NetworkObservationV1.decode(
            wrongOperation, expecting: request)) { error in
            XCTAssertEqual(error as? NetworkObservationError, .operationMismatch)
        }
        let wrongMethod = try observationFixture(operationID: operationID, method: "network.ping")
        XCTAssertThrowsError(try NetworkObservationV1.decode(
            wrongMethod, expecting: request)) { error in
            XCTAssertEqual(error as? NetworkObservationError, .wrongMethod("network.ping"))
        }
        let wrongVersion = try observationFixture(
            operationID: operationID, method: "network.wifiScan", version: 2)
        XCTAssertThrowsError(try NetworkObservationV1.decode(
            wrongVersion, expecting: request)) { error in
            XCTAssertEqual(error as? NetworkObservationError, .unsupportedVersion(2))
        }
        let wrongSource = try observationFixture(
            operationID: operationID, method: "network.wifiScan", source: "server")
        XCTAssertThrowsError(try NetworkObservationV1.decode(
            wrongSource, expecting: request)) { error in
            XCTAssertEqual(error as? NetworkObservationError, .wrongSource("server"))
        }
        let badTimestamp = try observationFixture(
            operationID: operationID, method: "network.wifiScan",
            measuredAt: "yesterday")
        XCTAssertThrowsError(try NetworkObservationV1.decode(
            badTimestamp, expecting: request)) { error in
            XCTAssertEqual(error as? NetworkObservationError,
                           .invalidTimestamp("yesterday"))
        }
    }

    func testPermissionRequiredAcceptsOptionalPermissionNames() throws {
        let request = try NetworkToolRequest.wifiScan(refresh: false, operationID: operationID)
        let withoutPermissions = try observationFixture(
            operationID: operationID, method: "network.wifiScan",
            status: "permissionRequired")
        let empty = try NetworkObservationV1.decode(
            withoutPermissions, expecting: request)
        XCTAssertEqual(empty.status, .permissionRequired)
        XCTAssertNil(empty.missingPermissions)
        let withPermissions = try observationFixture(
            operationID: operationID, method: "network.wifiScan",
            status: "permissionRequired",
            missingPermissions: #"["android.permission.ACCESS_FINE_LOCATION"]"#)
        let observation = try NetworkObservationV1.decode(
            withPermissions, expecting: request)
        XCTAssertEqual(observation.status, .permissionRequired)
        XCTAssertEqual(observation.missingPermissions,
                       ["android.permission.ACCESS_FINE_LOCATION"])
    }

    // MARK: - Export / summary

    func testExportRedactsAccessPointIdentifiersByDefault() throws {
        let request = try NetworkToolRequest.wifiScan(refresh: false, operationID: operationID)
        let observation = try NetworkObservationV1.decode(
            wifiFixture(), expecting: request)
        let exported = try XCTUnwrap(
            String(data: observation.exportJSON(), encoding: .utf8))
        XCTAssertTrue(exported.contains("<redacted>"), exported)
        XCTAssertFalse(exported.contains("aa:bb:cc:dd:ee:ff"), exported)
        XCTAssertFalse(exported.contains("HomeNet"), exported)
        let inApp = try XCTUnwrap(
            String(data: observation.inAppJSON(), encoding: .utf8))
        XCTAssertTrue(inApp.contains("aa:bb:cc:dd:ee:ff"), inApp)
    }

    func testSummaryIsBoundedValidJSONAndOmitsBSSIDAndCookies() throws {
        let request = try NetworkToolRequest.wifiScan(refresh: false, operationID: operationID)
        let observation = try NetworkObservationV1.decode(
            wifiFixture(), expecting: request)
        let summary = NetworkObservationSummary.render(observation)
        XCTAssertLessThanOrEqual(summary.count, NetworkObservationSummary.maximumCharacters)
        let object = try jsonObject(summary)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(object["method"] as? String, "network.wifiScan")
        XCTAssertEqual(object["source"] as? String, "phone")
        XCTAssertEqual(object["status"] as? String, "ok")
        let observations = try XCTUnwrap(object["observations"] as? [String: Any])
        let rows = try XCTUnwrap(observations["accessPoints"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["ssid"] as? String, "HomeNet")
        XCTAssertNil(rows[0]["bssid"])
        XCTAssertEqual(rows[0]["rssiDbm"] as? Int, -47)
        XCTAssertFalse(summary.contains("aa:bb:cc:dd:ee:ff"), summary)

        let httpRequest = try NetworkToolRequest.http(
            url: "https://example.com/", timeoutMs: nil, maxRedirects: nil,
            operationID: operationID)
        let httpObservation = try NetworkObservationV1.decode(
            httpFixture(), expecting: httpRequest)
        let httpSummary = NetworkObservationSummary.render(httpObservation)
        XCTAssertLessThanOrEqual(httpSummary.count, NetworkObservationSummary.maximumCharacters)
        let httpObject = try jsonObject(httpSummary)
        let httpObservations = try XCTUnwrap(httpObject["observations"] as? [String: Any])
        XCTAssertEqual(httpObservations["statusCode"] as? Int, 200)
        XCTAssertEqual(httpObservations["redirectCount"] as? Int, 1)
        XCTAssertEqual(httpObservations["contentLength"] as? Int, 1256)
        let tls = try XCTUnwrap(httpObservations["tls"] as? [String: Any])
        XCTAssertEqual(tls["cipherSuite"] as? String, "TLS_AES_128_GCM_SHA256")
        XCTAssertFalse(httpSummary.lowercased().contains("set-cookie"), httpSummary)
        XCTAssertFalse(httpSummary.contains("secret=1"), httpSummary)
    }

    func testPermissionSummaryRetainsIdentityStatusAndPermissionsAsJSON() throws {
        let request = try NetworkToolRequest.wifiScan(refresh: false, operationID: operationID)
        let data = try observationFixture(
            operationID: operationID, method: "network.wifiScan",
            status: "permissionRequired",
            missingPermissions: #"["android.permission.ACCESS_FINE_LOCATION"]"#,
            observations: #"{"requiredFor":"network.wifiScan"}"#)
        let observation = try NetworkObservationV1.decode(data, expecting: request)
        let summary = NetworkObservationSummary.render(observation)
        let object = try jsonObject(summary)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(object["method"] as? String, "network.wifiScan")
        XCTAssertEqual(object["source"] as? String, "phone")
        XCTAssertEqual(object["status"] as? String, "permissionRequired")
        XCTAssertEqual(object["missingPermissions"] as? [String],
                       ["android.permission.ACCESS_FINE_LOCATION"])
        let observations = try XCTUnwrap(object["observations"] as? [String: Any])
        XCTAssertEqual(observations["requiredFor"] as? String, "network.wifiScan")
    }

    func testLargeWifiScanSummaryIsBoundedJSONWithExplicitTruncation() throws {
        let request = try NetworkToolRequest.wifiScan(refresh: false, operationID: operationID)
        var rows: [String] = []
        for index in 0..<300 {
            rows.append("""
            {"ssid":"Net\(index)","bssid":"aa:bb:cc:dd:ee:\(String(format: "%02x", index % 256))",
            "frequencyMhz":2437,"rssiDbm":-\(40 + index % 50),"band":"2.4GHz",
            "capabilities":"[WPA2-PSK-CCMP]","ageMs":1000}
            """)
        }
        let scan = """
        {"cacheAgeMs":1000,"totalAccessPoints":300,"locationServicesEnabled":true,
        "wifiEnabled":true,"accessPoints":[\(rows.joined(separator: ","))]}
        """
        let data = try observationFixture(
            operationID: operationID, method: "network.wifiScan",
            status: "permissionRequired",
            missingPermissions: #"["android.permission.ACCESS_FINE_LOCATION"]"#,
            observations: scan)
        let observation = try NetworkObservationV1.decode(data, expecting: request)
        let summary = NetworkObservationSummary.render(observation)
        XCTAssertLessThanOrEqual(summary.count, NetworkObservationSummary.maximumCharacters)
        let object = try jsonObject(summary)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(object["method"] as? String, "network.wifiScan")
        XCTAssertEqual(object["source"] as? String, "phone")
        XCTAssertEqual(object["status"] as? String, "permissionRequired")
        XCTAssertEqual(object["missingPermissions"] as? [String],
                       ["android.permission.ACCESS_FINE_LOCATION"])
        XCTAssertEqual(object["summaryTruncated"] as? Bool, true)
        let observations = try XCTUnwrap(object["observations"] as? [String: Any])
        XCTAssertEqual(observations["totalAccessPoints"] as? Int, 300)
        XCTAssertEqual(observations["accessPointsTruncated"] as? Bool, true)
        let omitted = try XCTUnwrap(observations["accessPointsOmitted"] as? Int)
        XCTAssertGreaterThan(omitted, 0)
        let retained = try XCTUnwrap(observations["accessPoints"] as? [[String: Any]])
        XCTAssertLessThan(retained.count, 300)
        XCTAssertGreaterThan(retained.count, 0)
        let limitations = try XCTUnwrap(object["limitations"] as? [String])
        XCTAssertTrue(limitations.contains { $0.contains("access points") }, summary)
        XCTAssertFalse(summary.contains("aa:bb:cc:dd:ee:00"), summary)
    }

    // MARK: - Fixtures

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any])
    }

    private func argumentsObject(_ request: NetworkToolRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: request.argumentsJSON) as? [String: Any])
    }

    private func wifiFixture() throws -> Data {
        try observationFixture(operationID: operationID, method: "network.wifiScan")
    }

    private func httpFixture() throws -> Data {
        try observationFixture(operationID: operationID, method: "network.http",
                               observations: #"""
        {"requestedUrl":"https://example.com/","finalUrl":"https://example.com/",
        "statusCode":200,"redirectCount":1,
        "tls":{"cipherSuite":"TLS_AES_128_GCM_SHA256","certificateChainAnalyzed":false},
        "contentType":"text/html","contentLength":1256,
        "responseHeaders":{"Set-Cookie":"secret=1","Content-Type":"text/html"}}
        """#)
    }

    private func observationFixture(
        operationID: UUID,
        method: String,
        version: Int = 1,
        source: String = "phone",
        status: String = "ok",
        measuredAt: String = "2026-10-30T02:00:00Z",
        missingPermissions: String? = nil,
        observations: String? = nil
    ) throws -> Data {
        let observationsObject = observations ?? #"""
        {"cacheAgeMs":1200,"locationServicesEnabled":true,
        "totalAccessPoints":1,"wifiEnabled":true,
        "accessPoints":[{"ssid":"HomeNet","bssid":"aa:bb:cc:dd:ee:ff",
        "frequencyMhz":2437,"rssiDbm":-47,"band":"2.4GHz",
        "capabilities":"[WPA2-PSK-CCMP]"}]}
        """#
        let missing = missingPermissions.map { #","missingPermissions":\#($0)"# } ?? ""
        let json = """
        {"version":\(version),"operationID":"\(operationID.uuidString)",
        "method":"\(method)","source":"\(source)","status":"\(status)",
        "measuredAt":"\(measuredAt)","cacheAgeMs":1200,
        "network":{"available":true,"transports":["WIFI"],"typeName":"WIFI",
        "interfaceName":"wlan0","vpn":false,"validated":true,
        "captivePortal":false,"metered":false,
        "linkAddresses":["192.168.1.10/24"],"dnsServers":["192.168.1.1"],"mtu":1500},
        "target":"example.com","observations":\(observationsObject),
        "limitations":["Fresh Wi-Fi scans are throttled by Android."]\(missing)}
        """
        return Data(json.utf8)
    }
}

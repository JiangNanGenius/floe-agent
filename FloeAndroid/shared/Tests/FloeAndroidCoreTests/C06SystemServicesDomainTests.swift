// SPDX-License-Identifier: MPL-2.0
//
// C06 system-services domain tests. Authored source; NOT RUN by this lane.
// Every test injects a fake platform port: no real permission prompt, radio,
// contact provider, NFC tag or Health Connect record participates.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeAndroidCore

private final class FakeSystemPort: C06SystemPlatformPort, @unchecked Sendable {
    var locationValue = C06LocationFix(
        latitude: -33.8688,
        longitude: 151.2093,
        accuracyMeters: 12.5,
        timestamp: Date(timeIntervalSince1970: 1_730_000_000),
        precise: true,
        provider: "gps"
    )
    var contacts: [C06ContactRecord] = []
    var contactCalls = 0
    var nfcValue = C06NFCReadResult(
        records: [],
        rawBytes: 0,
        writable: false,
        techList: ["Ndef"],
        truncated: false,
        elapsedMilliseconds: 3
    )
    var healthRows: [C06HealthSampleRow] = []
    var healthAggregateValue: C06HealthAggregateResult?
    var failure: C06SystemError?

    func locationFix(owner: C06SystemOwner, timeout: TimeInterval) async throws -> C06LocationFix {
        if let failure { throw failure }
        return locationValue
    }

    func contactsScan(
        owner: C06SystemOwner,
        query: String?,
        field: C06ContactField,
        scanToken: String?,
        offset: Int,
        limit: Int
    ) async throws -> C06ContactScanPage {
        contactCalls += 1
        if let failure { throw failure }
        let lower = min(max(0, offset), contacts.count)
        let upper = min(contacts.count, lower + max(1, limit))
        let page = Array(contacts[lower..<upper])
        let next = upper < contacts.count ? upper : nil
        return C06ContactScanPage(
            scanToken: "scan-token",
            rows: page,
            totalCount: contacts.count,
            truncated: false,
            nextOffset: next
        )
    }

    func nfcRead(owner: C06SystemOwner, timeout: TimeInterval) async throws -> C06NFCReadResult {
        if let failure { throw failure }
        return nfcValue
    }

    func healthSamples(
        owner: C06SystemOwner,
        metric: C06HealthMetric,
        start: Date,
        end: Date,
        limit: Int,
        pageToken: String?
    ) async throws -> C06HealthPage {
        if let failure { throw failure }
        return C06HealthPage(
            rows: healthRows,
            nextPageToken: nil,
            totalScanned: healthRows.count,
            truncated: false
        )
    }

    func healthAggregate(
        owner: C06SystemOwner,
        metric: C06HealthMetric,
        aggregation: C06HealthAggregation,
        start: Date,
        end: Date
    ) async throws -> C06HealthAggregateResult {
        if let failure { throw failure }
        return healthAggregateValue ?? C06HealthAggregateResult(
            metric: metric.rawValue,
            aggregation: aggregation.rawValue,
            value: 1_234,
            unit: metric.unit,
            recordCount: 7,
            start: start,
            end: end,
            detail: "records=7"
        )
    }
}

final class C06SystemServicesDomainTests: XCTestCase {
    private var port: FakeSystemPort!
    private var domain: C06SystemServicesDomain!

    override func setUp() {
        super.setUp()
        C06SystemServicesDomain.availability.reset()
        port = FakeSystemPort()
        let fake = port!
        domain = C06SystemServicesDomain(portProvider: { _ in fake })
    }

    override func tearDown() {
        C06SystemServicesDomain.availability.reset()
        super.tearDown()
    }

    private func owner() throws -> C06SystemOwner {
        try C06SystemOwner(
            token: "test.owner.token",
            nativeEpoch: 1,
            taskID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        )
    }

    private func availability(
        foreground: Bool = true,
        locationPermission: C06SystemPermission = .granted,
        services: Bool = true,
        precise: Bool = true,
        contactsPermission: C06SystemPermission = .granted,
        nfcHardware: Bool = true,
        nfcEnabled: Bool = true,
        health: C06HealthProviderStatus = .available,
        metrics: Set<String> = ["steps", "heartRate"]
    ) -> C06SystemAvailabilitySnapshot {
        C06SystemAvailabilitySnapshot(
            coreReady: true,
            foreground: foreground,
            revision: 1,
            epoch: 1,
            location: C06LocationAvailability(
                hardwareAvailable: true,
                servicesEnabled: services,
                permission: locationPermission,
                precise: precise
            ),
            contacts: C06ContactsAvailability(
                providerAvailable: true,
                permission: contactsPermission
            ),
            nfc: C06NFCAvailability(
                hardwareAvailable: nfcHardware,
                enabled: nfcEnabled
            ),
            health: C06HealthAvailability(
                providerStatus: health,
                grantedMetrics: metrics
            )
        )
    }

    private func apply(_ snapshot: C06SystemAvailabilitySnapshot) async {
        await domain.applyHostAvailability(snapshot, epoch: 1)
    }

    private func context(temporary: Bool = false) -> ToolContext {
        ToolContext(
            runID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
            cancellation: CancellationToken(),
            conversationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555"),
            temporaryReadOnly: temporary
        )
    }

    // MARK: Owner and availability

    func testOwnerRejectsTemporaryZeroEpochAndBadToken() throws {
        XCTAssertThrowsError(try C06SystemOwner(token: "short", nativeEpoch: 1))
        XCTAssertThrowsError(try C06SystemOwner(token: "test.owner.token", nativeEpoch: 0))
        XCTAssertThrowsError(try C06SystemOwner(token: "test.owner.token", nativeEpoch: 1, temporary: true))
        let parsed = try C06SystemOwner.parse([
            "token": "test.owner.token",
            "nativeEpoch": 9,
            "temporary": false,
        ])
        XCTAssertFalse(parsed.temporary)
        XCTAssertThrowsError(try C06SystemOwner.parse([
            "token": "test.owner.token", "nativeEpoch": 9, "temporary": true,
        ]))
        XCTAssertThrowsError(try C06SystemOwner.parse(["token": "test.owner.token", "nativeEpoch": 0]))
    }

    func testAvailabilityRequiresForegroundAndPermission() async throws {
        await apply(availability(foreground: false))
        _ = try owner()
        do {
            _ = try await domain.contactsList(owner: owner(), query: nil, field: nil, limit: 50, cursor: nil)
            XCTFail("background contacts must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .foregroundRequired)
        }
        await apply(availability(contactsPermission: .notDetermined))
        do {
            _ = try await domain.contactsList(owner: owner(), query: nil, field: nil, limit: 50, cursor: nil)
            XCTFail("unanswered contacts permission must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .permissionNotDetermined)
        }
        await apply(availability(contactsPermission: .denied))
        do {
            _ = try await domain.contactsList(owner: owner(), query: nil, field: nil, limit: 50, cursor: nil)
            XCTFail("denied contacts permission must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .permissionDenied)
        }
        XCTAssertEqual(port.contactCalls, 0)
    }

    func testAvailabilityRevisionNeverRegresses() async {
        await apply(availability())
        var newer = availability()
        newer.revision = 7
        newer.foreground = false
        await domain.applyHostAvailability(newer, epoch: 1)
        XCTAssertFalse(C06SystemServicesDomain.availability.snapshot.foreground)
        var older = availability()
        older.revision = 6
        older.foreground = true
        await domain.applyHostAvailability(older, epoch: 1)
        XCTAssertFalse(C06SystemServicesDomain.availability.snapshot.foreground)
    }

    func testStaleOwnerEpochIsRefused() async throws {
        await apply(availability())
        let stale = try C06SystemOwner(token: "test.owner.token", nativeEpoch: 2)
        do {
            _ = try await domain.locate(owner: stale)
            XCTFail("stale epoch must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .staleEpoch)
        }
    }

    // MARK: Location

    func testLocationSuccessCarriesPrecisionAndNoBackgroundTracking() async throws {
        await apply(availability(precise: false))
        let fix = try await domain.locate(owner: owner())
        XCTAssertEqual(fix.provider, "gps")
        XCTAssertFalse(fix.precise)
        let output = try await C06LocationCurrentTool(domain: domain)
            .execute(C06LocationCurrentTool.Arguments(), context: context())
        XCTAssertTrue(output.summary.contains("status=ok capability=location"))
        XCTAssertTrue(output.summary.contains("precision=approximate"))
        XCTAssertTrue(output.summary.contains("backgroundTracking=false"))
        XCTAssertTrue(output.summary.contains("latitude=-33.869"))
    }

    func testLocationDistinguishesServicesPermissionAndInvalidFix() async throws {
        await apply(availability(services: false))
        do {
            _ = try await domain.locate(owner: owner())
            XCTFail("disabled services must be distinct")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .locationServicesDisabled)
        }
        await apply(availability(locationPermission: .notDetermined))
        do {
            _ = try await domain.locate(owner: owner())
            XCTFail("unanswered permission must be distinct")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .permissionNotDetermined)
        }
        await apply(availability())
        port.locationValue = C06LocationFix(
            latitude: 0,
            longitude: 0,
            accuracyMeters: -1,
            timestamp: Date(),
            precise: true,
            provider: "gps"
        )
        do {
            _ = try await domain.locate(owner: owner())
            XCTFail("negative accuracy is not a fix")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .locationUnavailable)
        }
    }

    // MARK: Contacts

    func testContactsPageIsStableAndCursorCannotCarryQuery() async throws {
        await apply(availability())
        port.contacts = (0..<120).map { index in
            C06ContactRecord(
                id: String(format: "%04d", index),
                displayName: "Contact \(String(format: "%03d", 119 - index))",
                organization: index % 2 == 0 ? "Floe" : "",
                phones: ["+61 2 5555 \(index)"],
                emails: ["person\(index)@example.com"]
            )
        }
        let first = try await domain.contactsList(
            owner: owner(), query: nil, field: nil, limit: 50, cursor: nil
        )
        XCTAssertEqual(first.returnedCount, 50)
        XCTAssertEqual(first.totalCount, 120)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.scanned, 120)
        XCTAssertEqual(first.scanTruncated, false)
        XCTAssertNotNil(first.nextCursor)
        XCTAssertTrue(first.lines.first?.contains("name=\"Contact 000\"") == true)

        let second = try await domain.contactsList(
            owner: owner(), query: nil, field: nil, limit: 50, cursor: first.nextCursor
        )
        XCTAssertEqual(second.returnedCount, 50)
        XCTAssertEqual(second.pageCount, 2)
        XCTAssertFalse(second.lines.contains(first.lines[0]))

        do {
            _ = try await domain.contactsList(
                owner: owner(), query: "Floe", field: "organization", limit: 50,
                cursor: first.nextCursor
            )
            XCTFail("cursor and query must not be combined")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidCursor)
        }
    }

    func testContactsScanIsCappedAtFiveHundred() async throws {
        await apply(availability())
        port.contacts = (0..<620).map { index in
            C06ContactRecord(
                id: String(format: "%04d", index),
                displayName: "Contact \(String(format: "%03d", index))",
                organization: "",
                phones: [],
                emails: []
            )
        }
        let page = try await domain.contactsList(
            owner: owner(), query: nil, field: nil, limit: 50, cursor: nil
        )
        XCTAssertEqual(page.scanned, 500)
        XCTAssertEqual(page.scanTruncated, true)
        XCTAssertEqual(page.totalCount, 620)
    }

    func testContactsEmptyAuthorizedResultIsNotError() async throws {
        await apply(availability())
        port.contacts = []
        let page = try await domain.contactsList(
            owner: owner(), query: nil, field: nil, limit: 50, cursor: nil
        )
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertEqual(page.returnedCount, 0)
        XCTAssertFalse(page.hasMore)
        let output = try await C06ContactsListTool(domain: domain)
            .execute(C06ContactsListTool.Arguments(), context: context())
        XCTAssertTrue(output.summary.contains("emptyResult=true"))
        XCTAssertTrue(output.summary.contains("authorization=granted"))
    }

    func testContactsQueryValidationIsLiteralAndBounded() async throws {
        await apply(availability())
        do {
            _ = try await domain.contactsList(
                owner: owner(), query: String(repeating: "a", count: 121),
                field: nil, limit: 50, cursor: nil
            )
            XCTFail("oversized query must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidQuery)
        }
        do {
            _ = try await domain.contactsList(
                owner: owner(), query: nil, field: "name", limit: 50, cursor: nil
            )
            XCTFail("field without query must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidField)
        }
        do {
            _ = try await domain.contactsList(
                owner: owner(), query: nil, field: nil, limit: 51, cursor: nil
            )
            XCTFail("limit above 50 must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidLimit)
        }
    }

    // MARK: NFC

    func testNFCReadBoundsAndDisabledState() async throws {
        await apply(availability())
        port.nfcValue = C06NFCReadResult(
            records: [
                C06NFCRecord(
                    index: 0,
                    tnf: 1,
                    typeText: "T",
                    identifier: "",
                    kind: "text",
                    value: "hello",
                    payloadBytes: 5,
                    payloadSHA256Prefix: "abc123",
                    truncated: false
                ),
            ],
            rawBytes: 32,
            writable: false,
            techList: ["Ndef"],
            truncated: false,
            elapsedMilliseconds: 4
        )
        let result = try await domain.readNFC(owner: owner(), timeoutSeconds: 20)
        XCTAssertEqual(result.records.count, 1)
        let output = try await C06NFCReadTool(domain: domain)
            .execute(C06NFCReadTool.Arguments(timeoutSeconds: 20), context: context())
        XCTAssertTrue(output.summary.contains("readOnly=true writeRequested=false"))
        XCTAssertTrue(output.summary.contains("kind=text"))

        do {
            _ = try await domain.readNFC(owner: owner(), timeoutSeconds: 3)
            XCTFail("short timeout must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidTimeout)
        }

        await apply(availability(nfcEnabled: false))
        do {
            _ = try await domain.readNFC(owner: owner(), timeoutSeconds: 20)
            XCTFail("disabled adapter must be distinct")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .nfcDisabled)
        }

        await apply(availability(nfcHardware: false))
        do {
            _ = try await domain.readNFC(owner: owner(), timeoutSeconds: 20)
            XCTFail("absent hardware must be distinct")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .nfcHardwareUnavailable)
        }
    }

    // MARK: Health

    private func healthDates() -> (String, String) {
        ("2026-01-01T00:00:00Z", "2026-01-08T00:00:00Z")
    }

    func testHealthSamplesArePagedAndMetricBound() async throws {
        await apply(availability(metrics: ["steps"]))
        port.healthRows = (0..<75).map { index in
            C06HealthSampleRow(
                metric: "steps",
                start: Date(timeIntervalSince1970: 1_767_225_600 + Double(index * 3_600)),
                end: Date(timeIntervalSince1970: 1_767_225_600 + Double(index * 3_600 + 3_000)),
                value: Double(index + 100),
                unit: "count",
                detail: nil
            )
        }
        let (start, end) = healthDates()
        let result = try await domain.healthRead(
            owner: owner(), metric: "steps", mode: "samples", aggregation: nil,
            start: start, end: end, limit: 50, cursor: nil
        )
        guard case .samples(let page) = result else {
            return XCTFail("expected samples")
        }
        XCTAssertEqual(page.returnedCount, 50)
        XCTAssertEqual(page.totalCount, 75)
        XCTAssertTrue(page.hasMore)
        let cursor = try XCTUnwrap(page.nextCursor)
        let next = try await domain.healthRead(
            owner: owner(), metric: "steps", mode: "samples", aggregation: nil,
            start: nil, end: nil, limit: 50, cursor: cursor
        )
        guard case .samples(let second) = next else {
            return XCTFail("expected samples")
        }
        XCTAssertEqual(second.returnedCount, 25)
        XCTAssertFalse(second.hasMore)

        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "heartRate", mode: "samples", aggregation: nil,
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("ungranted metric must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .healthPermissionDenied)
        }
    }

    func testHealthActivitySummaryAndAggregateRulesAreHonest() async throws {
        await apply(availability(metrics: ["activitySummary", "steps", "sleep", "heartRate"]))
        let (start, end) = healthDates()
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "activitySummary", mode: "samples", aggregation: nil,
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("activitySummary has no Android equivalent")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .healthUnsupportedMetric)
        }
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "sleep", mode: "aggregate", aggregation: "average",
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("sleep is sample-only")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .unsupportedOperation)
        }
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "heartRate", mode: "aggregate", aggregation: "sum",
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("sum is limited to steps and active energy")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidAggregation)
        }
        let aggregate = try await domain.healthRead(
            owner: owner(), metric: "steps", mode: "aggregate", aggregation: "sum",
            start: start, end: end, limit: 50, cursor: nil
        )
        guard case .aggregate(let value) = aggregate else {
            return XCTFail("expected aggregate")
        }
        XCTAssertEqual(value.metric, "steps")
        XCTAssertEqual(value.aggregation, "sum")
    }

    func testHealthRangeProviderStateAndPermissionsAreDistinct() async throws {
        await apply(availability(health: .updateRequired))
        let (start, end) = healthDates()
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "steps", mode: "samples", aggregation: nil,
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("provider update must be distinct")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .healthProviderUpdateRequired)
        }
        await apply(availability(health: .unavailable))
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "steps", mode: "samples", aggregation: nil,
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("absent provider must be distinct")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .healthProviderAbsent)
        }
        await apply(availability())
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "steps", mode: "samples", aggregation: nil,
                start: "2026-01-01T00:00:00Z", end: "2027-06-01T00:00:00Z",
                limit: 50, cursor: nil
            )
            XCTFail("range above 366 days must be refused")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidRange)
        }
        do {
            _ = try await domain.healthRead(
                owner: owner(), metric: "steps", mode: "aggregate", aggregation: nil,
                start: start, end: end, limit: 50, cursor: nil
            )
            XCTFail("aggregate requires an aggregation")
        } catch let error as C06SystemError {
            XCTAssertEqual(error.code, .invalidAggregation)
        }
    }

    // MARK: Tools and bridge

    func testTemporaryChatCannotUseSystemServices() async throws {
        await apply(availability())
        let output = try await C06ContactsListTool(domain: domain)
            .execute(C06ContactsListTool.Arguments(), context: context(temporary: true))
        XCTAssertTrue(output.summary.contains("temporaryOwnerCannotUseSystemServices"))
    }

    func testBridgeAvailabilityPushUpdatesStatus() throws {
        C06SystemServicesDomain.availability.reset()
        let request: [String: Any] = [
            "version": 15,
            "operation": "c06.system.availability",
            "requestID": "test-request",
            "owner": ["token": "bridge.host.token", "nativeEpoch": 4, "temporary": false],
            "revision": 3,
            "foreground": true,
            "location": [
                "hardwareAvailable": true,
                "servicesEnabled": true,
                "permission": "granted",
                "precise": true,
            ],
            "contacts": ["providerAvailable": true, "permission": "granted"],
            "nfc": ["hardwareAvailable": true, "enabled": true],
            "health": [
                "providerStatus": "available",
                "grantedMetrics": ["steps", "sleep"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let reply = C06SystemBridge.handle(requestData: data, fallbackRequestID: nil)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["locationAvailable"] as? Bool, true)
        XCTAssertEqual(reply["contactsAvailable"] as? Bool, true)
        XCTAssertEqual(reply["nfcAvailable"] as? Bool, true)
        XCTAssertEqual(reply["healthAvailable"] as? Bool, true)
        let snapshot = C06SystemServicesDomain.availability.snapshot
        XCTAssertEqual(snapshot.epoch, 4)
        XCTAssertEqual(snapshot.health.grantedMetrics, ["steps", "sleep"])
        XCTAssertEqual(snapshot.revision, 3)
    }

    func testBridgeRejectsMalformedAvailability() throws {
        C06SystemServicesDomain.availability.reset()
        let request: [String: Any] = [
            "version": 15,
            "operation": "c06.system.availability",
            "owner": ["token": "bridge.host.token", "nativeEpoch": 4],
            "revision": 3,
            "foreground": true,
            "location": ["permission": "bogus"],
            "contacts": ["permission": "granted"],
            "nfc": [:],
            "health": ["providerStatus": "available"],
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = C06SystemBridge.handle(requestData: data, fallbackRequestID: nil)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["code"] as? String, "invalidRequest")
    }

    func testMailboxBindsAndFencesGenerations() {
        let mailbox = C06SystemHostMailbox()
        XCTAssertEqual(mailbox.bind(epoch: 9), 0)
        XCTAssertEqual(mailbox.bind(epoch: 9), 0)
        XCTAssertEqual(mailbox.bind(epoch: 10), -2)
        XCTAssertEqual(mailbox.laneReady(epoch: 9), 0)
        XCTAssertEqual(mailbox.laneReady(epoch: 10), -2)
        XCTAssertEqual(mailbox.closeAll(timeoutMillis: 50), 0)
        XCTAssertEqual(mailbox.laneClosed(epoch: 9), 0)
    }
}

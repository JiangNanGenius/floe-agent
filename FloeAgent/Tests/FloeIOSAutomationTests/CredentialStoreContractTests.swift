import XCTest
@testable import FloeIOSAutomation

final class CredentialStoreContractTests: XCTestCase {
    func testRecordRoundTripAndRedaction() throws {
        let key = testKey(5)
        let record = try testRecord(key: key)
        let payload = try record.encodedSecretPayload()
        XCTAssertTrue(payload.count < 16_384)
        let decoded = try IOSBridgePairingRecord.decodeSecretPayload(payload)
        XCTAssertEqual(decoded.tokenID, record.tokenID)
        XCTAssertEqual(decoded.clientName, record.clientName)
        XCTAssertEqual(decoded.expiresAt, record.expiresAt)
        XCTAssertTrue(decoded.matchesKey(in: record))

        let keyHex = IOSBridgeEnvelope.hexLowercase(key)
        let keyBase64 = key.base64EncodedString()
        let description = String(describing: record)
        XCTAssertFalse(description.contains(keyHex))
        XCTAssertFalse(description.contains(keyBase64))
        XCTAssertTrue(description.contains("IOSBridgePairingRecord"))
        XCTAssertFalse(String(describing: record.summary).contains(keyHex))
    }

    func testRecordRejectsTokenMismatchAndTampering() throws {
        let key = testKey(6)
        XCTAssertThrowsError(
            try IOSBridgePairingRecord(
                tokenID: "00000000",
                clientName: "Floe",
                grantedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_702_592_000),
                protocolVersion: 1,
                keyMaterial: key
            )
        )
        let record = try testRecord(key: key)
        var payload = try record.encodedSecretPayload()
        payload[payload.count - 3] ^= 0x01
        XCTAssertThrowsError(try IOSBridgePairingRecord.decodeSecretPayload(payload))
        XCTAssertThrowsError(try IOSBridgePairingRecord.decodeSecretPayload(Data()))
    }

    func testHandleValidationAndSkillNamespace() throws {
        XCTAssertNotNil(IOSBridgePairingHandle(rawValue: "ios-bridge.local.v1"))
        XCTAssertNil(IOSBridgePairingHandle(rawValue: ""))
        XCTAssertNil(IOSBridgePairingHandle(rawValue: "has space"))
        XCTAssertNil(IOSBridgePairingHandle(rawValue: String(repeating: "a", count: 129)))
        let skill = try XCTUnwrap(IOSBridgePairingHandle.skillConnection(profileID: "publisher.skill_1"))
        XCTAssertEqual(skill.rawValue, "skill.ios-automation.publisher.skill_1")
        XCTAssertNil(IOSBridgePairingHandle.skillConnection(profileID: "bad profile"))
        XCTAssertNil(IOSBridgePairingHandle.skillConnection(profileID: "bad/profile"))
    }

    func testMemoryStoreLifecycleAndAtomicFailure() async throws {
        let store = MemoryPairingStore()
        let handle = IOSBridgePairingHandle.localDefault
        let first = try testRecord(key: testKey(1))
        let second = try testRecord(key: testKey(2))
        let initialAvailability = await store.availability(for: handle)
        XCTAssertEqual(initialAvailability, .missing)
        try await store.save(first, for: handle)
        let loadedFirstID = try await store.load(handle).tokenID
        XCTAssertEqual(loadedFirstID, first.tokenID)

        await store.setMode(.failSave)
        do {
            try await store.save(second, for: handle)
            XCTFail("save should fail")
        } catch {
            let stillFirstID = try await store.load(handle).tokenID
            XCTAssertEqual(stillFirstID, first.tokenID)
        }
        await store.setMode(.locked)
        let lockedAvailability = await store.availability(for: handle)
        XCTAssertEqual(lockedAvailability, .locked(reason: "test lock"))
        do {
            _ = try await store.load(handle)
            XCTFail("locked load should fail")
        } catch let error as IOSBridgePairingStoreError {
            XCTAssertEqual(error, .locked)
        }
        await store.setMode(.normal)
        try await store.delete(handle)
        let deletedAvailability = await store.availability(for: handle)
        XCTAssertEqual(deletedAvailability, .missing)
    }
}

final class CatalogContractTests: XCTestCase {
    func testEffectClassificationIncludesScrollingReadsAsMutating() {
        XCTAssertEqual(IOSAutomationAction.collect.effect, .mutating)
        XCTAssertEqual(IOSAutomationAction.scrollToElement.effect, .mutating)
        XCTAssertTrue(IOSAutomationAction.collect.requiresInputLease)
        XCTAssertTrue(IOSAutomationAction.scrollToElement.requiresInputLease)
        XCTAssertEqual(IOSAutomationAction.screenshot.effect, .readOnly)
        XCTAssertEqual(IOSAutomationAction.pageSource.effect, .readOnly)
        XCTAssertEqual(IOSAutomationAction.tap.effect, .mutating)
        XCTAssertEqual(IOSAutomationAction.type.effect, .mutating)
        XCTAssertEqual(IOSAutomationAction.launchApp.effect, .mutating)
        XCTAssertEqual(IOSAutomationAction.wait.effect, .readOnly)
    }

    func testAdministrativeMethodsNeverModelExposed() {
        for action in [IOSAutomationAction.config, .logs, .streamTicket, .reset] {
            XCTAssertFalse(action.isModelExposed, "\(action.rawValue)")
            XCTAssertNil(action.toolSurface, "\(action.rawValue)")
        }
        XCTAssertTrue(IOSAutomationAction.config.isAdministrative)
        XCTAssertTrue(IOSAutomationAction.streamTicket.isAdministrative)
        XCTAssertFalse(IOSAutomationCatalog.observeActionNames.contains("config"))
        XCTAssertFalse(IOSAutomationCatalog.controlActionNames.contains("config"))
        XCTAssertFalse(IOSAutomationCatalog.observeActionNames.contains("stream_ticket"))
    }

    func testToolSurfacePartitions() {
        XCTAssertEqual(IOSAutomationAction.screenshot.toolSurface, .observe)
        XCTAssertEqual(IOSAutomationAction.pageSource.toolSurface, .observe)
        XCTAssertEqual(IOSAutomationAction.findElement.toolSurface, .observe)
        XCTAssertEqual(IOSAutomationAction.tap.toolSurface, .control)
        XCTAssertEqual(IOSAutomationAction.collect.toolSurface, .control)
        XCTAssertEqual(IOSAutomationAction.launchApp.toolSurface, .control)
        let observe = Set(IOSAutomationCatalog.observeActionNames)
        let control = Set(IOSAutomationCatalog.controlActionNames)
        XCTAssertTrue(observe.isDisjoint(with: control))
        XCTAssertEqual(observe.count + control.count, IOSAutomationAction.allCases.filter(\.isModelExposed).count)
    }

    func testProtectedSurfacePolicy() {
        let policy = IOSAutomationProtectionPolicy.default
        XCTAssertNotNil(policy.mutationDenialReason(bundleIdentifier: "org.floeagent.ios"))
        XCTAssertNotNil(policy.mutationDenialReason(bundleIdentifier: "ORG.FLOEAGENT.IOSBRIDGE"))
        XCTAssertNil(policy.mutationDenialReason(bundleIdentifier: "com.example.notes"))
        XCTAssertNotNil(policy.readDenialReason(bundleIdentifier: "org.floeagent.iosbridge"))
        XCTAssertNil(policy.readDenialReason(bundleIdentifier: "com.example.notes"))
        XCTAssertNotNil(policy.urlDenialReason(URL(string: "floe://open")!))
        XCTAssertNotNil(policy.urlDenialReason(URL(string: "file:///tmp/secret")!))
        XCTAssertNotNil(policy.urlDenialReason(URL(string: "javascript:alert(1)")!))
        XCTAssertNil(policy.urlDenialReason(URL(string: "https://example.com/path")!))
    }

    func testParameterContractMatchesReleasedArguments() {
        XCTAssertEqual(
            IOSAutomationCatalog.requiredParameterNames(for: .findElement),
            ["element_id"]
        )
        XCTAssertEqual(
            IOSAutomationCatalog.requiredParameterNames(for: .type),
            ["text"]
        )
        XCTAssertEqual(
            IOSAutomationCatalog.requiredParameterNames(for: .openURL),
            ["url"]
        )
        XCTAssertEqual(
            IOSAutomationCatalog.requiredParameterNames(for: .launchApp),
            ["bundle_id"]
        )
        XCTAssertEqual(
            IOSAutomationCatalog.requiredParameterNames(for: .scrollToElement),
            ["element_id"]
        )
        XCTAssertEqual(IOSAutomationCatalog.requiredParameterNames(for: .tap), [])
        let pageSource = Dictionary(
            uniqueKeysWithValues: IOSAutomationAction.pageSource.parameters.map { ($0.name, $0.kind) }
        )
        XCTAssertEqual(pageSource["bundle_id"], .string)
        XCTAssertEqual(pageSource["filter"], .object)
        XCTAssertEqual(pageSource["visible_only"], .boolean)
        let screenshot = Dictionary(
            uniqueKeysWithValues: IOSAutomationAction.screenshot.parameters.map { ($0.name, $0.kind) }
        )
        XCTAssertEqual(screenshot["format"], .string)
        XCTAssertEqual(screenshot["quality"], .number)
        XCTAssertEqual(
            Set(IOSAutomationCatalog.observeParameterContract.keys),
            Set(IOSAutomationCatalog.observeActionNames)
        )
        XCTAssertEqual(
            Set(IOSAutomationCatalog.controlParameterContract.keys),
            Set(IOSAutomationCatalog.controlActionNames)
        )
        XCTAssertNil(IOSAutomationCatalog.observeParameterContract["config"])
        XCTAssertNil(IOSAutomationCatalog.controlParameterContract["config"])
    }

    func testCancellationBridgePollsPredicate() async throws {
        let flag = LockedValue(false)
        let token = IOSAutomationCancellationToken()
        let watcher = token.bridge(from: { flag.value }, pollInterval: .milliseconds(10))
        flag.set(true)
        for _ in 0..<50 {
            if token.isCancelled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(token.isCancelled)
        watcher.cancel()
    }

    func testOperationIDCanonicalRule() {
        XCTAssertTrue(IOSBridgeOperationID.isCanonical("iosauto-1234"))
        XCTAssertTrue(IOSBridgeOperationID.isCanonical("tool.call_1-A"))
        XCTAssertFalse(IOSBridgeOperationID.isCanonical(""))
        XCTAssertFalse(IOSBridgeOperationID.isCanonical("-bad"))
        XCTAssertFalse(IOSBridgeOperationID.isCanonical("has space"))
        XCTAssertFalse(IOSBridgeOperationID.isCanonical("."))
        XCTAssertFalse(IOSBridgeOperationID.isCanonical(".."))
        XCTAssertTrue(IOSBridgeOperationID.make().hasPrefix("iosauto-"))
        XCTAssertTrue(IOSBridgeOperationID.isCanonical(IOSBridgeOperationID.make()))
    }
}

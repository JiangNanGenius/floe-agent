import XCTest
@testable import FloeAndroidCore

/// A synthetic, in-process gateway used ONLY by these host tests to prove the
/// Swift-side seam is real. It is never registered outside tests and is NOT a
/// production memory backend — production has no memory fallback and the
/// original KeychainStore RAM stub is absent from the Android overlay.
final class SyntheticSecretGateway: AndroidSecretGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    // NSLock sections are sync helpers; async methods call them normally.
    private func value(for reference: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored[reference]
    }
    private func put(_ value: Data, for reference: String) {
        lock.lock(); stored[reference] = value; lock.unlock()
    }
    private func remove(_ reference: String) {
        lock.lock(); stored[reference] = nil; lock.unlock()
    }
    func read(reference: String) async throws -> Data? { value(for: reference) }
    func write(reference: String, value: Data) async throws { put(value, for: reference) }
    func delete(reference: String) async throws { remove(reference) }
    func snapshot() -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

final class SecretBackendTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SecretGatewayRegistry.shared.unregister()
    }
    override func tearDown() {
        SecretGatewayRegistry.shared.unregister()
        super.tearDown()
    }

    func testUnregisteredGatewayFailsClosedWithoutAnyMemoryFallback() async throws {
        XCTAssertFalse(SecretGatewayRegistry.shared.isRegistered)
        do {
            _ = try await SecretGatewayRegistry.shared.read(reference: "ref:v1:abc")
            XCTFail("unregistered gateway must fail closed")
        } catch let error as SecretGatewayError {
            XCTAssertEqual(error, .needsConfiguration)
        }
        // Writing also refuses: nothing may be buffered in process memory.
        do {
            try await SecretGatewayRegistry.shared.write(
                reference: "ref:v1:abc", value: Data("never-stored".utf8))
            XCTFail("unregistered gateway must reject writes")
        } catch let error as SecretGatewayError {
            XCTAssertEqual(error, .needsConfiguration)
        }
        let response = try XCTUnwrap(JSONSerialization.jsonObject(
            with: AndroidBridge.exchange(
                Data(#"{"version":2,"requestID":"s","operation":"credential.status"}"#.utf8)))
            as? [String: Any])
        let backend = try XCTUnwrap(response["secretBackend"] as? [String: Any])
        XCTAssertEqual(backend["registered"] as? Bool, false)
        XCTAssertEqual(backend["availability"] as? String, "NEEDS_CONFIGURATION")
        XCTAssertEqual(backend["memoryFallback"] as? Bool, false)
    }

    func testRegisteredGatewayRoundTripsThroughTheSeam() async throws {
        let gateway = SyntheticSecretGateway()
        SecretGatewayRegistry.shared.register(gateway)
        XCTAssertTrue(SecretGatewayRegistry.shared.isRegistered)
        let reference = SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                            account: "provider.example")
        try await SecretGatewayRegistry.shared.write(reference: reference,
                                                     value: Data("synthetic-secret".utf8))
        let value = try await SecretGatewayRegistry.shared.read(reference: reference)
        XCTAssertEqual(value, Data("synthetic-secret".utf8))
        try await SecretGatewayRegistry.shared.delete(reference: reference)
        let gone = try await SecretGatewayRegistry.shared.read(reference: reference)
        XCTAssertNil(gone)
        SecretGatewayRegistry.shared.unregister()
        // Late callbacks after unregister hit the fail-closed path again.
        do {
            _ = try await SecretGatewayRegistry.shared.read(reference: reference)
            XCTFail("unregistered gateway must fail closed")
        } catch let error as SecretGatewayError {
            XCTAssertEqual(error, .needsConfiguration)
        }
    }

    func testOpaqueReferencesAreDeterministicBoundedASCIIAndKeepUnicodeIdentity() {
        let a = SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                    account: "provider.公司网关-🔐")
        let b = SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                    account: "provider.公司网关-🔐")
        let c = SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                    account: "provider.公司网关-🔑")
        XCTAssertEqual(a, b, "deterministic")
        XCTAssertNotEqual(a, c, "account identity participates in the hash (not dropped)")
        XCTAssertTrue(SecretGatewayNaming.isBoundedASCII(a))
        XCTAssertTrue(a.hasPrefix("ref:v1:"))
        XCTAssertEqual(a.count, 71)
    }
}

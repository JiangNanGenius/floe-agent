import XCTest
@testable import FloeAndroidCore

final class BridgeTests: XCTestCase {
    func decode(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: AndroidBridge.exchange(Data(value.utf8))) as? [String: Any])
    }
    func testSharedPolicyAndUnicode() throws {
        let response = try decode(#"{"version":1,"requestID":"a","operation":"policy.inspect","policy":{"approvalMode":"ask","recoveryPolicy":"safePoint","notificationPolicy":"critical"},"echo":"中文 🧊"}"#)
        XCTAssertEqual(response["requestID"] as? String, "a")
        XCTAssertEqual(response["echo"] as? String, "中文 🧊")
        XCTAssertEqual(response["notifySuccess"] as? Bool, false)
        XCTAssertEqual(response["notifyFailure"] as? Bool, true)
        XCTAssertEqual(response["notifyApproval"] as? Bool, true)
    }
    func testMalformedAndVersionedRequestsFailClosed() throws {
        XCTAssertEqual(try decode("[]")["error"] as? String, "invalidJSON")
        // v1, v2 and v3 are now supported envelope versions
        // (BridgeEnvelopeV2Tests / BridgeEnvelopeV3Tests); an actually unknown
        // version still fails closed on the frozen v1 path. This narrow
        // fixture update replaces the stale v3 literal only.
        XCTAssertEqual(try decode(#"{"version":999,"operation":"handshake"}"#)["error"] as? String, "unsupportedVersion")
        XCTAssertEqual(try decode(#"{"operation":"handshake"}"#)["error"] as? String, "unsupportedVersion")
        XCTAssertEqual(try decode(#"{"version":1,"operation":"policy.inspect","policy":{"approvalMode":"anything"}}"#)["error"] as? String, "invalidPolicy")
        XCTAssertEqual(try decode(#"{"version":1,"operation":"exec.shell"}"#)["error"] as? String, "unsupportedOperation")
        let oversized = AndroidBridge.exchange(Data(repeating: 65, count: 65_537))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: oversized) as? [String: Any])?["error"] as? String, "requestTooLarge")
    }

    /// G01 freeze guard: the v1 handshake and policy.inspect bytes are
    /// unchanged by the append-only v2 addition.
    func testVersionOneSurfaceIsUnchanged() throws {
        let handshake = try decode(#"{"version":1,"requestID":"h","operation":"handshake"}"#)
        XCTAssertEqual(handshake["ok"] as? Bool, true)
        XCTAssertEqual(handshake["core"] as? String, "FloeAndroidCore")
        XCTAssertEqual(handshake["operations"] as? [String], ["handshake", "policy.inspect"])
        XCTAssertEqual(handshake["sharedModels"] as? [String], ["TaskPolicy"])
        XCTAssertEqual(handshake["localLLM"] as? Bool, false)
        XCTAssertEqual(handshake["version"] as? Int, 1)
        XCTAssertEqual(handshake["requestID"] as? String, "h")
    }
}

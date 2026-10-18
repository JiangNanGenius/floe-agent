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
        XCTAssertEqual(try decode(#"{"version":2,"operation":"handshake"}"#)["error"] as? String, "unsupportedVersion")
        XCTAssertEqual(try decode(#"{"version":1,"operation":"policy.inspect","policy":{"approvalMode":"anything"}}"#)["error"] as? String, "invalidPolicy")
        let oversized = AndroidBridge.exchange(Data(repeating: 65, count: 65_537))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: oversized) as? [String: Any])?["error"] as? String, "requestTooLarge")
    }
}

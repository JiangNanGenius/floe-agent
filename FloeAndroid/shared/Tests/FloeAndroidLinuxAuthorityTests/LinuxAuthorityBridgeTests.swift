// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 focused host checks for the additive C ABI
// (`floe_linux_authority_exchange` / `floe_linux_authority_free`) that
// Main's `LinuxAuthorityNative` JNI wraps (job-9c0066307afe460f). These
// exercise the REAL @_cdecl symbols, the blocking one-hop into the actor
// (no main-actor involvement), the 64 KiB ceiling, and the caller-owns-
// reply-buffer lifetime contract. No device, no process, no model call.

import XCTest
import Foundation
@testable import FloeAndroidLinuxAuthority

final class LinuxAuthorityBridgeTests: XCTestCase {

    private func replyDictionary(_ pointer: UnsafePointer<CChar>?) throws -> [String: Any] {
        guard let pointer else { throw XCTestFailure(message: "nil reply for non-nil input") }
        defer { floe_linux_authority_free(pointer) } // exactly-once free, always
        let string = String(cString: pointer)
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8), options: [.allowFragments])
        guard let dictionary = object as? [String: Any] else { throw XCTestFailure(message: "reply not an object: \(string)") }
        return dictionary
    }

    private func exchange(_ request: String) throws -> [String: Any] {
        let raw = strdup(request)!
        defer { free(raw) }
        return try replyDictionary(floe_linux_authority_exchange(raw))
    }

    func testHandshakeRoundTripAndFree() throws {
        let reply = try exchange(#"{"version":1,"operation":"handshake"}"#)
        XCTAssertEqual(reply["version"] as? Int, 1)
        let outcome = try XCTUnwrap(reply["outcome"] as? [String: Any])
        let ok = try XCTUnwrap(outcome["ok"] as? [String: Any])
        let handshake = try XCTUnwrap(ok["handshake"] as? [String: Any])
        XCTAssertEqual(handshake["wireVersion"] as? Int, 1)
        XCTAssertEqual(handshake["maxConcurrentRuntimeLeases"] as? Int, 3)
        XCTAssertEqual(handshake["maxInteractiveLeases"] as? Int, 2)
        XCTAssertEqual(handshake["maxExecutionLeases"] as? Int, 1)
        XCTAssertEqual(handshake["maxAgentLeases"] as? Int, 1)
        XCTAssertEqual(handshake["activeLeases"] as? Int, 0)
        XCTAssertEqual(handshake["execShellReady"] as? Bool, false, "the C surface must never advertise exec.shell readiness")
    }

    func testRequestIDEchoAcrossCBoundary() throws {
        let reply = try exchange(#"{"version":1,"requestID":"jni-42","operation":"handshake"}"#)
        XCTAssertEqual(reply["requestID"] as? String, "jni-42")
    }

    func testNilInputYieldsNil() {
        XCTAssertNil(floe_linux_authority_exchange(nil))
        floe_linux_authority_free(nil) // cleanup-tolerant free of nil is a no-op
    }

    func testEmptyInputFailsClosed() throws {
        let reply = try exchange("")
        let failure = try XCTUnwrap((reply["outcome"] as? [String: Any])?["failure"] as? [String: Any])
        XCTAssertEqual(failure["code"] as? String, "invalidWire")
    }

    func testMalformedJSONFailsClosedNotCrash() throws {
        let reply = try exchange(#"{"version":1,operation"#)
        let failure = try XCTUnwrap((reply["outcome"] as? [String: Any])?["failure"] as? [String: Any])
        XCTAssertEqual(failure["code"] as? String, "invalidWire")
    }

    func testOversizedRequestFailsClosedWithoutTouchingTheAuthority() throws {
        // 70 KiB NUL-terminated garbage: strnlen caps at the ceiling, the
        // wire gate refuses before parsing, and the reply is always returned.
        let size = 70_000
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size + 1)
        defer { buffer.deallocate() }
        memset(buffer, 0x78, size) // 'x'
        buffer[size] = 0
        let reply = try replyDictionary(floe_linux_authority_exchange(buffer))
        let failure = try XCTUnwrap((reply["outcome"] as? [String: Any])?["failure"] as? [String: Any])
        XCTAssertEqual(failure["code"] as? String, "requestTooLarge")
    }

    func testBlockingBridgeDoesNotNeedMainActorAndServesConcurrentCallers() {
        // The test method body runs on the main thread: a blocking exchange
        // must complete through the global-executor actor hop (no MainActor
        // anywhere), and concurrent native IO-style callers are serialized
        // safely by the actor.
        let attempts = 8
        let results = UnsafeMutablePointer<[String: Any]?>.allocate(capacity: attempts)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: attempts) { index in
            let request = #"{"version":1,"operation":"handshake"}"#
            let raw = strdup(request)!
            defer { free(raw) }
            let reply = floe_linux_authority_exchange(raw)
            defer { floe_linux_authority_free(reply) }
            if let reply, let object = try? JSONSerialization.jsonObject(with: Data(String(cString: reply).utf8)),
               let dictionary = object as? [String: Any] {
                results[index] = dictionary
            } else {
                results[index] = nil
            }
        }
        for index in 0..<attempts {
            guard let reply = results[index],
                  let outcome = reply["outcome"] as? [String: Any],
                  let ok = outcome["ok"] as? [String: Any],
                  let handshake = ok["handshake"] as? [String: Any],
                  handshake["wireVersion"] as? Int == 1 else {
                return XCTFail("concurrent exchange \(index) did not return a valid handshake reply")
            }
        }
    }

    func testSwiftBlockingEntryMirrorsCEntry() throws {
        let direct = FloeLinuxAuthorityBridge.blockingExchange(Data(#"{"version":1,"operation":"handshake"}"#.utf8))
        let object = try JSONSerialization.jsonObject(with: direct) as? [String: Any]
        XCTAssertNotNil((object?["outcome"] as? [String: Any])?["ok"])
    }
}

private struct XCTestFailure: Error { let message: String }

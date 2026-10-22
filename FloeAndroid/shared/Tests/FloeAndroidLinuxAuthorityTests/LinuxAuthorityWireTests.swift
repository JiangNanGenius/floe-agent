// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 focused host checks for the Linux authority WIRE_V1 contract
// (job-9c0066307afe460f). Pure shape/transport coverage: no real rootfs,
// no process, no model call. These fixtures ARE the wire documentation —
// golden bytes here are exactly what Main's JNI layer will parse.

import XCTest
import Foundation
@testable import FloeAndroidLinuxAuthority

final class LinuxAuthorityWireTests: XCTestCase {

    // MARK: - Helpers

    private func data(_ string: String) -> Data { Data(string.utf8) }

    private func dictionary(_ reply: Data, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: reply, options: [.allowFragments])
            guard let dictionary = object as? [String: Any] else {
                XCTFail("reply is not a JSON object: \(String(decoding: reply, as: UTF8.self))", file: file, line: line)
                return [:]
            }
            return dictionary
        } catch {
            XCTFail("reply is not valid JSON: \(String(decoding: reply, as: UTF8.self)) — \(error)", file: file, line: line)
            return [:]
        }
    }

    private func failure(_ reply: Data, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let outcome = dictionary(reply, file: file, line: line)["outcome"] as? [String: Any],
              let failure = outcome["failure"] as? [String: Any] else {
            XCTFail("expected failure outcome: \(String(decoding: reply, as: UTF8.self))", file: file, line: line)
            return [:]
        }
        return failure
    }

    private func failureCode(_ reply: Data, _ context: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let object = failure(reply, file: file, line: line)
        guard let code = object["code"] as? String else {
            XCTFail("failure without code in \(context): \(object)", file: file, line: line)
            return ""
        }
        return code
    }

    private func successPayload(_ reply: Data, _ operation: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let outcome = dictionary(reply, file: file, line: line)["outcome"] as? [String: Any],
              let ok = outcome["ok"] as? [String: Any],
              let payload = ok[operation] as? [String: Any] else {
            XCTFail("expected ok.\(operation) outcome: \(String(decoding: reply, as: UTF8.self))", file: file, line: line)
            return [:]
        }
        return payload
    }

    // MARK: - Golden request bytes (explicit frozen encoding)

    func testOperationEncodingGoldenBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = LinuxAuthorityProcessIdentity(pid: 4242, pgid: 4200, launcherToken: "launch-1", startedAtUnixMillis: 1_760_000_000_000)

        let cases: [(LinuxAuthorityOperation, String)] = [
            (.handshake, #""handshake""#),
            (.list, #""list""#),
            (.configure(.init(stateRoot: "/s", workspacesRoot: "/w", baseRoot: "/b", baseRevision: "r")),
             #"{"configure":{"baseRevision":"r","baseRoot":"/b","stateRoot":"/s","workspacesRoot":"/w"}}"#),
            (.acquire(.init(projectID: "P", runID: "R", conversationID: nil, environmentID: "E")),
             #"{"acquire":{"environmentID":"E","projectID":"P","runID":"R"}}"#),
            (.markStarted(.init(leaseID: "L", processIdentity: identity)),
             #"{"markStarted":{"leaseID":"L","processIdentity":{"launcherToken":"launch-1","pgid":4200,"pid":4242,"startedAtUnixMillis":1760000000000}}}"#),
            (.cancel(.init(leaseID: "L")),
             #"{"cancel":{"leaseID":"L"}}"#),
            (.abandon(.init(leaseID: "L")),
             #"{"abandon":{"leaseID":"L"}}"#),
            (.complete(.init(leaseID: "L", processIdentity: identity,
                             quiescence: .init(exitStatus: 9, reaped: true))),
             #"{"complete":{"leaseID":"L","processIdentity":{"launcherToken":"launch-1","pgid":4200,"pid":4242,"startedAtUnixMillis":1760000000000},"quiescence":{"exitStatus":9,"reaped":true}}}"#),
        ]
        func comparable(_ json: Any) -> NSObject {
            if let dictionary = json as? NSDictionary { return dictionary }
            if let string = json as? String { return string as NSString }
            return "\(json)" as NSString
        }
        for (operation, expected) in cases {
            let encoded = try encoder.encode(operation)
            // Compare SEMANTIC JSON (Foundation's encoder escapes '/' as '\/',
            // which any standard parser — including Kotlin's — decodes back
            // to '/'). Documented in WIRE_V1; the shape (bare string vs
            // single-key object, key names, no `_0` wrapper) is asserted here.
            let actualJSON = try JSONSerialization.jsonObject(with: encoded, options: [.allowFragments])
            let expectedJSON = try JSONSerialization.jsonObject(with: Data(expected.utf8), options: [.allowFragments])
            XCTAssertEqual(comparable(actualJSON), comparable(expectedJSON), "operation bytes for \(operation)")
        }
    }

    func testFoundationEncoderSlashEscapingIsAcceptedShape() throws {
        // WIRE_V1 note: paths inside request/reply JSON arrive with `\/`
        // escaping from Foundation's encoder; this is valid JSON and the
        // authority decodes them back to plain `/` before any use.
        let request = LinuxAuthorityRequest(version: 1, requestID: nil,
                                            operation: .configure(.init(stateRoot: "/s", workspacesRoot: "/w",
                                                                        baseRoot: "/b", baseRevision: "r")))
        let bytes = try JSONEncoder().encode(request)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\\/"))
        let decoded = try LinuxAuthorityWire.decodeRequest(bytes)
        guard case .configure(let config) = decoded.operation else { return XCTFail("shape") }
        XCTAssertEqual(config.stateRoot, "/s")
    }

    func testEnvelopeRoundTripStrictDecode() throws {
        let request = LinuxAuthorityRequest(version: 1, requestID: "req-7",
                                            operation: .acquire(.init(projectID: "P", runID: "R",
                                                                      conversationID: "C", environmentID: nil)))
        let encoded = try JSONEncoder().encode(request)
        let decoded = try LinuxAuthorityWire.decodeRequest(encoded)
        XCTAssertEqual(decoded, request)
        // Explicit null and an absent key are documented-equivalent.
        let nullForm = try LinuxAuthorityWire.decodeRequest(
            data(#"{"version":1,"operation":{"acquire":{"conversationID":null,"projectID":"P","runID":"R"}}}"#))
        guard case .acquire(let acquire) = nullForm.operation else { return XCTFail("shape") }
        XCTAssertNil(acquire.conversationID)
        XCTAssertNil(acquire.environmentID)
    }

    // MARK: - Strict unknown-field gate (the defect Main's review caught)

    func testUnknownEnvelopeKeyFailsClosed() async {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(data(#"{"version":1,"operation":"handshake","quota":true}"#))
        let object = failure(reply)
        XCTAssertEqual(object["code"] as? String, "invalidWire")
        XCTAssertTrue((object["message"] as? String ?? "").contains("unknown field 'quota'"),
                      "typed CodingKeys must not hide unknown keys: \(object)")
    }

    func testUnknownNestedPayloadKeyFailsClosed() async {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(
            data(#"{"version":1,"operation":{"configure":{"stateRoot":"/s","workspacesRoot":"/w","baseRoot":"/b","baseRevision":"r","tempAllowed":true}}}"#))
        let object = failure(reply)
        XCTAssertEqual(object["code"] as? String, "invalidWire")
        XCTAssertTrue((object["message"] as? String ?? "").contains("unknown field 'tempAllowed'"))
    }

    func testUnknownKeyInsideNestedIdentityAndQuiescence() async {
        let authority = FloeLinuxAuthority()
        let identityReply = await authority.exchange(
            data(#"{"version":1,"operation":{"markStarted":{"leaseID":"L","processIdentity":{"pid":1,"launcherToken":"t","reentrant":false}}}}"#))
        XCTAssertEqual(failureCode(identityReply, "markStarted identity"), "invalidWire")
        XCTAssertTrue((failure(identityReply)["message"] as? String ?? "").contains("unknown field 'reentrant'"))

        let quiescenceReply = await authority.exchange(
            data(#"{"version":1,"operation":{"complete":{"leaseID":"L","processIdentity":{"pid":1,"launcherToken":"t"},"quiescence":{"exitStatus":0,"reaped":true,"trustMe":true}}}}"#))
        XCTAssertEqual(failureCode(quiescenceReply, "complete quiescence"), "invalidWire")
        XCTAssertTrue((failure(quiescenceReply)["message"] as? String ?? "").contains("unknown field 'trustMe'"))
    }

    func testMissingAndWrongTypeFieldsFailClosed() async {
        let authority = FloeLinuxAuthority()
        let cases = [
            // missing version / operation
            #"{"requestID":"a","operation":"handshake"}"#,
            #"{"version":1}"#,
            // wrong types
            #"{"version":"1","operation":"handshake"}"#,
            #"{"version":1,"operation":{"acquire":{"projectID":"P","runID":123}}}"#,
            #"{"version":1,"operation":{"acquire":{"projectID":"P","runID":"R","conversationID":5}}}"#,
            // invalid operation shapes (Main: explicit encoding, no synthesis surprises)
            #"{"version":1,"operation":"unknownThing"}"#,
            #"{"version":1,"operation":{}}"#,
            #"{"version":1,"operation":{"handshake":{}}}"#,
            #"{"version":1,"operation":{"acquire":{"leaseID":"L"},"list":{}}}"#,
            #"{"version":1,"operation":{"cancel":"not-an-object"}}"#,
            #"{"version":1,"operation":12}"#,
        ]
        for raw in cases {
            let reply = await authority.exchange(data(raw))
            XCTAssertEqual(failureCode(reply, raw), "invalidWire", "case \(raw)")
        }
    }

    // MARK: - Size / version / transport gates

    func testOversizedRequestFailsClosedBeforeParsing() async {
        let authority = FloeLinuxAuthority()
        let padding = String(repeating: "x", count: 66_000)
        let reply = await authority.exchange(data(#"{"version":1,"operation":"handshake","note":"\#(padding)"}"#))
        XCTAssertEqual(failureCode(reply, "oversized"), "requestTooLarge")
    }

    func testNonUTF8RequestFailsClosed() async {
        let authority = FloeLinuxAuthority()
        // 0xFF is not a valid UTF-8 lead byte.
        let garbage = Data([0x7B, 0x22, 0x76, 0xFF, 0xFE, 0x00, 0x7D])
        let reply = await authority.exchange(garbage)
        XCTAssertEqual(failureCode(reply, "non-UTF8"), "invalidWire")
    }

    func testEmptyRequestFailsClosed() async {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(Data())
        XCTAssertEqual(failureCode(reply, "empty"), "invalidWire")
        XCTAssertTrue((failure(reply)["message"] as? String ?? "").contains("empty"))
    }

    func testUnsupportedVersionButValidShape() async {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(data(#"{"version":2,"operation":"handshake"}"#))
        XCTAssertEqual(failureCode(reply, "version 2"), "unsupportedVersion")
    }

    func testRequestIDRulesAndEcho() async throws {
        let authority = FloeLinuxAuthority()
        let echoed = await authority.exchange(data(#"{"version":1,"requestID":"req-1","operation":"handshake"}"#))
        XCTAssertEqual(dictionary(echoed)["requestID"] as? String, "req-1")

        let tooLong = await authority.exchange(data(
            "{\"version\":1,\"requestID\":\"\(String(repeating: "r", count: 65))\",\"operation\":\"handshake\"}"))
        XCTAssertEqual(failureCode(tooLong, "long requestID"), "invalidWire")

        let control = await authority.exchange(data(#"{"version":1,"requestID":"bad\u0007id","operation":"handshake"}"#))
        XCTAssertEqual(failureCode(control, "control requestID"), "invalidWire")
    }

    // MARK: - Golden reply bytes (exactly what JNI parses)

    func testHandshakeReplyGoldenBytesOnFreshAuthority() async throws {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(data(#"{"version":1,"operation":"handshake"}"#))
        let expected = #"{"outcome":{"ok":{"handshake":{"activeLease":false,"configurationInFlight":false,"configured":false,"execShellReady":false,"leaseAdmissionPending":false,"maxConcurrentRuntimeLeases":1,"wireVersion":1}}},"requestID":null,"version":1}"#
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), expected)
        // Reply must also decode into the typed value (round-trip symmetry).
        let decoded = try JSONDecoder().decode(LinuxAuthorityReply.self, from: reply)
        XCTAssertEqual(decoded, LinuxAuthorityReply(version: 1, requestID: nil,
                                                    outcome: .ok(.handshake(LinuxAuthorityHandshakeInfo(
                                                        wireVersion: 1, configured: false, activeLease: false,
                                                        leaseAdmissionPending: false, configurationInFlight: false,
                                                        maxConcurrentRuntimeLeases: 1, execShellReady: false)))))
    }

    func testFailureReplyGoldenBytes() async throws {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(data(#"{"version":1,"requestID":"r1","operation":"list"}"#))
        let expected = #"{"outcome":{"failure":{"code":"notConfigured","message":"configure the authority with trusted roots first"}},"requestID":"r1","version":1}"#
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), expected)
    }

    func testEveryLifecycleOperationRefusesUnconfigured() async {
        let authority = FloeLinuxAuthority()
        let cases = [
            #"{"version":1,"operation":{"acquire":{"projectID":"\#(UUID().uuidString)","runID":"\#(UUID().uuidString)"}}}"#,
            #"{"version":1,"operation":{"markStarted":{"leaseID":"\#(UUID().uuidString)","processIdentity":{"pid":1,"launcherToken":"t"}}}}"#,
            #"{"version":1,"operation":{"cancel":{"leaseID":"\#(UUID().uuidString)"}}}"#,
            #"{"version":1,"operation":{"complete":{"leaseID":"\#(UUID().uuidString)","processIdentity":{"pid":1,"launcherToken":"t"},"quiescence":{"exitStatus":0,"reaped":true}}}}"#,
            #"{"version":1,"operation":{"abandon":{"leaseID":"\#(UUID().uuidString)"}}}"#,
        ]
        for raw in cases {
            let reply = await authority.exchange(data(raw))
            XCTAssertEqual(failureCode(reply, raw), "notConfigured", "case \(raw)")
        }
    }

    func testHandshakeSuccessPayloadShapeViaExchange() async throws {
        let authority = FloeLinuxAuthority()
        let reply = await authority.exchange(data(#"{"version":1,"operation":"handshake"}"#))
        let payload = successPayload(reply, "handshake")
        XCTAssertEqual(payload["wireVersion"] as? Int, 1)
        XCTAssertEqual(payload["maxConcurrentRuntimeLeases"] as? Int, 1)
        XCTAssertEqual(payload["execShellReady"] as? Bool, false)
        XCTAssertEqual(payload["leaseAdmissionPending"] as? Bool, false)
        XCTAssertEqual(payload["configurationInFlight"] as? Bool, false)
    }

    func testMessageBoundingIsStableAndBounded() {
        let huge = String(repeating: "ü", count: 2_000)
        let bounded = LinuxAuthorityWire.boundedMessage(huge)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 512)
        XCTAssertTrue(bounded.hasSuffix("…"))
        let exact = LinuxAuthorityWire.failureData(code: .internalError, message: huge, requestID: "abc")
        XCTAssertLessThanOrEqual(exact.count, LinuxAuthorityWire.maximumBytes)
    }
}

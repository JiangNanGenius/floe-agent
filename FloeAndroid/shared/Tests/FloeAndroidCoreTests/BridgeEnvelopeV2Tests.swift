import XCTest
@testable import FloeAndroidCore

/// Host tests for the append-only bridge protocol v2 envelope seam.
/// Synthetic identities/JSON only; nothing here executes a task, provider
/// or credential operation, and every refusal is a typed failure.
final class BridgeEnvelopeV2Tests: XCTestCase {
    private func exchange(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: AndroidBridge.exchange(Data(json.utf8)))
                      as? [String: Any])
    }
    private let task = UUID().uuidString
    private let run = UUID().uuidString
    private let env = UUID().uuidString
    private let job = UUID().uuidString

    private func envelope(scope: String = "\"taskExecution\"",
                          owner: Bool = true,
                          command: String = "\"chat.send\"",
                          stateful: Bool = false,
                          statefulLiteral: String? = nil,
                          revision: String? = nil,
                          cursor: String? = nil,
                          grantID: String? = nil,
                          configurationScope: String? = nil,
                          correlation: String = "\"c-1\"",
                          payload: String? = nil) -> String {
        var parts: [String] = ["\"scope\":\(scope)"]
        if owner {
            parts.append("\"owner\":{\"taskID\":\"\(task)\",\"runID\":\"\(run)\",\"environmentID\":\"\(env)\",\"jobID\":\"\(job)\"}")
        }
        if let configurationScope {
            parts.append("\"configurationScope\":\(configurationScope)")
        }
        parts.append("\"command\":\(command)")
        parts.append("\"stateful\":\(statefulLiteral ?? (stateful ? "true" : "false"))")
        if let revision { parts.append("\"revision\":\(revision)") }
        if let cursor { parts.append("\"cursor\":\(cursor)") }
        if let grantID { parts.append("\"grantID\":\(grantID)") }
        parts.append("\"correlationID\":\(correlation)")
        if let payload { parts.append("\"payload\":\(payload)") }
        return "{" + parts.joined(separator: ",") + "}"
    }
    private func request(_ operation: String, _ body: String, id: String = "c-1") -> String {
        "{\"version\":2,\"requestID\":\"\(id)\",\"operation\":\"\(operation)\",\"envelope\":\(body)}"
    }

    func testHandshakeAdvertisesOnlyExecutableOperations() throws {
        let response = try exchange(#"{"version":2,"requestID":"h2","operation":"handshake"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["version"] as? Int, 2)
        XCTAssertEqual(response["requestID"] as? String, "h2")
        XCTAssertEqual(response["operations"] as? [String], ["handshake", "credential.status"])
        // Staged schema support is explicitly labelled unbound — it is NOT an
        // advertisement of working task/provider operations.
        let staged = try XCTUnwrap(response["stagedOperations"] as? [[String: Any]])
        XCTAssertEqual(staged.count, 2)
        XCTAssertTrue(staged.allSatisfy { ($0["bound"] as? Bool) == false })
        XCTAssertEqual(response["localLLM"] as? Bool, false)
    }

    func testCredentialStatusIsFailClosedAndNeverMemoryBacked() throws {
        let response = try exchange(#"{"version":2,"requestID":"s","operation":"credential.status"}"#)
        let backend = try XCTUnwrap(response["secretBackend"] as? [String: Any])
        let registered = try XCTUnwrap(backend["registered"] as? Bool)
        // Availability must match the registration state exactly; the RAM
        // fallback flag is structurally impossible (KeychainStore absent).
        XCTAssertEqual(backend["availability"] as? String,
                       registered ? "AVAILABLE" : "NEEDS_CONFIGURATION")
        XCTAssertEqual(backend["memoryFallback"] as? Bool, false)
    }

    func testValidTaskExecutionCommandFailsClosedOnUnboundBinder() throws {
        let response = try exchange(request("command.submit", envelope()))
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(response["reason"] as? String, "commandBinderUnbound")
        XCTAssertEqual(response["requestID"] as? String, "c-1")
        XCTAssertEqual(response["version"] as? Int, 2)
    }

    func testBinderSeamIsRealWithSyntheticHandler() throws {
        // Proves the seam executes host-registered handlers, not just errors.
        RuntimeCommandBinder.shared.register("test.echo") { data in
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return Data(#"{"ok":false}"#.utf8)
            }
            let out = ["ok": true, "echoCommand": object["command"] ?? "",
                       "source": "synthetic-test-binder"]
            return (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister("test.echo") }
        let response = try exchange(request("command.submit", envelope(command: "\"test.echo\"")))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["echoCommand"] as? String, "test.echo")
        XCTAssertEqual(response["source"] as? String, "synthetic-test-binder")
    }

    func testEventPollRequiresCursorAndFailsClosed() throws {
        let missing = try exchange(request("event.poll", envelope()))
        XCTAssertEqual(missing["error"] as? String, "invalidEnvelope")
        XCTAssertEqual(missing["reason"] as? String, "missingEventCursor")
        let valid = try exchange(request("event.poll",
            envelope(cursor: "{\"runID\":\"\(run)\",\"sequence\":42}")))
        XCTAssertEqual(valid["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(valid["reason"] as? String, "eventPumpUnbound")
    }

    func testNegativeIdentityEnvelopeMatrix() throws {
        let zero = "00000000-0000-0000-0000-000000000000"
        let cases: [(String, String)] = [
            (envelope(owner: false), "missingExecutionOwner"),
            ("{\"scope\":\"taskExecution\",\"owner\":{\"taskID\":\"not-a-uuid\",\"runID\":\"\(run)\",\"environmentID\":\"\(env)\",\"jobID\":\"\(job)\"},\"command\":\"a.b\",\"stateful\":false,\"correlationID\":\"c-1\"}",
             "invalidOwnertaskID"),
            ("{\"scope\":\"taskExecution\",\"owner\":{\"taskID\":\"\(zero)\",\"runID\":\"\(run)\",\"environmentID\":\"\(env)\",\"jobID\":\"\(job)\"},\"command\":\"a.b\",\"stateful\":false,\"correlationID\":\"c-1\"}",
             "invalidOwnertaskID"),
            // The former duplicateExecutionIdentity rejection was an invented
            // value-inequality rule, not part of the frozen RuntimeContracts
            // (ExecutionOwner has no distinctness requirement). Role fields
            // may intentionally alias (root jobID == runID); the positive
            // alias test below covers that case. Presence, UUID parse,
            // non-nil and cursor-run checks remain in this matrix.
            (envelope(command: "\"\""), "invalidCommand"),
            (envelope(command: "\"chat send\""), "invalidCommand"),
            ("{\"scope\":\"other\",\"owner\":{\"taskID\":\"\(task)\",\"runID\":\"\(run)\",\"environmentID\":\"\(env)\",\"jobID\":\"\(job)\"},\"command\":\"a.b\",\"stateful\":false,\"correlationID\":\"c-1\"}",
             "unknownScope"),
            (envelope(scope: "\"applicationConfiguration\"", owner: true,
                      command: "\"settings.save\""), "configurationScopeMustNotCarryOwner"),
            (envelope(scope: "\"applicationConfiguration\"", owner: false,
                      command: "\"settings.save\""), "missingConfigurationScope"),
            (envelope(stateful: true), "missingRevisionForStatefulCommand"),
            (envelope(revision: "{\"resourceID\":\"r\",\"version\":\"\"}"), "invalidRevision"),
            (envelope(cursor: "{\"runID\":\"\(env)\",\"sequence\":0}"), "cursorRunMismatch"),
            (envelope(cursor: "{\"runID\":\"\(run)\",\"sequence\":-1}"), "invalidEventCursor"),
            (envelope(grantID: "\"nope\""), "invalidGrantReference"),
            (envelope(correlation: "\"different\""), "MISMATCH"),
        ]
        for (body, expectedReason) in cases {
            let response = try exchange(request("command.submit", body))
            XCTAssertEqual(response["ok"] as? Bool, false, body)
            if expectedReason == "MISMATCH" {
                XCTAssertEqual(response["error"] as? String, "correlationMismatch", body)
            } else {
                XCTAssertEqual(response["error"] as? String, "invalidEnvelope", body)
                XCTAssertEqual(response["reason"] as? String, expectedReason, body)
            }
        }
    }

    func testStatefulFlagRequiresAnActualJSONBoolean() throws {
        // Main repro: Foundation `is Bool` bridged numeric 0/1 and accepted
        // them, so these envelopes reached the unbound-binder seam instead of
        // being typed-invalid. A stateful command must never bypass revision.
        for literal in ["0", "1", "0.0", "\"false\"", "null"] {
            let body = envelope(statefulLiteral: literal,
                                revision: "{\"resourceID\":\"r\",\"version\":\"1\"}")
            let response = try exchange(request("command.submit", body))
            XCTAssertEqual(response["ok"] as? Bool, false, literal)
            XCTAssertEqual(response["error"] as? String, "invalidEnvelope", literal)
            XCTAssertEqual(response["reason"] as? String, "invalidStatefulFlag", literal)
        }
        let typed = try exchange(request("command.submit",
            envelope(statefulLiteral: "true",
                     revision: "{\"resourceID\":\"r\",\"version\":\"1\"}")))
        XCTAssertEqual(typed["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(typed["reason"] as? String, "commandBinderUnbound")
    }

    func testEventCursorSequenceRequiresAnInRangeJSONInteger() throws {
        // `true` was previously bridged to 1 and accepted; fractional,
        // overflow and string values must also be rejected as typed-invalid.
        for literal in ["true", "false", "\"1\"", "1.5", "9223372036854775808", "-1"] {
            let response = try exchange(request("event.poll",
                envelope(cursor: "{\"runID\":\"\(run)\",\"sequence\":\(literal)}")))
            XCTAssertEqual(response["ok"] as? Bool, false, literal)
            XCTAssertEqual(response["error"] as? String, "invalidEnvelope", literal)
            XCTAssertEqual(response["reason"] as? String, "invalidEventCursor", literal)
        }
        let zero = try exchange(request("event.poll",
            envelope(cursor: "{\"runID\":\"\(run)\",\"sequence\":0}")))
        XCTAssertEqual(zero["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(zero["reason"] as? String, "eventPumpUnbound")
    }

    func testRevisionAndCorrelationRejectWhitespaceOnlyValues() throws {
        for revision in ["{\"resourceID\":\"   \",\"version\":\"1\"}",
                         "{\"resourceID\":\"r\",\"version\":\"\\t\\n\"}"] {
            let response = try exchange(request("command.submit", envelope(revision: revision)))
            XCTAssertEqual(response["error"] as? String, "invalidEnvelope", revision)
            XCTAssertEqual(response["reason"] as? String, "invalidRevision", revision)
        }
        let blankCorrelation = try exchange(request("command.submit",
            envelope(correlation: "\" \\t \"")))
        XCTAssertEqual(blankCorrelation["error"] as? String, "invalidEnvelope")
        XCTAssertEqual(blankCorrelation["reason"] as? String, "missingCorrelation")
        // Correlation is an opaque identity: surrounding spaces are kept, so
        // a spaced correlation only matches an exactly spaced requestID.
        let exact = try exchange(request("command.submit",
            envelope(correlation: "\" c-1 \""), id: " c-1 "))
        XCTAssertEqual(exact["error"] as? String, "runtimeUnavailable")
        let trimmed = try exchange(request("command.submit",
            envelope(correlation: "\" c-1 \""), id: "c-1"))
        XCTAssertEqual(trimmed["error"] as? String, "correlationMismatch")
    }

    func testExplicitAliasedRoleIDsStayStructuralAndUnbound() throws {
        // Roles are structured fields, not value-unique slots: a root jobID
        // equal to its runID is legitimate. Parsing this shape must not grant
        // authority or fabricate success; it reaches the same fail-closed seam.
        let body = "{\"scope\":\"taskExecution\",\"owner\":{\"taskID\":\"\(task)\",\"runID\":\"\(run)\",\"environmentID\":\"\(env)\",\"jobID\":\"\(run)\"},\"command\":\"chat.send\",\"stateful\":false,\"correlationID\":\"c-1\"}"
        let response = try exchange(request("command.submit", body))
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(response["reason"] as? String, "commandBinderUnbound")
    }

    func testMixedPrimitivePayloadStillReachesUnboundSeam() throws {
        // The strict envelope union must distinguish types without rejecting
        // a legitimate arbitrary payload (array/dict/scalar fragments).
        for payload in ["{\"nested\":[1,true,null,{\"text\":\"值\"}]}",
                        "\"text\"", "42", "true"] {
            let response = try exchange(request("command.submit", envelope(payload: payload)))
            XCTAssertEqual(response["error"] as? String, "runtimeUnavailable", payload)
            XCTAssertEqual(response["reason"] as? String, "commandBinderUnbound", payload)
        }
    }

    func testApplicationConfigurationScopeValidatesButStaysUnbound() throws {
        let body = envelope(scope: "\"applicationConfiguration\"", owner: false,
                            command: "\"provider.configure\"",
                            revision: "{\"resourceID\":\"provider\",\"version\":\"7\"}",
                            configurationScope: "\"floe.app.settings.v1\"",
                            correlation: "\"c-1\"")
        let response = try exchange(request("command.submit", body))
        // Explicit host configuration scope passes identity rules; no task/run
        // UUIDs are fabricated, and the binder is still unbound (fail closed).
        XCTAssertEqual(response["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(response["reason"] as? String, "commandBinderUnbound")
    }

    func testUnknownOperationAndOversizeFailClosed() throws {
        let unknown = try exchange(#"{"version":2,"requestID":"u","operation":"linux.exec"}"#)
        XCTAssertEqual(unknown["error"] as? String, "unsupportedOperation")
        let oversized = AndroidBridge.exchange(Data(repeating: 122, count: 65_537))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: oversized) as? [String: Any])?["error"]
                       as? String, "requestTooLarge")
    }
}

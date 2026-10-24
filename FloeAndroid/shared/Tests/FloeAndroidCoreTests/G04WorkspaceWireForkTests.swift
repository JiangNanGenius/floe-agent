// SPDX-License-Identifier: MPL-2.0
// Additive G04 grammar tests: forkDraft (D15 KEEP_BOTH) and workspace.activate
// (D14). AUTHORED, NOT EXECUTED (grouped cohort).
import Foundation
import Testing
@testable import FloeAndroidCore

struct G04WorkspaceWireForkTests {
    private func payload(_ operation: String,
                         _ fields: [String: SettingsDomainV1.JSONValue]) -> SettingsDomainV1.JSONValue {
        .object(fields.merging(["op": .string(operation), "workspaceID": .string(UUID().uuidString),
                                "nativeEpoch": .string("27")]) { original, _ in original })
    }

    @Test func forkDraftCarriesOnlyIdentityAndNeverText() throws {
        let valid = try G04WorkspaceWireRequest(payload: payload("forkDraft", [
            "documentID": .string(UUID().uuidString), "revision": .string("rev"),
            "destination": .string("main-copy.kt"), "discardAfterCopy": .boolean(true),
        ]), command: "workspace.write")
        #expect(valid.operation == .forkDraft && !valid.operation.isRead)
        // Any text/payload smuggling field refuses before anything else.
        for smuggled in ["content", "text", "draft", "sourceURI", "rootPath", "runID"] {
            #expect(throws: G04WorkspaceWireRequest.Failure.self) {
                _ = try G04WorkspaceWireRequest(payload: payload("forkDraft", [
                    "documentID": .string(UUID().uuidString), "revision": .string("rev"), smuggled: .string("x"),
                ]), command: "workspace.write")
            }
        }
        // Absolute/tilde destinations refuse.
        for bad in ["/tmp/x", "~x"] {
            #expect(throws: G04WorkspaceWireRequest.Failure.self) {
                _ = try G04WorkspaceWireRequest(payload: payload("forkDraft", [
                    "documentID": .string(UUID().uuidString), "revision": .string("rev"), "destination": .string(bad),
                ]), command: "workspace.write")
            }
        }
        // discardAfterCopy must be a strict boolean.
        #expect(throws: G04WorkspaceWireRequest.Failure.self) {
            _ = try G04WorkspaceWireRequest(payload: payload("forkDraft", [
                "documentID": .string(UUID().uuidString), "revision": .string("rev"),
                "discardAfterCopy": .integer(1),
            ]), command: "workspace.write")
        }
        // Read-family commands never carry write ops.
        #expect(throws: G04WorkspaceWireRequest.Failure.self) {
            _ = try G04WorkspaceWireRequest(payload: payload("forkDraft", [
                "documentID": .string(UUID().uuidString), "revision": .string("rev"),
            ]), command: "workspace.read")
        }
    }

    @Test func activationPayloadIsNativeEpochOnly() throws {
        let valid = try G04WorkspaceActivationRequest(payload: .object(["nativeEpoch": .string("27")]))
        #expect(valid.nativeEpoch == 27)
        for bad: SettingsDomainV1.JSONValue in [
            .integer(27),                                    // never a JSON number
            .string("027"), .string("27 "), .string("0"),   // canonical positive decimal only
        ] {
            #expect(throws: G04WorkspaceActivationRequest.Failure.self) {
                _ = try G04WorkspaceActivationRequest(payload: .object(["nativeEpoch": bad]))
            }
        }
        // Claimed identities/roots never ride activation.
        for extra in ["workspaceID", "rootPath", "runID", "taskID", "sourceURI"] {
            #expect(throws: G04WorkspaceActivationRequest.Failure.self) {
                _ = try G04WorkspaceActivationRequest(
                    payload: .object(["nativeEpoch": .string("27"), extra: .string("x")]))
            }
        }
        #expect(throws: G04WorkspaceActivationRequest.Failure.self) {
            _ = try G04WorkspaceActivationRequest(payload: .null)
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeAndroidCore

struct G04WorkspaceWireTests {
    private func payload(_ operation: String, _ fields: [String: SettingsDomainV1.JSONValue]) -> SettingsDomainV1.JSONValue {
        .object(fields.merging(["op": .string(operation), "workspaceID": .string(UUID().uuidString),
                                "nativeEpoch": .string("27")]) { original, _ in original })
    }

    @Test func ownerRootFieldsAndReadWriteConfusionAreRejectedBeforeAdmission() throws {
        #expect(throws: G04WorkspaceWireRequest.Failure.self) {
            _ = try G04WorkspaceWireRequest(payload: payload("delete", ["path": .string("file.txt")]), command: "workspace.read")
        }
        for field in ["rootPath", "sourceURI", "taskID", "runID", "environmentID", "permissionGranted"] {
            #expect(throws: G04WorkspaceWireRequest.Failure.self) {
                _ = try G04WorkspaceWireRequest(payload: payload("open", ["path": .string("file.txt"), field: .string("untrusted")]),
                                                command: "workspace.read")
            }
        }
        #expect(throws: G04WorkspaceWireRequest.Failure.self) {
            _ = try G04WorkspaceWireRequest(payload: payload("move", ["from": .string("source.txt")]), command: "workspace.write")
        }
        let valid = try G04WorkspaceWireRequest(payload: payload("move", ["from": .string("source.txt"), "to": .string("target.txt")]),
                                                command: "workspace.write")
        #expect(valid.operation == .move && valid.nativeEpoch == 27)
    }

    @Test func chunkBoundsAndStrictJSONTypesProtectTheByteChannel() throws {
        let handle = UUID().uuidString
        let offsets: [SettingsDomainV1.JSONValue] = [.boolean(true), .fractional(1.5), .integer(-1), .integer(Int64.max)]
        for offset in offsets {
            #expect(throws: G04WorkspaceWireRequest.Failure.self) {
                _ = try G04WorkspaceWireRequest(payload: payload("readContent", ["handle": .string(handle), "offset": offset,
                    "limit": .integer(24 * 1024)]), command: "workspace.read")
            }
        }
        let valid = try G04WorkspaceWireRequest(payload: payload("readContent", ["handle": .string(handle), "offset": .integer(0),
            "limit": .integer(24 * 1024)]), command: "workspace.read")
        #expect(try valid.integer("limit", maximum: 24 * 1024) == 24 * 1024)
        #expect(throws: G04WorkspaceWireRequest.Failure.self) {
            _ = try G04WorkspaceWireRequest(payload: payload("appendEditUpload", ["handle": .string(handle), "offset": .integer(0),
                "bytes": .string("not base64!")]), command: "workspace.write")
        }
        #expect(throws: G04WorkspaceWireRequest.Failure.self) {
            _ = try G04WorkspaceWireRequest(payload: payload("readContent", ["handle": .string(handle), "offset": .integer(0),
                "limit": .integer(24 * 1024 + 1)]), command: "workspace.read")
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
#if DEBUG
import Foundation
import FloeCAD
import FloeCore
import FloeModels

/// Synthetic qualification handoff only; this is data, never tool authority.
struct CADM30SelectionWitness: Codable, Sendable {
    var schema = 1
    var origin = "TEST-CREATED fixture; real History tap and host Save"
    var nonce: UUID
    var conversationID: UUID
    var workspaceID: UUID
    var documentName: String
    var descriptor: CADM30TargetDescriptor
    var revision: Int
    var changeCount: Int
    var contentSHA256: String
    var modelSHA256: String
    var documentJSONSHA256: String
    var selectionContextJSON: String
    var historyGeneration: UInt64
    var selectionAttachment: AttachmentRef? = nil

    static func directory(_ nonce: UUID) throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("FloeM30Selection/" + nonce.uuidString, isDirectory: true)
    }
    static func nonce() throws -> UUID {
        if let raw = ProcessInfo.processInfo.environment["FLOE_M30_NONCE"], let value = UUID(uuidString: raw) { return value }
        let url = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("FloeM30Selection/active-run.json")
        struct Policy: Decodable { var nonce: UUID }
        return try JSONDecoder().decode(Policy.self, from: Data(contentsOf: url)).nonce
    }
    static func read(target: CADM30TargetDescriptor.Target, nonce: UUID) throws -> Self {
        let data = try Data(contentsOf: directory(nonce).appendingPathComponent(target.rawValue + ".json"))
        guard data.count <= 128 * 1024 else { throw CADM30SelectedTargetFixture.fail("Oversize witness") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.nonce == nonce, value.descriptor.target == target,
              value.historyGeneration > 0, value.modelSHA256.count == 64,
              value.selectionAttachment?.conversationID == value.conversationID,
              value.documentName == "M30-\(target.rawValue).floecad" else { throw CADM30SelectedTargetFixture.fail("Witness identity mismatch") }
        return value
    }
}
#endif

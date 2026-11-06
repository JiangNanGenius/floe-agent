// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore
import FloeDiagramIntegration

extension DiagramExchange {
    public static func importLegacyNotesArchive(_ data: Data) throws -> DiagramImportResult {
        let entries = try DiagramZIP.unpack(data)
        guard let manifestData = entries["manifest.json"],
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              (1...2).contains(manifest["version"] as? Int ?? 1),
              let document = manifest["document"] as? [String: Any],
              let resources = manifest["resources"] as? [[String: Any]] else { throw DiagramError.invalid("legacy archive manifest") }
        var descriptors: [DiagramAsset] = [], bytesByID: [UUID: Data] = [:]
        let attachments = (document["nodes"] as? [[String: Any]] ?? []).flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
        let metadata = Dictionary(attachments.compactMap { a -> (String, [String: Any])? in
            guard let id = a["resourceID"] as? String else { return nil }; return (id, a)
        }, uniquingKeysWith: { a, _ in a })
        for resource in resources {
            guard let raw = resource["id"] as? String, let id = UUID(uuidString: raw),
                  let hash = resource["hash"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit),
                  let size = resource["size"] as? Int, let bytes = entries["resources/"+hash],
                  size == bytes.count, DiagramCodec.digest(bytes) == hash else { throw DiagramError.invalid("legacy archive resource integrity") }
            let detail = metadata[raw]
            let png = bytes.starts(with: Data([137,80,78,71])), jpeg = bytes.starts(with: Data([255,216]))
            let mediaType = detail?["mediaType"] as? String ?? (png ? "image/png" : jpeg ? "image/jpeg" : "application/octet-stream")
            descriptors.append(.init(id: id, fileName: detail?["fileName"] as? String ?? (id.uuidString+(png ? ".png" : jpeg ? ".jpg" : ".bin")), mediaType: mediaType, byteCount: bytes.count, sha256: hash))
            bytesByID[id] = bytes
        }
        let converted = try LegacyNotesBridge.importJSON(JSONSerialization.data(withJSONObject: document), assets: descriptors)
        var issues: [DiagramExchangeIssue] = []
        if !(manifest["linkedDocuments"] as? [[String: Any]] ?? []).isEmpty { issues.append(.init("linkedLegacyDocuments", "Linked documents remain separate files; this import converts the selected root mind map.")) }
        return .init(document: converted, assets: bytesByID, issues: issues)
    }
}

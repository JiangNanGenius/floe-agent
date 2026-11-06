import Foundation
import FloeCanvasCore

/// One authoritative record set per canvas, independent of optional templates.
/// Ordinary nodes carry purposes/references; shot order, timing and dialogue live here.
public enum CreativeRecords {
    public static let metadataKey = "floe.creative.records.v1"
    public static func read(_ snapshot: CanvasSnapshot) throws -> [CreativeRecord] {
        guard let raw = snapshot.metadata[metadataKey] else { return [] }
        return try JSONDecoder().decode([CreativeRecord].self, from: Data(raw.utf8))
    }
    public static func encode(_ records: [CreativeRecord]) throws -> String {
        String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    }
    public static func validate(_ records: [CreativeRecord], nodeIDs: Set<UUID>) throws {
        let ids = Set(records.map(\.id))
        guard ids.count == records.count,
              records.allSatisfy({ r in
                  r.nodeIDs.allSatisfy(nodeIDs.contains) && r.relatedRecordIDs.allSatisfy(ids.contains)
                    && (r.duration == nil || (r.duration!.isFinite && r.duration! >= 0))
              }) else { throw TemplateError.invalid("invalid creative record") }
    }
}

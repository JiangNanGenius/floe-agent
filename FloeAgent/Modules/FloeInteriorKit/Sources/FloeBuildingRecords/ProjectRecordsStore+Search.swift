import Foundation
import GRDB

public enum RecordSearchKind: String, Codable, Sendable {
    case room
    case source
    case observation
    case bomItem = "bom_item"
}

public enum RecordReference: Codable, Sendable, Hashable {
    case room(RoomID)
    case source(SourceID)
    case observation(ObservationID)
    case bomItem(BOMItemID)

    public var kind: RecordSearchKind {
        switch self {
        case .room: return .room
        case .source: return .source
        case .observation: return .observation
        case .bomItem: return .bomItem
        }
    }

    public var stableID: String {
        switch self {
        case .room(let id): return "room:\(id.databaseValue)"
        case .source(let id): return "source:\(id.databaseValue)"
        case .observation(let id): return "observation:\(id.databaseValue)"
        case .bomItem(let id): return "bom_item:\(id.databaseValue)"
        }
    }
}

public struct RecordSearchHit: Codable, Sendable, Hashable, Identifiable {
    public let reference: RecordReference
    public let title: String
    public let detail: String

    public var id: String { reference.stableID }

    public init(reference: RecordReference, title: String, detail: String) {
        self.reference = reference
        self.title = title
        self.detail = detail
    }
}

extension ProjectRecordsStore {
    /// Substring search across room names/aliases, source titles and latest
    /// original names, observations and BOM items. The query is bounded and
    /// paginated; imported content cannot supply SQL or paths.
    public func search(
        _ query: String,
        limit: Int = 20,
        offset: Int = 0
    ) throws -> [RecordSearchHit] {
        guard limit > 0, limit <= limits.maxSearchLimit else {
            throw BuildingRecordsError.invalidValue(
                field: "search.limit",
                reason: "must be 1...\(limits.maxSearchLimit)"
            )
        }
        guard offset >= 0, offset <= limits.maxSearchOffset else {
            throw BuildingRecordsError.invalidValue(
                field: "search.offset",
                reason: "must be 0...\(limits.maxSearchOffset)"
            )
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        guard needle.count <= 200 else {
            throw BuildingRecordsError.invalidValue(field: "search.query", reason: "must be at most 200 characters")
        }
        let scan = limit + offset
        return try database.read { db in
            var hits: [RecordSearchHit] = []
            hits.append(contentsOf: try searchRooms(db, needle: needle, scan: scan))
            hits.append(contentsOf: try searchSources(db, needle: needle, scan: scan))
            hits.append(contentsOf: try searchObservations(db, needle: needle, scan: scan))
            hits.append(contentsOf: try searchBOMItems(db, needle: needle, scan: scan))
            hits.sort { lhs, rhs in
                if lhs.reference.kind.sortRank != rhs.reference.kind.sortRank {
                    return lhs.reference.kind.sortRank < rhs.reference.kind.sortRank
                }
                if lhs.title.lowercased() != rhs.title.lowercased() {
                    return lhs.title.lowercased() < rhs.title.lowercased()
                }
                return lhs.id < rhs.id
            }
            return Array(hits.dropFirst(offset).prefix(limit))
        }
    }

    private func searchRooms(_ db: Database, needle: String, scan: Int) throws -> [RecordSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.id, r.name, r.storey, r.kind
                FROM room r
                WHERE r.project_id = ?
                    AND (
                        instr(lower(r.name), lower(?)) > 0
                        OR instr(lower(COALESCE(r.storey, '')), lower(?)) > 0
                        OR instr(lower(r.notes), lower(?)) > 0
                        OR EXISTS (
                            SELECT 1 FROM room_alias a
                            WHERE a.room_id = r.id AND instr(lower(a.alias), lower(?)) > 0
                        )
                    )
                ORDER BY r.updated_at DESC, r.id
                LIMIT ?
                """,
            arguments: [projectID.databaseValue, needle, needle, needle, needle, scan]
        )
        return try rows.map { row in
            let id: RoomID = try row.recordID("id")
            let name: String = row["name"]
            let storey: String? = row["storey"]
            let kind: RoomKind = try row.requiredEnum("kind", as: RoomKind.self)
            var detail = kind.rawValue
            if let storey, !storey.isEmpty {
                detail = "\(storey) · \(detail)"
            }
            return RecordSearchHit(reference: .room(id), title: name, detail: detail)
        }
    }

    private func searchSources(_ db: Database, needle: String, scan: Int) throws -> [RecordSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.id, s.title, s.kind,
                    (SELECT v.original_name FROM source_version v
                        WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_original_name,
                    (SELECT v.note FROM source_version v
                        WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_note
                FROM source s
                WHERE s.project_id = ?
                    AND (
                        instr(lower(s.title), lower(?)) > 0
                        OR EXISTS (
                            SELECT 1 FROM source_version v
                            WHERE v.source_id = s.id
                                AND instr(lower(v.original_name), lower(?)) > 0
                        )
                        OR EXISTS (
                            SELECT 1 FROM source_version v
                            WHERE v.source_id = s.id
                                AND instr(lower(v.note), lower(?)) > 0
                        )
                    )
                ORDER BY s.updated_at DESC, s.id
                LIMIT ?
                """,
            arguments: [projectID.databaseValue, needle, needle, needle, scan]
        )
        return try rows.map { row in
            let id: SourceID = try row.recordID("id")
            let title: String = row["title"]
            let kind: SourceKind = try row.requiredEnum("kind", as: SourceKind.self)
            let originalName: String? = row["latest_original_name"]
            let detail = [kind.rawValue, originalName].compactMap { $0 }.joined(separator: " · ")
            return RecordSearchHit(reference: .source(id), title: title, detail: detail)
        }
    }

    private func searchObservations(_ db: Database, needle: String, scan: Int) throws -> [RecordSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT o.id, o.property_key, o.raw_value, o.note, r.name AS room_name
                FROM observation o
                JOIN room r ON r.id = o.room_id
                WHERE o.project_id = ?
                    AND (
                        instr(lower(o.property_key), lower(?)) > 0
                        OR instr(lower(o.raw_value), lower(?)) > 0
                        OR instr(lower(o.note), lower(?)) > 0
                        OR instr(lower(r.name), lower(?)) > 0
                    )
                ORDER BY o.created_at DESC, o.id
                LIMIT ?
                """,
            arguments: [projectID.databaseValue, needle, needle, needle, needle, scan]
        )
        return try rows.map { row in
            let id: ObservationID = try row.recordID("id")
            let propertyKey: String = row["property_key"]
            let rawValue: String = row["raw_value"]
            let roomName: String = row["room_name"]
            let rawPreview = rawValue.count > 120 ? String(rawValue.prefix(120)) : rawValue
            return RecordSearchHit(
                reference: .observation(id),
                title: "\(roomName) · \(propertyKey)",
                detail: rawPreview
            )
        }
    }

    private func searchBOMItems(_ db: Database, needle: String, scan: Int) throws -> [RecordSearchHit] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT i.id, i.role, i.brand, i.raw_model, i.product_name, i.order_code,
                    i.notes, i.raw_unit, r.name AS room_name
                FROM bom_item i
                LEFT JOIN room r ON r.id = i.room_id
                WHERE i.project_id = ?
                    AND (
                        instr(lower(COALESCE(i.brand, '')), lower(?)) > 0
                        OR instr(lower(COALESCE(i.raw_model, '')), lower(?)) > 0
                        OR instr(lower(COALESCE(i.product_name, '')), lower(?)) > 0
                        OR instr(lower(COALESCE(i.order_code, '')), lower(?)) > 0
                        OR instr(lower(i.notes), lower(?)) > 0
                        OR instr(lower(COALESCE(r.name, '')), lower(?)) > 0
                    )
                ORDER BY i.updated_at DESC, i.id
                LIMIT ?
                """,
            arguments: [projectID.databaseValue, needle, needle, needle, needle, needle, needle, scan]
        )
        return try rows.map { row in
            let id: BOMItemID = try row.recordID("id")
            let role: BOMRole = try row.requiredEnum("role", as: BOMRole.self)
            let brand: String? = row["brand"]
            let model: String? = row["raw_model"]
            let productName: String? = row["product_name"]
            let orderCode: String? = row["order_code"]
            let roomName: String? = row["room_name"]
            let title = [brand, model, productName, orderCode].compactMap { $0 }.first ?? "BOM item"
            let detail = [role.rawValue, roomName].compactMap { $0 }.joined(separator: " · ")
            return RecordSearchHit(reference: .bomItem(id), title: title, detail: detail)
        }
    }
}

extension RecordSearchKind {
    var sortRank: Int {
        switch self {
        case .room: return 0
        case .source: return 1
        case .observation: return 2
        case .bomItem: return 3
        }
    }
}

import Foundation
import GRDB
import FloeCore

public struct CanvasRunContextSeed: Sendable, Codable, Hashable {
    public var canvasID: UUID
    public var documentID: UUID?
    public var selectedNodeIDs: [UUID]
    public var projectRevision: Int64

    public init(
        canvasID: UUID,
        documentID: UUID?,
        selectedNodeIDs: [UUID],
        projectRevision: Int64
    ) {
        self.canvasID = canvasID
        self.documentID = documentID
        self.selectedNodeIDs = selectedNodeIDs
        self.projectRevision = projectRevision
    }
}

public struct CanvasRunContext: Sendable, Codable, Hashable {
    public var runID: UUID
    public var conversationID: UUID
    public var canvasID: UUID
    public var documentID: UUID?
    public var selectedNodeIDs: [UUID]
    public var projectRevision: Int64
    public var createdAt: Date

    public init(
        runID: UUID,
        conversationID: UUID,
        canvasID: UUID,
        documentID: UUID?,
        selectedNodeIDs: [UUID],
        projectRevision: Int64,
        createdAt: Date = Date()
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.canvasID = canvasID
        self.documentID = documentID
        self.selectedNodeIDs = selectedNodeIDs
        self.projectRevision = projectRevision
        self.createdAt = createdAt
    }
}

public actor CanvasRunContextStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func save(_ context: CanvasRunContext) async throws {
        let selectedJSON = String(
            data: try JSONEncoder().encode(context.selectedNodeIDs),
            encoding: .utf8
        ) ?? "[]"
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO canvas_run_contexts (
                    run_id, conversation_id, canvas_id, document_id,
                    selected_node_ids_json, project_revision, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    conversation_id = excluded.conversation_id,
                    canvas_id = excluded.canvas_id,
                    document_id = excluded.document_id,
                    selected_node_ids_json = excluded.selected_node_ids_json,
                    project_revision = excluded.project_revision
                """, arguments: [
                    context.runID.uuidString,
                    context.conversationID.uuidString,
                    context.canvasID.uuidString,
                    context.documentID?.uuidString,
                    selectedJSON,
                    context.projectRevision,
                    PersistenceCodec.encode(context.createdAt)
                ])
        }
    }

    public func context(runID: UUID) async throws -> CanvasRunContext? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM canvas_run_contexts WHERE run_id = ?",
                arguments: [runID.uuidString]
            ),
            let conversationID = UUID(uuidString: row["conversation_id"]),
            let canvasID = UUID(uuidString: row["canvas_id"]) else { return nil }
            let data = Data((row["selected_node_ids_json"] as String).utf8)
            return CanvasRunContext(
                runID: runID,
                conversationID: conversationID,
                canvasID: canvasID,
                documentID: (row["document_id"] as String?).flatMap(UUID.init(uuidString:)),
                selectedNodeIDs: (try? JSONDecoder().decode([UUID].self, from: data)) ?? [],
                projectRevision: row["project_revision"],
                createdAt: try PersistenceCodec.decodeDate(row["created_at"])
            )
        }
    }
}

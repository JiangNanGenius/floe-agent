import GRDB

/// Adds Canvas-specific assistant and visual-understanding overrides. Nil
/// deliberately means "inherit the existing global route".
enum V28CanvasModelRouting {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v28") { db in
            try db.alter(table: "model_preferences") { table in
                table.add(column: "canvas_agent_model_id", .text)
                    .references("models", onDelete: .setNull)
                table.add(column: "canvas_vision_model_id", .text)
                    .references("models", onDelete: .setNull)
            }
            try db.execute(sql: "PRAGMA user_version = 28")
        }
    }
}

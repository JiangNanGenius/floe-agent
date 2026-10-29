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

/// Adds explicit product-surface routing so media endpoints can never leak
/// into the primary LLM picker merely because their transport is text-shaped.
enum V29ModelUseSurfaces {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v29") { db in
            try db.alter(table: "models") { table in
                table.add(column: "use_surfaces", .integer)
            }
            try db.execute(sql: "PRAGMA user_version = 29")
        }
    }
}

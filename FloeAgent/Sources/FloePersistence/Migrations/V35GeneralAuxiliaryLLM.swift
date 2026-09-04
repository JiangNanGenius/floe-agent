import GRDB

enum V35GeneralAuxiliaryLLM {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v35") { db in
            try db.alter(table: "model_preferences") { table in
                table.add(column: "general_auxiliary_llm_model_id", .text)
                    .references("models", onDelete: .setNull)
            }
            try db.execute(sql: "PRAGMA user_version = 35")
        }
    }
}

import GRDB

/// Persists the model's advisory Plan scale recommendation and the user's
/// explicit durable Goal boundaries. Existing plans default to ordinary
/// execution; existing goals retain their current behavior.
enum V14PlanGoalControls {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14") { db in
            try db.execute(sql: """
                ALTER TABLE plan_drafts ADD COLUMN execution_recommendation TEXT;
                ALTER TABLE plan_drafts ADD COLUMN recommendation_reason TEXT;
                ALTER TABLE conversation_goals ADD COLUMN blocking_conditions_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE conversation_goals ADD COLUMN stopping_conditions_json TEXT NOT NULL DEFAULT '[]';
                ALTER TABLE conversation_goals ADD COLUMN revision INTEGER NOT NULL DEFAULT 1;
                PRAGMA user_version = 14;
                """)
        }
    }
}

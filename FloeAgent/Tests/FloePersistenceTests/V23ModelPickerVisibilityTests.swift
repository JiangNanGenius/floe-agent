import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("V23 model picker visibility migration")
struct V23ModelPickerVisibilityTests {
    @Test("Existing models remain visible by default")
    func legacyRowsRemainVisible() throws {
        let queue = try DatabaseQueue()
        var throughV22 = DatabaseMigrator()
        V1Initial.register(into: &throughV22)
        V2ConfigSync.register(into: &throughV22)
        V3AgentDaily.register(into: &throughV22)
        V4ModelPreferences.register(into: &throughV22)
        V5Workspace.register(into: &throughV22)
        V6AppSettings.register(into: &throughV22)
        V7WorkbenchIntelligence.register(into: &throughV22)
        V8TaskOwnership.register(into: &throughV22)
        V9HarnessAndPermissions.register(into: &throughV22)
        V10ConversationContinuity.register(into: &throughV22)
        V11ArchiveCredentials.register(into: &throughV22)
        V12RunningInputs.register(into: &throughV22)
        V13PersonalizationMemory.register(into: &throughV22)
        V14PlanGoalControls.register(into: &throughV22)
        V15ProviderDisplayName.register(into: &throughV22)
        V16ProviderCompatibilityAndPackageReview.register(into: &throughV22)
        V17ModelReasoningEffort.register(into: &throughV22)
        V18RunUsageDimensions.register(into: &throughV22)
        V19DetailedRunUsage.register(into: &throughV22)
        V20RunResponseTiming.register(into: &throughV22)
        V21MemoryLifecycle.register(into: &throughV22)
        V22RemoteDevices.register(into: &throughV22)
        try throughV22.migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO providers (
                    id, kind, wire_protocol, base_url, non_secret_headers_json,
                    is_enabled, allows_plain_http, tool_name_compatibility,
                    created_at, updated_at, sync_revision
                ) VALUES ('p', 'custom', 'openAIChatCompletions', 'https://example.com',
                    '{}', 1, 0, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 0);
                INSERT INTO models (
                    id, provider_id, remote_model_id, display_name,
                    context_tokens, max_output_tokens, capabilities, is_enabled
                ) VALUES ('m', 'p', 'legacy', 'Legacy', 8192, 1024, 1, 1);
                """)
        }

        var v23 = DatabaseMigrator()
        V23ModelPickerVisibility.register(into: &v23)
        try v23.migrate(queue)

        let hidden: Bool = try queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT is_hidden_from_primary_picker FROM models WHERE id = 'm'") ?? true
        }
        #expect(!hidden)
    }
}

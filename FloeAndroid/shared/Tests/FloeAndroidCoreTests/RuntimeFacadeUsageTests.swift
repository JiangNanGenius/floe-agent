// SPDX-License-Identifier: MPL-2.0
//
// Authored host tests for the P5 global-usage adapter. SOURCE ONLY: no
// compiler, SwiftPM, XCTest, device or runtime execution was performed by the
// authoring job. The tests use the ORIGINAL file-backed DatabaseManager /
// migrations and keep SQLiteRunStore.usageStatistics() as the equivalence
// reference. They assert adapter pages == the original struct projection on
// unchanged bounded fixtures; live concurrent drift is explicitly allowed by
// the frozen contract and is not asserted as an immutable inventory.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

private func usageFixtureUUID(_ prefix: Int, _ index: Int) -> String {
    String(format: "%08x-0000-0000-0000-%012x",
           UInt32(prefix), UInt32(index))
}

// MARK: - Original-schema inserts

private func insertUsageProvider(_ db: Database,
                                   id: String,
                                   name: String) throws {
    try db.execute(
        sql: """
            INSERT INTO providers (
                id, kind, wire_protocol, base_url, secret_ref_account,
                secret_ref_synchronizable, region, non_secret_headers_json,
                is_enabled, allows_plain_http, created_at, updated_at,
                sync_revision, display_name, tool_name_compatibility
            ) VALUES (
                ?, 'openai', 'openAIChatCompletions',
                'https://example.invalid', NULL, NULL, NULL, '{}',
                1, 0, ?, ?, 0, ?, 0
            )
            """,
        arguments: [id, "2026-10-01T00:00:00.000Z",
                    "2026-10-01T00:00:00.000Z", name]
    )
}

private func insertUsageModel(_ db: Database,
                                id: String,
                                providerID: String,
                                name: String) throws {
    try db.execute(
        sql: """
            INSERT INTO models (
                id, provider_id, remote_model_id, display_name,
                context_tokens, max_output_tokens, pricing_json,
                capabilities, is_enabled, reasoning_effort,
                explicit_capabilities
            ) VALUES (?, ?, ?, ?, 128000, 8192, NULL, 1, 1, NULL, NULL)
            """,
        arguments: [id, providerID, "remote-\(id)", name]
    )
}

private func insertUsageConversation(_ db: Database,
                                       id: String,
                                       title: String) throws {
    try db.execute(
        sql: """
            INSERT INTO conversations (
                id, title, created_at, updated_at, title_origin,
                mode, is_searchable, archived_at, purpose
            ) VALUES (?, ?, ?, ?, 'manual', 'chat', 1, NULL, 'ordinary')
            """,
        arguments: [id, title, "2026-10-01T00:00:00.000Z",
                    "2026-10-01T00:00:00.000Z"]
    )
}

private func insertUsageRun(_ db: Database,
                              id: String,
                              conversationID: String,
                              providerID: String?,
                              modelID: String?,
                              providerName: String?,
                              modelName: String?,
                              startedAt: String = "2026-10-01T00:00:00.000Z")
    throws {
    try db.execute(
        sql: """
            INSERT INTO runs (
                id, conversation_id, state, goal, started_at, ended_at,
                goal_id, provider_id, model_id, provider_name_snapshot,
                model_name_snapshot, conversation_mode
            ) VALUES (?, ?, 'completed', '', ?, ?, NULL, ?, ?, ?, ?, 'chat')
            """,
        arguments: [id, conversationID, startedAt,
                    "2026-10-01T00:01:00.000Z", providerID, modelID,
                    providerName, modelName]
    )
}

private func insertUsageRow(_ db: Database,
                                id: String,
                                runID: String,
                                input: Int,
                                output: Int,
                                cacheRead: Int? = nil,
                                cacheWrite: Int? = nil,
                                reasoning: Int? = nil,
                                tokensPerSecond: Double? = nil,
                                timeToFirstTokenMs: Int? = nil,
                                durationMs: Int? = nil,
                                recordedAt: String,
                                costEstimate: String? = nil,
                                isEstimated: Bool = false) throws {
    try db.execute(
        sql: """
            INSERT INTO run_usage (
                id, run_id, input_tokens, output_tokens, cost_estimate,
                recorded_at, cache_read_tokens, cache_write_tokens,
                reasoning_tokens, is_estimated, total_duration_ms,
                time_to_first_token_ms, tokens_per_second
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [id, runID, input, output, costEstimate, recordedAt,
                    cacheRead, cacheWrite, reasoning, isEstimated ? 1 : 0,
                    durationMs, timeToFirstTokenMs, tokensPerSecond]
    )
}

final class UsageStatisticsAdapterTests: XCTestCase {
    // MARK: - File-backed original database

    private func makeDatabase() async throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-usage-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return (manager, url)
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix)
            )
        }
    }

    // MARK: - Adapter page collection

    private func collect(_ adapter: FacadeUsageAdapter,
                         dimension: SettingsDomainV1.UsageDimension,
                         limit: Int) async throws -> [SettingsDomainV1.UsageBreakdown] {
        var cursor: String?
        var result: [SettingsDomainV1.UsageBreakdown] = []
        var iterations = 0
        repeat {
            let page = try await adapter.page(
                UsageStatisticsRequest(dimension: dimension,
                                       cursor: cursor,
                                       limit: limit)
            )
            result.append(contentsOf: page.rows ?? [])
            cursor = page.nextCursor
            iterations += 1
            if iterations > 10_000 {
                XCTFail("pagination did not terminate")
                break
            }
        } while cursor != nil
        return result
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func parseReason(_ payload: SettingsDomainV1.JSONValue?) -> String? {
        do {
            _ = try UsageStatisticsRequest.parse(payload)
            return nil
        } catch let error as UsageStatisticsAdapterError {
            return error.wireReason
        } catch {
            return "unexpected"
        }
    }

    // MARK: - Empty / original equivalence

    func testEmptyDatabaseMatchesOriginalZerosAndNulls() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeUsageAdapter(database: manager)
        let total = try await adapter.page()

        XCTAssertEqual(total.totals.inputTokens, 0)
        XCTAssertEqual(total.totals.outputTokens, 0)
        XCTAssertEqual(total.totals.totalTokens, 0)
        XCTAssertEqual(total.totals.runs, 0)
        XCTAssertNil(total.totals.cacheReadTokens)
        XCTAssertNil(total.totals.cacheWriteTokens)
        XCTAssertNil(total.totals.reasoningTokens)
        XCTAssertNil(total.totals.averageTokensPerSecond)
        XCTAssertNil(total.totals.averageTimeToFirstTokenMs)
        XCTAssertNil(total.totals.averageDurationMs)
        XCTAssertEqual(total.byDay?.count ?? -1, 0)
        XCTAssertNil(total.rows)
        XCTAssertNil(total.nextCursor)

        for dimension: SettingsDomainV1.UsageDimension in
            [.conversation, .model, .provider] {
            let page = try await adapter.page(
                UsageStatisticsRequest(dimension: dimension)
            )
            XCTAssertEqual(page.rows?.count ?? -1, 0)
            XCTAssertNil(page.byDay)
            XCTAssertNil(page.nextCursor)
            XCTAssertEqual(page.totals, total.totals)
        }
    }

    func testTotalsByDayAndBreakdownsMatchOriginalStore() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }

        let provider1 = usageFixtureUUID(0x10000000, 1)
        let provider2 = usageFixtureUUID(0x10000000, 2)
        let model1 = usageFixtureUUID(0x20000000, 1)
        let model2 = usageFixtureUUID(0x20000000, 2)
        let model3 = usageFixtureUUID(0x20000000, 3)
        let conversation1 = usageFixtureUUID(0x30000000, 1)
        let conversation2 = usageFixtureUUID(0x30000000, 2)
        let conversation3 = usageFixtureUUID(0x30000000, 3)
        let run1 = usageFixtureUUID(0x40000000, 1)
        let run2 = usageFixtureUUID(0x40000000, 2)
        let run3 = usageFixtureUUID(0x40000000, 3)
        let run4 = usageFixtureUUID(0x40000000, 4)

        try await manager.writer { db in
            try insertUsageProvider(db, id: provider1, name: "Provider One")
            try insertUsageProvider(db, id: provider2, name: "Provider Two")
            try insertUsageModel(db, id: model1, providerID: provider1,
                                 name: "Model One")
            try insertUsageModel(db, id: model2, providerID: provider1,
                                 name: "Model Two")
            try insertUsageModel(db, id: model3, providerID: provider2,
                                 name: "Model Three")
            try insertUsageConversation(db, id: conversation1, title: "Alpha")
            try insertUsageConversation(db, id: conversation2, title: "Beta")
            try insertUsageConversation(db, id: conversation3, title: "Gamma")
            try insertUsageRun(db, id: run1, conversationID: conversation1,
                               providerID: provider1, modelID: model1,
                               providerName: "Provider One",
                               modelName: "Model One")
            try insertUsageRun(db, id: run2, conversationID: conversation2,
                               providerID: provider1, modelID: model2,
                               providerName: "Provider One",
                               modelName: "Model Two")
            try insertUsageRun(db, id: run3, conversationID: conversation3,
                               providerID: provider2, modelID: model3,
                               providerName: "Provider Two",
                               modelName: "Model Three")
            try insertUsageRun(db, id: run4, conversationID: conversation1,
                               providerID: provider1, modelID: model1,
                               providerName: "Provider One",
                               modelName: "Model One")

            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 1), runID: run1,
                input: 100, output: 50, cacheRead: 10, cacheWrite: 5,
                reasoning: 20, tokensPerSecond: 12.5,
                timeToFirstTokenMs: 250, durationMs: 4_000,
                recordedAt: "2026-10-18T23:59:59.999Z",
                costEstimate: "0.01"
            )
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 2), runID: run1,
                input: 20, output: 10, cacheRead: nil, cacheWrite: 2,
                reasoning: nil, tokensPerSecond: nil,
                timeToFirstTokenMs: nil, durationMs: 1_000,
                recordedAt: "2026-10-18T23:59:59.999Z",
                costEstimate: "0.02"
            )
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 3), runID: run2,
                input: 0, output: 0,
                recordedAt: "2026-10-19T00:00:00.000Z",
                isEstimated: true
            )
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 4), runID: run3,
                input: 300, output: 200, cacheRead: 30, cacheWrite: nil,
                reasoning: 40, tokensPerSecond: 20.0,
                timeToFirstTokenMs: 100, durationMs: 2_000,
                recordedAt: "2026-10-17T23:30:00.000+08:00",
                costEstimate: "9.99"
            )
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 5), runID: run4,
                input: 7, output: 3,
                recordedAt: "2026-10-18T00:00:00.000Z"
            )
        }

        let originalStore = SQLiteRunStore(database: manager)
        let original = try await originalStore.usageStatistics()
        let adapter = FacadeUsageAdapter(database: manager)
        let total = try await adapter.page()

        XCTAssertEqual(total.totals.inputTokens, original.totalInputTokens)
        XCTAssertEqual(total.totals.outputTokens, original.totalOutputTokens)
        XCTAssertEqual(total.totals.totalTokens, original.totalTokens)
        XCTAssertEqual(total.totals.runs, original.totalRuns)
        XCTAssertEqual(total.totals.cacheReadTokens, original.cacheReadTokens)
        XCTAssertEqual(total.totals.cacheWriteTokens, original.cacheWriteTokens)
        XCTAssertEqual(total.totals.reasoningTokens, original.reasoningTokens)
        XCTAssertEqual(total.totals.averageTokensPerSecond,
                       original.averageTokensPerSecond)
        XCTAssertEqual(total.totals.averageTimeToFirstTokenMs,
                       original.averageTimeToFirstTokenMs)
        XCTAssertEqual(total.totals.averageDurationMs,
                       original.averageDurationMs)

        let days = try XCTUnwrap(total.byDay)
        XCTAssertEqual(days.count, original.byDay.count)
        for (lhs, rhs) in zip(days, original.byDay) {
            XCTAssertEqual(lhs.date, rhs.date)
            XCTAssertEqual(lhs.inputTokens, rhs.inputTokens)
            XCTAssertEqual(lhs.outputTokens, rhs.outputTokens)
            XCTAssertEqual(lhs.cacheReadTokens, rhs.cacheReadTokens)
            XCTAssertEqual(lhs.cacheWriteTokens, rhs.cacheWriteTokens)
            XCTAssertEqual(lhs.runs, rhs.runs)
            XCTAssertEqual(lhs.totalTokens, rhs.totalTokens)
        }

        for dimension: SettingsDomainV1.UsageDimension in
            [.conversation, .model, .provider] {
            let rows = try await collect(adapter, dimension: dimension, limit: 2)
            let expected: [FloePersistence.UsageBreakdown]
            switch dimension {
            case .conversation:
                expected = original.byConversation
            case .model:
                expected = original.byModel
            case .provider:
                expected = original.byProvider
            case .total:
                expected = []
            }
            XCTAssertEqual(rows.count, expected.count)
            for (lhs, rhs) in zip(rows, expected) {
                XCTAssertEqual(lhs.id, rhs.id)
                XCTAssertEqual(lhs.label, rhs.label)
                XCTAssertEqual(lhs.inputTokens, rhs.inputTokens)
                XCTAssertEqual(lhs.outputTokens, rhs.outputTokens)
                XCTAssertEqual(lhs.runs, rhs.runs)
                XCTAssertEqual(lhs.cacheReadTokens, rhs.cacheReadTokens)
                XCTAssertEqual(lhs.cacheWriteTokens, rhs.cacheWriteTokens)
                XCTAssertEqual(lhs.reasoningTokens, rhs.reasoningTokens)
                XCTAssertEqual(lhs.averageTokensPerSecond,
                               rhs.averageTokensPerSecond)
                XCTAssertEqual(lhs.averageTimeToFirstTokenMs,
                               rhs.averageTimeToFirstTokenMs)
                XCTAssertEqual(lhs.averageDurationMs, rhs.averageDurationMs)
                XCTAssertEqual(lhs.totalTokens, rhs.totalTokens)
            }
        }
    }

    func testNullMetricsEncodeAsExplicitNullNeverZero() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let provider = usageFixtureUUID(0x10000000, 9)
        let model = usageFixtureUUID(0x20000000, 9)
        let conversation = usageFixtureUUID(0x30000000, 9)
        let run = usageFixtureUUID(0x40000000, 9)
        try await manager.writer { db in
            try insertUsageProvider(db, id: provider, name: "P")
            try insertUsageModel(db, id: model, providerID: provider, name: "M")
            try insertUsageConversation(db, id: conversation, title: "Nulls")
            try insertUsageRun(db, id: run, conversationID: conversation,
                               providerID: provider, modelID: model,
                               providerName: "P", modelName: "M")
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 9), runID: run,
                input: 0, output: 0, cacheRead: nil, cacheWrite: nil,
                reasoning: nil, tokensPerSecond: nil,
                timeToFirstTokenMs: nil, durationMs: nil,
                recordedAt: "2026-10-19T00:00:00.000Z"
            )
        }
        let adapter = FacadeUsageAdapter(database: manager)
        let total = try await adapter.page()
        let totalsObject = try jsonObject(total.totals)
        for key in ["cacheReadTokens", "cacheWriteTokens", "reasoningTokens",
                    "averageTokensPerSecond", "averageTimeToFirstTokenMs",
                    "averageDurationMs"] {
            XCTAssertNotNil(totalsObject[key] as? NSNull,
                            "\(key) must be JSON null, not 0")
        }

        let conversationPage = try await adapter.page(
            UsageStatisticsRequest(dimension: .conversation)
        )
        let rows = try XCTUnwrap(conversationPage.rows)
        XCTAssertEqual(rows.count, 1)
        let rowObject = try jsonObject(rows[0])
        for key in ["cacheReadTokens", "cacheWriteTokens", "reasoningTokens",
                    "averageTokensPerSecond", "averageTimeToFirstTokenMs",
                    "averageDurationMs"] {
            XCTAssertNotNil(rowObject[key] as? NSNull,
                            "\(key) must be JSON null, not 0")
        }
    }

    func testLegacyFallbacksAndEmptyLabelsUseOriginalRule() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let conversation = usageFixtureUUID(0x30000000, 10)
        let run = usageFixtureUUID(0x40000000, 10)
        try await manager.writer { db in
            try insertUsageConversation(db, id: conversation, title: "")
            try insertUsageRun(db, id: run, conversationID: conversation,
                               providerID: nil, modelID: nil,
                               providerName: nil, modelName: nil)
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 10), runID: run,
                input: 1, output: 2,
                recordedAt: "2026-10-19T00:00:00.000Z"
            )
        }
        let adapter = FacadeUsageAdapter(database: manager)
        let legacyLabel = FloeL10n.l("persistence.run_store.legacy_usage_label")
        let conversationRows = try await collect(adapter, dimension: .conversation,
                                                 limit: 50)
        XCTAssertEqual(conversationRows.count, 1)
        XCTAssertEqual(conversationRows[0].label, legacyLabel)

        let modelRows = try await collect(adapter, dimension: .model, limit: 50)
        XCTAssertEqual(modelRows.count, 1)
        XCTAssertEqual(modelRows[0].id, "legacy-model")
        XCTAssertEqual(modelRows[0].label, legacyLabel)

        let providerRows = try await collect(adapter, dimension: .provider,
                                             limit: 50)
        XCTAssertEqual(providerRows.count, 1)
        XCTAssertEqual(providerRows[0].id, "legacy-provider")
        XCTAssertEqual(providerRows[0].label, legacyLabel)
    }

    func testByDayLimitAndTimezoneBoundariesMatchOriginal() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let provider = usageFixtureUUID(0x10000000, 11)
        let model = usageFixtureUUID(0x20000000, 11)
        let conversation = usageFixtureUUID(0x30000000, 11)
        let run = usageFixtureUUID(0x40000000, 11)
        let days: [String] = (1...30).map {
            String(format: "2026-09-%02d", $0)
        } + ["2026-10-01", "2026-10-02", "2026-10-03"]
        try await manager.writer { db in
            try insertUsageProvider(db, id: provider, name: "P")
            try insertUsageModel(db, id: model, providerID: provider, name: "M")
            try insertUsageConversation(db, id: conversation, title: "Days")
            try insertUsageRun(db, id: run, conversationID: conversation,
                               providerID: provider, modelID: model,
                               providerName: "P", modelName: "M")
            for (index, day) in days.enumerated() {
                try insertUsageRow(
                    db, id: usageFixtureUUID(0x50000000, 100 + index), runID: run,
                    input: index + 1, output: 1,
                    recordedAt: "\(day)T12:00:00.000Z"
                )
            }
            // SQLite date() normalizes an offset timestamp to UTC.
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 200), runID: run,
                input: 1000, output: 0,
                recordedAt: "2026-10-04T01:00:00.000+08:00"
            )
        }
        let originalStore = SQLiteRunStore(database: manager)
        let original = try await originalStore.usageStatistics()
        let adapter = FacadeUsageAdapter(database: manager)
        let page = try await adapter.page()
        let daysOut = try XCTUnwrap(page.byDay)
        XCTAssertEqual(daysOut.count, 30)
        XCTAssertEqual(daysOut.count, original.byDay.count)
        for (lhs, rhs) in zip(daysOut, original.byDay) {
            XCTAssertEqual(lhs.date, rhs.date)
            XCTAssertEqual(lhs.inputTokens, rhs.inputTokens)
            XCTAssertEqual(lhs.runs, rhs.runs)
            XCTAssertEqual(lhs.totalTokens, rhs.totalTokens)
        }
        XCTAssertFalse(daysOut.contains { $0.date == "2026-08-31" })
    }

    // MARK: - Bounded paging / 48KiB budget

    func testLargeCJKLabelsStopAtBudgetWithoutTruncation() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let provider = usageFixtureUUID(0x10000000, 12)
        let model = usageFixtureUUID(0x20000000, 12)
        let count = 120
        try await manager.writer { db in
            try insertUsageProvider(db, id: provider, name: "P")
            try insertUsageModel(db, id: model, providerID: provider, name: "M")
            for index in 0..<count {
                let conversation = usageFixtureUUID(0x30000000, 300 + index)
                let run = usageFixtureUUID(0x40000000, 300 + index)
                let label = String(format: "%03d", index)
                    + String(repeating: "记", count: 297)
                try insertUsageConversation(db, id: conversation, title: label)
                try insertUsageRun(db, id: run, conversationID: conversation,
                                   providerID: provider, modelID: model,
                                   providerName: "P", modelName: "M")
                try insertUsageRow(
                    db, id: usageFixtureUUID(0x50000000, 300 + index), runID: run,
                    input: index + 1, output: 0,
                    recordedAt: "2026-10-19T00:00:00.000Z"
                )
            }
        }
        let adapter = FacadeUsageAdapter(database: manager)
        var cursor: String?
        var all: [SettingsDomainV1.UsageBreakdown] = []
        var pageSizes: [Int] = []
        var iterations = 0
        repeat {
            let page = try await adapter.page(
                UsageStatisticsRequest(dimension: .conversation,
                                       cursor: cursor, limit: 100)
            )
            let encoded = try JSONEncoder().encode(page)
            XCTAssertLessThanOrEqual(encoded.count, 48 * 1024)
            XCTAssertEqual(page.totals.inputTokens, (1...count).reduce(0, +))
            let rows = page.rows ?? []
            XCTAssertFalse(rows.isEmpty)
            pageSizes.append(rows.count)
            all.append(contentsOf: rows)
            cursor = page.nextCursor
            iterations += 1
            if iterations > 100 {
                XCTFail("budget paging did not terminate")
                break
            }
        } while cursor != nil

        XCTAssertEqual(all.count, count)
        XCTAssertEqual(Set(all.map(\.id)).count, count)
        XCTAssertEqual(pageSizes.reduce(0, +), count)
        XCTAssertTrue(pageSizes.allSatisfy { $0 > 0 && $0 <= 100 })
        XCTAssertGreaterThan(pageSizes.count, 1)
        for row in all {
            XCTAssertEqual(row.label.count, 300)
        }
    }

    func testFiveThousandConversationPagingIsBoundedAndComplete() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let provider = usageFixtureUUID(0x10000000, 13)
        let model = usageFixtureUUID(0x20000000, 13)
        let count = 5_000
        try await manager.writer { db in
            try insertUsageProvider(db, id: provider, name: "P")
            try insertUsageModel(db, id: model, providerID: provider, name: "M")
            for index in 0..<count {
                let conversation = usageFixtureUUID(0x30000000, 1_000 + index)
                let run = usageFixtureUUID(0x40000000, 1_000 + index)
                try insertUsageConversation(
                    db, id: conversation,
                    title: String(format: "C%05d", index)
                )
                try insertUsageRun(db, id: run, conversationID: conversation,
                                   providerID: provider, modelID: model,
                                   providerName: "P", modelName: "M")
                try insertUsageRow(
                    db, id: usageFixtureUUID(0x50000000, 1_000 + index), runID: run,
                    input: index + 1, output: 0,
                    recordedAt: "2026-10-19T00:00:00.000Z"
                )
            }
        }
        let adapter = FacadeUsageAdapter(database: manager)
        let first = try await adapter.page(
            UsageStatisticsRequest(dimension: .conversation, limit: 100)
        )
        XCTAssertEqual(first.rows?.count ?? -1, 100)
        XCTAssertEqual(first.nextCursor, "100")
        XCTAssertEqual(first.totals.inputTokens, (1...count).reduce(0, +))

        let all = try await collect(adapter, dimension: .conversation, limit: 100)
        XCTAssertEqual(all.count, count)
        XCTAssertEqual(Set(all.map(\.id)).count, count)
        XCTAssertEqual(all.first?.id, usageFixtureUUID(0x30000000, 1_000 + count - 1))
        XCTAssertEqual(all.last?.id, usageFixtureUUID(0x30000000, 1_000))

        let originalStore = SQLiteRunStore(database: manager)
        let original = try await originalStore.usageStatistics()
        XCTAssertEqual(all.count, original.byConversation.count)
        XCTAssertEqual(Set(all.map(\.id)),
                       Set(original.byConversation.map(\.id)))
    }

    // MARK: - Frozen scope: no filters / no cost

    func testResponseExposesNoCostCurrencyPriceOrBillingFields() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let provider = usageFixtureUUID(0x10000000, 14)
        let model = usageFixtureUUID(0x20000000, 14)
        let conversation = usageFixtureUUID(0x30000000, 14)
        let run = usageFixtureUUID(0x40000000, 14)
        try await manager.writer { db in
            try insertUsageProvider(db, id: provider, name: "P")
            try insertUsageModel(db, id: model, providerID: provider, name: "M")
            try insertUsageConversation(db, id: conversation, title: "Ledger")
            try insertUsageRun(db, id: run, conversationID: conversation,
                               providerID: provider, modelID: model,
                               providerName: "P", modelName: "M")
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 14), runID: run,
                input: 3, output: 4, recordedAt: "2026-10-19T00:00:00.000Z",
                costEstimate: "0.0001"
            )
            try insertUsageRow(
                db, id: usageFixtureUUID(0x50000000, 15), runID: run,
                input: 5, output: 6, recordedAt: "2026-10-19T00:00:00.000Z",
                costEstimate: "99.99", isEstimated: true
            )
        }
        let adapter = FacadeUsageAdapter(database: manager)
        let page = try await adapter.page(
            UsageStatisticsRequest(dimension: .conversation)
        )
        let data = try JSONEncoder().encode(page)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            .lowercased()
        for forbidden in ["cost", "price", "currency", "billing", "estimated"] {
            XCTAssertFalse(text.contains(forbidden),
                           "frozen usage scope forbids \(forbidden)")
        }
        XCTAssertEqual(page.totals.inputTokens, 8)
        XCTAssertEqual(page.totals.outputTokens, 10)
    }

    func testRequestRejectsUnknownFiltersAndOutOfRangeValues() async throws {
        XCTAssertNil(parseReason(nil))
        XCTAssertNil(parseReason(.object([:])))
        XCTAssertNil(parseReason(.object([
            "dimension": .string("model"),
            "cursor": .string("2"),
            "limit": .integer(1),
        ])))
        XCTAssertEqual(parseReason(.object([
            "from": .string("2026-01-01T00:00:00Z"),
        ])), "unknownUsageField")
        XCTAssertEqual(parseReason(.object([
            "provider": .string("p1"),
        ])), "unknownUsageField")
        XCTAssertEqual(parseReason(.object([
            "dimension": .string("bogus"),
        ])), "unknownDimension")
        XCTAssertEqual(parseReason(.object([
            "cursor": .string("-1"),
        ])), "invalidCursor")
        XCTAssertEqual(parseReason(.object([
            "cursor": .string("abc"),
        ])), "invalidCursor")
        XCTAssertEqual(parseReason(.object([
            "cursor": .string("1234567890123456789"),
        ])), "invalidCursor")
        XCTAssertEqual(parseReason(.object([
            "limit": .integer(0),
        ])), "payloadFieldOutOfRange:limit")
        XCTAssertEqual(parseReason(.object([
            "limit": .integer(101),
        ])), "payloadFieldOutOfRange:limit")
        XCTAssertEqual(parseReason(.object([
            "limit": .string("10"),
        ])), "invalidPayloadField:limit")

        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeUsageAdapter(database: manager)
        do {
            _ = try await adapter.page(UsageStatisticsRequest(limit: 0))
            XCTFail("typed limit 0 must be rejected, never widened")
        } catch let error as UsageStatisticsAdapterError {
            XCTAssertEqual(error.wireReason, "payloadFieldOutOfRange:limit")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Totals persistence / client-owned cursor

    func testTotalsStayGlobalAndRefreshRestartsAtZero() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let provider = usageFixtureUUID(0x10000000, 16)
        let model = usageFixtureUUID(0x20000000, 16)
        try await manager.writer { db in
            try insertUsageProvider(db, id: provider, name: "P")
            try insertUsageModel(db, id: model, providerID: provider, name: "M")
            for index in 0..<5 {
                let conversation = usageFixtureUUID(0x30000000, 600 + index)
                let run = usageFixtureUUID(0x40000000, 600 + index)
                try insertUsageConversation(
                    db, id: conversation,
                    title: String(format: "K%02d", index)
                )
                try insertUsageRun(db, id: run, conversationID: conversation,
                                   providerID: provider, modelID: model,
                                   providerName: "P", modelName: "M")
                try insertUsageRow(
                    db, id: usageFixtureUUID(0x50000000, 600 + index), runID: run,
                    input: (index + 1) * 10, output: index,
                    recordedAt: "2026-10-19T00:00:00.000Z"
                )
            }
        }
        let adapter = FacadeUsageAdapter(database: manager)
        let page1 = try await adapter.page(
            UsageStatisticsRequest(dimension: .conversation, limit: 2)
        )
        XCTAssertEqual(page1.rows?.count ?? -1, 2)
        XCTAssertEqual(page1.nextCursor, "2")
        let page2 = try await adapter.page(
            UsageStatisticsRequest(dimension: .conversation,
                                   cursor: page1.nextCursor, limit: 2)
        )
        XCTAssertEqual(page2.totals, page1.totals)
        XCTAssertEqual(page2.nextCursor, "4")
        let refreshed = try await adapter.page(
            UsageStatisticsRequest(dimension: .conversation, limit: 2)
        )
        XCTAssertEqual(refreshed, page1)
        let ids = (page1.rows ?? []).map(\.id) + (page2.rows ?? []).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// P5 — Global usage statistics adapter (private source candidate; UNCOMPILED).
//
// Authority: settings-domain-main-acceptance-20261019/input-final/contract.json
// (sha256 f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c),
// commandTable[23] usage.statistics.get; COMMANDS.md §5;
// IMPLEMENTATION_HANDOFF.md P5; SETTINGS_DEFAULTS_USAGE_SOURCE_ADMISSION_20261019
// .usageExactClosedScopeCorrection (the FROZEN exhaustive scope).
//
// Real dependencies:
// * ONE original DatabaseManager / schema 46 (FloePersistence).
// * The original run_usage / runs / conversations tables.
// * The original SQLiteRunStore.usageStatistics() remains the equivalence
//   reference; this adapter mirrors its SQL exactly and adds only
//   LIMIT ? OFFSET ? to the three breakdown queries. The unbounded original
//   struct is NEVER materialized for a wire page.
//
// Exact frozen scope: dimension total|conversation|model|provider (default
// total), client offset cursor, limit 1...100 (default 50). NO date/range/
// provider/model filter, NO price/currency/cost/billing field or calculation.
// The adapter does not read cost_estimate or is_estimated at all.
//
// Consistency: LIVE pagination, one original reader transaction per page.
// Pages may drift when run_usage changes mid-walk; ordering is deterministic
// and ids are stable, so the client dedupes by id and refreshes from offset 0.
// There is NO cross-page snapshot, durable cursor, cache or usage digest.
//
// No handler is registered by this file.

import Foundation
import GRDB
import FloeCore
import FloePersistence

/// Typed failures of the global-usage adapter.
public enum UsageStatisticsAdapterError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    /// Only for a pathological single row/envelope that cannot fit the normal
    /// 48KiB page budget without truncating an atomic item. The adapter never
    /// truncates a label and never skips a row silently.
    case payloadTooLarge(String)
    case persistenceUnavailable(String?)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope:
            return "invalidEnvelope"
        case .payloadTooLarge:
            return "payloadTooLarge"
        case .persistenceUnavailable:
            return "persistenceUnavailable"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason):
            return reason
        case .payloadTooLarge(let reason):
            return reason
        case .persistenceUnavailable(let reason):
            return reason
        }
    }
}

/// Closed request vocabulary. Unknown filter fields are structurally rejected;
/// there is no way to widen this request into a date/range/provider filter.
public struct UsageStatisticsRequest: Sendable, Equatable {
    public static let defaultLimit = 50
    public static let maximumLimit = SettingsDomainV1.maximumUsagePage
    public static let maximumCursorCharacters = 18

    public let dimension: SettingsDomainV1.UsageDimension
    public let cursor: String?
    public let limit: Int

    public init(dimension: SettingsDomainV1.UsageDimension = .total,
                cursor: String? = nil,
                limit: Int = UsageStatisticsRequest.defaultLimit) {
        self.dimension = dimension
        self.cursor = cursor
        self.limit = limit
    }

    /// Parses exactly the P0-validated payload surface. It intentionally
    /// repeats the range/enum checks so a direct caller cannot bypass them.
    /// `unknownDimension` matches commandTable[23].errors; the P0 candidate
    /// currently reports `invalidPayloadField:dimension` from its generic enum
    /// helper, so the future binder must let this adapter own that reason (or
    /// P0 final alignment must fix it) to preserve the frozen error string.
    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws -> UsageStatisticsRequest {
        guard let payload else {
            return UsageStatisticsRequest()
        }
        guard case .object(let root) = payload else {
            throw UsageStatisticsAdapterError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["dimension", "cursor", "limit"].contains(key) {
            throw UsageStatisticsAdapterError.invalidEnvelope("unknownUsageField")
        }

        var dimension = SettingsDomainV1.UsageDimension.total
        if let value = root["dimension"] {
            guard case .string(let raw) = value,
                  let decoded = SettingsDomainV1.UsageDimension(rawValue: raw) else {
                throw UsageStatisticsAdapterError.invalidEnvelope("unknownDimension")
            }
            dimension = decoded
        }

        var cursor: String?
        if let value = root["cursor"] {
            guard case .string(let raw) = value,
                  isValidCursor(raw) else {
                throw UsageStatisticsAdapterError.invalidEnvelope("invalidCursor")
            }
            cursor = raw
        }

        var limit = defaultLimit
        if let value = root["limit"] {
            guard case .integer(let raw) = value else {
                throw UsageStatisticsAdapterError.invalidEnvelope(
                    "invalidPayloadField:limit"
                )
            }
            guard raw >= 1, raw <= Int64(maximumLimit) else {
                throw UsageStatisticsAdapterError.invalidEnvelope(
                    "payloadFieldOutOfRange:limit"
                )
            }
            limit = Int(raw)
        }

        return UsageStatisticsRequest(dimension: dimension,
                                      cursor: cursor,
                                      limit: limit)
    }

    struct Validated: Sendable {
        let dimension: SettingsDomainV1.UsageDimension
        let offset: Int
        let limit: Int
    }

    func validated() throws -> Validated {
        guard limit >= 1, limit <= Self.maximumLimit else {
            throw UsageStatisticsAdapterError.invalidEnvelope(
                "payloadFieldOutOfRange:limit"
            )
        }
        let offset: Int
        if let cursor {
            guard Self.isValidCursor(cursor), let parsed = Int(cursor) else {
                throw UsageStatisticsAdapterError.invalidEnvelope("invalidCursor")
            }
            offset = parsed
        } else {
            offset = 0
        }
        return Validated(dimension: dimension, offset: offset, limit: limit)
    }

    private static func isValidCursor(_ raw: String) -> Bool {
        !raw.isEmpty &&
            raw.count <= maximumCursorCharacters &&
            raw.allSatisfy { $0.isNumber } &&
            Int(raw) != nil
    }
}

/// Read-only projection over the ORIGINAL database. Never a billing service,
/// account service, network client or second database.
public actor FacadeUsageAdapter {
    public static let pageBudgetBytes = SettingsDomainV1.pageBudgetBytes

    private let database: DatabaseManager

    /// The real original DatabaseManager is required. There is intentionally no
    /// nil/noop default and no in-memory production fallback.
    public init(database: DatabaseManager) {
        self.database = database
    }

    /// ONE original DatabaseManager.reader transaction per page. Totals are
    /// always the original global aggregate; byDay is present only for the
    /// total dimension; rows + nextCursor are present only for a breakdown.
    public func page(_ request: UsageStatisticsRequest = UsageStatisticsRequest()) async throws -> SettingsDomainV1.UsageStatisticsReply {
        let validated = try request.validated()
        let database = self.database
        do {
            return try await database.reader { db in
                let totals = try Self.totals(db)
                switch validated.dimension {
                case .total:
                    let days = try Self.days(db)
                    let reply = Self.reply(totals: totals, byDay: days,
                                           rows: nil, nextCursor: nil)
                    guard Self.encodedSize(reply) <= Self.pageBudgetBytes else {
                        throw UsageStatisticsAdapterError.payloadTooLarge(
                            "usageResponseExceedsPageBudget"
                        )
                    }
                    return reply
                case .conversation, .model, .provider:
                    let fetched = try Self.breakdownRows(
                        db,
                        dimension: validated.dimension,
                        offset: validated.offset,
                        limit: validated.limit
                    )
                    return try Self.assemble(totals: totals,
                                             fetched: fetched,
                                             offset: validated.offset,
                                             limit: validated.limit)
                }
            }
        } catch let error as UsageStatisticsAdapterError {
            throw error
        } catch {
            throw UsageStatisticsAdapterError.persistenceUnavailable(nil)
        }
    }

    // MARK: - Original SQL (mirrored verbatim except breakdown LIMIT/OFFSET)

    /// RunStore.swift:715-727, unchanged.
    private static let totalsSQL = """
        SELECT
            COALESCE(SUM(input_tokens), 0) AS total_input,
            COALESCE(SUM(output_tokens), 0) AS total_output,
            SUM(cache_read_tokens) AS cache_read,
            SUM(cache_write_tokens) AS cache_write,
            SUM(reasoning_tokens) AS reasoning,
            AVG(tokens_per_second) AS avg_tps,
            AVG(time_to_first_token_ms) AS avg_ttft,
            AVG(total_duration_ms) AS avg_duration,
            COUNT(DISTINCT run_id) AS total_runs
        FROM run_usage
        """

    /// RunStore.swift:738-750, unchanged (LIMIT 30).
    private static let byDaySQL = """
        SELECT
            date(recorded_at) AS day,
            COALESCE(SUM(input_tokens), 0) AS input,
            COALESCE(SUM(output_tokens), 0) AS output,
            SUM(cache_read_tokens) AS cache_read,
            SUM(cache_write_tokens) AS cache_write,
            COUNT(DISTINCT run_id) AS runs
        FROM run_usage
        GROUP BY date(recorded_at)
        ORDER BY day DESC
        LIMIT 30
        """

    /// RunStore.swift:762-780, with only `LIMIT ? OFFSET ?` appended.
    private static let conversationSQL = """
        SELECT
            r.conversation_id AS group_id,
            COALESCE(NULLIF(c.title, ''), '') AS label,
            COALESCE(SUM(u.input_tokens), 0) AS input,
            COALESCE(SUM(u.output_tokens), 0) AS output,
            SUM(u.cache_read_tokens) AS cache_read,
            SUM(u.cache_write_tokens) AS cache_write,
            SUM(u.reasoning_tokens) AS reasoning,
            AVG(u.tokens_per_second) AS avg_tps,
            AVG(u.time_to_first_token_ms) AS avg_ttft,
            AVG(u.total_duration_ms) AS avg_duration,
            COUNT(DISTINCT r.id) AS runs
        FROM run_usage u
        JOIN runs r ON r.id = u.run_id
        JOIN conversations c ON c.id = r.conversation_id
        GROUP BY r.conversation_id, c.title
        ORDER BY (
            SUM(u.input_tokens) + SUM(u.output_tokens)
            + COALESCE(SUM(u.cache_read_tokens), 0)
            + COALESCE(SUM(u.cache_write_tokens), 0)
        ) DESC, label
        LIMIT ? OFFSET ?
        """

    /// RunStore.swift:783-805, with only `LIMIT ? OFFSET ?` appended.
    private static let modelSQL = """
        SELECT
            COALESCE(r.model_id, 'legacy-model') AS group_id,
            COALESCE(MAX(NULLIF(r.model_name_snapshot, '')), '') AS label,
            COALESCE(SUM(u.input_tokens), 0) AS input,
            COALESCE(SUM(u.output_tokens), 0) AS output,
            SUM(u.cache_read_tokens) AS cache_read,
            SUM(u.cache_write_tokens) AS cache_write,
            SUM(u.reasoning_tokens) AS reasoning,
            AVG(u.tokens_per_second) AS avg_tps,
            AVG(u.time_to_first_token_ms) AS avg_ttft,
            AVG(u.total_duration_ms) AS avg_duration,
            COUNT(DISTINCT r.id) AS runs
        FROM run_usage u
        JOIN runs r ON r.id = u.run_id
        GROUP BY COALESCE(r.model_id, 'legacy-model')
        ORDER BY (
            SUM(u.input_tokens) + SUM(u.output_tokens)
            + COALESCE(SUM(u.cache_read_tokens), 0)
            + COALESCE(SUM(u.cache_write_tokens), 0)
        ) DESC, label
        LIMIT ? OFFSET ?
        """

    /// RunStore.swift:808-830, with only `LIMIT ? OFFSET ?` appended.
    private static let providerSQL = """
        SELECT
            COALESCE(r.provider_id, 'legacy-provider') AS group_id,
            COALESCE(MAX(NULLIF(r.provider_name_snapshot, '')), '') AS label,
            COALESCE(SUM(u.input_tokens), 0) AS input,
            COALESCE(SUM(u.output_tokens), 0) AS output,
            SUM(u.cache_read_tokens) AS cache_read,
            SUM(u.cache_write_tokens) AS cache_write,
            SUM(u.reasoning_tokens) AS reasoning,
            AVG(u.tokens_per_second) AS avg_tps,
            AVG(u.time_to_first_token_ms) AS avg_ttft,
            AVG(u.total_duration_ms) AS avg_duration,
            COUNT(DISTINCT r.id) AS runs
        FROM run_usage u
        JOIN runs r ON r.id = u.run_id
        GROUP BY COALESCE(r.provider_id, 'legacy-provider')
        ORDER BY (
            SUM(u.input_tokens) + SUM(u.output_tokens)
            + COALESCE(SUM(u.cache_read_tokens), 0)
            + COALESCE(SUM(u.cache_write_tokens), 0)
        ) DESC, label
        LIMIT ? OFFSET ?
        """

    // MARK: - Mapping

    private static func totals(_ db: Database) throws -> SettingsDomainV1.UsageMetrics {
        guard let row = try Row.fetchOne(db, sql: totalsSQL) else {
            throw UsageStatisticsAdapterError.persistenceUnavailable(
                "usageTotalsRowMissing"
            )
        }
        let input: Int = row["total_input"]
        let output: Int = row["total_output"]
        let runs: Int = row["total_runs"]
        let cacheRead: Int? = row["cache_read"]
        let cacheWrite: Int? = row["cache_write"]
        let reasoning: Int? = row["reasoning"]
        let averageTPS: Double? = row["avg_tps"]
        let averageTTFT: Double? = row["avg_ttft"]
        let averageDuration: Double? = row["avg_duration"]
        return SettingsDomainV1.UsageMetrics(
            inputTokens: input,
            outputTokens: output,
            totalTokens: input + output + (cacheRead ?? 0) + (cacheWrite ?? 0),
            runs: runs,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            averageTokensPerSecond: averageTPS,
            averageTimeToFirstTokenMs: averageTTFT,
            averageDurationMs: averageDuration
        )
    }

    private static func days(_ db: Database) throws -> [SettingsDomainV1.UsageDay] {
        let rows = try Row.fetchAll(db, sql: byDaySQL)
        return rows.map { row in
            let input: Int = row["input"]
            let output: Int = row["output"]
            let cacheRead: Int? = row["cache_read"]
            let cacheWrite: Int? = row["cache_write"]
            return SettingsDomainV1.UsageDay(
                date: row["day"],
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                runs: row["runs"],
                totalTokens: input + output + (cacheRead ?? 0) + (cacheWrite ?? 0)
            )
        }
    }

    private static func breakdownRows(_ db: Database,
                                      dimension: SettingsDomainV1.UsageDimension,
                                      offset: Int,
                                      limit: Int) throws -> [SettingsDomainV1.UsageBreakdown] {
        let sql: String
        switch dimension {
        case .conversation:
            sql = conversationSQL
        case .model:
            sql = modelSQL
        case .provider:
            sql = providerSQL
        case .total:
            return []
        }
        // n+1 hasMore probe, same shape as listMemories (:507-518): bounded
        // SQL, never a full materialization of the breakdown.
        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: [limit + 1, offset]
        )
        return rows.map { Self.breakdown(from: $0) }
    }

    private static func breakdown(from row: Row) -> SettingsDomainV1.UsageBreakdown {
        let rawLabel: String = row["label"]
        let label = rawLabel.isEmpty
            ? FloeL10n.l("persistence.run_store.legacy_usage_label")
            : rawLabel
        let input: Int = row["input"]
        let output: Int = row["output"]
        let cacheRead: Int? = row["cache_read"]
        let cacheWrite: Int? = row["cache_write"]
        return SettingsDomainV1.UsageBreakdown(
            id: row["group_id"],
            label: label,
            inputTokens: input,
            outputTokens: output,
            runs: row["runs"],
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: row["reasoning"],
            averageTokensPerSecond: row["avg_tps"],
            averageTimeToFirstTokenMs: row["avg_ttft"],
            averageDurationMs: row["avg_duration"],
            totalTokens: input + output + (cacheRead ?? 0) + (cacheWrite ?? 0)
        )
    }

    // MARK: - Budget-safe page assembly

    private static func reply(totals: SettingsDomainV1.UsageMetrics,
                              byDay: [SettingsDomainV1.UsageDay]?,
                              rows: [SettingsDomainV1.UsageBreakdown]?,
                              nextCursor: String?) -> SettingsDomainV1.UsageStatisticsReply {
        SettingsDomainV1.UsageStatisticsReply(
            totals: totals,
            byDay: byDay,
            rows: rows,
            nextCursor: nextCursor
        )
    }

    private static func encodedSize(_ reply: SettingsDomainV1.UsageStatisticsReply) -> Int {
        (try? JSONEncoder().encode(reply).count) ?? Int.max
    }

    private static func assemble(
        totals: SettingsDomainV1.UsageMetrics,
        fetched: [SettingsDomainV1.UsageBreakdown],
        offset: Int,
        limit: Int
    ) throws -> SettingsDomainV1.UsageStatisticsReply {
        var kept: [SettingsDomainV1.UsageBreakdown] = []
        var more = fetched.count > limit

        for (index, row) in fetched.prefix(limit).enumerated() {
            kept.append(row)
            let provisionalMore = more || fetched.count > index + 1
            let provisionalCursor = provisionalMore
                ? String(offset + kept.count)
                : nil
            let candidate = reply(totals: totals, byDay: nil, rows: kept,
                                  nextCursor: provisionalCursor)
            if encodedSize(candidate) <= Self.pageBudgetBytes {
                continue
            }
            // Atomic rows: never truncate a label or a metric. Drop the whole
            // row and let the client fetch it from the next offset.
            kept.removeLast()
            more = true
            break
        }

        if kept.isEmpty && !fetched.isEmpty {
            throw UsageStatisticsAdapterError.payloadTooLarge(
                "usageRowExceedsPageBudget"
            )
        }

        while true {
            let cursor = more ? String(offset + kept.count) : nil
            let candidate = reply(totals: totals, byDay: nil, rows: kept,
                                  nextCursor: cursor)
            if encodedSize(candidate) <= Self.pageBudgetBytes {
                return candidate
            }
            guard !kept.isEmpty else {
                throw UsageStatisticsAdapterError.payloadTooLarge(
                    "usageResponseExceedsPageBudget"
                )
            }
            kept.removeLast()
            more = true
        }
    }
}

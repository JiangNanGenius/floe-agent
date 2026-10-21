// FloeApp — `apple.health.read`, a bounded read-only HealthKit tool.
//
// The tool owns validation, authorization, paging and output shaping. The
// HealthKit service owns only the OS query; it has no write API.

#if canImport(UIKit) && canImport(HealthKit)
import Foundation
import UIKit
import FloeCore
import FloeTools

/// Foreground gate shared by Health and NDEF tools. A health read while the
/// app is backgrounded is refused rather than silently performed; the same
/// closure is injected by prepared tests.
enum AppleHealthForeground {
    static func isActive() async -> Bool {
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
    }
}

struct AppleHealthReadTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var metric: String?
        var mode: String?
        var aggregation: String?
        var start: String?
        var end: String?
        var limit: Int?
        var cursor: String?

        init(
            metric: String? = nil,
            mode: String? = nil,
            aggregation: String? = nil,
            start: String? = nil,
            end: String? = nil,
            limit: Int? = nil,
            cursor: String? = nil
        ) {
            self.metric = metric
            self.mode = mode
            self.aggregation = aggregation
            self.start = start
            self.end = end
            self.limit = limit
            self.cursor = cursor
        }
    }

    static let name = "apple.health.read"
    static let toolDescription = """
    Read a bounded, read-only slice of the user's Health data for ONE approved metric after system authorization. \
    Approved metrics: steps, activeEnergy, heartRate, restingHeartRate, sleep, workouts, activitySummary, bodyMass, \
    oxygenSaturation, heartRateVariability. Times are ISO 8601 UTC and each sample query includes records overlapping \
    the requested interval (activity summaries use the overlapping calendar days). This tool never writes, deletes, shares or requests clinical, mental-health \
    or diagnostic data. Use mode=samples (default) for bounded rows with a task-owned stable cursor, or mode=aggregate \
    for one statistic over the requested interval on quantity metrics only. start/end are required on the first call \
    (ISO 8601, maximum 366 days); cursor continues the SAME snapshot and omits start/end. Values use HealthKit canonical \
    units (percent is the 0...1 fraction; heart rate is count/min; oxygen saturation is percent). HealthKit does not \
    disclose read authorization: a completed authorization request or an empty result is NOT proof of granted or denied \
    access. Sleep is sample-only; exact duplicates are coalesced and same-stage overlaps are marked, never added into a \
    medical summary. Results are ordinary conversation data and remain subject to the task's existing permissions.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"metric":{"type":"string","enum":["steps","activeEnergy","heartRate","restingHeartRate","sleep","workouts","activitySummary","bodyMass","oxygenSaturation","heartRateVariability"],"description":"One approved HealthKit metric."},"mode":{"type":"string","enum":["samples","aggregate"],"description":"samples returns bounded rows; aggregate returns one statistic for quantity metrics."},"aggregation":{"type":"string","enum":["sum","average","minimum","maximum","mostRecent"],"description":"Required only for mode=aggregate; sum is limited to steps and activeEnergy."},"start":{"type":"string","description":"ISO 8601 inclusive start. Required unless cursor is supplied."},"end":{"type":"string","description":"ISO 8601 exclusive end. Required unless cursor is supplied."},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Rows per page; defaults to 50."},"cursor":{"type":"string","maxLength":2048,"description":"Opaque nextCursor from a previous page of the same metric."}},"required":["metric"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let service: any HealthDataProviding
    private let isForeground: @Sendable () async -> Bool

    init(
        service: any HealthDataProviding,
        isForeground: @escaping @Sendable () async -> Bool = {
            await AppleHealthForeground.isActive()
        }
    ) {
        self.service = service
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.plan(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return AppleToolOutput.make(
                "status=unavailable capability=health reason=temporaryChat",
                exitStatus: 75
            )
        }
        let plan = try Self.plan(args)
        guard await isForeground() else {
            return AppleToolOutput.make(
                "status=\(HealthAccessError.foregroundRequired.status) capability=health",
                exitStatus: HealthAccessError.foregroundRequired.exitStatus
            )
        }
        guard service.isAvailable else {
            return AppleToolOutput.make(
                "status=\(HealthAccessError.unsupportedDevice.status) capability=health",
                exitStatus: HealthAccessError.unsupportedDevice.exitStatus
            )
        }

        do {
            if let cursor = plan.cursor {
                return try await continueSnapshot(
                    cursor: cursor,
                    plan: plan,
                    context: context
                )
            }
            switch plan.mode {
            case .samples:
                return try await readSamples(plan: plan, context: context)
            case .aggregate:
                return try await readAggregate(plan: plan, context: context)
            }
        } catch let error as HealthAccessError {
            return Self.failure(error)
        } catch let error as PersonalToolCursorError {
            return AppleToolOutput.cursorError(error)
        } catch {
            return AppleToolOutput.make(
                "status=queryFailed capability=health message=\(error.localizedDescription)",
                exitStatus: 1
            )
        }
    }

    // MARK: - Execution paths

    private func readSamples(
        plan: HealthReadPlan,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        guard let start = plan.start, let end = plan.end else {
            throw FloeError.validationFailed("start and end are required")
        }
        try await authorize(plan.metric, context: context)
        let query = HealthSampleQuery(
            metric: plan.metric,
            start: start,
            end: end,
            maxRows: 1_000
        )
        let batch = try await HealthQueryRunner.run(
            cancellation: context.cancellation,
            timeout: 60
        ) {
            try await service.fetchSamples(
                query,
                cancellation: context.cancellation
            )
        }
        let prepared = HealthSampleRenderer.prepare(batch.rows, metric: plan.metric)
        let owner = PersonalToolOwnerID(context: context)
        let kind = Self.snapshotKind(plan.metric)
        let filterKey = Self.filterKey(plan: plan, start: start, end: end)
        let page = try await PersonalToolCursorStore.shared.begin(
            kind: kind,
            filterKey: filterKey,
            lines: prepared.lines,
            owner: owner,
            pageSize: plan.limit,
            characterBudget: AppleToolOutput.paginationCharacterBudget,
            reservedHeaderCharacters: 640
        )
        let header = Self.samplesHeader(
            plan: plan,
            start: start,
            end: end,
            batch: batch,
            prepared: prepared,
            page: page
        )
        return Self.pageOutput(header: header, page: page)
    }

    private func readAggregate(
        plan: HealthReadPlan,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        guard let start = plan.start,
              let end = plan.end,
              let aggregation = plan.aggregation else {
            throw FloeError.validationFailed("aggregate mode requires start, end and aggregation")
        }
        try await authorize(plan.metric, context: context)
        let value = try await HealthQueryRunner.run(
            cancellation: context.cancellation,
            timeout: 60
        ) {
            try await service.fetchAggregate(
                metric: plan.metric,
                start: start,
                end: end,
                aggregation: aggregation,
                cancellation: context.cancellation
            )
        }
        var fields = [
            "status=ok",
            "semantics=aggregate",
            "metric=\(plan.metric.rawValue)",
            "aggregation=\(aggregation.rawValue)",
            "intervalStart=\(HealthDates.iso(start))",
            "intervalEnd=\(HealthDates.iso(end))",
            "timezone=UTC",
            "displayTimeZone=\(TimeZone.current.identifier)",
            "timeFilter=overlapsRange",
            "value=\(HealthNumberFormat.string(value.value))",
            "unit=\(value.unit)",
            "hasValue=\(value.value != nil)",
            "aggregateScope=requestedInterval",
            "sampleRowsNotEnumerated=true",
            "authorization=grantNotDisclosed"
        ]
        if let mostRecentStart = value.mostRecentStart {
            fields.append("mostRecentStart=\(HealthDates.iso(mostRecentStart))")
        }
        if let mostRecentEnd = value.mostRecentEnd {
            fields.append("mostRecentEnd=\(HealthDates.iso(mostRecentEnd))")
        }
        if value.value == nil {
            fields.append("emptyResultIsNotDenial=true")
        }
        return AppleToolOutput.make(fields.joined(separator: " "))
    }

    private func continueSnapshot(
        cursor: String,
        plan: HealthReadPlan,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        let owner = PersonalToolOwnerID(context: context)
        let page = try await PersonalToolCursorStore.shared.next(
            cursor: cursor,
            owner: owner,
            kind: Self.snapshotKind(plan.metric),
            filterKey: nil,
            pageSize: plan.limit,
            characterBudget: AppleToolOutput.paginationCharacterBudget,
            reservedHeaderCharacters: 640
        )
        let header = [
            "status=ok",
            "kind=\(Self.snapshotKind(plan.metric))",
            "semantics=\(plan.metric == .activitySummary ? "dailySummaries" : "samples")",
            "metric=\(plan.metric.rawValue)",
            "cursorPage=true",
            "count=\(page.returnedCount)",
            "totalCount=\(page.totalCount)",
            "hasMore=\(page.hasMore)",
            "nextCursor=\(page.nextCursor ?? "none")",
            "pageCount=\(page.pageCount)",
            "snapshotTime=\(HealthDates.iso(page.snapshotTime))",
            "completeness=\(page.completeness)",
            "authorization=grantNotDisclosed",
            "emptyResultIsNotDenial=true"
        ].joined(separator: " ")
        return Self.pageOutput(header: header, page: page)
    }

    private func authorize(
        _ metric: HealthMetric,
        context: ToolContext
    ) async throws {
        try await HealthQueryRunner.run(
            cancellation: context.cancellation,
            timeout: 120
        ) {
            try await service.requestReadAuthorization(
                for: metric,
                cancellation: context.cancellation
            )
        }
    }

    // MARK: - Output

    private static func failure(_ error: HealthAccessError) -> ToolExecutionOutput {
        var fields = [
            "status=\(error.status)",
            "capability=health",
            "message=\(error.localizedDescription)"
        ]
        if case .queryFailed(let code) = error {
            fields.insert("code=\(code)", at: 2)
        }
        return AppleToolOutput.make(
            fields.joined(separator: " "),
            exitStatus: error.exitStatus
        )
    }

    private static func samplesHeader(
        plan: HealthReadPlan,
        start: Date,
        end: Date,
        batch: HealthSampleBatch,
        prepared: PreparedHealthRows,
        page: PersonalToolPage
    ) -> String {
        var fields = [
            "status=ok",
            "kind=\(snapshotKind(plan.metric))",
            "semantics=\(prepared.semantics)",
            "metric=\(plan.metric.rawValue)",
            "timezone=UTC",
            "displayTimeZone=\(TimeZone.current.identifier)",
            "intervalStart=\(HealthDates.iso(start))",
            "intervalEnd=\(HealthDates.iso(end))",
            "timeFilter=\(plan.metric == .activitySummary ? "calendarDayOverlap" : "overlapsRange")",
            "sort=\(prepared.sortDescription)",
            "bounded=true",
            "readOnly=true",
            "writeRequested=false",
            "count=\(page.returnedCount)",
            "totalCount=\(page.totalCount)",
            "fetched=\(batch.fetchedCount)",
            "queryTruncated=\(batch.truncated)",
            "hasMore=\(page.hasMore)",
            "nextCursor=\(page.nextCursor ?? "none")",
            "pageCount=\(page.pageCount)",
            "snapshotTime=\(HealthDates.iso(page.snapshotTime))",
            "completeness=\(page.completeness)",
            "duplicatesCoalesced=\(prepared.duplicatesCoalesced)",
            "sameStageOverlaps=\(prepared.sameStageOverlaps)",
            "authorization=grantNotDisclosed"
        ]
        if page.totalCount == 0 {
            fields.append("emptyResultIsNotDenial=true")
        }
        if page.truncatedRows > 0 {
            fields.append("truncatedRows=\(page.truncatedRows)")
        }
        return fields.joined(separator: " ")
    }

    private static func pageOutput(
        header: String,
        page: PersonalToolPage
    ) -> ToolExecutionOutput {
        guard !page.lines.isEmpty else { return AppleToolOutput.make(header) }
        return AppleToolOutput.make(header + "\n" + page.lines.joined(separator: "\n"))
    }

    private static func snapshotKind(_ metric: HealthMetric) -> String {
        "apple.health.samples.\(metric.rawValue)"
    }

    private static func filterKey(
        plan: HealthReadPlan,
        start: Date,
        end: Date
    ) -> String {
        "\(plan.metric.rawValue)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|samples"
    }

    // MARK: - Argument planning

    private struct HealthReadPlan {
        var metric: HealthMetric
        var mode: HealthQueryMode
        var aggregation: HealthAggregation?
        var start: Date?
        var end: Date?
        var limit: Int
        var cursor: String?
    }

    private static func plan(_ args: Arguments) throws -> HealthReadPlan {
        guard let rawMetric = args.metric?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawMetric.isEmpty else {
            throw FloeError.validationFailed("metric is required")
        }
        guard let metric = HealthMetric(rawValue: rawMetric) else {
            throw FloeError.validationFailed(
                "metric must be one of: \(HealthMetric.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        let mode: HealthQueryMode
        if let rawMode = args.mode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawMode.isEmpty {
            guard let parsed = HealthQueryMode(rawValue: rawMode) else {
                throw FloeError.validationFailed("mode must be samples or aggregate")
            }
            mode = parsed
        } else {
            mode = .samples
        }

        var aggregation: HealthAggregation?
        if let raw = args.aggregation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            guard let parsed = HealthAggregation(rawValue: raw) else {
                throw FloeError.validationFailed(
                    "aggregation must be one of: \(HealthAggregation.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            aggregation = parsed
        }

        let limit = args.limit ?? 50
        guard (1...200).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...200")
        }

        let cursor = args.cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCursor = cursor?.isEmpty == false
        if hasCursor, mode != .samples {
            throw FloeError.validationFailed("cursor is only valid with mode=samples")
        }
        if hasCursor, args.start != nil || args.end != nil || args.aggregation != nil {
            throw FloeError.validationFailed(
                "cursor continues a snapshot; omit start, end and aggregation"
            )
        }

        let start = try AppleToolOutput.date(args.start)
        let end = try AppleToolOutput.date(args.end)

        if hasCursor {
            return HealthReadPlan(
                metric: metric,
                mode: .samples,
                aggregation: nil,
                start: nil,
                end: nil,
                limit: limit,
                cursor: cursor
            )
        }

        guard let start, let end else {
            throw FloeError.validationFailed(
                "start and end are required (ISO 8601) unless cursor continues a snapshot"
            )
        }
        guard end > start else {
            throw FloeError.validationFailed("end must be later than start")
        }
        guard end.timeIntervalSince(start) <= 366 * 24 * 3600 else {
            throw FloeError.validationFailed("Health range must be no longer than 366 days")
        }

        switch mode {
        case .samples:
            if aggregation != nil {
                throw FloeError.validationFailed("aggregation is only valid with mode=aggregate")
            }
            return HealthReadPlan(
                metric: metric,
                mode: .samples,
                aggregation: nil,
                start: start,
                end: end,
                limit: limit,
                cursor: nil
            )
        case .aggregate:
            guard metric.supportsAggregate else {
                throw FloeError.validationFailed(
                    "aggregate is only available for quantity metrics; \(metric.rawValue) is sample-only"
                )
            }
            let resolved = aggregation
                ?? (metric.isCumulativeQuantity ? .sum : .average)
            guard metric.allowedAggregations.contains(resolved) else {
                let allowed = metric.allowedAggregations.map(\.rawValue).sorted()
                throw FloeError.validationFailed(
                    "aggregation for \(metric.rawValue) must be one of: \(allowed.joined(separator: ", "))"
                )
            }
            return HealthReadPlan(
                metric: metric,
                mode: .aggregate,
                aggregation: resolved,
                start: start,
                end: end,
                limit: limit,
                cursor: nil
            )
        }
    }
}
#endif

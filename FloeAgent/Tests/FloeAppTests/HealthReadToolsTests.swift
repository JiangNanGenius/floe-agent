// FloeAppTests — prepared behavior tests for `apple.health.read`.
//
// These use a fake `HealthDataProviding`; no HealthKit data, authorization
// sheet or device is touched. They are registered only after the primary adds
// this file to the FloeAppTests source list and regenerates the project.

#if canImport(UIKit) && canImport(HealthKit)
import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeApp

@Suite("FloeApp.HealthReadTools")
struct HealthReadToolsTests {
    private func context(
        conversation: UUID? = UUID(),
        environmentID: String? = nil,
        cancellation: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            cancellation: cancellation,
            environmentID: environmentID,
            conversationID: conversation
        )
    }

    private func tool(
        service: FakeHealthService,
        foreground: Bool = true
    ) -> AppleHealthReadTool {
        AppleHealthReadTool(
            service: service,
            isForeground: { foreground }
        )
    }

    private func field(_ name: String, in output: String) -> String? {
        guard let firstLine = output.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        for token in firstLine.split(separator: " ") {
            if token.hasPrefix("\(name)=") {
                return String(token.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    @Test("Only the approved finite metric catalog is representable")
    func approvedMetricCatalog() {
        let names = Set(HealthMetric.allCases.map(\.rawValue))
        #expect(names == [
            "steps", "activeEnergy", "heartRate", "restingHeartRate", "sleep",
            "workouts", "activitySummary", "bodyMass", "oxygenSaturation",
            "heartRateVariability"
        ])
        #expect(HealthMetric.steps.allowedAggregations == [.sum])
        #expect(HealthMetric.heartRate.allowedAggregations == [
            .average, .minimum, .maximum, .mostRecent
        ])
        #expect(HealthMetric.sleep.allowedAggregations.isEmpty)
        #expect(!HealthMetric.sleep.supportsAggregate)
        #expect(HealthMetric.activitySummary.allowedAggregations.isEmpty)
    }

    @Test("An empty result is not evidence of denial and a request is not evidence of grant")
    func authorizationIsUndisclosed() async throws {
        let service = FakeHealthService()
        let output = try await tool(service: service).execute(
            .init(
                metric: "steps",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("count=0"))
        #expect(output.summary.contains("authorization=grantNotDisclosed"))
        #expect(output.summary.contains("emptyResultIsNotDenial=true"))
        #expect(!output.summary.lowercased().contains("granted"))
        #expect(!output.summary.lowercased().contains("denied"))
        let requests = await service.readRequests
        #expect(requests == [.steps])
    }

    @Test("A not-requested query is a distinct failure and never completed data")
    func notRequestedIsDistinctFromEmpty() async throws {
        let service = FakeHealthService()
        await service.setAuthorizationError(.authorizationNotRequested)
        let output = try await tool(service: service).execute(
            .init(
                metric: "heartRate",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ),
            context: context()
        )
        #expect(output.exitStatus == 77)
        #expect(output.summary.contains("status=authorizationRequired"))
        #expect(!output.summary.contains("status=ok"))
        let fetchCount = await service.sampleFetchCount
        #expect(fetchCount == 0)
    }

    @Test("Only the queried metric is requested; no share/write capability exists")
    func onlyQueriedMetricRead() async throws {
        let service = FakeHealthService()
        _ = try await tool(service: service).execute(
            .init(
                metric: "bodyMass",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ),
            context: context()
        )
        let requests = await service.readRequests
        #expect(requests == [.bodyMass])
        let fetchCount = await service.sampleFetchCount
        #expect(fetchCount == 1)
    }

    @Test("Date, range, limit, cursor and aggregate bounds fail before any query")
    func requestBounds() throws {
        let service = FakeHealthService()
        let readTool = tool(service: service)

        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "steps",
                start: "2026-10-02T00:00:00Z",
                end: "2026-10-01T00:00:00Z"
            ))
        }
        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "steps",
                start: "2026-01-01T00:00:00Z",
                end: "2027-01-03T00:00:00Z"
            ))
        }
        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "steps",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z",
                limit: 201
            ))
        }
        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "steps",
                start: "2026-10-01T00:00:00Z",
                cursor: "ptc1.invalid"
            ))
        }
        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "sleep",
                mode: "aggregate",
                aggregation: "average",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ))
        }
        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "heartRate",
                mode: "aggregate",
                aggregation: "sum",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ))
        }
        #expect(throws: FloeError.self) {
            try readTool.validate(.init(
                metric: "clinicalRecord",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ))
        }
    }

    @Test("Snapshot continuation is stable and task-owned")
    func stableContinuationAndOwner() async throws {
        let service = FakeHealthService()
        let rows = [
            HealthSampleRow.quantity(
                start: Date(timeIntervalSince1970: 1_790_000_000),
                end: Date(timeIntervalSince1970: 1_790_000_100),
                value: 1,
                unit: "count"
            ),
            HealthSampleRow.quantity(
                start: Date(timeIntervalSince1970: 1_790_000_200),
                end: Date(timeIntervalSince1970: 1_790_000_300),
                value: 2,
                unit: "count"
            ),
            HealthSampleRow.quantity(
                start: Date(timeIntervalSince1970: 1_790_000_400),
                end: Date(timeIntervalSince1970: 1_790_000_500),
                value: 3,
                unit: "count"
            )
        ]
        await service.setSampleRows(rows)
        let conversation = UUID()
        let firstContext = context(conversation: conversation)
        let first = try await tool(service: service).execute(
            .init(
                metric: "steps",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z",
                limit: 2
            ),
            context: firstContext
        )
        #expect(first.summary.contains("hasMore=true"))
        let cursor = try #require(field("nextCursor", in: first.summary))
        #expect(cursor != "none")

        // Changing the service rows cannot rewrite the already captured page.
        await service.setSampleRows([
            HealthSampleRow.quantity(
                start: Date(timeIntervalSince1970: 1_790_000_000),
                end: Date(timeIntervalSince1970: 1_790_000_100),
                value: 99,
                unit: "count"
            )
        ])
        let secondContext = context(conversation: conversation)
        let second = try await tool(service: service).execute(
            .init(metric: "steps", limit: 2, cursor: cursor),
            context: secondContext
        )
        #expect(second.summary.contains("cursorPage=true"))
        #expect(second.summary.contains("value=3"))
        #expect(!second.summary.contains("value=99"))

        let otherConversation = try await tool(service: service).execute(
            .init(metric: "steps", limit: 2, cursor: cursor),
            context: context(conversation: UUID())
        )
        #expect(otherConversation.summary.contains("code=cursorNotOwned"))
        #expect(otherConversation.exitStatus == 1)
    }

    @Test("Cancellation returns once and ignores a late service result")
    func cancellationIgnoresLateCallback() async throws {
        let service = FakeHealthService()
        await service.setHoldSamples(true)
        let token = CancellationToken()
        let context = context(cancellation: token)
        let readTool = tool(service: service)

        let task = Task {
            try await readTool.execute(
                .init(
                    metric: "steps",
                    start: "2026-10-01T00:00:00Z",
                    end: "2026-10-02T00:00:00Z"
                ),
                context: context
            )
        }
        var started = false
        for _ in 0..<100 {
            if await service.sampleFetchStarted {
                started = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(started)
        token.cancel()
        let output = try await task.value
        #expect(output.exitStatus == 130)
        #expect(output.summary.contains("status=cancelled"))

        // A late HealthKit/fake callback must not produce a second result.
        await service.finishHeldSamples(
            HealthSampleBatch(
                rows: [
                    HealthSampleRow.quantity(
                        start: Date(timeIntervalSince1970: 1_790_000_000),
                        end: Date(timeIntervalSince1970: 1_790_000_100),
                        value: 999,
                        unit: "count"
                    )
                ],
                truncated: false,
                fetchedCount: 1
            )
        )
        let fetchCount = await service.sampleFetchCount
        #expect(fetchCount == 1)
    }

    @Test("Aggregate output states its real semantics and does not enumerate rows")
    func aggregateSemantics() async throws {
        let service = FakeHealthService()
        await service.setAggregateValue(
            HealthAggregateValue(
                metric: .steps,
                aggregation: .sum,
                value: 1_234,
                unit: "count",
                start: Date(timeIntervalSince1970: 1_790_000_000),
                end: Date(timeIntervalSince1970: 1_790_086_400),
                mostRecentStart: nil,
                mostRecentEnd: nil
            )
        )
        let output = try await tool(service: service).execute(
            .init(
                metric: "steps",
                mode: "aggregate",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ),
            context: context()
        )
        #expect(output.summary.contains("semantics=aggregate"))
        #expect(output.summary.contains("aggregation=sum"))
        #expect(output.summary.contains("value=1234"))
        #expect(output.summary.contains("unit=count"))
        #expect(output.summary.contains("sampleRowsNotEnumerated=true"))
        #expect(!output.summary.contains("\n"))
    }

    @Test("Sleep duplicates are coalesced and same-stage overlap is explicit, never summed")
    func sleepDuplicateAndOverlapSemantics() async throws {
        let service = FakeHealthService()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = [
            HealthSampleRow.sleep(stage: "asleepCore", start: start, end: start.addingTimeInterval(3_600)),
            HealthSampleRow.sleep(stage: "asleepCore", start: start, end: start.addingTimeInterval(3_600)),
            HealthSampleRow.sleep(
                stage: "asleepCore",
                start: start.addingTimeInterval(1_800),
                end: start.addingTimeInterval(5_400)
            ),
            HealthSampleRow.sleep(
                stage: "inBed",
                start: start.addingTimeInterval(-1_800),
                end: start.addingTimeInterval(5_400)
            )
        ]
        await service.setSampleRows(rows)
        let output = try await tool(service: service).execute(
            .init(
                metric: "sleep",
                start: "2026-09-30T20:00:00Z",
                end: "2026-10-02T02:00:00Z",
                limit: 10
            ),
            context: context()
        )
        #expect(output.summary.contains("duplicatesCoalesced=1"))
        #expect(output.summary.contains("sameStageOverlaps=1"))
        #expect(output.summary.contains("semantics=samples"))
        #expect(output.summary.contains("duplicates=2"))
        #expect(output.summary.contains("overlapSameStage=true"))
        #expect(!output.summary.lowercased().contains("asleeptotal"))
        #expect(!output.summary.lowercased().contains("medical"))
    }

    @Test("Foreground and unsupported-device results are distinct")
    func foregroundAndUnavailable() async throws {
        let foreground = try await tool(service: FakeHealthService(), foreground: false).execute(
            .init(
                metric: "steps",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ),
            context: context()
        )
        #expect(foreground.summary.contains("status=foregroundRequired"))
        #expect(foreground.exitStatus == 75)

        let unavailable = try await tool(
            service: FakeHealthService(isAvailable: false)
        ).execute(
            .init(
                metric: "steps",
                start: "2026-10-01T00:00:00Z",
                end: "2026-10-02T00:00:00Z"
            ),
            context: context()
        )
        #expect(unavailable.summary.contains("status=healthDataUnavailable"))
        #expect(unavailable.exitStatus == 77)
    }

    @Test("Activity summaries are reported as daily summaries with goals")
    func activitySummaryRows() async throws {
        let service = FakeHealthService()
        await service.setSampleRows([
            .activitySummary(
                day: "2026-10-01",
                moveKcal: 420,
                exerciseMinutes: 31,
                standHours: 9,
                moveGoalKcal: 500,
                exerciseGoalMinutes: 30,
                standGoalHours: 12,
                paused: false
            )
        ])
        let output = try await tool(service: service).execute(
            .init(
                metric: "activitySummary",
                start: "2026-09-30T14:00:00Z",
                end: "2026-10-02T14:00:00Z"
            ),
            context: context()
        )
        #expect(output.summary.contains("semantics=dailySummaries"))
        #expect(output.summary.contains("kind=activitySummary"))
        #expect(output.summary.contains("moveKcal=420"))
        #expect(output.summary.contains("moveGoalKcal=500"))
        #expect(output.summary.contains("paused=false"))
    }
}

private actor FakeHealthService: HealthDataProviding {
    nonisolated let isAvailable: Bool
    private(set) var readRequests: [HealthMetric] = []
    private(set) var sampleFetchCount = 0
    private var authorizationError: HealthAccessError?
    private var sampleResult: Result<HealthSampleBatch, HealthAccessError>
    private var aggregateResult: Result<HealthAggregateValue, HealthAccessError>
    private var holdSamples = false
    private var pendingSamples: CheckedContinuation<HealthSampleBatch, Error>?
    private var didStartSampleWaiters = false

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        self.sampleResult = .success(
            HealthSampleBatch(rows: [], truncated: false, fetchedCount: 0)
        )
        self.aggregateResult = .success(
            HealthAggregateValue(
                metric: .steps,
                aggregation: .sum,
                value: nil,
                unit: "count",
                start: now,
                end: now.addingTimeInterval(86_400),
                mostRecentStart: nil,
                mostRecentEnd: nil
            )
        )
    }

    func setAuthorizationError(_ error: HealthAccessError?) {
        authorizationError = error
    }

    func setSampleRows(_ rows: [HealthSampleRow], truncated: Bool = false) {
        sampleResult = .success(
            HealthSampleBatch(
                rows: rows,
                truncated: truncated,
                fetchedCount: rows.count
            )
        )
    }

    func setAggregateValue(_ value: HealthAggregateValue) {
        aggregateResult = .success(value)
    }

    func setHoldSamples(_ hold: Bool) {
        holdSamples = hold
    }

    var sampleFetchStarted: Bool {
        didStartSampleWaiters
    }

    func finishHeldSamples(_ batch: HealthSampleBatch) {
        pendingSamples?.resume(returning: batch)
        pendingSamples = nil
    }

    func requestReadAuthorization(
        for metric: HealthMetric,
        cancellation: CancellationToken
    ) async throws {
        _ = cancellation
        readRequests.append(metric)
        if let authorizationError { throw authorizationError }
    }

    func fetchSamples(
        _ query: HealthSampleQuery,
        cancellation: CancellationToken
    ) async throws -> HealthSampleBatch {
        _ = query
        _ = cancellation
        sampleFetchCount += 1
        if holdSamples {
            didStartSampleWaiters = true
            return try await withCheckedThrowingContinuation { continuation in
                pendingSamples = continuation
            }
        }
        return try sampleResult.get()
    }

    func fetchAggregate(
        metric: HealthMetric,
        start: Date,
        end: Date,
        aggregation: HealthAggregation,
        cancellation: CancellationToken
    ) async throws -> HealthAggregateValue {
        _ = metric
        _ = start
        _ = end
        _ = aggregation
        _ = cancellation
        return try aggregateResult.get()
    }

    func fetchActivitySummaries(
        start: Date,
        end: Date,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> HealthSampleBatch {
        _ = start
        _ = end
        _ = maxRows
        _ = cancellation
        return try sampleResult.get()
    }
}
#endif

// FloeApp — the real HealthKit read-only service.
//
// Only the modern async descriptor APIs are used. Every query is bounded by
// a row limit and wrapped in a cancellation/timeout completion gate so a
// late HealthKit result can never resume the tool twice after cancellation.

#if canImport(UIKit) && canImport(HealthKit)
import Foundation
@preconcurrency import HealthKit
import FloeTools

/// Injectable read-only boundary for the health tool and its fake services.
/// There is deliberately no write/share/delete method anywhere in this
/// protocol, so no tool path can request Health write authorization.
protocol HealthDataProviding: Sendable {
    var isAvailable: Bool { get }
    func requestReadAuthorization(
        for metric: HealthMetric,
        cancellation: CancellationToken
    ) async throws
    func fetchSamples(
        _ query: HealthSampleQuery,
        cancellation: CancellationToken
    ) async throws -> HealthSampleBatch
    func fetchAggregate(
        metric: HealthMetric,
        start: Date,
        end: Date,
        aggregation: HealthAggregation,
        cancellation: CancellationToken
    ) async throws -> HealthAggregateValue
    func fetchActivitySummaries(
        start: Date,
        end: Date,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> HealthSampleBatch
}

// MARK: - Completion gate and bounded runner

/// Exactly-once completion for one async operation. The continuation may be
/// attached after the operation already finished (a fast HealthKit error), or
/// finish once while the tool is being cancelled (a late callback); both are
/// handled without a double resume.
final class HealthQueryCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        let ready: Result<T, Error>?
        lock.lock()
        if let result {
            ready = result
        } else {
            ready = nil
            self.continuation = continuation
        }
        lock.unlock()
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Some current HealthKit query-descriptor structs are not declared
/// `Sendable` even though they are immutable and used by exactly one query.
/// This box keeps the @Sendable runner contract without changing the SDK
/// type; the descriptor is never mutated or shared across queries.
private final class HealthQueryDescriptorBox<Descriptor>: @unchecked Sendable {
    let descriptor: Descriptor
    init(_ descriptor: Descriptor) { self.descriptor = descriptor }
}

enum HealthQueryRunner {
    /// Runs one operation with a cancellation poll and a hard deadline. The
    /// returned value/error is exactly one of: operation result, `.cancelled`
    /// or `.timedOut`. A late operation result is discarded by the gate.
    static func run<T: Sendable>(
        cancellation: CancellationToken,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if cancellation.isCancelled { throw HealthAccessError.cancelled }
        let gate = HealthQueryCompletion<T>()
        let worker = Task {
            do {
                gate.finish(.success(try await operation()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        let watcher = Task {
            let deadline = Date().addingTimeInterval(max(1, timeout))
            while !gate.isFinished {
                if cancellation.isCancelled {
                    gate.finish(.failure(HealthAccessError.cancelled))
                    worker.cancel()
                    return
                }
                if Date() >= deadline {
                    gate.finish(.failure(HealthAccessError.timedOut))
                    worker.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer {
            watcher.cancel()
            worker.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
        }
    }
}

// MARK: - Real service

final class HealthKitService: HealthDataProviding, @unchecked Sendable {
    private let store: HKHealthStore
    private let queryTimeout: TimeInterval
    private let authorizationTimeout: TimeInterval

    init(
        store: HKHealthStore = HKHealthStore(),
        queryTimeout: TimeInterval = 20,
        authorizationTimeout: TimeInterval = 120
    ) {
        self.store = store
        self.queryTimeout = queryTimeout
        self.authorizationTimeout = authorizationTimeout
    }

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestReadAuthorization(
        for metric: HealthMetric,
        cancellation: CancellationToken
    ) async throws {
        guard isAvailable else { throw HealthAccessError.unsupportedDevice }
        let readTypes: Set<HKObjectType> = [objectType(for: metric)]
        do {
            try await HealthQueryRunner.run(
                cancellation: cancellation,
                timeout: authorizationTimeout
            ) {
                // Empty share set is explicit: Floe never asks to save health
                // samples, not even as an unused capability.
                try await self.store.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes)
            }
        } catch {
            throw Self.authorizationError(error)
        }
    }

    func fetchSamples(
        _ query: HealthSampleQuery,
        cancellation: CancellationToken
    ) async throws -> HealthSampleBatch {
        guard isAvailable else { throw HealthAccessError.unsupportedDevice }
        let limit = max(1, query.maxRows) + 1
        let predicate = HKQuery.predicateForSamples(
            withStart: query.start,
            end: query.end,
            options: HKQueryOptions()
        )

        do {
            switch query.metric {
            case .sleep:
                let type = HKCategoryType(.sleepAnalysis)
                let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
                    predicates: [.categorySample(type: type, predicate: predicate)],
                    sortDescriptors: [
                        // Fetch the newest bounded window; the renderer sorts
                        // these rows chronologically for overlap semantics.
                        SortDescriptor(\HKCategorySample.startDate, order: .reverse)
                    ],
                    limit: limit
                )
                let samples = try await runQuery(cancellation: cancellation) {
                    try await descriptor.result(for: self.store)
                }
                if cancellation.isCancelled { throw HealthAccessError.cancelled }
                let truncated = samples.count > query.maxRows
                let visible = truncated ? Array(samples.prefix(query.maxRows)) : samples
                let rows = visible.map { sample in
                    HealthSampleRow.sleep(
                        stage: sleepStage(sample.value),
                        start: sample.startDate,
                        end: sample.endDate
                    )
                }
                return HealthSampleBatch(
                    rows: rows,
                    truncated: truncated,
                    fetchedCount: visible.count
                )

            case .workouts:
                let descriptor = HKSampleQueryDescriptor<HKWorkout>(
                    predicates: [.workout(predicate)],
                    sortDescriptors: [
                        SortDescriptor(\HKWorkout.startDate, order: .reverse)
                    ],
                    limit: limit
                )
                let samples = try await runQuery(cancellation: cancellation) {
                    try await descriptor.result(for: self.store)
                }
                if cancellation.isCancelled { throw HealthAccessError.cancelled }
                let truncated = samples.count > query.maxRows
                let visible = truncated ? Array(samples.prefix(query.maxRows)) : samples
                let energyType = HKQuantityType(.activeEnergyBurned)
                let energyUnit = HKUnit(from: "kcal")
                let rows = visible.map { workout in
                    let energy = workout.statistics(for: energyType)?
                        .sumQuantity()?
                        .doubleValue(for: energyUnit)
                    return HealthSampleRow.workout(
                        activity: workoutActivity(workout.workoutActivityType),
                        start: workout.startDate,
                        end: workout.endDate,
                        durationSeconds: workout.duration,
                        activeEnergyKcal: energy
                    )
                }
                return HealthSampleBatch(
                    rows: rows,
                    truncated: truncated,
                    fetchedCount: visible.count
                )

            case .activitySummary:
                // Activity summaries are day-granular and handled by their own
                // bounded query below.
                return try await fetchActivitySummaries(
                    start: query.start,
                    end: query.end,
                    maxRows: query.maxRows,
                    cancellation: cancellation
                )

            default:
                guard let type = quantityType(for: query.metric),
                      let unit = unit(for: query.metric) else {
                    throw HealthAccessError.invalidQuery
                }
                let descriptor = HKSampleQueryDescriptor<HKQuantitySample>(
                    predicates: [.quantitySample(type: type, predicate: predicate)],
                    sortDescriptors: [
                        SortDescriptor(\HKQuantitySample.endDate, order: .reverse)
                    ],
                    limit: limit
                )
                let samples = try await runQuery(cancellation: cancellation) {
                    try await descriptor.result(for: self.store)
                }
                if cancellation.isCancelled { throw HealthAccessError.cancelled }
                let truncated = samples.count > query.maxRows
                let visible = truncated ? Array(samples.prefix(query.maxRows)) : samples
                let rows = visible.map { sample in
                    HealthSampleRow.quantity(
                        start: sample.startDate,
                        end: sample.endDate,
                        value: sample.quantity.doubleValue(for: unit),
                        unit: query.metric.canonicalUnit
                    )
                }
                return HealthSampleBatch(
                    rows: rows,
                    truncated: truncated,
                    fetchedCount: visible.count
                )
            }
        } catch {
            if Self.isNoData(error) {
                return HealthSampleBatch(rows: [], truncated: false, fetchedCount: 0)
            }
            throw Self.queryError(error)
        }
    }

    func fetchAggregate(
        metric: HealthMetric,
        start: Date,
        end: Date,
        aggregation: HealthAggregation,
        cancellation: CancellationToken
    ) async throws -> HealthAggregateValue {
        guard isAvailable else { throw HealthAccessError.unsupportedDevice }
        guard metric.supportsAggregate,
              metric.allowedAggregations.contains(aggregation),
              let type = quantityType(for: metric),
              let unit = unit(for: metric) else {
            throw HealthAccessError.invalidQuery
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: HKQueryOptions()
        )
        let descriptor = HealthQueryDescriptorBox(
            HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: type, predicate: predicate),
                options: statisticsOptions(for: aggregation)
            )
        )
        do {
            let statistics = try await runQuery(cancellation: cancellation) {
                try await descriptor.descriptor.result(for: self.store)
            }
            if cancellation.isCancelled { throw HealthAccessError.cancelled }
            let interval = statistics?.mostRecentQuantityDateInterval()
            return HealthAggregateValue(
                metric: metric,
                aggregation: aggregation,
                value: aggregateValue(
                    statistics: statistics,
                    aggregation: aggregation,
                    unit: unit
                ),
                unit: metric.canonicalUnit,
                start: start,
                end: end,
                mostRecentStart: interval?.start,
                mostRecentEnd: interval?.end
            )
        } catch {
            if Self.isNoData(error) {
                return HealthAggregateValue(
                    metric: metric,
                    aggregation: aggregation,
                    value: nil,
                    unit: metric.canonicalUnit,
                    start: start,
                    end: end,
                    mostRecentStart: nil,
                    mostRecentEnd: nil
                )
            }
            throw Self.queryError(error)
        }
    }

    func fetchActivitySummaries(
        start: Date,
        end: Date,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> HealthSampleBatch {
        guard isAvailable else { throw HealthAccessError.unsupportedDevice }
        let calendar = Calendar.current
        var startComponents = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: start
        )
        startComponents.calendar = calendar
        // The predicate's end day is inclusive. Subtract one second so an
        // exclusive ISO end at midnight does not pull in the following day.
        let inclusiveEnd = max(start, end.addingTimeInterval(-1))
        var endComponents = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: inclusiveEnd
        )
        endComponents.calendar = calendar
        let predicate = HKQuery.predicate(
            forActivitySummariesBetweenStart: startComponents,
            end: endComponents
        )
        let descriptor = HealthQueryDescriptorBox(
            HKActivitySummaryQueryDescriptor(predicate: predicate)
        )
        do {
            let summaries = try await runQuery(cancellation: cancellation) {
                try await descriptor.descriptor.result(for: self.store)
            }
            if cancellation.isCancelled { throw HealthAccessError.cancelled }
            let sorted = summaries.sorted { lhs, rhs in
                let left = lhs.dateComponents(for: calendar)
                let right = rhs.dateComponents(for: calendar)
                if left.year != right.year { return (left.year ?? 0) < (right.year ?? 0) }
                if left.month != right.month { return (left.month ?? 0) < (right.month ?? 0) }
                return (left.day ?? 0) < (right.day ?? 0)
            }
            let truncated = sorted.count > maxRows
            let visible = truncated ? Array(sorted.prefix(maxRows)) : sorted
            let energyUnit = HKUnit(from: "kcal")
            let minuteUnit = HKUnit(from: "min")
            let countUnit = HKUnit(from: "count")
            let rows = visible.map { summary -> HealthSampleRow in
                let components = summary.dateComponents(for: calendar)
                return HealthSampleRow.activitySummary(
                    day: dayString(components),
                    moveKcal: summary.activeEnergyBurned.doubleValue(for: energyUnit),
                    exerciseMinutes: summary.appleExerciseTime.doubleValue(for: minuteUnit),
                    standHours: summary.appleStandHours.doubleValue(for: countUnit),
                    moveGoalKcal: summary.activeEnergyBurnedGoal.doubleValue(for: energyUnit),
                    exerciseGoalMinutes: summary.exerciseTimeGoal?.doubleValue(for: minuteUnit),
                    standGoalHours: summary.standHoursGoal?.doubleValue(for: countUnit),
                    paused: summary.isPaused
                )
            }
            return HealthSampleBatch(
                rows: rows,
                truncated: truncated,
                fetchedCount: visible.count
            )
        } catch {
            if Self.isNoData(error) {
                return HealthSampleBatch(rows: [], truncated: false, fetchedCount: 0)
            }
            throw Self.queryError(error)
        }
    }

    // MARK: HealthKit mapping

    private func runQuery<T: Sendable>(
        cancellation: CancellationToken,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await HealthQueryRunner.run(
            cancellation: cancellation,
            timeout: queryTimeout,
            operation: operation
        )
    }

    private func objectType(for metric: HealthMetric) -> HKObjectType {
        switch metric {
        case .sleep:
            HKCategoryType(.sleepAnalysis)
        case .workouts:
            HKObjectType.workoutType()
        case .activitySummary:
            HKObjectType.activitySummaryType()
        default:
            quantityType(for: metric) ?? HKQuantityType(.stepCount)
        }
    }

    private func quantityType(for metric: HealthMetric) -> HKQuantityType? {
        switch metric {
        case .steps: HKQuantityType(.stepCount)
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .heartRate: HKQuantityType(.heartRate)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .bodyMass: HKQuantityType(.bodyMass)
        case .oxygenSaturation: HKQuantityType(.oxygenSaturation)
        case .heartRateVariability: HKQuantityType(.heartRateVariabilitySDNN)
        case .sleep, .workouts, .activitySummary: nil
        }
    }

    private func unit(for metric: HealthMetric) -> HKUnit? {
        switch metric {
        case .steps: HKUnit(from: "count")
        case .activeEnergy: HKUnit(from: "kcal")
        case .heartRate, .restingHeartRate: HKUnit(from: "count/min")
        case .bodyMass: HKUnit(from: "kg")
        case .oxygenSaturation: HKUnit(from: "%")
        case .heartRateVariability: HKUnit(from: "ms")
        case .sleep, .workouts, .activitySummary: nil
        }
    }

    private func statisticsOptions(for aggregation: HealthAggregation) -> HKStatisticsOptions {
        switch aggregation {
        case .sum: .cumulativeSum
        case .average: .discreteAverage
        case .minimum: .discreteMin
        case .maximum: .discreteMax
        case .mostRecent: .mostRecent
        }
    }

    private func aggregateValue(
        statistics: HKStatistics?,
        aggregation: HealthAggregation,
        unit: HKUnit
    ) -> Double? {
        guard let statistics else { return nil }
        switch aggregation {
        case .sum:
            return statistics.sumQuantity()?.doubleValue(for: unit)
        case .average:
            return statistics.averageQuantity()?.doubleValue(for: unit)
        case .minimum:
            return statistics.minimumQuantity()?.doubleValue(for: unit)
        case .maximum:
            return statistics.maximumQuantity()?.doubleValue(for: unit)
        case .mostRecent:
            return statistics.mostRecentQuantity()?.doubleValue(for: unit)
        }
    }

    private func sleepStage(_ rawValue: Int) -> String {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: rawValue) else {
            return "unknown"
        }
        switch stage {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        @unknown default: return "unknown"
        }
    }

    private func workoutActivity(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .traditionalStrengthTraining: return "traditionalStrengthTraining"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stairClimbing"
        case .coreTraining: return "coreTraining"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        case .mixedCardio: return "mixedCardio"
        case .pilates: return "pilates"
        case .cardioDance: return "cardioDance"
        case .socialDance: return "socialDance"
        case .golf: return "golf"
        case .tennis: return "tennis"
        case .basketball: return "basketball"
        case .soccer: return "soccer"
        case .other: return "other"
        default: return "activityType\(type.rawValue)"
        }
    }

    private func dayString(_ components: DateComponents) -> String {
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return "unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: Error mapping

    private static func isNoData(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == HKErrorDomain,
              let code = HKError.Code(rawValue: ns.code) else { return false }
        return code == .errorNoData
    }

    private static func authorizationError(_ error: Error) -> HealthAccessError {
        if let error = error as? HealthAccessError { return error }
        let ns = error as NSError
        guard ns.domain == HKErrorDomain,
              let code = HKError.Code(rawValue: ns.code) else {
            return .queryFailed(code: ns.code)
        }
        switch code {
        case .errorHealthDataUnavailable: return .unsupportedDevice
        case .errorHealthDataRestricted: return .restricted
        case .errorInvalidArgument: return .invalidQuery
        case .errorAuthorizationDenied, .errorRequiredAuthorizationDenied:
            return .authorizationRequestRejected
        case .errorAuthorizationNotDetermined: return .authorizationNotRequested
        case .errorDatabaseInaccessible: return .databaseInaccessible
        case .errorUserCanceled: return .authorizationRequestCancelled
        case .errorNoData: return .noData
        default: return .queryFailed(code: ns.code)
        }
    }

    private static func queryError(_ error: Error) -> HealthAccessError {
        if let error = error as? HealthAccessError { return error }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        guard ns.domain == HKErrorDomain,
              let code = HKError.Code(rawValue: ns.code) else {
            return .queryFailed(code: ns.code)
        }
        switch code {
        case .errorHealthDataUnavailable: return .unsupportedDevice
        case .errorHealthDataRestricted: return .restricted
        case .errorInvalidArgument: return .invalidQuery
        case .errorAuthorizationDenied, .errorRequiredAuthorizationDenied:
            return .authorizationDenied
        case .errorAuthorizationNotDetermined: return .authorizationNotRequested
        case .errorDatabaseInaccessible: return .databaseInaccessible
        case .errorUserCanceled: return .cancelled
        case .errorNoData: return .noData
        case .errorBackgroundWorkoutSessionNotAllowed: return .foregroundRequired
        default: return .queryFailed(code: ns.code)
        }
    }
}
#endif

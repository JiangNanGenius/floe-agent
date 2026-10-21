// FloeApp — bounded read-only HealthKit contracts.
//
// This directory is intentionally separate from AppleSystemTools.swift so the
// HealthKit/CoreNFC services and their compiled tools can be reviewed and
// registered without editing the existing Apple tool catalog implementation.
//
// Security model:
//   * one approved metric per call, read-only, no write/share types;
//   * the date interval and row/page/property bounds are validated before a
//     query is started;
//   * HealthKit read authorization is deliberately not disclosed by the OS.
//     A successful authorization request and an empty result are therefore
//     reported as "grant not disclosed", never as granted or denied;
//   * no health rows are written to a health database, notification store or
//     log. The only continuation state is the existing bounded in-memory
//     personal-tool snapshot store, owned by the task that started it.

#if canImport(UIKit) && canImport(HealthKit)
import Foundation
import FloeTools

/// The finite health metrics Floe may read. Clinical records, symptoms,
/// mental-health assessments, medications, ECG and any other type are not
/// part of this catalog and cannot be selected by model output.
enum HealthMetric: String, CaseIterable, Codable, Sendable {
    case steps
    case activeEnergy
    case heartRate
    case restingHeartRate
    case sleep
    case workouts
    case activitySummary
    case bodyMass
    case oxygenSaturation
    case heartRateVariability

    /// HealthKit canonical unit used for returned values. `percent` is the
    /// HealthKit 0...1 fraction, not a pre-multiplied display percentage.
    var canonicalUnit: String {
        switch self {
        case .steps: "count"
        case .activeEnergy: "kcal"
        case .heartRate, .restingHeartRate: "count/min"
        case .sleep: "seconds"
        case .workouts: "seconds"
        case .activitySummary: "mixed"
        case .bodyMass: "kg"
        case .oxygenSaturation: "percent"
        case .heartRateVariability: "ms"
        }
    }

    /// Only cumulative quantity types may be summed. Discrete measurements
    /// (heart rate, body mass, oxygen saturation, HRV) reject `sum` so a
    /// meaningless "total heart rate" can never be reported.
    var isCumulativeQuantity: Bool {
        switch self {
        case .steps, .activeEnergy: true
        default: false
        }
    }

    var supportsAggregate: Bool {
        switch self {
        case .steps, .activeEnergy, .heartRate, .restingHeartRate,
             .bodyMass, .oxygenSaturation, .heartRateVariability:
            true
        case .sleep, .workouts, .activitySummary:
            // Sleep stages and workout records have source/overlap semantics;
            // a single aggregate would silently invent a medical summary.
            false
        }
    }

    var allowedAggregations: Set<HealthAggregation> {
        if !supportsAggregate { return [] }
        return isCumulativeQuantity
            ? [.sum]
            : [.average, .minimum, .maximum, .mostRecent]
    }

    var sortDescription: String {
        switch self {
        case .sleep: "startDateAscending"
        case .workouts: "startDateDescending"
        case .activitySummary: "dayAscending"
        default: "endDateDescending"
        }
    }
}

enum HealthQueryMode: String, CaseIterable, Codable, Sendable {
    case samples
    case aggregate
}

enum HealthAggregation: String, CaseIterable, Codable, Sendable {
    case sum
    case average
    case minimum
    case maximum
    case mostRecent
}

/// One bounded query handed to the service. `maxRows + 1` is fetched by the
/// real service so truncation is observable rather than silently assumed.
struct HealthSampleQuery: Sendable, Equatable {
    var metric: HealthMetric
    var start: Date
    var end: Date
    var maxRows: Int
}

enum HealthRowKind: String, Sendable {
    case quantity
    case sleep
    case workout
    case activitySummary
}

/// One rendered health row. Optional fields are mutually exclusive by kind;
/// keeping one struct avoids a heterogeneous `[HKSample]` crossing the tool
/// boundary while preserving each row's real semantics.
struct HealthSampleRow: Sendable, Equatable {
    var kind: HealthRowKind
    var start: Date? = nil
    var end: Date? = nil
    var value: Double? = nil
    var unit: String? = nil
    var stage: String? = nil
    var activity: String? = nil
    var durationSeconds: Double? = nil
    var activeEnergyKcal: Double? = nil
    var summaryDay: String? = nil
    var moveKcal: Double? = nil
    var exerciseMinutes: Double? = nil
    var standHours: Double? = nil
    var moveGoalKcal: Double? = nil
    var exerciseGoalMinutes: Double? = nil
    var standGoalHours: Double? = nil
    var paused: Bool? = nil

    static func quantity(
        start: Date,
        end: Date,
        value: Double,
        unit: String
    ) -> HealthSampleRow {
        HealthSampleRow(
            kind: .quantity,
            start: start,
            end: end,
            value: value,
            unit: unit
        )
    }

    static func sleep(stage: String, start: Date, end: Date) -> HealthSampleRow {
        HealthSampleRow(
            kind: .sleep,
            start: start,
            end: end,
            stage: stage
        )
    }

    static func workout(
        activity: String,
        start: Date,
        end: Date,
        durationSeconds: Double,
        activeEnergyKcal: Double?
    ) -> HealthSampleRow {
        HealthSampleRow(
            kind: .workout,
            start: start,
            end: end,
            activity: activity,
            durationSeconds: durationSeconds,
            activeEnergyKcal: activeEnergyKcal
        )
    }

    static func activitySummary(
        day: String,
        moveKcal: Double,
        exerciseMinutes: Double,
        standHours: Double,
        moveGoalKcal: Double?,
        exerciseGoalMinutes: Double?,
        standGoalHours: Double?,
        paused: Bool
    ) -> HealthSampleRow {
        HealthSampleRow(
            kind: .activitySummary,
            summaryDay: day,
            moveKcal: moveKcal,
            exerciseMinutes: exerciseMinutes,
            standHours: standHours,
            moveGoalKcal: moveGoalKcal,
            exerciseGoalMinutes: exerciseGoalMinutes,
            standGoalHours: standGoalHours,
            paused: paused
        )
    }
}

struct HealthSampleBatch: Sendable, Equatable {
    var rows: [HealthSampleRow]
    /// More rows existed in the requested interval than the bounded snapshot
    /// fetched. The returned rows are a stable prefix, never a random slice.
    var truncated: Bool
    var fetchedCount: Int
}

struct HealthAggregateValue: Sendable, Equatable {
    var metric: HealthMetric
    var aggregation: HealthAggregation
    var value: Double?
    var unit: String
    var start: Date
    var end: Date
    var mostRecentStart: Date?
    var mostRecentEnd: Date?
}

/// Stable, secret-free failures. The tool reports these as explicit status
/// lines instead of an empty success. No associated value contains health
/// content.
enum HealthAccessError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedDevice
    case restricted
    case authorizationNotRequested
    case authorizationRequestCancelled
    case authorizationRequestRejected
    case authorizationDenied
    case databaseInaccessible
    case foregroundRequired
    case cancelled
    case timedOut
    case noData
    case invalidQuery
    case queryFailed(code: Int)

    var status: String {
        switch self {
        case .unsupportedDevice: "healthDataUnavailable"
        case .restricted: "healthDataRestricted"
        case .authorizationNotRequested: "authorizationRequired"
        case .authorizationRequestCancelled: "authorizationRequestCancelled"
        case .authorizationRequestRejected: "authorizationRequestRejected"
        case .authorizationDenied: "authorizationDenied"
        case .databaseInaccessible: "databaseInaccessible"
        case .foregroundRequired: "foregroundRequired"
        case .cancelled: "cancelled"
        case .timedOut: "timedOut"
        case .noData: "noData"
        case .invalidQuery: "invalidQuery"
        case .queryFailed: "queryFailed"
        }
    }

    var exitStatus: Int32 {
        switch self {
        case .cancelled: 130
        case .timedOut: 124
        case .foregroundRequired: 75
        case .unsupportedDevice, .restricted, .authorizationNotRequested,
             .authorizationRequestCancelled, .authorizationRequestRejected,
             .authorizationDenied:
            77
        case .databaseInaccessible: 75
        case .invalidQuery: 64
        case .noData, .queryFailed: 1
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            "Health data is not available on this device."
        case .restricted:
            "Health data is restricted by this device's configuration."
        case .authorizationNotRequested:
            "Health authorization has not been requested for this metric."
        case .authorizationRequestCancelled:
            "The Health authorization request was cancelled; no data was queried."
        case .authorizationRequestRejected:
            "The Health authorization request did not complete; no data was queried."
        case .authorizationDenied:
            "HealthKit denied access for this metric; no data was returned."
        case .databaseInaccessible:
            "Health data is protected while the device is locked or its protected data is unavailable."
        case .foregroundRequired:
            "Keep Floe in the foreground while reading or scanning."
        case .cancelled:
            "The health query was cancelled."
        case .timedOut:
            "The health query timed out."
        case .noData:
            "No data is available for the requested interval."
        case .invalidQuery:
            "The health query arguments are invalid."
        case .queryFailed(let code):
            "HealthKit could not complete the query (code \(code))."
        }
    }
}
#endif

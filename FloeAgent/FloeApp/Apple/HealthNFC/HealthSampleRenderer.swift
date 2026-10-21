// FloeApp — deterministic rendering for bounded health rows.
//
// The renderer is deliberately separate from HealthKit: prepared tests can
// exercise duplicate/overlap/semantics handling with plain rows. It never
// sums different sleep stages or sources into a medical conclusion.

#if canImport(UIKit) && canImport(HealthKit)
import Foundation

enum HealthNumberFormat {
    /// Stable machine-readable number with at most three decimals and no
    /// locale-dependent decimal separator.
    static func string(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "none" }
        if abs(value) < 0.0005 { return "0" }
        var text = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

enum HealthDates {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let utc = TimeZone(secondsFromGMT: 0) {
            formatter.timeZone = utc
        }
        return formatter.string(from: date)
    }
}

struct PreparedHealthRows: Equatable, Sendable {
    var lines: [String]
    var rawRowCount: Int
    var duplicatesCoalesced: Int
    var sameStageOverlaps: Int
    var semantics: String
    var sortDescription: String
}

enum HealthSampleRenderer {
    static func prepare(
        _ rows: [HealthSampleRow],
        metric: HealthMetric
    ) -> PreparedHealthRows {
        if metric == .sleep {
            return prepareSleep(rows)
        }
        let lines = rows.map(render)
        return PreparedHealthRows(
            lines: lines,
            rawRowCount: rows.count,
            duplicatesCoalesced: 0,
            sameStageOverlaps: 0,
            semantics: metric == .activitySummary ? "dailySummaries" : "samples",
            sortDescription: metric.sortDescription
        )
    }

    /// Sleep rows are chronological. Exact duplicate rows (same stage and
    /// interval, possibly reported by more than one source) are coalesced and
    /// counted. Overlap is marked only between rows of the SAME stage; normal
    /// `inBed`/`asleepCore` nesting is not mislabeled, and no durations are
    /// added together.
    private static func prepareSleep(_ rows: [HealthSampleRow]) -> PreparedHealthRows {
        let sorted = rows
            .filter { $0.kind == .sleep }
            .sorted { lhs, rhs in
                let lhsStart = lhs.start ?? .distantPast
                let rhsStart = rhs.start ?? .distantPast
                if lhsStart != rhsStart { return lhsStart < rhsStart }
                let lhsEnd = lhs.end ?? .distantPast
                let rhsEnd = rhs.end ?? .distantPast
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                return (lhs.stage ?? "") < (rhs.stage ?? "")
            }

        struct Coalesced {
            var row: HealthSampleRow
            var duplicates: Int
            var overlapSameStage: Bool
        }

        var coalesced: [Coalesced] = []
        for row in sorted {
            if let last = coalesced.last, sameSleepIdentity(last.row, row) {
                coalesced[coalesced.count - 1].duplicates += 1
                continue
            }
            coalesced.append(Coalesced(row: row, duplicates: 1, overlapSameStage: false))
        }

        var previousEndByStage: [String: Date] = [:]
        var overlaps = 0
        for index in coalesced.indices {
            let row = coalesced[index].row
            guard let stage = row.stage else { continue }
            if let start = row.start,
               let previousEnd = previousEndByStage[stage],
               start < previousEnd {
                coalesced[index].overlapSameStage = true
                overlaps += 1
            }
            if let end = row.end {
                previousEndByStage[stage] = max(previousEndByStage[stage] ?? .distantPast, end)
            }
        }

        let duplicates = coalesced.reduce(0) { $0 + ($1.duplicates - 1) }
        let lines = coalesced.map { item -> String in
            let row = item.row
            var fields = [
                "kind=sleep",
                "stage=\(row.stage ?? "unknown")",
                "start=\(HealthDates.iso(row.start ?? .distantPast))",
                "end=\(HealthDates.iso(row.end ?? .distantPast))",
                "durationSeconds=\(HealthNumberFormat.string(duration(of: row)))",
                "duplicates=\(item.duplicates)",
                "overlapSameStage=\(item.overlapSameStage)"
            ]
            if item.duplicates > 1 { fields.append("duplicateCoalesced=true") }
            return fields.joined(separator: " ")
        }

        return PreparedHealthRows(
            lines: lines,
            rawRowCount: rows.count,
            duplicatesCoalesced: duplicates,
            sameStageOverlaps: overlaps,
            semantics: "samples",
            sortDescription: HealthMetric.sleep.sortDescription
        )
    }

    private static func sameSleepIdentity(
        _ lhs: HealthSampleRow,
        _ rhs: HealthSampleRow
    ) -> Bool {
        lhs.stage == rhs.stage && lhs.start == rhs.start && lhs.end == rhs.end
    }

    private static func duration(of row: HealthSampleRow) -> Double? {
        guard let start = row.start, let end = row.end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    private static func render(_ row: HealthSampleRow) -> String {
        switch row.kind {
        case .quantity:
            return [
                "kind=quantity",
                "start=\(HealthDates.iso(row.start ?? .distantPast))",
                "end=\(HealthDates.iso(row.end ?? .distantPast))",
                "value=\(HealthNumberFormat.string(row.value))",
                "unit=\(row.unit ?? "unknown")"
            ].joined(separator: " ")
        case .sleep:
            return [
                "kind=sleep",
                "stage=\(row.stage ?? "unknown")",
                "start=\(HealthDates.iso(row.start ?? .distantPast))",
                "end=\(HealthDates.iso(row.end ?? .distantPast))",
                "durationSeconds=\(HealthNumberFormat.string(duration(of: row)))"
            ].joined(separator: " ")
        case .workout:
            return [
                "kind=workout",
                "activity=\(row.activity ?? "unknown")",
                "start=\(HealthDates.iso(row.start ?? .distantPast))",
                "end=\(HealthDates.iso(row.end ?? .distantPast))",
                "durationSeconds=\(HealthNumberFormat.string(row.durationSeconds))",
                "activeEnergyKcal=\(HealthNumberFormat.string(row.activeEnergyKcal))"
            ].joined(separator: " ")
        case .activitySummary:
            var fields = [
                "kind=activitySummary",
                "day=\(row.summaryDay ?? "unknown")",
                "moveKcal=\(HealthNumberFormat.string(row.moveKcal))",
                "exerciseMinutes=\(HealthNumberFormat.string(row.exerciseMinutes))",
                "standHours=\(HealthNumberFormat.string(row.standHours))",
                "paused=\(row.paused == true)"
            ]
            if let goal = row.moveGoalKcal {
                fields.append("moveGoalKcal=\(HealthNumberFormat.string(goal))")
            }
            if let goal = row.exerciseGoalMinutes {
                fields.append("exerciseGoalMinutes=\(HealthNumberFormat.string(goal))")
            }
            if let goal = row.standGoalHours {
                fields.append("standGoalHours=\(HealthNumberFormat.string(goal))")
            }
            return fields.joined(separator: " ")
        }
    }
}
#endif

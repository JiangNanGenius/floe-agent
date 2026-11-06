// SPDX-License-Identifier: MPL-2.0
import Foundation

public extension DiagramDocument {
    /// Calendar-day project dates use an explicit file timezone; old/date-only exchange files default to UTC.
    var workCalendar: DiagramWorkCalendar { .init(timeZone: TimeZone(identifier: metadata["calendarTimeZone"] ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!) }
}

public struct DiagramWorkCalendar: Sendable {
    public var calendar: Calendar
    public var workingWeekdays: Set<Int>
    public var holidays: Set<Date>
    public init(timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!, workingWeekdays: Set<Int> = [2, 3, 4, 5, 6], holidays: Set<Date> = []) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        self.calendar = calendar; self.workingWeekdays = workingWeekdays
        self.holidays = Set(holidays.map { calendar.startOfDay(for: $0) })
    }
    public func isWorkingDay(_ date: Date) -> Bool { workingWeekdays.contains(calendar.component(.weekday, from: date)) && !holidays.contains(calendar.startOfDay(for: date)) }
    public func nextWorkingDay(_ date: Date) throws -> Date {
        guard !workingWeekdays.isEmpty, workingWeekdays.isSubset(of: Set(1...7)) else { throw DiagramError.invalid("work calendar") }
        var d = calendar.startOfDay(for: date), tries = 0
        while !isWorkingDay(d) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: d), tries < 10_000 else { throw DiagramError.invalid("calendar range") }
            d = next; tries += 1
        }
        return d
    }
    public func addingWorkingDays(_ days: Int, to date: Date) throws -> Date {
        guard abs(days) <= 100_000 else { throw DiagramError.invalid("schedule duration") }
        var d = try nextWorkingDay(date), remaining = abs(days)
        while remaining > 0 {
            guard let next = calendar.date(byAdding: .day, value: days < 0 ? -1 : 1, to: d) else { throw DiagramError.invalid("calendar range") }
            d = next; if isWorkingDay(d) { remaining -= 1 }
        }
        return d
    }
}
public struct DiagramTaskRange: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}
public enum DiagramPlanning {
    public static func board(_ document: DiagramDocument) -> [DiagramTaskStatus: [DiagramTask]] {
        Dictionary(grouping: document.tasks, by: \.status)
    }
    /// Parent progress is the mean progress of leaf tasks; each leaf counts once.
    public static func rollups(_ document: DiagramDocument) throws -> [UUID: Double] {
        try document.validate()
        let children = Dictionary(grouping: document.tasks.filter { $0.parentID != nil }, by: { $0.parentID! })
        let tasks = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, $0) })
        var pending = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, children[$0.id]?.count ?? 0) })
        var queue = document.tasks.filter { pending[$0.id] == 0 }.map(\.id), cursor = 0
        var totals: [UUID: (Double, Int)] = [:], result: [UUID: Double] = [:]
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            let value = totals[id] ?? (tasks[id]!.status == .done ? 1 : tasks[id]!.progress, 1)
            result[id] = value.0 / Double(value.1)
            if let parent = tasks[id]?.parentID {
                let old = totals[parent] ?? (0, 0); totals[parent] = (old.0 + value.0, old.1 + value.1)
                pending[parent, default: 0] -= 1
                if pending[parent] == 0 { queue.append(parent) }
            }
        }
        return result
    }
    /// Explicit finish-to-start calculation. It returns a proposal; it never saves or executes anything.
    public static func schedule(_ document: DiagramDocument, from baseline: Date,
                                workCalendar: DiagramWorkCalendar = .init()) throws -> [UUID: DiagramTaskRange] {
        try document.validate()
        let tasks = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, $0) })
        let incoming = Dictionary(grouping: document.dependencies, by: \.successorID)
        let outgoing = Dictionary(grouping: document.dependencies, by: \.predecessorID)
        var degrees = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, incoming[$0.id]?.count ?? 0) })
        var queue = document.tasks.filter { degrees[$0.id] == 0 }.map(\.id), cursor = 0
        var result: [UUID: DiagramTaskRange] = [:]
        while cursor < queue.count {
            try Task.checkCancellation()
            let id = queue[cursor]; cursor += 1
            let task = tasks[id]!
            var start = try workCalendar.nextWorkingDay(max(baseline, task.start ?? baseline))
            for dependency in incoming[id] ?? [] {
                if let predecessor = result[dependency.predecessorID] {
                    start = max(start, try workCalendar.addingWorkingDays(dependency.lagDays + 1, to: predecessor.end))
                }
            }
            let rawDays = task.start.flatMap { a in task.end.map { max(0, workCalendar.calendar.dateComponents([.day], from: a, to: $0).day ?? 0) } } ?? 0
            var duration = 0
            if let a = task.start, let b = task.end {
                var d = try workCalendar.nextWorkingDay(a)
                while d < b && duration <= rawDays {
                    let next = try workCalendar.addingWorkingDays(1, to: d)
                    if next <= b { duration += 1 }; d = next
                }
            }
            result[id] = .init(start: start, end: try workCalendar.addingWorkingDays(duration, to: start))
            for edge in outgoing[id] ?? [] { degrees[edge.successorID, default: 0] -= 1; if degrees[edge.successorID] == 0 { queue.append(edge.successorID) } }
        }
        return result
    }
    public static func scheduleEdits(_ document: DiagramDocument, ranges: [UUID: DiagramTaskRange]) -> [DiagramEdit] {
        document.tasks.compactMap { old in
            guard let range = ranges[old.id] else { return nil }
            var task = old; task.start = range.start; task.end = range.end
            return .upsertTask(task)
        }
    }
}

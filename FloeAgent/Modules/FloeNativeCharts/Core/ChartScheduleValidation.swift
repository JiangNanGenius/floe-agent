// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartValidationContext {
    mutating func validateSchedule(_ d: ChartDocument, path: String, facets: [String]) throws -> Int {
        let p = path + ".data.records"
        switch d.data {
        case .events(let events):
            try chartCheck(!events.isEmpty,p,"needs events"); try consume(events.count,at:p)
            try identify(events.map(\.id),path:p,facets:facets)
            for event in events {
                try chartText(event.label,p + ".label")
                let start = try ChartDates.instant(event.time,path:p + ".time")
                if let end = event.end { try chartCheck(try ChartDates.instant(end,path:p + ".end") >= start,p + ".end","end precedes start") }
            }
        case .tasks(let tasks):
            try chartCheck(!tasks.isEmpty,p,"needs tasks"); try consume(tasks.count,at:p)
            try identify(tasks.map(\.id),path:p,facets:facets)
            let taskIDs = Set(tasks.map(\.id)); var links: [(String,String)] = []
            for task in tasks {
                try chartText(task.label,p + ".label")
                let start = try ChartDates.instant(task.start,path:p + ".start")
                let end = try ChartDates.instant(task.end,path:p + ".end")
                try chartCheck(end >= start,p + ".end","end precedes start")
                try chartCheck((task.milestone == true) == (start == end),p + ".milestone","zero-duration tasks must be explicit milestones; milestones cannot span time")
                if let progress = task.progress { try chartCheck(progress.isFinite && (0...1).contains(progress),p + ".progress","must be between zero and one") }
                let dependencies = task.dependsOn ?? []
                try chartCheck(dependencies.count <= ChartLimits.graphEdges && Set(dependencies).count == dependencies.count,p + ".dependsOn","duplicate or oversized dependency list")
                try consume(dependencies.count,at:p + ".dependsOn")
                for id in dependencies {
                    try chartCheck(id != task.id && taskIDs.contains(id),p + ".dependsOn","dependency must name another existing task")
                    links.append((id,task.id))
                }
            }
            try chartDAG(taskIDs,links:links,path:p + ".dependsOn")
        case .calendar(let values):
            try chartCheck(!values.isEmpty,p,"needs calendar values"); try consume(values.count,at:p)
            try identify(values.map(\.id),path:p,facets:facets)
            var calendar = Calendar(identifier:.gregorian)
            calendar.timeZone = TimeZone(identifier:d.options.timeZone ?? "UTC")!
            var days: Set<String> = []
            for value in values {
                try chartFinite(value.value,p + ".value")
                let key: String
                switch value.day {
                case .localDate(let text): _ = try ChartDates.localDate(text,path:p + ".day"); key = text
                case .instant(let text):
                    let date = try ChartDates.instant(text,path:p + ".day")
                    let parts = calendar.dateComponents([.year,.month,.day],from:date)
                    key = String(format:"%04d-%02d-%02d",parts.year!,parts.month!,parts.day!)
                default: throw ChartIssue(path:p + ".day",problem:"calendar entries require instant or localDate")
                }
                if !days.insert(key).inserted { try chartCheck(d.options.aggregation != nil,path + ".options.aggregation","multiple records on one local day require explicit sum/mean/count/last") }
            }
        default: throw ChartIssue(path:p,problem:"not a schedule payload")
        }
        return 1
    }
}

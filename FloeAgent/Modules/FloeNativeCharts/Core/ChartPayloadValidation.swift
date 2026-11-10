// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartValidationContext {
    mutating func validatePayload(_ d: ChartDocument, path: String, facets: [String]) throws -> Int {
        let p = path + ".data.records"
        switch d.data {
        case .cartesian(let rows):
            try chartCheck(!rows.isEmpty,p,"needs records"); try consume(rows.count,at:p)
            try identify(rows.map(\.id),path:p,facets:facets)
            var xKinds: Set<ChartCoordinate.Kind> = []
            for (i,row) in rows.enumerated() {
                let at = "\(p)[\(i)]"
                try coordinate(row.x,path:at + ".x"); xKinds.insert(row.x.kind)
                try series(row.seriesID,document:d,path:at + ".seriesID")
                if let label = row.label { try chartText(label,at + ".label",nonempty:false) }
                if let group = row.group { try chartText(group,at + ".group") }
                if let y = row.y { try chartFinite(y,at + ".y") }
                if let size = row.size { try chartCheck(size.isFinite && size >= 0,at + ".size","must be finite and nonnegative") }
                try chartCheck(row.size == nil || d.type == .bubble,at + ".size","size belongs to bubble charts")
                if [.scatter,.bubble].contains(d.type) {
                    try chartCheck(row.x.kind == .number && row.y != nil,at,"scatter/bubble require numeric x and y")
                }
                if d.type == .bubble { try chartCheck(row.size != nil,at + ".size","bubble requires size (mapped to area)") }
                if [.percentStackedBar,.percentStackedArea].contains(d.type), let y = row.y {
                    try chartCheck(y >= 0,at + ".y","percent stacks cannot contain negative values")
                }
                if [.column,.bar,.groupedBar,.stackedBar,.percentStackedBar,.combo].contains(d.type) {
                    try chartCheck(row.y != nil,at + ".y","bar/combo values cannot be missing")
                }
            }
            try chartCheck(xKinds.count == 1,p,"x coordinate kinds cannot be mixed")
            let groups = Dictionary(grouping: rows, by: { $0.seriesID ?? "" })
            for values in groups.values {
                if ![.scatter,.bubble].contains(d.type) {
                    try chartCheck(Set(values.map(\.x)).count == values.count,p,"duplicate x within a series")
                }
                if [.line,.area,.stackedArea,.percentStackedArea,.combo].contains(d.type) && xKinds.first != .category {
                    let numbers = try values.map { try scalar($0.x,path:p) }
                    try chartCheck(zip(numbers,numbers.dropFirst()).allSatisfy { $0.0 < $0.1 },p,"numeric/time records must be strictly ordered within each series")
                }
            }
            if [.stackedArea,.percentStackedArea].contains(d.type), let first = groups.values.first {
                let grid = first.map(\.x)
                try chartCheck(groups.values.allSatisfy { $0.map(\.x) == grid },p,"stacked area series need the same ordered x grid; use explicit nil for gaps")
            }
            if [.percentStackedBar,.percentStackedArea].contains(d.type) {
                let byX = Dictionary(grouping:rows,by:\.x)
                for values in byX.values {
                    let total = values.compactMap(\.y).reduce(0,+)
                    try chartCheck(total.isFinite,p,"percentage denominator overflow")
                    if total == 0 { warnings.append(.init(path:p,problem:"zero-total category is a gap, not a fabricated percentage")) }
                }
            }
            return groups.count
        case .parts(let rows):
            try chartCheck(!rows.isEmpty,p,"needs parts"); try consume(rows.count,at:p)
            try identify(rows.map(\.id),path:p,facets:facets)
            for row in rows { try chartText(row.label,p + ".label"); try chartCheck(row.value.isFinite && row.value >= 0,p + ".value","parts must be finite and nonnegative") }
            let total = rows.reduce(0) { $0 + $1.value }
            try chartCheck(total.isFinite && total > 0,p,"parts need a finite positive total")
            return 1
        case .samples, .bins, .boxSummary, .density, .intervals:
            return try validateStatistics(d,path:path,facets:facets)
        case .ohlc, .volume:
            return try validateFinance(d,path:path,facets:facets)
        case .matrix(let cells):
            try chartCheck(!cells.isEmpty,p,"needs cells"); try consume(cells.count,at:p)
            try identify(cells.map(\.id),path:p,facets:facets)
            var positions: Set<[ChartCoordinate]> = []
            for cell in cells {
                try coordinate(cell.row,path:p + ".row"); try coordinate(cell.column,path:p + ".column")
                try chartCheck(positions.insert([cell.row,cell.column]).inserted,p,"duplicate matrix position")
                if let value = cell.value { try chartFinite(value,p + ".value") }
            }
            try chartCheck(Set(cells.map { $0.row.kind }).count == 1 && Set(cells.map { $0.column.kind }).count == 1,p,"matrix coordinate kinds must be consistent")
            return 1
        case .dimensions(let data):
            let minimum = d.type == .radar ? 3 : 2
            try chartCheck((minimum...ChartLimits.dimensions).contains(data.dimensions.count),p + ".dimensions","invalid dimension count")
            try chartCheck(!data.records.isEmpty,p + ".records","needs records")
            try consume(data.records.count * data.dimensions.count,at:p)
            try identify(data.dimensions.map(\.id),collection:"dimensions",path:p,facets:facets)
            try identify(data.records.map(\.id),path:p,facets:facets)
            for dim in data.dimensions {
                try chartText(dim.label,p + ".dimensions.label")
                try chartCheck(dim.lower.isFinite && dim.upper.isFinite && dim.lower < dim.upper,p + ".dimensions.domain","dimension needs finite increasing bounds")
                if let unit = dim.unit { try chartText(unit,p + ".dimensions.unit",maximum:64,nonempty:false) }
            }
            for row in data.records {
                try chartCheck(row.values.count == data.dimensions.count,p + ".records.values","dimension count mismatch")
                if let label = row.label { try chartText(label,p + ".records.label",nonempty:false) }
                for (value,dim) in zip(row.values,data.dimensions) {
                    try chartCheck(value.isFinite && value >= dim.lower && value <= dim.upper,p + ".records.values","value is outside declared dimension bounds; expand the domain instead of clipping")
                }
            }
            return 1
        case .polar(let rows):
            try chartCheck(!rows.isEmpty,p,"needs polar records"); try consume(rows.count,at:p)
            try identify(rows.map(\.id),path:p,facets:facets)
            for row in rows {
                try chartFinite(row.angle,p + ".angle")
                try chartCheck(row.radius.isFinite && row.radius >= 0,p + ".radius","radius must be finite and nonnegative")
                try series(row.seriesID,document:d,path:p + ".seriesID")
            }
            return Set(rows.map { $0.seriesID ?? "" }).count
        case .hierarchy, .graph, .flow, .flowMatrix, .waterfall, .stages:
            return try validateRelationships(d,path:path,facets:facets)
        case .events, .tasks, .calendar:
            return try validateSchedule(d,path:path,facets:facets)
        case .facets(let children):
            try chartCheck(facets.isEmpty && !children.isEmpty && children.count <= ChartLimits.facets,p,"small multiples need 1...16 non-nested facets")
            try identify(children.map(\.id),collection:"facets",path:p,facets:facets)
            if d.options.sharedAxes == true, let first = children.first {
                try chartCheck(children.allSatisfy { $0.document.axes == first.document.axes },p,"shared axes require identical axis definitions, domains and units")
                try validateSharedAxes(children,path:p)
            }
            for (i,child) in children.enumerated() {
                try chartCheck(child.document.type != .smallMultiples,"\(p)[\(i)]","nested small multiples are not allowed")
                try validate(child.document,path:"\(p)[\(i)].document",facets:facets + [child.id])
            }
            return 0
        }
    }
    func scalar(_ value: ChartCoordinate, path: String) throws -> Double {
        switch value {
        case .number(let number): return number
        case .instant(let text): return try ChartDates.instant(text,path:path).timeIntervalSince1970
        case .localDate(let text): return try ChartDates.localDate(text,path:path).timeIntervalSince1970
        case .category: throw ChartIssue(path:path,problem:"a category has no continuous numeric/time coordinate")
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

extension ChartValidationContext {
    mutating func validateStatistics(_ d: ChartDocument, path: String, facets: [String]) throws -> Int {
        let p = path + ".data.records"
        switch d.data {
        case .samples(let groups):
            try chartCheck(!groups.isEmpty && groups.count <= ChartLimits.series,p,"needs 1...16 sample series")
            try identify(groups.map(\.id),collection:"samples",path:p,facets:facets)
            for group in groups {
                try chartCheck(!group.values.isEmpty,p + ".values","sample series is empty")
                try consume(group.values.count,at:p)
                if let label = group.label { try chartText(label,p + ".label",nonempty:false) }
                try chartCheck(group.values.allSatisfy(\.isFinite),p + ".values","samples must be finite")
                if [.violin,.density].contains(d.type) && d.options.bandwidth == nil {
                    try chartCheck(group.values.count >= 2 && Set(group.values).count >= 2,p + ".values","KDE of a constant/single sample requires an explicit positive bandwidth")
                }
            }
            return groups.count
        case .bins(let bins):
            try chartCheck(!bins.isEmpty,p,"needs bins"); try consume(bins.count,at:p)
            try identify(bins.map(\.id),path:p,facets:facets)
            try chartCheck(d.options.binEdges == nil && d.options.binCount == nil,path + ".options","preaggregated bins cannot also request sample binning")
            for bin in bins {
                try chartCheck(bin.lower.isFinite && bin.upper.isFinite && bin.lower < bin.upper && bin.count >= 0,p,"bin bounds must increase and count must be nonnegative")
                try series(bin.seriesID,document:d,path:p + ".seriesID")
            }
            let groups = Dictionary(grouping:bins,by:{ $0.seriesID ?? "" })
            for group in groups.values {
                try chartCheck(zip(group,group.dropFirst()).allSatisfy { $0.0.upper <= $0.1.lower },p,"bins must be ordered and nonoverlapping within each series")
                try chartCheck(group.contains { $0.count > 0 },p,"at least one count must be positive")
            }
            return groups.count
        case .boxSummary(let boxes):
            try chartCheck(!boxes.isEmpty,p,"needs box summaries"); try consume(boxes.count,at:p)
            try identify(boxes.map(\.id),path:p,facets:facets)
            for box in boxes {
                let values = [box.lowerWhisker,box.q1,box.median,box.q3,box.upperWhisker]
                try chartCheck(values.allSatisfy(\.isFinite) && zip(values,values.dropFirst()).allSatisfy { $0.0 <= $0.1 },p,"box statistics must be finite and ordered")
                try consume(box.outliers.count,at:p + ".outliers")
                try chartCheck(box.outliers.allSatisfy { $0.isFinite && ($0 < box.lowerWhisker || $0 > box.upperWhisker) },p + ".outliers","outliers must be outside supplied whiskers")
                if let label = box.label { try chartText(label,p + ".label",nonempty:false) }
            }
            return boxes.count
        case .density(let groups):
            try chartCheck(!groups.isEmpty && groups.count <= ChartLimits.series,p,"needs density series")
            try identify(groups.map(\.id),collection:"density",path:p,facets:facets)
            try chartCheck(d.options.bandwidth == nil,path + ".options.bandwidth","supplied density must not be smoothed again as raw samples")
            for group in groups {
                try chartCheck(group.points.count >= 2,p + ".points","density needs at least two points")
                try consume(group.points.count,at:p)
                try chartCheck(group.points.allSatisfy { $0.x.isFinite && $0.density.isFinite && $0.density >= 0 },p,"density samples must be finite and nonnegative")
                try chartCheck(zip(group.points,group.points.dropFirst()).allSatisfy { $0.0.x < $0.1.x },p,"density x must strictly increase")
                let area = zip(group.points,group.points.dropFirst()).reduce(0.0) { sum,pair in
                    sum + (pair.1.x-pair.0.x)*(pair.0.density/2 + pair.1.density/2)
                }
                try chartCheck(area.isFinite && area > 0,p,"density must have finite positive area")
                if d.options.densityNormalized == true {
                    try chartCheck(abs(area-1) <= 0.01,p,"declared normalized density must integrate to one; input is never silently rescaled")
                }
            }
            return groups.count
        case .intervals(let rows):
            try chartCheck(!rows.isEmpty,p,"needs intervals"); try consume(rows.count,at:p)
            try identify(rows.map(\.id),path:p,facets:facets)
            var kinds: Set<ChartCoordinate.Kind> = []
            for row in rows {
                try coordinate(row.x,path:p + ".x"); kinds.insert(row.x.kind)
                try series(row.seriesID,document:d,path:p + ".seriesID")
                try chartCheck(row.lower.isFinite && row.estimate.isFinite && row.upper.isFinite
                    && row.lower <= row.estimate && row.estimate <= row.upper,p,"interval requires lower <= estimate <= upper")
            }
            try chartCheck(kinds.count == 1,p,"interval x kinds cannot be mixed")
            if d.type == .confidenceBand {
                try chartCheck(kinds.first != .category,p,"confidence band requires numeric/time x")
                for values in Dictionary(grouping:rows,by:{$0.seriesID ?? ""}).values {
                    let xs = try values.map { try scalar($0.x,path:p) }
                    try chartCheck(zip(xs,xs.dropFirst()).allSatisfy { $0.0 < $0.1 },p,"confidence-band x must strictly increase")
                }
            }
            return Set(rows.map { $0.seriesID ?? "" }).count
        default: throw ChartIssue(path:p,problem:"not a statistical payload")
        }
    }
    mutating func validateFinance(_ d: ChartDocument, path: String, facets: [String]) throws -> Int {
        let p = path + ".data.records"
        var times: [Date] = []
        switch d.data {
        case .ohlc(let rows):
            try chartCheck(!rows.isEmpty,p,"needs OHLC records"); try consume(rows.count,at:p)
            try identify(rows.map(\.id),path:p,facets:facets)
            for row in rows {
                times.append(try ChartDates.instant(row.time,path:p + ".time"))
                try chartCheck([row.open,row.high,row.low,row.close].allSatisfy(\.isFinite)
                    && row.low <= row.open && row.open <= row.high && row.low <= row.close && row.close <= row.high,p,"OHLC requires low <= open/close <= high")
                if let volume = row.volume { try chartCheck(volume.isFinite && volume >= 0,p + ".volume","volume must be finite and nonnegative") }
                if [.volume,.priceVolume].contains(d.type) { try chartCheck(row.volume != nil,p + ".volume","this chart requires explicit volume") }
            }
        case .volume(let rows):
            try chartCheck(!rows.isEmpty,p,"needs volume records"); try consume(rows.count,at:p)
            try identify(rows.map(\.id),path:p,facets:facets)
            for row in rows {
                times.append(try ChartDates.instant(row.time,path:p + ".time"))
                try chartCheck(row.volume.isFinite && row.volume >= 0,p + ".volume","volume must be finite and nonnegative")
            }
        default: throw ChartIssue(path:p,problem:"not a financial payload")
        }
        try chartCheck(zip(times,times.dropFirst()).allSatisfy { $0.0 < $0.1 },p + ".time","financial timestamps must be unique and strictly increasing; do not silently reorder or merge")
        return 1 + (d.options.movingAverages?.count ?? 0)
    }
}

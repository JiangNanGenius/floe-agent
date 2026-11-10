// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ChartDataKind: String, Codable, CaseIterable, Sendable {
    case cartesian
    case parts
    case samples
    case bins
    case boxSummary
    case density
    case intervals
    case ohlc
    case volume
    case matrix
    case dimensions
    case polar
    case hierarchy
    case graph
    case waterfall
    case stages
    case flow
    case flowMatrix
    case events
    case tasks
    case calendar
    case facets
}

public enum ChartData: Sendable, Equatable, Codable {
    case cartesian([CartesianDatum])
    case parts([PartDatum])
    case samples([SampleSeries])
    case bins([HistogramBin])
    case boxSummary([BoxSummary])
    case density([DensitySeries])
    case intervals([IntervalDatum])
    case ohlc([OHLCRecord])
    case volume([VolumeRecord])
    case matrix([MatrixCell])
    case dimensions(DimensionData)
    case polar([PolarDatum])
    case hierarchy([HierarchyNode])
    case graph(GraphData)
    case waterfall([WaterfallStep])
    case stages([StageDatum])
    case flow(FlowData)
    case flowMatrix(ChordMatrix)
    case events([TimelineEvent])
    case tasks([ScheduleTask])
    case calendar([CalendarValue])
    case facets([ChartFacet])
    public var kind: ChartDataKind {
        switch self {
        case .cartesian: .cartesian
        case .parts: .parts
        case .samples: .samples
        case .bins: .bins
        case .boxSummary: .boxSummary
        case .density: .density
        case .intervals: .intervals
        case .ohlc: .ohlc
        case .volume: .volume
        case .matrix: .matrix
        case .dimensions: .dimensions
        case .polar: .polar
        case .hierarchy: .hierarchy
        case .graph: .graph
        case .waterfall: .waterfall
        case .stages: .stages
        case .flow: .flow
        case .flowMatrix: .flowMatrix
        case .events: .events
        case .tasks: .tasks
        case .calendar: .calendar
        case .facets: .facets
        }
    }
    private enum Keys: String, CodingKey { case kind, records }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(ChartDataKind.self, forKey: .kind) {
        case .cartesian: self = .cartesian(try c.decode([CartesianDatum].self, forKey: .records))
        case .parts: self = .parts(try c.decode([PartDatum].self, forKey: .records))
        case .samples: self = .samples(try c.decode([SampleSeries].self, forKey: .records))
        case .bins: self = .bins(try c.decode([HistogramBin].self, forKey: .records))
        case .boxSummary: self = .boxSummary(try c.decode([BoxSummary].self, forKey: .records))
        case .density: self = .density(try c.decode([DensitySeries].self, forKey: .records))
        case .intervals: self = .intervals(try c.decode([IntervalDatum].self, forKey: .records))
        case .ohlc: self = .ohlc(try c.decode([OHLCRecord].self, forKey: .records))
        case .volume: self = .volume(try c.decode([VolumeRecord].self, forKey: .records))
        case .matrix: self = .matrix(try c.decode([MatrixCell].self, forKey: .records))
        case .dimensions: self = .dimensions(try c.decode(DimensionData.self, forKey: .records))
        case .polar: self = .polar(try c.decode([PolarDatum].self, forKey: .records))
        case .hierarchy: self = .hierarchy(try c.decode([HierarchyNode].self, forKey: .records))
        case .graph: self = .graph(try c.decode(GraphData.self, forKey: .records))
        case .waterfall: self = .waterfall(try c.decode([WaterfallStep].self, forKey: .records))
        case .stages: self = .stages(try c.decode([StageDatum].self, forKey: .records))
        case .flow: self = .flow(try c.decode(FlowData.self, forKey: .records))
        case .flowMatrix: self = .flowMatrix(try c.decode(ChordMatrix.self, forKey: .records))
        case .events: self = .events(try c.decode([TimelineEvent].self, forKey: .records))
        case .tasks: self = .tasks(try c.decode([ScheduleTask].self, forKey: .records))
        case .calendar: self = .calendar(try c.decode([CalendarValue].self, forKey: .records))
        case .facets: self = .facets(try c.decode([ChartFacet].self, forKey: .records))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .cartesian(let values): try c.encode(values, forKey: .records)
        case .parts(let values): try c.encode(values, forKey: .records)
        case .samples(let values): try c.encode(values, forKey: .records)
        case .bins(let values): try c.encode(values, forKey: .records)
        case .boxSummary(let values): try c.encode(values, forKey: .records)
        case .density(let values): try c.encode(values, forKey: .records)
        case .intervals(let values): try c.encode(values, forKey: .records)
        case .ohlc(let values): try c.encode(values, forKey: .records)
        case .volume(let values): try c.encode(values, forKey: .records)
        case .matrix(let values): try c.encode(values, forKey: .records)
        case .dimensions(let values): try c.encode(values, forKey: .records)
        case .polar(let values): try c.encode(values, forKey: .records)
        case .hierarchy(let values): try c.encode(values, forKey: .records)
        case .graph(let values): try c.encode(values, forKey: .records)
        case .waterfall(let values): try c.encode(values, forKey: .records)
        case .stages(let values): try c.encode(values, forKey: .records)
        case .flow(let values): try c.encode(values, forKey: .records)
        case .flowMatrix(let values): try c.encode(values, forKey: .records)
        case .events(let values): try c.encode(values, forKey: .records)
        case .tasks(let values): try c.encode(values, forKey: .records)
        case .calendar(let values): try c.encode(values, forKey: .records)
        case .facets(let values): try c.encode(values, forKey: .records)
        }
    }
}

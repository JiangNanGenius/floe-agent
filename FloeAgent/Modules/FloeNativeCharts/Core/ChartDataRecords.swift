// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ChartCoordinate: Sendable, Equatable, Hashable, Codable {
    case category(String), number(Double), instant(String), localDate(String)
    private enum Keys: String, CodingKey { case kind, value }
    public enum Kind: String, Codable, Sendable { case category, number, instant, localDate }
    public var kind: Kind {
        switch self { case .category: .category; case .number: .number; case .instant: .instant; case .localDate: .localDate }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .category: self = .category(try c.decode(String.self, forKey: .value))
        case .number: self = .number(try c.decode(Double.self, forKey: .value))
        case .instant: self = .instant(try c.decode(String.self, forKey: .value))
        case .localDate: self = .localDate(try c.decode(String.self, forKey: .value))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .number(let v): try c.encode(v, forKey: .value)
        case .category(let v), .instant(let v), .localDate(let v): try c.encode(v, forKey: .value)
        }
    }
}

public struct CartesianDatum: Codable, Sendable, Equatable {
    public var id: String
    public var x: ChartCoordinate
    public var y: Double?
    public var seriesID: String?
    public var size: Double?
    public var group: String?
    public var label: String?
    public init(id: String, x: ChartCoordinate, y: Double? = nil, seriesID: String? = nil, size: Double? = nil, group: String? = nil, label: String? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.seriesID = seriesID
        self.size = size
        self.group = group
        self.label = label
    }
}

public struct PartDatum: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var value: Double
    public init(id: String, label: String, value: Double) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct SampleSeries: Codable, Sendable, Equatable {
    public var id: String
    public var values: [Double]
    public var label: String?
    public init(id: String, values: [Double], label: String? = nil) {
        self.id = id
        self.values = values
        self.label = label
    }
}

public struct HistogramBin: Codable, Sendable, Equatable {
    public var id: String
    public var lower: Double
    public var upper: Double
    public var count: Int
    public var seriesID: String?
    public init(id: String, lower: Double, upper: Double, count: Int, seriesID: String? = nil) {
        self.id = id
        self.lower = lower
        self.upper = upper
        self.count = count
        self.seriesID = seriesID
    }
}

public struct BoxSummary: Codable, Sendable, Equatable {
    public var id: String
    public var lowerWhisker: Double
    public var q1: Double
    public var median: Double
    public var q3: Double
    public var upperWhisker: Double
    public var outliers: [Double]
    public var label: String?
    public init(id: String, lowerWhisker: Double, q1: Double, median: Double, q3: Double, upperWhisker: Double, outliers: [Double], label: String? = nil) {
        self.id = id
        self.lowerWhisker = lowerWhisker
        self.q1 = q1
        self.median = median
        self.q3 = q3
        self.upperWhisker = upperWhisker
        self.outliers = outliers
        self.label = label
    }
}

public struct DensityPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var density: Double
    public init(x: Double, density: Double) {
        self.x = x
        self.density = density
    }
}

public struct DensitySeries: Codable, Sendable, Equatable {
    public var id: String
    public var points: [DensityPoint]
    public init(id: String, points: [DensityPoint]) {
        self.id = id
        self.points = points
    }
}

public struct IntervalDatum: Codable, Sendable, Equatable {
    public var id: String
    public var x: ChartCoordinate
    public var estimate: Double
    public var lower: Double
    public var upper: Double
    public var seriesID: String?
    public init(id: String, x: ChartCoordinate, estimate: Double, lower: Double, upper: Double, seriesID: String? = nil) {
        self.id = id
        self.x = x
        self.estimate = estimate
        self.lower = lower
        self.upper = upper
        self.seriesID = seriesID
    }
}

public struct OHLCRecord: Codable, Sendable, Equatable {
    public var id: String
    public var time: String
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var volume: Double?
    public init(id: String, time: String, open: Double, high: Double, low: Double, close: Double, volume: Double? = nil) {
        self.id = id
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

public struct VolumeRecord: Codable, Sendable, Equatable {
    public var id: String
    public var time: String
    public var volume: Double
    public init(id: String, time: String, volume: Double) {
        self.id = id
        self.time = time
        self.volume = volume
    }
}

public struct MatrixCell: Codable, Sendable, Equatable {
    public var id: String
    public var row: ChartCoordinate
    public var column: ChartCoordinate
    public var value: Double?
    public init(id: String, row: ChartCoordinate, column: ChartCoordinate, value: Double? = nil) {
        self.id = id
        self.row = row
        self.column = column
        self.value = value
    }
}

public struct DimensionDefinition: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var lower: Double
    public var upper: Double
    public var unit: String?
    public init(id: String, label: String, lower: Double, upper: Double, unit: String? = nil) {
        self.id = id
        self.label = label
        self.lower = lower
        self.upper = upper
        self.unit = unit
    }
}

public struct DimensionRecord: Codable, Sendable, Equatable {
    public var id: String
    public var values: [Double]
    public var label: String?
    public init(id: String, values: [Double], label: String? = nil) {
        self.id = id
        self.values = values
        self.label = label
    }
}

public struct DimensionData: Codable, Sendable, Equatable {
    public var dimensions: [DimensionDefinition]
    public var records: [DimensionRecord]
    public init(dimensions: [DimensionDefinition], records: [DimensionRecord]) {
        self.dimensions = dimensions
        self.records = records
    }
}

public struct PolarDatum: Codable, Sendable, Equatable {
    public var id: String
    public var angle: Double
    public var radius: Double
    public var seriesID: String?
    public init(id: String, angle: Double, radius: Double, seriesID: String? = nil) {
        self.id = id
        self.angle = angle
        self.radius = radius
        self.seriesID = seriesID
    }
}

public struct HierarchyNode: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var parentID: String?
    public var value: Double?
    public init(id: String, label: String, parentID: String? = nil, value: Double? = nil) {
        self.id = id
        self.label = label
        self.parentID = parentID
        self.value = value
    }
}

public struct ChartNode: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct GraphEdge: Codable, Sendable, Equatable {
    public var id: String
    public var source: String
    public var target: String
    public var weight: Double?
    public init(id: String, source: String, target: String, weight: Double? = nil) {
        self.id = id
        self.source = source
        self.target = target
        self.weight = weight
    }
}

public struct GraphData: Codable, Sendable, Equatable {
    public var nodes: [ChartNode]
    public var edges: [GraphEdge]
    public var directed: Bool
    public init(nodes: [ChartNode], edges: [GraphEdge], directed: Bool = true) {
        self.nodes = nodes
        self.edges = edges
        self.directed = directed
    }
}

public struct WaterfallStep: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var kind: WaterfallStepKind
    public var value: Double
    public init(id: String, label: String, kind: WaterfallStepKind, value: Double) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
    }
}

public struct StageDatum: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var value: Double
    public init(id: String, label: String, value: Double) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct FlowLink: Codable, Sendable, Equatable {
    public var id: String
    public var source: String
    public var target: String
    public var value: Double
    public init(id: String, source: String, target: String, value: Double) {
        self.id = id
        self.source = source
        self.target = target
        self.value = value
    }
}

public struct FlowData: Codable, Sendable, Equatable {
    public var nodes: [ChartNode]
    public var links: [FlowLink]
    public init(nodes: [ChartNode], links: [FlowLink]) {
        self.nodes = nodes
        self.links = links
    }
}

public struct ChordMatrix: Codable, Sendable, Equatable {
    public var nodes: [ChartNode]
    public var values: [[Double]]
    public var directed: Bool
    public init(nodes: [ChartNode], values: [[Double]], directed: Bool = false) {
        self.nodes = nodes
        self.values = values
        self.directed = directed
    }
}

public struct TimelineEvent: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var time: String
    public var end: String?
    public init(id: String, label: String, time: String, end: String? = nil) {
        self.id = id
        self.label = label
        self.time = time
        self.end = end
    }
}

public struct ScheduleTask: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var start: String
    public var end: String
    public var milestone: Bool?
    public var progress: Double?
    public var dependsOn: [String]?
    public init(id: String, label: String, start: String, end: String, milestone: Bool? = nil, progress: Double? = nil, dependsOn: [String]? = nil) {
        self.id = id
        self.label = label
        self.start = start
        self.end = end
        self.milestone = milestone
        self.progress = progress
        self.dependsOn = dependsOn
    }
}

public struct CalendarValue: Codable, Sendable, Equatable {
    public var id: String
    public var day: ChartCoordinate
    public var value: Double
    public init(id: String, day: ChartCoordinate, value: Double) {
        self.id = id
        self.day = day
        self.value = value
    }
}

public struct ChartFacet: Codable, Sendable, Equatable {
    public var id: String
    public var document: ChartDocument
    public init(id: String, document: ChartDocument) {
        self.id = id
        self.document = document
    }
}

public enum WaterfallStepKind: String, Codable, Sendable { case delta, subtotal, total }

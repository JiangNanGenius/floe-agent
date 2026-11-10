// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ChartMark: String, Codable, Sendable { case line, column, bar, area, points }
public enum ChartAxisKind: String, Codable, Sendable { case numeric, temporal, categorical }
public enum ChartOrientation: String, Codable, Sendable { case vertical, horizontal }
public enum ChartAngleUnit: String, Codable, Sendable { case degrees, radians }
public enum ChartHistogramMeasure: String, Codable, Sendable { case count, density, probability }
public enum ChartAggregation: String, Codable, Sendable { case sum, mean, count, last }
public enum ChartIntervalMeaning: String, Codable, Sendable { case standardDeviation, standardError, confidence, custom }
public enum MovingAverageMethod: String, Codable, Sendable { case sma, ema }
public enum MovingAverageSeed: String, Codable, Sendable { case firstValue, sma }
public enum OHLCField: String, Codable, Sendable { case open, high, low, close }

public struct ChartAxis: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ChartAxisKind
    public var title: String?
    public var unit: String?
    public var lower: Double?
    public var upper: Double?
    public init(id: String, kind: ChartAxisKind, title: String? = nil, unit: String? = nil, lower: Double? = nil, upper: Double? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.unit = unit
        self.lower = lower
        self.upper = upper
    }
}

public struct ChartSeries: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mark: ChartMark?
    public var axisID: String?
    public init(id: String, name: String, mark: ChartMark? = nil, axisID: String? = nil) {
        self.id = id
        self.name = name
        self.mark = mark
        self.axisID = axisID
    }
}

public struct MovingAverage: Codable, Sendable, Equatable {
    public var method: MovingAverageMethod
    public var period: Int
    public var field: OHLCField
    public var seed: MovingAverageSeed?
    public init(method: MovingAverageMethod, period: Int, field: OHLCField = .close, seed: MovingAverageSeed? = nil) {
        self.method = method
        self.period = period
        self.field = field
        self.seed = seed
    }
}

public struct ChartOptions: Codable, Sendable, Equatable {
    public var orientation: ChartOrientation?
    public var baseline: Double?
    public var binEdges: [Double]?
    public var binCount: Int?
    public var bandwidth: Double?
    public var densityNormalized: Bool?
    public var confidenceLevel: Double?
    public var intervalMeaning: ChartIntervalMeaning?
    public var method: String?
    public var movingAverages: [MovingAverage]?
    public var angleUnit: ChartAngleUnit?
    public var clockwise: Bool?
    public var zeroAngle: Double?
    public var holeRatio: Double?
    public var timeZone: String?
    public var weekStart: Int?
    public var aggregation: ChartAggregation?
    public var sharedAxes: Bool?
    public var histogramMeasure: ChartHistogramMeasure?
    public init(orientation: ChartOrientation? = nil, baseline: Double? = nil, binEdges: [Double]? = nil, binCount: Int? = nil, bandwidth: Double? = nil, densityNormalized: Bool? = nil, confidenceLevel: Double? = nil, intervalMeaning: ChartIntervalMeaning? = nil, method: String? = nil, movingAverages: [MovingAverage]? = nil, angleUnit: ChartAngleUnit? = nil, clockwise: Bool? = nil, zeroAngle: Double? = nil, holeRatio: Double? = nil, timeZone: String? = nil, weekStart: Int? = nil, aggregation: ChartAggregation? = nil, sharedAxes: Bool? = nil, histogramMeasure: ChartHistogramMeasure? = nil) {
        self.orientation = orientation
        self.baseline = baseline
        self.binEdges = binEdges
        self.binCount = binCount
        self.bandwidth = bandwidth
        self.densityNormalized = densityNormalized
        self.confidenceLevel = confidenceLevel
        self.intervalMeaning = intervalMeaning
        self.method = method
        self.movingAverages = movingAverages
        self.angleUnit = angleUnit
        self.clockwise = clockwise
        self.zeroAngle = zeroAngle
        self.holeRatio = holeRatio
        self.timeZone = timeZone
        self.weekStart = weekStart
        self.aggregation = aggregation
        self.sharedAxes = sharedAxes
        self.histogramMeasure = histogramMeasure
    }
}

public struct ChartProvenance: Codable, Sendable, Equatable {
    public var sourceReference: String?
    public var method: String?
    public init(sourceReference: String? = nil, method: String? = nil) {
        self.sourceReference = sourceReference
        self.method = method
    }
}

public struct ChartDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var type: ChartKind
    public var title: String?
    public var subtitle: String?
    public var axes: [ChartAxis]
    public var series: [ChartSeries]
    public var data: ChartData
    public var options: ChartOptions
    public var provenance: ChartProvenance?
    public init(type: ChartKind, data: ChartData, title: String? = nil, subtitle: String? = nil,
                axes: [ChartAxis] = [], series: [ChartSeries] = [], options: ChartOptions = .init(),
                provenance: ChartProvenance? = nil, schemaVersion: Int = 2) {
        self.schemaVersion = schemaVersion; self.type = type; self.data = data
        self.title = title; self.subtitle = subtitle; self.axes = axes; self.series = series
        self.options = options; self.provenance = provenance
    }
    private enum Keys: String, CodingKey { case schemaVersion, type, title, subtitle, axes, series, data, options, provenance }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        type = try c.decode(ChartKind.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        axes = try c.decodeIfPresent([ChartAxis].self, forKey: .axes) ?? []
        series = try c.decodeIfPresent([ChartSeries].self, forKey: .series) ?? []
        data = try c.decode(ChartData.self, forKey: .data)
        options = try c.decodeIfPresent(ChartOptions.self, forKey: .options) ?? .init()
        provenance = try c.decodeIfPresent(ChartProvenance.self, forKey: .provenance)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(title, forKey: .title); try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encode(axes, forKey: .axes); try c.encode(series, forKey: .series)
        try c.encode(data, forKey: .data); try c.encode(options, forKey: .options)
        try c.encodeIfPresent(provenance, forKey: .provenance)
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ChartKind: String, Codable, CaseIterable, Sendable {
    case line
    case column
    case bar
    case groupedBar
    case stackedBar
    case percentStackedBar
    case area
    case stackedArea
    case percentStackedArea
    case combo
    case smallMultiples
    case pie
    case donut
    case histogram
    case boxPlot
    case violin
    case density
    case errorBars
    case confidenceBand
    case candlestick
    case ohlc
    case volume
    case priceVolume
    case scatter
    case bubble
    case heatmap
    case radar
    case polar
    case parallelCoordinates
    case treemap
    case sunburst
    case network
    case tree
    case waterfall
    case funnel
    case sankey
    case chord
    case timeline
    case gantt
    case calendarHeatmap
}

public enum ChartFamily: String, Codable, CaseIterable, Sendable {
    case comparison, statistics, finance, multivariate, relationships, schedule
}

public struct ChartDescriptor: Sendable, Equatable {
    public let kind: ChartKind
    public let requirementID: String
    public let family: ChartFamily
    public let dataKinds: Set<ChartDataKind>
}

public enum ChartCatalog {
    /// Explicit identities, never inferred from enum ordering.
    public static let descriptors: [ChartDescriptor] = [
        .init(kind: .line, requirementID: "CH01", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .column, requirementID: "CH02", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .bar, requirementID: "CH03", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .groupedBar, requirementID: "CH04", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .stackedBar, requirementID: "CH05", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .percentStackedBar, requirementID: "CH06", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .area, requirementID: "CH07", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .stackedArea, requirementID: "CH08", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .percentStackedArea, requirementID: "CH09", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .combo, requirementID: "CH10", family: .comparison, dataKinds: [.cartesian]),
        .init(kind: .smallMultiples, requirementID: "CH11", family: .comparison, dataKinds: [.facets]),
        .init(kind: .pie, requirementID: "CH12", family: .comparison, dataKinds: [.parts]),
        .init(kind: .donut, requirementID: "CH13", family: .comparison, dataKinds: [.parts]),
        .init(kind: .histogram, requirementID: "CH14", family: .statistics, dataKinds: [.samples, .bins]),
        .init(kind: .boxPlot, requirementID: "CH15", family: .statistics, dataKinds: [.samples, .boxSummary]),
        .init(kind: .violin, requirementID: "CH16", family: .statistics, dataKinds: [.samples, .density]),
        .init(kind: .density, requirementID: "CH17", family: .statistics, dataKinds: [.samples, .density]),
        .init(kind: .errorBars, requirementID: "CH18", family: .statistics, dataKinds: [.intervals]),
        .init(kind: .confidenceBand, requirementID: "CH19", family: .statistics, dataKinds: [.intervals]),
        .init(kind: .candlestick, requirementID: "CH20", family: .finance, dataKinds: [.ohlc]),
        .init(kind: .ohlc, requirementID: "CH21", family: .finance, dataKinds: [.ohlc]),
        .init(kind: .volume, requirementID: "CH22", family: .finance, dataKinds: [.ohlc, .volume]),
        .init(kind: .priceVolume, requirementID: "CH23", family: .finance, dataKinds: [.ohlc]),
        .init(kind: .scatter, requirementID: "CH24", family: .multivariate, dataKinds: [.cartesian]),
        .init(kind: .bubble, requirementID: "CH25", family: .multivariate, dataKinds: [.cartesian]),
        .init(kind: .heatmap, requirementID: "CH26", family: .multivariate, dataKinds: [.matrix]),
        .init(kind: .radar, requirementID: "CH27", family: .multivariate, dataKinds: [.dimensions]),
        .init(kind: .polar, requirementID: "CH28", family: .multivariate, dataKinds: [.polar]),
        .init(kind: .parallelCoordinates, requirementID: "CH29", family: .multivariate, dataKinds: [.dimensions]),
        .init(kind: .treemap, requirementID: "CH30", family: .relationships, dataKinds: [.hierarchy]),
        .init(kind: .sunburst, requirementID: "CH31", family: .relationships, dataKinds: [.hierarchy]),
        .init(kind: .network, requirementID: "CH32", family: .relationships, dataKinds: [.graph]),
        .init(kind: .tree, requirementID: "CH33", family: .relationships, dataKinds: [.hierarchy]),
        .init(kind: .waterfall, requirementID: "CH34", family: .relationships, dataKinds: [.waterfall]),
        .init(kind: .funnel, requirementID: "CH35", family: .relationships, dataKinds: [.stages]),
        .init(kind: .sankey, requirementID: "CH36", family: .relationships, dataKinds: [.flow]),
        .init(kind: .chord, requirementID: "CH37", family: .relationships, dataKinds: [.flowMatrix]),
        .init(kind: .timeline, requirementID: "CH38", family: .schedule, dataKinds: [.events]),
        .init(kind: .gantt, requirementID: "CH39", family: .schedule, dataKinds: [.tasks]),
        .init(kind: .calendarHeatmap, requirementID: "CH40", family: .schedule, dataKinds: [.calendar]),

    ]
    public static func descriptor(for kind: ChartKind) -> ChartDescriptor {
        // All enum cases have a descriptor; coverage is a component contract.
        descriptors.first { $0.kind == kind }!
    }
}

public enum ChartLimits {
    public static let documentBytes = 1_048_576
    public static let historicalReadBytes = 2_097_152
    public static let series = 16
    public static let inputRecords = 2_000
    public static let graphNodes = 256
    public static let graphEdges = 1_024
    public static let hierarchyDepth = 32
    public static let dimensions = 16
    public static let facets = 16
    public static let geometryPrimitives = 20_000
    public static let geometryReferences = 40_000
    public static let densityGrid = 128
}

public struct ChartIssue: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let problem: String
    public init(path: String, problem: String) { self.path = path; self.problem = problem }
    public var description: String { "\(path): \(problem)" }
    public var errorDescription: String? { description }
}

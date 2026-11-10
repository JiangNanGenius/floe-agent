// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Wire-compatible with the five pre-v2 chart documents. Its categorical
/// scatter and historically ring-shaped pie remain explicit legacy data.
public struct LegacyChartDocument: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case line, bar, area, pie, scatter }
    public struct Point: Codable, Sendable, Equatable {
        public var label: String; public var value: Double
        public init(label: String, value: Double) { self.label = label; self.value = value }
    }
    public struct Series: Codable, Sendable, Equatable {
        public var name: String; public var points: [Point]
        public init(name: String, points: [Point]) { self.name = name; self.points = points }
    }
    public var title: String?
    public var type: Kind
    public var series: [Series]
    public init(title: String? = nil, type: Kind, series: [Series]) {
        self.title = title; self.type = type; self.series = series
    }
}

public enum DecodedChart: Sendable, Equatable {
    case legacy(LegacyChartDocument)
    case v2(PreparedChart)
}

public enum ChartDocumentCodec {
    public static func decode(_ data: Data) throws -> DecodedChart {
        try chartCheck(!data.isEmpty && data.count <= ChartLimits.historicalReadBytes,"chart","document exceeds the historical 2 MiB read limit")
        let object: Any
        do { object = try JSONSerialization.jsonObject(with:data) }
        catch { throw ChartIssue(path:"chart",problem:"malformed JSON") }
        guard let root = object as? [String:Any] else { throw ChartIssue(path:"chart",problem:"document must be an object") }
        do {
            if root["schemaVersion"] != nil {
                try chartCheck(data.count <= ChartLimits.documentBytes,"chart","v2 document exceeds 1 MiB")
                try StrictChartJSON.check(object,type:"ChartDocument",path:"chart")
                return .v2(try ChartValidator.prepare(JSONDecoder().decode(ChartDocument.self,from:data)))
            }
            let old = try JSONDecoder().decode(LegacyChartDocument.self,from:data)
            // Exact old producer limits; no conversion, negative pie clipping,
            // guessed numeric x, or rewritten storage is performed in Core.
            try chartCheck(old.title == nil || old.title!.count <= 160,"chart.title","legacy title exceeds 160 characters")
            try chartCheck(!old.series.isEmpty && old.series.count <= ChartLimits.series,"chart.series","legacy chart needs 1...16 series")
            var count = 0
            for series in old.series {
                try chartCheck(!series.name.isEmpty && series.name.count <= 100 && !series.points.isEmpty,"chart.series","invalid legacy series")
                try chartCheck(series.points.count <= ChartLimits.inputRecords-count,"chart.series","legacy chart exceeds 2000 points")
                count += series.points.count
                try chartCheck(series.points.allSatisfy { $0.label.count <= 100 && $0.value.isFinite },"chart.series.points","invalid legacy point")
            }
            return .legacy(old)
        } catch let issue as ChartIssue { throw issue }
        catch let error as DecodingError {
            let context: DecodingError.Context
            switch error {
            case .dataCorrupted(let c), .keyNotFound(_,let c), .typeMismatch(_,let c), .valueNotFound(_,let c): context = c
            @unknown default: throw ChartIssue(path:"chart",problem:"invalid chart structure")
            }
            let path = "chart" + context.codingPath.map { "." + $0.stringValue }.joined()
            throw ChartIssue(path:path,problem:context.debugDescription)
        }
    }
    public static func encode(_ document: ChartDocument) throws -> Data {
        _ = try ChartValidator.prepare(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
    public static func encode(_ document: LegacyChartDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try chartCheck(data.count <= ChartLimits.documentBytes,"chart","newly encoded legacy document exceeds 1 MiB")
        _ = try decode(data)
        return data
    }
}

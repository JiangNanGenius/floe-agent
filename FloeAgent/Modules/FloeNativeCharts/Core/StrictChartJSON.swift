// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Version 2 rejects misspelled/unsupported fields instead of decoding them
/// away. Kept separate from legacy JSON compatibility.
enum StrictChartJSON {
    static let fields: [String:[String:String]] = [
        "CartesianDatum": ["id":"String", "x":"ChartCoordinate", "y":"Double?", "seriesID":"String?", "size":"Double?", "group":"String?", "label":"String?"],
        "PartDatum": ["id":"String", "label":"String", "value":"Double"],
        "SampleSeries": ["id":"String", "values":"[Double]", "label":"String?"],
        "HistogramBin": ["id":"String", "lower":"Double", "upper":"Double", "count":"Int", "seriesID":"String?"],
        "BoxSummary": ["id":"String", "lowerWhisker":"Double", "q1":"Double", "median":"Double", "q3":"Double", "upperWhisker":"Double", "outliers":"[Double]", "label":"String?"],
        "DensityPoint": ["x":"Double", "density":"Double"],
        "DensitySeries": ["id":"String", "points":"[DensityPoint]"],
        "IntervalDatum": ["id":"String", "x":"ChartCoordinate", "estimate":"Double", "lower":"Double", "upper":"Double", "seriesID":"String?"],
        "OHLCRecord": ["id":"String", "time":"String", "open":"Double", "high":"Double", "low":"Double", "close":"Double", "volume":"Double?"],
        "VolumeRecord": ["id":"String", "time":"String", "volume":"Double"],
        "MatrixCell": ["id":"String", "row":"ChartCoordinate", "column":"ChartCoordinate", "value":"Double?"],
        "DimensionDefinition": ["id":"String", "label":"String", "lower":"Double", "upper":"Double", "unit":"String?"],
        "DimensionRecord": ["id":"String", "values":"[Double]", "label":"String?"],
        "DimensionData": ["dimensions":"[DimensionDefinition]", "records":"[DimensionRecord]"],
        "PolarDatum": ["id":"String", "angle":"Double", "radius":"Double", "seriesID":"String?"],
        "HierarchyNode": ["id":"String", "label":"String", "parentID":"String?", "value":"Double?"],
        "ChartNode": ["id":"String", "label":"String"],
        "GraphEdge": ["id":"String", "source":"String", "target":"String", "weight":"Double?"],
        "GraphData": ["nodes":"[ChartNode]", "edges":"[GraphEdge]", "directed":"Bool"],
        "WaterfallStep": ["id":"String", "label":"String", "kind":"WaterfallStepKind", "value":"Double"],
        "StageDatum": ["id":"String", "label":"String", "value":"Double"],
        "FlowLink": ["id":"String", "source":"String", "target":"String", "value":"Double"],
        "FlowData": ["nodes":"[ChartNode]", "links":"[FlowLink]"],
        "ChordMatrix": ["nodes":"[ChartNode]", "values":"[[Double]]", "directed":"Bool"],
        "TimelineEvent": ["id":"String", "label":"String", "time":"String", "end":"String?"],
        "ScheduleTask": ["id":"String", "label":"String", "start":"String", "end":"String", "milestone":"Bool?", "progress":"Double?", "dependsOn":"[String]?"],
        "CalendarValue": ["id":"String", "day":"ChartCoordinate", "value":"Double"],
        "ChartFacet": ["id":"String", "document":"ChartDocument"],
        "ChartAxis": ["id":"String", "kind":"ChartAxisKind", "title":"String?", "unit":"String?", "lower":"Double?", "upper":"Double?"],
        "ChartSeries": ["id":"String", "name":"String", "mark":"ChartMark?", "axisID":"String?"],
        "MovingAverage": ["method":"MovingAverageMethod", "period":"Int", "field":"OHLCField", "seed":"MovingAverageSeed?"],
        "ChartOptions": ["orientation":"ChartOrientation?", "baseline":"Double?", "binEdges":"[Double]?", "binCount":"Int?", "bandwidth":"Double?", "densityNormalized":"Bool?", "confidenceLevel":"Double?", "intervalMeaning":"ChartIntervalMeaning?", "method":"String?", "movingAverages":"[MovingAverage]?", "angleUnit":"ChartAngleUnit?", "clockwise":"Bool?", "zeroAngle":"Double?", "holeRatio":"Double?", "timeZone":"String?", "weekStart":"Int?", "aggregation":"ChartAggregation?", "sharedAxes":"Bool?", "histogramMeasure":"ChartHistogramMeasure?"],
        "ChartProvenance": ["sourceReference":"String?", "method":"String?"],
        "ChartDocument": ["schemaVersion":"Int", "type":"ChartKind", "title":"String?", "subtitle":"String?", "axes":"[ChartAxis]", "series":"[ChartSeries]", "data":"ChartData", "options":"ChartOptions", "provenance":"ChartProvenance?"],
    ]
    static let payloads: [String:String] = ["cartesian":"[CartesianDatum]", "parts":"[PartDatum]", "samples":"[SampleSeries]", "bins":"[HistogramBin]", "boxSummary":"[BoxSummary]", "density":"[DensitySeries]", "intervals":"[IntervalDatum]", "ohlc":"[OHLCRecord]", "volume":"[VolumeRecord]", "matrix":"[MatrixCell]", "dimensions":"DimensionData", "polar":"[PolarDatum]", "hierarchy":"[HierarchyNode]", "graph":"GraphData", "waterfall":"[WaterfallStep]", "stages":"[StageDatum]", "flow":"FlowData", "flowMatrix":"ChordMatrix", "events":"[TimelineEvent]", "tasks":"[ScheduleTask]", "calendar":"[CalendarValue]", "facets":"[ChartFacet]"]
    static func check(_ value: Any, type rawType: String, path: String) throws {
        if value is NSNull { return }
        let type = rawType.hasSuffix("?") ? String(rawType.dropLast()) : rawType
        if type.hasPrefix("["), type.hasSuffix("]") {
            guard let values = value as? [Any] else { return } // Decoder supplies the precise type error.
            let element = String(type.dropFirst().dropLast())
            for (i,v) in values.enumerated() { try check(v,type:element,path:"\(path)[\(i)]") }
            return
        }
        if type == "ChartCoordinate" {
            if let object = value as? [String:Any] {
                try unknown(object,allowed:["kind","value"],path:path)
            }
            return
        }
        if type == "ChartData" {
            guard let object = value as? [String:Any] else { return }
            try unknown(object,allowed:["kind","records"],path:path)
            if let kind = object["kind"] as? String, let child = payloads[kind], let records = object["records"] {
                try check(records,type:child,path:path + ".records")
            }
            return
        }
        guard let schema = fields[type], let object = value as? [String:Any] else { return }
        try unknown(object,allowed:Set(schema.keys),path:path)
        for (key,child) in schema {
            if let nested = object[key] { try check(nested,type:child,path:path + "." + key) }
        }
    }
    private static func unknown(_ object: [String:Any], allowed: Set<String>, path: String) throws {
        let extra = Set(object.keys).subtracting(allowed).sorted()
        try chartCheck(extra.isEmpty,path,"unknown fields: " + extra.joined(separator:", "))
    }
}

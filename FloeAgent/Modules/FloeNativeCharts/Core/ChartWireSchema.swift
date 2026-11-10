// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The model-facing field contract shares its records with strict decoding.
/// Semantic constraints (domains, units, references and data budgets) remain
/// authoritative in ChartValidator; the schema is discovery, not permission.
public enum ChartWireSchema {
    public static func documentSchema() throws -> Data {
        var definitions: [String: Any] = [:]
        for (name, fields) in StrictChartJSON.fields {
            let properties = fields.mapValues(schema(for:))
            var required = fields.filter { !$0.value.hasSuffix("?") }.map(\.key).sorted()
            if name == "ChartDocument" { required = ["schemaVersion", "type", "data"] }
            definitions[name] = ["type": "object", "properties": properties,
                "required": required, "additionalProperties": false]
        }
        definitions["ChartKind"] = ["type": "string", "enum": ChartKind.allCases.map(\.rawValue)]
        let enums = [
            "ChartMark": ["line", "column", "bar", "area", "points"],
            "ChartAxisKind": ["numeric", "temporal", "categorical"],
            "ChartOrientation": ["vertical", "horizontal"],
            "ChartAngleUnit": ["degrees", "radians"],
            "ChartHistogramMeasure": ["count", "density", "probability"],
            "ChartAggregation": ["sum", "mean", "count", "last"],
            "ChartIntervalMeaning": ["standardDeviation", "standardError", "confidence", "custom"],
            "MovingAverageMethod": ["sma", "ema"], "MovingAverageSeed": ["firstValue", "sma"],
            "OHLCField": ["open", "high", "low", "close"], "WaterfallStepKind": ["delta", "subtotal", "total"]
        ]
        for (name, values) in enums { definitions[name] = ["type": "string", "enum": values] }
        definitions["ChartCoordinate"] = ["oneOf": ["category", "number", "instant", "localDate"].map { kind -> [String: Any] in
            ["type": "object", "properties": ["kind": ["type": "string", "enum": [kind]],
                "value": ["type": kind == "number" ? "number" : "string"]],
             "required": ["kind", "value"], "additionalProperties": false]
        }]
        definitions["ChartData"] = ["oneOf": StrictChartJSON.payloads.keys.sorted().map { kind -> [String: Any] in
            ["type": "object", "properties": ["kind": ["type": "string", "enum": [kind]],
                "records": schema(for: StrictChartJSON.payloads[kind]!)],
             "required": ["kind", "records"], "additionalProperties": false]
        }]
        var document = definitions["ChartDocument"] as! [String: Any]
        var properties = document["properties"] as! [String: Any]
        properties["schemaVersion"] = ["type": "integer", "enum": [2]]
        document["properties"] = properties
        definitions["ChartDocument"] = document
        return try JSONSerialization.data(withJSONObject: ["$ref": "#/$defs/ChartDocument", "$defs": definitions], options: [.sortedKeys])
    }

    private static func schema(for rawType: String) -> [String: Any] {
        if rawType.hasSuffix("?") {
            return ["anyOf": [schema(for: String(rawType.dropLast())), ["type": "null"]]]
        }
        if rawType.hasPrefix("["), rawType.hasSuffix("]") {
            return ["type": "array", "items": schema(for: String(rawType.dropFirst().dropLast()))]
        }
        switch rawType {
        case "String": return ["type": "string"]
        case "Int": return ["type": "integer"]
        case "Double": return ["type": "number"]
        case "Bool": return ["type": "boolean"]
        default: return ["$ref": "#/$defs/" + rawType]
        }
    }
}

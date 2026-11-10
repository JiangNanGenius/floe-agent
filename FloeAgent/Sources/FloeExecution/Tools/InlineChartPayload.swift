// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeNativeChartsCore

/// Retain every submitted field until the strict chart decoder checks it.
/// Decoding directly as ChartDocument would silently discard unknown keys.
public struct InlineChartPayload: Decodable, Sendable {
    public let document: ChartDocument

    public init(document: ChartDocument) throws {
        _ = try ChartValidator.prepare(document)
        self.document = document
    }

    public init(from decoder: any Decoder) throws {
        let raw = try RawChartJSON(from: decoder)
        let data = try JSONEncoder().encode(raw)
        guard case .v2(let prepared) = try ChartDocumentCodec.decode(data) else {
            throw ChartIssue(path: "chart", problem: "Use schemaVersion 2 for the chart object; legacy charts use chartType and series")
        }
        document = prepared.document
    }
}

private indirect enum RawChartJSON: Codable, Sendable {
    case object([String: RawChartJSON]), array([RawChartJSON]), text(String), number(Double), boolean(Bool), null

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 64 else { throw ChartIssue(path: "chart", problem: "JSON nesting exceeds 64 levels") }
        if let object = try? decoder.container(keyedBy: Key.self) {
            guard object.allKeys.count <= 128 else { throw ChartIssue(path: "chart", problem: "too many object fields") }
            var result: [String: RawChartJSON] = [:]
            for key in object.allKeys { result[key.stringValue] = try object.decode(Self.self, forKey: key) }
            self = .object(result); return
        }
        if var array = try? decoder.unkeyedContainer() {
            guard (array.count ?? 0) <= 20_000 else { throw ChartIssue(path: "chart", problem: "array exceeds the input budget") }
            var result: [RawChartJSON] = []
            while !array.isAtEnd { result.append(try array.decode(Self.self)) }
            self = .array(result); return
        }
        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() { self = .null }
        else if let value = try? scalar.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? scalar.decode(String.self) { self = .text(value) }
        else { self = .number(try scalar.decode(Double.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .object(let values):
            var object = encoder.container(keyedBy: Key.self)
            for (key, value) in values { try object.encode(value, forKey: Key(stringValue: key)) }
        case .array(let values):
            var array = encoder.unkeyedContainer(); for value in values { try array.encode(value) }
        default:
            var scalar = encoder.singleValueContainer()
            switch self {
            case .text(let value): try scalar.encode(value)
            case .number(let value): try scalar.encode(value)
            case .boolean(let value): try scalar.encode(value)
            case .null: try scalar.encodeNil()
            default: break
            }
        }
    }
}

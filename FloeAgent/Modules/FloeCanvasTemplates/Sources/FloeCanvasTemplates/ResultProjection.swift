import Foundation
import FloeCanvasCore

/// Data-only default projection. Structured values are visible JSON; they cannot
/// turn themselves into an editor reference or grant an operation permission.
public enum TemplateResultProjection {
    public static func content(_ value: FlowValue) throws -> CanvasContent {
        switch value {
        case .string(let text): return .text(text)
        case .number(let number): return .text(String(number))
        case .bool(let flag): return .text(flag ? "true" : "false")
        case .asset(let asset): return .media(asset)
        case .table(let header, let rows): return .table(header: header, rows: rows)
        case .json(let json):
            return .code(language: "json", source: String(decoding: try JSONFidelity.serialize(json,
                options: .init(prettyPrinted: true)), as: UTF8.self))
        case .list:
            let json = try JSONFidelity.parse(JSONEncoder().encode(value))
            return try content(.json(json))
        }
    }
}

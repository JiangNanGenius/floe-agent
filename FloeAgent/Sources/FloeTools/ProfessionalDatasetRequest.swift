import Foundation
import FloeCore

/// Fixed operations of Kimi Datasource, carried by the existing web.search.
public struct ProfessionalDatasetRequest: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable { case describe, query }
    public let action: Action
    public let name: String
    public let apiName: String?
    public let parameters: [String: ProfessionalDatasetValue]?

    public static let sourceNames: Set<String> = [
        "stock_finance_data", "yahoo_finance", "world_bank_open_data", "tianyancha",
        "arxiv", "scholar", "yuandian_law", "wind", "imf", "gildata", "sec_edgar",
        "sp_data", "china_nda", "china_nbs", "china_standards", "who", "fao",
        "unsd", "ecb", "eurostat", "unicef", "oecd", "fred", "xhcj", "caixin"
    ]

    public init(action: Action, name: String, apiName: String? = nil,
                parameters: [String: ProfessionalDatasetValue]? = nil) {
        self.action = action
        self.name = name
        self.apiName = apiName
        self.parameters = parameters
    }

    public func validate() throws {
        guard Self.sourceNames.contains(name) else {
            throw FloeError.validationFailed("Choose one advertised Kimi data source.")
        }
        switch action {
        case .describe:
            guard apiName == nil, parameters == nil else {
                throw FloeError.validationFailed("A dataset description accepts only action and name.")
            }
        case .query:
            guard let apiName,
                  apiName.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil,
                  let parameters, parameters.count <= 64 else {
                throw FloeError.validationFailed("A dataset query requires an API name and bounded parameters from its description.")
            }
            for (key, value) in parameters {
                guard key.utf8.count <= 128, !key.isEmpty,
                      !["file_path", "filepath"].contains(key.lowercased()),
                      value.isBounded(depth: 0) else {
                    throw FloeError.validationFailed("Dataset parameters are too large or contain an output path. Floe owns result paths.")
                }
            }
            if let value = parameters["max_results"] {
                guard case .number(let count) = value, count.rounded() == count,
                      (1...10).contains(count) else {
                    throw FloeError.validationFailed("Dataset max_results must be an integer from 1 to 10.")
                }
            }
            guard try JSONEncoder().encode(parameters).count <= 16_384 else {
                throw FloeError.validationFailed("Dataset parameters exceed 16 KiB.")
            }
        }
    }
}

/// Bounded JSON parameters are data, never HTTP request configuration.
public enum ProfessionalDatasetValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([ProfessionalDatasetValue]), object([String: ProfessionalDatasetValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([ProfessionalDatasetValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: ProfessionalDatasetValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    fileprivate func isBounded(depth: Int) -> Bool {
        guard depth <= 8 else { return false }
        switch self {
        case .string(let v): return v.utf8.count <= 8_192
        case .number(let v): return v.isFinite
        case .array(let v): return v.count <= 100 && v.allSatisfy { $0.isBounded(depth: depth + 1) }
        case .object(let v):
            return v.count <= 64 && v.allSatisfy {
                !$0.key.isEmpty && $0.key.utf8.count <= 128
                    && !["file_path", "filepath"].contains($0.key.lowercased())
                    && $0.value.isBounded(depth: depth + 1)
            }
        case .bool, .null: return true
        }
    }
}

struct ProfessionalDatasetInvocation: Codable, Sendable {
    let query: String
    let dataset: ProfessionalDatasetRequest
}

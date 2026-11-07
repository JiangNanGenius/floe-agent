// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore

/// The outer studio revision is a string for all work kinds. At this boundary
/// accept that exact decimal representation as well as the media model's Int64,
/// and keep malformed calls outside the editor transaction.
enum StudioMediaToolContract {
    static func decode(_ json: String) throws -> MediaV2ToolInput {
        let data = Data(json.utf8)
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw FloeError.validationFailed("inputJSON must be one valid JSON object. Read studio.read and retry.") }
        guard var object = value as? [String: Any] else {
            throw FloeError.validationFailed("inputJSON must be one JSON object, not an array.")
        }
        let allowed: Set<String> = ["objectID", "objectIDs", "expectedRevision", "number", "secondary",
                                    "start", "duration", "text", "color", "property", "flag", "points", "captionStyle"]
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw FloeError.validationFailed("Unknown inputJSON fields: \(unknown.joined(separator: ", ")). Read studio.read for supported fields.")
        }
        guard let revision = object["expectedRevision"], !(revision is NSNull) else {
            throw FloeError.validationFailed("inputJSON.expectedRevision is required. Copy the revision from a fresh studio.read.")
        }
        if let text = revision as? String {
            guard text.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
                  let number = Int64(text) else {
                throw FloeError.validationFailed("inputJSON.expectedRevision must be the exact nonnegative decimal revision from studio.read.")
            }
            object["expectedRevision"] = number
        }
        do {
            let input = try JSONDecoder().decode(MediaV2ToolInput.self, from: JSONSerialization.data(withJSONObject: object))
            guard let revision = input.expectedRevision, revision >= 0 else {
                throw FloeError.validationFailed("inputJSON.expectedRevision must be a nonnegative integer from studio.read.")
            }
            return input
        } catch let error as DecodingError {
            let path: [CodingKey]
            let reason: String
            switch error {
            case .typeMismatch(_, let context): path = context.codingPath; reason = "has the wrong JSON type"
            case .valueNotFound(_, let context): path = context.codingPath; reason = "cannot be null"
            case .keyNotFound(let key, let context): path = context.codingPath + [key]; reason = "is required"
            case .dataCorrupted(let context): path = context.codingPath; reason = "has an invalid value"
            @unknown default: path = []; reason = "is invalid"
            }
            let field = (["inputJSON"] + path.map(\.stringValue)).joined(separator: ".")
            throw FloeError.validationFailed("\(field) \(reason). Use the typed example from studio.read; start/duration/number are JSON numbers and object IDs are UUID strings.")
        }
    }
}
#endif

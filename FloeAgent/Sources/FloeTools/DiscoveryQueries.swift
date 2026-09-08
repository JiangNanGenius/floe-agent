import Foundation
import FloeCore

/// Shared backwards-compatible input for tool and workflow discovery.
public struct DiscoveryQueries: Decodable, Sendable {
    public var query: String?
    public var queries: [String]?

    public init(query: String) { self.query = query }
    public init(queries: [String]) { self.queries = queries }

    public static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":512},"queries":{"type":"array","minItems":1,"maxItems":16,"items":{"type":"string","minLength":1,"maxLength":512}}},"additionalProperties":false}"#

    public func validated() throws -> [String] {
        guard (query != nil) != (queries != nil) else {
            throw FloeError.validationFailed("Supply exactly one of query or queries")
        }
        let values = queries ?? [query!]
        guard (1...16).contains(values.count), values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 512
        }) else {
            throw FloeError.validationFailed("Supply 1–16 nonempty queries, each at most 512 characters")
        }
        return values
    }
}

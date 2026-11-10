import Foundation
import FloeTools

/// Uses the same current capability matching as deferred tool discovery.
/// Matching is a relevance signal only; it grants no execution authority.
public enum ExecutionExperienceActivation {
    public static func toolNames(
        query: String,
        descriptors: [ToolCatalog.Descriptor],
        explicitlyActivated: Set<String> = []
    ) -> Set<String> {
        let available = Set(descriptors.map(\.name))
        let matching = ToolDiscovery.matches(
            query: String(query.prefix(8_192)), descriptors: descriptors
        )
        return Set(matching.map(\.name))
            .union(explicitlyActivated.intersection(available))
    }
}

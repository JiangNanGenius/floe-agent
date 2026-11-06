// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A browsable, source-backed catalog of manufacturing parameters.
public struct ManufacturingParameterCatalog: Codable, Equatable, Sendable {
    public var groups: [ManufacturingParameterGroup]
    public var parameters: [ManufacturingParameterDescriptor]

    public init(groups: [ManufacturingParameterGroup],
                parameters: [ManufacturingParameterDescriptor]) {
        self.groups = groups
        self.parameters = parameters
    }

    public static let standard = ManufacturingParameterCatalog(
        groups: ManufacturingParameterCatalog.standardGroups,
        parameters: ManufacturingParameterCatalog.standardParameters
    )

    public func lookup(_ id: String) -> ManufacturingParameterDescriptor? {
        parameters.first { $0.id == id }
    }

    /// Case-insensitive substring match over id and bilingual names/help.
    /// `includeRare == false` filters out rarely used fields.
    public func search(query: String, includeRare: Bool = true) -> [ManufacturingParameterDescriptor] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return parameters.filter { includeRare || !$0.rare }
        }
        func fuzzy(_ s: String) -> Bool { s.lowercased().contains(needle) }
        return parameters.filter { d in
            if !includeRare && d.rare { return false }
            return fuzzy(d.id) || fuzzy(d.nameZH) || fuzzy(d.nameEN)
                || fuzzy(d.helpZH) || fuzzy(d.helpEN)
        }
    }

    /// Catalog self-consistency: unique IDs, valid groupIDs, unique bindings,
    /// bound parameters marked previewUsed, choice kinds carrying choices.
    public func validate() -> [String] {
        var problems: [String] = []
        var seenIDs = Set<String>()
        var seenBindings = Set<String>()
        for p in parameters {
            if !seenIDs.insert(p.id).inserted { problems.append("duplicate parameter id \(p.id)") }
            if !groups.contains(where: { $0.id == p.groupID }) {
                problems.append("parameter \(p.id) references unknown group \(p.groupID)")
            }
            if let binding = p.binding {
                if p.support != .previewUsed {
                    problems.append("parameter \(p.id) has binding \(binding) but support is \(p.support.rawValue)")
                }
                if !seenBindings.insert(binding).inserted {
                    problems.append("duplicate binding \(binding)")
                }
            } else if p.support == .previewUsed {
                problems.append("parameter \(p.id) is previewUsed without a binding")
            }
            if p.kind == .choice && (p.choices == nil || p.choices!.isEmpty) {
                problems.append("choice parameter \(p.id) has no choices")
            }
            if let lo = p.minimum, let hi = p.maximum, lo > hi {
                problems.append("parameter \(p.id) has minimum > maximum")
            }
        }
        return problems.sorted()
    }
}

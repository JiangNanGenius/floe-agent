// SPDX-License-Identifier: MPL-2.0
import Foundation

public nonisolated enum CADBuildingExportDiscipline: String, Codable, CaseIterable, Sendable {
    case architecture, structure, mep
}

public nonisolated extension CADBuildingElement.Kind {
    /// Native authoring kinds have no load-bearing-wall flag or electrical-system kind.
    var exportDiscipline: CADBuildingExportDiscipline {
        switch self {
        case .beam, .column, .slab: .structure
        case .pipe, .duct: .mep
        case .wall, .roof, .stair, .door, .window, .space: .architecture
        }
    }
}

public nonisolated enum CADBuildingExportScope: Equatable, Sendable {
    case wholeProject
    case storey(UUID)
    case elements(Set<UUID>)
    case discipline(CADBuildingExportDiscipline)
}

/// An imported source can reuse another file's handle. Keep every actual match
/// with its file digest; a partial copy never embeds the whole source drawing.
public nonisolated struct CADBuildingExportLayer: Codable, Hashable, Sendable {
    public let elementID: UUID
    public let sourceSHA256: String
    public let sourceName: String
    public let handle: String
    public let layer: String
}

public nonisolated struct CADBuildingExportContext: Codable, Equatable, Sendable {
    /// Host or cutting-opening records needed to interpret selected elements.
    /// They are context, outside the exported element and solid lists.
    public let references: [CADBuildingElement]
    public let sourceLayers: [CADBuildingExportLayer]
}

public nonisolated struct CADBuildingExportSelection: Sendable {
    public let scope: CADBuildingExportScope
    public let storeys: [CADBuildingStorey]
    public let elements: [CADBuildingElement]
    public let bodyIDs: [UUID]
    public let units = "mm"
    public let references: [CADBuildingElement]
    public let sourceLayers: [CADBuildingExportLayer]

    static func resolve(_ scope: CADBuildingExportScope, in model: CADBuildingDocument?, documentBodyIDs: [UUID]) throws -> Self {
        guard let model else {
            guard scope == .wholeProject else { throw CADBuildingError.invalid("The drawing has no native building records for this scope.") }
            return .init(scope: scope, storeys: [], elements: [], bodyIDs: documentBodyIDs, references: [], sourceLayers: [])
        }
        try model.validate()
        let selected: [CADBuildingElement]
        let storeys: [CADBuildingStorey]
        switch scope {
        case .wholeProject:
            selected = model.elements; storeys = model.storeys
        case .storey(let id):
            guard let floor = model.storeys.first(where: { $0.id == id }) else { throw CADBuildingError.invalid("The selected building floor no longer exists.") }
            selected = model.elements.filter { $0.storeyID == id }; storeys = [floor]
        case .elements(let ids):
            selected = model.elements.filter { ids.contains($0.id) }
            guard !ids.isEmpty, selected.count == ids.count else { throw CADBuildingError.invalid("Select current building element IDs before exporting.") }
            let floorIDs = Set(selected.map(\.storeyID)); storeys = model.storeys.filter { floorIDs.contains($0.id) }
        case .discipline(let discipline):
            selected = model.elements.filter { $0.kind.exportDiscipline == discipline }
            guard !selected.isEmpty else { throw CADBuildingError.invalid("The project has no authored \(discipline.rawValue) elements.") }
            let floorIDs = Set(selected.map(\.storeyID)); storeys = model.storeys.filter { floorIDs.contains($0.id) }
        }
        let ids = Set(selected.map(\.id)), hosts = Set(selected.compactMap(\.hostID))
        let related = (model.elements + (model.exportContext?.references ?? [])).filter { item in
            !ids.contains(item.id) && (hosts.contains(item.id) || item.hostID.map(ids.contains) == true)
        }
        let wanted = Set(selected.flatMap(\.bodyIDs))
        guard wanted.isSubset(of: Set(documentBodyIDs)) else { throw CADBuildingError.invalid("Some selected building solids are missing from the native drawing.") }
        var layers = (model.exportContext?.sourceLayers ?? []).filter { ids.contains($0.elementID) }
        var knownLayers = Set(layers)
        let byHandle = Dictionary(grouping: selected, by: \.sourceHandle)
        for source in model.sources {
            for curve in source.snapshot.curves {
                let handle = curve.handle
                guard let owners = byHandle[handle] else { continue }
                for owner in owners {
                    let layer = CADBuildingExportLayer(elementID: owner.id, sourceSHA256: source.sourceSHA256,
                        sourceName: source.sourceName, handle: handle, layer: curve.layer)
                    if knownLayers.insert(layer).inserted {
                        guard layers.count < 8192 else { throw CADBuildingError.invalid("The source layer mapping exceeds the export budget.") }
                        layers.append(layer)
                    }
                }
            }
        }
        return .init(scope: scope, storeys: storeys, elements: selected,
            bodyIDs: scope == .wholeProject ? documentBodyIDs : documentBodyIDs.filter(wanted.contains),
            references: related, sourceLayers: layers)
    }

    func modelCopy(from original: CADBuildingDocument) throws -> CADBuildingDocument {
        var copy = original
        copy.storeys = storeys; copy.elements = elements; copy.sources = []
        copy.exportContext = references.isEmpty && sourceLayers.isEmpty ? nil : .init(references: references, sourceLayers: sourceLayers)
        try copy.validate()
        return copy
    }
}

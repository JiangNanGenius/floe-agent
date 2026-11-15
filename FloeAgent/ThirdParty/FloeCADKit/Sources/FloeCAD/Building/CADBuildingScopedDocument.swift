// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import simd

@MainActor public extension FloeCADDocument {
    func hasBuildingAssemblyPlacementsForExport() throws -> Bool {
        try !CADAssembly.decode(from: session.document.assemblyData).instances.isEmpty
    }

    func buildingExportSelection(_ scope: CADBuildingExportScope) throws -> CADBuildingExportSelection {
        guard !isClosed else { throw CADBuildingError.invalid("The source drawing is closed.") }
        return try .resolve(scope, in: building(), documentBodyIDs: session.document.bodies.map { $0.id.raw })
    }

    func createScopedBuildingExportDocument(_ scope: CADBuildingExportScope, at destination: URL) async throws -> FloeCADDocument {
        try await createBuildingScopeCopy(scope, plan: false, at: destination)
    }

    func createScopedBuildingPlan(_ scope: CADBuildingExportScope, at destination: URL) async throws -> FloeCADDocument {
        try await createBuildingScopeCopy(scope, plan: true, at: destination)
    }
}

@MainActor private extension FloeCADDocument {
    /// Export committed bytes. Staging and read-back precede the exclusive
    /// move to the caller's path; the source never receives an edit or save.
    func createBuildingScopeCopy(_ scope: CADBuildingExportScope, plan: Bool, at destination: URL) async throws -> FloeCADDocument {
        let fm = FileManager.default
        let sourcePath = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        var directoryFlag: ObjCBool = false
        guard destination.isFileURL, !target.pathComponents.starts(with: sourcePath),
              fm.fileExists(atPath: parent.path, isDirectory: &directoryFlag), directoryFlag.boolValue,
              !fm.fileExists(atPath: target.path) else { throw CADBuildingError.invalid("Choose a new native package outside the source drawing.") }
        let tick = buildingChangeCount, identity = savedIdentity
        func checkSource() throws {
            try Task.checkCancellation()
            guard !isClosed, !isReadOnly, !hasUnsavedChanges, !hasUnfinishedBuildingDraftingInput,
                  buildingChangeCount == tick, savedIdentity.revision == identity.revision,
                  savedIdentity.contentSHA256 == identity.contentSHA256 else { throw CADBuildingError.invalid("Save the current drawing before exporting this scope.") }
        }
        try checkSource()
        if plan, scope == .wholeProject, try hasBuildingAssemblyPlacementsForExport() {
            throw CADBuildingError.invalid("Use an assembly drawing page or choose a building floor or element scope.")
        }
        let selection = try buildingExportSelection(scope)
        let sourceStore = FileCADDocumentStore(packageURL: url)
        let source = try await Task.detached(priority: .userInitiated) { try sourceStore.readWithoutRecovery() }.value
        try checkSource()
        guard sourceStore.revision == identity.revision, sourceStore.contentSHA256 == identity.contentSHA256 else {
            throw CADBuildingError.invalid("The saved source drawing changed before export.")
        }
        let output: Project
        if plan { output = try buildingPlanProject(source: source, selection: selection) }
        else if scope == .wholeProject { output = source }
        else { output = try buildingModelProject(source: source, selection: selection) }
        let stage = parent.appendingPathComponent(".building-export-" + UUID().uuidString + ".floecad", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let stagedStore = FileCADDocumentStore(packageURL: stage)
        let payload = try stagedStore.makePayload(output)
        try await Task.detached(priority: .userInitiated) { try FileCADDocumentStore.createPackage(at: stage, payload: payload, overwrite: false) }.value
        let verified = try await Task.detached(priority: .userInitiated) { try stagedStore.readWithoutRecovery() }.value
        guard verified.unitRaw == output.unitRaw, verified.bodies.count == output.bodies.count,
              verified.sketches.count == output.sketches.count, verified.buildingData == output.buildingData,
              verified.itemFoldersData == output.itemFoldersData else { throw CADBuildingError.invalid("The independent drawing did not verify.") }
        let readBodies = Dictionary(verified.bodies.map { ($0.bodyID, $0) }, uniquingKeysWith: { first, _ in first })
        let readSketches = Dictionary(verified.sketches.map { ($0.sketchID, $0.sketchData) }, uniquingKeysWith: { first, _ in first })
        guard readBodies.count == output.bodies.count, readSketches.count == output.sketches.count, output.bodies.allSatisfy({ body in
            guard let same = readBodies[body.bodyID] else { return false }
            return same.name == body.name && same.transformData == body.transformData && same.meshData == body.meshData && same.brepData == body.brepData
        }), output.sketches.allSatisfy({ readSketches[$0.sketchID] == $0.sketchData }) else {
            throw CADBuildingError.invalid("The selected geometry differs from the saved independent drawing.")
        }
        let current = await FloeCADDocument.storedIdentity(at: url)
        try checkSource()
        guard current?.revision == identity.revision, current?.contentSHA256 == identity.contentSHA256 else {
            throw CADBuildingError.invalid("The original drawing changed during export.")
        }
        try fm.moveItem(at: stage, to: target)
        return try await FloeCADDocument.open(at: target)
    }

    func buildingModelProject(source: Project, selection: CADBuildingExportSelection) throws -> Project {
        guard let original = try CADBuildingDocument.decode(source.buildingData), !selection.bodyIDs.isEmpty else {
            throw CADBuildingError.invalid("This building scope has no saved 3D solids. Use its floor plan for room boundaries.")
        }
        let kept = Set(selection.bodyIDs)
        let model = try selection.modelCopy(from: original)
        let output = Project(name: source.name)
        output.formatVersion = source.formatVersion; output.unitRaw = source.unitRaw; output.tolerance = source.tolerance
        output.buildingData = try model.encoded()
        output.bodies = source.bodies.filter { kept.contains($0.bodyID) }
        guard output.bodies.count == kept.count else { throw CADBuildingError.invalid("One or more selected native bodies could not be read.") }
        // Keep the parametric building recipe only when the input graph is the
        // actual original building recipe. Otherwise retain exact native solid,
        // mesh, appearance and placement bytes as independently editable CAD.
        let originalRecipe = try CADBuildingGeometry.recipe(original), nodes = session.document.features.nodes
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if nodes.count == originalRecipe.count, source.rollbackIndex == nil,
           try zip(nodes, originalRecipe).allSatisfy({ actual, recipe in
               try !actual.suppressed && actual.id == recipe.id && actual.outputBodyIDs == recipe.outputBodyIDs && encoder.encode(actual.kind) == encoder.encode(recipe.kind)
           }) {
            let selectedFeatures = Set(try CADBuildingGeometry.recipe(model).map { $0.id.raw })
            output.features = source.features.filter { selectedFeatures.contains($0.featureID) }
        }
        output.itemFoldersData = try scopedFolders(bodyIDs: kept, sketchIDs: [])
        return output
    }

    func scopedFolders(bodyIDs: Set<UUID>, sketchIDs: Set<UUID>) throws -> Data? {
        let folders = session.document.itemFolders
        var keep: Set<ItemFolderID> = []
        let parents = Dictionary(folders.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        guard parents.count == folders.count else { throw CADBuildingError.invalid("Duplicate native folder identities.") }
        let filtered = folders.map { item -> ItemFolder in
            var copy = item
            copy.members = item.members.filter { member in
                switch member { case .body(let id): return bodyIDs.contains(id.raw); case .sketch(let id): return sketchIDs.contains(id.raw); default: return false }
            }
            if !copy.members.isEmpty {
                var cursor: ItemFolderID? = copy.id
                while let id = cursor, keep.insert(id).inserted { cursor = parents[id] ?? nil }
            }
            return copy
        }.filter { keep.contains($0.id) }
        return filtered.isEmpty ? nil : try JSONEncoder().encode(filtered)
    }

    func buildingPlanProject(source: Project, selection: CADBuildingExportSelection) throws -> Project {
        let output = Project(name: source.name)
        output.unitRaw = source.unitRaw; output.tolerance = source.tolerance; output.formatVersion = source.formatVersion
        var sketches: [Sketch] = [], folders: [ItemFolder] = []
        var entityCount = 0
        let bodies = Dictionary(session.document.bodies.map { ($0.id.raw, $0) }, uniquingKeysWith: { first, _ in first })
        guard bodies.count == session.document.bodies.count else { throw CADBuildingError.invalid("Duplicate native body identities.") }
        let byFloor = Dictionary(grouping: selection.elements, by: \.storeyID)
        let layers = Dictionary(grouping: selection.sourceLayers, by: \.elementID)
        var includedSketches: Set<UUID> = []
        func append(_ sketch: Sketch) throws {
            guard includedSketches.insert(sketch.id.raw).inserted else { throw CADBuildingError.invalid("The drawing contains a duplicate sketch identity.") }
            entityCount += sketch.entities.count
            guard entityCount <= 100_000 else { throw CADBuildingError.invalid("The selected floor drawings exceed 100,000 editable entities.") }
            sketches.append(sketch)
        }
        let includeDrafts: Bool
        switch selection.scope { case .wholeProject, .storey: includeDrafts = true; default: includeDrafts = false }
        for floor in selection.storeys {
            var floorFolder = ItemFolder(id: .init(raw: floor.id), name: floor.name)
            let plane = SketchPlane.offsetGround(y: floor.elevationMM)
            var layerFolders: [String: ItemFolder] = [:]
            for element in byFloor[floor.id] ?? [] {
                try Task.checkCancellation()
                var entities: [SketchEntity] = []
                if element.kind == .space {
                    let a = SIMD2<Double>(element.a[0], element.a[1]), b = SIMD2<Double>(element.b[0], element.b[1])
                    entities = [.rect(id: CADBuildingIdentity.uuid(element.id, "plan-boundary"), min: simd_min(a,b), max: simd_max(a,b))]
                } else {
                    for id in element.bodyIDs {
                        guard let body = bodies[id], body.edges.segments.count <= 200_000 else { throw CADBuildingError.invalid("The selected body has no supported bounded edge projection.") }
                        let lines = ProjectionKit.project(body: body, onto: plane)
                        guard !lines.isEmpty, entityCount + entities.count + lines.count <= 100_000 else { throw CADBuildingError.invalid("The body has no projected edges or exceeds the plan budget.") }
                        for (ordinal, entity) in lines.enumerated() {
                            guard case .line(_, let a, let b) = entity else { throw CADBuildingError.invalid("Unsupported native projection entity.") }
                            entities.append(.line(id: CADBuildingIdentity.uuid(id, "plan-edge-\(ordinal)"), a:a, b:b))
                        }
                    }
                }
                let sketch = Sketch(id: .init(raw: element.id), name: element.name, plane: plane, entities: entities)
                try append(sketch)
                let names = Set((layers[element.id] ?? []).map(\.layer).filter { !$0.isEmpty })
                if names.count == 1, let layer = names.first {
                    var folder = layerFolders[layer] ?? ItemFolder(id: .init(raw: CADBuildingIdentity.uuid(floor.id, "plan-layer-" + layer)), name: layer, parentID: floorFolder.id)
                    folder.members.append(.sketch(sketch.id)); layerFolders[layer] = folder
                } else { floorFolder.members.append(.sketch(sketch.id)) }
            }
            if includeDrafts, let draft = session.document.sketches.first(where: { $0.id == CADBuildingDraftingSession.sketchID(for: floor.id) }), !draft.entities.isEmpty {
                try append(try independentFloorSketch(draft)); floorFolder.members.append(.sketch(draft.id))
            }
            if !floorFolder.members.isEmpty || !layerFolders.isEmpty { folders.append(floorFolder); folders += layerFolders.values.sorted { $0.name < $1.name } }
        }
        if selection.scope == .wholeProject {
            // Whole-project plans retain other authored planar sketches and
            // project non-building CAD solids on the native ground plane.
            for sketch in session.document.sketches where !includedSketches.contains(sketch.id.raw) && !sketch.entities.isEmpty { try append(try independentFloorSketch(sketch)) }
            let represented = Set(selection.elements.flatMap(\.bodyIDs))
            for body in session.document.bodies where !represented.contains(body.id.raw) {
                try Task.checkCancellation()
                guard body.edges.segments.count <= 200_000 else { throw CADBuildingError.invalid("The native body projection exceeds the edge budget.") }
                let lines = try ProjectionKit.project(body: body, onto: .ground).enumerated().map { index, entity -> SketchEntity in
                    guard case let .line(_, a, b) = entity else { throw CADBuildingError.invalid("Unsupported native projection entity.") }
                    return .line(id: CADBuildingIdentity.uuid(body.id.raw, "plan-edge-\(index)"), a: a, b: b)
                }
                guard !lines.isEmpty else { throw CADBuildingError.invalid("An unassigned CAD body has no projectable native edges.") }
                try append(Sketch(id:.init(raw:CADBuildingIdentity.uuid(body.id.raw,"plan-body")),name:body.name,plane:.ground,entities:lines))
            }
        }
        guard !sketches.isEmpty else { throw CADBuildingError.invalid("The selected scope has no floor geometry or authored floor sketch.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        output.sketches = try sketches.map { PersistedSketch(sketchID: $0.id.raw, sketchData: try encoder.encode($0)) }
        output.itemFoldersData = folders.isEmpty ? nil : try encoder.encode(folders)
        return output
    }

    func independentFloorSketch(_ sketch: Sketch) throws -> Sketch {
        guard sketch.support == nil, sketch.externalReferences?.isEmpty != false else {
            throw CADBuildingError.invalid("An authored floor sketch has a live external reference. Export its original drawing page or resolve the reference first.")
        }
        var copy = sketch
        copy.drawingSource = nil
        return copy
    }
}
#endif

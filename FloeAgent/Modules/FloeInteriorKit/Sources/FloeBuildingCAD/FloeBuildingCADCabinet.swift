// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

public extension FloeBuildingCADSession {
    /// Create the stable 19-panel cabinet in this working document. Every
    /// panel has one owned rectangle sketch, one extrude feature, an optional
    /// owned move feature and one assembly instance; the returned binding
    /// records all of those identities.
    func createCabinet(_ recipe: CabinetRecipe) async throws -> FloeBuildingCADCabinetBinding {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        guard manifest.cabinet(id: recipe.id) == nil else {
            throw FloeBuildingCADError.duplicateBinding("cabinet \(recipe.id.uuidString)")
        }
        let assembly = try CabinetBuilder.build(recipe)
        let panelIDs = Set(assembly.panels.map(\.id))
        let state = try nativeState()
        if state.instances.values.contains(where: { panelIDs.contains($0.name) }) {
            throw FloeBuildingCADError.duplicateBinding(
                "live assembly instances for cabinet \(recipe.id.uuidString)")
        }
        let baseIdentity = try currentIdentity()
        return try await withMutationRollback { lease in
            var panels: [FloeBuildingCADPanelBinding] = []
            panels.reserveCapacity(assembly.panels.count)
            for (index, panel) in assembly.panels.enumerated() {
                panels.append(try withOwnedWrite(lease) { try createCabinetPanel(panel) })
                if index == 0 { try testMutationCheckpoint("cabinet.create.afterFirstPanel") }
            }
            try testMutationCheckpoint("cabinet.create.afterPanels")
            let provisional = FloeBuildingCADCabinetBinding(
                cabinetID: recipe.id, name: recipe.name, recipe: recipe,
                geometryFingerprint: assembly.geometryFingerprint,
                scheduleFingerprint: assembly.scheduleFingerprint,
                panelBindings: panels,
                createdAtIdentity: baseIdentity, updatedAtIdentity: baseIdentity)
            try validateCabinetGeometry(provisional, assembly: assembly)
            try lease.verifyOwnership()
            let identity = try await saveUnlocked()
            try lease.verifyOwnership()
            let binding = FloeBuildingCADCabinetBinding(
                cabinetID: provisional.cabinetID, name: provisional.name,
                recipe: provisional.recipe,
                geometryFingerprint: provisional.geometryFingerprint,
                scheduleFingerprint: provisional.scheduleFingerprint,
                panelBindings: provisional.panelBindings,
                createdAtIdentity: identity, updatedAtIdentity: identity)
            putCabinet(binding)
            return binding
        }
    }

    /// Re-generate the assembly from the new recipe and update the existing
    /// panel sketches/extrusions/owned moves in place. Panel, body, feature and
    /// instance identities are required to remain the same. Any failure undoes
    /// only this batch back to the captured native change count.
    func updateCabinet(recipe: CabinetRecipe,
                       binding: FloeBuildingCADCabinetBinding,
                       refreshSheet: Bool = true) async throws -> FloeBuildingCADCabinetUpdate {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        let oldAssembly = try CabinetBuilder.build(binding.recipe)
        try validateCabinetGeometry(binding, assembly: oldAssembly)
        let newAssembly = try CabinetBuilder.build(recipe)
        guard newAssembly.recipe.id == oldAssembly.recipe.id else {
            throw FloeBuildingCADError.identityNotPreserved("The cabinet id changed.")
        }
        let oldIDs = Set(oldAssembly.panels.map(\.id))
        let newIDs = Set(newAssembly.panels.map(\.id))
        guard oldIDs == newIDs, oldAssembly.panels.count == newAssembly.panels.count else {
            let missing = oldIDs.subtracting(newIDs).sorted()
            let added = newIDs.subtracting(oldIDs).sorted()
            throw FloeBuildingCADError.identityNotPreserved(
                "Panel ids changed. missing=[\(missing.joined(separator: ","))] added=[\(added.joined(separator: ","))]. "
                + "A bay/shelf-count change needs an additive native add/remove-panel hook.")
        }
        let oldByID = Dictionary(uniqueKeysWithValues: binding.panelBindings.map { ($0.panelID, $0) })
        return try await withMutationRollback { lease in
            // Re-read once, synchronously, after the preflight. The mutation
            // loop below never awaits, so nothing can interleave.
            let state = try nativeState()
            var updatedPanels: [FloeBuildingCADPanelBinding] = []
            updatedPanels.reserveCapacity(newAssembly.panels.count)
            for (index, panel) in newAssembly.panels.enumerated() {
                guard let old = oldByID[panel.id] else {
                    throw FloeBuildingCADError.identityNotPreserved("Missing panel binding \(panel.id).")
                }
                updatedPanels.append(try withOwnedWrite(lease) {
                    try updateCabinetPanel(old, to: panel, state: state)
                })
                if index == 0 { try testMutationCheckpoint("cabinet.update.afterFirstPanel") }
            }
            try testMutationCheckpoint("cabinet.update.afterPanels")
            let provisional = FloeBuildingCADCabinetBinding(
                cabinetID: binding.cabinetID, name: recipe.name, recipe: recipe,
                geometryFingerprint: newAssembly.geometryFingerprint,
                scheduleFingerprint: newAssembly.scheduleFingerprint,
                panelBindings: updatedPanels,
                createdAtIdentity: binding.createdAtIdentity,
                updatedAtIdentity: binding.updatedAtIdentity)
            try validateCabinetGeometry(provisional, assembly: newAssembly)

            var refreshedSheet: FloeBuildingCADSheetBinding?
            var sheetRefreshRequired = false
            var notes: [String] = []
            if let existing = manifest.sheet(cabinetID: binding.cabinetID) {
                let extraInstances = try extraAssemblyInstanceIDs(cabinet: binding)
                if refreshSheet, existing.documentScope == "project", extraInstances.isEmpty {
                    refreshedSheet = try withOwnedWrite(lease) {
                        try refreshProjectSheet(cabinet: provisional, sheet: existing)
                    }
                } else if existing.documentScope != "project" {
                    sheetRefreshRequired = true
                    notes.append("The verified-snapshot sheet is tied to the previous project generation; call refreshCombinationSheet to regenerate it.")
                } else if !extraInstances.isEmpty {
                    sheetRefreshRequired = true
                    notes.append("The project assembly now contains non-cabinet instances; refreshCombinationSheet will switch this page to an instance-scoped verified snapshot.")
                }
            }
            try testMutationCheckpoint("cabinet.update.beforeSave")
            try lease.verifyOwnership()
            let identity = try await saveUnlocked()
            try lease.verifyOwnership()
            let final = FloeBuildingCADCabinetBinding(
                cabinetID: provisional.cabinetID, name: provisional.name,
                recipe: provisional.recipe,
                geometryFingerprint: provisional.geometryFingerprint,
                scheduleFingerprint: provisional.scheduleFingerprint,
                panelBindings: provisional.panelBindings,
                createdAtIdentity: binding.createdAtIdentity,
                updatedAtIdentity: identity)
            putCabinet(final)
            if var sheet = refreshedSheet {
                sheet.sourceCabinetUpdatedAtIdentity = identity
                sheet.updatedAtIdentity = identity
                putSheet(sheet)
                refreshedSheet = sheet
            }
            return FloeBuildingCADCabinetUpdate(
                cabinet: final, sheet: refreshedSheet,
                sheetRefreshRequired: sheetRefreshRequired,
                notes: notes, manifest: manifest)
        }
    }

    /// Read-only validation used before an update and after reopen. It checks
    /// the live sketch rectangles, owned feature set, body bounds/volume and
    /// assembly instance frames, so an external geometry edit is refused
    /// instead of overwritten.
    func validateCabinetBinding(_ binding: FloeBuildingCADCabinetBinding) throws {
        let assembly = try CabinetBuilder.build(binding.recipe)
        try validateCabinetGeometry(binding, assembly: assembly)
    }

    func validateCabinetGeometry(_ binding: FloeBuildingCADCabinetBinding,
                                 assembly: CabinetAssembly) throws {
        guard binding.cabinetID == assembly.recipe.id,
              binding.recipe == assembly.recipe,
              binding.geometryFingerprint == assembly.geometryFingerprint,
              binding.scheduleFingerprint == assembly.scheduleFingerprint else {
            throw FloeBuildingCADError.invalidBinding(
                "The stored recipe or geometry/schedule fingerprint does not reproduce the binding.")
        }
        let assemblyPanels = FloeBuildingCADCabinetRules.assemblyPanels(assembly)
        guard Set(binding.panelBindings.map(\.panelID)) == Set(assemblyPanels.keys),
              binding.panelBindings.count == assembly.panels.count else {
            throw FloeBuildingCADError.invalidBinding("Panel ids/count do not match the recipe.")
        }
        let state = try nativeState()
        var panelBodyIDs = Set<UUID>()
        var panelInstanceIDs = Set<UUID>()
        for panelBinding in binding.panelBindings {
            guard let panel = assemblyPanels[panelBinding.panelID] else {
                throw FloeBuildingCADError.invalidBinding("Unknown panel \(panelBinding.panelID).")
            }
            guard panel.role.rawValue == panelBinding.role,
                  FloeBuildingCADGeometry.approxEqual(
                    FloeBuildingCADCabinetRules.rectMin(panel),
                    panelBinding.sketchRectMin, tolerance: 1e-7),
                  FloeBuildingCADGeometry.approxEqual(
                    FloeBuildingCADCabinetRules.rectMax(panel),
                    panelBinding.sketchRectMax, tolerance: 1e-7),
                  abs(panel.sizeMM.z - panelBinding.extrusionMM) <= 1e-7,
                  FloeBuildingCADGeometry.approxEqual(panel.originMM.values, panelBinding.originMM, tolerance: 1e-7),
                  FloeBuildingCADGeometry.approxEqual(panel.sizeMM.values, panelBinding.sizeMM, tolerance: 1e-7),
                  panel.material.id == panelBinding.materialID,
                  panel.material.version == panelBinding.materialVersion else {
                throw FloeBuildingCADError.invalidBinding(
                    "Panel \(panelBinding.panelID) values do not match the stored recipe.")
            }
            guard let sketch = state.sketches[panelBinding.sketchID],
                  sketch.entities.count == 1,
                  let entity = sketch.entities.first,
                  entity.kind == "rect",
                  let liveMin = entity.minimum,
                  let liveMax = entity.maximum,
                  FloeBuildingCADGeometry.approxEqual(liveMin, panelBinding.sketchRectMin, tolerance: 1e-4),
                  FloeBuildingCADGeometry.approxEqual(liveMax, panelBinding.sketchRectMax, tolerance: 1e-4) else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(panelBinding.panelID): its owned rectangle was moved, resized or deleted.")
            }
            let expectedFeatures = Set([panelBinding.extrudeFeatureID] + panelBinding.moverFeatureIDs)
            for featureID in expectedFeatures {
                guard let feature = state.features[featureID], !feature.suppressed else {
                    throw FloeBuildingCADError.externalModification(
                        "Panel \(panelBinding.panelID): expected feature \(featureID.uuidString) is missing or suppressed.")
                }
            }
            guard let extrude = state.features[panelBinding.extrudeFeatureID],
                  extrude.kind == "extrude",
                  extrude.referencedSketches.contains(panelBinding.sketchID) else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(panelBinding.panelID): the owned extrude feature no longer references its sketch.")
            }
            for moverID in panelBinding.moverFeatureIDs {
                guard let mover = state.features[moverID], mover.kind == "transform" else {
                    throw FloeBuildingCADError.externalModification(
                        "Panel \(panelBinding.panelID): the owned move feature \(moverID.uuidString) changed kind.")
                }
            }
            for feature in state.features.values {
                guard feature.outputBodyIDs.contains(panelBinding.bodyID)
                        || feature.bodyIDs.contains(panelBinding.bodyID) else { continue }
                guard expectedFeatures.contains(feature.id) else {
                    throw FloeBuildingCADError.externalModification(
                        "Panel \(panelBinding.panelID): an unexpected feature \(feature.id.uuidString) references its body.")
                }
            }
            let measured: FloeBuildingCADMeasurement
            do {
                measured = try measureNativeBody(panelBinding.bodyID)
            } catch {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(panelBinding.panelID): its recorded body is missing and cannot be measured.")
            }
            let expected = FloeBuildingCADCabinetRules.worldBounds(panel)
            guard measured.analyticBRep,
                  FloeBuildingCADGeometry.approxEqual(measured.boundsMinimum, expected.minimum,
                                                      tolerance: FloeBuildingCADGeometry.linearToleranceMM),
                  FloeBuildingCADGeometry.approxEqual(measured.boundsMaximum, expected.maximum,
                                                      tolerance: FloeBuildingCADGeometry.linearToleranceMM),
                  abs(measured.volumeMM3 - panel.volumeM3 * 1_000_000_000)
                    <= max(FloeBuildingCADGeometry.volumeToleranceMM3,
                           panel.volumeM3 * 1_000_000_000 * 1e-7) else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(panelBinding.panelID): the body bounds/volume no longer match the binding. "
                    + "Actual \(measured.boundsMinimum)…\(measured.boundsMaximum), expected \(expected.minimum)…\(expected.maximum).")
            }
            guard let instance = state.instances[panelBinding.instanceID],
                  instance.bodyID == panelBinding.bodyID,
                  instance.effectiveBodyID == panelBinding.bodyID,
                  !instance.hidden, !instance.isSubassembly, instance.parentID == nil,
                  FloeBuildingCADGeometry.approxEqual(instance.position, [0, 0, 0], tolerance: 1e-9),
                  FloeBuildingCADGeometry.quaternionDot(instance.rotation, [0, 0, 0, 1]) > 1 - 1e-9,
                  FloeBuildingCADGeometry.approxEqual(instance.scale, [1, 1, 1], tolerance: 1e-9) else {
                throw FloeBuildingCADError.externalModification(
                    "Panel \(panelBinding.panelID): its assembly instance is missing, hidden or moved.")
            }
            panelBodyIDs.insert(panelBinding.bodyID)
            panelInstanceIDs.insert(panelBinding.instanceID)
        }
        for instance in state.instances.values {
            let referencesPanel = panelBodyIDs.contains(instance.bodyID)
                || instance.effectiveBodyID.map(panelBodyIDs.contains) == true
            if referencesPanel, !panelInstanceIDs.contains(instance.id) {
                throw FloeBuildingCADError.externalModification(
                    "An extra assembly instance \(instance.id.uuidString) references a cabinet panel body.")
            }
        }
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeElectronicsCore
import FloeElectronicsUI
@testable import FloeApp

@Suite("Electronics cross-probe read contract", .serialized)
@MainActor struct ElectronicsCrossProbeReadTests {
    @Test func existingReadSelectionReturnsRealCounterpartsAndFencesADifferentSavedOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var p = EDAProject(title: "Read-only cross-probe")
        let symbol = EDASymbolDefinition(name: "R", graphics: [.rectangle(.init(-1,-1), .init(1,1), width: 0.2)])
        let definition = EDAFootprintDefinition(name: "0603", pads: [.init(number: "1", position: .zero)])
        let component = EDAComponent(symbolID: symbol.id, footprintID: definition.id, reference: "R1")
        let placement = EDASymbolPlacement(componentID: component.id, position: .init(10,20))
        let footprint = EDAFootprint(definitionID: definition.id, componentID: component.id, position: .init(30,40))
        p.symbols = [symbol]; p.footprints = [definition]; p.components = [component]
        p.sheets[0].symbols = [placement]; p.boards[0].footprints = [footprint]
        let store = try await EDAProjectStore.create(root: directory.appendingPathComponent("Electronics"), project: p)
        let original = try await store.load(), bytes = try Data(contentsOf: store.root.appendingPathComponent("project.json"))
        let native = try await ElectronicsProjectSession.open(id: p.id, directory: directory)
        native.workbench.selection = .init(context: .schematic(sheetID: p.sheets[0].id), objectIDs: [placement.id])
        let receipt = try StudioElectronicsRuntime.selection(id: p.id, directory: directory, savedProject: original.project)
        #expect(receipt.crossProbeStatus == "availableReadOnlyTargets")
        #expect(!receipt.crossProbeTargetsTruncated && receipt.crossProbeTargets.count == 1)
        let target = try #require(receipt.crossProbeTargets.first)
        #expect(target.context == "board" && target.contextID == p.boards[0].id)
        #expect(target.objectID == footprint.id && target.componentID == component.id && target.unit == nil)
        #expect(native.workbench.focusRequest == nil && !native.workbench.canUndo)
        var different = original.project; different.title = "same revision, different original"
        let stale = try StudioElectronicsRuntime.selection(id: p.id, directory: directory, savedProject: different)
        #expect(stale.crossProbeStatus == "savedOriginalDiffersFromNativeSession" && stale.crossProbeTargets.isEmpty)
        var deniedForeignDirectory = false
        do { _ = try StudioElectronicsRuntime.selection(id: p.id, directory: directory.appendingPathComponent("foreign"), savedProject: original.project) }
        catch PersonalContentError.changedDocument { deniedForeignDirectory = true }
        catch { Issue.record("Unexpected authority failure: \(error)") }
        #expect(deniedForeignDirectory)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("project.json")) == bytes)
        #expect(await native.flushForClose())
        let closed = try StudioElectronicsRuntime.selection(id: p.id, directory: directory, savedProject: original.project)
        #expect(closed.status == "noExistingNativeSession" && closed.crossProbeTargets.isEmpty)
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDAEngineeringTests {
    @Test func forwardAnnotationRetainsPlacementAndUpdatesTheRealPadNets() throws {
        let project = fixture()
        let plan = try EDAForwardAnnotation.plan(project, boardID: project.boards[0].id)
        #expect(plan.canApply && plan.addedComponentIDs.count == 2)
        let net = try #require(EDAConnectivity.derive(project).nets.first)
        #expect(plan.updatedBoard.footprints.allSatisfy { $0.padNets["1"] == net.id })
        var editor = try EDAEditingSession(project: project)
        try EDAForwardAnnotation.apply(plan, to: &editor)
        let placed = editor.project.boards[0].footprints
        let repeated = try EDAForwardAnnotation.plan(editor.project, boardID: plan.boardID)
        #expect(repeated.canApply && repeated.addedComponentIDs.isEmpty)
        #expect(repeated.updatedBoard.footprints == placed)
        #expect(throws: EDAError.self) { try EDAForwardAnnotation.apply(plan, to: &editor) }
    }

    @Test func splittingARoutedNetCannotSilentlyReassignOrDeleteItsCopper() throws {
        var editor = try EDAEditingSession(project: fixture())
        let initial = try EDAForwardAnnotation.plan(editor.project, boardID: editor.project.boards[0].id)
        try EDAForwardAnnotation.apply(initial, to: &editor)
        let footprints = editor.project.boards[0].footprints
        let oldNet = try #require(footprints[0].padNets["1"])
        let track = EDATrack(netID: oldNet, points: [footprints[0].position, footprints[1].position])
        try editor.apply([.putTrack(board: initial.boardID, track)], expectedRevision: 1)
        let wire = try #require(editor.project.sheets[0].wires.first)
        try editor.apply([.removeSchematicObject(sheet: editor.project.sheets[0].id, object: wire.id)], expectedRevision: 2)
        let plan = try EDAForwardAnnotation.plan(editor.project, boardID: initial.boardID)
        #expect(!plan.canApply && plan.conflictingNetIDs == [oldNet])
        let before = editor.project
        #expect(throws: EDAError.self) { try EDAForwardAnnotation.apply(plan, to: &editor) }
        #expect(editor.project == before)
        #expect(editor.project.boards[0].tracks == [track])
    }

    @Test func addingAPinToTheSameNetMigratesItsIdentityAndPreservesRoutingGeometry() throws {
        var editor = try EDAEditingSession(project: fixture())
        let initial = try EDAForwardAnnotation.plan(editor.project, boardID: editor.project.boards[0].id)
        try EDAForwardAnnotation.apply(initial, to: &editor)
        let fp = editor.project.boards[0].footprints
        let net = try #require(fp[0].padNets["1"])
        let track = EDATrack(netID: net, points: [fp[0].position, fp[1].position])
        let component = EDAComponent(symbolID: editor.project.symbols[0].id,
                                      footprintID: editor.project.footprints[0].id, reference: "R3")
        try editor.apply([.putTrack(board: initial.boardID, track), .putComponent(component),
                          .placeSymbol(sheet: editor.project.sheets[0].id, .init(componentID: component.id, position: .init(5, 0)))], expectedRevision: 1)
        let plan = try EDAForwardAnnotation.plan(editor.project, boardID: initial.boardID)
        #expect(plan.canApply && plan.conflictingNetIDs.isEmpty)
        let next = try #require(plan.updatedBoard.footprints.first?.padNets["1"])
        #expect(next != net)
        #expect(plan.updatedBoard.tracks[0].netID == next)
        #expect(plan.updatedBoard.tracks[0].points == track.points)
        #expect(plan.updatedBoard.tracks[0].id == track.id)
    }

    @Test func missingLibrariesAndLockedFootprintsRemainReviewableConflicts() throws {
        var project = fixture()
        var plan = try EDAForwardAnnotation.plan(project, boardID: project.boards[0].id)
        project.boards[0] = plan.updatedBoard
        project.boards[0].footprints[0].locked = true
        project.components[0].reference = "RENAMED"
        plan = try EDAForwardAnnotation.plan(project, boardID: project.boards[0].id)
        #expect(!plan.canApply && plan.lockedFootprintIDs == [project.boards[0].footprints[0].id])
        project.components[1].footprintID = UUID()
        plan = try EDAForwardAnnotation.plan(project, boardID: project.boards[0].id)
        #expect(!plan.canApply && plan.missingFootprintComponentIDs == [project.components[1].id])
    }

    @Test func electricalRulesObserveTheActualPinTypesAndConnections() throws {
        var project = fixture()
        project.symbols[0].pins[0].type = .output
        var report = try EDAERC.check(project)
        #expect(report.issues.contains { $0.code == "conflicting_outputs" })
        let inputSymbol = EDASymbolDefinition(name: "Input", pins: [.init(number: "1", position: .zero, type: .input)])
        project.symbols.append(inputSymbol); project.components[1].symbolID = inputSymbol.id
        report = try EDAERC.check(project)
        #expect(!report.issues.contains { ["conflicting_outputs", "undriven_input", "unconnected_pin"].contains($0.code) })
        project.sheets[0].noConnects = [.init(position: .zero)]
        #expect(try EDAERC.check(project).issues.contains { $0.code == "connected_no_connect" })
    }

    @Test func unpoweredPinsAndDuplicateReferencesProduceActionableObjects() throws {
        var project = fixture()
        project.symbols[0].pins[0].type = .powerInput
        project.components[1].reference = project.components[0].reference
        let report = try EDAERC.check(project)
        #expect(report.issues.contains { $0.code == "undriven_power" && $0.severity == .error && $0.netID != nil })
        #expect(report.issues.contains { $0.code == "duplicate_reference" && Set($0.objectIDs) == Set(project.components.map(\.id)) })
        #expect(throws: EDAError.cancelled) { try EDAERC.check(project, cancelled: { true }) }
    }

    private func fixture() -> EDAProject {
        var project = EDAProject(title: "Two connected components")
        let symbol = EDASymbolDefinition(name: "Pin", pins: [.init(number: "1", position: .zero)])
        let footprint = EDAFootprintDefinition(name: "Pad", pads: [.init(number: "1", position: .zero)])
        let a = EDAComponent(symbolID: symbol.id, footprintID: footprint.id, reference: "R1")
        let b = EDAComponent(symbolID: symbol.id, footprintID: footprint.id, reference: "R2")
        project.symbols = [symbol]; project.footprints = [footprint]; project.components = [a, b]
        project.sheets[0].symbols = [.init(componentID: a.id), .init(componentID: b.id, position: .init(10, 0))]
        project.sheets[0].wires = [.init(points: [.zero, .init(10, 0)])]
        return project
    }
}

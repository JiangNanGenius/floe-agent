// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDABackAnnotationTests {
    private func fixture() throws -> EDAProject {
        var p = EDAProject(title: "Back annotation original")
        let symbol = EDASymbolDefinition(name: "Pin", pins: [.init(number: "1", position: .zero)])
        let footprint = EDAFootprintDefinition(name: "One pad", pads: [.init(number: "1", position: .zero)])
        let a = EDAComponent(symbolID: symbol.id, footprintID: footprint.id, reference: "R1", value: "10k", fields: ["owned": "preserve"])
        let b = EDAComponent(symbolID: symbol.id, footprintID: footprint.id, reference: "R2", value: "20k")
        p.symbols = [symbol]; p.footprints = [footprint]; p.components = [a, b]
        p.sheets[0].symbols = [.init(componentID: a.id), .init(componentID: b.id, position: .init(10, 0))]
        p.sheets[0].wires = [.init(points: [.zero, .init(10, 0)])]
        let forward = try EDAForwardAnnotation.plan(p, boardID: p.boards[0].id)
        p.boards[0] = forward.updatedBoard
        let net = try #require(p.boards[0].footprints[0].padNets["1"])
        p.boards[0].tracks = [.init(netID: net, points: [.init(5, 5), .init(15, 5)])]
        return p
    }

    @Test func referenceSwapIsOneTransactionAndDoesNotMoveCopperOrInventLinks() throws {
        var p = try fixture()
        p.boards[0].footprints[0].reference = "R2"; p.boards[0].footprints[1].reference = "R1"
        p.boards[0].footprints[0].value = "47k"
        let independent = EDAFootprint(definitionID: p.footprints[0].id, reference: "TP1")
        p.boards[0].footprints.append(independent)
        let plan = try EDABackAnnotation.plan(p, boardID: p.boards[0].id)
        #expect(plan.preview.canApply && plan.preview.changes.count == 2)
        #expect(plan.preview.issues.contains { $0.code == .unlinkedFootprint && !$0.blocking })
        var editor = try EDAEditingSession(project: p)
        try EDABackAnnotation.apply(plan, to: &editor)
        #expect(editor.project.revision == 1)
        #expect(editor.project.components.map(\.reference) == ["R2", "R1"])
        #expect(editor.project.components[0].value == "47k" && editor.project.components[0].fields == p.components[0].fields)
        #expect(editor.project.boards == p.boards && editor.project.sheets == p.sheets)
        #expect(try EDAConnectivity.derive(editor.project).nets.map(\.id) == EDAConnectivity.derive(p).nets.map(\.id))
        try editor.undo(expectedRevision: 1)
        #expect(editor.project.components == p.components && editor.project.boards == p.boards)
        try editor.redo(expectedRevision: 2)
        #expect(editor.project.components.map(\.reference) == ["R2", "R1"])
    }

    @Test func fieldChoicesAndCompatibleAssignmentPreserveOtherComponentData() throws {
        var p = try fixture()
        let alternate = EDAFootprintDefinition(name: "Alternative", pads: [.init(number: "1", position: .zero)])
        p.footprints.append(alternate)
        p.boards[0].footprints[0].definitionID = alternate.id
        p.boards[0].footprints[0].reference = "R9"; p.boards[0].footprints[0].value = "33k"
        var editor = try EDAEditingSession(project: p)
        let values = try EDABackAnnotation.plan(p, boardID: p.boards[0].id,
            options: .init(references: false, values: true, footprintAssignments: false))
        try EDABackAnnotation.apply(values, to: &editor)
        #expect(editor.project.components[0].reference == "R1" && editor.project.components[0].value == "33k")
        #expect(editor.project.components[0].footprintID == p.components[0].footprintID)
        let assignments = try EDABackAnnotation.plan(editor.project, boardID: p.boards[0].id,
            options: .init(references: false, values: false, footprintAssignments: true))
        try EDABackAnnotation.apply(assignments, to: &editor)
        #expect(editor.project.components[0].footprintID == alternate.id && editor.project.components[0].fields == ["owned": "preserve"])
    }

    @Test func duplicateOrInvalidReferencesBlockTheWholePlan() throws {
        for reference in ["R2", "r2", "", " R3", "R3\n"] {
            var p = try fixture(); p.boards[0].footprints[0].reference = reference; p.boards[0].footprints[0].value = "uncommitted"
            let plan = try EDABackAnnotation.plan(p, boardID: p.boards[0].id)
            #expect(!plan.preview.canApply)
            var editor = try EDAEditingSession(project: p)
            #expect(throws: EDAError.self) { try EDABackAnnotation.apply(plan, to: &editor) }
            #expect(editor.project == p && !editor.canUndo)
        }
    }

    @Test func ambiguousLinksAndMissingPinsCannotRewriteSchematic() throws {
        var p = try fixture()
        var duplicate = p.boards[0].footprints[0]; duplicate.id = UUID(); p.boards[0].footprints.append(duplicate)
        #expect(try EDABackAnnotation.plan(p, boardID: p.boards[0].id).preview.issues.contains { $0.code == .multipleFootprints && $0.blocking })
        p = try fixture()
        let wrong = EDAFootprintDefinition(name: "Wrong pin", pads: [.init(number: "2", position: .zero)])
        p.footprints.append(wrong); p.boards[0].footprints[0].definitionID = wrong.id; p.boards[0].footprints[0].padNets = [:]
        let plan = try EDABackAnnotation.plan(p, boardID: p.boards[0].id)
        #expect(!plan.preview.canApply && plan.preview.issues.contains { $0.code == .incompatibleFootprint })
    }

    @Test func sourceIdentityCancellationAndReadOnlyAreAtomic() throws {
        var p = try fixture(); p.boards[0].footprints[0].reference = "R8"
        let plan = try EDABackAnnotation.plan(p, boardID: p.boards[0].id)
        #expect(throws: EDAError.cancelled) { try EDABackAnnotation.plan(p, boardID: p.boards[0].id, cancelled: { true }) }
        var editor = try EDAEditingSession(project: p)
        #expect(throws: EDAError.cancelled) { try EDABackAnnotation.apply(plan, to: &editor, cancelled: { true }) }
        #expect(editor.project == p)
        var otherBytes = p; otherBytes.components[0].value = "different original at the same revision"
        var other = try EDAEditingSession(project: otherBytes)
        #expect(throws: EDAError.self) { try EDABackAnnotation.apply(plan, to: &other) }
        #expect(other.project == otherBytes)
        var readOnly = try EDAEditingSession(project: p, readOnly: true)
        #expect(throws: EDAError.readOnly) { try EDABackAnnotation.apply(plan, to: &readOnly) }
        try editor.apply([.rename("Later original")], expectedRevision: 0)
        #expect(throws: EDAError.staleRevision(expected: 0, actual: 1)) { try EDABackAnnotation.apply(plan, to: &editor) }
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@Suite("Schematic bus drawing")
struct EDBusDrawingTests {
    private func draft(_ project: EDAProject, points: [EDAPoint]) throws -> EDBusDrawingDraft {
        var value = try EDBusDrawingDraft(project: project, sheetID: project.sheets[0].id)
        for point in points { try value.append(point) }
        return value
    }

    @Test func busToolIsAvailableOnSchematicOnly() {
        #expect(EDCanvasTool.schematicTools.map(\.rawValue).contains("bus"))
        #expect(!EDCanvasTool.boardTools.map(\.rawValue).contains("bus"))
    }

    @Test func pointGestureKeepsAnOpenPolylineAndUndoDoesNotInventMembers() throws {
        let project = EDAProject(title: "draw exact points")
        var drawing = try EDBusDrawingDraft(project: project, sheetID: project.sheets[0].id)
        #expect(!drawing.canFinish)
        try drawing.append(.zero)
        try drawing.append(.zero)
        try drawing.append(.init(EDAGeometry.tolerance / 2, 0))
        #expect(drawing.points == [.zero]); #expect(!drawing.canFinish)
        try drawing.append(.init(10, 0)); try drawing.append(.init(10, 10))
        drawing.undoLastPoint(); #expect(drawing.canFinish)
        try drawing.append(.init(12.1234, -3.5678))
        let plan = try drawing.plan(), repeatedPlan = try drawing.plan()
        #expect(plan.bus.points == [.zero, .init(10, 0), .init(12.1234, -3.5678)])
        #expect(plan.bus.points.last != plan.bus.points.first)
        #expect(plan.bus.members.isEmpty); #expect(plan.bus.entries == nil)
        #expect(plan.bus.id == repeatedPlan.bus.id); #expect(plan.edits.count == 1)
        drawing.undoLastPoint(); drawing.undoLastPoint(); drawing.undoLastPoint()
        #expect(drawing.points.isEmpty); #expect(!drawing.canFinish)
    }

    @Test func geometryBudgetAndCancelRejectInvalidFinishWithoutRepairingInput() throws {
        let project = EDAProject(title: "bounded bus")
        var drawing = try EDBusDrawingDraft(project: project, sheetID: project.sheets[0].id)
        #expect(throws: EDAError.self) { try drawing.plan() }
        for point in [EDAPoint(.nan, 0), .init(0, .infinity), .init(100_001, 0)] {
            #expect(throws: EDAError.self) { try drawing.append(point) }
        }
        #expect(drawing.points.isEmpty)
        for index in 0..<EDBusDrawingDraft.maximumPoints { try drawing.append(.init(Double(index), 0)) }
        try drawing.append(.init(Double(EDBusDrawingDraft.maximumPoints - 1), 0))
        #expect(drawing.points.count == EDBusDrawingDraft.maximumPoints)
        #expect(throws: EDAError.self) { try drawing.append(.init(0, 1)) }
        drawing.cancel()
        #expect(drawing.points.isEmpty); #expect(!drawing.canFinish)
        #expect(throws: EDAError.cancelled) { try drawing.plan() }
        #expect(throws: EDAError.cancelled) { try drawing.append(.zero) }
        #expect(throws: EDAError.self) { try EDBusDrawingDraft(project: project, sheetID: UUID()) }
    }

    @MainActor @Test func cancelBeforeFinishOrCommitDoesNotSaveOrCreateUndo() async throws {
        let project = EDAProject(title: "cancel bus gesture")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: project)
        let session = try await EDWorkbenchSession(store: store)
        let before = try await store.load()
        var drawing = try draft(project, points: [.zero, .init(10, 0), .init(20, 10)])
        drawing.cancel()
        #expect(throws: EDAError.cancelled) { try drawing.plan() }
        #expect(session.project == project); #expect(!session.canUndo)
        #expect(try await store.load() == before)

        let plan = try draft(project, points: [.zero, .init(10, 0)]).plan()
        let pending = Task { @MainActor in try await plan.apply(to: session) }
        pending.cancel() // This actor has not yielded: cancellation precedes admission.
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(session.project == project); #expect(!session.canUndo)
        #expect(try await store.load() == before)
    }

    @MainActor @Test func finishSavesOneBusAndOneUndoThenReopensTheSameOriginal() async throws {
        let project = EDAProject(title: "saved bus"), sheetID = project.sheets[0].id
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: project)
        let session = try await EDWorkbenchSession(store: store)
        let plan = try draft(project, points: [.zero, .init(0, 20), .init(30, 20)]).plan()
        var saves = 0; session.onSaved = { _ in saves += 1 }
        try await plan.apply(to: session)
        #expect(saves == 1); #expect(session.revision == 1); #expect(session.canUndo)
        #expect(!session.isDirty); #expect(session.project.sheets[0].buses == [plan.bus])
        #expect(try await store.load().project == session.project)
        #expect(plan.selection.context == .schematic(sheetID: sheetID))
        #expect(EDBusInspectorSelection.read(session.project, sheetID: sheetID,
            objectIDs: plan.selection.objectIDs) == .bus(plan.bus))
        #expect(EDCanvasInteraction.hit(project: session.project, context: .schematic(sheetID: sheetID),
            at: .init(0, 12), tolerance: 0.01) == plan.bus.id)
        #expect(EDCanvasInteraction.hit(project: session.project, context: .schematic(sheetID: sheetID),
            at: .init(15, 10), tolerance: 0.01) == nil)
        #expect(try EDAERC.check(session.project).issues.contains {
            $0.code == "bus_members_missing" && $0.objectIDs.contains(plan.bus.id)
        })
        await #expect(throws: EDAError.staleRevision(expected: 0, actual: 1)) { try await plan.apply(to: session) }
        #expect(saves == 1); #expect(session.project.sheets[0].buses.count == 1)
        try await session.undo(expectedRevision: 1)
        #expect(session.project.sheets[0].buses.isEmpty); #expect(!session.canUndo)
        #expect(try await store.load().project == session.project)
        try await session.redo(expectedRevision: 2)
        let reopened = try await EDWorkbenchSession(store: store)
        #expect(reopened.revision == 3); #expect(reopened.project.sheets[0].buses == [plan.bus])
    }

    @MainActor @Test func staleOrReplacedOriginalCannotAdoptTheDraft() async throws {
        var project = EDAProject(title: "fenced drawing")
        var second = project.sheets[0]; second.id = UUID(); project.sheets.append(second)
        let plan = try draft(project, points: [.zero, .init(10, 0)]).plan()
        var changed = project; changed.title = "same-revision replacement"
        #expect(throws: EDAError.self) { try plan.validateSource(changed) }
        changed = project; changed.sheets.removeFirst()
        #expect(throws: EDAError.self) { try plan.validateSource(changed) }
        changed = project; changed.id = UUID()
        #expect(throws: EDAError.self) { try plan.validateSource(changed) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: project)
        let session = try await EDWorkbenchSession(store: store)
        try await session.apply([.putWire(sheet: project.sheets[0].id, .init(points: [.init(20, 0), .init(30, 0)]))], expectedRevision: 0)
        let saved = try await store.load()
        await #expect(throws: EDAError.staleRevision(expected: 0, actual: 1)) { try await plan.apply(to: session) }
        #expect(session.project.sheets[0].buses.isEmpty)
        #expect(try await store.load() == saved)
        await session.close()
        #expect(session.isClosed)
        let closedPlan = try draft(session.project, points: [.zero, .init(0, 10)]).plan()
        await #expect(throws: EDAError.cancelled) { try await closedPlan.apply(to: session) }
        #expect(try await store.load() == saved)
    }

    @MainActor @Test func independentCASWriterRetainsItsSavedOriginalAndTheLocalBusProposal() async throws {
        let project = EDAProject(title: "bus CAS")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: project)
        let session = try await EDWorkbenchSession(store: store)
        let plan = try draft(project, points: [.zero, .init(10, 10)]).plan()
        let writer = try EDAProjectStore(root: root, projectID: project.id), before = try await writer.load()
        var external = before.project; external.title = "external author"; external.revision += 1
        let first = try await writer.save(external, expectedRevision: before.project.revision, expectedDigest: before.digest)
        await #expect(throws: EDAError.staleRevision(expected: 0, actual: 1)) { try await plan.apply(to: session) }
        #expect(try await writer.load() == first)
        #expect(session.conflictWithOriginal); #expect(session.isDirty); #expect(session.canUndo)
        #expect(session.project.sheets[0].buses == [plan.bus])
        try await session.refresh(discardChanges: true)
        #expect(session.project == external); #expect(!session.canUndo)
    }

    @Test func aBusCrossingScalarWiresDoesNotConnectTheirNets() throws {
        var project = EDAProject(title: "drawing is not wiring")
        project.sheets[0].wires = [.init(points: [.init(-5, 5), .init(5, 5)]), .init(points: [.init(-5, 15), .init(5, 15)])]
        project.sheets[0].labels = [.init(name: "D0", position: .init(-5, 5)), .init(name: "D1", position: .init(-5, 15))]
        let nets = try EDAConnectivity.derive(project).nets
        let plan = try draft(project, points: [.zero, .init(0, 20)]).plan()
        var editor = try EDAEditingSession(project: project)
        try editor.apply(plan.edits, expectedRevision: 0)
        #expect(try EDAConnectivity.derive(editor.project).nets == nets)
        #expect(editor.project.sheets[0].wires == project.sheets[0].wires)
        #expect(editor.project.sheets[0].labels == project.sheets[0].labels)
    }

    @MainActor @Test func blankCanvasBusCanDeclareMembersThenUnfoldTwoSeparateNets() async throws {
        let project = EDAProject(title: "draw properties unfold"), sheetID = project.sheets[0].id
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: project)
        let session = try await EDWorkbenchSession(store: store)
        let drawing = try draft(project, points: [.zero, .init(0, 30), .init(20, 30)]).plan()
        try await drawing.apply(to: session)
        var bus = try #require(session.project.sheets[0].buses.first)
        bus.name = "DATA"; bus.members = ["D0", "D1"]
        let edits = try EDBusInspectorEdits.bus(bus, sheetID: sheetID, project: session.project)
        try await session.apply(edits, expectedRevision: 1)
        for (member, y) in [("D0", 5.0), ("D1", 15.0)] {
            let unfold = try EDBusUnfoldDraft(project: session.project, sheetID: sheetID,
                busID: bus.id, member: member, at: .init(0, y))
            let plan = try unfold.plan(wirePoints: [.init(2, y + 2), .init(10, y + 2)])
            try plan.validateSource(session.project)
            try await session.apply(plan.edits, expectedRevision: plan.revision, cancelBeforeCommit: true)
        }
        let saved = try await store.load(), nets = try EDAConnectivity.derive(saved.project).nets
        let d0 = try #require(nets.first { $0.name == "D0" }), d1 = try #require(nets.first { $0.name == "D1" })
        #expect(d0.id != d1.id); #expect(d0.wireIDs.count == 1); #expect(d1.wireIDs.count == 1)
        #expect(Set(d0.wireIDs).isDisjoint(with: d1.wireIDs))
        #expect(saved.project.sheets[0].buses[0].entries?.count == 2)
        #expect(saved.project.sheets[0].buses[0].members == ["D0", "D1"])
        try await session.undo(expectedRevision: 4)
        #expect(session.project.sheets[0].buses[0].entries?.count == 1)
        #expect(session.project.sheets[0].labels.map(\.name) == ["D0"])
        #expect(try await store.load().project == session.project)
    }
}

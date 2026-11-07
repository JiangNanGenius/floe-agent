// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDAOriginalTests {
    @Test func crossingConductorsRequireAnExplicitJunction() throws {
        var project = EDAProject(title: "Crossing")
        project.sheets[0].wires = [EDAWire(points: [.init(-5, 0), .init(5, 0)]),
                                   EDAWire(points: [.init(0, -5), .init(0, 5)])]
        #expect(try EDAConnectivity.derive(project).nets.count == 2)
        project.sheets[0].junctions = [.init(position: .zero)]
        #expect(try EDAConnectivity.derive(project).nets.count == 1)
    }

    @Test func aWireBendDoesNotCreateAJunctionButAnEndpointDoes() throws {
        var project = EDAProject(title: "Bend")
        project.sheets[0].wires = [EDAWire(points: [.init(-5, 0), .zero, .init(0, 5)]),
                                   EDAWire(points: [.init(-5, -5), .init(5, 5)])]
        #expect(try EDAConnectivity.derive(project).nets.count == 2)
        project.sheets[0].wires[1].points = [.init(-5, -5), .zero]
        #expect(try EDAConnectivity.derive(project).nets.count == 1)
    }

    @Test func localLabelOnlyNetsKeepSeparateIdentitiesAndGlobalLabelsJoin() throws {
        var project = EDAProject(title: "Labels")
        project.sheets[0].labels = [.init(name: "SIGNAL", position: .zero)]
        project.sheets.append(.init(name: "Child", labels: [.init(name: "SIGNAL", position: .zero)]))
        let local = try EDAConnectivity.derive(project)
        #expect(local.nets.count == 2)
        #expect(Set(local.nets.map(\.id)).count == 2)
        project.sheets[0].labels[0].scope = .global
        project.sheets[1].labels[0].scope = .global
        #expect(try EDAConnectivity.derive(project).nets.count == 1)
    }

    @Test func hierarchyJoinsOnlyTheNamedPort() throws {
        var project = EDAProject(title: "Hierarchy")
        let child = EDASheet(name: "Child", labels: [
            .init(name: "IN", position: .zero, scope: .hierarchical),
            .init(name: "OUT", position: .init(2, 0), scope: .hierarchical)])
        project.sheets.append(child)
        project.sheets[0].labels = [.init(name: "MAIN", position: .zero)]
        project.sheets[0].children = [.init(childSheetID: child.id, name: "Child",
                                            ports: [.init(name: "IN", position: .zero)])]
        let nets = try EDAConnectivity.derive(project).nets
        #expect(nets.count == 2)
        #expect(nets.contains { Set($0.labels) == ["IN", "MAIN"] })
    }

    @Test func mirroredRotatedPinsAttachToTheirTransformedGeometry() throws {
        var project = EDAProject(title: "Pin transform")
        let symbol = EDASymbolDefinition(name: "One pin", pins: [.init(number: "1", position: .init(2, 0))])
        let component = EDAComponent(symbolID: symbol.id, reference: "U1")
        project.symbols = [symbol]; project.components = [component]
        project.sheets[0].symbols = [.init(componentID: component.id, position: .init(10, 10), angle: 90, mirrored: true)]
        let wire = EDAWire(points: [.init(10, 8), .init(15, 8)])
        project.sheets[0].wires = [wire]
        let net = try #require(EDAConnectivity.derive(project).net(for: .init(componentID: component.id, number: "1")))
        #expect(net.wireIDs == [wire.id])
    }

    @Test func invalidBatchRollsBackAllEditsAndUndoState() throws {
        let project = EDAProject(title: "Original")
        var editor = try EDAEditingSession(project: project)
        #expect(throws: EDAError.self) {
            try editor.apply([.rename("Partial"), .putWire(sheet: project.sheets[0].id,
                              EDAWire(points: [.zero, .init(.nan, 1)]))], expectedRevision: 0)
        }
        #expect(editor.project == project)
        #expect(!editor.canUndo && !editor.canRedo && !editor.isDirty)
    }

    @Test func undoRedoUseMonotonicRevisionsAndRejectStaleWrites() throws {
        var editor = try EDAEditingSession(project: EDAProject(title: "Original"))
        try editor.apply([.rename("Changed")], expectedRevision: 0)
        try editor.undo(expectedRevision: 1)
        #expect(editor.project.title == "Original" && editor.project.revision == 2)
        #expect(throws: EDAError.staleRevision(expected: 1, actual: 2)) {
            try editor.apply([.rename("Stale")], expectedRevision: 1)
        }
        try editor.redo(expectedRevision: 2)
        #expect(editor.project.title == "Changed" && editor.project.revision == 3)
        #expect(throws: EDAError.cancelled) {
            try editor.apply([.rename("Cancelled")], expectedRevision: 3, cancelled: { true })
        }
        #expect(editor.project.title == "Changed" && editor.project.revision == 3)
    }

    @Test func twoIndependentStoresHaveOnlyOneCompareAndSwapWinner() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = EDAProject(title: "Original")
        let first = try await EDAProjectStore.create(root: root, project: project)
        let second = try EDAProjectStore(root: root, projectID: project.id)
        let initial = try await first.load()
        var a = project; a.title = "A"; a.revision = 1
        var b = project; b.title = "B"; b.revision = 1
        let candidates = [a, b], stores = [first, second]
        let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<2 {
                group.addTask {
                    do {
                        _ = try await stores[i].save(candidates[i], expectedRevision: 0, expectedDigest: initial.digest)
                        return true
                    } catch EDAError.staleRevision { return false }
                }
            }
            var count = 0
            for try await winner in group { if winner { count += 1 } }
            return count
        }
        #expect(wins == 1)
        let saved = try await first.load(), history = try await second.history()
        #expect(saved.project.revision == 1)
        #expect(history.map(\.project) == [project])
        #expect(history.first?.digest == initial.digest)
    }

    @Test func anExternalSameRevisionReplacementCannotPassTheDigestCheck() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = EDAProject(title: "Original")
        let store = try await EDAProjectStore.create(root: root, project: project)
        let initial = try await store.load()
        var foreign = project; foreign.title = "External"
        let bytes = try JSONEncoder().encode(foreign)
        try bytes.write(to: root.appendingPathComponent("project.json"), options: .atomic)
        var proposed = project; proposed.title = "Overwrite"; proposed.revision = 1
        await #expect(throws: EDAError.self) {
            try await store.save(proposed, expectedRevision: 0, expectedDigest: initial.digest)
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("project.json")) == bytes)
    }

    @Test func readOnlyLoadingDoesNotCreateALockOrAlterTheOriginal() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = EDAProject(title: "Read only")
        _ = try await EDAProjectStore.create(root: root, project: project)
        let original = try Data(contentsOf: root.appendingPathComponent("project.json"))
        let store = try EDAProjectStore(root: root, projectID: project.id, readOnly: true)
        #expect(try await store.load().project == project)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".floe-eda.lock"))
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".floe-eda.lock").path))
        #expect(try Data(contentsOf: root.appendingPathComponent("project.json")) == original)
    }

    @Test func symlinkOriginalIsRejectedWithoutTouchingItsTarget() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = temporaryRoot(); defer { try? FileManager.default.removeItem(at: outside) }
        let project = EDAProject(title: "Original")
        let store = try await EDAProjectStore.create(root: root, project: project)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("owned.json")
        let sentinel = Data("outside original".utf8); try sentinel.write(to: target)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project.json"), withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test func foreignIdentityAndSecondCreationCannotReplaceTheOriginal() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let project = EDAProject(title: "Original")
        let store = try await EDAProjectStore.create(root: root, project: project)
        let original = try await store.load()
        let foreign = try EDAProjectStore(root: root, projectID: UUID())
        await #expect(throws: EDAError.self) { try await foreign.load() }
        await #expect(throws: EDAError.self) { try await EDAProjectStore.create(root: root, project: EDAProject(title: "Other")) }
        #expect(try await store.load() == original)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("floe-eda-tests-" + UUID().uuidString, isDirectory: true)
    }
}

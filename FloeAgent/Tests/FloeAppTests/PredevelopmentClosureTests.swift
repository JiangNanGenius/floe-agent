// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistryUI
@testable import FloeApp

@Suite("Predevelopment feedback closure", .serialized)
struct PredevelopmentClosureTests {
    @Test func nativeSMILESWithoutCoordinatesKeepsItsRealBenzeneBonds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chemistry-graph-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try ChemistryService(store: ChemistryProjectStore(root: root), authorize: { _ in })
        let project = try await service.create(title: "Benzene graph")
        let object = try await service.importObject(project.id, title: "Benzene", kind: .molecule, format: "smiles", source: "c1ccccc1")
        let graph = try ChemistryScene.parse(try #require(object.facts?["cjson"]?.string))
        #expect(graph.atoms.count == 12)
        #expect(graph.bonds.count == 12)
        #expect(graph.bonds.filter { $0.order == 2 }.count == 3)
        #expect(!graph.isThreeDimensional)
        #expect(object.requires3DPreparation)
        await #expect(throws: ChemistryError.requiresPrepared3DStructure) {
            _ = try await service.start(project.id, objectID: object.id, method: "uff.optimize")
        }
        #expect(try await service.project(project.id).runs.isEmpty)
        let reopened = try await ChemistryProjectStore(root: root).load(project.id)
        #expect(reopened.objects.first?.source == "c1ccccc1")
    }
    @Test @MainActor func registeredDevicePingReceivesActualLoopbackReplies() async throws {
        _ = FloeAgentApp.liveEnvironment
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: "network.ping"))
        let result = try await runner.execute(argumentsJSON: Data(#"{"target":"127.0.0.1","count":2,"timeoutSeconds":1}"#.utf8),
            context: .init(runID: UUID(), cancellation: CancellationToken()))
        #expect(result.summary.contains("method=icmpPing"))
        #expect(result.summary.contains("received=2"))
        #expect(result.summary.contains("lossPercent=0.0"))
        let trace = try #require(ToolRunnerRegistry.shared.runner(named:"network.traceroute"))
        let route = try await trace.execute(argumentsJSON:Data(#"{"target":"127.0.0.1","maxHops":1,"timeoutSeconds":1}"#.utf8),
            context:.init(runID:UUID(),cancellation:CancellationToken()))
        #expect(route.summary.contains("method=icmpTraceroute"))
        #expect(route.summary.contains("reached=true"))
    }
    @Test func fileProviderChangeDatesMatchCommittedVersionsAndBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-dates-\(UUID())")
        let store = try SQLiteSharedDocumentsStore(root: root)
        do {
            let anchor = try await store.currentAnchor()
            let bytes = Data("saved G-code fixture\nG1 X10 Y20\n".utf8)
            let stageID = try await store.beginContentStage(cancellation: nil)
            try await store.writeContent(bytes, operationID: stageID, cancellation: nil)
            let stage = try await store.finishContentStage(operationID: stageID, cancellation: nil)
            let created = try await store.commitCreate(parentID: SharedDocumentsIdentity.rootItemID,
                name: "cube.gcode", kind: .file, stage: stage)
            let first = try await store.item(id: created.id)
            try await Task.sleep(for: .milliseconds(20))
            _ = try await store.commitMetadata(id: first.id, newName: "renamed.gcode", newParentID: nil, expected: first.versions)
            let current = try await store.item(id: first.id)
            // A historical insert must not borrow a later version's date.
            let historical = try await store.changes(anchor: anchor, limit: 1)
            let old = try #require(historical.changes.first?.item)
            #expect(old.modificationDate == first.modificationDate)
            #expect(old.creationDate == first.creationDate)
            let bridge = SharedDocumentsFileProviderBridge(store: store,
                signalProvider: nil, materializationRootProvider: { root })
            let batch = try await bridge.changeBatch(anchor: anchor, limit: 100)
            let shown = try #require(batch.updates.first)
            #expect(batch.updates.count == 1)
            #expect(shown.filename == current.name)
            #expect(shown.creationDate == current.creationDate)
            #expect(shown.contentModificationDate == current.modificationDate)
            #expect(current.creationDate.timeIntervalSince1970 > 1_000_000_000)
            #expect(current.modificationDate > first.modificationDate)
            let saved = try await store.withLeasedContentSnapshot(id: current.id, cancellation: nil) {
                try Data(contentsOf: $0.contentURL)
            }
            #expect(saved == bytes)
            try await store.close()
        } catch {
            try? await store.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        try FileManager.default.removeItem(at: root)
    }
}
#endif

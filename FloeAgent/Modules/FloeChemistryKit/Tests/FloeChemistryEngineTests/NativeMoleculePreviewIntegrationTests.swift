import Foundation
import XCTest
import FloeChemistryCore
import FloeMoleculePreviewNative
@testable import FloeChemistryEngine

@MainActor final class NativeMoleculePreviewIntegrationTests: XCTestCase {
    private func fixture() async throws -> (URL, ChemistryProjectStore, ChemistryService, ChemistryProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chemistry-preview-" + UUID().uuidString)
        let store = try ChemistryProjectStore(root: root)
        let service = try ChemistryService(store: store, backends: [], authorize: { _ in })
        return (root, store, service, try await service.create(title: "Molecule preview"))
    }

    func testOriginalCoordinatesAndNativeGenerationPreserveTheOriginalAndReopenFromCache() async throws {
        let (root, store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let water = try await service.importObject(project.id, title: "Water", format: "xyz",
            source: "3\nWater\nO 0 0 0\nH 0.96 0 0\nH -0.24 0.93 0\n")
        let direct = try await service.moleculePreview(project.id, objectID: water.id, expectedObjectRevision: water.revision)
        XCTAssertEqual(direct.origin, .original)
        XCTAssertEqual(direct.cjson, water.facts?["cjson"]?.string)
        XCTAssertEqual(direct.atomCount, 3)
        XCTAssertNil(direct.molblock)

        let graph = try await service.importObject(project.id, title: "Ethanol", format: "smi", source: "CCO")
        let before = try await store.load(project.id)
        let historyBefore = try await store.history(project.id)
        let first = try await service.moleculePreview(project.id, objectID: graph.id, expectedObjectRevision: graph.revision)
        XCTAssertEqual(first.origin, .generated)
        XCTAssertEqual(first.atomCount, 9)
        XCTAssertEqual(first.bondCount, 8)
        XCTAssertTrue(try XCTUnwrap(first.molblock).contains("3D"))
        XCTAssertEqual(first.key.sourceDigest.count, 64)
        XCTAssertTrue(first.key.parameters.contains("ETKDGv3"))
        let reopened = try ChemistryService(store: ChemistryProjectStore(root: root), backends: [], authorize: { _ in })
        let second = try await reopened.moleculePreview(project.id, objectID: graph.id, expectedObjectRevision: graph.revision)
        XCTAssertEqual(second.origin, .cached)
        XCTAssertEqual(second.cjson, first.cjson)
        XCTAssertEqual(second.molblock, first.molblock)
        let after = try await reopened.project(project.id)
        let historyAfter = try await store.history(project.id)
        XCTAssertEqual(after, before)
        XCTAssertEqual(historyAfter, historyBefore)
        XCTAssertTrue(try XCTUnwrap(after.objects.first { $0.id == graph.id }).requires3DPreparation)
    }

    func testSaved2DMOLDrawingRegeneratesAfterEditAndHistoryRestoresBothOriginalFormats() async throws {
        let (root, store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blank = try await service.createDrawing(project.id, title: "2D drawing")
        var drawing = try ChemicalDrawing2D()
        let firstCarbon = try drawing.addAtom("C", at: .init(-1.30, -0.25))
        let secondCarbon = try drawing.addAtom("C", at: .init(0, 0.50), molecule: firstCarbon.molecule)
        let oxygen = try drawing.addAtom("O", at: .init(1.30, -0.25), molecule: firstCarbon.molecule)
        _ = try drawing.addBond(firstCarbon, secondCarbon)
        _ = try drawing.addBond(secondCarbon, oxygen)
        let ket = try drawing.encoded()
        let mol = """
        Ethanol
          Floe              2D

          3  2  0  0  0  0  0  0  0  0999 V2000
           -1.3000   -0.2500    0.0000 C   0  0  0  0  0  0  0  0  0  0  0  0
            0.0000    0.5000    0.0000 C   0  0  0  0  0  0  0  0  0  0  0  0
            1.3000   -0.2500    0.0000 O   0  0  0  0  0  0  0  0  0  0  0  0
          1  2  1  0
          2  3  1  0
        M  END
        """
        let original = try await service.saveSketch(project.id, objectID: blank.id, expectedObjectRevision: blank.revision,
            ket: ket, format: "mol", source: mol, smiles: "CCO")
        let history = try await store.history(project.id)
        let restorePoint = try XCTUnwrap(history.first)
        let first = try await service.moleculePreview(project.id, objectID: blank.id, expectedObjectRevision: original.revision)
        XCTAssertEqual(first.origin, .generated)
        XCTAssertEqual(first.atomCount, 9)
        let sidecar = root.appendingPathComponent(project.id.uuidString).appendingPathComponent("molecule-previews")
            .appendingPathComponent(blank.id.uuidString + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        let newMOL = mol.replacingOccurrences(of: "0.0000 O ", with: "0.0000 N ")
        try drawing.updateAtom(oxygen, label: "N")
        let edited = try await service.saveSketch(project.id, objectID: blank.id, expectedObjectRevision: original.revision,
            ket: drawing.encoded(), format: "mol", source: newMOL, smiles: "CCN")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        let second = try await service.moleculePreview(project.id, objectID: blank.id, expectedObjectRevision: edited.revision)
        XCTAssertEqual(second.origin, .generated)
        XCTAssertEqual(second.atomCount, 10)
        let current = try await store.load(project.id)
        XCTAssertEqual(current.objects.first, edited)
        let restored = try await service.restore(restorePoint, expectedRevision: current.revision)
        XCTAssertEqual(restored.objects.first?.source, mol)
        XCTAssertEqual(restored.objects.first?.sketchDocument, ket)
        XCTAssertEqual(restored.objects.first?.sketchSMILES, "CCO")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        let final = try await service.moleculePreview(project.id, objectID: blank.id, expectedObjectRevision: original.revision)
        XCTAssertEqual(final.atomCount, first.atomCount)
        let historyAfter = try await store.history(project.id)
        XCTAssertEqual(historyAfter.count, history.count + 2)
    }

    func testDifferentSourceAtTheSameRevisionProjectAndParametersCannotReuseCoordinates() async throws {
        let (root, store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await service.importObject(project.id, title: "First", format: "smi", source: "CCO")
        let first = try await service.moleculePreview(project.id, objectID: graph.id, expectedObjectRevision: graph.revision)
        var changed = try await store.load(project.id)
        changed.objects[0].source = "CO"
        _ = try await store.save(changed, expectedRevision: changed.revision)
        let second = try await service.moleculePreview(project.id, objectID: graph.id, expectedObjectRevision: graph.revision)
        XCTAssertEqual(second.origin, .generated)
        XCTAssertNotEqual(second.key.sourceDigest, first.key.sourceDigest)
        XCTAssertEqual(second.atomCount, 6)

        var options = MoleculePreviewOptions()
        options.seed += 1
        let reseeded = try await service.moleculePreview(project.id, objectID: graph.id, expectedObjectRevision: graph.revision, options: options)
        XCTAssertEqual(reseeded.origin, .generated)
        XCTAssertNotEqual(reseeded.key.parameters, second.key.parameters)
        var other = ChemistryProject(title: "Same molecule in a different project")
        other.objects = changed.objects
        _ = try await store.save(other, expectedRevision: 0)
        let independent = try await service.moleculePreview(other.id, objectID: graph.id, expectedObjectRevision: graph.revision, options: options)
        XCTAssertEqual(independent.origin, .generated)
        XCTAssertNotEqual(independent.key.projectID, reseeded.key.projectID)
    }

    func testCancelledAndStaleCompletionsCannotPublishOverANewerDrawing() async throws {
        let (root, store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = try await service.importObject(project.id, title: "Original", format: "smi", source: "CCO")
        let native = try await MoleculePreviewNative.generate(input: "CCO", format: .smiles)
        func start(_ gate: PreviewGate) -> Task<ChemistryMoleculePreview, Error> {
            Task {
                try await service.makeMoleculePreview(project.id, objectID: graph.id, expectedObjectRevision: graph.revision) { _, _, _ in
                    await gate.hold()
                    return native
                }
            }
        }
        let cancellation = PreviewGate()
        let cancelled = start(cancellation)
        try await cancellation.waitUntilHeld()
        cancelled.cancel()
        await cancellation.release()
        do { _ = try await cancelled.value; XCTFail("Cancelled preview was published") } catch is CancellationError {}
        let sidecar = root.appendingPathComponent(project.id.uuidString).appendingPathComponent("molecule-previews")
            .appendingPathComponent(graph.id.uuidString + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        let oldSource = PreviewGate()
        let old = start(oldSource)
        try await oldSource.waitUntilHeld()
        do {
            let newer = try await service.replaceObject(project.id, objectID: graph.id, expectedObjectRevision: graph.revision, format: "smi", source: "CO")
            let newPreview = try await service.moleculePreview(project.id, objectID: newer.id, expectedObjectRevision: newer.revision)
            let saved = try Data(contentsOf: sidecar)
            await oldSource.release()
            do { _ = try await old.value; XCTFail("Old preview overwrote the current molecule") } catch ChemistryError.invalid {}
            XCTAssertEqual(try Data(contentsOf: sidecar), saved)
            let cached = try await store.cachedMoleculePreview(newPreview.key)
            XCTAssertEqual(cached?.cjson, newPreview.cjson)
        } catch {
            await oldSource.release()
            throw error
        }
    }

    func testEmptyDrawingAndDisconnectedInputLeaveProjectAndCacheUntouched() async throws {
        let (root, store, service, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try await service.createDrawing(project.id, title: "Empty drawing")
        let mixture = try await service.importObject(project.id, title: "Separate molecules", format: "smi", source: "CC.O", deferPreparation: true)
        let original = try await store.load(project.id)
        do { _ = try await service.moleculePreview(project.id, objectID: empty.id, expectedObjectRevision: empty.revision); XCTFail("Empty drawing was displayed") }
        catch ChemistryPreviewError.emptyDrawing {}
        do { _ = try await service.moleculePreview(project.id, objectID: mixture.id, expectedObjectRevision: mixture.revision); XCTFail("Disconnected input was displayed") }
        catch ChemistryPreviewError.invalidMolecule {}
        let after = try await store.load(project.id)
        XCTAssertEqual(after, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(project.id.uuidString).appendingPathComponent("molecule-previews").path))
    }
}

private actor PreviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while continuation == nil {
            guard clock.now < deadline else { throw ChemistryError.unavailable("The test generator was never called.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

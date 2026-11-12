// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeElectronicsCore

final class ElectronicsRemoteInstallTests: XCTestCase {
    private func symbolSource() -> Data {
        Data(#"""
        (kicad_symbol_lib (version 20241209) (generator kicad_symbol_editor)
          (symbol "R"
            (pin_numbers hide)
            (pin_names (offset 0))
            (exclude_from_sim no)
            (in_bom yes)
            (on_board yes)
            (property "Reference" "R" (at 2.032 0 90) (effect (font (size 1.27 1.27))))
            (property "Value" "R" (at 0 0 90) (effect (font (size 1.27 1.27))))
            (symbol "R_0_1"
              (rectangle (start -1.016 -2.54) (end 1.016 2.54)
                (stroke (width 0.254) (type default)) (fill (type none))))
            (symbol "R_1_1"
              (pin passive line (at 0 3.81 270) (length 1.27)
                (name "~" (effect (font (size 1.27 1.27))))
                (number "1" (effect (font (size 1.27 1.27)))))
              (pin passive line (at 0 -3.81 90) (length 1.27)
                (name "~" (effect (font (size 1.27 1.27))))
                (number "2" (effect (font (size 1.27 1.27)))))))
        )
        """#.utf8)
    }

    private func footprintSource() -> Data {
        Data(#"""
        (footprint "R_0603_1608Metric" (version 20260206) (generator kicad-footprint-generator)
          (layer "F.Cu")
          (descr "Resistor SMD 0603")
          (attr smd)
          (fp_rect (start -1.48 -0.73) (end 1.48 0.73) (stroke (width 0.05) (type solid)) (fill no) (layer "F.CrtYd"))
          (pad "1" smd roundrect (at -0.825 0) (size 0.8 0.95) (layers "F.Cu" "F.Mask" "F.Paste") (roundrect_rratio 0.25))
          (pad "2" smd roundrect (at 0.825 0) (size 0.8 0.95) (layers "F.Cu" "F.Mask" "F.Paste") (roundrect_rratio 0.25))
          (model "${KICAD10_3DMODEL_DIR}/Resistor_SMD.3dshapes/R_0603_1608Metric.step"
            (offset (xyz 0 0 0.5)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 90)))
        )
        """#.utf8)
    }

    private func fixture(kind: String, sourcePath: String, raw: Data, withModel: Bool = false,
                         root: URL) throws -> ElectronicsRemotePartMaterial {
        let sourceID = kind == "symbol" ? "kicad-symbols" : "kicad-footprints"
        let name = kind == "symbol" ? "R" : "R_0603_1608Metric"
        let recordID = "floe:electronics:\(sourceID):\(kind):Test:\(name)~0123456789ab"
        var object: [String: Any] = [
            "schemaVersion": 1, "format": "kicad", "kind": kind, "id": recordID,
            "library": kind == "symbol" ? "Device" : "Resistor_SMD", "name": name,
            "status": "converted", "units": "mm", "issues": [] as [Any],
            "source": ["path": sourcePath, "sha256": EDALibraryDigest.sha256(raw)]
        ]
        if withModel {
            object["modelReferences"] = [[
                "file": "${KICAD10_3DMODEL_DIR}/Resistor_SMD.3dshapes/R_0603_1608Metric.step",
                "offset": [0.25, -0.5, 0.75], "rotationDeg": [0, 90, 0], "scale": [1, 1, 1]
            ]]
        }
        let recordData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let recordJSON = String(decoding: recordData, as: UTF8.self)
        let recordSHA = EDALibraryDigest.sha256(recordData + Data([0x0A]))
        let summary = ElectronicsRemotePartSummary(id: recordID, kind: kind, name: name,
            library: object["library"] as! String, status: "converted",
            path: "records/\(sourceID)/00000.jsonl.gz", line: 1, sha256: recordSHA, sourcePath: sourcePath)
        let license = ElectronicsRemoteLicense(id: "CC-BY-SA-4.0", attribution: "KiCad library contributors",
            url: "https://www.kicad.org/libraries/license/")
        let index = ElectronicsRemoteFile(path: "indexes/\(sourceID).jsonl.gz", bytes: 2,
            sha256: EDALibraryDigest.sha256(Data([1, 2])), role: "search-index", sourceID: sourceID)
        let originals = ElectronicsRemoteFile(path: "originals/\(sourceID).zip", bytes: 2,
            sha256: EDALibraryDigest.sha256(Data([3, 4])), role: "original-2d-sources", sourceID: sourceID)
        let source = ElectronicsRemoteCatalog.Source(id: sourceID,
            repository: "https://github.com/KiCad/kicad-" + (kind == "symbol" ? "symbols" : "footprints"),
            commit: String(repeating: "a", count: 40), license: license, recordCount: 1,
            sourceStatus: "normalized", statuses: ["converted": 1], kinds: [kind: 1],
            originalFileCount: 1, originalBytes: raw.count, index: index, chunks: [index], originals: originals)
        let model = ElectronicsRemoteModelRecord(id: "model:kicad-packages3d:Resistor_SMD.3dshapes/R_0603_1608Metric.step",
            sourceID: "kicad-packages3d", repository: "https://gitlab.com/kicad/libraries/kicad-packages3D",
            revision: String(repeating: "b", count: 40), path: "Resistor_SMD.3dshapes/R_0603_1608Metric.step",
            gitBlobSHA1: String(repeating: "c", count: 40), format: "step", licenseSourceID: "kicad-footprints")
        return ElectronicsRemotePartMaterial(libraryID: sourceID, record: summary,
            recordJSON: recordJSON, recordSHA256: recordSHA, source: source,
            libraryArchiveURL: root.appendingPathComponent("library.zip"),
            modelRecords: withModel ? [model] : [],
            originalFiles: [sourcePath: raw, "LICENSE.md": Data("KiCad library license fixture".utf8)])
    }

    func testSelectedRealisticRecordInstallsReadsBackAndPlacesOnSheetAndBoard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try EDALibraryStore(root: root.appendingPathComponent("Libraries"))
        let symbol = try fixture(kind: "symbol", sourcePath: "Device.kicad_symdir/R.kicad_sym",
            raw: symbolSource(), root: root)
        let footprint = try fixture(kind: "footprint", sourcePath: "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
            raw: footprintSource(), withModel: true, root: root)
        let symbolResult = try await ElectronicsRemoteInstaller.install(material: symbol, into: store)
        let footprintResult = try await ElectronicsRemoteInstaller.install(material: footprint, into: store)
        XCTAssertEqual(symbolResult.partKind, .symbol)
        XCTAssertEqual(footprintResult.partKind, .footprint)
        XCTAssertEqual(footprintResult.models.first?.modelID,
            "model:kicad-packages3d:Resistor_SMD.3dshapes/R_0603_1608Metric.step")

        let catalog = try await store.catalog()
        XCTAssertEqual(Set(catalog.entries.map(\.reference)), [symbolResult.reference, footprintResult.reference])
        let symbolSnapshot = try await store.snapshot(symbolResult.reference)
        let footprintSnapshot = try await store.snapshot(footprintResult.reference)
        XCTAssertEqual(symbolSnapshot.originalSources?["Device.kicad_symdir/R.kicad_sym"], symbolSource())
        XCTAssertEqual(footprintSnapshot.part.footprint?.modelReferences?.first?.offsetMillimetres, [0.25, -0.5, 0.75])
        XCTAssertEqual(footprintSnapshot.part.parameters["FloeRemoteSourceCommit"], String(repeating: "a", count: 40))
        XCTAssertTrue(footprintSnapshot.part.notices.contains { $0.code == "remote_source_pinned" })

        let boundPackage = try EDALibraryBinding.package(symbol: symbolSnapshot, footprint: footprintSnapshot,
            pinMap: .init(pinToPads: ["1": ["1"], "2": ["2"]]), name: "R 0603 explicit")
        let boundSnapshot = try EDALibrarySnapshot(package: boundPackage, partID: "associated-part")
        let projectStore = try await EDAProjectStore.create(root: root.appendingPathComponent("Project"),
            project: EDAProject(title: "Installed parts"))
        let loaded = try await projectStore.load()
        var editing = try EDAEditingSession(project: loaded.project, savedDigest: loaded.digest)
        var symbolPlacement: EDALibraryPlacementReceipt!
        try editing.transaction(expectedRevision: 0) { candidate in
            symbolPlacement = try EDALibraryProject.place(boundSnapshot, into: &candidate,
                sheetID: candidate.sheets[0].id, position: .zero)
            _ = try EDALibraryProject.place(boundSnapshot, into: &candidate,
                boardID: candidate.boards[0].id, position: .init(10, 10),
                existingComponentID: symbolPlacement.componentID)
        }
        let plan = try EDAForwardAnnotation.plan(editing.project, boardID: editing.project.boards[0].id)
        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.updatedBoard.footprints.first?.componentID, symbolPlacement.componentID)
        try EDAForwardAnnotation.apply(plan, to: &editing)
        let saved = try await projectStore.save(editing.project, expectedRevision: 0, expectedDigest: loaded.digest)
        let reopened = try await projectStore.load()
        XCTAssertEqual(reopened, saved)
        XCTAssertEqual(reopened.project.boards[0].footprints.count, 1)
        XCTAssertEqual(reopened.project.boards[0].footprints[0].componentID, symbolPlacement.componentID)
        XCTAssertEqual(try EDALibraryProject.snapshot(symbolPlacement.snapshotSHA256, in: reopened.project)
            .part.footprint?.modelReferences?.count, 1)
    }

    func testReviewRequiredAndUnsupportedRecordsNeverAlterTheNativeInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-refuse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try EDALibraryStore(root: root)
        let good = try fixture(kind: "symbol", sourcePath: "Device.kicad_symdir/R.kicad_sym",
            raw: symbolSource(), root: root)
        _ = try await ElectronicsRemoteInstaller.install(material: good, into: store)
        let before = try await store.inventory()
        var record = good.record; record.status = "reviewRequired"
        let bad = ElectronicsRemotePartMaterial(libraryID: good.libraryID, record: record, recordJSON: good.recordJSON,
            recordSHA256: good.recordSHA256, source: good.source, libraryArchiveURL: good.libraryArchiveURL,
            modelRecords: good.modelRecords, originalFiles: good.originalFiles)
        do { _ = try await ElectronicsRemoteInstaller.install(material: bad, into: store); XCTFail("review record installed") }
        catch let error as ElectronicsRemoteInstallError { if case .reviewRequired = error {} else { XCTFail("wrong error: \(error)") } }
        let after = try await store.inventory(); XCTAssertEqual(after, before)
        let catalog = try await store.catalog(); XCTAssertEqual(catalog.entries.count, 1)

        let other = ElectronicsRemotePartMaterial(libraryID: "other-library", record: good.record,
            recordJSON: good.recordJSON, recordSHA256: good.recordSHA256, source: good.source,
            libraryArchiveURL: good.libraryArchiveURL, modelRecords: [], originalFiles: good.originalFiles)
        do { _ = try await ElectronicsRemoteInstaller.install(material: other, into: store); XCTFail("mismatched source installed") }
        catch let error as ElectronicsRemoteInstallError { if case .invalidRecord = error {} else { XCTFail("wrong error: \(error)") } }
        let finalInventory = try await store.inventory()
        XCTAssertEqual(finalInventory, before)
    }

    func testProspectiveCatalogBudgetRejectsSecondActivePackageWithoutChangingTheFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try EDALibraryStore(root: root)
        func package(id: String) -> EDALibraryPackage {
            let payloads = ["a.bin": Data(count: 32 * 1_024 * 1_024),
                            "b.bin": Data(count: 32 * 1_024 * 1_024),
                            "c.bin": Data(count: 1 * 1_024 * 1_024)]
            let part = EDALibraryPart(id: "p", name: "P", kind: .symbol, category: "test",
                symbol: EDASymbolDefinition(name: "S", pins: [.init(number: "1", position: .zero)]),
                sources: [])
            return EDALibraryPackage(id: id, version: "1.0.0", title: "Large",
                parts: [part], licenses: [.init(id: "CC0-1.0", attribution: "fixture", text: "fixture")],
                sourcePayloads: payloads)
        }
        _ = try await store.install(package(id: "org.floe.budget.one"))
        let before = try await store.inventory()
        do { _ = try await store.install(package(id: "org.floe.budget.two")); XCTFail("aggregate budget accepted") }
        catch let error as EDAError { XCTAssertEqual(error, .invalid("active library catalog budget")) }
        let finalInventory = try await store.inventory()
        let finalCatalog = try await store.catalog()
        XCTAssertEqual(finalInventory, before)
        XCTAssertEqual(finalCatalog.entries.count, 1)
    }

    func testCancellationBeforeBuildPreservesInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try EDALibraryStore(root: root)
        let item = try fixture(kind: "symbol", sourcePath: "Device.kicad_symdir/R.kicad_sym",
            raw: symbolSource(), root: root)
        _ = try await ElectronicsRemoteInstaller.install(material: item, into: store)
        let before = try await store.inventory()
        do {
            _ = try await ElectronicsRemoteInstaller.install(material: item, into: store, cancelled: { true })
            XCTFail("cancelled install committed")
        } catch let error as ElectronicsRemoteInstallError { XCTAssertEqual(error, .cancelled) }
        let after = try await store.inventory()
        XCTAssertEqual(after, before)
    }

    func testRepeatedVerifiedInstallWithMultipleLicenseFilesKeepsTheSameReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-repeat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try EDALibraryStore(root: root)
        let base = try fixture(kind: "symbol", sourcePath: "Device.kicad_symdir/R.kicad_sym",
            raw: symbolSource(), root: root)
        var originals = base.originalFiles
        originals["licenses/CC-BY-SA-4.0.txt"] = Data("Second complete license text".utf8)
        let keys = originals.keys.sorted()
        var first: ElectronicsRemoteInstallResult?
        for iteration in 0..<12 {
            let rotated = Array(keys.dropFirst(iteration % keys.count)) + Array(keys.prefix(iteration % keys.count))
            let reordered = Dictionary(uniqueKeysWithValues: rotated.map { ($0, originals[$0]!) })
            let material = ElectronicsRemotePartMaterial(libraryID: base.libraryID, record: base.record,
                recordJSON: base.recordJSON, recordSHA256: base.recordSHA256, source: base.source,
                libraryArchiveURL: base.libraryArchiveURL, modelRecords: base.modelRecords,
                originalFiles: reordered)
            let installed = try await ElectronicsRemoteInstaller.install(material: material, into: store)
            if let first {
                XCTAssertEqual(installed.reference, first.reference)
                XCTAssertEqual(installed.snapshotSHA256, first.snapshotSHA256)
            } else { first = installed }
        }
        let catalog = try await store.catalog()
        XCTAssertEqual(catalog.entries.count, 1)
    }

    func testLegacyFootprintEncodingOmitsTheOptionalModelReferencesField() throws {
        let footprint = EDAFootprintDefinition(name: "Legacy")
        let encoded = try EDALibraryDigest.encoded(footprint)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("modelReferences"))
        XCTAssertNil(try JSONDecoder().decode(EDAFootprintDefinition.self, from: encoded).modelReferences)
        XCTAssertEqual(try EDALibraryDigest.encoded(footprint), encoded)
    }

    func testLocalizedEDAErrorIsNotOpaque() {
        let message = (EDAError.invalid("unresolved annotation conflicts") as Error).localizedDescription
        XCTAssertTrue(message.contains("unresolved annotation conflicts"))
        XCTAssertFalse(message.contains("error 0"))
    }
}

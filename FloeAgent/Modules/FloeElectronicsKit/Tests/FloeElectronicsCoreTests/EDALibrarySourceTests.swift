import XCTest
import Foundation
@testable import FloeElectronicsCore

final class EDALibrarySourceTests: XCTestCase {
    private func source(_ name: String, _ ext: String = "kicad_sym") throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/KiCad")))
    }
    func testSExpressionKeepsUTF8QuotesParenthesesAndCommentCharactersInStrings() throws {
        let input = #"""
        (root ; line comment
            (property "Value" "温度 (A); \"quoted\" \\ end") (at -1.27 2.54))
        """#
        let root = try EDASExpression.parse(Data(input.utf8))
        XCTAssertEqual(root.child("property")?.value(2), "温度 (A); \"quoted\" \\ end")
        XCTAssertEqual(try root.child("at")?.point(), EDAPoint(-1.27, 2.54))
    }
    func testSExpressionRefusesTruncationTrailingRootDeepInputAndCancelledRead() throws {
        for bad in ["(root", "(a)(b)", "(a \"unfinished)", String(repeating: "(", count: 100) + "x" + String(repeating: ")", count: 100)] {
            XCTAssertThrowsError(try EDASExpression.parse(Data(bad.utf8)))
        }
        XCTAssertThrowsError(try EDASExpression.parse(Data("(root)".utf8), cancelled: { true }))
        XCTAssertThrowsError(try EDASExpression.parse(Data([0xff, 0x01])))
    }
    func testActualLM358InheritancePreservesAllEightPhysicalPinsAndSeparateUnits() throws {
        let raw = try source("LM358"), parent = try source("LM2904")
        let result = try EDAKiCadSymbols.read(raw, sourcePath: "LM358.kicad_sym", namespace: "Amplifier_Operational", dependencies: ["LM2904": parent])
        let symbol = try XCTUnwrap(result.symbols.first)
        XCTAssertEqual(symbol.name, "LM358"); XCTAssertEqual(symbol.fields["Value"], "LM358")
        XCTAssertEqual(Set(symbol.pins.map(\.number)), Set((1...8).map(String.init)))
        XCTAssertEqual(Set(symbol.pins.map(\.unit)), [1, 2, 3])
        XCTAssertNotEqual(symbol.graphics(forUnit: 1), symbol.graphics(forUnit: 3))
        XCTAssertEqual(symbol.graphics.count, symbol.graphicUnits?.count)
        XCTAssertEqual(result.source.sha256, EDALibraryDigest.sha256(raw))
    }
    func testMissingParentAndCyclicInheritanceReturnBlockingEntriesWithoutEmptySubstitutes() throws {
        let missing = try EDAKiCadSymbols.read(source("LM358"), sourcePath: "LM358.kicad_sym", namespace: "A")
        XCTAssertTrue(missing.symbols.isEmpty); XCTAssertTrue(missing.notices["LM358"]!.contains { $0.severity == .blocking })
        let cycle = Data(#"(kicad_symbol_lib (version 20251024) (symbol "A" (extends "B")) (symbol "B" (extends "A")))"#.utf8)
        let result = try EDAKiCadSymbols.read(cycle, sourcePath: "cycle.kicad_sym", namespace: "A")
        XCTAssertTrue(result.symbols.isEmpty); XCTAssertEqual(result.notices.count, 2)
    }
    func testActual2N7002KeepsGateSourceDrainNumbersRatherThanGenericTransistorOrder() throws {
        let result = try EDAKiCadSymbols.read(source("2N7002"), sourcePath: "2N7002.kicad_sym", namespace: "Transistor_FET", dependencies: ["Q_NMOS_GSD": source("Q_NMOS_GSD")])
        let symbol = try XCTUnwrap(result.symbols.first)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: symbol.pins.map { ($0.number, $0.name) }), ["1": "G", "2": "S", "3": "D"])
        XCTAssertTrue(symbol.graphics.contains { if case .circle = $0 { true } else { false } })
    }
    func testUnknownSymbolGraphicIsNotSilentlyDropped() throws {
        let data = Data(#"(kicad_symbol_lib (version 20251024) (symbol "Curve" (symbol "Curve_1_1" (bezier (pts (xy 0 0) (xy 1 1) (xy 2 0))))))"#.utf8)
        let result = try EDAKiCadSymbols.read(data, sourcePath: "curve.kicad_sym", namespace: "Test")
        XCTAssertTrue(result.symbols.isEmpty); XCTAssertEqual(result.source.sha256, EDALibraryDigest.sha256(data))
        XCTAssertTrue(result.notices["Curve"]!.contains { $0.detail.contains("bezier") && $0.severity == .blocking })
    }
    func testActualSOT23PreservesPadNumbersLayerAndMeasuredRoundRadius() throws {
        let data = try source("SOT-23", "kicad_mod")
        let result = try EDAKiCadFootprints.read(data, sourcePath: "SOT-23.kicad_mod", namespace: "Package_TO_SOT_SMD")
        let fp = try XCTUnwrap(result.footprint)
        XCTAssertEqual(Set(fp.pads.map(\.number)), ["1", "2", "3"])
        XCTAssertTrue(fp.pads.allSatisfy { $0.shape == .roundRectangle && $0.roundRectangleRadius != nil })
        let pad = try XCTUnwrap(fp.pads.first { $0.number == "1" })
        XCTAssertTrue(pad.layers.contains("F.Cu"))
        // The official source has (at -0.9375 -0.95); native coordinates are Y-up.
        XCTAssertEqual(pad.position.x, -0.9375, accuracy: 1e-12)
        XCTAssertEqual(pad.position.y, 0.95, accuracy: 1e-12)
        XCTAssertEqual(pad.roundRectangleRadius!, 0.15, accuracy: 1e-12)
        XCTAssertEqual(fp.graphics.count, fp.graphicLayers?.count)
        let roundtrip = try JSONDecoder().decode(EDAFootprintDefinition.self, from: JSONEncoder().encode(fp))
        XCTAssertEqual(roundtrip, fp)
    }
    func testActualThroughHoleDIPKeepsAllPadsAndPlatedDrills() throws {
        let result = try EDAKiCadFootprints.read(source("DIP-8_W7.62mm", "kicad_mod"), sourcePath: "DIP.kicad_mod", namespace: "Package_DIP")
        let fp = try XCTUnwrap(result.footprint)
        XCTAssertEqual(Set(fp.pads.map(\.number)), Set((1...8).map(String.init)))
        XCTAssertTrue(fp.pads.allSatisfy { $0.drill != nil && $0.drillPlated == true && $0.layers.contains("F.Cu") && $0.layers.contains("B.Cu") })
        XCTAssertTrue(result.notices.contains { $0.code == "through_hole_two_layer_scope" })
    }
    func testHeatsinkRoleIsPreservedAndUnsupportedCastellatedPropertyBlocksWholeFootprint() throws {
        func bytes(_ role: String) -> Data { Data("(footprint \"Role\" (pad \"1\" smd rect (at 0 0) (size 1 1) (layers \"F.Cu\") (property \(role))))".utf8) }
        let imported = try EDAKiCadFootprints.read(bytes("pad_prop_heatsink"), sourcePath: "Role.kicad_mod", namespace: "Test")
        XCTAssertEqual(imported.footprint?.pads.count, 1)
        XCTAssertEqual(imported.footprint?.fields["kicad.pad.1.property"], "pad_prop_heatsink")
        XCTAssertTrue(imported.notices.contains { $0.code == "pad_property_retained" })
        for role in ["pad_prop_castellated", "unknown_new_role"] {
            let blocked = try EDAKiCadFootprints.read(bytes(role), sourcePath: "Role.kicad_mod", namespace: "Test")
            XCTAssertNil(blocked.footprint); XCTAssertTrue(blocked.notices.contains { $0.severity == .blocking })
        }
    }
    func testUnknownOrSlottedPadsAreRejectedWithoutDroppingThePad() throws {
        for shape in ["custom", "trapezoid"] {
            let raw = Data("(footprint \"X\" (pad \"1\" smd \(shape) (at 0 0) (size 1 1) (layers \"F.Cu\")))".utf8)
            let imported = try EDAKiCadFootprints.read(raw, sourcePath: "X.kicad_mod", namespace: "Test")
            XCTAssertNil(imported.footprint); XCTAssertTrue(imported.notices.contains { $0.severity == .blocking })
        }
        let slot = Data(#"(footprint "X" (pad "1" thru_hole oval (at 0 0) (size 2 3) (drill oval 1 2) (layers "*.Cu" "*.Mask")))"#.utf8)
        XCTAssertNil(try EDAKiCadFootprints.read(slot, sourcePath: "X.kicad_mod", namespace: "Test").footprint)
    }
    func testRoundedGeometryKeepsOneMicrometreEnvelopeAndLegacyRadiusFailure() throws {
        let pad = EDAPad(number: "1", position: .zero, size: .init(2, 1), shape: .roundRectangle, roundRectangleRadius: 0.25)
        let inner = try EDARoundedPadGeometry.vertices(pad), outer = try EDARoundedPadGeometry.vertices(pad, containing: true)
        XCTAssertLessThanOrEqual(inner.count, 256); XCTAssertLessThanOrEqual(outer.count, 256)
        for i in 0..<360 {
            let a = Double(i) * .pi / 180
            let q = EDAPoint(0.75 + 0.25 * cos(a), 0.25 + 0.25 * sin(a))
            if (0...90).contains(i) {
                XCTAssertTrue(EDAGeometry.contains(q, polygon: outer))
                let d = EDAGeometry.edges(inner).map { EDAGeometry.pointDistance(q, to: $0.0, $0.1) }.min()!
                XCTAssertLessThanOrEqual(d, 0.00101)
            }
        }
        let old = EDAPad(number: "1", position: .zero, size: .init(2, 1), shape: .roundRectangle)
        XCTAssertThrowsError(try EDARoundedPadGeometry.vertices(old))
    }
    func testIndependentSymbolAndFootprintImportRetainsEveryOriginalAndDoesNotGuessAssociation() throws {
        let files = ["Device.kicad_symdir/R.kicad_sym": try source("R"), "Package_TO_SOT_SMD.pretty/SOT-23.kicad_mod": try source("SOT-23", "kicad_mod")]
        let draft = try EDALibraryImport.inspect(files: files, title: "Independent imports")
        XCTAssertEqual(draft.availableCount, 2); XCTAssertEqual(draft.originalFiles, files)
        let package = try XCTUnwrap(draft.package)
        XCTAssertTrue(package.parts.allSatisfy { !$0.supportsBoundPCB && $0.pinMap == nil })
        XCTAssertEqual(package.sourcePayloads, files)
    }
    func testDuplicateSymbolAndFootprintNamesAreReportedWithoutOverwritingOriginalFiles() throws {
        let symbol = Data(#"(kicad_symbol_lib (version 20251024) (symbol "X" (symbol "X_1_1" (pin passive line (at 0 0 0) (length 1) (name "P") (number "1")))))"#.utf8)
        let footprint = Data(#"(footprint "X" (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu")))"#.utf8)
        let inputs = ["Same.kicad_symdir/a.kicad_sym": symbol, "Same.kicad_symdir/b.kicad_sym": symbol, "Same.pretty/a.kicad_mod": footprint, "Same.pretty/b.kicad_mod": footprint]
        let draft = try EDALibraryImport.inspect(files: inputs, title: "Conflicting originals")
        XCTAssertNil(draft.package); XCTAssertEqual(draft.originalFiles, inputs)
        XCTAssertEqual(draft.entries.count, 4); XCTAssertTrue(draft.entries.allSatisfy { !$0.available })
        XCTAssertTrue(draft.entries.contains { $0.notices.contains { $0.code == "symbol_name_conflict" } })
        XCTAssertTrue(draft.entries.contains { $0.notices.contains { $0.code == "part_name_conflict" } })
        let separate = try EDALibraryImport.inspect(files: ["Same.kicad_symdir/X.kicad_sym": symbol, "Same.pretty/X.kicad_mod": footprint], title: "Independent")
        XCTAssertEqual(separate.package?.parts.count, 2); XCTAssertEqual(Set(separate.package?.parts.map(\.id) ?? []).count, 2)
    }
    func testFolderImportResolvesActualSplitSymbolDependencyAndPreservesBlockedRawFile() throws {
        let unsupported = Data(#"(footprint "Custom" (pad "1" smd custom (at 0 0) (size 1 1) (layers "F.Cu")))"#.utf8)
        let files = ["OpAmp.kicad_symdir/LM358.kicad_sym": try source("LM358"), "OpAmp.kicad_symdir/LM2904.kicad_sym": try source("LM2904"), "Unsupported.kicad_mod": unsupported]
        let draft = try EDALibraryImport.inspect(files: files, title: "Split library")
        XCTAssertEqual(draft.package?.parts.count, 2)
        XCTAssertTrue(draft.entries.contains { !$0.available && $0.sourcePath == "Unsupported.kicad_mod" })
        XCTAssertEqual(draft.package?.sourcePayloads["Unsupported.kicad_mod"], unsupported)
    }
}

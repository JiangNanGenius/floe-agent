// SPDX-License-Identifier: MPL-2.0
// FloeDocumentsTests — conservative Office ink classification.
//
// These tests pin the CORRECTNESS GATES of `OfficeInkOmission` that the real
// engine output must satisfy and the spoof classes it must refuse:
//  * positive classification (titles, `custGeom` geometry, path commands and
//    removable candidates) only accepts the REAL OOXML markup languages —
//    DrawingML main, spreadsheetDrawing, wordprocessingDrawing,
//    wordprocessingShape and presentation. A foreign namespace that merely
//    reuses the local names (`twoCellAnchor`, `cNvPr`, `custGeom`, `sp` …)
//    can never earn a deletion, while the negative text/image/preset guards
//    stay deliberately conservative local-name matches (they can only ever
//    RETAIN).
//  * a drawing candidate carrying more than one independent shape (or none)
//    is a mixed/ambiguous representation and is retained whole — an unknown
//    freeform sibling is never erased using the title or geometry of a
//    different child.
//  * only the ECMA-376 command spellings count (`moveTo`, `lnTo`,
//    `quadBezTo`, `cubicBezTo`, `arcTo`); the invented `qtTo` does not.
//  * the strict known-name qualified CLOSED/filled stroke is still omitted,
//    Word `wp:docPr` outside `wps:wsp` still qualifies its drawing while the
//    sibling `w:r` text survives, and the receipt (`keptDrawingShapes`) is
//    truthful over EVERY visited part, not only the modified ones.
//  * the source is never written and untouched package members stay
//    byte-identical.
//
// Boundary: pure `FloeDocuments` checks on synthetic, public-safe packages.
// The real pinned-engine PDF output and the real user workbook digest remain
// the App/engine acceptance gate owned by the primary
// (`OfficePDFExportAcceptanceTests`); nothing here renders a PDF.

import Foundation
import Testing
import ZIPFoundation
@testable import FloeDocuments

// MARK: - Namespace fixtures (real ECMA-376 / ISO 29500 languages plus one
// foreign look-alike namespace)

private let nsDrawingML = "http://schemas.openxmlformats.org/drawingml/2006/main"
private let nsSheetDrawing = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
private let nsWord = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private let nsWordDrawing = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
private let nsWordShape = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
private let nsPresentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
private let nsCompatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"
private let nsVML = "urn:schemas-microsoft-com:vml"
private let nsOfficeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let nsSpoof = "http://example.com/ink-lookalike"

private let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

// MARK: - Synthetic shape builders

/// A proven-ink geometry: `a:custGeom`/`a:pathLst`/`a:path` in DrawingML
/// main with at least two standard commands and two points. `closed` emits
/// the engine's filled annotation form (`a:close`, no `fill="none"`).
private func realInkGeometry(closed: Bool = false,
                             command: String = "lnTo",
                             fill: Bool = false) -> String {
    let fillAttribute = (closed || fill) ? "" : " fill=\"none\""
    let close = closed ? "<a:close/>" : ""
    return """
    <a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/>\
    <a:rect l="l" t="t" r="r" b="b"/><a:pathLst><a:path w="10" h="10"\(fillAttribute)>\
    <a:moveTo><a:pt x="0" y="0"/></a:moveTo>\
    <a:\(command)><a:pt x="1" y="1"/></a:\(command)>\
    <a:\(command)><a:pt x="2" y="2"/></a:\(command)>\(close)\
    </a:path></a:pathLst></a:custGeom>
    """
}

/// The same structure with every geometry token in the SPOOF namespace —
/// locally identical to `realInkGeometry` but not DrawingML markup.
private func spoofInkGeometry(command: String = "lnTo") -> String {
    """
    <f:custGeom><f:pathLst><f:path w="10" h="10">\
    <f:moveTo><f:pt x="0" y="0"/></f:moveTo>\
    <f:\(command)><f:pt x="1" y="1"/></f:\(command)>\
    <f:\(command)><f:pt x="2" y="2"/></f:\(command)>\
    </f:path></f:pathLst></f:custGeom>
    """
}

private func sheetShape(id: Int, name: String, geometry: String,
                        titlePrefix: String = "xdr") -> String {
    """
    <\(titlePrefix):sp macro="" textlink="">\
    <\(titlePrefix):nvSpPr><\(titlePrefix):cNvPr id="\(id)" name="\(name)"/>\
    <\(titlePrefix):cNvSpPr/></\(titlePrefix):nvSpPr>\
    <\(titlePrefix):spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1" cy="1"/></a:xfrm>\(geometry)</\(titlePrefix):spPr>\
    <\(titlePrefix):txBody><a:bodyPr/><a:lstStyle/><a:p/></\(titlePrefix):txBody>\
    </\(titlePrefix):sp>
    """
}

private func sheetPresetShape(id: Int, name: String) -> String {
    """
    <xdr:sp macro="" textlink="">\
    <xdr:nvSpPr><xdr:cNvPr id="\(id)" name="\(name)"/><xdr:cNvSpPr/></xdr:nvSpPr>\
    <xdr:spPr><a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom></xdr:spPr>\
    <xdr:txBody><a:bodyPr/><a:lstStyle/><a:p/></xdr:txBody>\
    </xdr:sp>
    """
}

private func sheetPictureShape(id: Int, name: String) -> String {
    """
    <xdr:pic>\
    <xdr:nvPicPr><xdr:cNvPr id="\(id)" name="\(name)"/><xdr:cNvPicPr/></xdr:nvPicPr>\
    <xdr:blipFill><a:blip r:embed="rId1"/></xdr:blipFill>\
    </xdr:pic>
    """
}

private func sheetTwoCellAnchor(_ graphic: String) -> String {
    """
    <xdr:twoCellAnchor><xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff>\
    <xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>\
    <xdr:to><xdr:col>1</xdr:col><xdr:colOff>0</xdr:colOff>\
    <xdr:row>1</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>\
    \(graphic)<xdr:clientData/></xdr:twoCellAnchor>
    """
}

private func sheetOneCellAnchor(_ graphic: String) -> String {
    """
    <xdr:oneCellAnchor><xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff>\
    <xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>\
    <xdr:ext cx="1" cy="1"/>\
    \(graphic)<xdr:clientData/></xdr:oneCellAnchor>
    """
}

private func sheetDrawing(_ anchors: [String]) -> String {
    """
    \(xmlDeclaration)<xdr:wsDr xmlns:xdr="\(nsSheetDrawing)" xmlns:a="\(nsDrawingML)" \
    xmlns:r="\(nsOfficeRel)" xmlns:f="\(nsSpoof)">\(anchors.joined())</xdr:wsDr>
    """
}

/// The whole spoof anchor in the foreign namespace: locally it looks like a
/// qualified spreadsheet drawing object, but NONE of it is drawing markup.
private func spoofAnchor(id: Int, name: String) -> String {
    """
    <f:twoCellAnchor><f:from><f:col>0</f:col><f:row>0</f:row></f:from>\
    <f:to><f:col>1</f:col><f:row>1</f:row></f:to>\
    <f:sp><f:nvSpPr><f:cNvPr id="\(id)" name="\(name)"/></f:nvSpPr>\
    <f:spPr>\(spoofInkGeometry())</f:spPr></f:sp>\
    <f:clientData/></f:twoCellAnchor>
    """
}

/// Runs one test in its own scratch directory under the host temporary
/// directory; nothing is written into the repository or any Workspace.
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-ink-omission-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Suite("FloeDocuments.OfficeInkOmission")
struct OfficeInkOmissionTests {
    // MARK: - Fixtures

    private func writePackage(_ members: [String: String], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in members.sorted(by: { $0.key < $1.key }) {
            try archive.addFloeEntry(path: path, data: Data(text.utf8))
        }
    }

    private func openPackage(_ url: URL) throws -> OfficeArchive {
        try OfficeArchive(url: url, maximumEntries: 4096)
    }

    private func memberText(_ url: URL, _ path: String) throws -> String {
        let package = try openPackage(url)
        return String(decoding: try package.data(path: path, limit: 8 * 1_024 * 1_024),
                      as: UTF8.self)
    }

    private func memberBytes(_ url: URL, _ path: String) throws -> Data {
        let package = try openPackage(url)
        return try package.data(path: path, limit: 8 * 1_024 * 1_024)
    }

    /// All members of `lhs` byte-equal the same members of `rhs`
    /// (member list included).
    private func allMembersIdentical(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let a = try openPackage(lhs)
        let b = try openPackage(rhs)
        guard Set(a.paths) == Set(b.paths) else { return false }
        for path in a.paths {
            guard try a.data(path: path, limit: 8 * 1_024 * 1_024)
                    == b.data(path: path, limit: 8 * 1_024 * 1_024) else { return false }
        }
        return true
    }

    private func xlsx(at root: URL, named name: String, drawing: String) throws -> URL {
        let source = root.appendingPathComponent(name)
        try writePackage([
            "[Content_Types].xml":
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
            "xl/worksheets/sheet1.xml":
                "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>",
            "xl/drawings/drawing1.xml": drawing,
        ], to: source)
        return source
    }

    // MARK: - 1. Namespace enforcement (spoof class)

    @Test("Foreign-namespace look-alikes are neither candidates nor ink")
    func namespaceSpoofCannotEarnDeletion() throws {
        try withTemporaryDirectory { root in
            // (a) A fully foreign "anchor": not even a removable candidate.
            // (b) A REAL xdr anchor whose title and geometry live only in
            //     the spoof namespace: visited as a candidate but never
            //     proven ink.
            let drawing = sheetDrawing([
                spoofAnchor(id: 99, name: "Bézier curve 99"),
                sheetTwoCellAnchor("""
                <xdr:sp macro="" textlink=""><xdr:nvSpPr>\
                <f:cNvPr id="100" name="Bézier curve 100"/><xdr:cNvSpPr/>\
                </xdr:nvSpPr><xdr:spPr>\(spoofInkGeometry())</xdr:spPr>\
                <xdr:txBody><a:bodyPr/><a:p/></xdr:txBody></xdr:sp>
                """),
            ])
            let source = try xlsx(at: root, named: "spoof.xlsx", drawing: drawing)
            let copy = root.appendingPathComponent("spoof-copy.xlsx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 0,
                    "a spoofed title+geometry never earns a deletion")
            // Only the REAL anchor is a visited candidate; the foreign
            // anchor is not OOXML drawing markup at all.
            #expect(outcome.keptDrawingShapes == 1,
                    "the receipt counts the real visited candidate only")
            #expect(outcome.changedParts.isEmpty,
                    "nothing is rewritten when no ink was proven")
            let spoofUntouched = try allMembersIdentical(source, copy)
            #expect(spoofUntouched, "the spoof member stays byte-identical")
            let surviving = try memberText(copy, "xl/drawings/drawing1.xml")
            #expect(surviving.contains("Bézier curve 99"),
                    "the foreign anchor is untouched, not deleted")
        }
    }

    @Test("Real title with foreign geometry is retained")
    func realTitleWithForeignGeometryStays() throws {
        try withTemporaryDirectory { root in
            let drawing = sheetDrawing([
                sheetTwoCellAnchor(sheetShape(id: 5,
                                              name: "Bézier curve 5",
                                              geometry: spoofInkGeometry())),
            ])
            let source = try xlsx(at: root, named: "foreign-geom.xlsx", drawing: drawing)
            let counted = try OfficeInkShape.countInkStrokes(in: drawing, formatExtension: "xlsx")
            #expect(counted == 0,
                    "positive geometry must come from DrawingML main")
            let copy = root.appendingPathComponent("foreign-geom-copy.xlsx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 0)
            #expect(outcome.keptDrawingShapes == 1)
            let geometryUntouched = try allMembersIdentical(source, copy)
            #expect(geometryUntouched,
                    "the foreign-geometry drawing stays byte-identical")
        }
    }

    @Test("Foreign-namespace presentation shape is not a candidate")
    func foreignSpIsNeverACandidate() throws {
        try withTemporaryDirectory { root in
            let slide = """
            \(xmlDeclaration)<p:sld xmlns:p="\(nsPresentation)" xmlns:a="\(nsDrawingML)" \
            xmlns:f="\(nsSpoof)"><p:cSld><p:spTree>
            <f:sp><f:nvSpPr><f:cNvPr id="2" name="Bézier curve 1"/></f:nvSpPr>\
            <f:spPr>\(spoofInkGeometry())</f:spPr></f:sp>
            </p:spTree></p:cSld></p:sld>
            """
            let source = root.appendingPathComponent("spoof.pptx")
            try writePackage([
                "[Content_Types].xml":
                    "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
                "ppt/slides/slide1.xml": slide,
            ], to: source)
            let counted = try OfficeInkShape.countInkStrokes(in: slide, formatExtension: "pptx")
            #expect(counted == 0,
                    "a foreign `sp` is not even a drawing candidate")
            let copy = root.appendingPathComponent("spoof-copy.pptx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 0)
            #expect(outcome.keptDrawingShapes == 0)
            #expect(outcome.changedParts.isEmpty)
            let slideUntouched = try allMembersIdentical(source, copy)
            #expect(slideUntouched,
                    "the foreign-namespace slide stays byte-identical")
        }
    }

    // MARK: - 2. Mixed-candidate granularity

    @Test("A mixed anchor keeps every independent sibling object")
    func mixedAnchorIsRetainedWhole() throws {
        try withTemporaryDirectory { root in
            // ONE anchor containing two independent shapes: a proven ink
            // stroke and an unknown freeform without text or preset. The
            // ink child's title+geometry must not erase the ordinary one.
            let mixed = sheetTwoCellAnchor(
                sheetShape(id: 1, name: "Bézier curve 1", geometry: realInkGeometry())
                + sheetShape(id: 2, name: "Freeform 2", geometry: realInkGeometry())
            )
            // A separate, ordinary single-shape ink anchor next to it.
            let single = sheetTwoCellAnchor(
                sheetShape(id: 3, name: "Polyline with 3 points 1",
                           geometry: realInkGeometry(closed: true))
            )
            let drawing = sheetDrawing([mixed, single])
            let source = try xlsx(at: root, named: "mixed.xlsx", drawing: drawing)
            let counted = try OfficeInkShape.countInkStrokes(in: drawing, formatExtension: "xlsx")
            #expect(counted == 1,
                    "only the unambiguous single-shape candidate counts as ink")
            let copy = root.appendingPathComponent("mixed-copy.xlsx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 1,
                    "the ordinary sibling never disappears with the ink")
            #expect(outcome.keptDrawingShapes == 1)
            #expect(outcome.changedParts == ["xl/drawings/drawing1.xml"])
            let rewritten = try memberText(copy, "xl/drawings/drawing1.xml")
            #expect(rewritten.contains("Freeform 2"),
                    "the unknown freeform sibling survives")
            #expect(rewritten.contains("Bézier curve 1"),
                    "the mixed anchor survives whole, title intact")
            #expect(!rewritten.contains("Polyline with 3 points 1"),
                    "the separate proven-ink anchor is omitted")
            let mixedSheetBefore = try memberBytes(source, "xl/worksheets/sheet1.xml")
            let mixedSheetAfter = try memberBytes(copy, "xl/worksheets/sheet1.xml")
            #expect(mixedSheetBefore == mixedSheetAfter)
            let mixedTypesBefore = try memberBytes(source, "[Content_Types].xml")
            let mixedTypesAfter = try memberBytes(copy, "[Content_Types].xml")
            #expect(mixedTypesBefore == mixedTypesAfter)
        }
    }

    // MARK: - 3. Command spelling

    @Test("The invented qtTo spelling does not qualify; quadBezTo does")
    func qtToIsNotAnOOXMLCommand() throws {
        try withTemporaryDirectory { root in
            // moveTo + two `a:qtTo` look-alikes: only ONE standard command
            // (moveTo) counts, so the two-command floor is not reached.
            let qtOnly = sheetTwoCellAnchor(sheetShape(id: 1,
                                                      name: "Bézier curve 1",
                                                      geometry: realInkGeometry(command: "qtTo")))
            let quad = sheetTwoCellAnchor(sheetShape(id: 2,
                                                     name: "Bézier curve 2",
                                                     geometry: realInkGeometry(command: "quadBezTo")))
            let drawing = sheetDrawing([qtOnly, quad])
            let source = try xlsx(at: root, named: "spelling.xlsx", drawing: drawing)
            let counted = try OfficeInkShape.countInkStrokes(in: drawing, formatExtension: "xlsx")
            #expect(counted == 1,
                    "moveTo alone is below the command floor")
            let copy = root.appendingPathComponent("spelling-copy.xlsx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 1)
            #expect(outcome.keptDrawingShapes == 1)
            let rewritten = try memberText(copy, "xl/drawings/drawing1.xml")
            #expect(rewritten.contains("Bézier curve 1"), "qtTo markup is not engine ink")
            #expect(!rewritten.contains("Bézier curve 2"), "quadBezTo markup is engine ink")
        }
    }

    // MARK: - 4. Source-preserving omission (open + closed + text contract)

    @Test("Omission removes exactly the qualified strokes and preserves bytes")
    func omissionPreservesSourceAndOrdinaryObjects() throws {
        try withTemporaryDirectory { root in
            let openStroke = sheetTwoCellAnchor(
                sheetShape(id: 1, name: "Polyline with 3 points 1",
                           geometry: realInkGeometry()))
            let closedStroke = sheetTwoCellAnchor(
                sheetShape(id: 2, name: "Bézier curve 2",
                           geometry: realInkGeometry(closed: true)))
            let preset = sheetOneCellAnchor(sheetPresetShape(id: 3, name: "Circle 1"))
            let picture = sheetTwoCellAnchor(sheetPictureShape(id: 4, name: "Picture 4"))
            let renamed = sheetTwoCellAnchor(
                sheetShape(id: 5, name: "Sketch 5", geometry: realInkGeometry()))
            let labelled = sheetTwoCellAnchor("""
            <xdr:sp macro="" textlink=""><xdr:nvSpPr>\
            <xdr:cNvPr id="6" name="Bézier curve 6"/><xdr:cNvSpPr/></xdr:nvSpPr>\
            <xdr:spPr>\(realInkGeometry())</xdr:spPr>\
            <xdr:txBody><a:bodyPr/><a:lstStyle/>\
            <a:p><a:r><a:t>NOTE</a:t></a:r></a:p></xdr:txBody></xdr:sp>
            """)
            let drawing = sheetDrawing([openStroke, closedStroke, preset, picture,
                                        renamed, labelled])
            let source = try xlsx(at: root, named: "contract.xlsx", drawing: drawing)
            let sourceBytes = try Data(contentsOf: source)
            let counted = try OfficeInkShape.countInkStrokes(in: drawing, formatExtension: "xlsx")
            #expect(counted == 2,
                    "open and CLOSED named strokes count; preset/picture/renamed/labelled do not")
            let copy = root.appendingPathComponent("contract-copy.xlsx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 2)
            #expect(outcome.keptDrawingShapes == 4)
            #expect(outcome.changedParts == ["xl/drawings/drawing1.xml"])
            #expect(outcome.sourceSHA256.count == 64)
            #expect(outcome.copySHA256.count == 64)
            let sourceAfter = try Data(contentsOf: source)
            #expect(sourceAfter == sourceBytes, "the source is never written")
            let rewritten = try memberText(copy, "xl/drawings/drawing1.xml")
            #expect(!rewritten.contains("Polyline with 3 points 1"))
            #expect(!rewritten.contains("Bézier curve 2"),
                    "the closed filled named annotation is still omitted")
            #expect(rewritten.contains("Circle 1") && rewritten.contains("prstGeom"))
            #expect(rewritten.contains("Picture 4") && rewritten.contains("blip"))
            #expect(rewritten.contains("Sketch 5"), "renamed freeform stays")
            #expect(rewritten.contains("NOTE"), "labelled freeform stays with its text")
            let countedResidual = try OfficeInkShape.countInkStrokes(in: rewritten, formatExtension: "xlsx")
            #expect(countedResidual == 0,
                    "the residual verifier sees no ink in the prepared part")
            let contractSheetBefore = try memberBytes(source, "xl/worksheets/sheet1.xml")
            let contractSheetAfter = try memberBytes(copy, "xl/worksheets/sheet1.xml")
            #expect(contractSheetBefore == contractSheetAfter,
                    "the worksheet member is byte-identical")
        }
    }

    // MARK: - 5. Word: docPr outside wsp, sibling run text, fallback

    private func wordDocument(_ paragraphs: [String]) -> String {
        """
        \(xmlDeclaration)<w:document xmlns:w="\(nsWord)" xmlns:wp="\(nsWordDrawing)" \
        xmlns:wps="\(nsWordShape)" xmlns:a="\(nsDrawingML)" xmlns:mc="\(nsCompatibility)" \
        xmlns:v="\(nsVML)" xmlns:r="\(nsOfficeRel)" xmlns:f="\(nsSpoof)"><w:body>\
        \(paragraphs.joined())</w:body></w:document>
        """
    }

    private func wordInkDrawing(name: String, docPrId: Int,
                                geometry: String = realInkGeometry()) -> String {
        """
        <w:r><w:t>READ</w:t><w:drawing><wp:inline>
        <wp:extent cx="1" cy="1"/><wp:docPr id="\(docPrId)" name="\(name)"/>
        <a:graphic><a:graphicData uri="\(nsWordShape)">
        <wps:wsp><wps:nvSpPr><wps:cNvPr id="\(docPrId)" name="\(name)"/>
        <wps:cNvSpPr/></wps:nvSpPr><wps:spPr>\(geometry)</wps:spPr>
        <wps:bodyPr/></wps:wsp></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    @Test("Word drawing with docPr title is omitted while run text survives")
    func wordOmissionKeepsSiblingText() throws {
        try withTemporaryDirectory { root in
            let inkParagraph = "<w:p><w:r><w:t>KEEP THIS TEXT</w:t></w:r>"
                + wordInkDrawing(name: "Bézier curve 7", docPrId: 7)
                + "<w:r><w:t>READ AFTER INK</w:t></w:r></w:p>"
            let labelled = """
            <w:p><w:r><w:drawing><mc:AlternateContent>
            <mc:Choice Requires="wps"><wp:inline>
            <wp:extent cx="1" cy="1"/><wp:docPr id="9" name="Bézier curve 9"/>
            <a:graphic><a:graphicData uri="\(nsWordShape)">
            <wps:wsp><wps:nvSpPr><wps:cNvPr id="9" name="Bézier curve 9"/>
            <wps:cNvSpPr/></wps:nvSpPr><wps:spPr>\(realInkGeometry())</wps:spPr>
            <wps:txbx><w:txbxContent><w:p><w:r><w:t>Visible label</w:t></w:r></w:p>
            </w:txbxContent></wps:txbx><wps:bodyPr/></wps:wsp>
            </a:graphicData></a:graphic></wp:inline></mc:Choice>
            <mc:Fallback><w:pict><v:shape><v:textbox><w:p><w:r>
            <w:t>Visible label</w:t></w:r></w:p></v:textbox></v:shape></w:pict></mc:Fallback>
            </mc:AlternateContent></w:drawing></w:r></w:p>
            """
            let renamed = """
            <w:p><w:r><w:drawing><wp:inline>
            <wp:extent cx="1" cy="1"/><wp:docPr id="11" name="Sketch 11"/>
            <a:graphic><a:graphicData uri="\(nsWordShape)">
            <wps:wsp><wps:nvSpPr><wps:cNvPr id="11" name="Sketch 11"/>
            <wps:cNvSpPr/></wps:nvSpPr><wps:spPr>\(realInkGeometry())</wps:spPr>
            <wps:bodyPr/></wps:wsp></a:graphicData></a:graphic></wp:inline></w:drawing>
            </w:r></w:p>
            """
            // docPr carries the stroke name but ALL its geometry is foreign.
            let spoofed = """
            <w:p><w:r><w:drawing><wp:inline>
            <wp:extent cx="1" cy="1"/><wp:docPr id="13" name="Bézier curve 13"/>
            <a:graphic><a:graphicData uri="\(nsWordShape)">
            <wps:wsp><wps:nvSpPr><wps:cNvPr id="13" name="Bézier curve 13"/>
            <wps:cNvSpPr/></wps:nvSpPr><wps:spPr>\(spoofInkGeometry())</wps:spPr>
            <wps:bodyPr/></wps:wsp></a:graphicData></a:graphic></wp:inline></w:drawing>
            </w:r></w:p>
            """
            let document = wordDocument([inkParagraph, labelled, renamed, spoofed])
            let source = root.appendingPathComponent("word-ink.docx")
            try writePackage([
                "[Content_Types].xml":
                    "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
                "word/document.xml": document,
                "word/styles.xml": "<w:styles xmlns:w=\"\(nsWord)\"/>",
            ], to: source)
            let counted = try OfficeInkShape.countInkStrokes(in: document, formatExtension: "docx")
            #expect(counted == 1,
                    "only the drawing with real qualified geometry counts")
            let copy = root.appendingPathComponent("word-ink-copy.docx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 1)
            #expect(outcome.keptDrawingShapes == 3,
                    "labelled, renamed and foreign-geometry drawings are all kept")
            #expect(outcome.changedParts == ["word/document.xml"])
            let rewritten = try memberText(copy, "word/document.xml")
            #expect(rewritten.contains("KEEP THIS TEXT"), "sibling run text survives")
            #expect(rewritten.contains("READ AFTER INK"),
                    "text after the drawing in the same paragraph survives")
            #expect(rewritten.contains("Visible label"),
                    "the labelled AlternateContent object stays whole")
            #expect(rewritten.contains("Sketch 11") && rewritten.contains("Bézier curve 13"),
                    "renamed and foreign-geometry drawings stay")
            #expect(!rewritten.contains("READ</w:t><w:drawing>"),
                    "the omitted run keeps its text but loses the drawing")
            let countedBefore_rewritten = try OfficeInkShape.countInkStrokes(in: rewritten, formatExtension: "docx")
            #expect(countedBefore_rewritten == 0)
            let stylesBefore = try memberBytes(source, "word/styles.xml")
            let stylesAfter = try memberBytes(copy, "word/styles.xml")
            #expect(stylesBefore == stylesAfter, "unrelated Word member stays byte-identical")
        }
    }

    // MARK: - 6. Truthful no-change receipt

    @Test("No-ink packages still report every visited candidate")
    func receiptCountsUnchangedParts() throws {
        try withTemporaryDirectory { root in
            let drawing = sheetDrawing([
                sheetOneCellAnchor(sheetPresetShape(id: 1, name: "Circle 1")),
                sheetTwoCellAnchor(sheetPictureShape(id: 2, name: "Picture 2")),
                sheetTwoCellAnchor(sheetShape(id: 3,
                                              name: "Freeform 3",
                                              geometry: realInkGeometry())),
            ])
            let source = try xlsx(at: root, named: "noink.xlsx", drawing: drawing)
            let copy = root.appendingPathComponent("noink-copy.xlsx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 0)
            #expect(outcome.keptDrawingShapes == 3,
                    "kept counts candidates even when no part was rewritten")
            #expect(outcome.changedParts.isEmpty)
            let receiptUntouched = try allMembersIdentical(source, copy)
            #expect(receiptUntouched,
                    "with nothing omitted every member stays byte-identical")
        }
    }

    // MARK: - 7. Presentation omission

    @Test("Qualified presentation shape is omitted; picture and preset stay")
    func pptxOmission() throws {
        try withTemporaryDirectory { root in
            let slide = """
            \(xmlDeclaration)<p:sld xmlns:p="\(nsPresentation)" xmlns:a="\(nsDrawingML)">
            <p:cSld><p:spTree>
            <p:nvGrpSpPr><p:cNvPr id="1" name="Group 1"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Bézier curve 3"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
            <p:spPr>\(realInkGeometry(closed: true))</p:spPr>
            <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>
            <p:sp><p:nvSpPr><p:cNvPr id="3" name="Circle 3"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom></p:spPr>
            <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>
            <p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture 4"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
            </p:spTree></p:cSld></p:sld>
            """
            let source = root.appendingPathComponent("slide-ink.pptx")
            try writePackage([
                "[Content_Types].xml":
                    "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
                "ppt/slides/slide1.xml": slide,
            ], to: source)
            let countedBefore_slide = try OfficeInkShape.countInkStrokes(in: slide, formatExtension: "pptx")
            #expect(countedBefore_slide == 1)
            let copy = root.appendingPathComponent("slide-ink-copy.pptx")
            let outcome = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                                   destinationURL: copy)
            #expect(outcome.omittedInkDrawings == 1,
                    "the closed qualified slide shape is omitted too")
            #expect(outcome.keptDrawingShapes == 1)
            #expect(outcome.changedParts == ["ppt/slides/slide1.xml"])
            let rewritten = try memberText(copy, "ppt/slides/slide1.xml")
            #expect(!rewritten.contains("Bézier curve 3"))
            #expect(rewritten.contains("Circle 3") && rewritten.contains("Picture 4"))
        }
    }

    // MARK: - 8. Guard refusals

    @Test("Unsupported formats and stale sources are refused")
    func refusals() throws {
        try withTemporaryDirectory { root in
            #expect(!OfficeInkOmission.supports(formatExtension: "xls"))
            #expect(OfficeInkOmission.supports(formatExtension: "DOCX"))
            let legacy = root.appendingPathComponent("legacy.ods")
            try writePackage(["content.xml": "<office/>"], to: legacy)
            let legacyCopy = root.appendingPathComponent("legacy-copy.ods")
            #expect(throws: OfficeInkOmissionError.self) {
                _ = try OfficeInkOmission.prepareOmittedCopy(sourceURL: legacy,
                                                             destinationURL: legacyCopy)
            }
            let drawing = sheetDrawing([sheetTwoCellAnchor(
                sheetShape(id: 1, name: "Bézier curve 1", geometry: realInkGeometry()))])
            let source = try xlsx(at: root, named: "guard.xlsx", drawing: drawing)
            #expect(throws: OfficeInkOmissionError.destinationIsSource) {
                _ = try OfficeInkOmission.prepareOmittedCopy(sourceURL: source,
                                                             destinationURL: source)
            }
            #expect(throws: OfficeInkOmissionError.staleSource) {
                _ = try OfficeInkOmission.prepareOmittedCopy(
                    sourceURL: source,
                    destinationURL: root.appendingPathComponent("guard-copy.xlsx"),
                    expectedSHA256: String(repeating: "0", count: 64))
            }
            let countedUnsupported = try OfficeInkShape.countInkStrokes(in: "<x/>",
                                                                       formatExtension: "ods")
            #expect(countedUnsupported == 0,
                    "counting on an unqualified format is zero, not an error")
        }
    }
}

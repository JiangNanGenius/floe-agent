// SPDX-License-Identifier: MPL-2.0
// FloeDocuments — export-only handwriting (ink) omission for prepared PDF copies.
//
// The print/export pipeline already renders from task-owned isolated copies
// (`OfficePrintCopy` for `.xlsx`; the App service's own child directory for
// `.docx`/`.pptx`). This module is the ONLY place allowed to turn
// `OfficePDFPrintPlan.includeInk == false` into bytes: it produces a new
// private copy whose drawing members omit the app's handwriting, while every
// other package member — typed cells and text, charts, images, styles,
// relationships, theme, docProps — streams through the proven
// `OfficeArchive.writeCopy` byte-preserving path. Rewriting the intentionally
// changed drawing/document members through the canonical
// `OfficeXMLNode`/`OfficeBoundedXML` serializer (the module's existing
// namespace-aware bounded tree: no DTD/entities, node and depth caps, real
// quoting) is part of this contract: every OTHER member stays byte-identical
// and the source package is never written.
//
// Identification is provenance-gated and deliberately narrow. The pinned
// engine saves the app's pen/marker/highlighter strokes as DrawingML
// custom-geometry freeform shapes (verified against the real user workbook:
// 52 drawing shapes — 51 titled with the engine's own freeform stroke names
// "Bézier curve N"/"Polyline with N points", of which 2 are closed named
// Bézier annotations, 1 is an unrelated preset `a:prstGeom` object and 0
// carry text; command names are moveTo/lnTo/cubicBezTo — 51 moveTo, 115 lnTo,
// 280 cubicBezTo; the qualified live-ink vector counter counts the same
// `a:custGeom` DrawingML signature across all three formats). POSITIVE
// classification is NAMESPACE-enforced, never local-name-only: geometry and
// title evidence must come from the real OOXML markup languages (DrawingML
// main for `custGeom`/`pathLst`/`path`/`pt`/commands, spreadsheetDrawing /
// wordprocessingDrawing / wordprocessingShape / presentation for the
// `cNvPr`/`docPr` titles and the anchor/`sp` candidates). A foreign
// namespace merely named like DrawingML must not earn a deletion — matching
// positives by local name across arbitrary namespaces was the spoof class
// this module closes. Only the NEGATIVE guards (text/image/preset/
// graphicFrame) stay conservative local-name matches, because they can only
// ever RETAIN a drawing. A drawing candidate is proven ink only when ALL
// hold:
//  * the candidate carries exactly ONE recognized drawing shape (`xdr:sp`,
//    `wps:wsp` or `p:sp` in its real namespace); zero or more than one
//    independent shape is a mixed/ambiguous drawing representation and is
//    RETAINED whole — so an unknown freeform sibling can never be erased
//    using the title or geometry of a different child,
//  * that shape's title (`cNvPr@name` in a real shape namespace) or the
//    candidate's drawing-object title (`wp:docPr@name` in
//    wordprocessingDrawing, which in real WordML sits OUTSIDE `wps:wsp`)
//    begins with the engine's own freeform stroke prefixes ("Bézier
//    curve"/"Bezier curve" or "Polyline with"); a missing title, a renamed
//    drawing, a foreign-namespace title or any other title is ambiguous and
//    is RETAINED — arbitrary custom geometry is never treated as
//    handwriting just because it uses `custGeom`,
//  * the candidate declares `a:custGeom` AND `a:pathLst` in DrawingML main,
//  * the candidate contains at least one real `a:path` (DrawingML main)
//    with at least two standard point commands — only the ECMA-376
//    spellings moveTo/lnTo/quadBezTo/cubicBezTo/arcTo count (`qtTo` is not
//    an OOXML element and is not matched) — and two `a:pt` coordinates.
//    Both engine spellings qualify — the open unfilled stroke
//    (`fill="none"`) and the closed named Bézier annotation (default-filled
//    with `a:close`) — because the strict provenance title, the
//    namespace-qualified geometry guards and the text/image/preset guards,
//    not the open/filled detail, carry the identification,
//  * the DRAWING itself carries no typed text: any `t` element (a:t shape
//    text or a WordML `w:t` inside a VML-fallback textbox) with
//    non-whitespace content means a labelled object, never ink, and the
//    whole candidate is retained. Empty engine-generated txBody containers
//    carry no `t` element and never block a real stroke. The scan is limited
//    to the candidate subtree, so SIBLING run text outside the drawing is
//    preserved while its ink is removed,
//  * the candidate contains no `prstGeom` (preset geometry — an inserted or
//    pen-shape-recognition result, never a raw stroke), no `blip` (image),
//    no `graphicFrame` (chart/object frame) and no `pic` shape.
// Removal granularity is the DRAWING REPRESENTATION, never its parent
// context: for `.docx` that is the outermost `mc:AlternateContent` element —
// whose `mc:Choice` (DrawingML) and `mc:Fallback` (VML) branches are the
// SAME object and leave together — or a `w:drawing` that is not inside an
// AlternateContent. The enclosing `w:r` and its `w:t` siblings stay. For
// `.xlsx` it is the `xdr` anchor element (spreadsheetDrawing namespace);
// for `.pptx` the `p:sp` shape (presentation namespace). Ambiguity always
// keeps the object. Known honest boundary: the engine's
// own toolbar freeform tool produces the identical title pattern, so a
// toolbar-drawn freeform polygon is omitted together with pen strokes when
// the user turns handwriting off — the OOXML package carries no provenance
// field that separates the two. A workbook part whose only shapes were
// proven ink becomes an empty but valid drawing root, which the engine
// prints as "no drawings", so the automatic print bounds are derived at
// print time WITHOUT the omitted ink; an explicit user cell range and a
// sheet's own saved print area stay exactly honored, because omission never
// rewrites print members.
//
// Formats qualified here are exactly the saved isolated export route:
// `.xlsx` (`xl/drawings/drawing*.xml`), `.docx` (drawing runs in
// `word/document.xml`, headers/footers, footnotes/endnotes) and `.pptx`
// (`ppt/slides/slide*.xml`; masters/layouts are never touched). Legacy
// packages (`.xls/.ods/.doc/.odt/.rtf/.ppt/.odp`) cannot be rewritten
// through this route and must keep reporting `includeInk` as unsupported —
// the omission is never silently guessed for them.

import Foundation
import FloeCore

public enum OfficeInkOmissionError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case destinationIsSource
    case staleSource
    case sourceChangedDuringOmission
    case packageUnresolvable(reason: String)
    case verificationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "Ink omission is prepared for the saved isolated export formats .xlsx, .docx and .pptx only (requested .\(ext))."
        case .destinationIsSource:
            "The ink-omitted copy must be written to a different, task-owned path; the source is never a destination."
        case .staleSource:
            "The document changed since it was read; the ink-omitted copy was refused and the source is untouched."
        case .sourceChangedDuringOmission:
            "The source changed while the ink-omitted copy was being prepared; nothing was committed."
        case .packageUnresolvable(let reason):
            "The package structure cannot be resolved safely (\(reason))."
        case .verificationFailed(let reason):
            "The prepared ink-omitted copy failed verification (\(reason)); nothing was committed."
        }
    }
}

/// What the omission actually removed, measured from the staged copy — never
/// a restatement of the request.
public struct OfficeInkOmissionOutcome: Codable, Sendable, Equatable {
    public var formatExtension: String
    /// Total proven-ink drawings removed across all changed parts.
    public var omittedInkDrawings: Int
    /// Drawing candidates the copy still carries (proven non-ink: images,
    /// charts, preset shapes, text boxes, labelled or renamed freeforms,
    /// mixed/ambiguous candidates), counted across EVERY visited drawing
    /// part — not only the parts whose bytes changed. A copy with ordinary
    /// shapes and no ink truthfully reports their number here.
    public var keptDrawingShapes: Int
    /// Members whose bytes were rewritten (canonically through the bounded
    /// tree); every other member is verified byte-identical.
    public var changedParts: [String]
    public var sourceSHA256: String
    public var copySHA256: String

    public init(formatExtension: String,
                omittedInkDrawings: Int,
                keptDrawingShapes: Int,
                changedParts: [String],
                sourceSHA256: String,
                copySHA256: String) {
        self.formatExtension = formatExtension
        self.omittedInkDrawings = omittedInkDrawings
        self.keptDrawingShapes = keptDrawingShapes
        self.changedParts = changedParts
        self.sourceSHA256 = sourceSHA256
        self.copySHA256 = copySHA256
    }
}

// Namespaces the omission scanner needs beyond OfficeXMLNamespace. These are
// the real ECMA-376 / ISO 29500 markup languages; POSITIVE classification
// (titles, geometry, candidates) only accepts evidence in them, so a foreign
// namespace that merely reuses the local names cannot earn a deletion.
private enum InkNamespace {
    static let sheetDrawing = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    static let compatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let wordDrawing = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let wordShape = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
}

/// Namespaces in which a drawing-shape non-visual property element `cNvPr`
/// is real OOXML shape title markup (spreadsheet shape, Word processing
/// shape, presentation shape). Anything else is foreign evidence.
private let inkShapeTitleNamespaces: Set<String> = [
    InkNamespace.sheetDrawing,
    InkNamespace.wordShape,
    OfficeXMLNamespace.presentation,
]

/// The shared structural predicate, public so App-side qualification and the
/// engine acceptance tests measure the exact same fact the writer used.
public enum OfficeInkShape {
    /// The engine's own freeform stroke title prefixes, saved verbatim in
    /// OOXML regardless of UI locale (verified on the real user workbook and
    /// on the qualified three-format live-ink saves). Anything else is
    /// ambiguous and is retained.
    public static let strokeTitlePrefixes = ["Bézier curve", "Bezier curve", "Polyline with"]

    /// True when the node is a proven-ink drawing candidate (see the file
    /// header). Works on any subtree node; the pipeline always applies it to
    /// whole drawing candidates, never to parent runs. Positive evidence
    /// (shape granularity, titles, geometry, path commands) is namespace-
    /// enforced; only the text/image/preset/graphicFrame guards match local
    /// names conservatively. Internal because `OfficeXMLNode` is module-
    /// internal.
    static func isInkNode(_ node: OfficeXMLNode) -> Bool {
        // Mixed or ambiguous candidates are retained whole: exactly one
        // recognized drawing shape must exist, so a title+geometry match
        // from one child can never erase an independent sibling object.
        let shapes = shapeNodes(in: node)
        guard shapes.count == 1 else { return false }
        guard hasQualifiedStrokeTitle(in: node),
              hasQualifiedInkGeometry(in: node),
              nodeLocal(node, "prstGeom").isEmpty,
              nodeLocal(node, "blip").isEmpty,
              nodeLocal(node, "graphicFrame").isEmpty,
              nodeLocal(node, "pic").isEmpty
        else { return false }
        for text in nodeLocal(node, "t") {
            if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    /// The recognized drawing-shape objects inside a candidate (`xdr:sp`,
    /// `wps:wsp`, `p:sp` — in their real namespaces), in document order,
    /// not double-counting a shape nested inside a shape. A candidate that
    /// IS itself a shape (the `.pptx` `p:sp` granularity) counts as that one
    /// shape. Foreign-namespace elements merely named `sp`/`wsp` are not
    /// drawing objects at all.
    static func shapeNodes(in candidate: OfficeXMLNode) -> [OfficeXMLNode] {
        if isShapeNode(candidate) { return [candidate] }
        var found: [OfficeXMLNode] = []
        func walk(_ node: OfficeXMLNode) {
            for child in node.children {
                if isShapeNode(child) {
                    found.append(child)   // do not walk into a shape's subtree
                } else {
                    walk(child)
                }
            }
        }
        walk(candidate)
        return found
    }

    static func isShapeNode(_ node: OfficeXMLNode) -> Bool {
        switch node.local {
        case "sp":
            return node.namespace == InkNamespace.sheetDrawing
                || node.namespace == OfficeXMLNamespace.presentation
        case "wsp":
            return node.namespace == InkNamespace.wordShape
        default:
            return false
        }
    }

    /// The drawing's shape title (`cNvPr` in a real shape namespace) or the
    /// candidate's drawing-object title (`docPr` in wordprocessingDrawing,
    /// which real WordML places OUTSIDE `wps:wsp`) must carry the engine's
    /// freeform stroke prefix. A missing title, a renamed drawing or a
    /// foreign-namespace look-alike title is not proven ink.
    static func hasQualifiedStrokeTitle(in node: OfficeXMLNode) -> Bool {
        let titles = descendants(node, "cNvPr", namespaces: inkShapeTitleNamespaces)
            + descendants(node, "docPr", namespaces: [InkNamespace.wordDrawing])
        for title in titles {
            guard let name = title.attribute("name") else { continue }
            if strokeTitlePrefixes.contains(where: { name.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    /// Custom-geometry path evidence, restricted to DrawingML main. Only the
    /// ECMA-376 command spellings count; `qtTo` is not an OOXML element.
    static func hasQualifiedInkGeometry(in node: OfficeXMLNode) -> Bool {
        let a: Set<String> = [OfficeXMLNamespace.drawing]
        guard !descendants(node, "custGeom", namespaces: a).isEmpty,
              !descendants(node, "pathLst", namespaces: a).isEmpty
        else { return false }
        for path in descendants(node, "path", namespaces: a) {
            var commands = 0
            for command in ["moveTo", "lnTo", "quadBezTo", "cubicBezTo", "arcTo"] {
                commands += descendants(path, command, namespaces: a).count
            }
            let points = descendants(path, "pt", namespaces: a).count
            if commands >= 2 && points >= 2 { return true }
        }
        return false
    }

    /// Count of proven-ink drawing candidates in one whole part, per format
    /// (Word counts the drawing representation — docPr qualifies the object
    /// even outside `wps:wsp` — so a residual verifier can never falsely
    /// pass on a Word part).
    public static func countInkStrokes(in xml: String, formatExtension: String) throws -> Int {
        guard let candidates = try drawingCandidates(ext: formatExtension, xml: xml) else {
            return 0
        }
        return candidates.filter { isInkNode($0) }.count
    }

    /// Tree-based counter used by the writer on the SAME tree it prunes.
    static func countInkStrokes(in root: OfficeXMLNode, formatExtension: String) throws -> Int {
        guard let candidates = try drawingCandidates(ext: formatExtension, root: root) else {
            return 0
        }
        return candidates.filter { isInkNode($0) }.count
    }

    // MARK: - Tree helpers (build on the proven OfficeBoundedXML node)

    /// Depth-first descendants matching a LOCAL name across all namespaces.
    /// Used ONLY for the conservative NEGATIVE guards (`t`, `prstGeom`,
    /// `blip`, `graphicFrame`, `pic`): a match anywhere, in any namespace,
    /// can only ever RETAIN a drawing. Positive evidence never uses this —
    /// it goes through the namespace-enforced `descendants(_:namespaces:)`
    /// helpers below, because local-name positives across arbitrary
    /// namespaces could otherwise earn a deletion of a foreign object.
    static func nodeLocal(_ root: OfficeXMLNode, _ local: String) -> [OfficeXMLNode] {
        var found: [OfficeXMLNode] = []
        func walk(_ node: OfficeXMLNode) {
            for child in node.children {
                if child.local == local { found.append(child) }
                walk(child)
            }
        }
        walk(root)
        return found
    }

    /// Depth-first descendants matching a LOCAL name only in the given real
    /// OOXML namespaces. The backbone of positive classification.
    static func descendants(_ root: OfficeXMLNode, _ local: String,
                            namespaces: Set<String>) -> [OfficeXMLNode] {
        var found: [OfficeXMLNode] = []
        func walk(_ node: OfficeXMLNode) {
            for child in node.children {
                if child.local == local, namespaces.contains(child.namespace) {
                    found.append(child)
                }
                walk(child)
            }
        }
        walk(root)
        return found
    }

    /// The removable drawing candidates of one part, in document order.
    static func drawingCandidates(ext: String, xml: String) throws -> [OfficeXMLNode]? {
        guard OfficeInkOmission.supports(formatExtension: ext) else { return nil }
        return try drawingCandidates(ext: ext, root: OfficeXMLNode.parse(xml))
    }

    /// Candidates computed from an ALREADY parsed tree, so the writer prunes
    /// exactly the nodes it classified (never a second parse of the same
    /// bytes).
    static func drawingCandidates(ext: String, root: OfficeXMLNode) throws -> [OfficeXMLNode]? {
        guard OfficeInkOmission.supports(formatExtension: ext) else { return nil }
        switch ext {
        case "xlsx":
            // Every spreadsheetDrawing anchor is one drawing object; a
            // foreign-namespace look-alike anchor is not markup this module
            // may touch.
            let xdr: Set<String> = [InkNamespace.sheetDrawing]
            return descendants(root, "twoCellAnchor", namespaces: xdr)
                + descendants(root, "oneCellAnchor", namespaces: xdr)
                + descendants(root, "absoluteAnchor", namespaces: xdr)
        case "docx":
            var candidates: [OfficeXMLNode] = []
            // Outermost AlternateContent (Choice+Fallback = ONE object) plus
            // bare w:drawing nodes that are not inside one. Parent runs and
            // their text siblings are never candidates.
            func collect(_ node: OfficeXMLNode, insideAlternates: Bool) {
                if node.local == "AlternateContent", node.namespace == InkNamespace.compatibility {
                    if !insideAlternates { candidates.append(node) }
                    for child in node.children { collect(child, insideAlternates: true) }
                    return
                }
                if node.local == "drawing", node.namespace == OfficeXMLNamespace.word,
                   !insideAlternates {
                    candidates.append(node)
                    return
                }
                for child in node.children { collect(child, insideAlternates: insideAlternates) }
            }
            collect(root, insideAlternates: false)
            return candidates
        default: // pptx
            // p:sp shapes on the slide in the REAL presentation namespace;
            // p:pic / graphicFrame / groups are not sp elements and a
            // foreign-namespace look-alike `sp` is not a candidate.
            return descendants(root, "sp", namespaces: [OfficeXMLNamespace.presentation])
        }
    }
}

public enum OfficeInkOmission {
    private static let maximumEntries = 4_096
    private static let maximumXMLBytes: UInt32 = 8 * 1_024 * 1_024
    private static let maximumMemberBytes: UInt32 = 64 * 1_024 * 1_024
    private static let maximumTotalBytes = 256 * 1_024 * 1_024

    /// True when the saved-file isolated route can prepare an ink-omitted
    /// copy for this extension. The App and the assistant must show/accept
    /// `includeInk = false` only where this returns true.
    public static func supports(formatExtension: String) -> Bool {
        switch formatExtension.lowercased() {
        case "xlsx", "docx", "pptx": return true
        default: return false
        }
    }

    /// Builds a task-owned copy of `sourceURL` at `destinationURL` whose
    /// qualified drawing members omit every proven-ink drawing candidate.
    /// The source is verified (`expectedSHA256` and again after staging) and
    /// never written. Refuses formats outside `supports(formatExtension:)`.
    public static func prepareOmittedCopy(sourceURL: URL,
                                          destinationURL: URL,
                                          expectedSHA256: String? = nil) throws
        -> OfficeInkOmissionOutcome {
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else {
            throw OfficeInkOmissionError.destinationIsSource
        }
        let ext = sourceURL.pathExtension.lowercased()
        guard supports(formatExtension: ext) else {
            throw OfficeInkOmissionError.unsupportedFormat(sourceURL.pathExtension)
        }
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: sourceURL)
        if let expectedSHA256, sourceSHA != expectedSHA256.lowercased() {
            throw OfficeInkOmissionError.staleSource
        }
        let package = try OfficeArchive(url: sourceURL, maximumEntries: maximumEntries)
        var replacements: [String: Data] = [:]
        var partFacts: [(part: String, omitted: Int, kept: Int)] = []
        for part in inkPartPaths(ext: ext, in: package.paths) {
            let original = try package.xml(path: part, limit: maximumXMLBytes)
            let root = try OfficeXMLNode.parse(original)
            let rewrite = try omitInk(ext: ext, root: root)
            if rewrite.reason == "overlap" {
                throw OfficeInkOmissionError.packageUnresolvable(
                    reason: "\(part) nests one drawing candidate inside another")
            }
            // EVERY visited part contributes to the receipt, changed or not,
            // so `keptDrawingShapes` reflects all candidates the copy
            // carries even when nothing was omitted.
            partFacts.append((part, rewrite.omitted, rewrite.kept))
            if rewrite.omitted > 0 {
                replacements[part] = Data(rewrite.xml.utf8)
            }
        }
        return try commit(package: package,
                          ext: ext,
                          replacements: replacements,
                          partFacts: partFacts,
                          sourceURL: sourceURL,
                          destinationURL: destinationURL,
                          sourceSHA: sourceSHA)
    }

    // MARK: - Per-part rewrite

    struct PartRewrite {
        var xml: String
        var omitted: Int
        var kept: Int
        var reason: String?
    }

    /// Removes proven-ink candidates from the parsed tree and re-serializes
    /// canonically (bounded tree serializer: real quoting, sorted attributes).
    /// The XML declaration and the root element are preserved; only the
    /// intentional candidate removals change the tree.
    static func omitInk(ext: String, root: OfficeXMLNode) throws -> PartRewrite {
        // The original serialization is reconstructed from this same tree
        // when nothing is omitted, so callers can compare members exactly.
        let originalXML = root.xml
        guard let candidates = try OfficeInkShape.drawingCandidates(ext: ext, root: root) else {
            return PartRewrite(xml: originalXML, omitted: 0, kept: 0, reason: nil)
        }
        let ink = candidates.filter { OfficeInkShape.isInkNode($0) }
        let kept = candidates.count - ink.count
        guard !ink.isEmpty else {
            return PartRewrite(xml: originalXML, omitted: 0, kept: kept, reason: nil)
        }
        // pptx `p:sp` candidates can be siblings inside a group; docx
        // candidates are mutually exclusive by construction; xlsx anchors are
        // siblings. Refuse if any removal is nested inside another removal.
        for outer in ink {
            for inner in ink where inner !== outer {
                if containsNode(outer, inner) {
                    return PartRewrite(xml: originalXML, omitted: 0, kept: kept, reason: "overlap")
                }
            }
        }
        let removals = Set<ObjectIdentifier>(ink.map { ObjectIdentifier($0) })
        prune(root, removals: removals)
        // Keep the source's XML declaration verbatim; serialize from the root.
        let declaration = xmlDeclaration(of: originalXML)
        return PartRewrite(xml: declaration + root.xml, omitted: ink.count, kept: kept, reason: nil)
    }

    private static func containsNode(_ root: OfficeXMLNode, _ target: OfficeXMLNode) -> Bool {
        if target === root { return true }
        for child in root.children where containsNode(child, target) { return true }
        return false
    }

    private static func prune(_ node: OfficeXMLNode, removals: Set<ObjectIdentifier>) {
        node.content.removeAll { item in
            if case .node(let child) = item { return removals.contains(ObjectIdentifier(child)) }
            return false
        }
        for child in node.children { prune(child, removals: removals) }
    }

    private static func xmlDeclaration(of xml: String) -> String {
        guard xml.hasPrefix("<?xml") else { return "" }
        guard let end = xml.range(of: "?>") else { return "" }
        return String(xml[..<end.upperBound])
    }

    // MARK: - Commit + verify

    private static func commit(package: OfficeArchive,
                               ext: String,
                               replacements: [String: Data],
                               partFacts: [(part: String, omitted: Int, kept: Int)],
                               sourceURL: URL,
                               destinationURL: URL,
                               sourceSHA: String) throws -> OfficeInkOmissionOutcome {
        let expectedOmitted = partFacts.reduce(0) { $0 + $1.omitted }
        let expectedKept = partFacts.reduce(0) { $0 + $1.kept }
        // Receipt: only parts whose bytes were intentionally rewritten are
        // "changed"; every visited part still contributes to the counts.
        let changedParts = partFacts.filter { $0.omitted > 0 }.map(\.part)
        try package.writeCopy(
            to: destinationURL,
            replacements: replacements,
            maximumMemberBytes: maximumMemberBytes,
            maximumTotalBytes: maximumTotalBytes,
            verify: { staged in
                let reopened = try OfficeArchive(url: staged, maximumEntries: maximumEntries)
                guard Set(reopened.paths) == Set(package.paths) else {
                    throw OfficeInkOmissionError.verificationFailed(
                        reason: "the copy's member list differs from the source")
                }
                // Every member that was not intentionally rewritten must be
                // byte-identical: media, charts, styles, relationships, theme,
                // docProps and all untouched text parts.
                for path in package.paths where replacements[path] == nil {
                    let original = try package.data(path: path, limit: maximumMemberBytes)
                    let copied = try reopened.data(path: path, limit: maximumMemberBytes)
                    guard original == copied else {
                        throw OfficeInkOmissionError.verificationFailed(
                            reason: "unrelated member \(path) changed")
                    }
                }
                for fact in partFacts {
                    let rewritten = try reopened.xml(path: fact.part, limit: maximumXMLBytes)
                    let residual = try OfficeInkShape.countInkStrokes(in: rewritten,
                                                                      formatExtension: ext)
                    if residual != 0 {
                        throw OfficeInkOmissionError.verificationFailed(
                            reason: "\(fact.part) still declares \(residual) ink drawings")
                    }
                }
                guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA else {
                    throw OfficeInkOmissionError.sourceChangedDuringOmission
                }
            })
        guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA else {
            throw OfficeInkOmissionError.sourceChangedDuringOmission
        }
        let copySHA = try FloeDigest.sha256Hex(ofFileAt: destinationURL)
        return OfficeInkOmissionOutcome(formatExtension: ext,
                                        omittedInkDrawings: expectedOmitted,
                                        keptDrawingShapes: expectedKept,
                                        changedParts: changedParts,
                                        sourceSHA256: sourceSHA,
                                        copySHA256: copySHA)
    }

    /// Only the qualified drawing members of the three saved formats.
    static func inkPartPaths(ext: String, in paths: [String]) -> [String] {
        switch ext {
        case "xlsx":
            return paths.filter { path in
                guard path.hasPrefix("xl/drawings/"), path.hasSuffix(".xml"),
                      !path.contains("/_rels/") else { return false }
                let name = (path as NSString).lastPathComponent
                return name.hasPrefix("drawing")
            }.sorted()
        case "docx":
            return paths.filter { path in
                guard path.hasPrefix("word/"), path.hasSuffix(".xml"),
                      !path.contains("/_rels/") else { return false }
                let name = (path as NSString).lastPathComponent
                return name == "document.xml"
                    || name == "footnotes.xml" || name == "endnotes.xml"
                    || (name.hasPrefix("header") && name != "headerFooter.xml")
                    || name.hasPrefix("footer")
            }.sorted()
        case "pptx":
            return paths.filter { path in
                guard path.hasPrefix("ppt/slides/slide"), path.hasSuffix(".xml"),
                      !path.contains("/_rels/") else { return false }
                let name = (path as NSString).lastPathComponent
                let stem = (name as NSString).deletingPathExtension
                return stem.count > 5 && stem.hasPrefix("slide")
                    && stem.dropFirst(5).allSatisfy(\.isNumber)
            }.sorted()
        default:
            return []
        }
    }
}

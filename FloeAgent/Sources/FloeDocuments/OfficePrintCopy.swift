// SPDX-License-Identifier: MPL-2.0
// FloeDocuments — XLSX print-copy preparation for user PDF export.
//
// `OfficePrintCopy` turns a pure `OfficePDFPrintPlan` into a private,
// task-owned workbook copy whose own print members are exactly what the
// engine will print. The source package is only read: its digest is verified
// before and after the copy, and every member that is not a declared
// replacement streams through the proven `OfficeArchive.writeCopy`
// byte-preserving path. The copy is not the Notes resource and not the live
// editor's working copy.
//
// Semantics (settled for build 283; extended for the build 285 preview round):
//  * `.documentSettings` keeps the workbook's own sheet set, print areas,
//    print titles, visibility and tab order. It only writes page-setup
//    overrides the caller explicitly chose.
//  * `.sheet(name:range:nil)` makes exactly that tab visible/active,
//    suppresses the other tabs in the copy, removes print areas so the
//    engine's full content (including ink outside nonempty cells) prints,
//    and PRESERVES genuine print titles.
//  * `.sheet(name:range:)` additionally writes exactly one scoped
//    `_xlnm.Print_Area` for the canonical range and removes print titles so
//    an out-of-range repeating header is never silently added.
//  * `.sheetWithPrintArea(name)` suppresses the other tabs like `.sheet` but
//    rewrites the target tab's own saved `_xlnm.Print_Area` verbatim after
//    clearing; when the sheet declares no area of its own, the copy declares
//    none either (full content), never another sheet's area. Print titles
//    are preserved.
//  * `.sheets(names:)` keeps exactly the chosen tabs visible/active (an
//    explicitly selected hidden tab is made visible inside the copy), hides
//    every other previously-visible tab, clears print areas so each printed
//    tab emits its full content, and preserves print titles.
//  * `.allVisibleSheets` keeps every visible sheet visible, keeps hidden
//    sheets hidden, removes print areas so each visible sheet prints its full
//    content, and preserves print titles.
//
// Cell ranges use the native Excel bounds (XFD1048576), never the assistant
// PNG region limits (32 columns / 160 rows / 2400 cells). The range is
// validated and reported exactly; it is never clamped.
//
// Page setup is written as valid SpreadsheetML: `sheetPr/pageSetUpPr`
// `fitToPage` AND `pageSetup` `scale`/`fitToWidth`/`fitToHeight` are kept
// consistent, paper/orientation use the ECMA-376 codes, and margin presets
// write all six physical-inch attributes. An exact scale writes
// `fitToPage="0"` + `scale=<percent>` with no fit attributes; a fit-to-pages
// budget writes `fitToPage="1"` + `fitToWidth=<w>` + `fitToHeight=<h>` with
// no stale `scale`. Printed gridlines are a separate explicit choice: an
// on/off decision writes only the `printOptions@gridLines` member of the
// private copy (creating the element in schema order — after `hyperlinks`,
// before `pageMargins` — or updating it in place while every other declared
// attribute such as `headings`/`horizontalCentered`/`verticalCentered`
// survives unchanged and is verified); per ECMA-376 gridlines print only
// when `gridLines` AND `gridLinesSet` are both true, so an explicit "on"
// also coerces a saved `gridLinesSet="false"`, and an explicit "off" never
// needs more than `gridLines="0"`. A nil choice keeps the worksheet's own
// printOptions byte-identical (Excel's shipped default prints NO gridlines
// regardless of the screen display). Cell borders and the source package are
// never touched. Every unrelated package member — drawings, media,
// styles, relationships, theme, custom properties — is compared byte-for-byte
// before the copy is committed.

import Foundation
import FloeCore

public enum OfficePrintCopyError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case destinationIsSource
    case staleSource
    case sourceChangedDuringCopy
    case unknownSheet(requested: String, available: [String])
    case noVisibleSheets
    case invalidRange(requested: String, example: String)
    case rangeOutsideWorksheetBounds(requested: String, maximumColumn: Int, maximumRow: Int)
    case packageUnresolvable(reason: String)
    case verificationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "PDF print copies are prepared for .xlsx workbooks only (requested .\(ext))."
        case .destinationIsSource:
            "The print copy must be written to a different, task-owned path; the source is never a destination."
        case .staleSource:
            "The workbook changed since it was read; the print copy was refused and the source is untouched."
        case .sourceChangedDuringCopy:
            "The source workbook changed while the print copy was being prepared; nothing was committed."
        case .unknownSheet(let requested, let available):
            "No worksheet named \(requested) exists in the workbook. Available sheets (tab order): \(available.joined(separator: ", "))."
        case .noVisibleSheets:
            "The workbook has no visible worksheet to print."
        case .invalidRange(let requested, let example):
            "Cell range \(requested) is not a canonical rectangular reference; use a form like \(example)."
        case .rangeOutsideWorksheetBounds(let requested, let maximumColumn, let maximumRow):
            "Cell range \(requested) is outside the worksheet bounds (columns 1…\(maximumColumn), rows 1…\(maximumRow))."
        case .packageUnresolvable(let reason):
            "The workbook's own sheet relationships or XML structure cannot be resolved safely (\(reason))."
        case .verificationFailed(let reason):
            "The prepared print copy failed verification (\(reason)); nothing was committed."
        }
    }
}

/// What the copy actually declares. Every field is read from or verified
/// against the staged copy; none of them is a restatement of the request.
public struct OfficePrintCopyPlan: Codable, Sendable, Equatable {
    public var scope: OfficePDFScope
    /// Sheets whose pages the engine can print from the copy, in tab order.
    public var printedSheetNames: [String]
    /// Sheets the copy leaves hidden or very hidden.
    public var suppressedSheetNames: [String]
    public var targetSheetName: String?
    public var targetSheetIndex: Int?
    public var targetSheetPart: String?
    /// The exact `_xlnm.Print_Area` content written into the copy, or `nil`
    /// when the copy declares no print area (full-content modes).
    public var printAreaReference: String?
    /// True only for `.sheetWithPrintArea` when the copy carries the target
    /// sheet's own saved print area (re-emitted verbatim). A written
    /// requested cell range is never reported as preserved.
    public var preservedDocumentPrintArea: Bool = false
    public var removedPrintAreas: Int
    public var removedPrintTitles: Int
    public var preservedPrintAreas: Int
    public var preservedPrintTitles: Int
    /// Only fields the caller actually chose are non-nil; a nil field means
    /// the source worksheet's own value was preserved.
    public var appliedPageSetup: OfficePDFPageSetup
    public var pageSetupSheetParts: [String]
    public var changedSheetParts: [String]
    public var drawingPartPaths: [String]
    /// True after every non-replaced member has been compared byte-for-byte
    /// with the source (true when the package has no drawings).
    public var drawingPartsPreserved: Bool
    public var madeTargetVisible: Bool
    public var setActiveTab: Bool
    public var sourceSHA256: String
    public var copySHA256: String
    public var packageEntries: Int
}

public enum OfficePrintCopy {
    private static let maximumEntries = 4_096
    private static let maximumXMLBytes: UInt32 = 8 * 1_024 * 1_024
    private static let maximumMemberBytes: UInt32 = 64 * 1_024 * 1_024
    private static let maximumTotalBytes = 256 * 1_024 * 1_024

    /// Prepares the private print copy at `destinationURL` and returns the
    /// actual sheet/scope/setup it declares.
    ///
    /// - Parameters:
    ///   - sourceURL: the saved `.xlsx` package; never written.
    ///   - destinationURL: a caller-owned path different from the source.
    ///   - expectedSHA256: when supplied, the source must still match it.
    ///   - plan: the pure export plan; `validate(for: .xlsx)` is enforced.
    public static func prepare(sourceURL: URL,
                               destinationURL: URL,
                               expectedSHA256: String? = nil,
                               plan: OfficePDFPrintPlan) throws -> OfficePrintCopyPlan {
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else {
            throw OfficePrintCopyError.destinationIsSource
        }
        guard sourceURL.pathExtension.lowercased() == "xlsx" else {
            throw OfficePrintCopyError.unsupportedFormat(sourceURL.pathExtension)
        }
        try plan.validate(for: .xlsx)

        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: sourceURL)
        if let expectedSHA256, sourceSHA != expectedSHA256.lowercased() {
            throw OfficePrintCopyError.staleSource
        }
        let sheets = try OfficeRegionExport.workbookSheets(sourceURL: sourceURL,
                                                           expectedSHA256: sourceSHA)
        guard sheets.contains(where: \.isVisible) else {
            throw OfficePrintCopyError.noVisibleSheets
        }

        let package = try OfficeArchive(url: sourceURL, maximumEntries: maximumEntries)
        guard package.paths.contains("xl/workbook.xml"),
              package.paths.contains("xl/_rels/workbook.xml.rels") else {
            throw OfficePrintCopyError.packageUnresolvable(
                reason: "the workbook or its relationships part is missing")
        }
        let workbookXML = try package.xml(path: "xl/workbook.xml", limit: maximumXMLBytes)

        let rewrite: WorkbookRewrite
        let target: OfficeRegionWorkbookSheet?
        let selectedTargets: [OfficeRegionWorkbookSheet]
        switch plan.scope {
        case .documentSettings:
            target = nil
            selectedTargets = []
            rewrite = try rewriteDocumentSettings(workbookXML, sheets: sheets)
        case .sheet(let name, let cellRange):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let selected = sheets.first(where: { $0.name == trimmed }) else {
                throw OfficePrintCopyError.unknownSheet(requested: trimmed,
                                                        available: sheets.map(\.name))
            }
            target = selected
            selectedTargets = []
            rewrite = try rewriteSingleSheet(workbookXML, sheets: sheets,
                                             target: selected, cellRange: cellRange)
        case .sheetWithPrintArea(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let selected = sheets.first(where: { $0.name == trimmed }) else {
                throw OfficePrintCopyError.unknownSheet(requested: trimmed,
                                                        available: sheets.map(\.name))
            }
            target = selected
            selectedTargets = []
            rewrite = try rewritePrintAreaPreserving(workbookXML, sheets: sheets,
                                                     target: selected)
        case .sheets(let names):
            var resolved: [OfficeRegionWorkbookSheet] = []
            resolved.reserveCapacity(names.count)
            for raw in names {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let selected = sheets.first(where: { $0.name == trimmed }) else {
                    throw OfficePrintCopyError.unknownSheet(requested: trimmed,
                                                            available: sheets.map(\.name))
                }
                resolved.append(selected)
            }
            target = nil
            selectedTargets = resolved
            rewrite = try rewriteSelectedSheets(workbookXML, sheets: sheets,
                                                selected: resolved)
        case .allVisibleSheets:
            target = nil
            selectedTargets = []
            rewrite = try rewriteAllVisibleSheets(workbookXML, sheets: sheets)
        }

        let pageSetupParts: [String]
        switch plan.scope {
        case .documentSettings, .allVisibleSheets:
            pageSetupParts = sheets.filter(\.isVisible).map(\.partPath)
        case .sheet, .sheetWithPrintArea:
            pageSetupParts = target.map { [$0.partPath] } ?? []
        case .sheets:
            pageSetupParts = selectedTargets.map(\.partPath)
        }

        var replacements: [String: Data] = ["xl/workbook.xml": Data(rewrite.xml.utf8)]
        var expectations: [String: PageSetupExpectation] = [:]
        var changedParts: [String] = []
        if plan.pageSetup.hasOverrides {
            for part in pageSetupParts {
                let worksheet = try package.xml(path: part, limit: maximumXMLBytes)
                let applied = try applyPageSetup(plan.pageSetup, to: worksheet)
                guard let expectation = applied.expectation else { continue }
                replacements[part] = Data(applied.xml.utf8)
                expectations[part] = expectation
                changedParts.append(part)
            }
        }

        let drawingParts = package.paths.filter {
            $0.hasPrefix("xl/drawings/") && !$0.contains("/_rels/")
        }
        let expectedStates = rewrite.expectedStates
        let expectedActiveTab = rewrite.expectedActiveTab
        let expectedPrintArea = rewrite.expectedPrintArea
        let expectedPrintAreaCount = rewrite.expectedPrintAreaCount
        let expectedPrintTitleCount = rewrite.expectedPrintTitleCount
        let sheetNames = sheets.map(\.name)

        try package.writeCopy(
            to: destinationURL,
            replacements: replacements,
            maximumMemberBytes: maximumMemberBytes,
            maximumTotalBytes: maximumTotalBytes,
            verify: { staged in
                let reopened = try OfficeArchive(url: staged, maximumEntries: maximumEntries)
                guard Set(reopened.paths) == Set(package.paths) else {
                    throw OfficePrintCopyError.verificationFailed(
                        reason: "the copy's member list differs from the source")
                }
                // Every member that was not intentionally replaced must be
                // byte-identical: drawings, media, styles, relationships,
                // theme, custom properties and all other parts.
                for path in package.paths where replacements[path] == nil {
                    let original = try package.data(path: path, limit: maximumMemberBytes)
                    let copied = try reopened.data(path: path, limit: maximumMemberBytes)
                    guard original == copied else {
                        throw OfficePrintCopyError.verificationFailed(
                            reason: "unrelated member \(path) changed")
                    }
                }
                let copiedWorkbook = try reopened.xml(path: "xl/workbook.xml",
                                                      limit: maximumXMLBytes)
                try OfficePrintCopyVerify.workbook(
                    copiedWorkbook, sheetNames: sheetNames,
                    expectedStates: expectedStates,
                    expectedActiveTab: expectedActiveTab,
                    expectedPrintArea: expectedPrintArea,
                    expectedPrintAreaCount: expectedPrintAreaCount,
                    expectedPrintTitleCount: expectedPrintTitleCount)
                for (part, expectation) in expectations {
                    let worksheet = try reopened.xml(path: part, limit: maximumXMLBytes)
                    try OfficePrintCopyVerify.pageSetup(worksheet, expectation: expectation)
                }
                guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA else {
                    throw OfficePrintCopyError.sourceChangedDuringCopy
                }
            })

        guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA else {
            throw OfficePrintCopyError.sourceChangedDuringCopy
        }
        let copySHA = try FloeDigest.sha256Hex(ofFileAt: destinationURL)
        let snapshot = try OfficeDocumentService.inspect(url: destinationURL)
        guard snapshot.kind == .workbook,
              snapshot.sha256?.lowercased() == copySHA else {
            throw OfficePrintCopyError.verificationFailed(
                reason: "the committed copy did not reopen as a consistent workbook")
        }

        let printedNames: [String]
        let suppressedNames: [String]
        switch plan.scope {
        case .documentSettings, .allVisibleSheets:
            printedNames = sheets.filter(\.isVisible).map(\.name)
            suppressedNames = sheets.filter { !$0.isVisible }.map(\.name)
        case .sheet, .sheetWithPrintArea:
            printedNames = target.map { [$0.name] } ?? []
            suppressedNames = sheets.filter { $0.index != target?.index }.map(\.name)
        case .sheets:
            let selectedIndices = Set(selectedTargets.map(\.index))
            // Tab order, not the request's spelling order.
            printedNames = sheets.filter { selectedIndices.contains($0.index) }.map(\.name)
            suppressedNames = sheets.filter { !selectedIndices.contains($0.index) }.map(\.name)
        }

        return OfficePrintCopyPlan(
            scope: plan.scope,
            printedSheetNames: printedNames,
            suppressedSheetNames: suppressedNames,
            targetSheetName: target?.name,
            targetSheetIndex: target?.index,
            targetSheetPart: target?.partPath,
            printAreaReference: rewrite.expectedPrintArea,
            preservedDocumentPrintArea: {
                guard case .sheetWithPrintArea = plan.scope else { return false }
                return rewrite.expectedPrintArea != nil
            }(),
            removedPrintAreas: rewrite.removedPrintAreas,
            removedPrintTitles: rewrite.removedPrintTitles,
            preservedPrintAreas: rewrite.preservedPrintAreas,
            preservedPrintTitles: rewrite.preservedPrintTitles,
            appliedPageSetup: plan.pageSetup,
            pageSetupSheetParts: changedParts,
            changedSheetParts: changedParts,
            drawingPartPaths: drawingParts,
            drawingPartsPreserved: true,
            madeTargetVisible: rewrite.madeTargetVisible,
            setActiveTab: rewrite.setActiveTab,
            sourceSHA256: sourceSHA,
            copySHA256: copySHA,
            packageEntries: snapshot.packageEntries)
    }

    // MARK: - Workbook rewrites

    private struct WorkbookRewrite {
        var xml: String
        var expectedStates: [String]
        var expectedActiveTab: Int?
        var expectedPrintArea: String?
        var expectedPrintAreaCount: Int
        var expectedPrintTitleCount: Int
        var removedPrintAreas: Int
        var removedPrintTitles: Int
        var preservedPrintAreas: Int
        var preservedPrintTitles: Int
        var madeTargetVisible: Bool
        var setActiveTab: Bool
    }

    private static func rewriteDocumentSettings(_ xml: String,
                                                sheets: [OfficeRegionWorkbookSheet]) throws
        -> WorkbookRewrite {
        let counts = try definedNameCounts(xml)
        return WorkbookRewrite(
            xml: xml,
            expectedStates: sheets.map(\.visibility),
            expectedActiveTab: nil,
            expectedPrintArea: nil,
            expectedPrintAreaCount: counts.printAreas,
            expectedPrintTitleCount: counts.printTitles,
            removedPrintAreas: 0,
            removedPrintTitles: 0,
            preservedPrintAreas: counts.printAreas,
            preservedPrintTitles: counts.printTitles,
            madeTargetVisible: false,
            setActiveTab: false)
    }

    private static func rewriteSingleSheet(_ xml: String,
                                           sheets: [OfficeRegionWorkbookSheet],
                                           target: OfficeRegionWorkbookSheet,
                                           cellRange: String?) throws
        -> WorkbookRewrite {
        var parsedRange: OfficeRegionCellRange?
        if let cellRange {
            guard let range = OfficeRegionCellRange.parse(cellRange) else {
                throw OfficePrintCopyError.invalidRange(requested: cellRange, example: "A1:R37")
            }
            guard range.lastColumn <= OfficePDFWorksheetBounds.maximumColumn,
                  range.lastRow <= OfficePDFWorksheetBounds.maximumRow else {
                throw OfficePrintCopyError.rangeOutsideWorksheetBounds(
                    requested: cellRange,
                    maximumColumn: OfficePDFWorksheetBounds.maximumColumn,
                    maximumRow: OfficePDFWorksheetBounds.maximumRow)
            }
            parsedRange = range
        }

        var fixed = xml
        let sheetRanges = elementRanges(fixed, tag: "sheet")
        guard sheetRanges.count == sheets.count else {
            throw OfficePrintCopyError.packageUnresolvable(
                reason: "sheet element count (\(sheetRanges.count)) does not match the resolved tab list (\(sheets.count))")
        }
        var madeTargetVisible = false
        for position in stride(from: sheetRanges.count - 1, through: 0, by: -1) {
            let range = sheetRanges[position]
            var element = String(fixed[range])
            let state = attribute("state", inOpeningElement: element)
            if position == target.index {
                if let state, state != "visible" {
                    madeTargetVisible = true
                    element = removeAttribute(element, name: "state")
                    fixed.replaceSubrange(range, with: element)
                }
            } else {
                let visibility = state ?? "visible"
                if visibility != "hidden", visibility != "veryHidden" {
                    element = setAttribute(element, name: "state", value: "hidden")
                    fixed.replaceSubrange(range, with: element)
                }
            }
        }

        let activeTab = setActiveTab(fixed, index: target.index)
        fixed = activeTab.xml

        let printArea = parsedRange.map {
            OfficeRegionExport.quoteSheetName(target.name) + "!" + $0.absoluteReference
        }
        let names = try rewriteDefinedNames(fixed,
                                            printAreaReference: printArea,
                                            printAreaSheetIndex: target.index,
                                            removePrintAreas: true,
                                            removePrintTitles: parsedRange != nil)
        fixed = names.xml

        var expectedStates = sheets.map(\.visibility)
        expectedStates[target.index] = "visible"
        for position in expectedStates.indices where position != target.index {
            if expectedStates[position] == "visible" {
                expectedStates[position] = "hidden"
            }
        }

        return WorkbookRewrite(
            xml: fixed,
            expectedStates: expectedStates,
            expectedActiveTab: target.index,
            expectedPrintArea: printArea,
            expectedPrintAreaCount: printArea == nil ? 0 : 1,
            expectedPrintTitleCount: parsedRange == nil ? names.preservedPrintTitles : 0,
            removedPrintAreas: names.removedPrintAreas,
            removedPrintTitles: names.removedPrintTitles,
            preservedPrintAreas: names.preservedPrintAreas,
            preservedPrintTitles: names.preservedPrintTitles,
            madeTargetVisible: madeTargetVisible,
            setActiveTab: activeTab.changed)
    }

    /// Keeps exactly the chosen tabs printable: every selected tab is visible
    /// (an explicitly selected hidden tab is made visible inside the copy —
    /// the user asked for it by name), every other previously-visible tab is
    /// hidden, the first selected tab in tab order becomes the active tab,
    /// print areas are cleared so each printed tab emits its full content,
    /// and genuine print titles are preserved.
    private static func rewriteSelectedSheets(_ xml: String,
                                              sheets: [OfficeRegionWorkbookSheet],
                                              selected: [OfficeRegionWorkbookSheet]) throws
        -> WorkbookRewrite {
        let selectedIndices = Set(selected.map(\.index))
        var fixed = xml
        let sheetRanges = elementRanges(fixed, tag: "sheet")
        guard sheetRanges.count == sheets.count else {
            throw OfficePrintCopyError.packageUnresolvable(
                reason: "sheet element count (\(sheetRanges.count)) does not match the resolved tab list (\(sheets.count))")
        }
        var madeTargetVisible = false
        for position in stride(from: sheetRanges.count - 1, through: 0, by: -1) {
            let range = sheetRanges[position]
            var element = String(fixed[range])
            let state = attribute("state", inOpeningElement: element)
            if selectedIndices.contains(position) {
                if let state, state != "visible" {
                    madeTargetVisible = true
                    element = removeAttribute(element, name: "state")
                    fixed.replaceSubrange(range, with: element)
                }
            } else {
                let visibility = state ?? "visible"
                if visibility != "hidden", visibility != "veryHidden" {
                    element = setAttribute(element, name: "state", value: "hidden")
                    fixed.replaceSubrange(range, with: element)
                }
            }
        }
        guard let firstSelected = selectedIndices.min() else {
            throw OfficePrintCopyError.noVisibleSheets
        }
        let activeTab = setActiveTab(fixed, index: firstSelected)
        fixed = activeTab.xml
        let names = try rewriteDefinedNames(fixed,
                                            printAreaReference: nil,
                                            printAreaSheetIndex: nil,
                                            removePrintAreas: true,
                                            removePrintTitles: false)
        fixed = names.xml

        var expectedStates = sheets.map(\.visibility)
        for position in expectedStates.indices {
            if selectedIndices.contains(position) {
                expectedStates[position] = "visible"
            } else if expectedStates[position] == "visible" {
                expectedStates[position] = "hidden"
            }
        }

        return WorkbookRewrite(
            xml: fixed,
            expectedStates: expectedStates,
            expectedActiveTab: activeTab.changed ? firstSelected : nil,
            expectedPrintArea: nil,
            expectedPrintAreaCount: 0,
            expectedPrintTitleCount: names.preservedPrintTitles,
            removedPrintAreas: names.removedPrintAreas,
            removedPrintTitles: names.removedPrintTitles,
            preservedPrintAreas: names.preservedPrintAreas,
            preservedPrintTitles: names.preservedPrintTitles,
            madeTargetVisible: madeTargetVisible,
            setActiveTab: activeTab.changed)
    }

    /// Suppresses every other tab like the single-sheet rewrite, but instead
    /// of clearing the target's print area it re-emits the target tab's OWN
    /// saved scoped `_xlnm.Print_Area` verbatim after clearing the workbook.
    /// When the target declares no area, the copy declares none either and
    /// the sheet prints its full content — it never silently adopts another
    /// sheet's area. Print titles are preserved.
    private static func rewritePrintAreaPreserving(_ xml: String,
                                                   sheets: [OfficeRegionWorkbookSheet],
                                                   target: OfficeRegionWorkbookSheet) throws
        -> WorkbookRewrite {
        var preservedPrintArea: String?
        for range in elementRanges(xml, tag: "definedName") {
            let element = String(xml[range])
            let name = attribute("name", inOpeningElement: element) ?? ""
            let local = attribute("localSheetId", inOpeningElement: element)
            if name == "_xlnm.Print_Area", local == String(target.index) {
                let text = definedNameText(element)
                if !text.isEmpty { preservedPrintArea = text }
            }
        }

        var fixed = xml
        let sheetRanges = elementRanges(fixed, tag: "sheet")
        guard sheetRanges.count == sheets.count else {
            throw OfficePrintCopyError.packageUnresolvable(
                reason: "sheet element count (\(sheetRanges.count)) does not match the resolved tab list (\(sheets.count))")
        }
        var madeTargetVisible = false
        for position in stride(from: sheetRanges.count - 1, through: 0, by: -1) {
            let range = sheetRanges[position]
            var element = String(fixed[range])
            let state = attribute("state", inOpeningElement: element)
            if position == target.index {
                if let state, state != "visible" {
                    madeTargetVisible = true
                    element = removeAttribute(element, name: "state")
                    fixed.replaceSubrange(range, with: element)
                }
            } else {
                let visibility = state ?? "visible"
                if visibility != "hidden", visibility != "veryHidden" {
                    element = setAttribute(element, name: "state", value: "hidden")
                    fixed.replaceSubrange(range, with: element)
                }
            }
        }

        let activeTab = setActiveTab(fixed, index: target.index)
        fixed = activeTab.xml
        let names = try rewriteDefinedNames(fixed,
                                            printAreaReference: preservedPrintArea,
                                            printAreaSheetIndex: target.index,
                                            removePrintAreas: true,
                                            removePrintTitles: false)
        fixed = names.xml

        var expectedStates = sheets.map(\.visibility)
        expectedStates[target.index] = "visible"
        for position in expectedStates.indices where position != target.index {
            if expectedStates[position] == "visible" {
                expectedStates[position] = "hidden"
            }
        }

        return WorkbookRewrite(
            xml: fixed,
            expectedStates: expectedStates,
            expectedActiveTab: activeTab.changed ? target.index : nil,
            expectedPrintArea: preservedPrintArea,
            expectedPrintAreaCount: preservedPrintArea == nil ? 0 : 1,
            expectedPrintTitleCount: names.preservedPrintTitles,
            removedPrintAreas: names.removedPrintAreas,
            removedPrintTitles: names.removedPrintTitles,
            preservedPrintAreas: names.preservedPrintAreas,
            preservedPrintTitles: names.preservedPrintTitles,
            madeTargetVisible: madeTargetVisible,
            setActiveTab: activeTab.changed)
    }

    private static func rewriteAllVisibleSheets(_ xml: String,
                                                sheets: [OfficeRegionWorkbookSheet]) throws
        -> WorkbookRewrite {        let visible = sheets.filter(\.isVisible)
        guard let firstVisible = visible.first else {
            throw OfficePrintCopyError.noVisibleSheets
        }
        let names = try rewriteDefinedNames(xml,
                                            printAreaReference: nil,
                                            printAreaSheetIndex: nil,
                                            removePrintAreas: true,
                                            removePrintTitles: false)
        var fixed = names.xml

        var setActive = false
        let current = workbookViewActiveTab(fixed)
        let needsActiveChange: Bool
        if let current, sheets.indices.contains(current), sheets[current].isVisible {
            needsActiveChange = false
        } else {
            needsActiveChange = true
        }
        if needsActiveChange {
            let active = setActiveTab(fixed, index: firstVisible.index)
            fixed = active.xml
            setActive = active.changed
        }

        return WorkbookRewrite(
            xml: fixed,
            expectedStates: sheets.map(\.visibility),
            expectedActiveTab: setActive ? firstVisible.index : nil,
            expectedPrintArea: nil,
            expectedPrintAreaCount: 0,
            expectedPrintTitleCount: names.preservedPrintTitles,
            removedPrintAreas: names.removedPrintAreas,
            removedPrintTitles: names.removedPrintTitles,
            preservedPrintAreas: names.preservedPrintAreas,
            preservedPrintTitles: names.preservedPrintTitles,
            madeTargetVisible: false,
            setActiveTab: setActive)
    }

    /// The unescaped, trimmed element text of one `<definedName>` element.
    /// A self-closing element yields the empty string.
    private static func definedNameText(_ element: String) -> String {
        guard let openEnd = element.firstIndex(of: ">"),
              let closeStart = element.lastIndex(of: "<"),
              openEnd < closeStart else { return "" }
        return XMLText.unescape(String(element[element.index(after: openEnd)..<closeStart]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct DefinedNameCounts {
        var printAreas: Int
        var printTitles: Int
    }

    private static func definedNameCounts(_ xml: String) throws -> DefinedNameCounts {
        var areas = 0
        var titles = 0
        for range in elementRanges(xml, tag: "definedName") {
            let name = attribute("name", inOpeningElement: String(xml[range])) ?? ""
            if name == "_xlnm.Print_Area" { areas += 1 }
            if name == "_xlnm.Print_Titles" { titles += 1 }
        }
        return DefinedNameCounts(printAreas: areas, printTitles: titles)
    }

    private struct DefinedNamesRewrite {
        var xml: String
        var removedPrintAreas: Int
        var removedPrintTitles: Int
        var preservedPrintAreas: Int
        var preservedPrintTitles: Int
    }

    private static func rewriteDefinedNames(_ xml: String,
                                            printAreaReference: String?,
                                            printAreaSheetIndex: Int?,
                                            removePrintAreas: Bool,
                                            removePrintTitles: Bool) throws -> DefinedNamesRewrite {
        var fixed = xml
        var removedAreas = 0
        var removedTitles = 0
        var preservedAreas = 0
        var preservedTitles = 0
        for range in elementRanges(fixed, tag: "definedName").reversed() {
            let element = String(fixed[range])
            let name = attribute("name", inOpeningElement: element) ?? ""
            if name == "_xlnm.Print_Area" {
                if removePrintAreas {
                    fixed.replaceSubrange(range, with: "")
                    removedAreas += 1
                } else {
                    preservedAreas += 1
                }
            } else if name == "_xlnm.Print_Titles" {
                if removePrintTitles {
                    fixed.replaceSubrange(range, with: "")
                    removedTitles += 1
                } else {
                    preservedTitles += 1
                }
            }
        }
        if let printAreaReference {
            guard let printAreaSheetIndex else {
                throw OfficePrintCopyError.packageUnresolvable(
                    reason: "a print area needs a target worksheet index")
            }
            // Element text is re-escaped so a preserved area containing XML
            // entities re-emits its original bytes exactly; a generated
            // reference has no entities, so this is a no-op for that path.
            let entry = "<definedName name=\"_xlnm.Print_Area\" localSheetId=\"\(printAreaSheetIndex)\">\(XMLText.escape(printAreaReference))</definedName>"
            if let container = elementRanges(fixed, tag: "definedNames").first,
               let openEnd = fixed[container].firstIndex(of: ">") {
                fixed.insert(contentsOf: entry, at: fixed.index(after: openEnd))
            } else if let sheetsEnd = fixed.range(of: "</sheets>") {
                fixed.insert(contentsOf: "<definedNames>" + entry + "</definedNames>",
                             at: sheetsEnd.upperBound)
            } else {
                throw OfficePrintCopyError.packageUnresolvable(
                    reason: "workbook.xml has no </sheets> element to anchor defined names")
            }
        }
        return DefinedNamesRewrite(
            xml: fixed,
            removedPrintAreas: removedAreas,
            removedPrintTitles: removedTitles,
            preservedPrintAreas: preservedAreas,
            preservedPrintTitles: preservedTitles)
    }

    // MARK: - Active tab

    private static func workbookViewActiveTab(_ xml: String) -> Int? {
        guard let range = elementRanges(xml, tag: "workbookView").first else { return nil }
        return attribute("activeTab", inOpeningElement: String(xml[range])).flatMap(Int.init)
    }

    private static func setActiveTab(_ xml: String, index: Int) -> (xml: String, changed: Bool) {
        var fixed = xml
        if let range = elementRanges(fixed, tag: "workbookView").first {
            let element = String(fixed[range])
            if attribute("activeTab", inOpeningElement: element) == String(index) {
                return (fixed, false)
            }
            fixed.replaceSubrange(range, with: setAttribute(element, name: "activeTab",
                                                             value: String(index)))
            return (fixed, true)
        }
        if let views = elementRanges(fixed, tag: "bookViews").first,
           let openEnd = fixed[views].firstIndex(of: ">") {
            fixed.insert(contentsOf: "<workbookView activeTab=\"\(index)\"/>",
                         at: fixed.index(after: openEnd))
            return (fixed, true)
        }
        if let sheets = fixed.range(of: "<sheets") {
            fixed.insert(contentsOf: "<bookViews><workbookView activeTab=\"\(index)\"/></bookViews>",
                         at: sheets.lowerBound)
            return (fixed, true)
        }
        return (fixed, false)
    }

    // MARK: - Worksheet page setup

    struct PageSetupExpectation {
        var fitToPage: String?
        var paperSize: String?
        var orientation: String?
        var fitToWidth: String?
        var fitToHeight: String?
        var scale: String?
        var requiresScaleAbsent = false
        var requiresFitWidthAbsent = false
        var requiresFitHeightAbsent = false
        var margins: [String: String]?
        /// True when an explicit printed-gridlines choice forced the copy to
        /// carry a `printOptions` element with these exact declared values.
        var requiresPrintOptions = false
        var printGridLines: String?
        var printGridLinesSet: String?
        /// Other attributes the source element already declared; each must
        /// survive verbatim next to the gridlines change.
        var preservedPrintOptions: [String: String] = [:]
    }

    private static func applyPageSetup(_ setup: OfficePDFPageSetup,
                                       to worksheet: String) throws
        -> (xml: String, expectation: PageSetupExpectation?) {
        guard setup.hasOverrides else { return (worksheet, nil) }
        var xml = worksheet
        var expectation = PageSetupExpectation()

        // Exactly one scaling control may be set (plan validation enforces
        // this); the declared mode fixes `sheetPr/pageSetUpPr@fitToPage` so
        // `scale` and `fitToWidth/fitToHeight` never contradict each other.
        let fitToPageValue: String?
        if let fit = setup.fit {
            fitToPageValue = fit == .actualSize ? "0" : "1"
        } else if setup.scalePercent != nil {
            fitToPageValue = "0"
        } else if setup.fitPages != nil {
            fitToPageValue = "1"
        } else {
            fitToPageValue = nil
        }
        if let value = fitToPageValue {
            xml = try setSheetFitToPage(xml, value: value)
            expectation.fitToPage = value
        }

        if let margins = setup.margins, let values = margins.openXMLValues {
            let attributes = [
                ("left", values.left), ("right", values.right),
                ("top", values.top), ("bottom", values.bottom),
                ("header", values.header), ("footer", values.footer),
            ]
            xml = try setPageMargins(xml, attributes: attributes)
            expectation.margins = Dictionary(uniqueKeysWithValues: attributes)
        }

        if setup.paper != nil || setup.orientation != nil || setup.fit != nil
            || setup.scalePercent != nil || setup.fitPages != nil {
            xml = try updatePageSetup(xml, setup: setup, expectation: &expectation)
        }

        // Printed gridlines are the `printOptions` member, independent of the
        // `pageSetup` element: an explicit on/off writes only this attribute
        // into the copy, creating the element in schema order when the sheet
        // never declared one. A nil choice returned `hasOverrides == false`
        // for this member and never reaches a rewrite.
        if let printGridlines = setup.printGridlines {
            xml = applyPrintOptionsGridlines(xml,
                                             print: printGridlines,
                                             expectation: &expectation)
        }
        return (xml, expectation)
    }

    private static func setSheetFitToPage(_ worksheet: String, value: String) throws -> String {
        var fixed = worksheet
        if let range = elementRanges(fixed, tag: "sheetPr").first {
            var element = String(fixed[range])
            if let prRange = elementRanges(element, tag: "pageSetUpPr").first {
                let pr = setAttribute(String(element[prRange]), name: "fitToPage", value: value)
                element.replaceSubrange(prRange, with: pr)
            } else if element.hasSuffix("/>") {
                let head = String(element.dropLast(2))
                element = head + "><pageSetUpPr fitToPage=\"\(value)\"/></sheetPr>"
            } else if let openEnd = element.firstIndex(of: ">") {
                element.insert(contentsOf: "<pageSetUpPr fitToPage=\"\(value)\"/>",
                               at: element.index(after: openEnd))
            } else {
                throw OfficePrintCopyError.packageUnresolvable(
                    reason: "a sheetPr element has no opening tag end")
            }
            fixed.replaceSubrange(range, with: element)
            return fixed
        }
        guard let root = fixed.range(of: "<worksheet"),
              let openEnd = fixed.range(of: ">", range: root.upperBound..<fixed.endIndex) else {
            throw OfficePrintCopyError.packageUnresolvable(
                reason: "the worksheet part is missing its root element")
        }
        fixed.insert(contentsOf: "<sheetPr><pageSetUpPr fitToPage=\"\(value)\"/></sheetPr>",
                     at: openEnd.upperBound)
        return fixed
    }

    private static func setPageMargins(_ worksheet: String,
                                       attributes: [(String, String)]) throws -> String {
        var fixed = worksheet
        if let range = elementRanges(fixed, tag: "pageMargins").first {
            var element = String(fixed[range])
            for (name, value) in attributes {
                element = setAttribute(element, name: name, value: value)
            }
            fixed.replaceSubrange(range, with: element)
            return fixed
        }
        let element = "<pageMargins " + attributes.map {
            "\($0.0)=\"\(XMLText.escapeAttribute($0.1))\""
        }.joined(separator: " ") + "/>"
        fixed.insert(contentsOf: element, at: pageBlockInsertionIndex(in: fixed))
        return fixed
    }

    private static func updatePageSetup(_ worksheet: String,
                                        setup: OfficePDFPageSetup,
                                        expectation: inout PageSetupExpectation) throws -> String {
        var fixed = worksheet
        if let range = elementRanges(fixed, tag: "pageSetup").first {
            var element = String(fixed[range])
            if let paper = setup.paper {
                element = setAttribute(element, name: "paperSize",
                                       value: String(paper.openXMLPaperSize))
                expectation.paperSize = String(paper.openXMLPaperSize)
            }
            if let orientation = setup.orientation {
                element = setAttribute(element, name: "orientation",
                                       value: orientation.rawValue)
                expectation.orientation = orientation.rawValue
            }
            switch setup.fit {
            case .actualSize:
                element = setAttribute(element, name: "scale", value: "100")
                element = removeAttribute(element, name: "fitToWidth")
                element = removeAttribute(element, name: "fitToHeight")
                expectation.scale = "100"
                expectation.requiresFitWidthAbsent = true
                expectation.requiresFitHeightAbsent = true
            case .fitToWidth:
                element = setAttribute(element, name: "fitToWidth", value: "1")
                element = setAttribute(element, name: "fitToHeight", value: "0")
                element = removeAttribute(element, name: "scale")
                expectation.fitToWidth = "1"
                expectation.fitToHeight = "0"
                expectation.requiresScaleAbsent = true
            case .fitToOnePage:
                element = setAttribute(element, name: "fitToWidth", value: "1")
                element = setAttribute(element, name: "fitToHeight", value: "1")
                element = removeAttribute(element, name: "scale")
                expectation.fitToWidth = "1"
                expectation.fitToHeight = "1"
                expectation.requiresScaleAbsent = true
            case nil:
                break
            }
            // Exact-scale and fit-to-pages are the other two legal scaling
            // spellings; plan validation guarantees at most one scaling
            // control is set, so these branches never race `setup.fit`.
            if let scalePercent = setup.scalePercent {
                element = setAttribute(element, name: "scale", value: String(scalePercent))
                element = removeAttribute(element, name: "fitToWidth")
                element = removeAttribute(element, name: "fitToHeight")
                expectation.scale = String(scalePercent)
                expectation.requiresFitWidthAbsent = true
                expectation.requiresFitHeightAbsent = true
            }
            if let fitPages = setup.fitPages {
                element = setAttribute(element, name: "fitToWidth", value: String(fitPages.width))
                element = setAttribute(element, name: "fitToHeight", value: String(fitPages.height))
                element = removeAttribute(element, name: "scale")
                expectation.fitToWidth = String(fitPages.width)
                expectation.fitToHeight = String(fitPages.height)
                expectation.requiresScaleAbsent = true
            }
            fixed.replaceSubrange(range, with: element)
            return fixed
        }

        var attributes: [(String, String)] = []
        if let paper = setup.paper {
            attributes.append(("paperSize", String(paper.openXMLPaperSize)))
            expectation.paperSize = String(paper.openXMLPaperSize)
        }
        if let orientation = setup.orientation {
            attributes.append(("orientation", orientation.rawValue))
            expectation.orientation = orientation.rawValue
        }
        switch setup.fit {
        case .actualSize:
            attributes.append(("scale", "100"))
            expectation.scale = "100"
        case .fitToWidth:
            attributes.append(("fitToWidth", "1"))
            attributes.append(("fitToHeight", "0"))
            expectation.fitToWidth = "1"
            expectation.fitToHeight = "0"
        case .fitToOnePage:
            attributes.append(("fitToWidth", "1"))
            attributes.append(("fitToHeight", "1"))
            expectation.fitToWidth = "1"
            expectation.fitToHeight = "1"
        case nil:
            break
        }
        if let scalePercent = setup.scalePercent {
            attributes.append(("scale", String(scalePercent)))
            expectation.scale = String(scalePercent)
            expectation.requiresFitWidthAbsent = true
            expectation.requiresFitHeightAbsent = true
        }
        if let fitPages = setup.fitPages {
            attributes.append(("fitToWidth", String(fitPages.width)))
            attributes.append(("fitToHeight", String(fitPages.height)))
            expectation.fitToWidth = String(fitPages.width)
            expectation.fitToHeight = String(fitPages.height)
            expectation.requiresScaleAbsent = true
        }
        let element = "<pageSetup " + attributes.map {
            "\($0.0)=\"\(XMLText.escapeAttribute($0.1))\""
        }.joined(separator: " ") + "/>"
        let insertion: String.Index
        if let margins = elementRanges(fixed, tag: "pageMargins").first {
            insertion = margins.upperBound
        } else {
            insertion = pageBlockInsertionIndex(in: fixed)
        }
        fixed.insert(contentsOf: element, at: insertion)
        return fixed
    }

    /// Writes the explicit printed-gridlines choice into the private copy.
    /// Only `printOptions@gridLines` changes (plus `gridLinesSet` where an
    /// explicit "on" needs it); every other declared attribute of the source
    /// element — `headings`, `horizontalCentered`, `verticalCentered` — is
    /// recorded in the expectation and must survive verbatim. When the sheet
    /// never declared a `printOptions`, the element is created in schema
    /// order (after `hyperlinks`, before `pageMargins`/`pageSetup`). Cell
    /// borders and the source package are never touched by this writer.
    private static func applyPrintOptionsGridlines(_ worksheet: String,
                                                   print: Bool,
                                                   expectation: inout PageSetupExpectation) -> String {
        var fixed = worksheet
        let gridLines = print ? "1" : "0"
        expectation.requiresPrintOptions = true
        expectation.printGridLines = gridLines
        if let range = elementRanges(fixed, tag: "printOptions").first {
            var element = String(fixed[range])
            for name in ["headings", "horizontalCentered", "verticalCentered"] {
                if let value = attribute(name, inOpeningElement: element) {
                    expectation.preservedPrintOptions[name] = value
                }
            }
            let savedGridLinesSet = attribute("gridLinesSet", inOpeningElement: element)
            element = setAttribute(element, name: "gridLines", value: gridLines)
            if print, let savedGridLinesSet,
               savedGridLinesSet == "0" || savedGridLinesSet == "false" {
                // ECMA-376 prints gridlines only when `gridLines` AND
                // `gridLinesSet` are both true, so an explicit "on" has to
                // coerce a saved "false"; an explicit "off" is complete with
                // `gridLines="0"` alone and never needs to touch `gridLinesSet`.
                element = setAttribute(element, name: "gridLinesSet", value: "1")
                expectation.printGridLinesSet = "1"
            } else if let savedGridLinesSet {
                expectation.printGridLinesSet = savedGridLinesSet
            }
            fixed.replaceSubrange(range, with: element)
            return fixed
        }
        var attributes = ["gridLines=\"\(gridLines)\""]
        if print {
            // A created element states both members so "on" is self-contained
            // and never depends on a consumer's reading of the schema default.
            attributes.append("gridLinesSet=\"1\"")
            expectation.printGridLinesSet = "1"
        }
        let element = "<printOptions " + attributes.joined(separator: " ") + "/>"
        fixed.insert(contentsOf: element, at: printOptionsInsertionIndex(in: fixed))
        return fixed
    }

    /// The schema position of `printOptions`: before `pageMargins` and
    /// `pageSetup` when the sheet declares either, otherwise the page-block
    /// boundary (`headerFooter`/`rowBreaks`/`drawing`/… or the closing root).
    private static func printOptionsInsertionIndex(in worksheet: String) -> String.Index {
        let earlier = [
            elementRanges(worksheet, tag: "pageMargins").first?.lowerBound,
            elementRanges(worksheet, tag: "pageSetup").first?.lowerBound,
        ].compactMap { $0 }
        if let earliest = earlier.min() { return earliest }
        return pageBlockInsertionIndex(in: worksheet)
    }

    /// The first element after `pageSetup`/`pageMargins` in the worksheet
    /// schema order, or the closing root. Inserting here never places a page
    /// member after `drawing`, `legacyDrawing`, `tableParts` or `extLst`.
    private static func pageBlockInsertionIndex(in worksheet: String) -> String.Index {
        let laterTags = [
            "headerFooter", "rowBreaks", "colBreaks", "customProperties",
            "cellWatches", "ignoredErrors", "smartTags", "drawing",
            "legacyDrawing", "legacyDrawingHF", "picture", "oleObjects",
            "controls", "webPublishItems", "tableParts", "extLst",
        ]
        var best: String.Index?
        for tag in laterTags {
            if let found = worksheet.range(of: "<\(tag)"),
               best == nil || found.lowerBound < best! {
                best = found.lowerBound
            }
        }
        if let best { return best }
        if let close = worksheet.range(of: "</worksheet>") { return close.lowerBound }
        return worksheet.endIndex
    }

    // MARK: - XML splice helpers

    private static func elementRanges(_ source: String, tag: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = source.startIndex
        let opener = "<\(tag)"
        let closer = "</\(tag)>"
        while let candidate = source.range(of: opener, range: cursor..<source.endIndex) {
            let boundary = candidate.upperBound
            if boundary < source.endIndex {
                let scalar = source[boundary]
                guard scalar == ">" || scalar == "/" || scalar.isWhitespace else {
                    cursor = boundary
                    continue
                }
            }
            guard let openEnd = source[candidate.lowerBound...].firstIndex(of: ">") else { break }
            let openTagEnd = source.index(after: openEnd)
            if source[source.index(before: openEnd)] == "/" {
                ranges.append(candidate.lowerBound..<openTagEnd)
                cursor = openTagEnd
                continue
            }
            guard let close = source.range(of: closer, range: openTagEnd..<source.endIndex) else { break }
            ranges.append(candidate.lowerBound..<close.upperBound)
            cursor = close.upperBound
        }
        return ranges
    }

    private static func attribute(_ name: String, inOpeningElement element: String) -> String? {
        XMLText.attribute(name, inOpeningElement: element)
    }

    private static func setAttribute(_ element: String, name: String, value: String) -> String {
        guard let openEnd = element.firstIndex(of: ">") else { return element }
        let head = String(element[element.startIndex..<openEnd])
        let tail = String(element[openEnd...])
        if let existing = attributeRange(name, inOpening: head) {
            var fixed = head
            fixed.replaceSubrange(existing, with: "\(name)=\"\(XMLText.escapeAttribute(value))\"")
            return fixed + tail
        }
        let escaped = "\(name)=\"\(XMLText.escapeAttribute(value))\""
        if head.hasSuffix("/") {
            let base = String(head.dropLast())
            let separator = base.last == " " ? "" : " "
            return base + separator + escaped + "/" + tail
        }
        let separator = head.last == " " ? "" : " "
        return head + separator + escaped + tail
    }

    private static func removeAttribute(_ element: String, name: String) -> String {
        guard let openEnd = element.firstIndex(of: ">") else { return element }
        let head = String(element[element.startIndex..<openEnd])
        let tail = String(element[openEnd...])
        guard let existing = attributeRange(name, inOpening: head) else { return element }
        var fixed = head
        var remove = existing
        if remove.lowerBound > fixed.startIndex,
           fixed[fixed.index(before: remove.lowerBound)] == " " {
            remove = fixed.index(before: remove.lowerBound)..<remove.upperBound
        }
        fixed.replaceSubrange(remove, with: "")
        return fixed + tail
    }

    private static func attributeRange(_ name: String, inOpening opening: String) -> Range<String.Index>? {
        guard opening.first == "<" else { return nil }
        for quote in ["\"", "'"] {
            let marker = name + "=" + quote
            var search = opening.startIndex
            while let found = opening.range(of: marker, range: search..<opening.endIndex) {
                let boundaryOK = found.lowerBound == opening.index(after: opening.startIndex)
                    || opening[opening.index(before: found.lowerBound)] == " "
                    || opening[opening.index(before: found.lowerBound)] == "\t"
                    || opening[opening.index(before: found.lowerBound)] == "\n"
                if boundaryOK,
                   let valueEnd = opening.range(of: quote, range: found.upperBound..<opening.endIndex) {
                    return found.lowerBound..<valueEnd.upperBound
                }
                search = found.upperBound
            }
        }
        return nil
    }

    // MARK: - Verification

    fileprivate enum OfficePrintCopyVerify {
        static func workbook(_ xml: String,
                             sheetNames: [String],
                             expectedStates: [String],
                             expectedActiveTab: Int?,
                             expectedPrintArea: String?,
                             expectedPrintAreaCount: Int,
                             expectedPrintTitleCount: Int) throws {
            let ranges = elementRanges(xml, tag: "sheet")
            guard ranges.count == sheetNames.count else {
                throw OfficePrintCopyError.verificationFailed(reason: "sheet count changed")
            }
            var names: [String] = []
            var states: [String] = []
            for range in ranges {
                let element = String(xml[range])
                names.append(attribute("name", inOpeningElement: element) ?? "")
                states.append(attribute("state", inOpeningElement: element) ?? "visible")
            }
            guard names == sheetNames else {
                throw OfficePrintCopyError.verificationFailed(reason: "sheet identity or order changed")
            }
            guard states.count == expectedStates.count else {
                throw OfficePrintCopyError.verificationFailed(reason: "sheet visibility list is incomplete")
            }
            for (position, expected) in expectedStates.enumerated() {
                let actual = states[position]
                if expected == "visible" {
                    guard actual == "visible" else {
                        throw OfficePrintCopyError.verificationFailed(reason: "sheet \(names[position]) is not visible")
                    }
                } else if expected == "veryHidden" {
                    guard actual == "veryHidden" else {
                        throw OfficePrintCopyError.verificationFailed(reason: "sheet \(names[position]) did not stay very hidden")
                    }
                } else {
                    guard actual == "hidden" else {
                        throw OfficePrintCopyError.verificationFailed(reason: "sheet \(names[position]) did not stay hidden")
                    }
                }
            }
            if let expectedActiveTab {
                guard OfficePrintCopy.workbookViewActiveTab(xml) == expectedActiveTab else {
                    throw OfficePrintCopyError.verificationFailed(reason: "active tab was not set")
                }
            }
            var areas: [(String, String?)] = []
            var titles = 0
            for range in elementRanges(xml, tag: "definedName") {
                let element = String(xml[range])
                let name = attribute("name", inOpeningElement: element) ?? ""
                if name == "_xlnm.Print_Area" {
                    let content = elementText(element)
                    let local = attribute("localSheetId", inOpeningElement: element)
                    areas.append((content, local))
                } else if name == "_xlnm.Print_Titles" {
                    titles += 1
                }
            }
            guard areas.count == expectedPrintAreaCount else {
                throw OfficePrintCopyError.verificationFailed(
                    reason: "expected \(expectedPrintAreaCount) print area(s), found \(areas.count)")
            }
            if let expectedPrintArea {
                guard areas.count == 1, areas[0].0 == expectedPrintArea else {
                    throw OfficePrintCopyError.verificationFailed(reason: "print area differs from the plan")
                }
            }
            guard titles == expectedPrintTitleCount else {
                throw OfficePrintCopyError.verificationFailed(
                    reason: "expected \(expectedPrintTitleCount) print title(s), found \(titles)")
            }
        }

        static func pageSetup(_ xml: String, expectation: PageSetupExpectation) throws {
            if let expected = expectation.fitToPage {
                guard let sheetPr = elementRanges(xml, tag: "sheetPr").first else {
                    throw OfficePrintCopyError.verificationFailed(reason: "sheetPr is missing")
                }
                let sheetPrBlock = String(xml[sheetPr])
                guard let pr = elementRanges(sheetPrBlock, tag: "pageSetUpPr").first else {
                    throw OfficePrintCopyError.verificationFailed(reason: "pageSetUpPr is missing")
                }
                let value = attribute("fitToPage",
                                      inOpeningElement: String(sheetPrBlock[pr]))
                guard value == expected else {
                    throw OfficePrintCopyError.verificationFailed(reason: "fitToPage differs from the plan")
                }
            }
            let hasPageSetupExpectation = expectation.paperSize != nil
                || expectation.orientation != nil
                || expectation.fitToWidth != nil
                || expectation.fitToHeight != nil
                || expectation.scale != nil
            if hasPageSetupExpectation {
                guard let range = elementRanges(xml, tag: "pageSetup").first else {
                    throw OfficePrintCopyError.verificationFailed(reason: "pageSetup is missing")
                }
                let element = String(xml[range])
                if let expected = expectation.paperSize {
                    guard attribute("paperSize", inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(reason: "paper size differs from the plan")
                    }
                }
                if let expected = expectation.orientation {
                    guard attribute("orientation", inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(reason: "orientation differs from the plan")
                    }
                }
                if let expected = expectation.fitToWidth {
                    guard attribute("fitToWidth", inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(reason: "fitToWidth differs from the plan")
                    }
                }
                if let expected = expectation.fitToHeight {
                    guard attribute("fitToHeight", inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(reason: "fitToHeight differs from the plan")
                    }
                }
                if let expected = expectation.scale {
                    guard attribute("scale", inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(reason: "scale differs from the plan")
                    }
                }
                if expectation.requiresScaleAbsent,
                   attribute("scale", inOpeningElement: element) != nil {
                    throw OfficePrintCopyError.verificationFailed(reason: "a stale scale survived a fit override")
                }
                if expectation.requiresFitWidthAbsent,
                   attribute("fitToWidth", inOpeningElement: element) != nil {
                    throw OfficePrintCopyError.verificationFailed(reason: "a stale fitToWidth survived actual size")
                }
                if expectation.requiresFitHeightAbsent,
                   attribute("fitToHeight", inOpeningElement: element) != nil {
                    throw OfficePrintCopyError.verificationFailed(reason: "a stale fitToHeight survived actual size")
                }
            }
            if let margins = expectation.margins {
                guard let range = elementRanges(xml, tag: "pageMargins").first else {
                    throw OfficePrintCopyError.verificationFailed(reason: "pageMargins is missing")
                }
                let element = String(xml[range])
                for (name, expected) in margins {
                    guard attribute(name, inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(reason: "margin \(name) differs from the plan")
                    }
                }
            }
            if expectation.requiresPrintOptions {
                guard let range = elementRanges(xml, tag: "printOptions").first else {
                    throw OfficePrintCopyError.verificationFailed(reason: "printOptions is missing")
                }
                let element = String(xml[range])
                guard attribute("gridLines", inOpeningElement: element) == expectation.printGridLines else {
                    throw OfficePrintCopyError.verificationFailed(reason: "printed gridlines differ from the plan")
                }
                if let expected = expectation.printGridLinesSet,
                   attribute("gridLinesSet", inOpeningElement: element) != expected {
                    throw OfficePrintCopyError.verificationFailed(reason: "gridLinesSet differs from the plan")
                }
                for (name, expected) in expectation.preservedPrintOptions {
                    guard attribute(name, inOpeningElement: element) == expected else {
                        throw OfficePrintCopyError.verificationFailed(
                            reason: "print option \(name) was lost by the gridlines write")
                    }
                }
            }
        }

        private static func elementText(_ element: String) -> String {
            guard let openEnd = element.firstIndex(of: ">"),
                  let closeStart = element.lastIndex(of: "<"),
                  openEnd < closeStart else { return "" }
            return XMLText.unescape(String(element[element.index(after: openEnd)..<closeStart]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func elementRanges(_ source: String, tag: String) -> [Range<String.Index>] {
            var ranges: [Range<String.Index>] = []
            var cursor = source.startIndex
            let opener = "<\(tag)"
            let closer = "</\(tag)>"
            while let candidate = source.range(of: opener, range: cursor..<source.endIndex) {
                let boundary = candidate.upperBound
                if boundary < source.endIndex {
                    let scalar = source[boundary]
                    guard scalar == ">" || scalar == "/" || scalar.isWhitespace else {
                        cursor = boundary
                        continue
                    }
                }
                guard let openEnd = source[candidate.lowerBound...].firstIndex(of: ">") else { break }
                let openTagEnd = source.index(after: openEnd)
                if source[source.index(before: openEnd)] == "/" {
                    ranges.append(candidate.lowerBound..<openTagEnd)
                    cursor = openTagEnd
                    continue
                }
                guard let close = source.range(of: closer, range: openTagEnd..<source.endIndex) else { break }
                ranges.append(candidate.lowerBound..<close.upperBound)
                cursor = close.upperBound
            }
            return ranges
        }

        private static func attribute(_ name: String, inOpeningElement element: String) -> String? {
            XMLText.attribute(name, inOpeningElement: element)
        }
    }
}

// SPDX-License-Identifier: MPL-2.0
// FloeDocuments — bounded Office region export-copy preparation.
//
// The Notes assistant region reader needs one honest primitive for
// workbooks: given an immutable saved CAS resource, produce a task-owned
// disposable XLSX COPY in which exactly one worksheet carries a valid
// `_xlnm.Print_Area` for a bounded canonical cell range, `fitToPage` is set,
// the target is visible/active, and every other sheet is suppressed — so an
// actual engine PDF export renders only the requested region. The source
// package is never modified: its digest is verified before AND after the
// copy. Every non-replaced archive member (formulas, drawings/ink, media,
// relationships) streams through the proven `OfficeArchive.writeCopy`
// byte-preserving path, and the staged copy is reopened and XML-verified
// before the destination is committed.
//
// Scope of the first shipping surface (build 283): explicit sheet identity
// (workbook tab name or 0-based workbook-order index) plus a canonical
// bounded cell range. No arbitrary Calc twips ABI, no live viewport use, and
// no per-cell pixel geometry is claimed: the plan records what the copy
// declares so the reader maps region → actual PDF page(s) from the real
// export.

import Foundation
import FloeCore

public enum OfficeRegionExportError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case staleSource
    case sourceChangedDuringCopy
    case unknownSheet(requested: String, available: [String])
    case sheetIndexOutOfRange(index: Int, sheetCount: Int)
    case invalidRange(requested: String, example: String)
    case oversizedRange(columns: Int, rows: Int, cells: Int,
                        maximumColumns: Int, maximumRows: Int, maximumCells: Int)
    case packageUnresolvable(reason: String)
    case destinationIsSource

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "Office region export copies are prepared for .xlsx workbooks only (requested .\(ext))."
        case .staleSource:
            "The workbook package changed since it was read; the export copy was refused and the source is untouched."
        case .sourceChangedDuringCopy:
            "The source workbook changed while the export copy was being prepared; nothing was committed."
        case .unknownSheet(let requested, let available):
            "No worksheet named \(requested) exists in the workbook. Available sheets (tab order): \(available.joined(separator: ", "))."
        case .sheetIndexOutOfRange(let index, let sheetCount):
            "Sheet index \(index) is outside the workbook's \(sheetCount) sheet(s) (valid indices: 0…\(max(0, sheetCount - 1)))."
        case .invalidRange(let requested, let example):
            "Cell range \(requested) is not a canonical rectangular reference; use an example like \(example) (letters then digits, optional $ prefixes, at most one colon)."
        case .oversizedRange(let columns, let rows, let cells,
                             let maximumColumns, let maximumRows, let maximumCells):
            "The requested region is too large to render in one honest pass (\(columns) columns × \(rows) rows = \(cells) cells). "
                + "Keep it within \(maximumColumns) columns, \(maximumRows) rows and \(maximumCells) cells, or request adjacent sub-ranges as continuation."
        case .packageUnresolvable(let reason):
            "The workbook's own sheet relationships or XML structure cannot be resolved safely (\(reason)); no export copy was prepared and the source is untouched."
        case .destinationIsSource:
            "The export copy must be written to a different, task-owned path; the source is never a destination."
        }
    }
}

/// One worksheet as the workbook's own tab order declares it. `index` is the
/// workbook ordering, which is exactly what a `localSheetId` on a scoped
/// defined name refers to (not the `sheetN.xml` part number).
public struct OfficeRegionWorkbookSheet: Codable, Sendable, Equatable {
    public var index: Int
    public var name: String
    public var partPath: String
    /// `visible`, `hidden` or `veryHidden` — the workbook's own state.
    public var visibility: String

    public init(index: Int, name: String, partPath: String, visibility: String) {
        self.index = index
        self.name = name
        self.partPath = partPath
        self.visibility = visibility
    }

    public var isVisible: Bool { visibility == "visible" }
}

/// A canonical bounded rectangular cell range (1-based, inclusive), parsed
/// from the strict `A1:N30` form (optional `$` prefixes, case-insensitive).
public struct OfficeRegionCellRange: Codable, Sendable, Equatable {
    public var firstColumn: Int
    public var lastColumn: Int
    public var firstRow: Int
    public var lastRow: Int

    public init(firstColumn: Int, lastColumn: Int, firstRow: Int, lastRow: Int) {
        self.firstColumn = firstColumn
        self.lastColumn = lastColumn
        self.firstRow = firstRow
        self.lastRow = lastRow
    }

    public var columnCount: Int { lastColumn - firstColumn + 1 }
    public var rowCount: Int { lastRow - firstRow + 1 }
    public var cellCount: Int { columnCount * rowCount }

    /// Canonical `A1:N30` display form (no `$`).
    public var canonicalReference: String {
        Self.columnLetters(firstColumn) + String(firstRow)
            + ":" + Self.columnLetters(lastColumn) + String(lastRow)
    }

    /// The absolute form written into `_xlnm.Print_Area` (`$A$1:$N$30`).
    public var absoluteReference: String {
        "$" + Self.columnLetters(firstColumn) + "$" + String(firstRow)
            + ":$" + Self.columnLetters(lastColumn) + "$" + String(lastRow)
    }

    static func columnLetters(_ number: Int) -> String {
        var value = number
        var letters = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            letters = String(Character(UnicodeScalar(UInt8(65 + UInt8(remainder))))) + letters
            value = (value - 1) / 26
        }
        return letters.isEmpty ? "A" : letters
    }

    static func columnNumber(_ letters: String) -> Int? {
        var total = 0
        for scalar in letters.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            total = total * 26 + Int(scalar.value - 64)
        }
        return total > 0 ? total : nil
    }

    /// Strict canonical parse: one or two `\$?[A-Z]{1,3}\d{1,7}` corners.
    /// Ranges are normalized so the first corner is the top-left; a single
    /// cell (`B7`) is accepted and normalized to a 1×1 range.
    public static func parse(_ value: String) -> OfficeRegionCellRange? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 24 else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let first = parseCorner(String(parts[0])) else { return nil }
        let lastCorner = parts.count == 2 ? String(parts[1]) : String(parts[0])
        guard let last = parseCorner(lastCorner) else { return nil }
        return OfficeRegionCellRange(
            firstColumn: min(first.column, last.column),
            lastColumn: max(first.column, last.column),
            firstRow: min(first.row, last.row),
            lastRow: max(first.row, last.row))
    }

    private static func parseCorner(_ raw: String) -> (column: Int, row: Int)? {
        var text = Substring(raw)
        if text.first == "$" { text = text.dropFirst() }
        guard !text.isEmpty else { return nil }
        var letters = ""
        var digits = ""
        var sawRowDollar = false
        for scalar in text.unicodeScalars {
            if scalar.value >= 65, scalar.value <= 90 {
                if !digits.isEmpty || sawRowDollar { return nil }
                letters.unicodeScalars.append(scalar)
            } else if scalar.value >= 97, scalar.value <= 122 {
                if !digits.isEmpty || sawRowDollar { return nil }
                letters.unicodeScalars.append(UnicodeScalar(scalar.value - 32)!)
            } else if scalar.value == 36 {
                // Optional absolute-row marker: `$A$1` / `A$1`.
                guard !letters.isEmpty, digits.isEmpty, !sawRowDollar else { return nil }
                sawRowDollar = true
            } else if scalar.value >= 48, scalar.value <= 57 {
                digits.unicodeScalars.append(scalar)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty, letters.count <= 3, digits.count <= 7,
              let column = columnNumber(letters), let row = Int(digits), row >= 1 else { return nil }
        return (column, row)
    }
}

/// What the prepared export copy actually declares. The reader reports these
/// values verbatim; they are the truth of the temporary copy, never of the
/// source document (whose own print settings are unchanged).
public struct OfficeRegionPrintPlan: Codable, Sendable, Equatable {
    public var sheetIndex: Int
    public var sheetName: String
    public var sheetPartPath: String
    /// The exact `_xlnm.Print_Area` content written into the copy.
    public var printAreaReference: String
    /// Every other sheet the copy leaves suppressed (this includes sheets the
    /// source already hid; the copy never un-hides them).
    public var suppressedSheetNames: [String]
    /// Pre-existing scoped print areas removed from the copy.
    public var removedPrintAreas: Int
    /// Pre-existing `_xlnm.Print_Titles` entries removed from the copy so
    /// repeating headers are never mislabeled as part of the requested range.
    public var removedPrintTitles: Int
    /// True when the target sheet had to be made visible inside the copy.
    public var madeTargetVisible: Bool
    /// True when the copy's `activeTab` names the target sheet.
    public var setActiveTab: Bool
    public var sourceSHA256: String
    public var copySHA256: String
    public var packageEntries: Int
}

public enum OfficeRegionExport {
    /// Hard bounds for one honest region render. A rejected request names
    /// these limits so the assistant can split the region instead of
    /// silently losing content.
    public static let maximumRangeColumns = 32
    public static let maximumRangeRows = 160
    public static let maximumRangeCells = 2_400
    private static let maximumEntries = 4_096
    private static let maximumXMLBytes: UInt32 = 8 * 1024 * 1024
    private static let maximumMemberBytes: UInt32 = 64 * 1024 * 1024
    private static let maximumTotalBytes = 256 * 1024 * 1024

    /// Resolves the workbook's own sheets in tab order. A workbook whose
    /// sheet relationships do not resolve consistently is refused
    /// (`packageUnresolvable`) rather than guessed by part file name.
    public static func workbookSheets(sourceURL: URL, expectedSHA256: String? = nil) throws
        -> [OfficeRegionWorkbookSheet] {
        let snapshot = try OfficeDocumentService.inspect(url: sourceURL)
        guard snapshot.kind == .workbook else {
            throw OfficeRegionExportError.unsupportedFormat(snapshot.kind.rawValue)
        }
        if let expectedSHA256, snapshot.sha256?.lowercased() != expectedSHA256.lowercased() {
            throw OfficeRegionExportError.staleSource
        }
        guard let preview = snapshot.workbookPreview else {
            throw OfficeRegionExportError.packageUnresolvable(
                reason: "xl/workbook.xml sheet relationships do not resolve against the worksheet parts")
        }
        return preview.sheets.enumerated().map { position, sheet in
            OfficeRegionWorkbookSheet(index: position, name: sheet.name,
                                      partPath: sheet.target, visibility: sheet.visibility.rawValue)
        }
    }

    /// Prepares the private immutable print-area COPY at `destinationURL`.
    /// The caller owns a unique task directory; the source is read-only and
    /// its digest is re-verified after the copy is committed.
    public static func preparePrintAreaCopy(
        sourceURL: URL,
        destinationURL: URL,
        expectedSHA256: String? = nil,
        sheetIndex: Int?,
        sheetName: String?,
        cellRange: String
    ) throws -> (copyURL: URL, plan: OfficeRegionPrintPlan) {
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else {
            throw OfficeRegionExportError.destinationIsSource
        }
        guard sourceURL.pathExtension.lowercased() == "xlsx" else {
            throw OfficeRegionExportError.unsupportedFormat(sourceURL.pathExtension)
        }
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: sourceURL)
        if let expectedSHA256, sourceSHA != expectedSHA256.lowercased() {
            throw OfficeRegionExportError.staleSource
        }
        let sheets = try workbookSheets(sourceURL: sourceURL, expectedSHA256: expectedSHA256)
        let target = try selectSheet(from: sheets, index: sheetIndex, name: sheetName)
        guard let range = OfficeRegionCellRange.parse(cellRange) else {
            throw OfficeRegionExportError.invalidRange(requested: cellRange, example: "A1:N30")
        }
        guard range.columnCount <= maximumRangeColumns, range.rowCount <= maximumRangeRows,
              range.cellCount <= maximumRangeCells else {
            throw OfficeRegionExportError.oversizedRange(
                columns: range.columnCount, rows: range.rowCount, cells: range.cellCount,
                maximumColumns: maximumRangeColumns, maximumRows: maximumRangeRows,
                maximumCells: maximumRangeCells)
        }

        let package = try OfficeArchive(url: sourceURL, maximumEntries: maximumEntries)
        guard package.paths.contains("xl/workbook.xml"),
              package.paths.contains("xl/_rels/workbook.xml.rels"),
              package.paths.contains(target.partPath) else {
            throw OfficeRegionExportError.packageUnresolvable(reason: "workbook, relationship or worksheet member is missing")
        }
        let workbookXML = try package.xml(path: "xl/workbook.xml", limit: maximumXMLBytes)
        let worksheetXML = try package.xml(path: target.partPath, limit: maximumXMLBytes)

        let printAreaReference = quoteSheetName(target.name) + "!" + range.absoluteReference

        // 1. Sheet visibility (copy-only): target visible, every other sheet
        // suppressed. Spliced right-to-left so earlier ranges stay valid.
        var fixedWorkbook = workbookXML
        let sheetElementRanges = elementRanges(fixedWorkbook, tag: "sheet")
        guard sheetElementRanges.count == sheets.count else {
            throw OfficeRegionExportError.packageUnresolvable(
                reason: "sheet element count (\(sheetElementRanges.count)) does not match the resolved tab list (\(sheets.count))")
        }
        let madeTargetVisible = sheets[target.index].visibility != "visible"
        for position in stride(from: sheetElementRanges.count - 1, through: 0, by: -1) {
            let elementRange = sheetElementRanges[position]
            var element = String(fixedWorkbook[elementRange])
            let state = attribute("state", inOpeningElement: element)
            if position == target.index {
                if let state, state != "visible" {
                    element = removeAttribute(element, name: "state")
                }
            } else {
                let visibility = state ?? "visible"
                if visibility != "hidden", visibility != "veryHidden" {
                    element = setAttribute(element, name: "state", value: "hidden")
                }
            }
            fixedWorkbook.replaceSubrange(elementRange, with: element)
        }

        // 2. activeTab → target index, so the copy opens on the rendered
        // sheet and the engine never prints with a hidden active sheet.
        var setActiveTab = false
        if let viewRange = elementRanges(fixedWorkbook, tag: "workbookView").first {
            let element = String(fixedWorkbook[viewRange])
            let fixed = setAttribute(element, name: "activeTab", value: String(target.index))
            fixedWorkbook.replaceSubrange(viewRange, with: fixed)
            setActiveTab = true
        }

        // 3. Defined names: remove every scoped `_xlnm.Print_Area` and every
        // `_xlnm.Print_Titles` from the copy, then add exactly the requested
        // area for the target sheet's workbook-order index.
        var removedPrintAreas = 0
        var removedPrintTitles = 0
        for entry in elementRanges(fixedWorkbook, tag: "definedName").reversed() {
            let element = String(fixedWorkbook[entry])
            let name = attribute("name", inOpeningElement: element) ?? ""
            if name == "_xlnm.Print_Area" {
                fixedWorkbook.replaceSubrange(entry, with: "")
                removedPrintAreas += 1
            } else if name == "_xlnm.Print_Titles" {
                fixedWorkbook.replaceSubrange(entry, with: "")
                removedPrintTitles += 1
            }
        }
        let newEntry = "<definedName name=\"_xlnm.Print_Area\" localSheetId=\"\(target.index)\">\(printAreaReference)</definedName>"
        if let open = fixedWorkbook.range(of: "<definedNames>"),
           let close = fixedWorkbook.range(of: "</definedNames>", range: open.upperBound..<fixedWorkbook.endIndex) {
            fixedWorkbook.insert(contentsOf: newEntry, at: open.upperBound)
            // If removing every print entry emptied the container, keep the
            // now-necessary container we just filled; nothing else to do.
            _ = close
        } else if let sheetsEnd = fixedWorkbook.range(of: "</sheets>") {
            fixedWorkbook.insert(contentsOf: "<definedNames>" + newEntry + "</definedNames>",
                                 at: sheetsEnd.upperBound)
        } else {
            throw OfficeRegionExportError.packageUnresolvable(reason: "workbook.xml has no </sheets> element to anchor defined names")
        }

        // 4. Worksheet copy: sheetPr/pageSetUpPr fitToPage and pageSetup
        // fitToWidth/fitToHeight = 1 (LibreOffice honors fitToPage for the
        // region→page scale).
        var fixedWorksheet = worksheetXML
        if let pageSetupRange = elementRanges(fixedWorksheet, tag: "pageSetup").first {
            var element = String(fixedWorksheet[pageSetupRange])
            element = setAttribute(element, name: "fitToWidth", value: "1")
            element = setAttribute(element, name: "fitToHeight", value: "1")
            element = removeAttribute(element, name: "scale")
            fixedWorksheet.replaceSubrange(pageSetupRange, with: element)
        } else {
            let pageSetup = "<pageSetup fitToWidth=\"1\" fitToHeight=\"1\"/>"
            if let margins = elementRanges(fixedWorksheet, tag: "pageMargins").first {
                fixedWorksheet.insert(contentsOf: pageSetup, at: margins.upperBound)
            } else if let footer = fixedWorksheet.range(of: "<headerFooter") {
                fixedWorksheet.insert(contentsOf: pageSetup, at: footer.lowerBound)
            } else if let root = fixedWorksheet.range(of: "</worksheet>") {
                fixedWorksheet.insert(contentsOf: pageSetup, at: root.lowerBound)
            } else {
                throw OfficeRegionExportError.packageUnresolvable(reason: "worksheet \(target.partPath) has no closed worksheet root")
            }
        }
        if let sheetPrRange = elementRanges(fixedWorksheet, tag: "sheetPr").first {
            let element = String(fixedWorksheet[sheetPrRange])
            if element.contains("<pageSetUpPr") {
                var fixedPr = element
                if let inner = elementRanges(fixedPr, tag: "pageSetUpPr").first {
                    var pr = String(fixedPr[inner])
                    pr = setAttribute(pr, name: "fitToPage", value: "1")
                    fixedPr.replaceSubrange(inner, with: pr)
                }
                fixedWorksheet.replaceSubrange(sheetPrRange, with: fixedPr)
            } else if element.hasSuffix("/>") {
                let head = String(element.dropLast(2))
                fixedWorksheet.replaceSubrange(sheetPrRange, with: head + "><pageSetUpPr fitToPage=\"1\"/></sheetPr>")
            } else if let openEnd = fixedWorksheet[sheetPrRange].firstIndex(of: ">") {
                fixedWorksheet.insert(contentsOf: "<pageSetUpPr fitToPage=\"1\"/>",
                                      at: fixedWorksheet[sheetPrRange].index(after: openEnd))
            }
        } else if let rootOpen = fixedWorksheet.range(of: "<worksheet"),
                  let rootEnd = fixedWorksheet.range(of: ">", range: rootOpen.upperBound..<fixedWorksheet.endIndex) {
            // sheetPr must be the first child of the worksheet root.
            fixedWorksheet.insert(contentsOf: "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr>",
                                  at: rootEnd.upperBound)
        } else {
            throw OfficeRegionExportError.packageUnresolvable(reason: "worksheet \(target.partPath) is missing its root element")
        }

        // 5. Commit the copy through the proven member-preserving writer,
        // with reopen + XML + source-digest verification INSIDE the staged
        // boundary (the destination is only replaced once verification ran).
        let expectedPrintArea = printAreaReference
        let targetIndex = target.index
        try package.writeCopy(
            to: destinationURL,
            replacements: [
                "xl/workbook.xml": Data(fixedWorkbook.utf8),
                target.partPath: Data(fixedWorksheet.utf8),
            ],
            maximumMemberBytes: maximumMemberBytes,
            maximumTotalBytes: maximumTotalBytes,
            verify: { staged in
                let reopened = try OfficeArchive(url: staged, maximumEntries: maximumEntries)
                let reopenedWorkbook = try reopened.xml(path: "xl/workbook.xml", limit: maximumXMLBytes)
                guard reopenedWorkbook.contains(expectedPrintArea) else {
                    throw OfficeDocumentError.verificationFailed
                }
                let elements = elementRanges(reopenedWorkbook, tag: "sheet")
                let names = elements.map { attribute("name", inOpeningElement: String(reopenedWorkbook[$0])) ?? "" }
                let states = elements.map { attribute("state", inOpeningElement: String(reopenedWorkbook[$0])) ?? "visible" }
                guard names.count == sheets.count, names.indices.allSatisfy({ names[$0] == sheets[$0].name }),
                      states.indices.contains(targetIndex), states[targetIndex] == "visible" else {
                    throw OfficeDocumentError.verificationFailed
                }
                for (position, state) in states.enumerated() where position != targetIndex {
                    guard state == "hidden" || state == "veryHidden" else {
                        throw OfficeDocumentError.verificationFailed
                    }
                }
                let reopenedWorksheet = try reopened.xml(path: target.partPath, limit: maximumXMLBytes)
                guard reopenedWorksheet.contains("fitToPage=\"1\""),
                      reopenedWorksheet.contains("fitToWidth=\"1\""),
                      reopenedWorksheet.contains("fitToHeight=\"1\"") else {
                    throw OfficeDocumentError.verificationFailed
                }
                // Exactly one Print_Area must survive in the copy: ours.
                var survivingAreas = 0
                for entry in elementRanges(reopenedWorkbook, tag: "definedName") {
                    let element = String(reopenedWorkbook[entry])
                    let name = attribute("name", inOpeningElement: element) ?? ""
                    let localSheetId = attribute("localSheetId", inOpeningElement: element)
                    if name == "_xlnm.Print_Area" {
                        survivingAreas += 1
                        guard localSheetId == String(targetIndex) else {
                            throw OfficeDocumentError.verificationFailed
                        }
                    } else if name == "_xlnm.Print_Titles" {
                        throw OfficeDocumentError.verificationFailed
                    }
                }
                guard survivingAreas == 1 else { throw OfficeDocumentError.verificationFailed }
                // The source must still be the exact bytes we started from.
                guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA else {
                    throw OfficeRegionExportError.sourceChangedDuringCopy
                }
            })

        guard try FloeDigest.sha256Hex(ofFileAt: sourceURL) == sourceSHA else {
            throw OfficeRegionExportError.sourceChangedDuringCopy
        }
        let copySHA = try FloeDigest.sha256Hex(ofFileAt: destinationURL)
        // A final reopen through the shared inspector proves the copy is a
        // consistent workbook (relationships + fields readable).
        let reopenedSnapshot = try OfficeDocumentService.inspect(url: destinationURL)
        guard reopenedSnapshot.kind == .workbook, reopenedSnapshot.sha256?.lowercased() == copySHA else {
            throw OfficeDocumentError.verificationFailed
        }
        let plan = OfficeRegionPrintPlan(
            sheetIndex: target.index,
            sheetName: target.name,
            sheetPartPath: target.partPath,
            printAreaReference: printAreaReference,
            suppressedSheetNames: sheets.indices.filter { $0 != target.index }.map { sheets[$0].name },
            removedPrintAreas: removedPrintAreas,
            removedPrintTitles: removedPrintTitles,
            madeTargetVisible: madeTargetVisible,
            setActiveTab: setActiveTab,
            sourceSHA256: sourceSHA,
            copySHA256: copySHA,
            packageEntries: reopenedSnapshot.packageEntries)
        return (destinationURL, plan)
    }

    // MARK: - Helpers

    private static func selectSheet(from sheets: [OfficeRegionWorkbookSheet],
                                    index: Int?, name: String?) throws -> OfficeRegionWorkbookSheet {
        if let index {
            guard sheets.indices.contains(index) else {
                throw OfficeRegionExportError.sheetIndexOutOfRange(index: index, sheetCount: sheets.count)
            }
            return sheets[index]
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Exact tab-name match only. No fuzzy "closest sheet" guessing:
            // a wrong sheet must never be printed for the requested one.
            if let exact = sheets.first(where: { $0.name == trimmed }) { return exact }
            throw OfficeRegionExportError.unknownSheet(requested: trimmed,
                                                       available: sheets.map(\.name))
        }
        throw OfficeRegionExportError.unknownSheet(requested: "(none)",
                                                  available: sheets.map(\.name))
    }

    /// `'It''s Tab'` — OOXML sheet names are quoted with internal apostro-
    /// phes doubled. Quoting is always valid, so every name is quoted.
    static func quoteSheetName(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Element-range scan with the same boundary discipline the shared
    /// inspector uses (self-closing tags never swallow a sibling).
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
            let end = close.upperBound
            ranges.append(candidate.lowerBound..<end)
            cursor = end
        }
        return ranges
    }

    private static func attribute(_ name: String, inOpeningElement element: String) -> String? {
        XMLText.attribute(name, inOpeningElement: element)
    }

    /// Adds or replaces one attribute on an element opening tag. Element is
    /// either `<tag .../>` or `<tag ...>…</tag>`; only the opening tag is
    /// touched (same convention the shared inspector's attribute reader uses).
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
        // `<tag .../>`: the head ends with the slash before the final `>`,
        // so the attribute must go BEFORE that slash.
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

    /// The full `name="value"` range inside an element opening tag. The
    /// attribute name must start at the tag body or follow whitespace, so a
    /// suffix inside a prefixed/foreign attribute name never matches. Quote
    /// forms `"` and `'` are both handled; the scan never crosses the tag.
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
}

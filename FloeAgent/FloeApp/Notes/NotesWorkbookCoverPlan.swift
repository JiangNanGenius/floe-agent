// SPDX-License-Identifier: MPL-2.0
//
// Foundation-only worksheet and window selection for the bounded native
// workbook content summary.
//
// The summary is the product's bounded answer to the system whole-workbook
// page render: it shows one worksheet and one window of real cells instead of
// shrinking an entire used range into a card. Keeping this selection free of
// UIKit and of document-module types makes the exact semantics compilable and
// testable off-device.
import Foundation

/// One cell reference exactly as `OfficeDocumentService.inspect` exposes it:
/// the worksheet section name ("Sheet N" from the worksheet part path), the
/// A1-style cell label and the display text, which is empty for a referenced
/// but blank cell.
struct WorkbookCoverField: Equatable {
    var section: String
    var label: String
    var text: String

    init(section: String, label: String, text: String) {
        self.section = section
        self.label = label
        self.text = text
    }
}

/// One workbook sheet exactly as the read-only workbook preview metadata
/// reports it: array position is the workbook's actual tab order, `section` is
/// the stable key of the sheet's worksheet part ("Sheet N"), and the hidden
/// row/column layout is the bounded, read-only visibility information parsed
/// from the worksheet. It never carries cell text.
struct WorkbookCoverSheet: Equatable {
    /// The tab's display name from `xl/workbook.xml`.
    var name: String
    /// The stable section key of the sheet's worksheet part.
    var section: String
    var isVisible: Bool
    /// 1-based hidden row numbers.
    var hiddenRows: Set<Int>
    /// 1-based hidden column spans.
    var hiddenColumnSpans: [ClosedRange<Int>]
    /// True when the hidden layout could not be fully analyzed; the summary
    /// must not filter with an incomplete list.
    var hiddenLayoutTruncated: Bool

    init(
        name: String,
        section: String,
        isVisible: Bool,
        hiddenRows: Set<Int> = [],
        hiddenColumnSpans: [ClosedRange<Int>] = [],
        hiddenLayoutTruncated: Bool = false
    ) {
        self.name = name
        self.section = section
        self.isVisible = isVisible
        self.hiddenRows = hiddenRows
        self.hiddenColumnSpans = hiddenColumnSpans
        self.hiddenLayoutTruncated = hiddenLayoutTruncated
    }

    /// 1-based row visibility.
    func isHidden(row: Int) -> Bool { hiddenRows.contains(row) }

    /// 1-based column visibility.
    func isHidden(column: Int) -> Bool { hiddenColumnSpans.contains { $0.contains(column) } }
}

/// The outcome of choosing a bounded workbook summary from authoritative
/// tab/visibility metadata. The non-plan cases are deliberately distinct so a
/// caller can publish the right honest state (explicit empty placeholder vs.
/// the existing native preview) and record a precise diagnostic:
///
///  * `.emptyVisibleWorkbook` — the workbook is fully understood and no
///    visible sheet exposes visible text. A summary grid must not be drawn,
///    and a system render could only be a blank page.
///  * `.metadataRequired` — no authoritative preview metadata was available
///    (older callers, or a package whose workbook relationships do not
///    resolve). Never guess the first sheet.
///  * `.hiddenFilteringUnavailable` — a visible, non-empty sheet declared more
///    hidden layout than the bounded analysis keeps, so hidden cells cannot be
///    excluded reliably.
///  * `.fieldListIncomplete` — the inspected cell list was truncated before
///    every sheet was read, so "no visible content" cannot be proven.
enum WorkbookCoverPlanDecision: Equatable {
    case plan(WorkbookCoverPlan)
    case emptyVisibleWorkbook
    case metadataRequired
    case hiddenFilteringUnavailable
    case fieldListIncomplete
}

/// The bounded layout of one workbook content summary.
///
/// `cells` are positioned relative to the rendered window (`anchorColumn`,
/// `anchorRow`), so the renderer never has to know about the sheet's absolute
/// coordinates. The window is anchored at the top-left of the cells that
/// actually carry visible text: a table that starts at C10 renders from C10
/// rather than wasting the window on empty leading rows and columns, while a
/// sheet that starts at A1 renders exactly where it did before.
struct WorkbookCoverPlan: Equatable {
    struct Cell: Equatable {
        /// Zero-based, relative to the rendered window's top-left.
        var column: Int
        var row: Int
        var text: String
    }

    /// The chosen worksheet section ("Sheet N").
    var sheet: String
    /// True when the chosen worksheet is the workbook's own first tab-order
    /// sheet, which is the sheet the system page renderer targets. When false,
    /// the system render draws an earlier (often empty, hidden or
    /// formatting-only) sheet. On the legacy metadata-free path this is the
    /// first worksheet part instead.
    var isFirstWorksheet: Bool
    /// Zero-based top-left of the rendered window in sheet coordinates.
    var anchorColumn: Int
    var anchorRow: Int
    /// Drawn window size, clamped to 1...`maximumColumns` / 1...`maximumRows`.
    var columns: Int
    var rows: Int
    /// Referenced cells inside the window, window-relative. Blank references
    /// are kept so their grid lines still render; cells outside the window are
    /// dropped, never rewritten.
    var cells: [Cell]
    /// True when the worksheet's whole referenced extent (including empty
    /// formatted cells and cells outside the window) is wider or taller than
    /// the bounded window. The system page renderer can then only fit the
    /// entire used extent at once, which is the unreadable wide/tall workbook
    /// render this bounded summary replaces.
    var usedExtentExceedsWindow: Bool
    /// True when the chosen worksheet declares hidden rows or columns. The
    /// filtered summary deliberately excludes that content, so the system
    /// whole-sheet page (which does not honor Floe's filtering) could show
    /// unverified hidden data. The primary product decision is to retain the
    /// filtered bounded summary as the settled cover in that case.
    var hasKnownHiddenContent: Bool

    /// True when the settled cover must stay this bounded, labeled summary
    /// instead of the system page render:
    ///
    ///  * the worksheet's whole referenced extent does not fit the bounded
    ///    window, so the system render could only be a whole-workbook fit
    ///    (wide/tall sheets, stray distant formatted cells); or
    ///  * the chosen worksheet is not the first worksheet part, so the system
    ///    renderer targets a different sheet — often an empty cover sheet; or
    ///  * the chosen worksheet declares hidden rows or columns, so the system
    ///    render could expose content the filtered summary intentionally hides.
    ///
    /// A workbook whose first worksheet fits the window and declares no hidden
    /// content keeps the original Quick Look-first behavior: the system page
    /// render then shows the same content at a legible size.
    var prefersBoundedSummaryOverSystemRender: Bool {
        usedExtentExceedsWindow || !isFirstWorksheet || hasKnownHiddenContent
    }
}

enum WorkbookCoverPlanner {
    /// The renderer's stable window bounds. They are part of the cover
    /// contract asserted by the NativeNotes geometry tests, so they do not
    /// change here.
    static let maximumColumns = 5
    static let maximumRows = 10

    /// Legacy metadata-free plan: it orders worksheets by the inspect order of
    /// their part paths and cannot see tab order, visibility or hidden rows.
    /// It is retained for callers and fixtures that carry no workbook preview
    /// metadata; the production cover path uses `decide(fields:sheets:...)`,
    /// because a corrupt relationship must never fall back to "sheet 1 by
    /// file name".
    ///
    /// The plan is nil when no worksheet exposes an addressable cell with
    /// visible text. A nil plan must never be replaced by a synthetic grid: a
    /// header-only summary is not document content.
    static func plan(fields: [WorkbookCoverField]) -> WorkbookCoverPlan? {
        // Group by worksheet section, preserving the inspect order (worksheet
        // parts sorted by their path number).
        var order: [String] = []
        var bySection: [String: [WorkbookCoverField]] = [:]
        for field in fields {
            if bySection[field.section] == nil { order.append(field.section) }
            bySection[field.section, default: []].append(field)
        }
        // Prefer the first worksheet that actually shows text. An earlier
        // formatting-only sheet (drawn as an empty grid before) must not hide
        // the sheet that carries the workbook's content.
        guard let chosen = order.first(where: { name in
            (bySection[name] ?? []).contains { !isBlank($0.text) }
        }) else { return nil }

        let section = bySection[chosen] ?? []
        var parsed: [(column: Int, row: Int, text: String)] = []
        for field in section {
            guard let position = cellPosition(field.label) else { continue }
            parsed.append((position.column, position.row, field.text))
        }
        let populated = parsed.filter { !isBlank($0.text) }
        guard !populated.isEmpty else { return nil }

        let firstColumn = populated.map(\.column).min() ?? 0
        let firstRow = populated.map(\.row).min() ?? 0
        let lastColumn = populated.map(\.column).max() ?? firstColumn
        let lastRow = populated.map(\.row).max() ?? firstRow
        let columns = min(lastColumn - firstColumn + 1, maximumColumns)
        let rows = min(lastRow - firstRow + 1, maximumRows)

        let cells = parsed
            .filter { cell in
                cell.column >= firstColumn && cell.column < firstColumn + columns
                    && cell.row >= firstRow && cell.row < firstRow + rows
            }
            .map { WorkbookCoverPlan.Cell(column: $0.column - firstColumn, row: $0.row - firstRow, text: $0.text) }
            .sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        guard !cells.isEmpty else { return nil }

        // The referenced extent (every cell reference the sheet declares,
        // including blank formatted cells) is the conservative proxy for the
        // extent the system page renderer lays out. The inspect snapshot does
        // not expose a stale `<dimension>` or a print area larger than the
        // cells themselves; that limit is recorded in the lane diagnosis.
        let referencedColumns = (parsed.map(\.column).max() ?? firstColumn) - (parsed.map(\.column).min() ?? firstColumn) + 1
        let referencedRows = (parsed.map(\.row).max() ?? firstRow) - (parsed.map(\.row).min() ?? firstRow) + 1
        let usedExtentExceedsWindow = referencedColumns > maximumColumns || referencedRows > maximumRows

        return WorkbookCoverPlan(
            sheet: chosen,
            isFirstWorksheet: (worksheetNumber(chosen) ?? 1) <= 1,
            anchorColumn: firstColumn,
            anchorRow: firstRow,
            columns: columns,
            rows: rows,
            cells: cells,
            usedExtentExceedsWindow: usedExtentExceedsWindow,
            // The metadata-free legacy path cannot see hidden rows/columns.
            hasKnownHiddenContent: false
        )
    }

    /// The bounded plan for one workbook whose tab/visibility metadata is
    /// authoritative, or the exact reason no honest bounded summary exists.
    ///
    /// Selection is by the workbook's own tab order, never by worksheet part
    /// number: the first visible sheet that exposes visible non-blank text
    /// after hidden rows and hidden columns are filtered out wins. Hidden and
    /// very-hidden sheets are never candidates, and cells inside hidden rows
    /// or columns are never drawn, so a hidden helper sheet or a hidden helper
    /// column cannot reach the cover.
    static func decide(
        fields: [WorkbookCoverField],
        sheets: [WorkbookCoverSheet],
        fieldsComplete: Bool
    ) -> WorkbookCoverPlanDecision {
        guard fieldsComplete else { return .fieldListIncomplete }
        guard !sheets.isEmpty else { return .emptyVisibleWorkbook }
        var bySection: [String: [WorkbookCoverField]] = [:]
        for field in fields {
            bySection[field.section, default: []].append(field)
        }
        for (tabIndex, sheet) in sheets.enumerated() where sheet.isVisible {
            let sheetFields = bySection[sheet.section] ?? []
            // A sheet with no non-blank cell cannot hide content, so an
            // incomplete hidden layout is harmless for it.
            guard sheetFields.contains(where: { !isBlank($0.text) }) else { continue }
            // A sheet that does carry text must be filterable with complete
            // knowledge, or the whole workbook defers to the native preview.
            guard !sheet.hiddenLayoutTruncated else { return .hiddenFilteringUnavailable }
            let visibleFields = sheetFields.filter { field in
                guard let position = cellPosition(field.label) else { return false }
                return !sheet.isHidden(row: position.row + 1) && !sheet.isHidden(column: position.column + 1)
            }
            guard visibleFields.contains(where: { !isBlank($0.text) }) else { continue }
            guard let plan = makePlan(sheet: sheet, tabIndex: tabIndex, allFields: sheetFields,
                                      visibleFields: visibleFields) else { continue }
            return .plan(plan)
        }
        return .emptyVisibleWorkbook
    }

    /// Builds the bounded window from the cells that survive hidden
    /// row/column filtering. The used-extent policy keeps the conservative
    /// meaning of the legacy path: it is computed from every referenced cell
    /// of the chosen sheet (including hidden cells and blank formatting), so
    /// the summary is preferred over a whole-extent system page whenever that
    /// page could only be a smaller render.
    private static func makePlan(
        sheet: WorkbookCoverSheet,
        tabIndex: Int,
        allFields: [WorkbookCoverField],
        visibleFields: [WorkbookCoverField]
    ) -> WorkbookCoverPlan? {
        var parsed: [(column: Int, row: Int, text: String)] = []
        for field in visibleFields {
            guard let position = cellPosition(field.label) else { continue }
            parsed.append((position.column, position.row, field.text))
        }
        let populated = parsed.filter { !isBlank($0.text) }
        guard !populated.isEmpty else { return nil }

        let firstColumn = populated.map(\.column).min() ?? 0
        let firstRow = populated.map(\.row).min() ?? 0
        let lastColumn = populated.map(\.column).max() ?? firstColumn
        let lastRow = populated.map(\.row).max() ?? firstRow
        let columns = min(lastColumn - firstColumn + 1, maximumColumns)
        let rows = min(lastRow - firstRow + 1, maximumRows)

        let cells = parsed
            .filter { cell in
                cell.column >= firstColumn && cell.column < firstColumn + columns
                    && cell.row >= firstRow && cell.row < firstRow + rows
            }
            .map { WorkbookCoverPlan.Cell(column: $0.column - firstColumn, row: $0.row - firstRow, text: $0.text) }
            .sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        guard !cells.isEmpty else { return nil }

        let referenced = allFields.compactMap { cellPosition($0.label) }
        let referencedColumns = (referenced.map(\.column).max() ?? firstColumn)
            - (referenced.map(\.column).min() ?? firstColumn) + 1
        let referencedRows = (referenced.map(\.row).max() ?? firstRow)
            - (referenced.map(\.row).min() ?? firstRow) + 1
        let usedExtentExceedsWindow = referencedColumns > maximumColumns || referencedRows > maximumRows

        return WorkbookCoverPlan(
            sheet: sheet.section,
            isFirstWorksheet: tabIndex == 0,
            anchorColumn: firstColumn,
            anchorRow: firstRow,
            columns: columns,
            rows: rows,
            cells: cells,
            usedExtentExceedsWindow: usedExtentExceedsWindow,
            hasKnownHiddenContent: !sheet.hiddenRows.isEmpty || !sheet.hiddenColumnSpans.isEmpty
        )
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parses an A1-style reference into zero-based column and row. The same
    /// reference form `XLSXCellCodec` emits; anything else is skipped. A
    /// multi-letter column (AA, AB, ...) is parsed base-26.
    static func cellPosition(_ reference: String) -> (column: Int, row: Int)? {
        let upper = reference.uppercased()
        var column = 0
        var row = 0
        var readingColumn = true
        for scalar in upper.unicodeScalars {
            if readingColumn, scalar.value >= 65, scalar.value <= 90 {
                column = column * 26 + Int(scalar.value - 64)
            } else if scalar.value >= 48, scalar.value <= 57 {
                readingColumn = false
                row = row * 10 + Int(scalar.value - 48)
            } else {
                readingColumn = true
            }
        }
        guard column > 0, row > 0 else { return nil }
        return (column - 1, row - 1)
    }

    /// The trailing worksheet number of a section name ("Sheet 12" -> 12).
    /// Unknown naming returns nil so the caller keeps the original
    /// system-first behavior instead of silently changing the settled source.
    static func worksheetNumber(_ section: String) -> Int? {
        let digits = section.reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }
}

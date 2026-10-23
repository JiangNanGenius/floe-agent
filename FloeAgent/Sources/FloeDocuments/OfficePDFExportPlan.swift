// SPDX-License-Identifier: MPL-2.0
// FloeDocuments — pure, view-independent Office PDF export plan.
//
// This file owns the values a user chooses BEFORE a PDF exists: the print
// scope (the document's own settings, one named sheet with all of its content,
// the sheet's own saved print area, one canonical cell range, an explicitly
// selected set of worksheets, or every visible sheet), the page setup
// overrides (paper, orientation, margins, exactly one scaling control —
// preset fit, an exact 10–400% scale, or a fit-to-width×height page count —
// and the optional explicit printed-gridlines choice), and an optional final
// PDF page selection. It also owns the read-only content-extent resolver the
// live UI can use to prefill an explicit cell range from the saved package.
//
// Nothing here renders, opens an engine session or touches a live editor.
// `OfficePrintCopy` turns an XLSX plan into a private copy with real print
// members; `FloeApp.OfficePDFExportService` runs the existing isolated PDF
// export and validates the actual file. Keeping the plan pure makes the same
// contract usable by the screen and by the assistant, without SwiftUI state.
//
// Deliberate scope boundaries:
//  * No assistant PNG region limits. Cell ranges are validated against the
//    native Excel worksheet bounds (XFD1048576), not 32x160x2400, and are
//    never enumerated cell by cell.
//  * No "current sheet" case. The live adapter resolves the engine's selected
//    sheet to its real workbook tab identity first; the backend never assumes
//    the first sheet.
//  * No page setup is invented for formats whose engine support is not
//    implemented. `validate(for:)` refuses non-XLSX custom settings instead
//    of silently dropping them.

import Foundation

/// Paper size values that map to the OOXML `pageSetup@paperSize` codes the
/// pinned engine and spreadsheet applications both understand.
public enum OfficePDFPaper: String, Codable, Sendable, CaseIterable, Equatable {
    case a4
    case a3
    case letter
    case legal

    /// ECMA-376 `ST_PaperSize` code.
    public var openXMLPaperSize: Int {
        switch self {
        case .a4: return 9
        case .a3: return 8
        case .letter: return 1
        case .legal: return 5
        }
    }
}

public enum OfficePDFOrientation: String, Codable, Sendable, CaseIterable, Equatable {
    case portrait
    case landscape
}

public enum OfficePDFFit: String, Codable, Sendable, CaseIterable, Equatable {
    /// Declare the sheet's own scale (`pageSetUpPr@fitToPage="0"`,
    /// `pageSetup@scale="100"`) and remove stale fit attributes.
    case actualSize
    /// Fit all printed columns onto one page width; page count vertical is
    /// automatic (`fitToWidth="1" fitToHeight="0"`).
    case fitToWidth
    /// Fit the whole print scope onto one page (`fitToWidth="1"
    /// fitToHeight="1"`).
    case fitToOnePage
}

/// A bounded explicit scaling percentage written to `pageSetup@scale` with
/// `pageSetUpPr@fitToPage="0"`. The bounds are the ECMA-376 `ST_Percentage`
/// range the spreadsheet print path reads (the same `scale` member that the
/// user's own saved worksheets already carry, e.g. `scale="100"`), so any
/// value here only changes an attribute the engine demonstrably consumes.
public enum OfficePDFScale {
    public static let minimumPercent = 10
    public static let maximumPercent = 400
}

/// An explicit fit-to-pages size written to `pageSetup@fitToWidth`/
/// `pageSetup@fitToHeight` with `pageSetUpPr@fitToPage="1"`: at most `width`
/// pages wide by at most `height` pages tall. Bounds exclude the `0`
/// ("automatic") spelling so every accepted value is a definite page budget;
/// the automatic directions remain available through `OfficePDFFit`.
public struct OfficePDFFitPages: Codable, Sendable, Equatable {
    public static let minimum = 1
    public static let maximum = 99

    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Margin presets. `.document` is a no-op: the source worksheet's own
/// `pageMargins` element is left byte-identical. The other presets write the
/// six physical-inch attributes OOXML requires.
public enum OfficePDFMargins: String, Codable, Sendable, CaseIterable, Equatable {
    case document
    case normal
    case narrow
    case wide

    /// `(left, right, top, bottom, header, footer)` in inches. Values are
    /// kept as canonical decimal strings so the XML never depends on the
    /// process locale.
    var openXMLValues: (left: String, right: String, top: String,
                        bottom: String, header: String, footer: String)? {
        switch self {
        case .document:
            return nil
        case .normal:
            return ("0.7", "0.7", "0.75", "0.75", "0.3", "0.3")
        case .narrow:
            return ("0.25", "0.25", "0.25", "0.25", "0.3", "0.3")
        case .wide:
            return ("1", "1", "1", "1", "0.5", "0.5")
        }
    }
}

/// The page setup subset this backend can actually write into a valid XLSX
/// copy. Every `nil` field means "keep the source worksheet's own value";
/// only chosen fields are overridden.
public struct OfficePDFPageSetup: Codable, Sendable, Equatable {
    public var paper: OfficePDFPaper?
    public var orientation: OfficePDFOrientation?
    public var fit: OfficePDFFit?
    public var margins: OfficePDFMargins?
    /// Exact `pageSetup@scale` percentage (10…400). Mutually exclusive with
    /// `fit` and `fitPages`; nil keeps the sheet's own scaling member.
    public var scalePercent: Int?
    /// Exact fit-to-pages budget (1…99 × 1…99). Mutually exclusive with
    /// `fit` and `scalePercent`.
    public var fitPages: OfficePDFFitPages?
    /// Explicit `printOptions@gridLines` decision written only into the
    /// private print copy: `nil` keeps the worksheet's own printOptions
    /// member byte-identical, `true`/`false` declares printed gridlines
    /// on/off. Cell borders and the source package are never touched.
    /// The App's options form defaults to `true`: a printed spreadsheet is
    /// expected to show a practical cell grid, and this choice never edits
    /// the user's file. `.document` (nil here) stays selectable when a
    /// workbook's own saved print options must be honoured exactly.
    public var printGridlines: Bool?

    public init(paper: OfficePDFPaper? = nil,
                orientation: OfficePDFOrientation? = nil,
                fit: OfficePDFFit? = nil,
                margins: OfficePDFMargins? = nil,
                scalePercent: Int? = nil,
                fitPages: OfficePDFFitPages? = nil,
                printGridlines: Bool? = nil) {
        self.paper = paper
        self.orientation = orientation
        self.fit = fit
        self.margins = margins
        self.scalePercent = scalePercent
        self.fitPages = fitPages
        self.printGridlines = printGridlines
    }

    /// Keep every page-setup member of the source worksheet.
    public static let documentSettings = OfficePDFPageSetup()

    /// True when this setup asks for no worksheet change at all.
    public var isDocumentSettings: Bool {
        paper == nil && orientation == nil && fit == nil
            && (margins == nil || margins == .document)
            && scalePercent == nil && fitPages == nil
            && printGridlines == nil
    }

    /// True when at least one member must be written.
    public var hasOverrides: Bool { !isDocumentSettings }

    /// How many scaling controls are set; at most one may be chosen because
    /// `scale` and `fitToWidth/fitToHeight` are mutually exclusive in a
    /// consistent OOXML print setup.
    public var scalingControlCount: Int {
        (fit != nil ? 1 : 0) + (scalePercent != nil ? 1 : 0) + (fitPages != nil ? 1 : 0)
    }
}

/// What the shared backend can truthfully do for one source format.
///
/// `workbook` (`.xlsx`) supports the full plan: sheet/workbook scope, cell
/// ranges, page setup and a final PDF page selection.
/// `paginated` (`.docx`, `.pptx`) supports the document's own page setup and
/// a final PDF page selection, but no sheet/cell or custom page setup.
/// `documentSettingsOnly` (legacy `.xls`, `.ods`, `.doc`, `.odt`, `.rtf`,
/// `.ppt`, `.odp`) supports the document's own settings plus a final page
/// selection. Those formats are exported from an already-open live session
/// and finalized through the shared validator; they are not silently mapped
/// to a different qualified format.
public enum OfficePDFFormatSupport: String, Codable, Sendable, Equatable {
    case workbook
    case paginated
    case documentSettingsOnly

    public var supportsSheetScope: Bool { self == .workbook }
    /// Printing an explicitly chosen set of worksheets (each with its full
    /// content) uses the same copy-only visibility mechanism as `.sheet` and
    /// `.allVisibleSheets`, both already qualified on saved `.xlsx`.
    public var supportsSelectedSheetsScope: Bool { self == .workbook }
    /// Printing one sheet's own saved `_xlnm.Print_Area` uses the same defined
    /// name the qualified cell-range and assistant region routes write.
    public var supportsPrintAreaScope: Bool { self == .workbook }
    public var supportsCustomPageSetup: Bool { self == .workbook }
    /// Exact `pageSetup@scale` percent — the same member a source worksheet's
    /// own settings already carry and the engine prints from.
    public var supportsExactScale: Bool { self == .workbook }
    /// Exact `fitToWidth`×`fitToHeight` page budget — the same members the
    /// qualified fit presets write.
    public var supportsFitPageCount: Bool { self == .workbook }
    /// Explicit printed-gridlines choice — the same `printOptions@gridLines`
    /// member a saved worksheet's own print settings already carry. It is
    /// written only into the private print copy, never into cell borders.
    public var supportsPrintGridlines: Bool { self == .workbook }
    public var supportsFinalPageRange: Bool { true }
    /// The saved-file isolated engine host is qualified for `.xlsx`,
    /// `.docx` and `.pptx` only. Legacy formats use the live-session
    /// finalize path instead of being mapped to another format.
    public var supportsSavedIsolatedExport: Bool {
        self == .workbook || self == .paginated
    }

    public static func resolve(forExtension ext: String) -> OfficePDFFormatSupport? {
        switch ext.lowercased() {
        case "xlsx": return .workbook
        case "docx", "pptx": return .paginated
        case "xls", "ods", "doc", "odt", "rtf", "ppt", "odp":
            return .documentSettingsOnly
        default:
            return nil
        }
    }
}

/// What content the PDF should print.
public enum OfficePDFScope: Codable, Sendable, Equatable {
    /// The workbook's own print settings: every sheet the source already
    /// prints, its print areas and print titles, hidden state and tab order.
    /// The copy changes no workbook print member.
    case documentSettings
    /// Exactly one sheet, named by its real workbook tab name. `cellRange`
    /// is a canonical `A1:R37` reference; `nil` prints the sheet's full
    /// content (engine content extent, including ink/drawings outside the
    /// nonempty cells), never a used-range print crop.
    case sheet(name: String, cellRange: String?)
    /// Every visible sheet, each with its full content. Hidden and very-hidden
    /// sheets keep their state and are not printed.
    case allVisibleSheets
    /// Exactly one sheet, printed through the `_xlnm.Print_Area` the source
    /// workbook itself declares for that tab. When the sheet has no print
    /// area of its own this is truthfully the sheet's full content (the copy
    /// suppresses the other tabs and clears their areas, exactly like
    /// `.sheet(name:cellRange:nil)`); it never silently adopts another
    /// sheet's area. Print titles are preserved.
    case sheetWithPrintArea(name: String)
    /// An explicitly chosen set of worksheets (at least one name, workbook tab
    /// names in the request's own order is not meaningful — the copy prints
    /// them in tab order), each with its full content. Unselected sheets are
    /// suppressed inside the copy; already-hidden sheets stay hidden.
    case sheets(names: [String])
}

/// A bounded, strictly 1-based selection of FINAL PDF pages.
///
/// This is a page selection on the actual exported PDF, not a Word page
/// field or a slide number. An empty `pages` array means "all pages".
/// Values are normalized to ascending unique order; malformed or
/// out-of-range input is refused without producing a partial PDF.
public struct OfficePDFPageRange: Codable, Sendable, Equatable {
    /// A single export may select at most this many final pages. Larger
    /// documents remain exportable in full; the UI must split an explicit
    /// selection instead of silently truncating it.
    public static let maximumSelectedPages = 500

    public var pages: [Int]

    public init(pages: [Int]) {
        self.pages = pages
    }

    /// Strict parse of the user-facing form: `1-3,5` (whitespace allowed
    /// around tokens and hyphens). Returns `nil` for any malformed token,
    /// `0`, a reversed range, or a selection above the bound — the caller
    /// must not export a best-effort subset.
    public static func parse(_ text: String) -> OfficePDFPageRange? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return OfficePDFPageRange(pages: []) }
        var values: [Int] = []
        for rawToken in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return nil }
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return nil }
            guard let first = pageNumber(String(parts[0])) else { return nil }
            if parts.count == 2 {
                guard let last = pageNumber(String(parts[1])), last >= first else { return nil }
                guard last - first + 1 <= maximumSelectedPages else { return nil }
                values.append(contentsOf: first...last)
            } else {
                values.append(first)
            }
            guard values.count <= maximumSelectedPages else { return nil }
        }
        return OfficePDFPageRange(pages: Array(Set(values)).sorted())
    }

    /// Ascending unique form. Invalid values are preserved here so
    /// `validated(pageCount:)` can report them; this property never hides an
    /// invalid request.
    public var normalizedPages: [Int] {
        Array(Set(pages)).sorted()
    }

    /// Resolves this selection against an actual PDF page count.
    ///
    /// - Empty selection returns every page in order.
    /// - Non-empty selection is ordered, deduplicated, bounded and strictly
    ///   1-based; an out-of-range page refuses the whole selection.
    public func validated(pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else {
            throw OfficePDFPlanError.invalidDocumentPageCount(pageCount)
        }
        let normalized = normalizedPages
        guard normalized.allSatisfy({ $0 >= 1 }) else {
            throw OfficePDFPlanError.invalidPageSelection(
                reason: "PDF page numbers start at 1")
        }
        guard normalized.count <= Self.maximumSelectedPages else {
            throw OfficePDFPlanError.tooManySelectedPages(
                requested: normalized.count, maximum: Self.maximumSelectedPages)
        }
        if normalized.isEmpty {
            return Array(1...pageCount)
        }
        if let last = normalized.last, last > pageCount {
            throw OfficePDFPlanError.pageOutOfRange(page: last, pageCount: pageCount)
        }
        return normalized
    }

    private static func pageNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 7,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }
}

/// One complete, view-independent export request.
public struct OfficePDFPrintPlan: Codable, Sendable, Equatable {
    /// Hard cap for an explicit worksheet selection; it matches the
    /// assistant's 0-based sheet index bound and any real workbook this
    /// backend prints.
    public static let maximumSelectedSheets = 255

    public var scope: OfficePDFScope
    public var pageSetup: OfficePDFPageSetup
    /// `nil` or an empty selection means every page of the actual PDF.
    public var pageRange: OfficePDFPageRange?
    /// Whether the prepared output carries the app's handwriting ink.
    /// `true` (the default everywhere, including every plan decoded from a
    /// legacy payload that predates this key) prints the document exactly as
    /// before. `false` is one optional per-output setting: the prepared
    /// export path renders from an isolated copy whose proven-ink strokes
    /// (`OfficeInkOmission`) are removed, while typed cells and text,
    /// charts, images, preset shapes, printed gridlines and cell borders
    /// all stay, and the source package — including every saved stroke —
    /// is never written. The automatic content extent shrinks with the
    /// omitted ink, so a fit-to-width/one-page plan re-paginates without
    /// reserving space for suppressed strokes; an explicit larger cell
    /// range remains the user's own choice. Honesty boundary: the value is
    /// only honored on the saved isolated export route (`.xlsx`/`.docx`/
    /// `.pptx`); a live-session finalize (legacy formats) keeps ink and
    /// the service refuses `false` there instead of silently ignoring it.
    public var includeInk: Bool

    public init(scope: OfficePDFScope = .documentSettings,
                pageSetup: OfficePDFPageSetup = .documentSettings,
                pageRange: OfficePDFPageRange? = nil,
                includeInk: Bool = true) {
        self.scope = scope
        self.pageSetup = pageSetup
        self.pageRange = pageRange
        self.includeInk = includeInk
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case pageSetup
        case pageRange
        case includeInk
    }

    /// Plans encoded before this key existed decode as `includeInk == true`
    /// — the byte-identical behavior of every saved job and preview.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(OfficePDFScope.self, forKey: .scope)
        pageSetup = try container.decode(OfficePDFPageSetup.self, forKey: .pageSetup)
        pageRange = try container.decodeIfPresent(OfficePDFPageRange.self, forKey: .pageRange)
        includeInk = try container.decodeIfPresent(Bool.self, forKey: .includeInk) ?? true
    }

    /// The plan needs an XLSX print copy instead of exporting the source
    /// package as-is.
    public var requiresPrintCopy: Bool {
        switch scope {
        case .documentSettings:
            return pageSetup.hasOverrides || !includeInk
        case .sheet, .sheetWithPrintArea, .sheets, .allVisibleSheets:
            return true
        }
    }

    /// Structural validation that does not need an exported PDF. Page-range
    /// bounds against the actual page count are checked by the service after
    /// the real PDF exists.
    ///
    /// Non-XLSX formats support only their own document page setup: a sheet,
    /// workbook or cell-scope request is refused explicitly rather than
    /// silently normalized to the whole document.
    public func validate(for format: OfficeDocumentFormat) throws {
        try validate(forExtension: format.rawValue)
    }

    /// Validates the plan against the actual source extension, including the
    /// legacy formats the App's live session can export but the saved
    /// isolated host does not load. Custom sheet/page setup is refused
    /// explicitly for every non-workbook format; a final PDF page range is
    /// allowed for all supported formats.
    public func validate(forExtension ext: String) throws {
        guard let support = OfficePDFFormatSupport.resolve(forExtension: ext) else {
            throw OfficePDFPlanError.unsupportedFormat(ext)
        }
        if !support.supportsSheetScope, scope != .documentSettings {
            throw OfficePDFPlanError.unsupportedScope(format: ext)
        }
        if !support.supportsCustomPageSetup, pageSetup.hasOverrides {
            throw OfficePDFPlanError.unsupportedPageSetup(format: ext)
        }
        // Exactly one scaling control at most: `scale` and
        // `fitToWidth`/`fitToHeight` cannot both be declared truthfully.
        guard pageSetup.scalingControlCount <= 1 else {
            throw OfficePDFPlanError.conflictingScalingControls
        }
        if let scalePercent = pageSetup.scalePercent {
            guard (OfficePDFScale.minimumPercent...OfficePDFScale.maximumPercent)
                    .contains(scalePercent) else {
                throw OfficePDFPlanError.scalePercentOutOfRange(
                    requested: scalePercent,
                    minimum: OfficePDFScale.minimumPercent,
                    maximum: OfficePDFScale.maximumPercent)
            }
        }
        if let fitPages = pageSetup.fitPages {
            guard (OfficePDFFitPages.minimum...OfficePDFFitPages.maximum)
                    .contains(fitPages.width),
                  (OfficePDFFitPages.minimum...OfficePDFFitPages.maximum)
                    .contains(fitPages.height) else {
                throw OfficePDFPlanError.fitPagesOutOfRange(
                    requested: fitPages, maximum: OfficePDFFitPages.maximum)
            }
        }
        switch scope {
        case .documentSettings, .allVisibleSheets:
            break
        case .sheet(let name, let cellRange):
            guard name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false else {
                throw OfficePDFPlanError.invalidSheetName
            }
            if let cellRange {
                guard let parsed = OfficeRegionCellRange.parse(cellRange) else {
                    throw OfficePDFPlanError.invalidRange(requested: cellRange, example: "A1:R37")
                }
                guard parsed.lastColumn <= OfficePDFWorksheetBounds.maximumColumn,
                      parsed.lastRow <= OfficePDFWorksheetBounds.maximumRow else {
                    throw OfficePDFPlanError.rangeOutsideWorksheetBounds(
                        requested: cellRange,
                        maximumColumn: OfficePDFWorksheetBounds.maximumColumn,
                        maximumRow: OfficePDFWorksheetBounds.maximumRow)
                }
            }
        case .sheetWithPrintArea(let name):
            guard name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false else {
                throw OfficePDFPlanError.invalidSheetName
            }
        case .sheets(let names):
            guard !names.isEmpty else {
                throw OfficePDFPlanError.emptySheetSelection
            }
            guard names.count <= Self.maximumSelectedSheets else {
                throw OfficePDFPlanError.tooManySheets(
                    requested: names.count, maximum: Self.maximumSelectedSheets)
            }
            var seen: Set<String> = []
            for raw in names {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw OfficePDFPlanError.invalidSheetName
                }
                guard seen.insert(trimmed).inserted else {
                    throw OfficePDFPlanError.duplicateSheetName(name: trimmed)
                }
            }
        }
        if let pageRange {
            guard pageRange.pages.allSatisfy({ $0 >= 1 }) else {
                throw OfficePDFPlanError.invalidPageSelection(
                    reason: "PDF page numbers start at 1")
            }
            guard pageRange.normalizedPages.count <= OfficePDFPageRange.maximumSelectedPages else {
                throw OfficePDFPlanError.tooManySelectedPages(
                    requested: pageRange.normalizedPages.count,
                    maximum: OfficePDFPageRange.maximumSelectedPages)
            }
        }
    }
}

/// Native Excel worksheet bounds. A user PDF export may legitimately cover a
/// whole sheet; these are the only cell bounds the backend imposes. They are
/// intentionally unrelated to the assistant PNG region limits.
public enum OfficePDFWorksheetBounds {
    public static let maximumColumn = 16_384   // XFD
    public static let maximumRow = 1_048_576
}

/// Typed plan failures. The App layer maps these to localized copy; the
/// backend never invents a user-facing sentence that the UI must parse.
public enum OfficePDFPlanError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case invalidSheetName
    case unknownSheet(requested: String, available: [String])
    case invalidRange(requested: String, example: String)
    case rangeOutsideWorksheetBounds(requested: String, maximumColumn: Int, maximumRow: Int)
    case unsupportedScope(format: String)
    case unsupportedPageSetup(format: String)
    case conflictingScalingControls
    case scalePercentOutOfRange(requested: Int, minimum: Int, maximum: Int)
    case fitPagesOutOfRange(requested: OfficePDFFitPages, maximum: Int)
    case emptySheetSelection
    case tooManySheets(requested: Int, maximum: Int)
    case duplicateSheetName(name: String)
    case invalidPageSelection(reason: String)
    case tooManySelectedPages(requested: Int, maximum: Int)
    case pageOutOfRange(page: Int, pageCount: Int)
    case invalidDocumentPageCount(Int)
    case packageUnresolvable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "PDF export is not available for .\(ext)."
        case .invalidSheetName:
            "Choose a worksheet by its tab name."
        case .unknownSheet(let requested, let available):
            "No worksheet named \(requested) exists. Available sheets: \(available.joined(separator: ", "))."
        case .invalidRange(let requested, let example):
            "Cell range \(requested) is not a canonical rectangular reference; use a form like \(example)."
        case .rangeOutsideWorksheetBounds(let requested, let maximumColumn, let maximumRow):
            "Cell range \(requested) is outside the worksheet bounds (columns 1…\(maximumColumn), rows 1…\(maximumRow))."
        case .unsupportedScope(let format):
            "Sheet and workbook scopes are available for .xlsx workbooks only (requested .\(format))."
        case .unsupportedPageSetup(let format):
            "Custom paper, orientation, fit, margin and printed-gridlines settings are available for .xlsx workbooks only (requested .\(format))."
        case .conflictingScalingControls:
            "Choose only one scaling control: a fit preset, an exact scale, or a fit-to-pages size."
        case .scalePercentOutOfRange(let requested, let minimum, let maximum):
            "Scale \(requested)% is outside the supported \(minimum)…\(maximum)% range."
        case .fitPagesOutOfRange(let requested, let maximum):
            "Fit-to \(requested.width)×\(requested.height) pages is outside the supported \(OfficePDFFitPages.minimum)…\(maximum) bounds for each direction."
        case .emptySheetSelection:
            "Select at least one worksheet to print."
        case .tooManySheets(let requested, let maximum):
            "The sheet selection names \(requested) worksheets; select at most \(maximum)."
        case .duplicateSheetName(let name):
            "Worksheet \(name) is selected more than once."
        case .invalidPageSelection(let reason):
            "The page selection is invalid: \(reason)."
        case .tooManySelectedPages(let requested, let maximum):
            "The page selection names \(requested) pages; select at most \(maximum)."
        case .pageOutOfRange(let page, let pageCount):
            "Page \(page) does not exist in the exported PDF (\(pageCount) page(s))."
        case .invalidDocumentPageCount(let pageCount):
            "The exported PDF has an invalid page count (\(pageCount))."
        case .packageUnresolvable(let reason):
            "The workbook structure cannot be resolved safely (\(reason))."
        }
    }
}

/// Bounded, read-only content extent of one worksheet.
///
/// The cell rectangle comes from the worksheet's own `<dimension>` and is
/// expanded by the cell anchors of every drawing part the sheet references
/// (`twoCellAnchor` from/to). One-cell and absolute anchors cannot prove a
/// cell rectangle without inventing pixel-to-cell geometry, so they are
/// reported as unresolved and never silently guessed. An unresolved extent
/// (missing/invalid dimension) stays `nil`; callers must fall back to the
/// engine's full-content export instead of deriving a range from nonempty
/// cells.
public struct OfficePDFContentExtent: Codable, Sendable, Equatable {
    public var sheetName: String
    public var sheetPartPath: String
    public var dimensionReference: String?
    public var firstColumn: Int?
    public var lastColumn: Int?
    public var firstRow: Int?
    public var lastRow: Int?
    public var cellRangeReference: String?
    public var drawingPartPaths: [String]
    public var drawingAnchorCount: Int
    public var resolvedDrawingAnchorCount: Int
    public var unresolvedAnchorCount: Int
    public var includesDrawings: Bool

    /// True when the cell rectangle is known (a valid `<dimension>`).
    public var isResolved: Bool { cellRangeReference != nil }

    /// True when the rectangle is known AND every drawing anchor contributed
    /// a provable cell span. A false value means the range may under-cover
    /// drawing content.
    public var isComplete: Bool { isResolved && unresolvedAnchorCount == 0 }

    private static let maximumEntries = 4_096
    private static let maximumXMLBytes: UInt32 = 8 * 1_024 * 1_024

    /// Resolves the saved package's own extent for `sheetName`. The source is
    /// only read; its digest is re-verified when `expectedSHA256` is given.
    public static func resolve(sourceURL: URL,
                               sheetName: String,
                               expectedSHA256: String? = nil) throws -> OfficePDFContentExtent {
        let trimmed = sheetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OfficePDFPlanError.invalidSheetName }
        let sheets = try OfficeRegionExport.workbookSheets(sourceURL: sourceURL,
                                                           expectedSHA256: expectedSHA256)
        guard let target = sheets.first(where: { $0.name == trimmed }) else {
            throw OfficePDFPlanError.unknownSheet(requested: trimmed,
                                                  available: sheets.map(\.name))
        }
        let package = try OfficeArchive(url: sourceURL, maximumEntries: maximumEntries)
        guard package.paths.contains(target.partPath) else {
            throw OfficePDFPlanError.packageUnresolvable(reason: "worksheet part is missing")
        }
        let worksheet = try package.xml(path: target.partPath, limit: maximumXMLBytes)

        var dimensionReference: String?
        if let range = elementRanges(worksheet, localName: "dimension").first {
            dimensionReference = XMLText.attribute("ref", inOpeningElement: String(worksheet[range]))
        }
        var firstColumn: Int?
        var lastColumn: Int?
        var firstRow: Int?
        var lastRow: Int?
        var hasResolvedDimension = false
        if let dimensionReference,
           let parsed = OfficeRegionCellRange.parse(dimensionReference),
           parsed.lastColumn <= OfficePDFWorksheetBounds.maximumColumn,
           parsed.lastRow <= OfficePDFWorksheetBounds.maximumRow {
            firstColumn = parsed.firstColumn
            lastColumn = parsed.lastColumn
            firstRow = parsed.firstRow
            lastRow = parsed.lastRow
            hasResolvedDimension = true
        }

        let drawingPaths = try drawingPartPaths(sheetPartPath: target.partPath,
                                                package: package)
        var anchorCount = 0
        var resolvedAnchorCount = 0
        var unresolvedAnchorCount = 0
        for path in drawingPaths {
            let drawing: String
            do {
                drawing = try package.xml(path: path, limit: maximumXMLBytes)
            } catch {
                unresolvedAnchorCount += 1
                continue
            }
            for anchor in elementRanges(drawing, localName: "twoCellAnchor") {
                anchorCount += 1
                let block = String(drawing[anchor])
                guard let from = anchoredCell(in: block, tag: "from"),
                      let to = anchoredCell(in: block, tag: "to") else {
                    unresolvedAnchorCount += 1
                    continue
                }
                resolvedAnchorCount += 1
                if hasResolvedDimension {
                    firstColumn = min(firstColumn ?? Int.max, from.column + 1)
                    lastColumn = max(lastColumn ?? 0, to.column + 1)
                    firstRow = min(firstRow ?? Int.max, from.row + 1)
                    lastRow = max(lastRow ?? 0, to.row + 1)
                }
            }
            for anchor in elementRanges(drawing, localName: "oneCellAnchor") {
                anchorCount += 1
                let block = String(drawing[anchor])
                if hasResolvedDimension, let from = anchoredCell(in: block, tag: "from") {
                    firstColumn = min(firstColumn ?? Int.max, from.column + 1)
                    lastColumn = max(lastColumn ?? 0, from.column + 1)
                    firstRow = min(firstRow ?? Int.max, from.row + 1)
                    lastRow = max(lastRow ?? 0, from.row + 1)
                }
                // The anchor's `ext` is in EMU; converting it to cells would
                // require column widths/row heights we cannot prove.
                unresolvedAnchorCount += 1
            }
            for _ in elementRanges(drawing, localName: "absoluteAnchor") {
                anchorCount += 1
                // No cell coordinate exists in an absolute anchor.
                unresolvedAnchorCount += 1
            }
        }

        var cellRangeReference: String?
        if hasResolvedDimension,
           let firstColumn, let lastColumn, let firstRow, let lastRow,
           firstColumn >= 1, lastColumn >= firstColumn, firstRow >= 1, lastRow >= firstRow,
           lastColumn <= OfficePDFWorksheetBounds.maximumColumn,
           lastRow <= OfficePDFWorksheetBounds.maximumRow {
            cellRangeReference = OfficeRegionCellRange(
                firstColumn: firstColumn, lastColumn: lastColumn,
                firstRow: firstRow, lastRow: lastRow).canonicalReference
        } else {
            firstColumn = nil
            lastColumn = nil
            firstRow = nil
            lastRow = nil
        }

        return OfficePDFContentExtent(
            sheetName: target.name,
            sheetPartPath: target.partPath,
            dimensionReference: dimensionReference,
            firstColumn: firstColumn,
            lastColumn: lastColumn,
            firstRow: firstRow,
            lastRow: lastRow,
            cellRangeReference: cellRangeReference,
            drawingPartPaths: drawingPaths,
            drawingAnchorCount: anchorCount,
            resolvedDrawingAnchorCount: resolvedAnchorCount,
            unresolvedAnchorCount: unresolvedAnchorCount,
            includesDrawings: anchorCount > 0)
    }

    // MARK: - Drawing discovery

    private static func drawingPartPaths(sheetPartPath: String,
                                         package: OfficeArchive) throws -> [String] {
        let sheetFolder = (sheetPartPath as NSString).deletingLastPathComponent
        let sheetName = (sheetPartPath as NSString).lastPathComponent
        let relsPath = "\(sheetFolder)/_rels/\(sheetName).rels"
        guard package.paths.contains(relsPath) else { return [] }
        let rels = try package.xml(path: relsPath, limit: maximumXMLBytes)
        var paths: [String] = []
        for range in elementRanges(rels, localName: "Relationship") {
            let element = String(rels[range])
            guard let type = XMLText.attribute("Type", inOpeningElement: element),
                  type.hasSuffix("/drawing"),
                  let target = XMLText.attribute("Target", inOpeningElement: element),
                  let resolved = resolvePackageTarget(target, base: sheetFolder),
                  package.paths.contains(resolved),
                  !paths.contains(resolved) else { continue }
            paths.append(resolved)
        }
        return paths
    }

    /// Resolves a relationship target relative to a package folder, refusing
    /// any path that would escape the package root.
    private static func resolvePackageTarget(_ target: String, base: String) -> String? {
        let raw = target.hasPrefix("/") ? String(target.dropFirst()) : base + "/" + target
        var components: [String] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    // MARK: - Bounded XML scan

    /// Prefix-agnostic element ranges by local name. Handles `xdr:twoCellAnchor`
    /// as well as an unprefixed element and never swallows a sibling when an
    /// element is self-closing.
    private static func elementRanges(_ source: String, localName: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = source.startIndex
        while cursor < source.endIndex, let opening = source[cursor...].firstIndex(of: "<") {
            var index = source.index(after: opening)
            guard index < source.endIndex else { break }
            var isClosing = false
            if source[index] == "/" {
                isClosing = true
                index = source.index(after: index)
            }
            guard index < source.endIndex else { break }
            let first = source[index]
            if first == "!" || first == "?" {
                guard let finish = source[index...].firstIndex(of: ">") else { break }
                cursor = source.index(after: finish)
                continue
            }
            var tokenEnd = index
            while tokenEnd < source.endIndex,
                  !source[tokenEnd].isWhitespace,
                  source[tokenEnd] != ">",
                  source[tokenEnd] != "/" {
                tokenEnd = source.index(after: tokenEnd)
            }
            let token = String(source[index..<tokenEnd])
            guard !token.isEmpty, let tagEnd = source[tokenEnd...].firstIndex(of: ">") else {
                cursor = source.index(after: index)
                continue
            }
            let elementEnd = source.index(after: tagEnd)
            if isClosing {
                cursor = elementEnd
                continue
            }
            let local = token.split(separator: ":").last.map(String.init) ?? token
            if local == localName {
                if source[source.index(before: tagEnd)] == "/" {
                    ranges.append(opening..<elementEnd)
                } else if let close = source.range(of: "</\(token)>", range: elementEnd..<source.endIndex) {
                    ranges.append(opening..<close.upperBound)
                    cursor = close.upperBound
                    continue
                } else {
                    ranges.append(opening..<elementEnd)
                }
            }
            cursor = elementEnd
        }
        return ranges
    }

    private static func anchoredCell(in anchor: String, tag: String)
        -> (column: Int, row: Int)? {
        guard let blockRange = elementRanges(anchor, localName: tag).first,
              let column = integerText("col", in: String(anchor[blockRange])),
              let row = integerText("row", in: String(anchor[blockRange])),
              column >= 0, row >= 0,
              column < OfficePDFWorksheetBounds.maximumColumn,
              row < OfficePDFWorksheetBounds.maximumRow else { return nil }
        return (column, row)
    }

    private static func integerText(_ localName: String, in xml: String) -> Int? {
        guard let range = elementRanges(xml, localName: localName).first else { return nil }
        let element = xml[range]
        guard element.first != "/",
              let openEnd = element.firstIndex(of: ">"),
              let closeStart = element.lastIndex(of: "<"),
              openEnd < closeStart else { return nil }
        let text = XMLText.unescape(String(element[element.index(after: openEnd)..<closeStart]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 7,
              text.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let value = Int(text) else { return nil }
        return value
    }
}

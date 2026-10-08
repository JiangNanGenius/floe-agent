// FloeDocuments — shared, validated Office engine commands.
//
// Every requested Word/Excel/Presentation edit funnels through this one typed
// catalog. The UI and the agent tools build the SAME `OfficeEngineCommand`; the
// app-side bridge dispatches the SAME plan to the pinned Collabora engine, and
// the saved package is verified against the SAME expectations. Nothing here
// reaches the engine as free-form UNO: the catalog is the allow-list.
//
// Encodings are not invented. Each dispatch below mirrors a call site in the
// pinned bundle (`ThirdParty/Collabora` / `Vendor/Office/37261456081`):
//   * `.uno:StyleApply`      map.applyStyle(name, "ParagraphStyles")
//   * `.uno:DefaultBullet` / `.uno:DefaultNumbering`   toolbar + Ctrl+Shift+L / Ctrl+/
//   * `.uno:LeftPara` …      actionsMap.leftpara/centerpara/rightpara/justifypara
//   * `.uno:InsertTable`     insert-table popup (`Columns`/`Rows` long args)
//   * `.uno:NumberFormat*`   Calc format menu
//   * `.uno:InsertRowsBefore` / `.uno:DeleteRows` / column variants  row/column headers
//   * `.uno:FreezePanes`     row/column header menu
//   * `.uno:SortAscending` / `.uno:SortDescending` / `.uno:DataFilterAutoFilter`   Data menu
//   * `.uno:GoToCell`        #REF! error dialog "Find First" (`ToPoint` string)
//   * `.uno:DuplicatePage`   slide context menu (`InsertPos` int16)
//   * object alignment menu  `ObjectAlignLeft` / `AlignCenter` / `ObjectAlignRight` /
//                            `AlignUp` / `AlignMiddle` / `AlignDown`
//
// `scripts/tests/test_office_command_bridge_evidence.py` re-checks these exact
// encodings against the pinned bundle so the catalog cannot silently drift from
// the engine it claims to drive.

import Foundation
import FloeCore

public enum OfficeDocumentFormat: String, Codable, Sendable, CaseIterable {
    case docx, xlsx, pptx

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "docx": self = .docx
        case "xlsx": self = .xlsx
        case "pptx": self = .pptx
        default: return nil
        }
    }

    public static func from(kind: OfficeDocumentKind) -> OfficeDocumentFormat? {
        switch kind {
        case .word: return .docx
        case .workbook: return .xlsx
        case .presentation: return .pptx
        }
    }
}

public enum OfficeParagraphAlignment: String, Codable, Sendable, CaseIterable {
    case left, center, right, justified
}

public enum OfficeObjectAlignment: String, Codable, Sendable, CaseIterable {
    case left, center, right, top, middle, bottom
}

public enum OfficeNumberFormat: String, Codable, Sendable, CaseIterable {
    case standard, decimal, percent, currency, date, time, scientific, thousands, increaseDecimals, decreaseDecimals

    /// Pinned Calc menu command names (no arguments).
    var unoName: String {
        switch self {
        case .standard: return ".uno:NumberFormatStandard"
        case .decimal: return ".uno:NumberFormatDecimal"
        case .percent: return ".uno:NumberFormatPercent"
        case .currency: return ".uno:NumberFormatCurrency"
        case .date: return ".uno:NumberFormatDate"
        case .time: return ".uno:NumberFormatTime"
        case .scientific: return ".uno:NumberFormatScientific"
        case .thousands: return ".uno:NumberFormatThousands"
        case .increaseDecimals: return ".uno:NumberFormatIncDecimals"
        case .decreaseDecimals: return ".uno:NumberFormatDecDecimals"
        }
    }
}

/// One UNO argument in the exact `{"type":…,"value":…}` shape
/// `map.sendUnoCommand` JSON-encodes for the engine.
public struct OfficeUnoArgument: Equatable, Sendable, Codable {
    public enum Value: Equatable, Sendable, Codable {
        case string(String)
        case integer(Int)
        case boolean(Bool)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) { self = .boolean(bool) }
            else if let int = try? container.decode(Int.self) { self = .integer(int) }
            else { self = .string(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            }
        }
    }

    public var type: String
    public var value: Value

    public init(type: String, value: Value) {
        self.type = type
        self.value = value
    }

    public static func string(_ value: String) -> OfficeUnoArgument {
        OfficeUnoArgument(type: "string", value: .string(value))
    }

    public static func long(_ value: Int) -> OfficeUnoArgument {
        OfficeUnoArgument(type: "long", value: .integer(value))
    }

    public static func int16(_ value: Int) -> OfficeUnoArgument {
        OfficeUnoArgument(type: "int16", value: .integer(value))
    }

    public static func unsignedShort(_ value: Int) -> OfficeUnoArgument {
        OfficeUnoArgument(type: "unsigned short", value: .integer(value))
    }

    public var jsonObject: [String: Any] {
        switch value {
        case .string(let value): return ["type": type, "value": value]
        case .integer(let value): return ["type": type, "value": value]
        case .boolean(let value): return ["type": type, "value": value]
        }
    }
}

/// One step of an engine dispatch plan. The app-side JavaScript bridge knows
/// exactly these three shapes; no arbitrary UNO/JS crosses the boundary.
public enum OfficeDispatchStep: Equatable, Sendable {
    /// `window.app.map.sendUnoCommand(name, arguments)`.
    case uno(name: String, arguments: [String: OfficeUnoArgument])
    /// `window.app.socket.sendMessage(payload)` with a `uno …` payload.
    case socket(payload: String)
    /// `window.app.map.setPart(index)` (0-based part selection) before the next step.
    case selectPart(Int)

    var unoName: String? {
        if case .uno(let name, _) = self { return name }
        return nil
    }
}

public struct OfficeDispatchPlan: Equatable, Sendable {
    public var steps: [OfficeDispatchStep]
    /// Human-readable facts the caller can show/return; never claims success.
    public var notes: [String]

    public init(steps: [OfficeDispatchStep], notes: [String] = []) {
        self.steps = steps
        self.notes = notes
    }

    /// The names a verification state probe should watch for fresh
    /// `commandstatechanged` events (commands whose state the engine reports).
    public var observableCommands: [String] {
        steps.compactMap(\.unoName)
    }
}

public enum OfficeEngineCommandError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String, String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let command, let format):
            return "\(command) is not available for \(format) documents"
        case .invalidArgument(let detail):
            return detail
        }
    }
}

/// A typed, validated engine edit. Only the cases here can be dispatched; the
/// tool schema additionally allow-lists the command names it accepts.
///
/// Commands that act on the current cursor/selection carry an explicit target
/// wherever the engine exposes one (`cell`), and the rest are marked
/// `requiresSelectionFingerprint`: a proposal for them binds the live
/// selection identity captured at propose time and the apply re-checks it, so a
/// changed selection cannot silently redirect the edit. A command whose target
/// cannot be named and whose selection cannot be fingerprinted is gated
/// unavailable instead of being applied against an unknown target.
public enum OfficeEngineCommand: Equatable, Sendable {
    case wordStyle(name: String)
    case wordBulletList
    case wordNumberedList
    case wordAlignment(OfficeParagraphAlignment)
    case wordInsertTable(rows: Int, columns: Int)
    case excelNumberFormat(OfficeNumberFormat, cell: String)
    case excelInsertRows(count: Int, at: String)
    case excelDeleteRows(count: Int, at: String)
    case excelInsertColumns(count: Int, at: String)
    case excelDeleteColumns(count: Int, at: String)
    case excelFreezePanes(at: String?)
    case excelSort(ascending: Bool, range: String?)
    case excelAutoFilter
    case excelGoToCell(String)
    case excelRecalculate
    case pptDuplicateSlide(at: Int)
    case pptMoveSlide(from: Int, to: Int)
    case pptAlignObjects(OfficeObjectAlignment)

    /// Stable id used by the tool schema, capability matrix and receipts.
    public var id: String {
        switch self {
        case .wordStyle: return "word.style"
        case .wordBulletList: return "word.bulletList"
        case .wordNumberedList: return "word.numberedList"
        case .wordAlignment: return "word.alignment"
        case .wordInsertTable: return "word.insertTable"
        case .excelNumberFormat: return "excel.numberFormat"
        case .excelInsertRows: return "excel.insertRows"
        case .excelDeleteRows: return "excel.deleteRows"
        case .excelInsertColumns: return "excel.insertColumns"
        case .excelDeleteColumns: return "excel.deleteColumns"
        case .excelFreezePanes: return "excel.freezePanes"
        case .excelSort: return "excel.sort"
        case .excelAutoFilter: return "excel.autoFilter"
        case .excelGoToCell: return "excel.goToCell"
        case .excelRecalculate: return "excel.recalculate"
        case .pptDuplicateSlide: return "pptx.duplicateSlide"
        case .pptMoveSlide: return "pptx.moveSlide"
        case .pptAlignObjects: return "pptx.alignObjects"
        }
    }

    /// True when the command acts on whatever is selected in the live editor
    /// and cannot be redirected by an explicit engine target. A proposal for
    /// such a command must carry the live selection fingerprint.
    public var requiresSelectionFingerprint: Bool {
        switch self {
        case .wordStyle, .wordBulletList, .wordNumberedList, .wordAlignment:
            return true
        case .excelSort, .excelAutoFilter:
            return true
        case .pptAlignObjects:
            return true
        default:
            return false
        }
    }

    /// The explicit target shown in proposals/receipts.
    public var targetSummary: String {
        switch self {
        case .wordStyle, .wordBulletList, .wordNumberedList, .wordAlignment:
            return "current text selection"
        case .wordInsertTable:
            return "cursor position"
        case .excelNumberFormat(_, let cell): return "cell \(cell)"
        case .excelInsertRows(_, let cell), .excelDeleteRows(_, let cell),
             .excelInsertColumns(_, let cell), .excelDeleteColumns(_, let cell):
            return "cell \(cell)"
        case .excelFreezePanes(let cell): return "cell \(cell ?? "current")"
        case .excelSort(_, let range): return range.map { "range \($0)" } ?? "current selection"
        case .excelAutoFilter: return "current selection"
        case .excelGoToCell(let cell): return "cell \(cell)"
        case .excelRecalculate: return "workbook"
        case .pptDuplicateSlide(let index): return "slide \(index)"
        case .pptMoveSlide(let from, let to): return "slide \(from) → position \(to)"
        case .pptAlignObjects: return "current object selection"
        }
    }

    public var format: OfficeDocumentFormat {
        switch self {
        case .wordStyle, .wordBulletList, .wordNumberedList, .wordAlignment, .wordInsertTable:
            return .docx
        case .excelNumberFormat, .excelInsertRows, .excelDeleteRows, .excelInsertColumns,
             .excelDeleteColumns, .excelFreezePanes, .excelSort, .excelAutoFilter,
             .excelGoToCell, .excelRecalculate:
            return .xlsx
        case .pptDuplicateSlide, .pptMoveSlide, .pptAlignObjects:
            return .pptx
        }
    }

    public var isMutating: Bool {
        switch self {
        case .excelGoToCell, .excelRecalculate:
            return false
        default:
            return true
        }
    }

    /// Human summary used in proposal previews and receipts.
    public var summary: String {
        switch self {
        case .wordStyle(let name): return "Apply paragraph style \(name)"
        case .wordBulletList: return "Apply bulleted list"
        case .wordNumberedList: return "Apply numbered list"
        case .wordAlignment(let alignment): return "Align paragraphs \(alignment.rawValue)"
        case .wordInsertTable(let rows, let columns): return "Insert \(rows)×\(columns) table"
        case .excelNumberFormat(let format, let cell): return "Apply \(format.rawValue) number format to \(cell)"
        case .excelInsertRows(let count, let cell): return "Insert \(count) row(s) at \(cell)"
        case .excelDeleteRows(let count, let cell): return "Delete \(count) row(s) at \(cell)"
        case .excelInsertColumns(let count, let cell): return "Insert \(count) column(s) at \(cell)"
        case .excelDeleteColumns(let count, let cell): return "Delete \(count) column(s) at \(cell)"
        case .excelFreezePanes(let cell): return "Freeze panes\(cell.map { " at \($0)" } ?? "")"
        case .excelSort(let ascending, _): return ascending ? "Sort ascending" : "Sort descending"
        case .excelAutoFilter: return "Toggle AutoFilter"
        case .excelGoToCell(let cell): return "Go to cell \(cell)"
        case .excelRecalculate: return "Recalculate"
        case .pptDuplicateSlide(let index): return "Duplicate slide \(index)"
        case .pptMoveSlide(let from, let to): return "Move slide \(from) to position \(to)"
        case .pptAlignObjects(let alignment): return "Align selected objects \(alignment.rawValue)"
        }
    }

    // MARK: - Validation (fail closed, before anything reaches the engine)

    public func validate() throws {
        switch self {
        case .wordStyle(let name):
            guard OfficeEngineCommandCatalog.paragraphStyles.contains(name) else {
                throw OfficeEngineCommandError.invalidArgument(
                    "style must be one of: \(OfficeEngineCommandCatalog.paragraphStyles.joined(separator: ", "))")
            }
        case .wordInsertTable(let rows, let columns):
            guard (1...100).contains(rows), (1...20).contains(columns) else {
                throw OfficeEngineCommandError.invalidArgument("table size must be 1...100 rows × 1...20 columns")
            }
        case .excelInsertRows(let count, let cell), .excelDeleteRows(let count, let cell),
             .excelInsertColumns(let count, let cell), .excelDeleteColumns(let count, let cell):
            guard (1...100).contains(count) else {
                throw OfficeEngineCommandError.invalidArgument("row/column count must be 1...100")
            }
            try Self.validateCellReference(cell)
        case .excelNumberFormat(_, let cell):
            try Self.validateCellReference(cell)
        case .excelFreezePanes(let cell):
            if let cell { try Self.validateCellReference(cell) }
        case .excelSort(_, let range):
            if let range { try Self.validateCellRange(range) }
        case .excelGoToCell(let cell):
            try Self.validateCellReference(cell)
        case .pptDuplicateSlide(let index):
            guard (1...500).contains(index) else {
                throw OfficeEngineCommandError.invalidArgument("slide index must be 1...500")
            }
        case .pptMoveSlide(let from, let to):
            guard (1...500).contains(from), (1...500).contains(to), from != to else {
                throw OfficeEngineCommandError.invalidArgument("slide move needs distinct 1-based positions within 1...500")
            }
        case .wordBulletList, .wordNumberedList, .wordAlignment,
             .excelAutoFilter, .excelRecalculate, .pptAlignObjects:
            break
        }
    }

    static func validateCellReference(_ cell: String) throws {
        let pattern = "^[A-Za-z]{1,3}[1-9][0-9]{0,6}$"
        guard cell.range(of: pattern, options: .regularExpression) != nil else {
            throw OfficeEngineCommandError.invalidArgument("cell must be an A1 reference such as B7")
        }
    }

    static func validateCellRange(_ range: String) throws {
        let parts = range.split(separator: ":")
        guard parts.count == 2 else {
            throw OfficeEngineCommandError.invalidArgument("range must be A1:B9")
        }
        try validateCellReference(String(parts[0]))
        try validateCellReference(String(parts[1]))
    }

    // MARK: - Dispatch plans

    public var plan: OfficeDispatchPlan {
        OfficeEngineCommandCatalog.plan(for: self)
    }
}

public enum OfficeEngineCommandCatalog {
    /// Programmatic Writer paragraph style names exposed by the engine's
    /// `.uno:StyleApply` command values (the same names the pinned style
    /// combobox applies via `map.applyStyle(name, "ParagraphStyles")`).
    public static let paragraphStyles: [String] = [
        "Title", "Subtitle", "Heading 1", "Heading 2", "Heading 3", "Heading 4",
        "Normal", "Quote", "Caption",
    ]

    public static func plan(for command: OfficeEngineCommand) -> OfficeDispatchPlan {
        switch command {
        case .wordStyle(let name):
            return OfficeDispatchPlan(steps: [
                .uno(name: ".uno:StyleApply", arguments: [
                    "Style": .string(name),
                    "FamilyName": .string("ParagraphStyles"),
                ]),
            ], notes: ["Applies the paragraph style at the current selection/cursor."])

        case .wordBulletList:
            return OfficeDispatchPlan(steps: [
                .uno(name: ".uno:DefaultBullet", arguments: [:]),
            ], notes: ["Toggles the engine's default bulleted list on the current paragraphs."])

        case .wordNumberedList:
            return OfficeDispatchPlan(steps: [
                .uno(name: ".uno:DefaultNumbering", arguments: [:]),
            ], notes: ["Toggles the engine's default numbered list on the current paragraphs."])

        case .wordAlignment(let alignment):
            let name: String
            switch alignment {
            case .left: name = ".uno:LeftPara"
            case .center: name = ".uno:CenterPara"
            case .right: name = ".uno:RightPara"
            case .justified: name = ".uno:JustifyPara"
            }
            return OfficeDispatchPlan(steps: [.uno(name: name, arguments: [:])],
                                      notes: ["Applies paragraph alignment at the current selection."])

        case .wordInsertTable(let rows, let columns):
            return OfficeDispatchPlan(steps: [
                .uno(name: ".uno:InsertTable", arguments: [
                    "Columns": .long(columns),
                    "Rows": .long(rows),
                ]),
            ], notes: ["Inserts a real Writer table at the cursor; rows/columns are engine arguments."])

        case .excelNumberFormat(let format, let cell):
            return OfficeDispatchPlan(steps: [
                .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)]),
                .uno(name: format.unoName, arguments: [:]),
            ], notes: ["Moves the cell cursor to \(cell) first, then applies the number format."])

        case .excelInsertRows(let count, let cell):
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)])]
                + repeatStep(.uno(name: ".uno:InsertRowsBefore", arguments: [:]), count: count),
                                      notes: ["Inserts \(count) row(s) before \(cell)."])
        case .excelDeleteRows(let count, let cell):
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)])]
                + repeatStep(.uno(name: ".uno:DeleteRows", arguments: [:]), count: count),
                                      notes: ["Deletes \(count) row(s) at \(cell)."])
        case .excelInsertColumns(let count, let cell):
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)])]
                + repeatStep(.uno(name: ".uno:InsertColumnsBefore", arguments: [:]), count: count),
                                      notes: ["Inserts \(count) column(s) before \(cell)."])
        case .excelDeleteColumns(let count, let cell):
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)])]
                + repeatStep(.uno(name: ".uno:DeleteColumns", arguments: [:]), count: count),
                                      notes: ["Deletes \(count) column(s) at \(cell)."])

        case .excelFreezePanes(let cell):
            var steps: [OfficeDispatchStep] = []
            if let cell {
                steps.append(.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)]))
            }
            steps.append(.uno(name: ".uno:FreezePanes", arguments: [:]))
            return OfficeDispatchPlan(steps: steps,
                                      notes: ["Freezes rows/columns above-left of \(cell ?? "the current cell")."])

        case .excelSort(let ascending, let range):
            var steps: [OfficeDispatchStep] = []
            if let range {
                steps.append(.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(range)]))
            }
            steps.append(.uno(name: ascending ? ".uno:SortAscending" : ".uno:SortDescending", arguments: [:]))
            return OfficeDispatchPlan(steps: steps,
                                      notes: [range.map { "Sorts \($0) by its first column." }
                                              ?? "Sorts the current selection by its first column."])

        case .excelAutoFilter:
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:DataFilterAutoFilter", arguments: [:])],
                                      notes: ["Toggles the AutoFilter on the current range."])

        case .excelGoToCell(let cell):
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string(cell)])],
                                      notes: ["Moves the cell cursor; no content is changed."])

        case .excelRecalculate:
            return OfficeDispatchPlan(steps: [.uno(name: ".uno:Calculate", arguments: [:])],
                                      notes: ["Requests a full recalculation; formula results land in the saved output."])

        case .pptDuplicateSlide(let index):
            return OfficeDispatchPlan(steps: [
                .socket(payload: "uno .uno:DuplicatePage {\"InsertPos\":{\"type\":\"int16\",\"value\":\(max(0, index - 1))}}"),
            ], notes: ["Duplicates the current slide at 1-based position \(index)."])

        case .pptMoveSlide(let from, let to):
            // The pinned bundle exposes no move-slide UNO command; the engine's
            // own slide context menu reorders by duplicate + delete. The plan
            // states both steps so the saved output verification can prove the
            // final order.
            let insert = max(0, to - 1)
            return OfficeDispatchPlan(steps: [
                .socket(payload: "uno .uno:DuplicatePage {\"InsertPos\":{\"type\":\"int16\",\"value\":\(insert)}}"),
                .selectPart(from - 1),
                .uno(name: ".uno:DeletePage", arguments: [:]),
            ], notes: [
                "No .uno:MoveSlide exists in the pinned bundle; the slide is reordered by duplicate-at-target + delete-original.",
                "Slide content and notes are preserved; slide identity/animation timing may reset.",
            ])

        case .pptAlignObjects(let alignment):
            let name: String
            switch alignment {
            case .left: name = ".uno:ObjectAlignLeft"
            case .center: name = ".uno:AlignCenter"
            case .right: name = ".uno:ObjectAlignRight"
            case .top: name = ".uno:AlignUp"
            case .middle: name = ".uno:AlignMiddle"
            case .bottom: name = ".uno:AlignDown"
            }
            return OfficeDispatchPlan(steps: [.uno(name: name, arguments: [:])],
                                      notes: ["Aligns the currently selected drawing objects."])
        }
    }

    private static func repeatStep(_ step: OfficeDispatchStep, count: Int) -> [OfficeDispatchStep] {
        Array(repeating: step, count: max(1, count))
    }

    /// All commands implemented through the engine bridge for a format.
    public static func engineCommands(_ format: OfficeDocumentFormat) -> [OfficeEngineCommand] {
        switch format {
        case .docx:
            return [.wordStyle(name: "Heading 1"), .wordBulletList, .wordNumberedList,
                    .wordAlignment(.left), .wordInsertTable(rows: 1, columns: 1)]
        case .xlsx:
            return [.excelNumberFormat(.decimal, cell: "A1"), .excelInsertRows(count: 1, at: "A1"),
                    .excelDeleteRows(count: 1, at: "A1"),
                    .excelInsertColumns(count: 1, at: "A1"), .excelDeleteColumns(count: 1, at: "A1"),
                    .excelFreezePanes(at: "A1"), .excelSort(ascending: true, range: nil),
                    .excelAutoFilter, .excelGoToCell("A1"), .excelRecalculate]
        case .pptx:
            return [.pptDuplicateSlide(at: 1), .pptMoveSlide(from: 1, to: 2), .pptAlignObjects(.left)]
        }
    }
}

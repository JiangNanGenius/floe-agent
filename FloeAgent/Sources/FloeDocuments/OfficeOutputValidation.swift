// FloeDocuments — saved-package verification for engine edits.
//
// "Applied" is never taken from a dispatch acknowledgement. After an engine
// command is flushed, the private working copy is reopened with the ordinary
// OOXML reader and checked against the expectation the command promised
// (table inserted, freeze pane present, formula at a cell, slide count
// increased, …). The same snapshot answers read-only questions such as
// formula-error cell locations.
//
// The parser is deliberately bounded and structural: it scans the members the
// engine actually writes (word/document.xml, xl/worksheets/*, ppt/slides/*)
// with a hard byte cap; it is not a general OOXML implementation.

import Foundation
import Crypto
import FloeCore

public struct OfficeErrorCell: Equatable, Sendable, Codable {
    public var cell: String
    public var error: String

    public init(cell: String, error: String) {
        self.cell = cell
        self.error = error
    }
}

public struct OfficeTableShape: Equatable, Sendable {
    public var rows: Int
    public var columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }
}

/// One Word paragraph's structural identity, used to verify a targeted change
/// (paragraph N gained the style/alignment/list) instead of "some paragraph
/// somewhere already has this value".
public struct OfficeWordParagraph: Equatable, Sendable {
    public var text: String
    public var styleID: String?
    public var alignment: String?
    public var numbered: Bool

    public init(text: String, styleID: String?, alignment: String?, numbered: Bool) {
        self.text = text
        self.styleID = styleID
        self.alignment = alignment
        self.numbered = numbered
    }
}

/// A bounded structural snapshot of one saved Office package.
public struct OfficeOutputSnapshot: Equatable, Sendable {
    public var kind: OfficeDocumentKind
    public var sha256: String
    public var entryCount: Int

    // Word
    public var paragraphCount: Int = 0
    public var paragraphs: [OfficeWordParagraph] = []
    public var styleNamesByID: [String: String] = [:]
    public var tables: [OfficeTableShape] = []
    public var wordMediaCount: Int = 0
    public var numberingHasBullet: Bool = false
    public var numberingHasDecimal: Bool = false

    // Excel
    public var sheetNames: [String] = []
    public var sheetRowCounts: [Int] = []
    public var sheetColumnCounts: [Int] = []
    public var hasFrozenPanes: Bool = false
    public var frozenPaneTopLeftCell: String? = nil
    public var hasAutoFilter: Bool = false
    public var numberFormatCodes: [String] = []
    public var cellFormatCodes: [String: String] = [:]
    public var formulasByCell: [String: String] = [:]
    public var errorCells: [OfficeErrorCell] = []
    public var firstSheetColumnA: [String] = []

    // Presentation
    public var slideCount: Int = 0
    public var slideNumbersInOrder: [Int] = []
    public var slideTexts: [String] = []
    public var presentationMediaCount: Int = 0

    public func tableShapes() -> [OfficeTableShape] { tables }

    public static func capture(url: URL) throws -> OfficeOutputSnapshot {
        guard let kind = OfficeDocumentKind(url: url) else {
            throw OfficeDocumentError.unsupportedFormat
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? 0) <= 128 * 1_024 * 1_024 else {
            throw OfficeDocumentError.packageTooLarge
        }
        let package = try OfficeArchive(url: url, maximumEntries: 4_096)
        var snapshot = OfficeOutputSnapshot(kind: kind,
                                            sha256: try Self.digest(url),
                                            entryCount: package.paths.count)
        let xmlLimit: UInt32 = 16 * 1_024 * 1_024
        switch kind {
        case .word:
            let xml = try package.xml(path: "word/document.xml", limit: xmlLimit)
            snapshot.paragraphCount = OfficeXMLScan.count(of: "<w:p ", in: xml) + OfficeXMLScan.count(of: "<w:p>", in: xml)
            snapshot.paragraphs = OfficeXMLScan.wordParagraphs(in: xml)
            snapshot.tables = OfficeXMLScan.wordTables(in: xml)
            snapshot.wordMediaCount = package.paths.filter { $0.hasPrefix("word/media/") }.count
            if let styles = try? package.xml(path: "word/styles.xml", limit: xmlLimit) {
                snapshot.styleNamesByID = OfficeXMLScan.wordStyleNames(in: styles)
            }
            if let numbering = try? package.xml(path: "word/numbering.xml", limit: xmlLimit) {
                snapshot.numberingHasBullet = numbering.contains("w:numFmt w:val=\"bullet\"")
                    || numbering.contains("w:numFmt w:val='bullet'")
                snapshot.numberingHasDecimal = numbering.contains("w:numFmt w:val=\"decimal\"")
                    || numbering.contains("w:numFmt w:val='decimal'")
            }
        case .workbook:
            let shared = (try? SharedStringTable.load(from: package, limit: xmlLimit)) ?? []
            let stylesXML = (try? package.xml(path: "xl/styles.xml", limit: xmlLimit)) ?? ""
            let formatCodesByStyleIndex = OfficeXMLScan.cellFormatCodes(stylesXML: stylesXML)
            let members = package.paths.filter {
                $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") && !$0.contains("/_rels/")
            }.sorted(by: OfficeXMLScan.entryOrder)
            for (index, member) in members.enumerated() {
                guard let xml = try? package.xml(path: member, limit: xmlLimit) else { continue }
                snapshot.sheetNames.append(member)
                snapshot.sheetRowCounts.append(OfficeXMLScan.count(of: "<row ", in: xml))
                snapshot.sheetColumnCounts.append(OfficeXMLScan.maxColumn(in: xml))
                if index == 0 {
                    snapshot.firstSheetColumnA = OfficeXMLScan.columnValues(in: xml, column: "A", shared: shared)
                    snapshot.cellFormatCodes = OfficeXMLScan.cellFormatCodes(in: xml,
                                                                            byStyleIndex: formatCodesByStyleIndex)
                }
                snapshot.formulasByCell.merge(OfficeXMLScan.formulas(in: xml)) { _, new in new }
                snapshot.errorCells.append(contentsOf: OfficeXMLScan.errorCells(in: xml))
                snapshot.hasFrozenPanes = snapshot.hasFrozenPanes || OfficeXMLScan.hasFrozenPane(in: xml)
                if snapshot.frozenPaneTopLeftCell == nil {
                    snapshot.frozenPaneTopLeftCell = OfficeXMLScan.frozenPaneTopLeftCell(in: xml)
                }
                snapshot.hasAutoFilter = snapshot.hasAutoFilter || xml.contains("<autoFilter")
            }
            snapshot.numberFormatCodes = formatCodesByStyleIndex.values.sorted()
        case .presentation:
            let slides = package.paths.filter {
                $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") && !$0.contains("/_rels/")
            }
            snapshot.slideCount = slides.count
            snapshot.presentationMediaCount = package.paths.filter { $0.hasPrefix("ppt/media/") }.count
            snapshot.slideNumbersInOrder = OfficeXMLScan.slideOrder(package: package, limit: xmlLimit)
            var texts: [String] = []
            for member in slides.sorted(by: OfficeXMLScan.entryOrder) {
                guard let xml = try? package.xml(path: member, limit: xmlLimit) else { continue }
                texts.append(contentsOf: OfficeXMLScan.all(pattern: "<a:t>([^<]*)</a:t>", in: xml))
            }
            snapshot.slideTexts = texts
        }
        return snapshot
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What the caller asked the engine to change. Each case mirrors one command
/// in `OfficeEngineCommandCatalog`, so the validator can never claim a
/// different edit than the one that was dispatched.
public enum OfficeOutputExpectation: Equatable, Sendable {
    case wordParagraphStyle(styleName: String)
    case wordList(ordered: Bool)
    case wordAlignment(String)
    case wordTableCount(Int)
    case wordTableShape(rows: Int, columns: Int)
    case wordMediaCountDelta(Int)
    case excelNumberFormat(OfficeNumberFormat, cell: String)
    case excelRowDelta(Int)
    case excelColumnDelta(Int)
    case excelFreezePane(cell: String?)
    case excelAutoFilter(Bool)
    case excelFormula(cell: String, formula: String)
    /// Sort evidence: strong when the pre-sort first-column values are the same
    /// multiset as the saved values; otherwise the saved sheet must at least
    /// have changed while remaining a valid package.
    case excelSortApplied(ascending: Bool)
    case excelErrorCells(atLeast: Int)
    case pptSlideCountDelta(Int)
    case pptSlideOrder([Int])
    case pptText(String)
    case pptMediaCountDelta(Int)
    /// Always satisfied; carries an observed fact (e.g. whether bytes changed).
    case informational(String)

    /// The expectations one validated command promises. `before` is the saved
    /// package captured immediately before the dispatch; nil means the caller
    /// has no baseline and only presence-based checks can run.
    public static func forCommand(_ command: OfficeEngineCommand,
                                  before: OfficeOutputSnapshot?) -> [OfficeOutputExpectation] {
        switch command {
        case .wordStyle(let name):
            return [.wordParagraphStyle(styleName: name)]
        case .wordBulletList:
            return [.wordList(ordered: false)]
        case .wordNumberedList:
            return [.wordList(ordered: true)]
        case .wordAlignment(let alignment):
            return [.wordAlignment(alignment.rawValue)]
        case .wordInsertTable(let rows, let columns):
            return [.wordTableShape(rows: rows, columns: columns)]
        case .excelNumberFormat(let format, let cell):
            return [.excelNumberFormat(format, cell: cell.uppercased())]
        case .excelInsertRows(let count, _):
            return [.excelRowDelta(count)]
        case .excelDeleteRows(let count, _):
            return [.excelRowDelta(-count)]
        case .excelInsertColumns(let count, _):
            return [.excelColumnDelta(count)]
        case .excelDeleteColumns(let count, _):
            return [.excelColumnDelta(-count)]
        case .excelFreezePanes(let cell):
            return [.excelFreezePane(cell: cell?.uppercased())]
        case .excelSort(let ascending, _):
            return [.excelSortApplied(ascending: ascending)]
        case .excelAutoFilter:
            let expected = !(before?.hasAutoFilter ?? false)
            return [.excelAutoFilter(expected)]
        case .excelGoToCell:
            return [.informational("cell cursor moved")]
        case .excelRecalculate:
            return [.informational("recalculation requested")]
        case .pptDuplicateSlide:
            return [.pptSlideCountDelta(1)]
        case .pptMoveSlide(let from, let to):
            guard let before else { return [.informational("slide order change dispatched (no baseline)")] }
            return [.pptSlideOrder(Self.move(before.slideNumbersInOrder, from: from, to: to))]
        case .pptAlignObjects:
            return [.informational("object alignment dispatched; geometry is not independently verifiable from OOXML")]
        }
    }

    /// 1-based from → 1-based to reorder of a slide-number order.
    static func move(_ order: [Int], from: Int, to: Int) -> [Int] {
        var working = order
        guard let index = working.firstIndex(of: from), to >= 1, to <= working.count else { return order }
        let value = working.remove(at: index)
        working.insert(value, at: min(max(to - 1, 0), working.count))
        return working
    }
}

public enum OfficeOutputValidationError: LocalizedError, Equatable, Sendable {
    case expectationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .expectationFailed(let detail): return "Saved document verification failed: \(detail)"
        }
    }
}

public enum OfficeOutputValidator {
    /// Verifies the saved package after an engine edit. Returns one human
    /// fact per satisfied expectation; throws on the first mismatch.
    @discardableResult
    public static func verify(before: OfficeOutputSnapshot?,
                              after: OfficeOutputSnapshot,
                              expectations: [OfficeOutputExpectation]) throws -> [String] {
        var facts: [String] = []
        for expectation in expectations {
            switch expectation {
            case .wordParagraphStyle(let styleName):
                // Target-aware DELTA: the style must now be present on a
                // paragraph that did not have it before. "Some paragraph
                // already has this style" never satisfies the edit.
                let changed = Self.changedParagraphIndex(before: before, after: after) { paragraph in
                    Self.styleMatches(paragraph.styleID, styleName, names: after.styleNamesByID)
                }
                guard let changed else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "no paragraph changed to the '\(styleName)' style")
                }
                facts.append("style=\(styleName)@\(changed)")

            case .wordList(let ordered):
                if ordered, !after.numberingHasDecimal {
                    throw OfficeOutputValidationError.expectationFailed("numbering part has no decimal format")
                }
                if !ordered, !after.numberingHasBullet {
                    throw OfficeOutputValidationError.expectationFailed("numbering part has no bullet format")
                }
                let changed = Self.changedParagraphIndex(before: before, after: after) { $0.numbered }
                guard let changed else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "no paragraph gained a \(ordered ? "numbered" : "bulleted") list")
                }
                facts.append("list=\(ordered ? "ordered" : "bullet")@\(changed)")

            case .wordAlignment(let alignment):
                let expected: String
                switch alignment.lowercased() {
                case "left": expected = "left"
                case "center": expected = "center"
                case "right": expected = "right"
                case "justified", "justify", "both": expected = "both"
                default: expected = alignment.lowercased()
                }
                let changed = Self.changedParagraphIndex(before: before, after: after) { paragraph in
                    paragraph.alignment?.lowercased() == expected
                }
                guard let changed else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "no paragraph changed to alignment \(alignment)")
                }
                facts.append("alignment=\(alignment)@\(changed)")

            case .wordTableCount(let count):
                guard after.tables.count == count else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "expected \(count) table(s), found \(after.tables.count)")
                }
                facts.append("tables=\(count)")

            case .wordTableShape(let rows, let columns):
                // A table insert must ADD a table (delta), not match one that
                // already existed.
                let beforeCount = before?.tables.count ?? 0
                guard after.tables.count == beforeCount + 1, let shape = after.tables.last,
                      shape.rows == rows, shape.columns >= columns else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "expected one new \(rows)×\(columns) table (before \(beforeCount), after \(after.tables.count)"
                            + ", last \(after.tables.last.map { "\($0.rows)×\($0.columns)" } ?? "absent"))")
                }
                facts.append("table=\(shape.rows)x\(shape.columns)")

            case .wordMediaCountDelta(let delta):
                let beforeCount = before?.wordMediaCount ?? 0
                guard after.wordMediaCount - beforeCount >= delta else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "media count did not grow by \(delta) (\(beforeCount) → \(after.wordMediaCount))")
                }
                facts.append("media=\(after.wordMediaCount)")

            case .excelNumberFormat(let format, let cell):
                // Target-aware: only the addressed cell's effective format is
                // checked, and it must have changed to (or away from a
                // non-matching) numeric format. A different cell already
                // carrying the format never satisfies the edit.
                let key = cell.uppercased()
                guard let afterCode = after.cellFormatCodes[key] else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "cell \(key) was not found in the saved first sheet")
                }
                guard Self.formatMatches(code: afterCode, format: format) else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "cell \(key) format '\(afterCode)' is not \(format.rawValue)")
                }
                let beforeCode = before?.cellFormatCodes[key]
                let wasAlreadyMatching = beforeCode.map { Self.formatMatches(code: $0, format: format) } ?? false
                guard !wasAlreadyMatching, beforeCode != afterCode || before == nil else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "cell \(key) already had a matching \(format.rawValue) format; no change was verified")
                }
                facts.append("numberFormat=\(format.rawValue)@\(key)")

            case .excelRowDelta(let delta):
                let beforeRows = before?.sheetRowCounts.first ?? 0
                let afterRows = after.sheetRowCounts.first ?? 0
                guard afterRows - beforeRows == delta else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "row count change \(beforeRows) → \(afterRows), expected +\(delta)")
                }
                facts.append("rows=\(afterRows)")

            case .excelColumnDelta(let delta):
                let beforeColumns = before?.sheetColumnCounts.first ?? 0
                let afterColumns = after.sheetColumnCounts.first ?? 0
                guard afterColumns - beforeColumns == delta else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "column count change \(beforeColumns) → \(afterColumns), expected +\(delta)")
                }
                facts.append("columns=\(afterColumns)")

            case .excelFreezePane(let cell):
                if let cell {
                    let key = cell.uppercased()
                    guard after.hasFrozenPanes, after.frozenPaneTopLeftCell?.uppercased() == key else {
                        throw OfficeOutputValidationError.expectationFailed(
                            "frozen pane top-left is \(after.frozenPaneTopLeftCell ?? "none"), expected \(key)")
                    }
                    facts.append("freezePanes=\(key)")
                } else {
                    guard after.hasFrozenPanes else {
                        throw OfficeOutputValidationError.expectationFailed("no frozen pane in the saved sheet")
                    }
                    facts.append("freezePanes")
                }

            case .excelAutoFilter(let on):
                guard after.hasAutoFilter == on else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "autoFilter is \(after.hasAutoFilter), expected \(on)")
                }
                facts.append("autoFilter=\(on)")

            case .excelFormula(let cell, let formula):
                let saved = after.formulasByCell[cell.uppercased()] ?? after.formulasByCell[cell]
                let normalizedSaved = saved?.trimmingCharacters(in: .whitespaces)
                let normalizedExpected = formula.trimmingCharacters(in: .whitespaces)
                guard normalizedSaved == normalizedExpected else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "cell \(cell) formula is '\(normalizedSaved ?? "none")', expected '\(normalizedExpected)'")
                }
                facts.append("formula=\(cell)")

            case .excelSortApplied(let ascending):
                let beforeValues = before?.firstSheetColumnA ?? []
                let afterValues = after.firstSheetColumnA
                if beforeValues.count >= 2, afterValues.count == beforeValues.count,
                   Set(beforeValues) == Set(afterValues) {
                    // The active range starts at column A: the reorder is fully
                    // verifiable from the saved values.
                    let comparable = afterValues.map(OfficeXMLScan.sortKey)
                    let ordered = ascending
                        ? zip(comparable, comparable.dropFirst()).allSatisfy { $0 <= $1 }
                        : zip(comparable, comparable.dropFirst()).allSatisfy { $0 >= $1 }
                    guard ordered else {
                        throw OfficeOutputValidationError.expectationFailed(
                            "column A is not \(ascending ? "ascending" : "descending"): \(afterValues)")
                    }
                    facts.append("sorted=A:\(ascending ? "asc" : "desc")")
                } else {
                    // The selection may not start at column A; we can still
                    // prove the saved sheet changed, and never claim more.
                    let changed = before.map { $0.sha256 != after.sha256 } ?? true
                    guard changed else {
                        throw OfficeOutputValidationError.expectationFailed(
                            "the saved workbook did not change after the sort")
                    }
                    facts.append("sorted=sheetChanged")
                }

            case .pptSlideOrder(let expected):
                let actual = after.slideNumbersInOrder
                guard !expected.isEmpty, actual == expected else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "slide order is \(actual), expected \(expected)")
                }
                facts.append("slideOrder=\(actual.map(String.init).joined(separator: ","))")

            case .informational(let fact):
                facts.append(fact)

            case .excelErrorCells(let atLeast):
                guard after.errorCells.count >= atLeast else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "expected at least \(atLeast) error cell(s), found \(after.errorCells.count)")
                }
                facts.append("errorCells=\(after.errorCells.count)")

            case .pptSlideCountDelta(let delta):
                let beforeCount = before?.slideCount ?? 0
                guard after.slideCount - beforeCount == delta else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "slide count change \(beforeCount) → \(after.slideCount), expected +\(delta)")
                }
                facts.append("slides=\(after.slideCount)")

            case .pptText(let text):
                guard after.slideTexts.contains(where: { $0.contains(text) }) else {
                    throw OfficeOutputValidationError.expectationFailed("text '\(text)' not found in slides")
                }
                facts.append("text=\(text)")

            case .pptMediaCountDelta(let delta):
                let beforeCount = before?.presentationMediaCount ?? 0
                guard after.presentationMediaCount - beforeCount >= delta else {
                    throw OfficeOutputValidationError.expectationFailed(
                        "presentation media count did not grow by \(delta) (\(beforeCount) → \(after.presentationMediaCount))")
                }
                facts.append("media=\(after.presentationMediaCount)")
            }
        }
        return facts
    }

    /// First paragraph index that matches AFTER and did not match before.
    /// Handles a `before` with a different paragraph count by treating missing
    /// indices as "did not match".
    static func changedParagraphIndex(before: OfficeOutputSnapshot?,
                                      after: OfficeOutputSnapshot,
                                      matches: (OfficeWordParagraph) -> Bool) -> Int? {
        let beforeParagraphs = before?.paragraphs ?? []
        return after.paragraphs.indices.first { index in
            guard matches(after.paragraphs[index]) else { return false }
            if beforeParagraphs.indices.contains(index), matches(beforeParagraphs[index]) { return false }
            return true
        }
    }

    static func styleMatches(_ styleID: String?, _ styleName: String,
                             names: [String: String]) -> Bool {
        guard let styleID, !styleID.isEmpty else { return false }
        let resolved = names[styleID.lowercased()] ?? styleID
        return normalizedStyle(resolved) == normalizedStyle(styleName)
    }

    private static func normalizedStyle(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }

    /// Whether a saved format code carries the marker of the requested format.
    /// `decimal`/`standard`/step formats fall back to a style delta check.
    static func formatMatches(code: String, format: OfficeNumberFormat) -> Bool {
        let upper = code.uppercased()
        switch format {
        case .percent: return upper.contains("%")
        case .currency: return ["$", "€", "£", "¥", "USD", "CNY", "EUR"].contains { upper.contains($0) }
        case .date:
            return (upper.contains("YY") || upper.contains("DD") || upper.contains("M/D"))
                && !upper.contains("%")
        case .time: return upper.contains(":") || upper.contains("HH") || upper.contains("SS")
        case .scientific: return upper.contains("E+") || upper.contains("E-")
        case .thousands: return upper.contains("#,##")
        case .standard: return upper == "GENERAL" || upper == "STANDARD"
        case .decimal, .increaseDecimals, .decreaseDecimals:
            return upper != "GENERAL" && !upper.contains("%")
        }
    }
}

// MARK: - Package-level image replacement (no engine ChangePicture exists)

public struct OfficeImageReplacement: Equatable, Sendable {
    /// Exact package member (e.g. `ppt/media/image2.png`) or `#N` for the
    /// N-th (1-based) image member in stable path order.
    public var target: String
    public var imageData: Data

    public init(target: String, imageData: Data) {
        self.target = target
        self.imageData = imageData
    }
}

public enum OfficePackageEdits {
    public enum ImageError: LocalizedError, Equatable {
        case unknownTarget(String)
        case unsupportedImageFormat
        case extensionMismatch(String, String)

        public var errorDescription: String? {
            switch self {
            case .unknownTarget(let target):
                return "No image member matches '\(target)' in this package"
            case .unsupportedImageFormat:
                return "Replacement must be PNG, JPEG or GIF bytes"
            case .extensionMismatch(let member, let format):
                return "Replacement \(format) bytes do not match the existing \(member) member; convert the image first"
            }
        }
    }

    /// Replaces one existing picture's bytes in place, preserving the drawing,
    /// relationship and layout (the picture shape keeps pointing at the same
    /// member). The package is rewritten atomically and reopened to prove the
    /// new digest; never used to fake a screenshot edit.
    @discardableResult
    public static func replaceImage(url: URL,
                                    _ replacement: OfficeImageReplacement,
                                    expectedSHA256: String? = nil) throws -> OfficeOutputSnapshot {
        let current = try OfficeOutputSnapshot.capture(url: url)
        if let expectedSHA256, current.sha256 != expectedSHA256.lowercased() {
            throw OfficeDocumentError.revisionConflict
        }
        let package = try OfficeArchive(url: url, maximumEntries: 4_096)
        let mediaEntries = package.paths.filter {
            ($0.hasPrefix("word/media/") || $0.hasPrefix("ppt/media/") || $0.hasPrefix("xl/media/"))
                && ["png", "jpg", "jpeg", "gif"].contains(($0 as NSString).pathExtension.lowercased())
        }.sorted(by: OfficeXMLScan.entryOrder)
        let member: String
        if replacement.target.hasPrefix("#") {
            guard let index = Int(replacement.target.dropFirst()), index >= 1, index <= mediaEntries.count else {
                throw ImageError.unknownTarget(replacement.target)
            }
            member = mediaEntries[index - 1]
        } else {
            guard mediaEntries.contains(replacement.target) else {
                throw ImageError.unknownTarget(replacement.target)
            }
            member = replacement.target
        }
        guard let format = Self.imageFormat(of: replacement.imageData) else {
            throw ImageError.unsupportedImageFormat
        }
        let memberExtension = (member as NSString).pathExtension.lowercased()
        let expectedExtensions = format == "jpeg" ? ["jpg", "jpeg"] : [format]
        guard expectedExtensions.contains(memberExtension) else {
            throw ImageError.extensionMismatch(member, format)
        }
        let newDigest = Self.digest(replacement.imageData)
        let memberCopy = member
        try package.writeCopy(to: url,
                              replacements: [member: replacement.imageData],
                              maximumMemberBytes: 64 * 1_024 * 1_024,
                              maximumTotalBytes: 256 * 1_024 * 1_024,
                              verify: { candidate in
                                  let reopened = try OfficeArchive(url: candidate, maximumEntries: 4_096)
                                  let bytes = try reopened.data(path: memberCopy, limit: 64 * 1_024 * 1_024)
                                  guard Self.digest(bytes) == newDigest else {
                                      throw OfficeDocumentError.revisionConflict
                                  }
                              })
        return try OfficeOutputSnapshot.capture(url: url)
    }

    static func imageFormat(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        return nil
    }

    private static func digest(_ data: Data) -> String {
        var hash = SHA256()
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Bounded XML scanning helpers

enum OfficeXMLScan {
    static func count(of needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var total = 0
        var search = source.startIndex..<source.endIndex
        while let range = source.range(of: needle, range: search) {
            total += 1
            search = range.upperBound..<source.endIndex
        }
        return total
    }

    static func all(pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        }
    }

    static func entryOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = trailingNumber(lhs) ?? 0
        let right = trailingNumber(rhs) ?? 0
        return left == right ? lhs < rhs : left < right
    }

    static func trailingNumber(_ path: String) -> Int? {
        let stem = (path as NSString).deletingPathExtension
        let digits = stem.reversed().prefix(while: \.isNumber).reversed()
        return Int(String(digits))
    }

    /// Paragraph tables: rows per table and the widest row's cell count.
    static func wordTables(in xml: String) -> [OfficeTableShape] {
        let tables = xml.components(separatedBy: "<w:tbl>").dropFirst()
        return tables.map { table in
            let rows = table.components(separatedBy: "<w:tr ").dropFirst()
                + table.components(separatedBy: "<w:tr>").dropFirst()
            let rowCount = max(count(of: "<w:tr", in: table), 1)
            var columns = 0
            for row in rows {
                let cells = count(of: "<w:tc", in: row)
                columns = max(columns, cells)
            }
            if columns == 0 { columns = count(of: "<w:tc", in: table) / max(rowCount, 1) }
            return OfficeTableShape(rows: rowCount, columns: columns)
        }
    }

    static func wordStyleNames(in stylesXML: String) -> [String: String] {
        var names: [String: String] = [:]
        for block in stylesXML.components(separatedBy: "<w:style ").dropFirst() {
            guard let id = all(pattern: "w:styleId=\"([^\"]+)\"", in: block).first else { continue }
            if let name = all(pattern: "<w:name w:val=\"([^\"]+)\"", in: block).first {
                names[id.lowercased()] = name
            }
        }
        return names
    }

    static func maxColumn(in sheetXML: String) -> Int {
        var maximum = 0
        for reference in all(pattern: "<c r=\"([A-Z]{1,3})[0-9]+\"", in: sheetXML) {
            maximum = max(maximum, columnIndex(reference))
        }
        return maximum
    }

    static func columnIndex(_ letters: String) -> Int {
        var result = 0
        for scalar in letters.uppercased().unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            result = result * 26 + Int(scalar.value - 64)
        }
        return result
    }

    static func columnValues(in sheetXML: String, column: String, shared: [String]) -> [String] {
        let target = column.uppercased()
        var values: [String] = []
        guard let regex = try? NSRegularExpression(
            pattern: "<c r=\"(\(target)[0-9]+)\"([^>]*)>(.*?)</c>", options: [.dotMatchesLineSeparators]) else {
            return values
        }
        let range = NSRange(sheetXML.startIndex..<sheetXML.endIndex, in: sheetXML)
        for match in regex.matches(in: sheetXML, options: [], range: range) {
            guard let bodyRange = Range(match.range(at: 3), in: sheetXML),
                  let attributesRange = Range(match.range(at: 2), in: sheetXML) else { continue }
            let body = String(sheetXML[bodyRange])
            let attributes = String(sheetXML[attributesRange])
            if attributes.contains("t=\"s\""), let raw = all(pattern: "<v>([0-9]+)</v>", in: body).first,
               let index = Int(raw), index >= 0, index < shared.count {
                values.append(shared[index])
            } else if let raw = all(pattern: "<v>([^<]*)</v>", in: body).first {
                values.append(raw)
            } else if let inline = all(pattern: "<t[^>]*>([^<]*)</t>", in: body).first {
                values.append(inline)
            }
        }
        return values
    }

    static func formulas(in sheetXML: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: "<c r=\"([A-Z]{1,3}[0-9]+)\"[^>]*>(.*?)</c>", options: [.dotMatchesLineSeparators]) else {
            return result
        }
        let range = NSRange(sheetXML.startIndex..<sheetXML.endIndex, in: sheetXML)
        for match in regex.matches(in: sheetXML, options: [], range: range) {
            guard let cellRange = Range(match.range(at: 1), in: sheetXML),
                  let bodyRange = Range(match.range(at: 2), in: sheetXML) else { continue }
            let body = String(sheetXML[bodyRange])
            if let formula = all(pattern: "<f[^>]*>([^<]*)</f>", in: body).first {
                result[String(sheetXML[cellRange]).uppercased()] = formula
            }
        }
        return result
    }

    static func errorCells(in sheetXML: String) -> [OfficeErrorCell] {
        var result: [OfficeErrorCell] = []
        guard let regex = try? NSRegularExpression(
            pattern: "<c r=\"([A-Z]{1,3}[0-9]+)\"([^>]*)>(.*?)</c>", options: [.dotMatchesLineSeparators]) else {
            return result
        }
        let range = NSRange(sheetXML.startIndex..<sheetXML.endIndex, in: sheetXML)
        for match in regex.matches(in: sheetXML, options: [], range: range) {
            guard let cellRange = Range(match.range(at: 1), in: sheetXML),
                  let attributesRange = Range(match.range(at: 2), in: sheetXML),
                  let bodyRange = Range(match.range(at: 3), in: sheetXML) else { continue }
            let attributes = String(sheetXML[attributesRange])
            guard attributes.contains("t=\"e\"") else { continue }
            let body = String(sheetXML[bodyRange])
            let code = all(pattern: "<v>([^<]*)</v>", in: body).first ?? "#ERROR"
            result.append(OfficeErrorCell(cell: String(sheetXML[cellRange]).uppercased(), error: code))
        }
        return result
    }

    static func hasFrozenPane(in sheetXML: String) -> Bool {
        guard let range = sheetXML.range(of: "<pane") else { return false }
        let tail = sheetXML[range.lowerBound...].prefix(400)
        return tail.contains("state=\"frozen\"")
    }

    /// Presentation slide order (1-based slide numbers) from `sldIdLst` and
    /// the presentation relationships.
    static func slideOrder(package: OfficeArchive, limit: UInt32) -> [Int] {
        guard let presentation = try? package.xml(path: "ppt/presentation.xml", limit: limit),
              let rels = try? package.xml(path: "ppt/_rels/presentation.xml.rels", limit: limit) else {
            return []
        }
        var targetByRelationship: [String: String] = [:]
        guard let relRegex = try? NSRegularExpression(
            pattern: "<Relationship[^>]*Id=\"([^\"]+)\"[^>]*Target=\"([^\"]+)\"", options: []) else { return [] }
        let relRange = NSRange(rels.startIndex..<rels.endIndex, in: rels)
        for match in relRegex.matches(in: rels, options: [], range: relRange) {
            guard let idRange = Range(match.range(at: 1), in: rels),
                  let targetRange = Range(match.range(at: 2), in: rels) else { continue }
            targetByRelationship[String(rels[idRange])] = String(rels[targetRange])
        }
        let orderedIDs = all(pattern: "<p:sldId[^>]*r:id=\"([^\"]+)\"", in: presentation)
        return orderedIDs.compactMap { id in
            guard let target = targetByRelationship[id] else { return nil }
            return trailingNumber(target)
        }
    }

    /// Comparison key for a saved cell value: numerics compare numerically,
    /// text compares case-insensitively.
    static func sortKey(_ value: String) -> String {
        if let number = Double(value) {
            return String(format: "%020.6f", number)
        }
        return value.lowercased()
    }

    // MARK: Target-aware Word structure

    static func wordParagraphs(in xml: String) -> [OfficeWordParagraph] {
        guard let regex = try? NSRegularExpression(
            pattern: "<w:p(?: [^>]*)?>(.*?)</w:p>", options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        var paragraphs: [OfficeWordParagraph] = []
        for match in regex.matches(in: xml, options: [], range: range) {
            guard let bodyRange = Range(match.range(at: 1), in: xml) else { continue }
            let block = String(xml[bodyRange])
            let text = all(pattern: "<w:t[^>]*>([^<]*)</w:t>", in: block).joined()
            let styleID = all(pattern: "<w:pStyle[^>]*w:val=\"([^\"]+)\"", in: block).first
            let alignment = all(pattern: "<w:jc[^>]*w:val=\"([^\"]+)\"", in: block).first
            let numbered = block.contains("<w:numPr")
            paragraphs.append(OfficeWordParagraph(text: text, styleID: styleID,
                                                  alignment: alignment, numbered: numbered))
        }
        return paragraphs
    }

    // MARK: Target-aware Excel cell formats

    /// Effective number-format code per style index from `xl/styles.xml`.
    static func cellFormatCodes(stylesXML: String) -> [Int: String] {
        var custom: [Int: String] = [:]
        guard let numFmtRegex = try? NSRegularExpression(
            pattern: "<numFmt[^>]*numFmtId=\"([0-9]+)\"[^>]*formatCode=\"([^\"]*)\"", options: []) else {
            return [:]
        }
        let range = NSRange(stylesXML.startIndex..<stylesXML.endIndex, in: stylesXML)
        for match in numFmtRegex.matches(in: stylesXML, options: [], range: range) {
            guard let idRange = Range(match.range(at: 1), in: stylesXML),
                  let codeRange = Range(match.range(at: 2), in: stylesXML),
                  let id = Int(stylesXML[idRange]) else { continue }
            custom[id] = unescapeXMLAttribute(String(stylesXML[codeRange]))
        }
        // `<cellXfs count="N">` lists xf entries in style-index order.
        guard let xfsRange = stylesXML.range(of: "<cellXfs") else { return [:] }
        let tail = stylesXML[xfsRange.lowerBound...]
        guard let end = tail.range(of: "</cellXfs>") else { return [:] }
        let xfs = String(tail[..<end.lowerBound])
        var result: [Int: String] = [:]
        var index = 0
        for block in xfs.components(separatedBy: "<xf ").dropFirst() {
            let numFmtId = all(pattern: "numFmtId=\"([0-9]+)\"", in: block).first.flatMap(Int.init) ?? 0
            result[index] = custom[numFmtId] ?? builtinFormatCode(numFmtId)
            index += 1
        }
        return result
    }

    /// Cell A1 → effective number-format code for the cells of one sheet.
    static func cellFormatCodes(in sheetXML: String,
                                byStyleIndex: [Int: String]) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<c r=\"([A-Z]{1,3}[0-9]+)\"([^>]*)", options: []) else { return [:] }
        let range = NSRange(sheetXML.startIndex..<sheetXML.endIndex, in: sheetXML)
        var result: [String: String] = [:]
        for match in regex.matches(in: sheetXML, options: [], range: range) {
            guard let cellRange = Range(match.range(at: 1), in: sheetXML),
                  let attributeRange = Range(match.range(at: 2), in: sheetXML) else { continue }
            let attributes = String(sheetXML[attributeRange])
            let styleIndex = all(pattern: "s=\"([0-9]+)\"", in: attributes).first.flatMap(Int.init) ?? 0
            result[String(sheetXML[cellRange]).uppercased()] = byStyleIndex[styleIndex] ?? "General"
        }
        return result
    }

    static func frozenPaneTopLeftCell(in sheetXML: String) -> String? {
        guard let paneRange = sheetXML.range(of: "<pane") else { return nil }
        let tag = sheetXML[paneRange.lowerBound...].prefix(400)
        guard tag.contains("state=\"frozen\"") else { return nil }
        return all(pattern: "topLeftCell=\"([^\"]+)\"", in: String(tag)).first
    }

    /// Representative codes for the most common OOXML builtin numFmtId values.
    static func builtinFormatCode(_ id: Int) -> String {
        switch id {
        case 0: return "General"
        case 1: return "0"
        case 2: return "0.00"
        case 3: return "#,##0"
        case 4: return "#,##0.00"
        case 5, 6, 7, 8: return "$#,##0.00"
        case 9: return "0%"
        case 10: return "0.00%"
        case 11: return "0.00E+00"
        case 12, 13: return "# ?/?"
        case 14: return "mm-dd-yy"
        case 15, 16, 17: return "d-mmm-yy"
        case 18, 19, 20, 21: return "h:mm"
        case 22: return "m/d/yy h:mm"
        case 37, 38, 39, 40: return "$#,##0.00"
        case 45, 46, 47: return "mm:ss"
        case 48: return "##0.0E+0"
        case 49: return "@"
        default: return "General"
        }
    }

    static func unescapeXMLAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

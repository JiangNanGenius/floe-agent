// FloeDocuments — bounded native Office Open XML inspection and editing.

import Foundation
import Crypto
import ZIPFoundation
import FloeCore

public enum OfficeDocumentKind: String, Codable, Sendable, CaseIterable {
    case word = "docx"
    case workbook = "xlsx"
    case presentation = "pptx"

    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

/// A user- or model-editable text surface inside an OOXML package. The stable
/// identifier addresses an archive member and an ordinal/cell reference; it
/// never contains raw document content.
public struct OfficeEditableField: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var section: String
    public var label: String
    public var text: String

    public init(id: String, section: String, label: String, text: String) {
        self.id = id
        self.section = section
        self.label = label
        self.text = text
    }
}

/// Tab visibility of one workbook sheet, exactly the three values
/// `xl/workbook.xml` declares. `visible` is the default when the attribute is
/// absent; it is not the only state a sheet can carry.
public enum OfficeSheetVisibility: String, Codable, Sendable, CaseIterable, Equatable {
    case visible
    case hidden
    case veryHidden
}

/// One hidden column span as a worksheet's `<cols>` element declares it:
/// 1-based and inclusive, exactly the OOXML `min`/`max` attributes. Spans are
/// kept as spans (never expanded) so a whole-sheet hidden column costs one
/// entry.
public struct OfficeWorkbookColumnSpan: Codable, Sendable, Equatable, Hashable {
    public var first: Int
    public var last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public func contains(_ column: Int) -> Bool {
        column >= first && column <= last
    }
}

/// Read-only preview metadata for one workbook sheet, in the workbook's own
/// tab order. It never carries cell content; `section` is the same stable key
/// `OfficeDocumentSnapshot.fields` already uses for the worksheet part, so
/// existing field identifiers and sections are unchanged.
public struct OfficeWorkbookSheetPreview: Codable, Sendable, Equatable {
    /// The tab's display name from `xl/workbook.xml`.
    public var name: String
    /// The tab's visibility state (`visible` when the attribute is absent).
    public var visibility: OfficeSheetVisibility
    /// The resolved worksheet part path, e.g. `xl/worksheets/sheet2.xml`.
    public var target: String
    /// The stable section key for `target` in the snapshot's fields
    /// (`"Sheet 2"`), derived from the part path exactly as `inspect` does.
    public var section: String
    /// 1-based hidden row numbers declared by the worksheet, ascending and
    /// deduplicated. Bounded; see `hiddenRowsTruncated`.
    public var hiddenRows: [Int]
    /// 1-based hidden column spans declared by the worksheet's `<cols>`.
    /// Bounded; see `hiddenColumnsTruncated`.
    public var hiddenColumnSpans: [OfficeWorkbookColumnSpan]
    /// True when the worksheet declared more hidden rows than the bounded
    /// analysis keeps, or a hidden row could not be located. The row list is
    /// then incomplete and the bounded summary must not filter with it.
    public var hiddenRowsTruncated: Bool
    /// True when the worksheet declared more hidden column spans than the
    /// bounded analysis keeps, or a hidden span was malformed. The span list
    /// is then incomplete and the bounded summary must not filter with it.
    public var hiddenColumnsTruncated: Bool

    public init(
        name: String,
        visibility: OfficeSheetVisibility,
        target: String,
        section: String,
        hiddenRows: [Int] = [],
        hiddenColumnSpans: [OfficeWorkbookColumnSpan] = [],
        hiddenRowsTruncated: Bool = false,
        hiddenColumnsTruncated: Bool = false
    ) {
        self.name = name
        self.visibility = visibility
        self.target = target
        self.section = section
        self.hiddenRows = hiddenRows
        self.hiddenColumnSpans = hiddenColumnSpans
        self.hiddenRowsTruncated = hiddenRowsTruncated
        self.hiddenColumnsTruncated = hiddenColumnsTruncated
    }

    public var isVisible: Bool { visibility == .visible }
}

/// Backward-compatible, read-only workbook preview metadata.
///
/// It is present only when the package resolves consistently: `xl/workbook.xml`
/// declares its sheets with resolvable worksheet relationships and every
/// worksheet part the inspector reads is referenced by exactly one sheet. A
/// missing, duplicated or unsupported relationship leaves this `nil`, and a
/// caller must then keep the existing native preview instead of guessing a
/// sheet. It is optional on `OfficeDocumentSnapshot`, so every older caller
/// and every Codable fixture without it still decodes unchanged.
public struct OfficeWorkbookPreviewMetadata: Codable, Sendable, Equatable {
    /// Sheets in the workbook's actual tab order. This is the order of the
    /// `<sheet>` elements, which is not necessarily the worksheet part number
    /// (a tab may reference `sheet3.xml` before `sheet1.xml`).
    public var sheets: [OfficeWorkbookSheetPreview]
    /// True when `inspect` kept fewer fields than the package declares, so no
    /// worksheet's cell list is complete and no emptiness can be proven.
    public var fieldsTruncated: Bool

    public init(sheets: [OfficeWorkbookSheetPreview], fieldsTruncated: Bool = false) {
        self.sheets = sheets
        self.fieldsTruncated = fieldsTruncated
    }
}

public struct OfficeDocumentSnapshot: Codable, Sendable, Equatable {
    public var kind: OfficeDocumentKind
    public var fields: [OfficeEditableField]
    public var packageEntries: Int
    public var packageBytes: Int64
    public var sha256: String?
    /// Read-only workbook tab/visibility preview metadata. `nil` for Word and
    /// PowerPoint, and for a workbook whose metadata cannot be resolved
    /// consistently. Optional so existing callers and old Codable fixtures
    /// remain compatible.
    public var workbookPreview: OfficeWorkbookPreviewMetadata?

    public init(
        kind: OfficeDocumentKind,
        fields: [OfficeEditableField],
        packageEntries: Int,
        packageBytes: Int64,
        sha256: String? = nil,
        workbookPreview: OfficeWorkbookPreviewMetadata? = nil
    ) {
        self.kind = kind
        self.fields = fields
        self.packageEntries = packageEntries
        self.packageBytes = packageBytes
        self.sha256 = sha256
        self.workbookPreview = workbookPreview
    }
}

public enum OfficeDocumentError: LocalizedError, Sendable {
    case unsupportedFormat
    case packageTooLarge
    case tooManyEntries
    case unsafeEntry(String)
    case oversizedEntry(String)
    case missingEntry(String)
    case invalidXML(String)
    case unknownField(String)
    case emptyDocument
    case revisionConflict
    case verificationFailed
    case invalidContent(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Only .docx, .xlsx, and .pptx are supported"
        case .packageTooLarge: "Office document exceeds the 128 MiB safety limit"
        case .tooManyEntries: "Office package contains too many archive members"
        case .unsafeEntry(let path): "Office package contains an unsafe path: \(path)"
        case .oversizedEntry(let path): "Office package member is too large: \(path)"
        case .missingEntry(let path): "Office package is missing \(path)"
        case .invalidXML(let path): "Office package contains invalid XML in \(path)"
        case .unknownField(let field): "Office edit refers to an unknown field: \(field)"
        case .revisionConflict: "Office document changed since it was read. Reload before saving."
        case .verificationFailed: "Office edits did not survive reopening; the original file was preserved."
        case .emptyDocument: "This document has no editable text fields. It may contain only images, drawings, form controls or protected content; document.office.updateText cannot change it."
        case .invalidContent(let detail): "Office content cannot be generated safely: \(detail)"
        }
    }
}

/// Native OOXML text/cell service shared by model tools and the manual editor.
/// It rewrites only selected XML members and streams every other archive member
/// unchanged into a new atomic package, preserving themes, media and relations.
public enum OfficeDocumentService {
    private static let updateLock = NSLock()
    private static let maximumArchiveBytes: Int64 = 128 * 1_024 * 1_024
    private static let maximumEntries = 4_096
    private static let maximumMemberBytes: UInt32 = 64 * 1_024 * 1_024
    private static let maximumXMLBytes: UInt32 = 16 * 1_024 * 1_024
    private static let maximumFields = 20_000
    private static let maximumCreatedCellsPerUpdate = 2_000

    public static func inspect(url: URL) throws -> OfficeDocumentSnapshot {
        guard let kind = OfficeDocumentKind(url: url) else {
            throw OfficeDocumentError.unsupportedFormat
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw OfficeDocumentError.unsupportedFormat }
        guard Int64(values.fileSize ?? 0) <= maximumArchiveBytes else {
            throw OfficeDocumentError.packageTooLarge
        }
        let sourceDigest = try digest(url)
        let package = try OfficeArchive(url: url, maximumEntries: maximumEntries)
        var fields: [OfficeEditableField] = []
        var workbookPreview: OfficeWorkbookPreviewMetadata?
        switch kind {
        case .word:
            let members = package.paths.filter {
                $0 == "word/document.xml"
                    || $0.hasPrefix("word/header") && $0.hasSuffix(".xml")
                    || $0.hasPrefix("word/footer") && $0.hasSuffix(".xml")
            }.sorted(by: OfficePathOrder.less)
            guard members.contains("word/document.xml") else {
                throw OfficeDocumentError.missingEntry("word/document.xml")
            }
            for member in members {
                let xml = try package.xml(path: member, limit: maximumXMLBytes)
                fields.append(contentsOf: XMLTextCodec.fields(
                    source: xml,
                    entry: member,
                    paragraphTag: "w:p",
                    textTag: "w:t",
                    section: member == "word/document.xml" ? "Document" : member
                ))
            }
        case .presentation:
            let members = package.paths.filter {
                ($0.hasPrefix("ppt/slides/slide") || $0.hasPrefix("ppt/notesSlides/notesSlide"))
                    && $0.hasSuffix(".xml")
                    && !$0.contains("/_rels/")
            }.sorted(by: OfficePathOrder.less)
            guard members.contains(where: { $0.hasPrefix("ppt/slides/slide") }) else {
                throw OfficeDocumentError.missingEntry("ppt/slides/slide1.xml")
            }
            for member in members {
                let xml = try package.xml(path: member, limit: maximumXMLBytes)
                let section = member.contains("notesSlides")
                    ? "Notes \(OfficePathOrder.trailingNumber(member) ?? 0)"
                    : "Slide \(OfficePathOrder.trailingNumber(member) ?? 0)"
                fields.append(contentsOf: XMLTextCodec.fields(
                    source: xml,
                    entry: member,
                    paragraphTag: "a:p",
                    textTag: "a:t",
                    section: section
                ))
            }
        case .workbook:
            let shared = try SharedStringTable.load(from: package, limit: maximumXMLBytes)
            let members = package.paths.filter {
                $0.hasPrefix("xl/worksheets/sheet")
                    && $0.hasSuffix(".xml")
                    && !$0.contains("/_rels/")
            }.sorted(by: OfficePathOrder.less)
            guard !members.isEmpty else {
                throw OfficeDocumentError.missingEntry("xl/worksheets/sheet1.xml")
            }
            // The tab metadata is best-effort and never throws: a package whose
            // workbook part or relationships do not resolve keeps its fields
            // unchanged and simply carries no preview metadata, so every
            // existing reader/edit path behaves exactly as before.
            let shape = XLSXWorkbookPreviewReader.sheets(
                package: package, worksheetMembers: members, limit: maximumXMLBytes
            )
            var hiddenByMember: [String: XLSXHiddenLayout] = [:]
            for member in members {
                let xml = try package.xml(path: member, limit: maximumXMLBytes)
                fields.append(contentsOf: XLSXCellCodec.fields(
                    source: xml,
                    entry: member,
                    sharedStrings: shared,
                    section: "Sheet \(OfficePathOrder.trailingNumber(member) ?? 0)"
                ))
                hiddenByMember[member] = XLSXCellCodec.hiddenLayout(source: xml)
            }
            workbookPreview = shape.map { sheets in
                OfficeWorkbookPreviewMetadata(
                    sheets: sheets.map { sheet in
                        let hidden = hiddenByMember[sheet.target] ?? XLSXHiddenLayout()
                        return OfficeWorkbookSheetPreview(
                            name: sheet.name,
                            visibility: sheet.visibility,
                            target: sheet.target,
                            section: sheet.section,
                            hiddenRows: hidden.rows,
                            hiddenColumnSpans: hidden.columnSpans,
                            hiddenRowsTruncated: hidden.rowsTruncated,
                            hiddenColumnsTruncated: hidden.columnsTruncated
                        )
                    },
                    fieldsTruncated: fields.count > maximumFields
                )
            }
        }
        if fields.count > maximumFields {
            fields = Array(fields.prefix(maximumFields))
        }
        guard try digest(url) == sourceDigest else { throw OfficeDocumentError.revisionConflict }
        return OfficeDocumentSnapshot(
            kind: kind,
            fields: fields,
            packageEntries: package.paths.count,
            packageBytes: Int64(values.fileSize ?? 0),
            sha256: sourceDigest,
            workbookPreview: workbookPreview
        )
    }

    /// Applies exact field updates. Unknown/stale IDs fail closed so a model or
    /// UI cannot accidentally edit a different package revision.
    ///
    /// With `allowsWorkbookCellCreation` set on a workbook, a canonical
    /// `"<worksheet part>|c|<CELL>"` key for a cell that does not exist yet
    /// creates that cell inside the package's own worksheet instead of
    /// refusing: a strict finite decimal becomes a real numeric `<v>` cell
    /// (never the inline text a formula such as `SUM` would ignore), a
    /// `=`-prefixed value becomes a formula `<f>` with no fabricated cached
    /// result, and digit-free text becomes preserved inline text — all through
    /// the same cell writer the existing-cell rewrite uses. The opt-in is
    /// bounded and fails closed otherwise: a worksheet part that the
    /// workbook's own sheet relationships do not resolve, references outside
    /// the canonical `A1…XFD1048576` bounds, numeric look-alikes that are not
    /// strict decimals (for example "007", ".5", "1,000", "0x1p3", "inf",
    /// "nan"), empty, oversized or XML-illegal values, batches above the
    /// creation limit, and worksheets whose `<sheetData>`, `<row>` or `<c>`
    /// structure this writer cannot preserve (positional, duplicate,
    /// descending or non-canonical references). Without the opt-in — and for
    /// Word and PowerPoint with it — the unknown-field refusal and every other
    /// behavior are exactly as before. The reopen verification still reads
    /// back every written value, created cells included, and installs nothing
    /// unless the round-trip matches the requested text.
    @discardableResult
    public static func update(
        sourceURL: URL,
        outputURL: URL? = nil,
        updates: [String: String],
        expectedSHA256: String? = nil,
        allowsWorkbookCellCreation: Bool = false
    ) throws -> OfficeDocumentSnapshot {
        updateLock.lock()
        defer { updateLock.unlock() }
        let current = try inspect(url: sourceURL)
        if let expectedSHA256, current.sha256 != expectedSHA256.lowercased() {
            throw OfficeDocumentError.revisionConflict
        }
        let known = Set(current.fields.map(\.id))
        let unknownKeys = updates.keys.filter { !known.contains($0) }.sorted()
        if let unknown = unknownKeys.first, !(allowsWorkbookCellCreation && current.kind == .workbook) {
            throw OfficeDocumentError.unknownField(unknown)
        }
        guard !updates.isEmpty else { return current }
        let destination = outputURL ?? sourceURL
        let package = try OfficeArchive(url: sourceURL, maximumEntries: maximumEntries)
        var creations: [String: [XLSXCellCodec.CellCreation]] = [:]
        if !unknownKeys.isEmpty {
            creations = try plannedWorkbookCellCreations(unknownKeys, updates: updates, package: package)
        }
        var rewritten: [String: Data] = [:]
        let entries = Set(updates.keys.compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) })
        for entry in entries {
            let source = try package.xml(path: entry, limit: maximumXMLBytes)
            let result: String
            switch current.kind {
            case .word:
                result = try XMLTextCodec.rewrite(
                    source: source, entry: entry, paragraphTag: "w:p", textTag: "w:t", updates: updates
                )
            case .presentation:
                result = try XMLTextCodec.rewrite(
                    source: source, entry: entry, paragraphTag: "a:p", textTag: "a:t", updates: updates
                )
            case .workbook:
                var workbookXML = try XLSXCellCodec.rewrite(source: source, entry: entry, updates: updates)
                if let entryCreations = creations[entry] {
                    workbookXML = try XLSXCellCodec.applyCreations(
                        source: workbookXML, entry: entry, creations: entryCreations
                    )
                }
                result = workbookXML
            }
            rewritten[entry] = Data(result.utf8)
        }
        try package.writeCopy(
            to: destination,
            replacements: rewritten,
            maximumMemberBytes: maximumMemberBytes,
            maximumTotalBytes: 256 * 1_024 * 1_024,
            verify: { staged in
                let reopened = try inspect(url: staged)
                let fields = Dictionary(uniqueKeysWithValues: reopened.fields.map { ($0.id, $0.text) })
                guard updates.allSatisfy({ (fields[$0.key] ?? "") == $0.value }) else {
                    throw OfficeDocumentError.verificationFailed
                }
                guard try digest(sourceURL) == current.sha256 else {
                    throw OfficeDocumentError.revisionConflict
                }
            }
        )
        return try inspect(url: destination)
    }

    /// Validates the unknown keys of an opted-in workbook update as cell
    /// creations and returns them grouped by worksheet part. Keys arrive
    /// sorted, so refusals are deterministic. A key may only create when its
    /// worksheet part is one the inspector reads AND the workbook's own sheet
    /// relationships resolve consistently — the read-only
    /// `XLSXWorkbookPreviewReader` is the single authority for sheet
    /// existence, so a model-selected path can never widen that set. Foreign,
    /// malformed or non-canonical keys keep the preserved `unknownField`
    /// refusal; unsafe values and unbounded batches report `invalidContent`.
    private static func plannedWorkbookCellCreations(
        _ unknownKeys: [String],
        updates: [String: String],
        package: OfficeArchive
    ) throws -> [String: [XLSXCellCodec.CellCreation]] {
        guard unknownKeys.count <= maximumCreatedCellsPerUpdate else {
            throw OfficeDocumentError.invalidContent(
                "one workbook cell-creation update is limited to \(maximumCreatedCellsPerUpdate) new cells; split the batch")
        }
        let worksheetMembers = package.paths.filter {
            $0.hasPrefix("xl/worksheets/sheet")
                && $0.hasSuffix(".xml")
                && !$0.contains("/_rels/")
        }.sorted(by: OfficePathOrder.less)
        guard XLSXWorkbookPreviewReader.sheets(
            package: package, worksheetMembers: worksheetMembers, limit: maximumXMLBytes
        ) != nil else {
            throw OfficeDocumentError.invalidContent(
                "workbook cells can only be created when xl/workbook.xml resolves every worksheet relationship; re-read the field list and edit listed cells or repair the package first")
        }
        var creations: [String: [XLSXCellCodec.CellCreation]] = [:]
        for id in unknownKeys {
            guard let separator = id.range(of: "|c|") else {
                throw OfficeDocumentError.unknownField(id)
            }
            let entry = String(id[..<separator.lowerBound])
            guard worksheetMembers.contains(entry) else {
                throw OfficeDocumentError.unknownField(id)
            }
            let reference = String(id[separator.upperBound...])
            guard let position = XLSXCellCodec.canonicalCellReference(reference) else {
                throw OfficeDocumentError.unknownField(id)
            }
            let value = updates[id] ?? ""
            try XLSXCellCodec.validatedCreationValue(value, fieldID: id)
            creations[entry, default: []].append(
                XLSXCellCodec.CellCreation(reference: reference, column: position.column, row: position.row, value: value)
            )
        }
        return creations
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

}

struct OfficeArchive {
    let url: URL
    let archive: Archive
    let paths: [String]

    init(url: URL, maximumEntries: Int) throws {
        self.url = url
        self.archive = try Archive(url: url, accessMode: .read)
        var discovered: [String] = []
        var entryCount = 0, expandedBytes: UInt64 = 0
        for entry in archive {
            entryCount += 1
            guard entryCount <= maximumEntries else { throw OfficeDocumentError.tooManyEntries }
            let path = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard Self.isSafe(path: path), entry.type == .file || entry.type == .directory else { throw OfficeDocumentError.unsafeEntry(entry.path) }
            if entry.type == .directory { continue }
            expandedBytes += UInt64(entry.uncompressedSize)
            guard expandedBytes <= 128 * 1_024 * 1_024 else { throw OfficeDocumentError.packageTooLarge }
            guard !discovered.contains(entry.path) else { throw OfficeDocumentError.unsafeEntry(entry.path) }
            discovered.append(entry.path)
        }
        self.paths = discovered
    }

    func xml(path: String, limit: UInt32) throws -> String {
        let data = try data(path: path, limit: limit)
        guard !data.contains(Data("<!DOCTYPE".utf8)),
              !data.contains(Data("<!ENTITY".utf8)),
              let value = String(data: data, encoding: .utf8) else {
            throw OfficeDocumentError.invalidXML(path)
        }
        return value
    }

    func data(path: String, limit: UInt32) throws -> Data {
        guard let entry = archive[path] else { throw OfficeDocumentError.missingEntry(path) }
        guard entry.uncompressedSize <= limit else { throw OfficeDocumentError.oversizedEntry(path) }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            guard result.count <= Int(limit) - chunk.count else {
                throw OfficeDocumentError.oversizedEntry(path)
            }
            result.append(chunk)
        }
        return result
    }

    func writeCopy(
        to destination: URL,
        replacements: [String: Data],
        maximumMemberBytes: UInt32,
        maximumTotalBytes: Int,
        verify: (URL) throws -> Void
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".floe-office-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? manager.removeItem(at: temporary) }
        let output = try Archive(url: temporary, accessMode: .create)
        var total = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            let bytes: Data
            if let replacement = replacements[entry.path] {
                bytes = replacement
            } else {
                guard entry.uncompressedSize <= maximumMemberBytes else {
                    throw OfficeDocumentError.oversizedEntry(entry.path)
                }
                bytes = try data(path: entry.path, limit: maximumMemberBytes)
            }
            total += bytes.count
            guard total <= maximumTotalBytes else { throw OfficeDocumentError.packageTooLarge }
            try output.addFloeEntry(path: entry.path, data: bytes)
        }
        let mutationLock = ManagedFileMutationLock.shared
        mutationLock.lock(); defer { mutationLock.unlock() }
        try verify(temporary)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    private static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

extension Archive {
    func addFloeEntry(path: String, data: Data) throws {
        try addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        )
    }
}

enum OfficePathOrder {
    static func trailingNumber(_ path: String) -> Int? {
        let stem = (path as NSString).deletingPathExtension
        let digits = stem.reversed().prefix(while: \.isNumber).reversed()
        return Int(String(digits))
    }

    static func less(_ lhs: String, _ rhs: String) -> Bool {
        let left = trailingNumber(lhs) ?? 0
        let right = trailingNumber(rhs) ?? 0
        return left == right ? lhs < rhs : left < right
    }
}

/// Read-only resolver for the workbook's own tab list.
///
/// It returns `nil` — never a partial or guessed order — unless every check
/// below holds:
///  * `xl/workbook.xml` and `xl/_rels/workbook.xml.rels` exist and parse;
///  * every `<sheet>` has a name, a relationship id that resolves to a
///    worksheet part this inspector reads, and a known visibility state;
///  * no worksheet part is referenced twice, and every worksheet part the
///    inspector reads is referenced exactly once.
///
/// That strictness is the point: a corrupt relationship must make the caller
/// fall back to the existing native preview, never to "sheet 1 by file name".
private enum XLSXWorkbookPreviewReader {
    struct SheetShape: Equatable {
        var name: String
        var visibility: OfficeSheetVisibility
        var target: String
        var section: String
    }

    static func sheets(package: OfficeArchive, worksheetMembers: [String], limit: UInt32) -> [SheetShape]? {
        guard package.paths.contains("xl/workbook.xml"),
              package.paths.contains("xl/_rels/workbook.xml.rels"),
              let workbookXML = try? package.xml(path: "xl/workbook.xml", limit: limit),
              let relsXML = try? package.xml(path: "xl/_rels/workbook.xml.rels", limit: limit) else {
            return nil
        }
        var targetsByID: [String: String] = [:]
        for range in XMLTextCodec.elementRanges(relsXML, tag: "Relationship") {
            let block = String(relsXML[range])
            guard let id = XMLText.attribute("Id", inOpeningElement: block),
                  let type = XMLText.attribute("Type", inOpeningElement: block),
                  let target = XMLText.attribute("Target", inOpeningElement: block) else {
                return nil
            }
            // Only worksheet relationships matter here; styles/theme and other
            // package relationships are ignored rather than mistrusted.
            guard type.hasSuffix("/worksheet") else { continue }
            guard targetsByID[id] == nil else { return nil }
            let resolved = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            targetsByID[id] = resolved
        }
        var shapes: [SheetShape] = []
        var referenced = Set<String>()
        // Use the same XML parser as readSheet so numeric character references
        // and quoted names resolve identically in both tool catalogs.
        let workbookParser = WorkbookXMLParser()
        guard (try? workbookParser.parse(Data(workbookXML.utf8))) != nil,
              !workbookParser.invalidSheet else { return nil }
        for sheet in workbookParser.sheets {
            guard let target = targetsByID[sheet.relationshipID],
                  let visibility = OfficeSheetVisibility(rawValue: sheet.visibility) else { return nil }
            guard worksheetMembers.contains(target) else { return nil }
            guard !referenced.contains(target) else { return nil }
            referenced.insert(target)
            shapes.append(SheetShape(
                name: sheet.name,
                visibility: visibility,
                target: target,
                section: "Sheet \(OfficePathOrder.trailingNumber(target) ?? 0)"
            ))
        }
        guard !shapes.isEmpty, referenced.count == worksheetMembers.count else { return nil }
        return shapes
    }
}

private enum XMLTextCodec {
    static func fields(
        source: String,
        entry: String,
        paragraphTag: String,
        textTag: String,
        section: String
    ) -> [OfficeEditableField] {
        elementRanges(source, tag: paragraphTag).enumerated().compactMap { index, range in
            let block = String(source[range])
            let text = textContents(block, tag: textTag).joined()
            guard !text.isEmpty else { return nil }
            return OfficeEditableField(
                id: "\(entry)|p|\(index)",
                section: section,
                label: label(for: block, index: index, paragraphTag: paragraphTag),
                text: text
            )
        }
    }

    /// DOCX titles and headings carry a `w:pStyle`; map the generated `Title`
    /// paragraph to a "Title" field label so edits can target it by name
    /// instead of by ordinal only.
    private static func label(for block: String, index: Int, paragraphTag: String) -> String {
        guard paragraphTag == "w:p", let styleStart = block.range(of: "<w:pStyle") else {
            return "Text \(index + 1)"
        }
        let element = String(block[styleStart.lowerBound...])
        guard let value = XMLText.attribute("w:val", inOpeningElement: element), !value.isEmpty else {
            return "Text \(index + 1)"
        }
        switch value {
        case "Title": return "Title"
        case let heading where heading.hasPrefix("Heading"): return heading
        default: return "Text \(index + 1)"
        }
    }

    static func rewrite(
        source: String,
        entry: String,
        paragraphTag: String,
        textTag: String,
        updates: [String: String]
    ) throws -> String {
        var output = source
        let ranges = elementRanges(source, tag: paragraphTag)
        for (index, range) in ranges.enumerated().reversed() {
            let id = "\(entry)|p|\(index)"
            guard let replacement = updates[id] else { continue }
            let original = String(source[range])
            let rewritten = replaceTextContents(original, tag: textTag, text: replacement)
            output.replaceSubrange(range, with: rewritten)
        }
        return output
    }

    static func elementRanges(_ source: String, tag: String) -> [Range<String.Index>] {
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
            // Self-closing elements (<w:p/>, <c r="B3" s="7"/>, <a:p/>) have no
            // closing tag. Searching forward for the next `</tag>` would merge
            // following siblings into this element and corrupt the document.
            if source[source.index(before: openEnd)] == "/" {
                ranges.append(candidate.lowerBound..<openTagEnd)
                cursor = openTagEnd
                continue
            }
            guard let close = source.range(of: closer, range: openTagEnd..<source.endIndex)
            else { break }
            let end = close.upperBound
            ranges.append(candidate.lowerBound..<end)
            cursor = end
        }
        return ranges
    }

    static func textContents(_ source: String, tag: String) -> [String] {
        elementRanges(source, tag: tag).compactMap { range in
            let element = source[range]
            guard let openEnd = element.firstIndex(of: ">"),
                  let closeStart = element.range(of: "</\(tag)>")?.lowerBound else { return nil }
            return XMLText.unescape(String(element[element.index(after: openEnd)..<closeStart]))
        }
    }

    static func replaceTextContents(_ source: String, tag: String, text: String) -> String {
        // Self-closing elements (<w:t/>) hold no text and must not consume a
        // replacement slot, so only paired elements participate.
        let ranges = elementRanges(source, tag: tag).filter { range in
            source[range].range(of: "</\(tag)>") != nil
        }
        guard !ranges.isEmpty else { return source }
        var output = source
        for (offset, range) in ranges.enumerated().reversed() {
            let element = source[range]
            guard let openEnd = element.firstIndex(of: ">"),
                  let close = element.range(of: "</\(tag)>") else { continue }
            let contentRange = element.index(after: openEnd)..<close.lowerBound
            let absoluteStart = source.index(range.lowerBound, offsetBy: element.distance(from: element.startIndex, to: contentRange.lowerBound))
            let absoluteEnd = source.index(range.lowerBound, offsetBy: element.distance(from: element.startIndex, to: contentRange.upperBound))
            output.replaceSubrange(absoluteStart..<absoluteEnd, with: offset == 0 ? XMLText.escape(text) : "")
        }
        return output
    }
}

/// Canonical display value for one worksheet cell, shared by the inspect and
/// readSheet readers so the two cannot drift (formula wins over any cached
/// value; shared strings, booleans and inline strings decode identically).
enum OOXMLCellDecoder {
    static func displayValue(
        type: String?,
        rawValue: String,
        formula: String?,
        sharedStrings: [String]
    ) -> String {
        if let formula, !formula.isEmpty { return "=" + formula }
        switch type {
        case "s":
            guard let index = Int(rawValue), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "b":
            return rawValue == "1" ? "true" : "false"
        default:
            return rawValue
        }
    }
}

/// Bounded hidden row/column layout for one worksheet, parsed from the
/// worksheet's own `<row hidden="…">` and `<col hidden="…">` declarations.
/// `rowsTruncated`/`columnsTruncated` mean the list is incomplete and must not
/// be used to filter cell content.
struct XLSXHiddenLayout: Equatable {
    var rows: [Int] = []
    var columnSpans: [OfficeWorkbookColumnSpan] = []
    var rowsTruncated = false
    var columnsTruncated = false

    init() {}
}

private enum XLSXCellCodec {
    /// Bounds for the hidden layout analysis. A worksheet that exceeds either
    /// bound is reported truncated instead of being partially filtered.
    static let maximumHiddenRows = 1_024
    static let maximumHiddenColumnSpans = 128

    static func fields(
        source: String,
        entry: String,
        sharedStrings: [String],
        section: String
    ) -> [OfficeEditableField] {
        XMLTextCodec.elementRanges(source, tag: "c").compactMap { range in
            let cell = String(source[range])
            guard let reference = XMLText.attribute("r", inOpeningElement: cell) else { return nil }
            let type = XMLText.attribute("t", inOpeningElement: cell)
            let formula = XMLTextCodec.textContents(cell, tag: "f").first
            let rawValue: String
            if type == "inlineStr" {
                rawValue = XMLTextCodec.textContents(cell, tag: "t").joined()
            } else {
                rawValue = XMLTextCodec.textContents(cell, tag: "v").first ?? ""
            }
            let value = OOXMLCellDecoder.displayValue(
                type: type, rawValue: rawValue, formula: formula, sharedStrings: sharedStrings
            )
            return OfficeEditableField(
                id: "\(entry)|c|\(reference)", section: section, label: reference, text: value
            )
        }
    }

    /// The bounded hidden row/column layout of one worksheet. Detection is a
    /// bounded scan of the worksheet's own `<row>` and `<col>` elements; a
    /// worksheet with more hidden entries than the bound, or a malformed
    /// hidden declaration, is reported as truncated instead of silently
    /// filtered with incomplete knowledge.
    static func hiddenLayout(source: String) -> XLSXHiddenLayout {
        var layout = XLSXHiddenLayout()
        for range in XMLTextCodec.elementRanges(source, tag: "row") {
            let block = String(source[range])
            let hidden = isHidden(block)
            if hidden == nil { layout.rowsTruncated = true; continue }
            guard hidden == true else { continue }
            guard let row = XMLText.attribute("r", inOpeningElement: block).flatMap(Int.init), row > 0 else {
                layout.rowsTruncated = true
                continue
            }
            guard layout.rows.count < maximumHiddenRows else {
                layout.rowsTruncated = true
                break
            }
            layout.rows.append(row)
        }
        layout.rows = Array(Set(layout.rows)).sorted()
        for range in XMLTextCodec.elementRanges(source, tag: "col") {
            let block = String(source[range])
            let hidden = isHidden(block)
            if hidden == nil { layout.columnsTruncated = true; continue }
            guard hidden == true else { continue }
            guard let first = XMLText.attribute("min", inOpeningElement: block).flatMap(Int.init),
                  let last = XMLText.attribute("max", inOpeningElement: block).flatMap(Int.init),
                  first > 0, last >= first else {
                layout.columnsTruncated = true
                continue
            }
            guard layout.columnSpans.count < maximumHiddenColumnSpans else {
                layout.columnsTruncated = true
                break
            }
            layout.columnSpans.append(OfficeWorkbookColumnSpan(first: first, last: last))
        }
        return layout
    }

    /// OOXML booleans are `1`/`true` and `0`/`false`. Anything else is not a
    /// visibility value this reader can trust, so it reports `nil` and the
    /// caller marks the layout truncated rather than guessing.
    private static func isHidden(_ block: String) -> Bool? {
        guard let value = XMLText.attribute("hidden", inOpeningElement: block) else { return false }
        switch value.lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    static func rewrite(source: String, entry: String, updates: [String: String]) throws -> String {
        var output = source
        let ranges = XMLTextCodec.elementRanges(source, tag: "c")
        for range in ranges.reversed() {
            let cell = String(source[range])
            guard let reference = XMLText.attribute("r", inOpeningElement: cell),
                  let value = updates["\(entry)|c|\(reference)"] else { continue }
            let style = XMLText.attribute("s", inOpeningElement: cell)
                .map { " s=\"\(XMLText.escapeAttribute($0))\"" } ?? ""
            output.replaceSubrange(range, with: cellElement(reference: reference, styleAttribute: style, value: value))
        }
        return output
    }

    /// The single cell-writing convention of this package: a `=`-prefixed
    /// value becomes a formula with no fabricated cached result, a value that
    /// parses as a number keeps its literal text as the numeric `<v>` an
    /// engine sums, and anything else becomes preserved inline text. The
    /// existing-cell rewrite and the bounded creation opt-in both go through
    /// this function, so the two value conventions can never drift apart.
    static func cellElement(reference: String, styleAttribute: String, value: String) -> String {
        if value.hasPrefix("=") {
            return "<c r=\"\(XMLText.escapeAttribute(reference))\"\(styleAttribute)><f>\(XMLText.escape(String(value.dropFirst())))</f></c>"
        } else if Double(value) != nil, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return "<c r=\"\(XMLText.escapeAttribute(reference))\"\(styleAttribute)><v>\(XMLText.escape(value))</v></c>"
        } else {
            return "<c r=\"\(XMLText.escapeAttribute(reference))\"\(styleAttribute) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(value))</t></is></c>"
        }
    }

    /// Bounds shared with the Notes `<targetEntry>|c|<CELL>` caller contract
    /// (the tool caps operation text at 65536 UTF-8 bytes).
    static let maximumCreatedValueBytes = 65_536
    static let maximumCreatedFormulaCharacters = 8_192

    /// One validated new cell for the explicit creation opt-in.
    struct CellCreation {
        let reference: String
        let column: Int
        let row: Int
        let value: String
    }

    /// The canonical Excel address of the `<worksheet-part>|c|<CELL>` field
    /// convention: one or more ASCII uppercase letters followed by one or
    /// more ASCII digits with no leading zero, inside the real worksheet
    /// bounds `A1…XFD1048576`. This mirrors the key shape the Notes tool
    /// advertises and validates so both sides share one single format.
    static func canonicalCellReference(_ value: String) -> (column: Int, row: Int)? {
        guard !value.isEmpty, value.count <= 10 else { return nil }
        var column = 0
        var index = value.startIndex
        while index < value.endIndex, isASCIIUppercase(value[index]) {
            column = column * 26 + Int(value[index].asciiValue! - 64)
            guard column <= 16_384 else { return nil }
            index = value.index(after: index)
        }
        guard index > value.startIndex, index < value.endIndex else { return nil }
        let digits = value[index...]
        guard !digits.isEmpty, digits.count <= 7, digits.first != "0",
              digits.allSatisfy(isASCIIDigit),
              let row = Int(digits), row >= 1, row <= 1_048_576 else { return nil }
        return (column, row)
    }

    static func cellColumnLetters(_ column: Int) -> String {
        var value = column
        var letters: [Character] = []
        while value > 0 {
            value -= 1
            letters.append(Character(UnicodeScalar(UInt8(65 + value % 26))))
            value /= 26
        }
        return String(letters.reversed())
    }

    static func isASCIIDigit(_ character: Character) -> Bool {
        character.asciiValue.map { (48...57).contains($0) } ?? false
    }

    static func isASCIIUppercase(_ character: Character) -> Bool {
        character.asciiValue.map { (65...90).contains($0) } ?? false
    }

    /// Creation-side value screen. It writes nothing: it only decides which
    /// values are safe to hand to `cellElement`, the existing convention.
    /// Strict finite decimals go numeric (a real `<v>` that `SUM` reads), a
    /// `=`-prefixed non-empty remainder goes formula, and text containing no
    /// ASCII digit at all goes inline text. Anything that merely looks like a
    /// number — a Swift-parseable value that is not a strict decimal, a
    /// non-finite "inf"/"nan", a hex literal, or any digit-bearing text an
    /// engine might reinterpret — is refused instead of being silently
    /// written as inline text a formula would ignore or as an invalid `<v>`.
    static func validatedCreationValue(_ value: String, fieldID: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumCreatedValueBytes else {
            throw OfficeDocumentError.invalidContent(
                "cell \(fieldID) needs a non-empty value of at most \(maximumCreatedValueBytes) UTF-8 bytes")
        }
        guard value.unicodeScalars.allSatisfy(XMLText.isLegalXMLText) else {
            throw OfficeDocumentError.invalidContent(
                "cell \(fieldID) contains characters that cannot be stored safely")
        }
        if value.hasPrefix("=") {
            let formula = value.dropFirst()
            guard !formula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OfficeDocumentError.invalidContent("cell \(fieldID) has an empty formula")
            }
            guard formula.count <= maximumCreatedFormulaCharacters else {
                throw OfficeDocumentError.invalidContent(
                    "cell \(fieldID) formula exceeds \(maximumCreatedFormulaCharacters) characters")
            }
            return
        }
        if isStrictDecimal(value), Double(value)?.isFinite == true {
            return
        }
        if Double(value) != nil || value.contains(where: isASCIIDigit) {
            throw OfficeDocumentError.invalidContent(
                "cell \(fieldID) is not a safe creation value: write a strict number such as 120 or 1.5, a formula starting with =, or text without digits")
        }
    }

    /// `-?[0-9]+(.[0-9]+)?([eE][+-]?[0-9]+)?` with a no-leading-zero integer
    /// part (except a single `0`), scanned directly so the grammar cannot
    /// drift. "007", ".5", "+5", "5.", "1e", "0x1p3" and anything with stray
    /// characters are all rejected here.
    static func isStrictDecimal(_ value: String) -> Bool {
        let characters = Array(value)
        var index = 0
        if index < characters.count, characters[index] == "-" { index += 1 }
        let integerStart = index
        while index < characters.count, isASCIIDigit(characters[index]) { index += 1 }
        let integerDigits = index - integerStart
        guard integerDigits > 0 else { return false }
        if integerDigits > 1, characters[integerStart] == "0" { return false }
        if index < characters.count, characters[index] == "." {
            index += 1
            let fractionalStart = index
            while index < characters.count, isASCIIDigit(characters[index]) { index += 1 }
            guard index > fractionalStart else { return false }
        }
        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            index += 1
            if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
            let exponentStart = index
            while index < characters.count, isASCIIDigit(characters[index]) { index += 1 }
            guard index > exponentStart else { return false }
        }
        return index == characters.count
    }

    /// `r` values OOXML writes as plain positive integers without leading
    /// zeros; anything else means this writer must not reinterpret the
    /// structure for creation.
    static func isCanonicalPositiveInteger(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 7, text.first != "0", text.allSatisfy(isASCIIDigit) else { return false }
        return true
    }

    /// One worksheet row captured in coordinates of the member source (its
    /// outer range and the stable opening/content boundaries of its own block
    /// text) so edits can be applied strictly right-to-left.
    private struct CreationRow {
        let range: Range<String.Index>
        let number: Int
        let block: String
        let openingEnd: String.Index
        let contentEnd: String.Index
        let selfClosed: Bool
        let cells: [(column: Int, range: Range<String.Index>)]
        let spans: (first: Int, last: Int)?
        let spansMalformed: Bool
    }

    /// One absolute-position string edit for the creation pass.
    struct CreationEdit {
        let range: Range<String.Index>
        let text: String
    }

    /// Inserts validated new cells into the worksheet's own `sheetData` while
    /// every other byte of the member — and every other package member —
    /// streams through the existing copy unchanged. Cells land in column
    /// order inside their row and rows in ascending order inside
    /// `sheetData`; a `spans` declaration a modified row no longer fits is
    /// dropped so the engine recomputes it honestly; `<dimension ref>` is
    /// widened only when it currently parses as `A1` or `A1:B2`, because any
    /// other shape is recomputed by readers anyway. Fails closed — installing
    /// nothing — when the structure cannot be preserved: no single
    /// `sheetData`, a `<row>` or `<c>` without a canonical ascending `r`,
    /// unexpected content inside a row, a cell reference contradicting its
    /// row, or a self-closed row that also has content. A target reference
    /// that already exists is not duplicated: the normal rewrite pass ran
    /// first and has already updated that cell.
    static func applyCreations(source: String, entry: String, creations: [CellCreation]) throws -> String {
        let sheetDataElements = XMLTextCodec.elementRanges(source, tag: "sheetData")
        guard sheetDataElements.count == 1, let sheetDataRange = sheetDataElements.first else {
            throw OfficeDocumentError.invalidContent(
                "\(entry) needs exactly one sheetData element before cells can be created")
        }
        let ordered = creations.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        guard Set(ordered.map(\.reference)).count == ordered.count else {
            throw OfficeDocumentError.invalidContent("\(entry) received duplicate cell creation references")
        }
        var rows: [CreationRow] = []
        var existingReferences = Set<String>()
        var previousRowNumber = 0
        var totalRowCells = 0
        for rowRange in XMLTextCodec.elementRanges(source, tag: "row") {
            guard rowRange.lowerBound >= sheetDataRange.lowerBound, rowRange.upperBound <= sheetDataRange.upperBound else {
                throw OfficeDocumentError.invalidContent("\(entry) has a row element outside sheetData; creation cannot preserve it")
            }
            let block = String(source[rowRange])
            guard let openingEnd = block.firstIndex(of: ">") else {
                throw OfficeDocumentError.invalidContent("\(entry) has a malformed row element")
            }
            guard let numberText = XMLText.attribute("r", inOpeningElement: block),
                  isCanonicalPositiveInteger(numberText),
                  let number = Int(numberText), number <= 1_048_576,
                  number > previousRowNumber else {
                throw OfficeDocumentError.invalidContent(
                    "\(entry) has a row without a canonical ascending r attribute; creation cannot preserve it")
            }
            previousRowNumber = number
            let selfClosed = block.hasSuffix("/>")
            var cells: [(column: Int, range: Range<String.Index>)] = []
            var previousColumn = 0
            var cursor = block.index(after: openingEnd)
            for cellRange in XMLTextCodec.elementRanges(block, tag: "c") {
                guard block[cursor..<cellRange.lowerBound].allSatisfy(\.isWhitespace) else {
                    throw OfficeDocumentError.invalidContent(
                        "\(entry) row \(number) has unexpected content between cells; creation cannot preserve it")
                }
                cursor = cellRange.upperBound
                let cellText = String(block[cellRange])
                guard let reference = XMLText.attribute("r", inOpeningElement: cellText),
                      let position = canonicalCellReference(reference),
                      position.row == number,
                      position.column > previousColumn else {
                    throw OfficeDocumentError.invalidContent(
                        "\(entry) row \(number) has a cell without a canonical ascending r attribute; creation cannot preserve it")
                }
                previousColumn = position.column
                cells.append((position.column, cellRange))
                existingReferences.insert(reference)
            }
            let contentEnd: String.Index
            if selfClosed {
                guard cells.isEmpty else {
                    throw OfficeDocumentError.invalidContent("\(entry) row \(number) is both self-closed and populated")
                }
                contentEnd = block.index(block.endIndex, offsetBy: -2)
            } else if let close = block.range(of: "</row>") {
                guard block[cursor..<close.lowerBound].allSatisfy(\.isWhitespace) else {
                    throw OfficeDocumentError.invalidContent(
                        "\(entry) row \(number) has unexpected content after its last cell; creation cannot preserve it")
                }
                contentEnd = close.lowerBound
            } else {
                throw OfficeDocumentError.invalidContent("\(entry) row \(number) has no row close element")
            }
            var spans: (first: Int, last: Int)?
            var spansMalformed = false
            if let text = XMLText.attribute("spans", inOpeningElement: block) {
                let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2, isCanonicalPositiveInteger(String(parts[0])), isCanonicalPositiveInteger(String(parts[1])),
                   let first = Int(parts[0]), let last = Int(parts[1]), first <= last {
                    spans = (first, last)
                } else {
                    spansMalformed = true
                }
            }
            totalRowCells += cells.count
            rows.append(CreationRow(
                range: rowRange,
                number: number,
                block: block,
                openingEnd: block.index(after: openingEnd),
                contentEnd: contentEnd,
                selfClosed: selfClosed,
                cells: cells,
                spans: spans,
                spansMalformed: spansMalformed
            ))
        }
        guard totalRowCells == XMLTextCodec.elementRanges(source, tag: "c").count else {
            throw OfficeDocumentError.invalidContent("\(entry) has cell elements outside their rows; creation cannot preserve them")
        }
        var pendingByRow: [Int: [CellCreation]] = [:]
        for creation in ordered where !existingReferences.contains(creation.reference) {
            pendingByRow[creation.row, default: []].append(creation)
        }
        var edits: [CreationEdit] = []
        if source[sheetDataRange].hasSuffix("/>") {
            guard rows.isEmpty else {
                throw OfficeDocumentError.invalidContent("\(entry) has rows outside its self-closed sheetData")
            }
            var replacement = "<sheetData>"
            for group in pendingByRow.sorted(by: { $0.key < $1.key }) {
                replacement += "<row r=\"\(group.key)\">"
                for creation in group.value {
                    replacement += cellElement(reference: creation.reference, styleAttribute: "", value: creation.value)
                }
                replacement += "</row>"
            }
            edits.append(CreationEdit(range: sheetDataRange, text: replacement + "</sheetData>"))
        } else {
            let rowsByNumber = Dictionary(uniqueKeysWithValues: rows.map { ($0.number, $0) })
            guard let sheetDataClose = source.range(of: "</sheetData>", range: sheetDataRange)?.lowerBound else {
                throw OfficeDocumentError.invalidContent("\(entry) has no closed sheetData element")
            }
            var runByAnchor: [(anchor: String.Index, text: String)] = []
            for group in pendingByRow.sorted(by: { $0.key < $1.key }) {
                if let row = rowsByNumber[group.key] {
                    edits.append(CreationEdit(range: row.range, text: modifiedRow(row, adding: group.value)))
                } else {
                    let text = "<row r=\"\(group.key)\">"
                        + group.value.map { cellElement(reference: $0.reference, styleAttribute: "", value: $0.value) }.joined()
                        + "</row>"
                    let anchor = rows.first(where: { $0.number > group.key })?.range.lowerBound ?? sheetDataClose
                    if let last = runByAnchor.last, last.anchor == anchor {
                        runByAnchor[runByAnchor.count - 1].text += text
                    } else {
                        runByAnchor.append((anchor, text))
                    }
                }
            }
            for run in runByAnchor {
                edits.append(CreationEdit(range: run.anchor..<run.anchor, text: run.text))
            }
        }
        if let dimensionEdit = dimensionWideningEdit(source: source, creations: ordered) {
            edits.append(dimensionEdit)
        }
        var output = source
        for edit in edits.sorted(by: { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound { return lhs.range.lowerBound > rhs.range.lowerBound }
            return !lhs.range.isEmpty && rhs.range.isEmpty
        }) {
            output.replaceSubrange(edit.range, with: edit.text)
        }
        return output
    }

    /// Rebuilds one existing row: additions are spliced right-to-left at
    /// their column-order boundaries (stable original row-block positions),
    /// a self-closed row is converted so its new cells land inside the
    /// element, and a `spans` declaration the additions no longer fit into is
    /// dropped so the engine recomputes it instead of trusting a stale hint.
    private static func modifiedRow(_ row: CreationRow, adding additions: [CellCreation]) -> String {
        var block = row.block
        for addition in additions.sorted(by: { $0.column > $1.column }) {
            let element = cellElement(reference: addition.reference, styleAttribute: "", value: addition.value)
            let anchor = row.cells.first(where: { $0.column > addition.column })?.range.lowerBound ?? row.contentEnd
            block.replaceSubrange(anchor..<anchor, with: element)
        }
        if row.selfClosed {
            block.replaceSubrange(block.index(block.endIndex, offsetBy: -2)..<block.endIndex, with: "></row>")
        }
        let exceedsSpans = row.spansMalformed
            || (row.spans.map { span in additions.contains { $0.column < span.first || $0.column > span.last } } ?? false)
        if exceedsSpans {
            block = removingSpansAttribute(from: block, openingEnd: row.openingEnd)
        }
        return block
    }

    /// Removes one whole whitespace-delimited, quote-closed `spans="…"`
    /// attribute from the opening tag (including its single leading space) so
    /// the row keeps every other byte unchanged. An ambiguous match — inside
    /// a quoted value, or with a malformed quote span — is left in place:
    /// `spans` is a recomputable hint and a wrong removal must not damage the
    /// member.
    private static func removingSpansAttribute(from block: String, openingEnd: String.Index) -> String {
        guard openingEnd > block.startIndex,
              let marker = block.range(of: "spans=", options: [], range: block.startIndex..<openingEnd),
              marker.lowerBound > block.startIndex,
              block[block.index(before: marker.lowerBound)].isWhitespace,
              marker.upperBound < openingEnd else { return block }
        let prefix = block[block.startIndex..<marker.lowerBound]
        guard prefix.reduce(0) { $0 + ($1 == "\"" ? 1 : 0) } % 2 == 0 else { return block }
        let quote = block[marker.upperBound]
        guard quote == "\"" || quote == "'",
              let valueEnd = block[marker.upperBound...].firstIndex(of: quote), valueEnd < openingEnd else { return block }
        var output = block
        output.replaceSubrange(block.index(before: marker.lowerBound)..<block.index(after: valueEnd), with: "")
        return output
    }

    /// Builds the `<dimension ref>` widening edit, or `nil` (leave untouched)
    /// when there is no single `dimension`, the current value is not a clean
    /// `A1`/`A1:B2`, or the union would not change it.
    private static func dimensionWideningEdit(source: String, creations: [CellCreation]) -> CreationEdit? {
        guard !creations.isEmpty else { return nil }
        let elements = XMLTextCodec.elementRanges(source, tag: "dimension")
        guard elements.count == 1, let range = elements.first else { return nil }
        var search = range
        var marker: Range<String.Index>?
        while let found = source.range(of: "ref=", options: [], range: search) {
            let previous = found.lowerBound > range.lowerBound ? source[source.index(before: found.lowerBound)] : ">"
            if (previous == " " || previous == "\t" || previous == "\n" || previous == ">"),
               found.upperBound < range.upperBound,
               source[found.upperBound] == "\"" || source[found.upperBound] == "'" {
                marker = found
                break
            }
            search = found.upperBound..<range.upperBound
        }
        guard let marker else { return nil }
        let quote = source[marker.upperBound]
        guard let valueEnd = source[marker.upperBound...].firstIndex(of: quote), valueEnd < range.upperBound else { return nil }
        let valueStart = source.index(after: marker.upperBound)
        let ref = String(source[valueStart..<valueEnd])
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        var minColumn = Int.max
        var minRow = Int.max
        var maxColumn = 0
        var maxRow = 0
        var wasSingle = false
        switch parts.count {
        case 1:
            guard let corner = canonicalCellReference(String(parts[0])) else { return nil }
            minColumn = corner.column
            minRow = corner.row
            maxColumn = corner.column
            maxRow = corner.row
            wasSingle = true
        case 2:
            guard let first = canonicalCellReference(String(parts[0])),
                  let last = canonicalCellReference(String(parts[1])) else { return nil }
            minColumn = min(first.column, last.column)
            maxColumn = max(first.column, last.column)
            minRow = min(first.row, last.row)
            maxRow = max(first.row, last.row)
        default:
            return nil
        }
        for creation in creations {
            minColumn = min(minColumn, creation.column)
            maxColumn = max(maxColumn, creation.column)
            minRow = min(minRow, creation.row)
            maxRow = max(maxRow, creation.row)
        }
        let newRef: String
        if wasSingle, minColumn == maxColumn, minRow == maxRow {
            newRef = cellColumnLetters(minColumn) + String(minRow)
        } else {
            newRef = cellColumnLetters(minColumn) + String(minRow) + ":" + cellColumnLetters(maxColumn) + String(maxRow)
        }
        guard newRef != ref else { return nil }
        return CreationEdit(range: valueStart..<valueEnd, text: newRef)
    }
}

enum SharedStringTable {
    static func load(from package: OfficeArchive, limit: UInt32) throws -> [String] {
        guard package.paths.contains("xl/sharedStrings.xml") else { return [] }
        let xml = try package.xml(path: "xl/sharedStrings.xml", limit: limit)
        return XMLTextCodec.elementRanges(xml, tag: "si").map { range in
            XMLTextCodec.textContents(String(xml[range]), tag: "t").joined()
        }
    }
}

enum XMLText {
    /// XML 1.0 text may contain only tab/CR/LF plus scalars from U+0020 up,
    /// excluding the non-characters U+FFFE/U+FFFF. Creation input is screened
    /// with this so an unsafe value fails closed instead of writing a member
    /// that cannot reopen.
    static func isLegalXMLText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: return true
        case 0xFFFE, 0xFFFF: return false
        default: return scalar.value >= 0x20
        }
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func attribute(_ name: String, inOpeningElement element: String) -> String? {
        guard let end = element.firstIndex(of: ">") else { return nil }
        let opening = element[..<end]
        for quote in ["\"", "'"] {
            let marker = "\(name)=\(quote)"
            guard let start = opening.range(of: marker) else { continue }
            let valueStart = start.upperBound
            guard let valueEnd = opening[valueStart...].firstIndex(of: Character(quote)) else { continue }
            return unescape(String(opening[valueStart..<valueEnd]))
        }
        return nil
    }
}

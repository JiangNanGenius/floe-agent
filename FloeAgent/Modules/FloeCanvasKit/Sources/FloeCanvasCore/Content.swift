import Foundation

/// Structured content carried by a canvas node. Every case is native and
/// editable in its own professional surface; content a future build does not
/// understand is kept verbatim via `.unknown` and survives read/write.
public enum CanvasContent: Codable, Hashable, Sendable {
    /// Plain editable text.
    case text(String)
    /// Markdown document with an optional rendered preview hint.
    case markdown(document: String, previewText: String?)
    /// Attributed rich text with explicit runs. This is real structured
    /// content (ICQA08/09), not a markdown projection: runs carry their own
    /// style and UI layers render them natively.
    case richText(document: CanvasRichTextDocument)
    /// Editable vector shape with optional inner text (rectangle, ellipse,
    /// connector, …). Geometry styling lives in the node's metadata under
    /// `CanvasVisualMetadataKeys` so UI and Exchange share one vocabulary.
    case shape(kind: CanvasShapeKind, text: String)
    /// Syntax-highlighted code snippet.
    case code(language: String?, source: String)
    /// Rendered formula (LaTeX source plus a pre-rendered asset if present).
    case formula(source: String, renderedAssetID: UUID?)
    /// Editable table; row cells are plain strings so partial tables survive.
    case table(header: [String], rows: [[String]])
    /// Audio/video/image payload referenced by asset.
    case media(CanvasAssetLocator)
    /// A page range or fragment of a PDF document.
    case pdf(documentAssetID: UUID?, pageRange: ClosedRange<Int>?)
    /// A web page snapshot or live reference.
    case web(URL, title: String?)
    /// Reference to an editable child project handled by a professional
    /// editor (image/video/CAD/mind-map). The canvas never duplicates the
    /// child project's state.
    case editor(CanvasEditorReference)
    /// Verbatim retention of a content kind this build does not model.
    /// Unknown-content policy: raw import (legacy adapter) and the native
    /// archive preserve the COMPLETE original payload; decoding never
    /// crashes on kinds this build does not know — unrecognized `kind`
    /// strings (present or future) decode into this case with their full
    /// payload intact, and a missing payload decodes as an empty object.
    case unknown(kind: String, payload: JSONValue)

    public var unknownKind: String? {
        guard case .unknown(let kind, _) = self else { return nil }
        return kind
    }

    private enum CodingKeys: String, CodingKey {
        case kind, unknownKind, text, document, previewText, language, source
        case renderedAssetID, header, rows, asset, documentAssetID
        case pageLower, pageUpper, url, title, editor, payload
        case shapeKind
    }

    private enum Kind: String, Codable {
        case text, markdown, richText, shape, code, formula, table, media, pdf
        case web, editor, unknown
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the envelope kind as a raw string: kind strings this build
        // does not know (from future builds or foreign archives) must
        // degrade to `.unknown` with payload preserved, never crash.
        guard let kindRaw = try values.decodeIfPresent(String.self, forKey: .kind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: values,
                debugDescription: "canvas content is missing its kind")
        }
        let unknownPayload = { try values.decodeIfPresent(JSONValue.self, forKey: .payload) }
        guard let kind = Kind(rawValue: kindRaw) else {
            self = .unknown(kind: kindRaw, payload: try unknownPayload() ?? .object([:]))
            return
        }
        switch kind {
        case .text:
            self = .text(try values.decode(String.self, forKey: .text))
        case .markdown:
            self = .markdown(
                document: try values.decode(String.self, forKey: .document),
                previewText: try values.decodeIfPresent(String.self, forKey: .previewText)
            )
        case .richText:
            self = .richText(
                document: try values.decodeIfPresent(
                    CanvasRichTextDocument.self, forKey: .document)
                    ?? CanvasRichTextDocument())
        case .shape:
            self = .shape(
                kind: CanvasShapeKind(
                    rawValue: try values.decodeIfPresent(String.self, forKey: .shapeKind) ?? ""
                ) ?? .rectangle,
                text: try values.decodeIfPresent(String.self, forKey: .text) ?? "")
        case .code:
            self = .code(
                language: try values.decodeIfPresent(String.self, forKey: .language),
                source: try values.decode(String.self, forKey: .source)
            )
        case .formula:
            self = .formula(
                source: try values.decode(String.self, forKey: .source),
                renderedAssetID: try values.decodeIfPresent(UUID.self, forKey: .renderedAssetID)
            )
        case .table:
            self = .table(
                header: try values.decodeIfPresent([String].self, forKey: .header) ?? [],
                rows: try values.decodeIfPresent([[String]].self, forKey: .rows) ?? []
            )
        case .media:
            self = .media(try values.decode(CanvasAssetLocator.self, forKey: .asset))
        case .pdf:
            let range: ClosedRange<Int>?
            if let lower = try values.decodeIfPresent(Int.self, forKey: .pageLower),
               let upper = try values.decodeIfPresent(Int.self, forKey: .pageUpper) {
                // A hostile or corrupt archive must surface as a decoding
                // error, never as a runtime trap from `lower...upper`.
                guard lower >= 1, upper >= lower else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .pageLower, in: values,
                        debugDescription: "invalid pdf page range \(lower)...\(upper)")
                }
                range = lower...upper
            } else {
                range = nil
            }
            self = .pdf(
                documentAssetID: try values.decodeIfPresent(UUID.self, forKey: .documentAssetID),
                pageRange: range
            )
        case .web:
            self = .web(
                try values.decode(URL.self, forKey: .url),
                title: try values.decodeIfPresent(String.self, forKey: .title)
            )
        case .editor:
            self = .editor(try values.decode(CanvasEditorReference.self, forKey: .editor))
        case .unknown:
            self = .unknown(
                kind: try values.decode(String.self, forKey: .unknownKind),
                payload: try unknownPayload() ?? .object([:])
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try values.encode(Kind.text, forKey: .kind)
            try values.encode(text, forKey: .text)
        case .markdown(let document, let previewText):
            try values.encode(Kind.markdown, forKey: .kind)
            try values.encode(document, forKey: .document)
            try values.encodeIfPresent(previewText, forKey: .previewText)
        case .richText(let document):
            try values.encode(Kind.richText, forKey: .kind)
            try values.encode(document, forKey: .document)
        case .shape(let kind, let text):
            try values.encode(Kind.shape, forKey: .kind)
            try values.encode(kind.rawValue, forKey: .shapeKind)
            try values.encode(text, forKey: .text)
        case .code(let language, let source):
            try values.encode(Kind.code, forKey: .kind)
            try values.encodeIfPresent(language, forKey: .language)
            try values.encode(source, forKey: .source)
        case .formula(let source, let renderedAssetID):
            try values.encode(Kind.formula, forKey: .kind)
            try values.encode(source, forKey: .source)
            try values.encodeIfPresent(renderedAssetID, forKey: .renderedAssetID)
        case .table(let header, let rows):
            try values.encode(Kind.table, forKey: .kind)
            try values.encode(header, forKey: .header)
            try values.encode(rows, forKey: .rows)
        case .media(let asset):
            try values.encode(Kind.media, forKey: .kind)
            try values.encode(asset, forKey: .asset)
        case .pdf(let documentAssetID, let pageRange):
            try values.encode(Kind.pdf, forKey: .kind)
            try values.encodeIfPresent(documentAssetID, forKey: .documentAssetID)
            if let pageRange {
                try values.encode(pageRange.lowerBound, forKey: .pageLower)
                try values.encode(pageRange.upperBound, forKey: .pageUpper)
            }
        case .web(let url, let title):
            try values.encode(Kind.web, forKey: .kind)
            try values.encode(url, forKey: .url)
            try values.encodeIfPresent(title, forKey: .title)
        case .editor(let reference):
            try values.encode(Kind.editor, forKey: .kind)
            try values.encode(reference, forKey: .editor)
        case .unknown(let kind, let payload):
            try values.encode(Kind.unknown, forKey: .kind)
            try values.encode(kind, forKey: .unknownKind)
            try values.encode(payload, forKey: .payload)
        }
    }
}

/// Editable vector shape kinds. The geometry itself lives on the node's
/// frame; the kind selects the rendered primitive.
public enum CanvasShapeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case rectangle, roundedRectangle, ellipse, diamond, line, arrow
}

/// One attributed run of a rich-text document. Styles are plain values so
/// the document stays Foundation-only Codable data; UI layers map them to
/// fonts/colors (see `CanvasRichTextAttribute`).
public struct CanvasRichTextRun: Codable, Hashable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    /// Optional hyperlink target.
    public var link: URL?
    /// Canonical color string (see `CanvasVisualMetadataKeys` spelling) or
    /// nil for inherited color.
    public var foregroundColor: String?

    public init(
        text: String,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        link: URL? = nil,
        foregroundColor: String? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.link = link
        self.foregroundColor = foregroundColor
    }
}

/// Attributed rich-text document: an ordered list of runs. This is the
/// native rich-text content model (ICQA08/09); it is deliberately NOT a
/// markdown projection — runs survive editing with their styles intact.
public struct CanvasRichTextDocument: Codable, Hashable, Sendable {
    public var runs: [CanvasRichTextRun]

    public init(runs: [CanvasRichTextRun] = []) {
        self.runs = runs
    }

    /// Lossless plain-text projection.
    public var plainText: String {
        runs.map(\.text).joined()
    }
}

/// Canonical attributed-string attribute keys for `CanvasRichTextRun`.
/// They are Foundation-only (`NSAttributedString.Key` needs no UIKit/AppKit)
/// so any target can build an attributed string; UI layers map bold/italic
/// to fonts and color strings to platform colors at render time.
public enum CanvasRichTextAttribute {
    public static let bold = NSAttributedString.Key("floeCanvas.richText.bold")
    public static let italic = NSAttributedString.Key("floeCanvas.richText.italic")
    public static let underline = NSAttributedString.Key("floeCanvas.richText.underline")
    public static let strikethrough = NSAttributedString.Key("floeCanvas.richText.strikethrough")
    public static let link = NSAttributedString.Key("floeCanvas.richText.link")
    public static let foregroundColor = NSAttributedString.Key("floeCanvas.richText.foregroundColor")
}

public extension CanvasRichTextDocument {
    /// Foundation-only attributed-string conversion. Attribute values are
    /// the run's plain values (Bool / URL / color String) under the
    /// canonical keys in `CanvasRichTextAttribute`.
    func makeAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if run.bold { attributes[CanvasRichTextAttribute.bold] = true }
            if run.italic { attributes[CanvasRichTextAttribute.italic] = true }
            if run.underline { attributes[CanvasRichTextAttribute.underline] = true }
            if run.strikethrough { attributes[CanvasRichTextAttribute.strikethrough] = true }
            if let link = run.link { attributes[CanvasRichTextAttribute.link] = link }
            if let color = run.foregroundColor {
                attributes[CanvasRichTextAttribute.foregroundColor] = color
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}

/// Stable metadata keys for node visual styling (ICQA08/09). UI, Layout and
/// Exchange MUST use these keys instead of inventing per-module spellings.
/// Colors are canonical strings (`#RRGGBB`, `#RRGGBBAA` or a lowercase name
/// such as `primary`); widths are finite non-negative doubles.
public enum CanvasVisualMetadataKeys {
    public static let fillColor = "floeCanvas.visual.fillColor"
    public static let strokeColor = "floeCanvas.visual.strokeColor"
    public static let strokeWidth = "floeCanvas.visual.strokeWidth"
    public static let textColor = "floeCanvas.visual.textColor"

    public static let all: Set<String> = [
        fillColor, strokeColor, strokeWidth, textColor,
    ]

    public static func isVisualKey(_ key: String) -> Bool {
        all.contains(key)
    }

    /// Validates a metadata VALUE for a visual key: colors use the canonical
    /// color grammar, stroke width a finite non-negative double literal.
    public static func isValid(value: String, forKey key: String) -> Bool {
        guard isVisualKey(key) else { return true }
        if key == strokeWidth {
            return Double(value).map(CanvasVisualStyle.isValidStrokeWidth) ?? false
        }
        return CanvasVisualStyle.isValidColorString(value)
    }
}

/// Typed view over the visual-style metadata keys.
public struct CanvasVisualStyle: Hashable, Sendable {
    public var fillColor: String?
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var textColor: String?

    public init(
        fillColor: String? = nil,
        strokeColor: String? = nil,
        strokeWidth: Double? = nil,
        textColor: String? = nil
    ) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.textColor = textColor
    }

    public init?(metadata: [String: String]) {
        let style = CanvasVisualStyle(
            fillColor: metadata[CanvasVisualMetadataKeys.fillColor],
            strokeColor: metadata[CanvasVisualMetadataKeys.strokeColor],
            strokeWidth: metadata[CanvasVisualMetadataKeys.strokeWidth]
                .flatMap(Double.init),
            textColor: metadata[CanvasVisualMetadataKeys.textColor])
        guard style.fillColor != nil || style.strokeColor != nil
            || style.strokeWidth != nil || style.textColor != nil else {
            return nil
        }
        self = style
    }

    public func applied(to metadata: inout [String: String]) {
        metadata[CanvasVisualMetadataKeys.fillColor] = fillColor
        metadata[CanvasVisualMetadataKeys.strokeColor] = strokeColor
        metadata[CanvasVisualMetadataKeys.strokeWidth] = strokeWidth
            .map { "\($0)" }
        metadata[CanvasVisualMetadataKeys.textColor] = textColor
    }

    /// True when every present value satisfies the canonical color and
    /// width grammar (`isValidColorString` / `isValidStrokeWidth`).
    public var isValid: Bool {
        [fillColor, strokeColor, textColor].allSatisfy { color in
            color.map(CanvasVisualStyle.isValidColorString) ?? true
        } && strokeWidth.map(CanvasVisualStyle.isValidStrokeWidth) ?? true
    }
}

public extension CanvasVisualStyle {
    /// Canonical color spelling: `#RGB`, `#RRGGBB`, `#RRGGBBAA` hex forms
    /// or a lowercase alphanumeric style name (`primary`, `accent2`, …).
    static func isValidColorString(_ value: String) -> Bool {
        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            let validCount = [3, 6, 8].contains(hex.count)
            let validChars = hex.allSatisfy {
                ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
                || ($0 >= "A" && $0 <= "F")
            }
            return validCount && validChars
        }
        return !value.isEmpty && value.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "."
        }
    }

    /// Stroke width must be finite and non-negative.
    static func isValidStrokeWidth(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }
}

/// Asset identity only — the kit never stores media bytes. Hosts resolve
/// bytes through `CanvasAssetStore` (Integration).
public struct CanvasAssetLocator: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var contentHash: String?
    public var relativePath: String?
    public var mimeType: String?
    public var byteCount: Int64?
    public var sourceURL: URL?
    public var license: String?

    public init(
        id: UUID = UUID(),
        contentHash: String? = nil,
        relativePath: String? = nil,
        mimeType: String? = nil,
        byteCount: Int64? = nil,
        sourceURL: URL? = nil,
        license: String? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sourceURL = sourceURL
        self.license = license
    }
}

/// Binding to a child editable project owned by a professional editor.
public struct CanvasEditorReference: Codable, Hashable, Sendable {
    public var projectID: UUID
    /// Revision the canvas currently displays.
    public var appliedRevision: Int64
    /// Newer draft revision saved by the editor but not yet applied.
    public var draftRevision: Int64?
    /// Which professional editor surface owns the child project.
    public var editorKind: String

    public init(
        projectID: UUID,
        appliedRevision: Int64,
        draftRevision: Int64? = nil,
        editorKind: String
    ) {
        self.projectID = projectID
        self.appliedRevision = appliedRevision
        self.draftRevision = draftRevision
        self.editorKind = editorKind
    }
}

/// Stable identity of an external source plus the exact fragment and
/// revision the node currently uses. Refresh (Integration) compares
/// `usedRevision` against the live source revision.
public struct CanvasSourceReference: Codable, Hashable, Sendable {
    /// Stable source identity in the host content service (never a bare URL
    /// copied into free text).
    public var sourceID: UUID
    /// Fragment locator, e.g. `page:3`, `heading:结论`, `paragraph:2`.
    public var fragment: String?
    /// Revision of the source content this node was last refreshed from.
    public var usedRevision: Int64
    /// User-authored annotations anchored on this node's copy of the source.
    public var annotations: [CanvasSourceAnnotation]

    public init(
        sourceID: UUID,
        fragment: String? = nil,
        usedRevision: Int64,
        annotations: [CanvasSourceAnnotation] = []
    ) {
        self.sourceID = sourceID
        self.fragment = fragment
        self.usedRevision = usedRevision
        self.annotations = annotations
    }
}

public struct CanvasSourceAnnotation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var author: String
    public var text: String
    public var anchor: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        author: String,
        text: String,
        anchor: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.anchor = anchor
        self.createdAt = createdAt
    }
}

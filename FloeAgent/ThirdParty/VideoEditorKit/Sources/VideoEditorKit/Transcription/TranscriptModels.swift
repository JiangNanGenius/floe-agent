import Foundation

/// Persisted transcript document stored inside `VideoEditingConfiguration`.
public struct TranscriptDocument: Codable, Hashable, Sendable {

    enum CodingKeys: String, CodingKey {
        case segments
        case overlayPosition
        case overlaySize
        case availableStyles
        case selectedStyleID
    }

    // MARK: - Public Properties

    public var segments: [EditableTranscriptSegment] = []
    public var overlayPosition: TranscriptOverlayPosition = .bottom
    public var overlaySize: TranscriptOverlaySize = .medium

    // MARK: - Initializer

    public init(
        segments: [EditableTranscriptSegment] = [],
        overlayPosition: TranscriptOverlayPosition = .bottom,
        overlaySize: TranscriptOverlaySize = .medium
    ) {
        self.segments = segments
        self.overlayPosition = overlayPosition
        self.overlaySize = overlaySize
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decodeIfPresent([EditableTranscriptSegment].self, forKey: .segments) ?? []
        overlayPosition =
            try container.decodeIfPresent(TranscriptOverlayPosition.self, forKey: .overlayPosition)
            ?? .bottom
        overlaySize =
            try container.decodeIfPresent(TranscriptOverlaySize.self, forKey: .overlaySize)
            ?? .medium

        // Ignore legacy style fields while remaining backward compatible with persisted snapshots.
        _ = try container.decodeIfPresent([TranscriptStyle].self, forKey: .availableStyles)
        _ = try container.decodeIfPresent(TranscriptStyle.StyleIdentifier.self, forKey: .selectedStyleID)
    }

    // MARK: - Public Methods

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(overlayPosition, forKey: .overlayPosition)
        try container.encode(overlaySize, forKey: .overlaySize)
    }

}

extension TranscriptDocument {

    // MARK: - Public Properties

    /// Plain-text transcript grouped into paragraphs.
    public var plainText: String {
        plainTextParagraphs.joined(separator: "\n\n")
    }

    /// Returns `true` when the document contains non-empty text that can be copied.
    public var hasCopyableText: Bool {
        plainTextParagraphs.isEmpty == false
    }

    // MARK: - Private Properties

    private var plainTextParagraphs: [String] {
        segments.compactMap(\.plainTextParagraph)
    }

}

/// Editable transcript segment stored inside a transcript document.
public struct EditableTranscriptSegment: Identifiable, Codable, Hashable, Sendable {

    enum CodingKeys: String, CodingKey {
        case id
        case timeMapping
        case originalText
        case editedText
        case words
        case styleID
    }

    // MARK: - Public Properties

    public let id: UUID
    public var timeMapping: TranscriptTimeMapping
    public var originalText: String
    public var editedText: String
    public var words: [EditableTranscriptWord] = []

    // MARK: - Initializer

    public init(
        id: UUID,
        timeMapping: TranscriptTimeMapping,
        originalText: String,
        editedText: String,
        words: [EditableTranscriptWord] = []
    ) {
        self.id = id
        self.timeMapping = timeMapping
        self.originalText = originalText
        self.editedText = editedText
        self.words = words
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timeMapping = try container.decode(TranscriptTimeMapping.self, forKey: .timeMapping)
        originalText = try container.decode(String.self, forKey: .originalText)
        editedText = try container.decode(String.self, forKey: .editedText)
        words = try container.decodeIfPresent([EditableTranscriptWord].self, forKey: .words) ?? []

        // Ignore legacy per-segment style overrides from older snapshots.
        _ = try container.decodeIfPresent(TranscriptStyle.StyleIdentifier.self, forKey: .styleID)
    }

    // MARK: - Public Methods

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeMapping, forKey: .timeMapping)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(editedText, forKey: .editedText)
        try container.encode(words, forKey: .words)
    }

}

extension EditableTranscriptSegment {

    // MARK: - Public Properties

    /// Returns `true` when the segment text differs from its original transcription.
    public var isEdited: Bool {
        originalText != editedText
    }

    // MARK: - Private Properties

    fileprivate var plainTextParagraph: String? {
        let trimmedText = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    // MARK: - Public Methods

    /// Restores the segment and all its words to their original transcription text.
    public mutating func revertEdits() {
        editedText = originalText
        words = words.map {
            var word = $0
            word.editedText = word.originalText
            return word
        }
    }

}

/// Editable transcript word stored inside an editable segment.
public struct EditableTranscriptWord: Identifiable, Codable, Hashable, Sendable {

    // MARK: - Public Properties

    public let id: UUID
    public var timeMapping: TranscriptTimeMapping
    public let originalText: String
    public var editedText: String

    // MARK: - Initializer

    public init(
        id: UUID,
        timeMapping: TranscriptTimeMapping,
        originalText: String,
        editedText: String
    ) {
        self.id = id
        self.timeMapping = timeMapping
        self.originalText = originalText
        self.editedText = editedText
    }

}

/// Maps transcript content between source-video time and edited timeline time.
public struct TranscriptTimeMapping: Codable, Hashable, Sendable {

    // MARK: - Public Properties

    public var sourceStartTime: Double
    public var sourceEndTime: Double
    public var timelineStartTime: Double?
    public var timelineEndTime: Double?

    public var sourceRange: ClosedRange<Double> {
        sourceStartTime...sourceEndTime
    }

    public var timelineRange: ClosedRange<Double>? {
        guard let timelineStartTime, let timelineEndTime else { return nil }
        return timelineStartTime...timelineEndTime
    }

    // MARK: - Initializer

    public init(
        sourceStartTime: Double,
        sourceEndTime: Double,
        timelineStartTime: Double? = nil,
        timelineEndTime: Double? = nil
    ) {
        self.sourceStartTime = sourceStartTime
        self.sourceEndTime = sourceEndTime
        self.timelineStartTime = timelineStartTime
        self.timelineEndTime = timelineEndTime
    }

}

/// Caption styling information stored with transcript content.
public struct TranscriptStyle: Identifiable, Codable, Hashable, Sendable {

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fontWeight
        case hasStroke
        case textAlignment
        case textColor
        case strokeColor
        case fontFamily
        case isItalic
    }

    public typealias StyleIdentifier = UUID

    // MARK: - Public Properties

    public let id: StyleIdentifier
    public var name: String
    public var fontWeight: TranscriptFontWeight = .bold
    public var hasStroke = false
    public var textAlignment: TranscriptTextAlignment = .center
    public var textColor: RGBAColor = .white
    public var strokeColor: RGBAColor?

    // MARK: - Initializer

    public init(
        id: StyleIdentifier,
        name: String,
        fontWeight: TranscriptFontWeight = .bold,
        hasStroke: Bool = false,
        textAlignment: TranscriptTextAlignment = .center,
        textColor: RGBAColor = .white,
        strokeColor: RGBAColor? = nil
    ) {
        self.id = id
        self.name = name
        self.fontWeight = fontWeight
        self.hasStroke = hasStroke
        self.textAlignment = textAlignment
        self.textColor = textColor
        self.strokeColor = strokeColor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyFontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        let legacyIsItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false

        id = try container.decode(StyleIdentifier.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fontWeight =
            try container.decodeIfPresent(TranscriptFontWeight.self, forKey: .fontWeight)
            ?? Self.fallbackFontWeight(
                legacyFontFamily: legacyFontFamily,
                legacyIsItalic: legacyIsItalic
            )
        hasStroke = try container.decodeIfPresent(Bool.self, forKey: .hasStroke) ?? false
        textAlignment =
            try container.decodeIfPresent(TranscriptTextAlignment.self, forKey: .textAlignment)
            ?? .center
        textColor = try container.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? .white
        strokeColor = try container.decodeIfPresent(RGBAColor.self, forKey: .strokeColor)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(fontWeight, forKey: .fontWeight)
        try container.encode(hasStroke, forKey: .hasStroke)
        try container.encode(textAlignment, forKey: .textAlignment)
        try container.encode(textColor, forKey: .textColor)
        try container.encodeIfPresent(strokeColor, forKey: .strokeColor)
    }

    // MARK: - Private Methods

    private static func fallbackFontWeight(
        legacyFontFamily _: String?,
        legacyIsItalic: Bool
    ) -> TranscriptFontWeight {
        legacyIsItalic ? .heavy : .bold
    }

}

extension TranscriptStyle {

    // MARK: - Public Properties

    /// Default caption style used by the current package UI.
    public static let defaultCaptionStyle = Self(
        id: UUID(uuidString: "E5A04D11-329A-4C8E-B266-1E6A60A6F9F9") ?? UUID(),
        name: String(
            localized: "editor.transcript.default-style",
            defaultValue: "Default",
            bundle: .module
        ),
        fontWeight: .semibold,
        hasStroke: true,
        textAlignment: .center,
        textColor: .white,
        strokeColor: .init(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )
    )

}

/// Codable RGBA color used by transcript styling models.
public struct RGBAColor: Codable, Hashable, Sendable {

    // MARK: - Public Properties

    public static let white = Self(red: 1, green: 1, blue: 1, alpha: 1)
    public static let black = Self(red: 0, green: 0, blue: 0, alpha: 1)

    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    // MARK: - Initializer

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

}

/// Text alignment options for transcript overlays.
public enum TranscriptTextAlignment: String, Codable, Hashable, Sendable {
    case leading
    case center
    case trailing
}

/// Supported font-weight options for transcript overlays.
public enum TranscriptFontWeight: String, Codable, Hashable, Sendable, CaseIterable {
    case regular
    case semibold
    case bold
    case heavy
}

/// Vertical placement options for transcript overlays.
public enum TranscriptOverlayPosition: String, Codable, Hashable, Sendable, CaseIterable {
    case top
    case center
    case bottom

    // MARK: - Public Properties

    public var title: String {
        switch self {
        case .top:
            VideoEditorStrings.transcriptPositionTop
        case .center:
            VideoEditorStrings.transcriptPositionCenter
        case .bottom:
            VideoEditorStrings.transcriptPositionBottom
        }
    }

    public var abbreviation: String {
        switch self {
        case .top:
            VideoEditorStrings.transcriptPositionTopAbbreviation
        case .center:
            VideoEditorStrings.transcriptPositionCenterAbbreviation
        case .bottom:
            VideoEditorStrings.transcriptPositionBottomAbbreviation
        }
    }
}

/// Relative sizing options for transcript overlays.
public enum TranscriptOverlaySize: String, Codable, Hashable, Sendable, CaseIterable {
    case small
    case medium
    case large

    // MARK: - Public Properties

    public var title: String {
        switch self {
        case .small:
            VideoEditorStrings.transcriptSizeSmall
        case .medium:
            VideoEditorStrings.transcriptSizeMedium
        case .large:
            VideoEditorStrings.transcriptSizeLarge
        }
    }

    public var abbreviation: String {
        switch self {
        case .small:
            VideoEditorStrings.transcriptSizeSmallAbbreviation
        case .medium:
            VideoEditorStrings.transcriptSizeMediumAbbreviation
        case .large:
            VideoEditorStrings.transcriptSizeLargeAbbreviation
        }
    }
}

/// Persisted transcript feature state stored in `VideoEditingConfiguration`.
public enum TranscriptFeaturePersistenceState: String, Codable, Equatable, Sendable {
    case idle
    case loaded
    case failed
}

/// Runtime transcript feature state used by transcription components.
public enum TranscriptFeatureState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(TranscriptError)
}

/// Public transcript-related errors surfaced by the package.
public enum TranscriptError: Error, Sendable, Equatable {
    case providerNotConfigured
    case unavailable(message: String)
    case invalidVideoSource
    case emptyResult
    case cancelled
    case providerFailure(message: String)
}

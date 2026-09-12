import Foundation

/// A serializable snapshot of all user-editable state managed by the package.
///
/// Host apps typically persist this value to resume a project later and mirror autosave updates
/// emitted by `VideoEditorView`.
public struct VideoEditingConfiguration: Codable, Equatable, Sendable {

    // MARK: - Public Properties

    /// The latest schema version understood by the package.
    public static let currentSchemaVersion: SchemaVersion = .current
    /// An empty editing configuration with package defaults.
    public static let initial = Self()

    /// Stored schema version for the encoded payload.
    public var version = Self.currentSchemaVersion.rawValue
    /// Trim bounds stored in source timeline seconds.
    public var trim = Trim()
    /// Playback-related state such as rate and current timeline position.
    public var playback = Playback()
    /// Crop-related state such as rotation, mirroring, and freeform rect.
    public var crop = Crop()
    /// Canvas preset and interactive transform state.
    public var canvas = Canvas()
    /// Color adjustment values used by preview and export.
    public var adjusts = Adjusts()
    /// Frame/background styling state.
    public var frame = Frame()
    /// Extra recorded-audio state.
    public var audio = Audio()
    /// Transcript generation and editing state.
    public var transcript = Transcript()
    /// UI presentation state that should survive across editing sessions.
    public var presentation = Presentation()

    /// Typed schema version when the stored payload is recognized by this package.
    public var schemaVersion: SchemaVersion? {
        SchemaVersion(rawValue: version)
    }

    // MARK: - Private Properties

    private var opaquePayload: OpaquePayload?

    private enum CodingKeys: String, CodingKey {
        case version
        case trim
        case playback
        case crop
        case canvas
        case adjusts
        case frame
        case audio
        case transcript
        case presentation
    }

    // MARK: - Initializer

    public init(
        version: Int = Self.currentSchemaVersion.rawValue,
        trim: Trim = .init(),
        playback: Playback = .init(),
        crop: Crop = .init(),
        canvas: Canvas = .init(),
        adjusts: Adjusts = .init(),
        frame: Frame = .init(),
        audio: Audio = .init(),
        transcript: Transcript = .init(),
        presentation: Presentation = .init()
    ) {
        self.version = version
        self.trim = trim
        self.playback = playback
        self.crop = crop
        self.canvas = canvas
        self.adjusts = adjusts
        self.frame = frame
        self.audio = audio
        self.transcript = transcript
        self.presentation = presentation
    }

    public init(from decoder: any Decoder) throws {
        let opaquePayload = try OpaquePayload(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version)

        self = try Self(
            decodedFrom: container,
            version: decodedVersion ?? SchemaVersion.current.rawValue
        )
        self.opaquePayload = opaquePayload
        self = self.migratedToCurrentSchema()
    }

    // MARK: - Public Methods

    public func encode(to encoder: any Encoder) throws {
        if schemaVersion == nil, let opaquePayload {
            try opaquePayload.encode(to: encoder)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion.rawValue, forKey: .version)
        try container.encode(trim, forKey: .trim)
        try container.encode(playback, forKey: .playback)
        try container.encode(crop, forKey: .crop)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(adjusts, forKey: .adjusts)
        try container.encode(frame, forKey: .frame)
        try container.encode(audio, forKey: .audio)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(presentation, forKey: .presentation)
    }

    // MARK: - Private Initializer

    private init(
        decodedFrom container: KeyedDecodingContainer<CodingKeys>,
        version: Int
    ) throws {
        let decodedAdjusts = try container.decodeIfPresent(Adjusts.self, forKey: .adjusts) ?? .init()

        self.init(
            version: version,
            trim: try container.decodeIfPresent(Trim.self, forKey: .trim) ?? .init(),
            playback: try container.decodeIfPresent(Playback.self, forKey: .playback) ?? .init(),
            crop: try container.decodeIfPresent(Crop.self, forKey: .crop) ?? .init(),
            canvas: try container.decodeIfPresent(Canvas.self, forKey: .canvas) ?? .init(),
            adjusts: decodedAdjusts,
            frame: try container.decodeIfPresent(Frame.self, forKey: .frame) ?? .init(),
            audio: try container.decodeIfPresent(Audio.self, forKey: .audio) ?? .init(),
            transcript: try container.decodeIfPresent(Transcript.self, forKey: .transcript) ?? .init(),
            presentation: try container.decodeIfPresent(Presentation.self, forKey: .presentation) ?? .init()
        )
    }

    // MARK: - Private Methods

    private func migratedToCurrentSchema() -> Self {
        guard let schemaVersion else {
            return preservingVersion(version)
        }

        switch schemaVersion {
        case .v1:
            return preservingVersion(Self.currentSchemaVersion.rawValue)
                .clearingOpaquePayload()
        case .current:
            return preservingVersion(Self.currentSchemaVersion.rawValue)
                .clearingOpaquePayload()
        }
    }

    private func preservingVersion(_ version: Int) -> Self {
        var configuration = self
        configuration.version = version
        return configuration
    }

    private func clearingOpaquePayload() -> Self {
        var configuration = self
        configuration.opaquePayload = nil
        return configuration
    }

}

extension VideoEditingConfiguration {

    /// Schema versions supported by persisted editing snapshots.
    public enum SchemaVersion: Int, Codable, Equatable, Sendable {
        case v1 = 1
        case current = 2
    }

    /// Trim bounds stored in source timeline seconds.
    public struct Trim: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var lowerBound: Double = 0
        public var upperBound: Double = 0

        // MARK: - Initializer

        public init(
            lowerBound: Double = 0,
            upperBound: Double = 0
        ) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }

    }

    /// Playback and source-audio settings.
    public struct Playback: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var rate: Float = 1
        public var videoVolume: Float = 1
        public var currentTimelineTime: Double?

        // MARK: - Initializer

        public init(
            rate: Float = 1,
            videoVolume: Float = 1,
            currentTimelineTime: Double? = nil
        ) {
            self.rate = rate
            self.videoVolume = videoVolume
            self.currentTimelineTime = currentTimelineTime
        }

    }

    /// Crop, rotation, and mirror state.
    public struct Crop: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var rotationDegrees: Double = 0
        public var isMirrored = false
        public var freeformRect: FreeformRect?

        // MARK: - Initializer

        public init(
            rotationDegrees: Double = 0,
            isMirrored: Bool = false,
            freeformRect: FreeformRect? = nil
        ) {
            self.rotationDegrees = rotationDegrees
            self.isMirrored = isMirrored
            self.freeformRect = freeformRect
        }

    }

    /// A normalized freeform crop rectangle encoded relative to a reference size.
    public struct FreeformRect: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        // MARK: - Initializer

        public init(
            x: Double,
            y: Double,
            width: Double,
            height: Double
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

    }

    /// Color adjustment values shared by preview and export.
    public struct Adjusts: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var brightness: Double = 0
        public var contrast: Double = 0
        public var saturation: Double = 0

        // MARK: - Initializer

        public init(
            brightness: Double = 0,
            contrast: Double = 0,
            saturation: Double = 0
        ) {
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
        }

    }

    /// Canvas state persisted alongside the rest of the editing snapshot.
    public struct Canvas: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var snapshot: VideoCanvasSnapshot = .initial

        // MARK: - Initializer

        public init(snapshot: VideoCanvasSnapshot = .initial) {
            self.snapshot = snapshot
        }

    }

    /// Background frame styling for the rendered video.
    public struct Frame: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var scaleValue: Double = 0
        public var colorToken: String?

        // MARK: - Initializer

        public init(
            scaleValue: Double = 0,
            colorToken: String? = nil
        ) {
            self.scaleValue = scaleValue
            self.colorToken = colorToken
        }

    }

    /// Optional recorded-audio state and selected-audio-track state.
    public struct Audio: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var recordedClip: RecordedClip?
        public var selectedTrack: SelectedTrack = .video

        // MARK: - Initializer

        public init(
            recordedClip: RecordedClip? = nil,
            selectedTrack: SelectedTrack = .video
        ) {
            self.recordedClip = recordedClip
            self.selectedTrack = selectedTrack
        }

    }

    /// Metadata for the single recorded audio clip supported by the current editor.
    public struct RecordedClip: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var url: URL
        public var duration: Double
        public var volume: Float = 1

        // MARK: - Initializer

        public init(
            url: URL,
            duration: Double,
            volume: Float = 1
        ) {
            self.url = url
            self.duration = duration
            self.volume = volume
        }

    }

    /// Transcript feature state stored inside the editing snapshot.
    public struct Transcript: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var featureState: TranscriptFeaturePersistenceState = .idle
        public var document: TranscriptDocument?

        // MARK: - Initializer

        public init(
            featureState: TranscriptFeaturePersistenceState = .idle,
            document: TranscriptDocument? = nil
        ) {
            self.featureState = featureState
            self.document = document
        }

    }

    /// UI presentation state that should round-trip with persisted edits.
    public struct Presentation: Codable, Equatable, Sendable {

        // MARK: - Public Properties

        public var selectedTool: ToolEnum?
        public var socialVideoDestination: SocialVideoDestination?
        public var showsSafeAreaGuides = false

        // MARK: - Private Properties

        private enum CodingKeys: String, CodingKey {
            case selectedTool
            case socialVideoDestination
            case showsSafeAreaGuides
        }

        // MARK: - Initializer

        public init(
            _ selectedTool: ToolEnum? = nil,
            socialVideoDestination: SocialVideoDestination? = nil,
            showsSafeAreaGuides: Bool = false
        ) {
            self.selectedTool = selectedTool
            self.socialVideoDestination = socialVideoDestination
            self.showsSafeAreaGuides = showsSafeAreaGuides
        }

        // MARK: - Public Methods

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if let selectedToolRawValue = try container.decodeIfPresent(Int.self, forKey: .selectedTool) {
                selectedTool = ToolEnum(rawValue: selectedToolRawValue)
            } else {
                selectedTool = nil
            }

            socialVideoDestination = try container.decodeIfPresent(
                SocialVideoDestination.self,
                forKey: .socialVideoDestination
            )
            showsSafeAreaGuides =
                try container.decodeIfPresent(Bool.self, forKey: .showsSafeAreaGuides)
                ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(selectedTool?.rawValue, forKey: .selectedTool)
            try container.encodeIfPresent(socialVideoDestination, forKey: .socialVideoDestination)
            try container.encode(showsSafeAreaGuides, forKey: .showsSafeAreaGuides)
        }

    }

    /// The audio track currently selected by the editor UI.
    public enum SelectedTrack: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
        case video
        case recorded

        // MARK: - Public Properties

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .video:
                VideoEditorStrings.selectedTrackVideo
            case .recorded:
                VideoEditorStrings.selectedTrackRecorded
            }
        }
    }

    /// Supported short-form social destinations used by preset-related UI.
    public enum SocialVideoDestination: String, Codable, CaseIterable, Equatable, Sendable {
        case instagramReels
        case tikTok
        case youtubeShorts

        // MARK: - Public Properties

        public var title: String {
            switch self {
            case .instagramReels:
                VideoEditorStrings.destinationInstagramReels
            case .tikTok:
                VideoEditorStrings.destinationTikTok
            case .youtubeShorts:
                VideoEditorStrings.destinationYouTubeShorts
            }
        }

        public var shortTitle: String {
            switch self {
            case .instagramReels:
                VideoEditorStrings.destinationInstagramShort
            case .tikTok:
                VideoEditorStrings.destinationTikTokShort
            case .youtubeShorts:
                VideoEditorStrings.destinationShortsShort
            }
        }
    }

}

extension VideoEditingConfiguration {

    // MARK: - Public Properties

    /// A normalized configuration suitable for autosave deduplication.
    public var continuousSaveFingerprint: Self {
        var configuration = self
        configuration.playback.currentTimelineTime = nil
        configuration.audio.selectedTrack = .video
        configuration.presentation.selectedTool = nil
        configuration.presentation.showsSafeAreaGuides = false
        configuration.canvas.snapshot.showsSafeAreaOverlay = false
        return configuration
    }

}

private enum OpaquePayload: Codable, Equatable, Sendable {

    // MARK: - Cases

    case object([String: Self])
    case array([Self])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: - Initializer

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([Self].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: Self].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported opaque JSON payload."
            )
        }
    }

    // MARK: - Public Methods

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .integer(let integer):
            try container.encode(integer)
        case .number(let number):
            try container.encode(number)
        case .bool(let bool):
            try container.encode(bool)
        case .null:
            try container.encodeNil()
        }
    }

}

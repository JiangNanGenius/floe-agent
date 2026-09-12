import CoreGraphics
import Foundation

/// Canvas presets supported by the package preview and export mapping system.
public enum VideoCanvasPreset: Codable, Equatable, Sendable {

    // MARK: - Cases

    case original
    case free
    case custom(width: Int, height: Int)
    case social(platform: SocialPlatform)
    case story
    case facebookPost

    // MARK: - Private Properties

    private enum CodingKeys: String, CodingKey {
        case kind
        case width
        case height
        case platform
    }

    private enum Kind: String, Codable {
        case original
        case free
        case custom
        case social
        case story
        case facebookPost
    }

    // MARK: - Initializer

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .original:
            self = .original
        case .free:
            self = .free
        case .custom:
            self = .custom(
                width: try container.decode(Int.self, forKey: .width),
                height: try container.decode(Int.self, forKey: .height)
            )
        case .social:
            self = .social(
                platform: try container.decode(
                    SocialPlatform.self,
                    forKey: .platform
                )
            )
        case .story:
            self = .story
        case .facebookPost:
            self = .facebookPost
        }
    }

    // MARK: - Public Properties

    /// Human-readable title used by the package UI.
    public var title: String {
        switch self {
        case .original:
            VideoEditorStrings.canvasOriginal
        case .free:
            VideoEditorStrings.canvasFree
        case .custom:
            VideoEditorStrings.canvasCustom
        case .social(let platform):
            platform.title
        case .story:
            VideoEditorStrings.canvasStory
        case .facebookPost:
            VideoEditorStrings.canvasFacebookPost
        }
    }

    /// Indicates whether the preset represents a short-form social output.
    public var isSocial: Bool {
        switch self {
        case .social:
            true
        case .original,
            .free,
            .custom,
            .story,
            .facebookPost:
            false
        }
    }

    // MARK: - Public Methods

    /// Encodes the preset while preserving associated values.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .original:
            try container.encode(Kind.original, forKey: .kind)
        case .free:
            try container.encode(Kind.free, forKey: .kind)
        case .custom(let width, let height):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        case .social(let platform):
            try container.encode(Kind.social, forKey: .kind)
            try container.encode(platform, forKey: .platform)
        case .story:
            try container.encode(Kind.story, forKey: .kind)
        case .facebookPost:
            try container.encode(Kind.facebookPost, forKey: .kind)
        }
    }

    /// Resolves the export canvas size for the preset.
    public func resolvedExportSize(
        naturalSize: CGSize,
        freeCanvasSize: CGSize
    ) -> CGSize {
        switch self {
        case .original:
            return resolvedSize(
                fallback: CGSize(width: 1080, height: 1920),
                candidate: naturalSize
            )
        case .free:
            return resolvedSize(
                fallback: CGSize(width: 1080, height: 1080),
                candidate: freeCanvasSize
            )
        case .custom(let width, let height):
            return resolvedSize(
                fallback: CGSize(width: 1080, height: 1080),
                candidate: CGSize(width: width, height: height)
            )
        case .social,
            .story:
            return CGSize(width: 1080, height: 1920)
        case .facebookPost:
            return CGSize(width: 1080, height: 1350)
        }
    }

    /// Converts the legacy crop-preset selection into the newer canvas preset model.
    public static func fromLegacySelection(
        preset: VideoCropFormatPreset,
        socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?
    ) -> Self {
        switch preset {
        case .original:
            .original
        case .vertical9x16:
            if let socialVideoDestination {
                .social(platform: socialVideoDestination.socialPlatform)
            } else {
                .story
            }
        case .square1x1:
            .custom(width: 1080, height: 1080)
        case .portrait4x5:
            .facebookPost
        case .landscape16x9:
            .custom(width: 1920, height: 1080)
        }
    }

    // MARK: - Private Methods

    private func resolvedSize(
        fallback: CGSize,
        candidate: CGSize
    ) -> CGSize {
        guard candidate.width > 0, candidate.height > 0 else {
            return fallback
        }

        return CGSize(
            width: max(round(candidate.width), 1),
            height: max(round(candidate.height), 1)
        )
    }

}

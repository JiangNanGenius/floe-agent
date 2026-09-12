import AVFoundation
import CoreGraphics
import Foundation

/// Export qualities supported by the current package export pipeline.
public enum VideoQuality: Int, CaseIterable, Sendable {

    // MARK: - Public Properties

    case original = -1
    case low = 0
    case medium = 1
    case high = 2

    /// Orientation used when resolving a final output size.
    public enum RenderLayout: Sendable {
        case landscape
        case portrait
    }

    /// The AVFoundation preset used by the current export implementation.
    public var exportPresetName: String {
        switch self {
        case .original:
            AVAssetExportPresetHighestQuality
        case .low:
            AVAssetExportPresetMediumQuality
        case .high, .medium:
            AVAssetExportPresetHighestQuality
        }
    }

    /// Display ordering used by the package export UI.
    public var order: Int {
        switch self {
        case .original:
            3
        case .high:
            0
        case .medium:
            1
        case .low:
            2
        }
    }

    /// Human-readable title shown in the export sheet.
    public var title: String {
        switch self {
        case .original:
            VideoEditorStrings.qualityOriginalTitle
        case .low:
            VideoEditorStrings.qualityLowTitle
        case .medium:
            VideoEditorStrings.qualityMediumTitle
        case .high:
            VideoEditorStrings.qualityHighTitle
        }
    }

    /// Human-readable subtitle describing the target export profile.
    public var subtitle: String {
        switch self {
        case .original:
            VideoEditorStrings.qualityOriginalSubtitle
        case .low:
            VideoEditorStrings.qualityLowSubtitle
        case .medium:
            VideoEditorStrings.qualityMediumSubtitle
        case .high:
            VideoEditorStrings.qualityHighSubtitle
        }
    }

    /// The base landscape render size for the quality.
    public var size: CGSize {
        switch self {
        case .original, .high:
            .init(width: 1920, height: 1080)
        case .low:
            .init(width: 854, height: 480)
        case .medium:
            .init(width: 1280, height: 720)
        }
    }

    /// The portrait render size for the quality.
    public var portraitSize: CGSize {
        CGSize(width: size.height, height: size.width)
    }

    /// The target frame rate used by the current export implementation.
    public var frameRate: Double {
        switch self {
        case .low, .medium:
            30
        case .original, .high:
            60
        }
    }

    /// Whether this export option should resolve the output from the source asset.
    public var isOriginal: Bool {
        self == .original
    }

    // MARK: - Public Methods

    /// Resolves the render size for a given orientation.
    public func size(for layout: RenderLayout) -> CGSize {
        switch layout {
        case .landscape:
            size
        case .portrait:
            portraitSize
        }
    }

}

/// Host-facing availability wrapper for `VideoQuality`.
public struct ExportQualityAvailability: Hashable, Identifiable {

    // MARK: - Public Properties

    /// Convenience list with every quality enabled.
    public static var allEnabled: [Self] {
        enabled([.high, .medium, .low, .original])
    }

    /// Convenience list commonly used for premium gating flows.
    public static var premiumLocked: [Self] {
        [
            .enabled(.low),
            .blocked(.medium),
            .blocked(.high),
            .enabled(.original),
        ]
    }

    /// The export quality being configured.
    public let quality: VideoQuality
    /// Whether the quality is enabled or visible-but-blocked.
    public let access: ToolAvailability.Access
    /// Relative ordering used by the export sheet.
    public let order: Int

    /// Stable identifier for SwiftUI collections.
    public var id: VideoQuality {
        quality
    }

    public var isBlocked: Bool {
        access == .blocked
    }

    public var isEnabled: Bool {
        access == .enabled
    }

    // MARK: - Initializer

    /// Creates an availability entry for one export quality.
    public init(
        _ quality: VideoQuality,
        access: ToolAvailability.Access = .enabled,
        order: Int? = nil
    ) {
        self.quality = quality
        self.access = quality.isOriginal ? .enabled : access
        self.order = order ?? quality.order
    }

    /// Convenience constructor for an enabled export quality.
    public static func enabled(
        _ quality: VideoQuality,
        order: Int? = nil
    ) -> Self {
        .init(quality, order: order)
    }

    /// Convenience constructor for a blocked export quality.
    public static func blocked(
        _ quality: VideoQuality,
        order: Int? = nil
    ) -> Self {
        .init(quality, access: .blocked, order: order)
    }

    /// Maps a list of qualities into enabled availability entries.
    public static func enabled(_ qualities: [VideoQuality]) -> [Self] {
        qualities.map { Self.enabled($0) }
    }

}

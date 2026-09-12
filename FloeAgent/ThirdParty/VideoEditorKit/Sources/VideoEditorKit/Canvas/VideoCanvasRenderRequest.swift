import CoreGraphics
import Foundation

/// Immutable description of the source video used by the canvas mapping system.
public struct VideoCanvasSourceDescriptor: Equatable, Sendable {

    // MARK: - Public Properties

    /// Natural pixel size reported by the source track.
    public let naturalSize: CGSize
    /// Preferred transform reported by the source track.
    public let preferredTransform: CGAffineTransform
    /// User-authored rotation in degrees stored in editing state.
    public let userRotationDegrees: Double
    /// Whether the content should be mirrored horizontally.
    public let isMirrored: Bool

    /// The presentation size after applying the preferred transform.
    public var resolvedPresentationSize: CGSize {
        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let resolvedSize = CGSize(
            width: abs(transformedBounds.width),
            height: abs(transformedBounds.height)
        )

        guard resolvedSize.width > 0, resolvedSize.height > 0 else {
            return naturalSize
        }

        return resolvedSize
    }

    // MARK: - Initializer

    public init(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        userRotationDegrees: Double,
        isMirrored: Bool
    ) {
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.userRotationDegrees = userRotationDegrees
        self.isMirrored = isMirrored
    }

}

/// A preset paired with its resolved export size.
public struct VideoCanvasResolvedPreset: Equatable, Sendable {

    // MARK: - Public Properties

    public let preset: VideoCanvasPreset
    public let exportSize: CGSize

    // MARK: - Initializer

    public init(
        preset: VideoCanvasPreset,
        exportSize: CGSize
    ) {
        self.preset = preset
        self.exportSize = exportSize
    }

}

/// Immutable input bundle used to derive preview and export mappings.
public struct VideoCanvasRenderRequest: Equatable, Sendable {

    // MARK: - Public Properties

    public let source: VideoCanvasSourceDescriptor
    public let snapshot: VideoCanvasSnapshot
    public let resolvedPreset: VideoCanvasResolvedPreset

    // MARK: - Initializer

    public init(
        source: VideoCanvasSourceDescriptor,
        snapshot: VideoCanvasSnapshot,
        resolvedPreset: VideoCanvasResolvedPreset
    ) {
        self.source = source
        self.snapshot = snapshot
        self.resolvedPreset = resolvedPreset
    }

}

/// Final geometry used by the export pipeline to compose rendered content.
public struct VideoCanvasExportMapping: Equatable, Sendable {

    // MARK: - Public Properties

    public let renderSize: CGSize
    public let orientedSourceSize: CGSize
    public let aspectFillScale: CGFloat
    public let contentTransform: CGAffineTransform
    public let totalRotationRadians: CGFloat

    // MARK: - Initializer

    public init(
        renderSize: CGSize,
        orientedSourceSize: CGSize,
        aspectFillScale: CGFloat,
        contentTransform: CGAffineTransform,
        totalRotationRadians: CGFloat
    ) {
        self.renderSize = renderSize
        self.orientedSourceSize = orientedSourceSize
        self.aspectFillScale = aspectFillScale
        self.contentTransform = contentTransform
        self.totalRotationRadians = totalRotationRadians
    }

}

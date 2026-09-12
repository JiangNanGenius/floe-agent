import CoreGraphics
import Foundation

/// Interactive transform state applied to the source video inside the canvas.
public struct VideoCanvasTransform: Codable, Equatable, Sendable {

    // MARK: - Public Properties

    /// Identity transform used as the default canvas state.
    public static let identity = Self()

    /// Normalized offset relative to the canvas center.
    public var normalizedOffset: CGPoint = .zero
    /// Scale factor applied after aspect-fill placement.
    public var zoom: CGFloat = 1
    /// Additional user rotation in radians.
    public var rotationRadians: CGFloat = 0

    /// Returns `true` when the transform is effectively unchanged.
    public var isIdentity: Bool {
        abs(normalizedOffset.x) < Constants.numericTolerance
            && abs(normalizedOffset.y) < Constants.numericTolerance
            && abs(zoom - 1) < Constants.numericTolerance
            && abs(rotationRadians) < Constants.numericTolerance
    }

    /// Returns `true` when host UI should show a reset affordance.
    public var shouldShowResetButton: Bool {
        isIdentity == false
    }

    // MARK: - Private Properties

    private enum Constants {
        static let numericTolerance: CGFloat = 0.001
    }

    // MARK: - Initializer

    public init(
        normalizedOffset: CGPoint = .zero,
        zoom: CGFloat = 1,
        rotationRadians: CGFloat = 0
    ) {
        self.normalizedOffset = normalizedOffset
        self.zoom = zoom
        self.rotationRadians = rotationRadians
    }

}

/// A serializable canvas snapshot that can be stored inside `VideoEditingConfiguration`.
public struct VideoCanvasSnapshot: Codable, Equatable, Sendable {

    // MARK: - Public Properties

    /// Default empty canvas snapshot.
    public static let initial = Self()

    /// Active output preset.
    public var preset: VideoCanvasPreset = .original
    /// Custom canvas size used when `preset` is `.free`.
    public var freeCanvasSize = CGSize(width: 1080, height: 1080)
    /// Interactive transform applied to the source content.
    public var transform: VideoCanvasTransform = .identity
    /// Whether safe-area overlays should be shown in preview.
    public var showsSafeAreaOverlay = false

    /// Returns `true` when the snapshot is equivalent to the package default.
    public var isIdentity: Bool {
        preset == .original
            && transform.isIdentity
    }

    // MARK: - Initializer

    public init(
        preset: VideoCanvasPreset = .original,
        freeCanvasSize: CGSize = CGSize(width: 1080, height: 1080),
        transform: VideoCanvasTransform = .identity,
        showsSafeAreaOverlay: Bool = false
    ) {
        self.preset = preset
        self.freeCanvasSize = freeCanvasSize
        self.transform = transform
        self.showsSafeAreaOverlay = showsSafeAreaOverlay
    }

}

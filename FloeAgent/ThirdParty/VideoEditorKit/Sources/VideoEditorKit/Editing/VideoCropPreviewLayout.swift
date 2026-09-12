import CoreGraphics
import Foundation

public struct VideoCropPreviewLayout: Equatable, Sendable {

    // MARK: - Public Properties

    public let sourceRect: CGRect
    public let presetSourceRect: CGRect
    public let viewportRect: CGRect
    public let contentScale: CGFloat
    public let contentOffset: CGSize
    public let referenceScale: CGFloat

    // MARK: - Initializer

    public init?(
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) {
        guard
            let resolvedGeometry = Self.resolvedGeometry(
                freeformRect: freeformRect,
                in: referenceSize
            )
        else { return nil }

        self.init(
            sourceRect: resolvedGeometry.sourceRect,
            presetSourceRect: resolvedGeometry.presetSourceRect,
            viewportRect: resolvedGeometry.presetSourceRect
        )
    }

    public init?(
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        sourceSize: CGSize,
        viewportSize: CGSize
    ) {
        self.init(
            freeformRect: freeformRect,
            referenceSize: sourceSize,
            contentSize: sourceSize,
            viewportSize: viewportSize
        )
    }

    public init?(
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        referenceSize: CGSize,
        contentSize: CGSize,
        viewportSize: CGSize
    ) {
        guard
            referenceSize.width > 0,
            referenceSize.height > 0,
            contentSize.width > 0,
            contentSize.height > 0,
            viewportSize.width > 0,
            viewportSize.height > 0,
            let resolvedGeometry = Self.resolvedGeometry(
                freeformRect: freeformRect,
                in: referenceSize
            )
        else { return nil }

        self.init(
            sourceRect: resolvedGeometry.sourceRect,
            presetSourceRect: resolvedGeometry.presetSourceRect,
            viewportRect: CGRect(origin: .zero, size: viewportSize),
            contentSize: contentSize,
            referenceSize: referenceSize
        )
    }

    private init(
        sourceRect: CGRect,
        presetSourceRect: CGRect,
        viewportRect: CGRect,
        contentSize: CGSize? = nil,
        referenceSize: CGSize? = nil
    ) {
        let resolvedReferenceScale = max(
            viewportRect.width / sourceRect.width,
            viewportRect.height / sourceRect.height
        )
        let baseContentScale: CGFloat

        if let contentSize,
            let referenceSize,
            referenceSize.width > 0,
            referenceSize.height > 0
        {
            baseContentScale = min(
                contentSize.width / referenceSize.width,
                contentSize.height / referenceSize.height
            )
        } else {
            baseContentScale = 1
        }

        let resolvedContentScale = resolvedReferenceScale / max(baseContentScale, 0.0001)

        let resolvedContentOffset = CGSize(
            width: viewportRect.minX - sourceRect.minX * resolvedReferenceScale,
            height: viewportRect.minY - sourceRect.minY * resolvedReferenceScale
        )

        self.sourceRect = sourceRect
        self.presetSourceRect = presetSourceRect
        self.viewportRect = viewportRect
        self.contentScale = resolvedContentScale
        self.contentOffset = resolvedContentOffset
        self.referenceScale = resolvedReferenceScale
    }

    // MARK: - Public Methods

    public func sourceTranslation(for gestureTranslation: CGSize) -> CGSize {
        guard referenceScale > 0 else { return .zero }

        return CGSize(
            width: -gestureTranslation.width / referenceScale,
            height: -gestureTranslation.height / referenceScale
        )
    }

    public static func resolvedGeometry(
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        in sourceSize: CGSize
    ) -> (sourceRect: CGRect, presetSourceRect: CGRect)? {
        guard
            let sourceRect = Self.visibleRect(
                from: freeformRect,
                in: sourceSize
            ),
            let viewportFreeformRect = VideoCropFormatPreset.resetRect(
                matching: freeformRect,
                in: sourceSize
            ),
            let presetSourceRect = Self.visibleRect(
                from: viewportFreeformRect,
                in: sourceSize
            ),
            sourceRect.width > 0,
            sourceRect.height > 0,
            presetSourceRect.width > 0,
            presetSourceRect.height > 0
        else { return nil }

        return (sourceRect, presetSourceRect)
    }

    // MARK: - Private Methods

    private static func decodedRect(
        from freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) -> CGRect? {
        guard let freeformRect else { return nil }
        guard referenceSize.width > 0, referenceSize.height > 0 else { return nil }

        return CGRect(
            x: freeformRect.x * referenceSize.width,
            y: freeformRect.y * referenceSize.height,
            width: freeformRect.width * referenceSize.width,
            height: freeformRect.height * referenceSize.height
        )
    }

    private static func visibleRect(
        from freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) -> CGRect? {
        guard
            let decodedRect = Self.decodedRect(
                from: freeformRect,
                in: referenceSize
            )?.standardized
        else { return nil }

        let bounds = CGRect(origin: .zero, size: referenceSize)
        let visibleRect = decodedRect.intersection(bounds)

        guard !visibleRect.isNull, !visibleRect.isEmpty else { return nil }
        return visibleRect
    }

}

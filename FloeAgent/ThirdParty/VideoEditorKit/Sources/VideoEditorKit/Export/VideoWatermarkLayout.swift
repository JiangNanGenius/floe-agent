import CoreGraphics

/// Resolves the export-space frame for a host-provided watermark image.
public enum VideoWatermarkLayout {

    // MARK: - Public Properties

    public static let padding: CGFloat = 16

    // MARK: - Private Properties

    private static let widthRatio: CGFloat = 0.16

    // MARK: - Public Methods

    public static func frame(
        renderSize: CGSize,
        imageSize: CGSize,
        position: VideoWatermarkPosition
    ) -> CGRect {
        let renderWidth = resolvedDimension(renderSize.width)
        let renderHeight = resolvedDimension(renderSize.height)
        let imageWidth = resolvedDimension(imageSize.width)
        let imageHeight = resolvedDimension(imageSize.height)
        let width = max(renderWidth, renderHeight) * widthRatio
        let height = resolvedHeight(width: width, imageWidth: imageWidth, imageHeight: imageHeight)

        let origin: CGPoint =
            switch position {
            case .topLeading:
                CGPoint(x: padding, y: padding)
            case .topTrailing:
                CGPoint(x: renderWidth - width - padding, y: padding)
            case .bottomLeading:
                CGPoint(x: padding, y: renderHeight - height - padding)
            case .bottomTrailing:
                CGPoint(x: renderWidth - width - padding, y: renderHeight - height - padding)
            }

        return CGRect(
            origin: origin,
            size: CGSize(width: width, height: height)
        )
    }

    // MARK: - Private Methods

    private static func resolvedDimension(_ dimension: CGFloat) -> CGFloat {
        guard dimension.isFinite, dimension > 0 else { return 0 }
        return dimension
    }

    private static func resolvedHeight(width: CGFloat, imageWidth: CGFloat, imageHeight: CGFloat) -> CGFloat {
        guard width > 0, imageWidth > 0, imageHeight > 0 else { return 0 }
        return width * imageHeight / imageWidth
    }

}

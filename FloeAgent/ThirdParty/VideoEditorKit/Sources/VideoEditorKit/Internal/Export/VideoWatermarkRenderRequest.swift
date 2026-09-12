import CoreGraphics
import SwiftUI

struct VideoWatermarkRenderRequest: @unchecked Sendable {

    // MARK: - Public Properties

    let image: CGImage
    let imageSize: CGSize
    let imageScale: CGFloat
    let opacity: Float
    let position: VideoWatermarkPosition

    // MARK: - Private Properties

    private static let defaultOpacity: Float = 0.4

    // MARK: - Initializer

    @MainActor
    init?(_ configuration: VideoWatermarkConfiguration?) {
        guard let configuration else { return nil }
        guard let cgImage = Self.rasterizedImage(from: configuration.image) else { return nil }

        image = cgImage
        imageSize = configuration.image.size
        imageScale = max(configuration.image.scale, 1)
        opacity = Self.defaultOpacity
        position = configuration.position
    }

    @MainActor
    static func isRenderableImage(_ image: UIImage) -> Bool {
        isRenderableSize(image.size)
    }

    // MARK: - Private Methods

    @MainActor
    private static func rasterizedImage(from image: UIImage) -> CGImage? {
        guard isRenderableImage(image) else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = max(image.scale, 1)
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: image.size,
            format: format
        )
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    private static func isRenderableSize(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

}

extension VideoWatermarkConfiguration {

    // MARK: - Public Properties

    @MainActor
    var isRenderableWatermark: Bool {
        VideoWatermarkRenderRequest.isRenderableImage(image)
    }

}

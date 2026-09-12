import SwiftUI
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoEditorPlayerStageViewTests")
struct VideoEditorPlayerStageViewTests {

    // MARK: - Public Methods

    @Test
    func loadingPlaceholderDoesNotRenderABrightBorder() throws {
        let stage = VideoEditorPlayerStageView(
            .loading,
            source: .init(
                naturalSize: CGSize(width: 1080, height: 1080),
                preferredTransform: .identity,
                userRotationDegrees: 0,
                isMirrored: false
            ),
            isCanvasInteractive: false
        ) {
            Color.clear
        } overlay: { _ in
            EmptyView()
        }
        .frame(width: 320, height: 400)
        .background(.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: stage)
        renderer.scale = 1

        let cgImage = try #require(renderer.uiImage?.cgImage)

        #expect(pixelColor(in: cgImage, x: 160, y: 42)?.isBright == false)
    }

}

private struct PixelColor {

    // MARK: - Public Properties

    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var isBright: Bool {
        red > 180 && green > 180 && blue > 180 && alpha > 200
    }

}

private func pixelColor(
    in image: CGImage,
    x: Int,
    y: Int
) -> PixelColor? {
    guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
    guard let dataProviderData = image.dataProvider?.data else { return nil }
    guard let data = CFDataGetBytePtr(dataProviderData) else { return nil }

    let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
    let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
    guard offset + 3 < CFDataGetLength(dataProviderData) else { return nil }

    return PixelColor(
        red: data[offset],
        green: data[offset + 1],
        blue: data[offset + 2],
        alpha: data[offset + 3]
    )
}

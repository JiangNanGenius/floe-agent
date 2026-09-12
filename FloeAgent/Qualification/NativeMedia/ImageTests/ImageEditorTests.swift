import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ZLImageEditor
@testable import FloeMediaUISmoke

@MainActor
final class ImageEditorTests: XCTestCase {
    private func source() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
    }

    func testPNGReadbackPreservesAlphaAndPixelSize() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let data = try ImageEditorFiles.verifiedPNG(image)
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(decoded.alphaInfo))
    }

    func testLoadAppliesEXIFOrientationWithoutChangingOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(source().cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let loaded = try ImageEditorFiles.load(url)
        XCTAssertEqual(loaded.cgImage?.width, 300)
        XCTAssertEqual(loaded.cgImage?.height, 400)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testInvalidSourceFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageEditorFiles.load(url))
        XCTAssertThrowsError(try ImageEditorFiles.load(url.deletingLastPathComponent()))
    }

    func testLibraryCropAndChineseTextProduceRealPNG() async throws {
        let input = source()
        let before = try ImageEditorFiles.verifiedPNG(input)
        let sticker = ZLTextStickerState(id: UUID().uuidString, text: "画布中文", textColor: .white,
            font: .systemFont(ofSize: 32), style: .normal, originScale: 1, originAngle: 0,
            originFrame: CGRect(x: 30, y: 30, width: 180, height: 80), gesScale: 1,
            gesRotation: 0, totalTranslationPoint: .zero)
        let model = ZLEditImageModel(clipStatus: .init(editRect: CGRect(x: 0, y: 0, width: 300, height: 200)), stickers: [sticker])
        let controller = ZLEditImageViewController(image: input, editModel: model)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await withCheckedContinuation { continuation in
            host.present(controller, animated: false) { continuation.resume() }
        }
        controller.view.layoutIfNeeded()
        let finished = expectation(description: "library rendered and returned image")
        var result: UIImage?
        controller.editFinishBlock = { image, _ in result = image; finished.fulfill() }
        controller.doneBtn.sendActions(for: .touchUpInside)
        await fulfillment(of: [finished], timeout: 20)
        let data = try ImageEditorFiles.verifiedPNG(XCTUnwrap(result))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 200)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let whitePixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 180 && pixels[$0 + 1] > 180 && pixels[$0 + 2] > 180
        }.count
        XCTAssertGreaterThan(whitePixels, 20, "Chinese text must be rendered into the output pixels")
        XCTAssertEqual(try ImageEditorFiles.verifiedPNG(input), before)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "ZLImageEditor cropped Chinese caption output"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

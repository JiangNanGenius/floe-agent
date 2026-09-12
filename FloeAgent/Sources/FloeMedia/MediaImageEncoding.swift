#if canImport(ImageIO)
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaImageEncoding {
    static func png(_ image: CGImage) -> Data? {
        encode(image, format: "png")
    }

    static func encode(_ image: CGImage, format: String) -> Data? {
        guard ["png", "jpeg"].contains(format) else { return nil }
        let type = format == "png" ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

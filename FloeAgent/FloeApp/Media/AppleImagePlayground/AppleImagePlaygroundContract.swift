import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Native inputs are already resolved by the caller's task authority. No model
/// argument can select a window, conversation, run, or an absolute host URL.
struct AppleImagePlaygroundOwner: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
    let toolCallID: String
}

enum AppleImagePlaygroundIntent: String, Codable, Sendable {
    case generate, edit
}

enum AppleImagePlaygroundStyle: String, Codable, Sendable {
    case automatic, animation, illustration, sketch
}

struct AppleImagePlaygroundInput: Sendable {
    let prompt: String
    var source: AppleImagePlaygroundImage?
    var intent: AppleImagePlaygroundIntent = .generate
    var style: AppleImagePlaygroundStyle = .automatic
    var width: Int?
    var height: Int?

    func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 16_384 else {
            throw AppleImagePlaygroundFailure.invalidInput("A description of 1–16384 UTF-8 bytes is required.")
        }
        guard intent != .edit || source != nil else {
            throw AppleImagePlaygroundFailure.invalidInput("Editing requires an original image.")
        }
        if width != nil || height != nil {
            guard let width, let height, (64...4096).contains(width),
                  (64...4096).contains(height) else {
                throw AppleImagePlaygroundFailure.invalidInput("Supply both width and height, each between 64 and 4096.")
            }
        }
    }
}

/// The temporary system URL is consumed before the sheet is dismissed. Keep
/// the real encoding; never feed generated output through photo JPEG resizing.
struct AppleImagePlaygroundImage: Sendable {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumPixels = 32_000_000
    let data: Data
    let fileExtension: String
    let mimeType: String
    let uti: String
    let width: Int
    let height: Int
    let sha256: String

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,
                  CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maximumPixels / height,
              let encoding = Self.encodings[type],
              CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                  [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw AppleImagePlaygroundFailure.invalidImage
        }
        self.data = data
        self.width = width
        self.height = height
        self.uti = type
        self.fileExtension = encoding.0
        self.mimeType = encoding.1
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(contentsOf url: URL) throws {
        guard url.isFileURL else { throw AppleImagePlaygroundFailure.invalidImage }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= Self.maximumBytes else {
            throw AppleImagePlaygroundFailure.invalidImage
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        try self.init(data: bytes)
    }

    private static let encodings: [String: (String, String)] = [
        UTType.png.identifier: ("png", "image/png"),
        UTType.jpeg.identifier: ("jpg", "image/jpeg"),
        UTType.heic.identifier: ("heic", "image/heic"),
        UTType.heif.identifier: ("heif", "image/heif")
    ]
}

enum AppleImagePlaygroundFailure: Error, Sendable, Equatable, LocalizedError {
    case unavailable, foregroundRequired, busy, cancelled, ownerChanged
    case editingUnavailable, invalidImage
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Image Playground is unavailable on this device."
        case .foregroundRequired: "Open the owning task in Floe before using Image Playground."
        case .busy: "An Image Playground session is already open."
        case .cancelled: "Image creation was cancelled."
        case .ownerChanged: "The original task is no longer available."
        case .editingUnavailable: "Editing an original image requires iOS 27 or later."
        case .invalidImage: "The image is invalid, unsupported, or exceeds the size limit."
        case .invalidInput(let message): message
        }
    }
}

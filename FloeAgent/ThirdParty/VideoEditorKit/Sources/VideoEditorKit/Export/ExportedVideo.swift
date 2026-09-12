import AVFoundation
import CoreGraphics
import Foundation

/// Metadata describing a finished exported video file.
public struct ExportedVideo: Equatable, Sendable {

    // MARK: - Public Properties

    /// File URL of the exported `.mp4`.
    public let url: URL
    /// Resolved presentation width of the exported asset.
    public let width: CGFloat
    /// Resolved presentation height of the exported asset.
    public let height: CGFloat
    /// Duration, in seconds, of the exported asset.
    public let duration: Double
    /// File size in bytes.
    public let fileSize: Int64

    /// Width divided by height for convenience in host UI.
    public var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return width / height
    }

    // MARK: - Initializer

    public init(
        _ url: URL,
        width: CGFloat,
        height: CGFloat,
        duration: Double,
        fileSize: Int64
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.duration = duration
        self.fileSize = fileSize
    }

    // MARK: - Public Methods

    /// Loads export metadata from a file URL asynchronously.
    public static func load(from url: URL) async -> ExportedVideo {
        let asset = AVURLAsset(url: url)
        let presentationSize = await resolvedPresentationSize(for: asset)
        let duration = (try? await asset.load(.duration).seconds) ?? .zero
        let fileSize = resolvedFileSize(for: url)

        return ExportedVideo(
            url,
            width: max(presentationSize.width, 0),
            height: max(presentationSize.height, 0),
            duration: max(duration, 0),
            fileSize: max(fileSize, 0)
        )
    }

    // MARK: - Private Methods

    private static func resolvedFileSize(for url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path())
        let sizeValue = attributes?[.size] as? NSNumber
        return sizeValue?.int64Value ?? 0
    }

    private static func resolvedPresentationSize(for asset: AVURLAsset) async -> CGSize {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return .zero }
        guard let track = tracks.first else { return .zero }
        guard let naturalSize = try? await track.load(.naturalSize) else { return .zero }
        guard let preferredTransform = try? await track.load(.preferredTransform) else {
            return naturalSize
        }

        let transformedSize = naturalSize.applying(preferredTransform)
        let resolvedSize = CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )

        guard resolvedSize.width > 0, resolvedSize.height > 0 else {
            return naturalSize
        }

        return resolvedSize
    }

}

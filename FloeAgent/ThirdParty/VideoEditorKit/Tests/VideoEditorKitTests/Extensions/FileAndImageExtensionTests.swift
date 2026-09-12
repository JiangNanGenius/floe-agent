import CoreGraphics
import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("FileManagerExtensionTests")
struct FileManagerExtensionTests {

    // MARK: - Public Methods

    @Test
    func createImageAndVideoPathsUseTheExpectedFileNamingRules() throws {
        let imageURL = try #require(FileManager.default.createImagePath(with: "cover"))
        let videoURL = try #require(FileManager.default.createVideoPath(with: "sample.mp4"))

        #expect(imageURL.lastPathComponent == "cover.jpg")
        #expect(videoURL.lastPathComponent == "sample.mp4")
    }

    @Test
    func saveRetrieveAndDeleteImageRoundTripsOnDisk() throws {
        let identifier = UUID().uuidString
        let image = TestFixtures.makeSolidImage()
        let imageURL = try #require(FileManager.default.createImagePath(with: identifier))

        defer { FileManager.default.deleteImage(with: identifier) }

        FileManager.default.saveImage(with: identifier, image: image)
        let retrieved = FileManager.default.retrieveImage(with: identifier)

        #expect(FileManager.default.fileExists(atPath: imageURL.path()))
        #expect(retrieved != nil)
        #expect(abs((retrieved?.size.width ?? 0) - image.size.width) < 0.0001)
        #expect(abs((retrieved?.size.height ?? 0) - image.size.height) < 0.0001)

        FileManager.default.deleteImage(with: identifier)

        #expect(FileManager.default.retrieveImage(with: identifier) == nil)
    }

    @Test
    func removeIfExistsDeletesTemporaryFilesAndIgnoresMissingOnes() throws {
        let url = try TestFixtures.createTemporaryFile()

        #expect(FileManager.default.fileExists(atPath: url.path()))

        FileManager.default.removeIfExists(for: url)
        FileManager.default.removeIfExists(for: url)

        #expect(FileManager.default.fileExists(atPath: url.path()) == false)
    }

}

@Suite("UIImageExtensionTests")
struct UIImageExtensionTests {

    // MARK: - Public Methods

    @Test
    func normalizedForDisplayKeepsPointSizeAndUsesANonZeroScale() throws {
        let baseImage = TestFixtures.makeSolidImage(scale: 3)
        let cgImage = try #require(baseImage.cgImage)
        let orientedImage = UIImage(
            cgImage: cgImage,
            scale: 3,
            orientation: .left
        )

        let normalized = orientedImage.normalizedForDisplay(scale: 0.5)

        #expect(abs(normalized.size.width - orientedImage.size.width) < 0.0001)
        #expect(abs(normalized.size.height - orientedImage.size.height) < 0.0001)
        #expect(normalized.scale == 1)
        #expect(normalized.imageOrientation == .up)
    }

    @Test
    func resizeUsesTheRequestedSizeAndScale() {
        let image = TestFixtures.makeSolidImage(size: CGSize(width: 30, height: 10))

        let resized = image.resize(to: CGSize(width: 90, height: 60), scale: 2)

        #expect(abs(resized.size.width - 90) < 0.0001)
        #expect(abs(resized.size.height - 60) < 0.0001)
        #expect(resized.scale == 2)
    }

}

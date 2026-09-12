import AVFoundation
import CoreGraphics
import CoreImage
import Testing

@testable import VideoEditorKit

@Suite("AVAssetExtensionTests")
struct AVAssetExtensionTests {

    // MARK: - Public Methods

    @Test
    func generateImageAndImagesReturnRequestedFramesForATemporaryVideo() async throws {
        let url = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: url) }

        let asset = AVURLAsset(url: url)
        let image = await asset.generateImage(at: 0.2, maximumSize: CGSize(width: 24, height: 12))
        let images = await asset.generateImages(
            at: [0.1, 0.3, 0.5],
            maximumSize: CGSize(width: 24, height: 12)
        )

        #expect(image != nil)
        #expect(images.count == 3)
        #expect(images.allSatisfy { $0 != nil })
    }

    @Test
    func sizeHelpersReflectTheTemporaryVideoGeometry() async throws {
        let url = try await TestFixtures.createTemporaryVideo(size: CGSize(width: 48, height: 24))
        defer { FileManager.default.removeIfExists(for: url) }

        let asset = AVURLAsset(url: url)
        let naturalSize = try #require(await asset.naturalSize())
        let presentationSize = try #require(await asset.presentationSize())
        let adjustedSize = try #require(
            await asset.adjustVideoSize(to: CGSize(width: 120, height: 120))
        )

        #expect(abs(naturalSize.width - 48) < 0.0001)
        #expect(abs(naturalSize.height - 24) < 0.0001)
        #expect(abs(presentationSize.width - 48) < 0.0001)
        #expect(abs(presentationSize.height - 24) < 0.0001)
        #expect(abs(adjustedSize.width - 120) < 0.0001)
        #expect(abs(adjustedSize.height - 60) < 0.0001)
    }

    @Test
    func filterCompositionHelpersCreateVideoCompositions() async throws {
        let url = try await TestFixtures.createTemporaryVideo()
        defer { FileManager.default.removeIfExists(for: url) }

        let asset = AVURLAsset(url: url)
        let chainedComposition = try await asset.makeVideoComposition(applying: [
            try #require(Helpers.createColorAdjustsFilter(.init(brightness: 0.2)))
        ])

        #expect(chainedComposition.renderSize.width > 0)
        #expect(chainedComposition.renderSize.height > 0)
    }

}

@Suite("AVAudioSessionExtensionTests")
struct AVAudioSessionExtensionTests {

    // MARK: - Public Methods

    @Test
    func audioSessionConvenienceMethodsSetTheExpectedCategories() throws {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category
        let originalMode = session.mode

        defer {
            try? session.setCategory(originalCategory, mode: originalMode)
            try? session.setActive(false)
        }

        session.playAndRecord()
        #expect(session.category == .playAndRecord)

        session.configureRecordAudioSessionCategory()
        #expect(session.category == .record)

        session.configurePlaybackSession()
        #expect(session.category == .playback)
    }

}

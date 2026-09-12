import AVFoundation
import Testing

@testable import VideoEditorKit

@Suite("VideoAudioExtractionServiceTests")
struct VideoAudioExtractionServiceTests {

    // MARK: - Public Methods

    @Test
    func extractAudioCreatesATemporaryM4AFileForAVideoWithAudio() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideoWithAudio()
        let service = VideoAudioExtractionService()

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let audioURL = try await service.extractAudio(from: videoURL)
        defer { service.removeExtractedAudioIfNeeded(at: audioURL) }

        let asset = AVURLAsset(url: audioURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)

        #expect(audioURL.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: audioURL.path()))
        #expect(audioTracks.count == 1)
        #expect(videoTracks.isEmpty)
        #expect(duration.seconds > 0)
    }

    @Test
    func extractAudioFailsWhenTheVideoHasNoAudioTrack() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo()
        let service = VideoAudioExtractionService()

        defer { FileManager.default.removeIfExists(for: videoURL) }

        do {
            _ = try await service.extractAudio(from: videoURL)
            Issue.record("Expected extraction to fail for a silent video.")
        } catch let error as VideoAudioExtractionService.ExtractionError {
            #expect(error == .audioTrackNotFound)
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func removeExtractedAudioIfNeededDeletesTheTemporaryAudioFile() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideoWithAudio()
        let service = VideoAudioExtractionService()

        defer { FileManager.default.removeIfExists(for: videoURL) }

        let audioURL = try await service.extractAudio(from: videoURL)

        #expect(FileManager.default.fileExists(atPath: audioURL.path()))

        service.removeExtractedAudioIfNeeded(at: audioURL)

        #expect(FileManager.default.fileExists(atPath: audioURL.path()) == false)
    }

    @Test
    func extractAudioRejectsNonFileURLs() async {
        let service = VideoAudioExtractionService()
        guard let remoteURL = URL(string: "https://example.com/video.mp4") else {
            Issue.record("Expected the non-file video URL fixture to be valid.")
            return
        }

        do {
            _ = try await service.extractAudio(from: remoteURL)
            Issue.record("Expected extraction to reject non-file URLs.")
        } catch let error as VideoAudioExtractionService.ExtractionError {
            #expect(error == .invalidVideoSource)
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

}

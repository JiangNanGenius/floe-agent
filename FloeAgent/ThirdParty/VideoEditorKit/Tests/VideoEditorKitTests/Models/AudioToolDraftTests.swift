import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("AudioToolDraftTests", .serialized)
struct AudioToolDraftTests {

    // MARK: - Public Methods

    @Test
    func selectedTrackVolumeReadsTheSelectedTrackValue() {
        let videoDraft = AudioToolDraft(
            selectedTrack: .video,
            videoVolume: 0.8,
            recordedVolume: 0.35
        )
        let recordedDraft = AudioToolDraft(
            selectedTrack: .recorded,
            videoVolume: 0.8,
            recordedVolume: 0.35
        )

        #expect(abs(Double(videoDraft.selectedTrackVolume) - 0.8) < 0.0001)
        #expect(abs(Double(recordedDraft.selectedTrackVolume) - 0.35) < 0.0001)
    }

    @Test
    func settingSelectedTrackVolumeOnlyMutatesTheActiveTrack() {
        var videoDraft = AudioToolDraft(
            selectedTrack: .video,
            videoVolume: 0.8,
            recordedVolume: 0.35
        )
        videoDraft.selectedTrackVolume = 0.6

        #expect(abs(Double(videoDraft.videoVolume) - 0.6) < 0.0001)
        #expect(abs(Double(videoDraft.recordedVolume) - 0.35) < 0.0001)

        var recordedDraft = AudioToolDraft(
            selectedTrack: .recorded,
            videoVolume: 0.8,
            recordedVolume: 0.35
        )
        recordedDraft.selectedTrackVolume = 0.2

        #expect(abs(Double(recordedDraft.videoVolume) - 0.8) < 0.0001)
        #expect(abs(Double(recordedDraft.recordedVolume) - 0.2) < 0.0001)
    }

    @Test
    func initializerLoadsVolumesFromTheVideoState() {
        var video = Video.mock
        video.volume = 0.55
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/recorded-audio.m4a"),
            duration: 12,
            volume: 0.25
        )

        let draft = AudioToolDraft(
            video: video,
            selectedTrack: .recorded
        )

        #expect(draft.selectedTrack == .recorded)
        #expect(abs(Double(draft.videoVolume) - 0.55) < 0.0001)
        #expect(abs(Double(draft.recordedVolume) - 0.25) < 0.0001)
    }

}

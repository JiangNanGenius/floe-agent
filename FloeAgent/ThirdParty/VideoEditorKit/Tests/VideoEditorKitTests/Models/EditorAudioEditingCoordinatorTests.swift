import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorAudioEditingCoordinatorTests")
struct EditorAudioEditingCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func selectingRecordedTrackFallsBackToVideoWhenTheClipDoesNotExist() {
        let selectedTrack = EditorAudioEditingCoordinator.selectedTrack(
            .recorded,
            hasRecordedAudioTrack: false
        )

        #expect(selectedTrack == .video)
    }

    @Test
    @MainActor
    func setRecordedAudioUpdatesTheVideoAndMarksTheAudioTool() {
        var video = Video.mock
        let audio = Audio(
            url: URL(fileURLWithPath: "/tmp/recorded-audio.m4a"),
            duration: 2,
            volume: 0.4
        )

        let selectedTrack = EditorAudioEditingCoordinator.setRecordedAudio(
            audio,
            in: &video
        )

        #expect(video.audio == audio)
        #expect(video.isAppliedTool(for: .audio) == true)
        #expect(selectedTrack == .recorded)
    }

    @Test
    @MainActor
    func updateSelectedTrackVolumeSyncsTheAppliedToolState() {
        var video = Video.mock

        EditorAudioEditingCoordinator.updateSelectedTrackVolume(
            0.6,
            in: &video,
            selectedTrack: .video
        )

        #expect(abs(Double(video.volume) - 0.6) < 0.0001)
        #expect(video.isAppliedTool(for: .audio) == true)

        EditorAudioEditingCoordinator.updateSelectedTrackVolume(
            1.0,
            in: &video,
            selectedTrack: .video
        )

        #expect(video.isAppliedTool(for: .audio) == false)
    }

}

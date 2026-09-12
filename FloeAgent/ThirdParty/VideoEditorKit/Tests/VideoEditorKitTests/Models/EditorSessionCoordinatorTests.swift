import Foundation
import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("EditorSessionCoordinatorTests")
struct EditorSessionCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func beginSourceVideoSessionReturnsABootstrapOnlyWhenTheSourceWasNotLoadedYet() {
        let sourceVideoURL = URL(fileURLWithPath: "/tmp/source-video.mp4")
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 4, upperBound: 18)
        )

        let bootstrap = EditorSessionCoordinator.beginSourceVideoSession(
            sourceVideoURL: sourceVideoURL,
            editingConfiguration: editingConfiguration,
            availableSize: CGSize(width: 390, height: 844),
            hasLoadedSourceVideo: false,
            containerSizeResolver: { _ in CGSize(width: 358, height: 320) }
        )
        let ignoredBootstrap = EditorSessionCoordinator.beginSourceVideoSession(
            sourceVideoURL: sourceVideoURL,
            editingConfiguration: editingConfiguration,
            availableSize: CGSize(width: 390, height: 844),
            hasLoadedSourceVideo: true,
            containerSizeResolver: { _ in CGSize(width: 358, height: 320) }
        )

        #expect(bootstrap?.sourceVideoURL == sourceVideoURL)
        #expect(bootstrap?.editingConfiguration == editingConfiguration)
        #expect(bootstrap?.containerSize == CGSize(width: 358, height: 320))
        #expect(ignoredBootstrap == nil)
    }

    @Test
    func recordedVideoSessionResetsSelectionToTheVideoTrackAndMarksTheSourceAsLoaded() {
        let recordedVideoURL = URL(fileURLWithPath: "/tmp/recorded-video.mov")

        let session = EditorSessionCoordinator.recordedVideoSession(recordedVideoURL)

        #expect(session.hasLoadedSourceVideo == true)
        #expect(session.selectedAudioTrack == .video)
        #expect(session.playerLoadState == .loaded(recordedVideoURL))
    }

    @Test
    @MainActor
    func exportVideoOnlyExistsWhileTheQualitySheetIsPresented() {
        let video = Video.mock

        let hiddenExportVideo = EditorSessionCoordinator.exportVideo(
            currentVideo: video,
            isQualitySheetPresented: false
        )
        let visibleExportVideo = EditorSessionCoordinator.exportVideo(
            currentVideo: video,
            isQualitySheetPresented: true
        )

        #expect(hiddenExportVideo == nil)
        #expect(visibleExportVideo?.id == video.id)
    }

    @Test
    @MainActor
    func currentEditingConfigurationBuildsTheExportSnapshotFromSessionState() {
        let audioURL = URL(fileURLWithPath: "/tmp/export-audio.m4a")
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 8,
                        sourceEndTime: 12,
                        timelineStartTime: 8,
                        timelineEndTime: 12
                    ),
                    originalText: "Original segment",
                    editedText: "Edited segment"
                )
            ]
        )
        var video = Video.mock
        video.rangeDuration = 4...18
        video.updateRate(1.75)
        video.rotation = 180
        video.isMirror = true
        video.colorAdjusts = .init(
            brightness: 0.2,
            contrast: 1.15,
            saturation: 0.65
        )
        video.audio = Audio(
            url: audioURL,
            duration: 2.5,
            volume: 0.45
        )

        let configuration = EditorSessionCoordinator.currentEditingConfiguration(
            from: video,
            frames: .init(
                scaleValue: 0.3,
                frameColor: Color(uiColor: .systemOrange)
            ),
            freeformRect: .init(
                x: 0.12,
                y: 0.08,
                width: 0.72,
                height: 0.6
            ),
            canvasSnapshot: .init(
                preset: .social(platform: .youtubeShorts),
                freeCanvasSize: CGSize(width: 1080, height: 1920),
                transform: .identity,
                showsSafeAreaOverlay: true
            ),
            selectedAudioTrack: .recorded,
            transcriptFeatureState: .loaded,
            transcriptDocument: transcriptDocument,
            selectedTool: .adjusts,
            socialVideoDestination: .youtubeShorts,
            showsSafeAreaGuides: true,
            currentTimelineTime: 9
        )

        #expect(configuration?.trim.lowerBound == 4)
        #expect(configuration?.trim.upperBound == 18)
        #expect(abs(Double(configuration?.playback.rate ?? 0) - 1.75) < 0.0001)
        #expect(configuration?.crop.rotationDegrees == 180)
        #expect(configuration?.crop.isMirrored == true)
        #expect(configuration?.audio.selectedTrack == .recorded)
        #expect(configuration?.transcript.featureState == .loaded)
        #expect(configuration?.transcript.document == transcriptDocument)
        #expect(configuration?.presentation.selectedTool == .adjusts)
        #expect(configuration?.presentation.socialVideoDestination == .youtubeShorts)
        #expect(configuration?.presentation.showsSafeAreaGuides == false)
        #expect(configuration?.frame.colorToken == "palette:orange")
    }

}

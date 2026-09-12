import CoreGraphics
import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorInitialLoadCoordinatorTests")
struct EditorInitialLoadCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func prepareResetsPresentationStateAndDropsPersistedTimelineTime() {
        let configuration = VideoEditingConfiguration(
            playback: .init(currentTimelineTime: 12),
            presentation: .init(.adjusts)
        )

        let preparedState = EditorInitialLoadCoordinator.prepare(configuration)

        #expect(preparedState.pendingEditingConfiguration == configuration)
        #expect(preparedState.selectedAudioTrack == .video)
        #expect(preparedState.selectedTool == nil)
        #expect(preparedState.cropEditingState == .initial)
        #expect(preparedState.transcriptFeatureState == .idle)
        #expect(preparedState.transcriptDocument == nil)
    }

    @Test
    func prepareRestoresPersistedTranscriptState() {
        let configuration = VideoEditingConfiguration(
            transcript: .init(
                featureState: TranscriptFeaturePersistenceState.loaded,
                document: TranscriptDocument(
                    segments: [
                        EditableTranscriptSegment(
                            id: UUID(),
                            timeMapping: .init(
                                sourceStartTime: 8,
                                sourceEndTime: 12,
                                timelineStartTime: 8,
                                timelineEndTime: 12
                            ),
                            originalText: "Original",
                            editedText: "Edited"
                        )
                    ]
                )
            )
        )

        let preparedState = EditorInitialLoadCoordinator.prepare(configuration)

        #expect(preparedState.transcriptFeatureState == .loaded)
        #expect(preparedState.transcriptDocument == configuration.transcript.document)
    }

    @Test
    func prepareIgnoresPersistedTranscriptFailuresWhenThereIsNoSavedTranscript() {
        let configuration = VideoEditingConfiguration(
            transcript: .init(
                featureState: .failed,
                document: nil
            )
        )

        let preparedState = EditorInitialLoadCoordinator.prepare(configuration)

        #expect(preparedState.transcriptFeatureState == .idle)
        #expect(preparedState.transcriptDocument == nil)
    }

    @Test
    @MainActor
    func applyPendingEditingConfigurationAppliesMappedStateAndResolvedLayout() {
        let configuration = VideoEditingConfiguration(
            trim: .init(lowerBound: 4, upperBound: 16),
            playback: .init(rate: 1.5, videoVolume: 0.6),
            crop: .init(rotationDegrees: 90, isMirrored: true),
            adjusts: .init(brightness: 0.2, contrast: 1.1, saturation: 0.8)
        )
        var video = Video.mock

        EditorInitialLoadCoordinator.applyPendingEditingConfiguration(
            configuration,
            to: &video,
            containerSize: CGSize(width: 320, height: 240)
        ) { _, _ in
            CGSize(width: 200, height: 120)
        }

        #expect(video.rangeDuration == 4...16)
        #expect(abs(Double(video.rate) - 1.5) < 0.0001)
        #expect(abs(Double(video.volume) - 0.6) < 0.0001)
        #expect(video.rotation == 90)
        #expect(video.isMirror == true)
        #expect(video.frameSize == CGSize(width: 200, height: 120))
        #expect(video.geometrySize == CGSize(width: 200, height: 120))
    }

    @Test
    @MainActor
    func applyPendingEditingConfigurationRestoresTheFullRangeWhenTrimIsNotPersisted() {
        let configuration = VideoEditingConfiguration(
            playback: .init(rate: 1.5, videoVolume: 0.6)
        )
        var video = Video.mock
        video.rangeDuration = 40...120
        video.appliedTool(for: .cut)

        EditorInitialLoadCoordinator.applyPendingEditingConfiguration(
            configuration,
            to: &video,
            containerSize: CGSize(width: 320, height: 240)
        ) { _, _ in
            CGSize(width: 200, height: 120)
        }

        #expect(video.rangeDuration == 0...250)
        #expect(video.isAppliedTool(for: .cut) == false)
        #expect(abs(Double(video.rate) - 1.5) < 0.0001)
        #expect(abs(Double(video.volume) - 0.6) < 0.0001)
    }

    @Test
    @MainActor
    func applyPendingEditingConfigurationClampsTheTrimRangeToTheMaximumDuration() {
        let configuration = VideoEditingConfiguration(
            trim: .init(lowerBound: 30, upperBound: 120)
        )
        var video = Video.mock

        EditorInitialLoadCoordinator.applyPendingEditingConfiguration(
            configuration,
            to: &video,
            containerSize: CGSize(width: 320, height: 240),
            maximumDuration: 60
        ) { _, _ in
            CGSize(width: 200, height: 120)
        }

        #expect(video.rangeDuration == 30...90)
    }

    @Test
    func restorePendingEditingPresentationStateBuildsTheEditorPresentationState() async throws {
        let persistedSnapshot = VideoCanvasSnapshot(
            preset: .facebookPost,
            freeCanvasSize: CGSize(width: 1080, height: 1350),
            transform: .init(
                normalizedOffset: CGPoint(x: 0.2, y: -0.1),
                zoom: 1.4
            ),
            showsSafeAreaOverlay: false
        )
        let configuration = VideoEditingConfiguration(
            canvas: .init(snapshot: persistedSnapshot),
            audio: .init(selectedTrack: .recorded),
            presentation: .init(
                .adjusts,
                socialVideoDestination: .instagramReels,
                showsSafeAreaGuides: true
            )
        )

        let resolvedState = await EditorInitialLoadCoordinator.restorePendingEditingPresentationState(
            from: configuration,
            referenceSize: CGSize(width: 1920, height: 1080),
            hasRecordedAudioTrack: true,
            enabledTools: Set(ToolEnum.all)
        )
        let restoredState = try #require(resolvedState)

        #expect(restoredState.cropEditingState.canvasSnapshot == persistedSnapshot)
        #expect(restoredState.cropEditingState.socialVideoDestination == .instagramReels)
        #expect(restoredState.cropEditingState.showsSafeAreaOverlay == false)
        #expect(restoredState.selectedAudioTrack == .recorded)
        #expect(restoredState.selectedTool == .adjusts)
    }

}

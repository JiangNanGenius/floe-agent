import Foundation
import SwiftUI
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("EditorViewModelTests", .serialized)
struct EditorViewModelTests {

    // MARK: - Public Methods

    @Test
    func selectedTrackVolumeUsesRecordedTrackWhenSelected() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/recorded-audio.m4a"),
            duration: 12,
            volume: 0.35
        )
        viewModel.currentVideo = video

        viewModel.selectAudioTrack(.recorded)

        #expect(abs(Double(viewModel.selectedTrackVolume()) - 0.35) < 0.0001)
    }

    @Test
    func updateSelectedTrackVolumeUpdatesRecordedTrackVolume() {
        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.audio = Audio(
            url: URL(fileURLWithPath: "/tmp/recorded-audio.m4a"),
            duration: 12,
            volume: 0.35
        )
        viewModel.currentVideo = video
        viewModel.selectAudioTrack(.recorded)

        viewModel.updateSelectedTrackVolume(0.8, videoPlayer: videoPlayer)

        #expect(abs(Double(viewModel.currentVideo?.audio?.volume ?? 0) - 0.8) < 0.0001)
        #expect(abs(Double(viewModel.currentVideo?.volume ?? 0) - 1.0) < 0.0001)
    }

    @Test
    func resetSpeedPreservesTimelineIndicatorPosition() {
        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.rangeDuration = 20...80
        viewModel.currentVideo = video
        videoPlayer.syncPlaybackState(with: video)
        videoPlayer.currentTime = 50

        viewModel.handleRateChange(2, videoPlayer: videoPlayer)

        viewModel.reset(.speed, videoPlayer: videoPlayer)

        #expect(abs(Double(viewModel.currentVideo?.rate ?? 0) - 1.0) < 0.0001)
        #expect(abs(videoPlayer.currentTime - 50) < 0.0001)
    }

    @Test
    func refreshThumbnailsIfNeededKeepsTheLatestThumbnailRequestForTheSameVideo() async throws {
        let thumbnailProbe = ThumbnailLoaderProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { await Video.load(from: $0) },
                makeThumbnails: { _, _, _ in
                    await thumbnailProbe.load()
                },
                sleep: { try await Task.sleep(for: $0) }
            )
        )
        var video = Video.mock
        video.thumbnailsImages = []
        viewModel.currentVideo = video

        viewModel.refreshThumbnailsIfNeeded(
            containerSize: CGSize(width: 300, height: 120)
        )
        viewModel.refreshThumbnailsIfNeeded(
            containerSize: CGSize(width: 420, height: 120)
        )

        await thumbnailProbe.resumeNext(
            with: [
                .init(image: TestFixtures.makeSolidImage(color: .systemRed))
            ]
        )
        await thumbnailProbe.resumeNext(
            with: [
                .init(image: TestFixtures.makeSolidImage(color: .systemGreen))
            ]
        )

        var resolvedImage: UIImage?
        for _ in 0..<20 {
            resolvedImage = viewModel.currentVideo?.thumbnailsImages.first?.image

            if let resolvedImage,
                let sampledColor = resolvedImage.sampledThumbnailColor(),
                sampledColor.greenComponent > 0.45,
                sampledColor.redComponent < 0.4,
                sampledColor.blueComponent < 0.4
            {
                break
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        let image = try #require(resolvedImage)
        let sampledColor = try #require(image.sampledThumbnailColor())
        #expect(sampledColor.greenComponent > 0.45)
        #expect(sampledColor.redComponent < 0.4)
        #expect(sampledColor.blueComponent < 0.4)
    }

    @Test
    func applyLoadedThumbnailsIgnoresResultsForAnotherVideo() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.thumbnailsImages = []
        viewModel.currentVideo = video

        viewModel.applyLoadedThumbnails(
            [
                .init(image: TestFixtures.makeSolidImage(color: .systemRed))
            ],
            for: .init(videoID: UUID(), generation: 0)
        )

        #expect(viewModel.currentVideo?.thumbnailsImages.isEmpty == true)
    }

    @Test
    func applyLoadedThumbnailsIgnoresStaleGenerations() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.thumbnailsImages = []
        viewModel.currentVideo = video

        viewModel.refreshThumbnailsIfNeeded(
            containerSize: CGSize(width: 300, height: 120)
        )
        viewModel.refreshThumbnailsIfNeeded(
            containerSize: CGSize(width: 420, height: 120)
        )

        viewModel.applyLoadedThumbnails(
            [
                .init(image: TestFixtures.makeSolidImage(color: .systemRed))
            ],
            for: .init(videoID: video.id, generation: 1)
        )

        #expect(viewModel.currentVideo?.thumbnailsImages.isEmpty == true)
    }

    @Test
    func exportVideoOnlyExistsWhileTheQualitySheetIsPresented() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock

        #expect(viewModel.exportVideo == nil)

        viewModel.presentationState.showVideoQualitySheet = true

        #expect(viewModel.exportVideo?.id == viewModel.currentVideo?.id)
    }

    @Test
    func setTranscriptDocumentRemapsThePersistedTimelineToTheCurrentVideoState() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 20...80
        video.updateRate(2)
        viewModel.currentVideo = video

        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 40,
                            timelineStartTime: 10,
                            timelineEndTime: 40
                        ),
                        originalText: "Original segment",
                        editedText: "Edited segment"
                    )
                ]
            )
        )

        #expect(viewModel.transcriptFeatureState == .loaded)
        #expect(viewModel.transcriptDocument?.segments.first?.timeMapping.timelineRange == 10...20)
    }

    @Test
    func transcribeCurrentVideoMapsProviderOutputIntoATranscriptDraftUntilApply() async {
        let provider = RecordingTranscriptionProvider(
            result: .success(
                VideoTranscriptionResult(
                    segments: [
                        TranscriptionSegment(
                            id: UUID(),
                            startTime: 8,
                            endTime: 12,
                            text: "Ola mundo",
                            words: [
                                TranscriptionWord(
                                    id: UUID(),
                                    startTime: 8,
                                    endTime: 9,
                                    text: "Ola"
                                )
                            ]
                        )
                    ],
                )
            )
        )
        let viewModel = EditorViewModel()
        var video = Video(url: URL(fileURLWithPath: "/tmp/transcription-source.mov"), rangeDuration: 0...20)
        video.updateRate(2)
        viewModel.currentVideo = video
        viewModel.configureTranscription(
            provider: provider,
            preferredLocale: "pt-BR"
        )

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptState(on: viewModel, equals: .loaded)

        let recordedInput = await provider.inputs().first
        #expect(recordedInput?.assetIdentifier == video.url.absoluteString)
        #expect(recordedInput?.preferredLocale == "pt-BR")
        #expect(viewModel.transcriptState == .loaded)
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptDraftDocument?.segments.first?.originalText == "Ola mundo")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "Ola mundo")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.timeMapping.timelineRange == 4...6)
        #expect(viewModel.transcriptDraftDocument?.segments.first?.words.first?.editedText == "Ola")

        viewModel.applyTranscriptChanges()

        #expect(viewModel.transcriptFeatureState == .loaded)
        #expect(viewModel.transcriptDocument == viewModel.transcriptDraftDocument)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .transcript) == true)
    }

    @Test
    func transcribeCurrentVideoReflectsTheStatefulComponentLoadingAndLoadedStates() async {
        let component = StatefulTranscriptionComponentProbe(
            success: VideoTranscriptionResult(
                segments: [
                    TranscriptionSegment(
                        id: UUID(),
                        startTime: 4,
                        endTime: 8,
                        text: "Segmento carregado"
                    )
                ]
            )
        )
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        viewModel.configureTranscription(provider: component)

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptState(on: viewModel, equals: .loading)

        #expect(viewModel.transcriptState == .loading)
        #expect(await component.inputs().count == 1)

        await component.finish()
        await waitForTranscriptState(on: viewModel, equals: .loaded)

        #expect(viewModel.transcriptState == .loaded)
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptDraftDocument?.segments.first?.originalText == "Segmento carregado")
    }

    @Test
    func transcribeCurrentVideoReflectsTheStatefulComponentFailureState() async {
        let component = StatefulTranscriptionComponentProbe(
            failure: .providerFailure(message: "offline")
        )
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        viewModel.configureTranscription(provider: component)

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptState(on: viewModel, equals: .loading)
        await component.finish()
        await waitForTranscriptFailure(on: viewModel)

        #expect(
            viewModel.transcriptState
                == .failed(.providerFailure(message: "offline"))
        )
        #expect(viewModel.transcriptFeatureState == .idle)
    }

    @Test
    func transcribeCurrentVideoFailsWhenProviderIsNotConfigured() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )

        viewModel.transcribeCurrentVideo()

        #expect(viewModel.transcriptState == .failed(.providerNotConfigured))
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
    }

    @Test
    func configureTranscriptionExposesAvailabilityImmediately() {
        let viewModel = EditorViewModel()

        #expect(viewModel.isTranscriptionAvailable == false)

        viewModel.configureTranscription(
            provider: RecordingTranscriptionProvider(
                result: .success(
                    VideoTranscriptionResult(segments: [])
                )
            )
        )

        #expect(viewModel.isTranscriptionAvailable)

        viewModel.configureTranscription(provider: nil)

        #expect(viewModel.isTranscriptionAvailable == false)
    }

    @Test
    func configureTranscriptionSurfacesComponentUnavailabilityImmediately() async {
        let viewModel = EditorViewModel()
        let component = StatefulTranscriptionComponentProbe(
            availabilityError: .unavailable(
                message: "Local speech transcription is not available on this device."
            )
        )

        viewModel.configureTranscription(provider: component)
        await waitForTranscriptFailure(on: viewModel)

        #expect(
            viewModel.transcriptState
                == .failed(
                    .unavailable(
                        message: "Local speech transcription is not available on this device."
                    )
                )
        )
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptDraftDocument == nil)
    }

    @Test
    func transcribeCurrentVideoFailsWhenProviderReturnsAnEmptyResult() async {
        let provider = RecordingTranscriptionProvider(
            result: .success(
                VideoTranscriptionResult(segments: [])
            )
        )
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        viewModel.configureTranscription(provider: provider)

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptFailure(on: viewModel)

        #expect(viewModel.transcriptState == .failed(.emptyResult))
        #expect(viewModel.transcriptFeatureState == .idle)
    }

    @Test
    func transcribeCurrentVideoMapsProviderFailuresIntoTranscriptState() async {
        let provider = RecordingTranscriptionProvider(
            result: .failure(.offline)
        )
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        viewModel.configureTranscription(provider: provider)

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptFailure(on: viewModel)

        #expect(
            viewModel.transcriptState
                == .failed(.providerFailure(message: TranscriptProviderProbeError.offline.localizedDescription))
        )
        #expect(viewModel.transcriptFeatureState == .idle)
    }

    @Test
    func updateTranscriptSegmentTextPreservesTimingAndOriginalText() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "Original segment",
                        editedText: "Original segment"
                    )
                ]
            )
        )

        viewModel.updateTranscriptSegmentText(
            "Edited segment",
            segmentID: segmentID
        )

        #expect(viewModel.transcriptDocument?.segments.first?.originalText == "Original segment")
        #expect(viewModel.transcriptDocument?.segments.first?.editedText == "Original segment")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "Edited segment")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.timeMapping.sourceRange == 10...14)
        #expect(viewModel.transcriptDraftDocument?.segments.first?.timeMapping.timelineRange == 5...7)
    }

    @Test
    func revertTranscriptSegmentTextRestoresTheOriginalDraftTextAndWords() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "hello world",
                        editedText: "hello world",
                        words: [
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 10,
                                    sourceEndTime: 11,
                                    timelineStartTime: 5,
                                    timelineEndTime: 5.5
                                ),
                                originalText: "hello",
                                editedText: "hello"
                            ),
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 11,
                                    sourceEndTime: 14,
                                    timelineStartTime: 5.5,
                                    timelineEndTime: 7
                                ),
                                originalText: "world",
                                editedText: "world"
                            ),
                        ]
                    )
                ]
            )
        )

        viewModel.updateTranscriptSegmentText(
            "hello brave world",
            segmentID: segmentID
        )
        viewModel.revertTranscriptSegmentText(segmentID: segmentID)

        #expect(viewModel.transcriptDocument?.segments.first?.editedText == "hello world")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "hello world")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.words.map(\.editedText) == ["hello", "world"])
    }

    @Test
    func closeSelectedToolPreservesUnappliedTranscriptDraftChanges() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "Original segment",
                        editedText: "Original segment"
                    )
                ]
            )
        )
        viewModel.selectTool(.transcript)

        viewModel.updateTranscriptSegmentText(
            "Edited segment",
            segmentID: segmentID
        )
        viewModel.closeSelectedTool()

        #expect(viewModel.transcriptDocument?.segments.first?.editedText == "Original segment")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "Edited segment")
        #expect(viewModel.presentationState.selectedTool == nil)
    }

    @Test
    func switchingAwayFromTranscriptToolKeepsDraftOverlayChangesAvailableForPreview() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "Original segment",
                        editedText: "Original segment"
                    )
                ]
            )
        )
        viewModel.selectTool(.transcript)
        viewModel.updateTranscriptSegmentText(
            "Edited segment",
            segmentID: segmentID
        )
        viewModel.updateTranscriptOverlayPosition(.top)
        viewModel.updateTranscriptOverlaySize(.large)

        viewModel.selectTool(.presets)

        #expect(viewModel.presentationState.selectedTool == .presets)
        #expect(viewModel.transcriptDocument?.overlayPosition == .bottom)
        #expect(viewModel.transcriptDocument?.overlaySize == .medium)
        #expect(viewModel.transcriptDraftDocument?.overlayPosition == .top)
        #expect(viewModel.transcriptDraftDocument?.overlaySize == .large)
        #expect(viewModel.activeTranscriptSegment(at: 6)?.editedText == "Edited segment")
    }

    @Test
    func currentEditingConfigurationIgnoresUnappliedTranscriptDraftChanges() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: segmentID,
                    timeMapping: .init(
                        sourceStartTime: 10,
                        sourceEndTime: 14,
                        timelineStartTime: 5,
                        timelineEndTime: 7
                    ),
                    originalText: "Original segment",
                    editedText: "Original segment"
                )
            ]
        )
        viewModel.currentVideo = Video.mock
        viewModel.setTranscriptDocument(transcriptDocument)
        viewModel.selectTool(.transcript)

        viewModel.updateTranscriptSegmentText(
            "Edited segment",
            segmentID: segmentID
        )

        let configuration = viewModel.currentEditingConfiguration()

        #expect(configuration?.transcript.featureState == .loaded)
        #expect(configuration?.transcript.document?.segments.first?.editedText == "Original segment")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "Edited segment")
    }

    @Test
    func exportEditingConfigurationUsesUnappliedTranscriptDraftChanges() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: segmentID,
                    timeMapping: .init(
                        sourceStartTime: 10,
                        sourceEndTime: 14,
                        timelineStartTime: 5,
                        timelineEndTime: 7
                    ),
                    originalText: "Original segment",
                    editedText: "Original segment"
                )
            ]
        )
        viewModel.currentVideo = Video.mock
        viewModel.setTranscriptDocument(transcriptDocument)
        viewModel.selectTool(.transcript)

        viewModel.updateTranscriptSegmentText(
            "Edited segment",
            segmentID: segmentID
        )

        let configuration = viewModel.exportEditingConfiguration()

        #expect(configuration?.transcript.featureState == .loaded)
        #expect(configuration?.transcript.document?.segments.first?.editedText == "Edited segment")
        #expect(viewModel.transcriptDocument?.segments.first?.editedText == "Original segment")
    }

    @Test
    func resetTranscriptClearsTheDocumentAndReturnsToIdleState() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcript-reset.mov"),
            rangeDuration: 0...20
        )
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "Original segment",
                        editedText: "Edited segment"
                    )
                ]
            )
        )

        viewModel.resetTranscript()

        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptState == .idle)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .transcript) == false)
    }

    @Test
    func updateTranscriptOverlayControlsPersistPositionAndSizeInDraft() {
        let viewModel = EditorViewModel()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "Original segment",
                        editedText: "Edited segment"
                    )
                ]
            )
        )
        viewModel.prepareTranscriptDraft()

        viewModel.updateTranscriptOverlayPosition(.top)
        viewModel.updateTranscriptOverlaySize(.large)

        #expect(viewModel.transcriptDocument?.overlayPosition == .bottom)
        #expect(viewModel.transcriptDocument?.overlaySize == .medium)
        #expect(viewModel.transcriptDraftDocument?.overlayPosition == .top)
        #expect(viewModel.transcriptDraftDocument?.overlaySize == .large)
    }

    @Test
    func prepareTranscriptDraftIfNeededPreservesExistingUnappliedChanges() {
        let viewModel = EditorViewModel()
        let segmentID = UUID()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "Original segment",
                        editedText: "Original segment"
                    )
                ]
            )
        )
        viewModel.prepareTranscriptDraft()
        viewModel.updateTranscriptSegmentText(
            "Edited segment",
            segmentID: segmentID
        )

        viewModel.prepareTranscriptDraftIfNeeded()

        #expect(viewModel.transcriptDocument?.segments.first?.editedText == "Original segment")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "Edited segment")
    }

    @Test
    func activeTranscriptSegmentUsesTimelineTimingInsteadOfSourceTiming() {
        let viewModel = EditorViewModel()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 20,
                            sourceEndTime: 40,
                            timelineStartTime: 10,
                            timelineEndTime: 20
                        ),
                        originalText: "Visible segment",
                        editedText: "Visible segment"
                    )
                ]
            )
        )

        #expect(viewModel.activeTranscriptSegment(at: 15)?.editedText == "Visible segment")
        #expect(viewModel.activeTranscriptSegment(at: 5) == nil)
    }

    @Test
    func activeTranscriptWordUsesTimelineTimingInsideTheActiveSegment() {
        let visibleWordID = UUID()
        let viewModel = EditorViewModel()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 20,
                            sourceEndTime: 40,
                            timelineStartTime: 10,
                            timelineEndTime: 20
                        ),
                        originalText: "Visible segment",
                        editedText: "Visible segment",
                        words: [
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 20,
                                    sourceEndTime: 24,
                                    timelineStartTime: 10,
                                    timelineEndTime: 12
                                ),
                                originalText: "Visible",
                                editedText: "Visible"
                            ),
                            EditableTranscriptWord(
                                id: visibleWordID,
                                timeMapping: .init(
                                    sourceStartTime: 30,
                                    sourceEndTime: 34,
                                    timelineStartTime: 14,
                                    timelineEndTime: 16
                                ),
                                originalText: "segment",
                                editedText: "segment"
                            ),
                        ]
                    )
                ]
            )
        )

        #expect(viewModel.activeTranscriptWord(at: 15)?.id == visibleWordID)
        #expect(viewModel.activeTranscriptWord(at: 25) == nil)
    }

    @Test
    func activeTranscriptWordReturnsNilWhenTheSegmentIsActiveButNoWordMatchesTheTimelineTime() {
        let viewModel = EditorViewModel()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 20,
                            sourceEndTime: 40,
                            timelineStartTime: 10,
                            timelineEndTime: 20
                        ),
                        originalText: "Visible segment",
                        editedText: "Visible segment",
                        words: [
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 20,
                                    sourceEndTime: 24,
                                    timelineStartTime: 10,
                                    timelineEndTime: 12
                                ),
                                originalText: "Visible",
                                editedText: "Visible"
                            ),
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 30,
                                    sourceEndTime: 34,
                                    timelineStartTime: 16,
                                    timelineEndTime: 18
                                ),
                                originalText: "segment",
                                editedText: "segment"
                            ),
                        ]
                    )
                ]
            )
        )

        #expect(viewModel.activeTranscriptSegment(at: 14)?.editedText == "Visible segment")
        #expect(viewModel.activeTranscriptWord(at: 14) == nil)
    }

    @Test
    func activeTranscriptWordDoesNotKeepThePreviousWordActiveAfterItsUpperBound() {
        let viewModel = EditorViewModel()
        let visibleWordID = UUID()

        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 20,
                            sourceEndTime: 40,
                            timelineStartTime: 10,
                            timelineEndTime: 20
                        ),
                        originalText: "Visible segment",
                        editedText: "Visible segment",
                        words: [
                            EditableTranscriptWord(
                                id: visibleWordID,
                                timeMapping: .init(
                                    sourceStartTime: 20,
                                    sourceEndTime: 24,
                                    timelineStartTime: 10,
                                    timelineEndTime: 12
                                ),
                                originalText: "Visible",
                                editedText: "Visible"
                            )
                        ]
                    )
                ]
            )
        )

        #expect(viewModel.activeTranscriptWord(at: 11.99)?.id == visibleWordID)
        #expect(viewModel.activeTranscriptWord(at: 12.0) == nil)
        #expect(viewModel.activeTranscriptWord(at: 12.08) == nil)
    }

    @Test
    func updateRateRemapsTranscriptDocumentUsingTheCurrentTrim() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 20...80
        video.updateRate(1)
        viewModel.currentVideo = video
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 20,
                            sourceEndTime: 40,
                            timelineStartTime: 20,
                            timelineEndTime: 40
                        ),
                        originalText: "Original segment",
                        editedText: "Edited segment"
                    )
                ]
            )
        )

        viewModel.updateRate(rate: 2)

        #expect(abs(Double(viewModel.currentVideo?.rate ?? 0) - 2) < 0.0001)
        #expect(viewModel.transcriptDocument?.segments.first?.timeMapping.timelineRange == 10...20)
    }

    @Test
    func updateTranscriptSegmentTextReconcilesWordTextsWhenTheEditedSegmentKeepsTheSameWordCount() {
        let segmentID = UUID()
        let firstWordID = UUID()
        let viewModel = EditorViewModel()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "hello world",
                        editedText: "hello world",
                        words: [
                            EditableTranscriptWord(
                                id: firstWordID,
                                timeMapping: .init(
                                    sourceStartTime: 10,
                                    sourceEndTime: 12,
                                    timelineStartTime: 5,
                                    timelineEndTime: 6
                                ),
                                originalText: "hello",
                                editedText: "hello"
                            ),
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 12,
                                    sourceEndTime: 14,
                                    timelineStartTime: 6,
                                    timelineEndTime: 7
                                ),
                                originalText: "world",
                                editedText: "world"
                            ),
                        ]
                    )
                ]
            )
        )

        viewModel.updateTranscriptSegmentText(
            "Hello, world!",
            segmentID: segmentID
        )

        #expect(viewModel.transcriptDraftDocument?.segments.first?.words.map(\.editedText) == ["Hello,", "world!"])
        #expect(viewModel.transcriptDraftDocument?.segments.first?.words.first?.id == firstWordID)
    }

    @Test
    func updateTranscriptSegmentTextKeepsRenderableWordBlocksWhenExtraWordsAreInserted() {
        let segmentID = UUID()
        let viewModel = EditorViewModel()
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: segmentID,
                        timeMapping: .init(
                            sourceStartTime: 10,
                            sourceEndTime: 14,
                            timelineStartTime: 5,
                            timelineEndTime: 7
                        ),
                        originalText: "hello world",
                        editedText: "hello world",
                        words: [
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 10,
                                    sourceEndTime: 12,
                                    timelineStartTime: 5,
                                    timelineEndTime: 6
                                ),
                                originalText: "hello",
                                editedText: "hello"
                            ),
                            EditableTranscriptWord(
                                id: UUID(),
                                timeMapping: .init(
                                    sourceStartTime: 12,
                                    sourceEndTime: 14,
                                    timelineStartTime: 6,
                                    timelineEndTime: 7
                                ),
                                originalText: "world",
                                editedText: "world"
                            ),
                        ]
                    )
                ]
            )
        )

        viewModel.updateTranscriptSegmentText(
            "hello brave world",
            segmentID: segmentID
        )

        #expect(
            viewModel.transcriptDraftDocument?.segments.first?.words.map(\.editedText) == ["hello brave", "world"])
    }

    @Test
    func setCutRemapsTranscriptDocumentAndHidesSegmentsOutsideTheTrimmedRange() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 0...250
        viewModel.currentVideo = video
        viewModel.setTranscriptDocument(
            TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 30,
                            sourceEndTime: 50,
                            timelineStartTime: 30,
                            timelineEndTime: 50
                        ),
                        originalText: "Visible",
                        editedText: "Visible"
                    ),
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(
                            sourceStartTime: 5,
                            sourceEndTime: 10,
                            timelineStartTime: 5,
                            timelineEndTime: 10
                        ),
                        originalText: "Hidden",
                        editedText: "Hidden"
                    ),
                ]
            )
        )
        viewModel.currentVideo?.rangeDuration = 20...60

        viewModel.setCut()

        #expect(viewModel.transcriptDocument?.segments.first?.timeMapping.timelineRange == 30...50)
        #expect(viewModel.transcriptDocument?.segments.last?.timeMapping.timelineRange == nil)
    }

    @Test
    func handleRecordedVideoResetsTheSelectedAudioTrackAndLoadsThePlayer() async {
        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        let recordedVideoURL = URL(fileURLWithPath: "/tmp/recorded-video.mov")
        viewModel.presentationState.selectedAudioTrack = .recorded

        viewModel.handleRecordedVideo(recordedVideoURL, videoPlayer: videoPlayer)

        for _ in 0..<20 where videoPlayer.loadState != .loaded(recordedVideoURL) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.presentationState.selectedAudioTrack == .video)
        #expect(videoPlayer.loadState == .loaded(recordedVideoURL))
    }

    @Test
    func setSourceVideoIfNeededBootstrapsTheFirstSourceOnlyOnce() async {
        let loadVideoProbe = LoadedVideoURLProbe()
        let deferredVideoLoadProbe = DeferredVideoLoadProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { url in
                    await loadVideoProbe.record(url)
                    await deferredVideoLoadProbe.wait()
                    return Video(url: url, rangeDuration: 0...10)
                },
                makeThumbnails: { _, _, _ in [] },
                sleep: { try await Task.sleep(for: $0) }
            )
        )
        let videoPlayer = VideoPlayerManager()
        let firstURL = URL(fileURLWithPath: "/tmp/source-a.mp4")
        let secondURL = URL(fileURLWithPath: "/tmp/source-b.mp4")

        viewModel.setSourceVideoIfNeeded(
            firstURL,
            availableSize: CGSize(width: 390, height: 844),
            videoPlayer: videoPlayer
        )
        viewModel.setSourceVideoIfNeeded(
            secondURL,
            availableSize: CGSize(width: 390, height: 844),
            videoPlayer: videoPlayer
        )

        for _ in 0..<10 where await loadVideoProbe.urls().count != 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(videoPlayer.loadState == .loading)

        await deferredVideoLoadProbe.resumeNext()

        for _ in 0..<10 where videoPlayer.loadState != .loaded(firstURL) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(await loadVideoProbe.urls() == [firstURL])
        #expect(videoPlayer.loadState == .loaded(firstURL))
    }

    @Test
    func setSourceVideoIfNeededKeepsTrimScrubbingInSyncBeforeTheFirstPlayback() async throws {
        let thumbnailProbe = ThumbnailLoaderProbe()
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let viewModel = EditorViewModel(
            .init(
                loadVideo: { url in
                    var video = await Video.load(from: url)
                    video.rangeDuration = 0.2...1.2
                    return video
                },
                makeThumbnails: { _, _, _ in
                    await thumbnailProbe.load()
                },
                sleep: { try await Task.sleep(for: $0) }
            )
        )
        let videoPlayer = VideoPlayerManager()

        viewModel.setSourceVideoIfNeeded(
            videoURL,
            availableSize: CGSize(width: 390, height: 844),
            videoPlayer: videoPlayer
        )

        for _ in 0..<50 where viewModel.currentVideo == nil || videoPlayer.loadState != .loading {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let currentVideo = try #require(viewModel.currentVideo)
        viewModel.handleCurrentVideoChange(
            currentVideo,
            videoPlayer: videoPlayer
        )

        await thumbnailProbe.resumeNext(with: [])

        for _ in 0..<50 where videoPlayer.loadState != .loaded(videoURL) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let scrubRange = try #require(viewModel.currentVideo?.outputRangeDuration)
        let scrubbedTime = 0.8

        videoPlayer.beginScrubbing(in: scrubRange)
        videoPlayer.scrub(
            to: scrubbedTime,
            in: scrubRange
        )

        var resolvedPlayerTime = videoPlayer.videoPlayer.currentTime().seconds
        for _ in 0..<50
        where !resolvedPlayerTime.isFinite || abs(resolvedPlayerTime - scrubbedTime) > 0.05 {
            try? await Task.sleep(for: .milliseconds(10))
            resolvedPlayerTime = videoPlayer.videoPlayer.currentTime().seconds
        }

        #expect(abs(videoPlayer.currentTime - scrubbedTime) < 0.001)
        #expect(resolvedPlayerTime.isFinite)
        #expect(abs(resolvedPlayerTime - scrubbedTime) <= 0.05)
    }

    @Test
    func setMaximumVideoDurationClampsTheLoadedVideoRange() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 0...250
        viewModel.currentVideo = video

        viewModel.setMaximumVideoDuration(60)

        #expect(viewModel.currentVideo?.rangeDuration == 0...60)
    }

    @Test
    func applyPendingEditingConfigurationUsesTheConfiguredMaximumVideoDuration() {
        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 30, upperBound: 120)
        )

        viewModel.setMaximumVideoDuration(60)
        viewModel.prepareEditingConfigurationForInitialLoad(
            editingConfiguration,
            videoPlayer: videoPlayer
        )

        var video = Video.mock
        viewModel.applyPendingEditingConfiguration(
            to: &video,
            containerSize: CGSize(width: 320, height: 240)
        )

        #expect(video.rangeDuration == 30...90)
    }

    @Test
    func setSourceVideoIfNeededStartsAtTheTrimmedBeginningWhenTrimWasNotSaved() async throws {
        let videoURL = try await TestFixtures.createTemporaryVideo(frameCount: 60)
        defer { FileManager.default.removeIfExists(for: videoURL) }

        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        let editingConfiguration = VideoEditingConfiguration(
            playback: .init(currentTimelineTime: 0.5)
        )

        viewModel.setSourceVideoIfNeeded(
            videoURL,
            editingConfiguration: editingConfiguration,
            availableSize: CGSize(width: 390, height: 844),
            videoPlayer: videoPlayer
        )

        for _ in 0..<100
        where viewModel.currentVideo == nil || videoPlayer.loadState != .loaded(videoURL) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let currentVideo = try #require(viewModel.currentVideo)

        #expect(abs(currentVideo.rangeDuration.lowerBound) < 0.001)
        #expect(abs(currentVideo.rangeDuration.upperBound - currentVideo.originalDuration) < 0.001)
        #expect(currentVideo.isAppliedTool(for: .cut) == false)
        #expect(abs(videoPlayer.currentTime) < 0.05)
    }

    @Test
    func handleRecordedVideoKeepsThePlayerInLoadingUntilTheVideoFinishesBootstrapping() async {
        let loadVideoProbe = LoadedVideoURLProbe()
        let deferredVideoLoadProbe = DeferredVideoLoadProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { url in
                    await loadVideoProbe.record(url)
                    await deferredVideoLoadProbe.wait()
                    return Video(url: url, rangeDuration: 0...10)
                },
                makeThumbnails: { _, _, _ in [] },
                sleep: { try await Task.sleep(for: $0) }
            )
        )
        let videoPlayer = VideoPlayerManager()
        let recordedVideoURL = URL(fileURLWithPath: "/tmp/recorded-video.mp4")

        viewModel.handleRecordedVideo(recordedVideoURL, videoPlayer: videoPlayer)

        #expect(videoPlayer.loadState == .loading)

        for _ in 0..<10 where await loadVideoProbe.urls().count != 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        await deferredVideoLoadProbe.resumeNext()

        for _ in 0..<10 where videoPlayer.loadState != .loaded(recordedVideoURL) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(videoPlayer.loadState == .loaded(recordedVideoURL))
    }

    @Test
    func setAdjustsAppliesAndRemovesTheAdjustsTool() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock
        viewModel.selectTool(.adjusts)

        viewModel.setAdjusts(
            ColorAdjusts(brightness: 0.2, contrast: 0.15, saturation: 0.1)
        )

        #expect(abs((viewModel.currentVideo?.colorAdjusts.brightness ?? 0) - 0.2) < 0.0001)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .adjusts) == true)

        viewModel.setAdjusts(.init())

        #expect(viewModel.currentVideo?.colorAdjusts == .init())
        #expect(viewModel.currentVideo?.isAppliedTool(for: .adjusts) == false)
    }

    @Test
    func setAdjustsMutatesTheCurrentVideoImmediately() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock
        let adjusts = ColorAdjusts(
            brightness: 0.2,
            contrast: -0.1,
            saturation: 0.35
        )

        viewModel.setAdjusts(adjusts)

        #expect(viewModel.currentVideo?.colorAdjusts == adjusts)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .adjusts) == true)

        viewModel.setAdjusts(.init())

        #expect(viewModel.currentVideo?.colorAdjusts == .init())
        #expect(viewModel.currentVideo?.isAppliedTool(for: .adjusts) == false)
    }

    @Test
    func settingTheSameAdjustsDoesNotAdvanceTheEditingConfigurationRevision() {
        let viewModel = EditorViewModel()
        let adjusts = ColorAdjusts(brightness: 0.2, contrast: -0.1, saturation: 0.35)
        var video = Video.mock
        video.colorAdjusts = adjusts
        viewModel.currentVideo = video
        let initialRevision = viewModel.presentationState.editingConfigurationRevision

        viewModel.setAdjusts(adjusts)

        #expect(viewModel.presentationState.editingConfigurationRevision == initialRevision)
    }

    @Test
    func setCutTracksWhetherTheVideoIsCurrentlyTrimmed() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 10...80
        viewModel.currentVideo = video

        viewModel.setCut()

        #expect(viewModel.currentVideo?.isAppliedTool(for: .cut) == true)

        viewModel.currentVideo?.rangeDuration = 0...250
        viewModel.setCut()

        #expect(viewModel.currentVideo?.isAppliedTool(for: .cut) == false)
    }

    @Test
    func resetCutRestoresTheFullRangeAndClearsTheCutTool() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.rangeDuration = 15...40
        video.appliedTool(for: .cut)
        viewModel.currentVideo = video

        viewModel.resetCut()

        #expect(viewModel.currentVideo?.rangeDuration == 0...250)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .cut) == false)
    }

    @Test
    func cropRotationAndMirrorProxyTheCurrentVideoState() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock

        viewModel.cropRotation = 180
        viewModel.toggleMirror()

        #expect(viewModel.cropRotation == 180)
        #expect(viewModel.isMirrorEnabled)
    }

    @Test
    func resolvedPlayerDisplaySizeUsesTheRotatedPresentationDimensions() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        video.rotation = 90

        let displaySize = viewModel.resolvedPlayerDisplaySize(
            for: video,
            in: CGSize(width: 320, height: 220)
        )

        #expect(abs(displaySize.width - 123.75) < 0.0001)
        #expect(abs(displaySize.height - 220) < 0.0001)
    }

    @Test
    func resolvedCropPreviewCanvasKeepsReferenceAndRenderedContentSeparatedWhenNoPresetIsActive() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video

        let previewCanvas = viewModel.resolvedCropPreviewCanvas(
            for: video,
            in: CGSize(width: 320, height: 360)
        )

        #expect(abs(previewCanvas.referenceSize.width - 1920) < 0.0001)
        #expect(abs(previewCanvas.referenceSize.height - 1080) < 0.0001)
        #expect(abs(previewCanvas.contentSize.width - 320) < 0.0001)
        #expect(abs(previewCanvas.contentSize.height - 180) < 0.0001)
        #expect(previewCanvas.viewportSize == previewCanvas.contentSize)
    }

    @Test
    func resolvedCropPreviewCanvasExpandsThePresetViewportWithoutLosingTheVideoReferenceSpace() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)
        viewModel.selectCropFormat(.vertical9x16)

        let previewCanvas = viewModel.resolvedCropPreviewCanvas(
            for: video,
            in: CGSize(width: 320, height: 360)
        )

        #expect(abs(previewCanvas.referenceSize.width - 1920) < 0.0001)
        #expect(abs(previewCanvas.referenceSize.height - 1080) < 0.0001)
        #expect(abs(previewCanvas.contentSize.width - 320) < 0.0001)
        #expect(abs(previewCanvas.contentSize.height - 180) < 0.0001)
        #expect(abs(previewCanvas.viewportSize.width - 202.5) < 0.0001)
        #expect(abs(previewCanvas.viewportSize.height - 360) < 0.0001)
        #expect(previewCanvas.viewportSize.height > previewCanvas.contentSize.height)
    }

    @Test
    func originalPresetIsSelectedByDefault() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        let cropSummary = viewModel.cropPresentationSummary

        #expect(cropSummary.selectedPreset == .original)
        #expect(cropSummary.isCropFormatSelected(.original))
        #expect(cropSummary.shouldUseCropPresetSpotlight == false)
    }

    @Test
    func selectingVerticalCropFormatCreatesACenteredNineBySixteenRect() throws {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)

        viewModel.selectCropFormat(.vertical9x16)

        let cropRect = try #require(viewModel.cropPresentationState.freeformRect)
        let cropSummary = viewModel.cropPresentationSummary
        #expect(abs(cropRect.x - 0.341796875) < 0.0001)
        #expect(abs(cropRect.width - 0.31640625) < 0.0001)
        #expect(abs(cropRect.y - 0) < 0.0001)
        #expect(abs(cropRect.height - 1) < 0.0001)
        #expect(viewModel.presentationState.selectedTool == nil)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .presets) == true)
        #expect(cropSummary.shouldShowCropOverlay)
        #expect(cropSummary.isCropOverlayInteractive)
        #expect(cropSummary.shouldUseCropPresetSpotlight)
        #expect(cropSummary.isCropFormatSelected(.vertical9x16))
        #expect(viewModel.cropPresentationState.socialVideoDestination == nil)
        #expect(viewModel.cropPresentationState.showsSafeAreaOverlay == false)
    }

    @Test
    func selectingOriginalCropFormatClearsThePresetRect() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)
        viewModel.selectCropFormat(.vertical9x16)

        viewModel.selectCropFormat(.original)
        let cropSummary = viewModel.cropPresentationSummary

        #expect(viewModel.cropPresentationState.freeformRect == nil)
        #expect(cropSummary.shouldShowCropOverlay == false)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .presets) == false)
        #expect(cropSummary.isCropFormatSelected(.original))
        #expect(viewModel.cropPresentationState.socialVideoDestination == nil)
        #expect(viewModel.cropPresentationState.showsSafeAreaOverlay == false)
        #expect(cropSummary.isCropOverlayInteractive)
        #expect(cropSummary.shouldUseCropPresetSpotlight == false)
        #expect(cropSummary.shouldShowCanvasResetButton == false)
        #expect(cropSummary.badgeTitle == "Original")
        #expect(cropSummary.badgeDimension == "1920x1080")
    }

    @Test
    func selectingVerticalCropFormatAlsoUpdatesTheCanvasEditorState() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)

        viewModel.selectCropFormat(.vertical9x16)

        #expect(viewModel.cropPresentationState.canvasEditorState.preset == .story)
        #expect(viewModel.cropPresentationState.canvasEditorState.transform == .identity)
        #expect(viewModel.cropPresentationState.canvasEditorState.showsSafeAreaOverlay == false)
    }

    @Test
    func selectingSocialVideoDestinationUpdatesIntentWithoutDependingOnGeometryInference() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1080, height: 1920)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)

        viewModel.selectSocialVideoDestination(.youtubeShorts)
        let cropSummary = viewModel.cropPresentationSummary

        #expect(viewModel.cropPresentationState.socialVideoDestination == .youtubeShorts)
        #expect(cropSummary.isCropFormatSelected(.vertical9x16))
        #expect(cropSummary.isSocialVideoDestinationSelected(.youtubeShorts))
        #expect(cropSummary.selectedPreset == .vertical9x16)
        #expect(cropSummary.badgeTitle == "Social")
        #expect(cropSummary.badgeDimension == "9:16")
        #expect(viewModel.cropPresentationState.showsSafeAreaOverlay == false)
    }

    @Test
    func socialPresetIgnoresLegacySafeAreaStateWhenRenderingSummary() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1080, height: 1920)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)
        viewModel.selectSocialVideoDestination(.tikTok)

        viewModel.cropPresentationState.showsSafeAreaOverlay = false

        #expect(viewModel.cropPresentationSummary.shouldShowCropPresetBadge)
        #expect(viewModel.cropPresentationSummary.badgeText == "Social • 9:16")
    }

    @Test
    func selectingPortraitPresetClearsSocialDestinationAndUpdatesTheBadge() throws {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)
        viewModel.selectSocialVideoDestination(.instagramReels)

        viewModel.selectCropFormat(.portrait4x5)

        let cropRect = try #require(viewModel.cropPresentationState.freeformRect)
        let cropSummary = viewModel.cropPresentationSummary
        #expect(abs(cropRect.x - 0.275) < 0.0001)
        #expect(abs(cropRect.width - 0.45) < 0.0001)
        #expect(viewModel.cropPresentationState.socialVideoDestination == nil)
        #expect(viewModel.cropPresentationState.showsSafeAreaOverlay == false)
        #expect(cropSummary.shouldUseCropPresetSpotlight)
        #expect(cropSummary.selectedPreset == .portrait4x5)
        #expect(cropSummary.badgeTitle == "Portrait")
        #expect(cropSummary.badgeDimension == "4:5")
        #expect(cropSummary.badgeText == "Portrait • 4:5")
    }

    @Test
    func currentEditingConfigurationPersistsActivePresetPresentationState() throws {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)
        viewModel.selectCropFormat(.vertical9x16)

        let configuration = try #require(
            viewModel.currentEditingConfiguration(currentTimelineTime: 12)
        )
        let cropRect = try #require(configuration.crop.freeformRect)
        let activeRect = try #require(viewModel.cropPresentationState.freeformRect)

        #expect(configuration.presentation.socialVideoDestination == nil)
        #expect(configuration.presentation.showsSafeAreaGuides == false)
        #expect(configuration.playback.currentTimelineTime == 12)
        #expect(cropRect == activeRect)
        #expect(configuration.canvas.snapshot.preset == .story)
        #expect(configuration.canvas.snapshot.showsSafeAreaOverlay == false)
    }

    @Test
    func currentEditingConfigurationPersistsCanvasTransform() throws {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.cropPresentationState.canvasEditorState.restore(
            .init(
                preset: .facebookPost,
                freeCanvasSize: CGSize(width: 1080, height: 1350),
                transform: .init(
                    normalizedOffset: CGPoint(x: 0.18, y: -0.06),
                    zoom: 1.25,
                    rotationRadians: 0.2
                ),
                showsSafeAreaOverlay: false
            )
        )

        let configuration = try #require(viewModel.currentEditingConfiguration())

        #expect(configuration.canvas.snapshot.preset == .facebookPost)
        #expect(abs(configuration.canvas.snapshot.transform.normalizedOffset.x - 0.18) < 0.0001)
        #expect(abs(configuration.canvas.snapshot.transform.normalizedOffset.y + 0.06) < 0.0001)
        #expect(abs(configuration.canvas.snapshot.transform.zoom - 1.25) < 0.0001)
        #expect(abs(configuration.canvas.snapshot.transform.rotationRadians - 0.2) < 0.0001)
    }

    @Test
    func originalCanvasTransformShowsTheResetAffordanceAndCanBeReset() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video

        viewModel.cropPresentationState.canvasEditorState.restore(
            .init(
                preset: .original,
                transform: .init(
                    normalizedOffset: CGPoint(x: 0.16, y: -0.05),
                    zoom: 1.4
                )
            )
        )

        viewModel.handleCanvasPreviewChange()

        #expect(viewModel.cropPresentationSummary.shouldShowCanvasResetButton)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .presets) == true)

        viewModel.resetCanvasTransform()

        #expect(viewModel.cropPresentationState.canvasEditorState.transform == .identity)
        #expect(viewModel.cropPresentationSummary.shouldShowCanvasResetButton == false)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .presets) == false)
    }

    @Test
    func restorePendingEditingPresentationStateSynthesizesCanvasSnapshotFromLegacyCrop() async {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video
        viewModel.prepareEditingConfigurationForInitialLoad(
            VideoEditingConfiguration(
                crop: .init(
                    freeformRect: .init(
                        x: 0.341796875,
                        y: 0,
                        width: 0.31640625,
                        height: 1
                    )
                ),
                presentation: .init(
                    socialVideoDestination: .tikTok,
                    showsSafeAreaGuides: true
                )
            ),
            videoPlayer: VideoPlayerManager()
        )

        await viewModel.restorePendingEditingPresentationState()

        #expect(viewModel.cropPresentationState.canvasEditorState.preset == .social(platform: .tiktok))
        #expect(viewModel.cropPresentationState.canvasEditorState.showsSafeAreaOverlay == false)
        #expect(viewModel.cropPresentationState.canvasEditorState.transform == .identity)
    }

    @Test
    func restorePendingEditingPresentationStateRestoresPersistedCanvasSnapshotVerbatim() async {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.currentVideo = video

        let persistedSnapshot = VideoCanvasSnapshot(
            preset: .facebookPost,
            freeCanvasSize: CGSize(width: 1080, height: 1350),
            transform: .init(
                normalizedOffset: CGPoint(x: 0.14, y: -0.09),
                zoom: 1.6,
                rotationRadians: 0.22
            ),
            showsSafeAreaOverlay: false
        )

        viewModel.prepareEditingConfigurationForInitialLoad(
            VideoEditingConfiguration(
                canvas: .init(snapshot: persistedSnapshot),
                presentation: .init(
                    socialVideoDestination: .instagramReels,
                    showsSafeAreaGuides: true
                )
            ),
            videoPlayer: VideoPlayerManager()
        )

        await viewModel.restorePendingEditingPresentationState()

        #expect(viewModel.cropPresentationState.canvasEditorState.snapshot() == persistedSnapshot)
        #expect(viewModel.cropPresentationState.socialVideoDestination == .instagramReels)
        #expect(viewModel.cropPresentationState.showsSafeAreaOverlay == false)
    }

    @Test
    func setAudioSwitchesToRecordedTrackAndMarksAudioTool() throws {
        let viewModel = EditorViewModel()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }

        viewModel.currentVideo = Video.mock
        viewModel.selectTool(.audio)

        viewModel.setAudio(Audio(url: audioURL, duration: 3, volume: 0.5))

        #expect(viewModel.currentVideo?.audio?.url == audioURL)
        #expect(viewModel.presentationState.selectedAudioTrack == .recorded)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .audio) == true)
    }

    @Test
    func removeAudioDeletesTheRecordedFileAndRestoresTheVideoTrackSelection() throws {
        let viewModel = EditorViewModel()
        let audioURL = try TestFixtures.createTemporaryAudio()
        var video = Video.mock
        video.audio = Audio(url: audioURL, duration: 4, volume: 0.7)
        video.appliedTool(for: .audio)
        viewModel.currentVideo = video
        viewModel.selectTool(.audio)
        viewModel.presentationState.selectedAudioTrack = .recorded

        viewModel.removeAudio()

        #expect(FileManager.default.fileExists(atPath: audioURL.path()) == false)
        #expect(viewModel.currentVideo?.audio == nil)
        #expect(viewModel.presentationState.selectedAudioTrack == .video)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .audio) == false)
    }

    @Test
    func selectingRecordedTrackFallsBackToVideoWhenNoRecordedAudioExists() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock

        viewModel.selectAudioTrack(.recorded)

        #expect(viewModel.presentationState.selectedAudioTrack == .video)
    }

    @Test
    func updateSelectedTrackVolumeRemovesTheAudioToolWhenBackAtDefaults() {
        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.appliedTool(for: .audio)
        viewModel.currentVideo = video
        viewModel.presentationState.selectedAudioTrack = .video

        viewModel.updateSelectedTrackVolume(1.0, videoPlayer: videoPlayer)

        #expect(abs(Double(viewModel.currentVideo?.volume ?? 0) - 1.0) < 0.0001)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .audio) == false)
    }

    @Test
    func editingConfigurationRevisionAdvancesWhenEditingStateMutates() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock
        let initialRevision = viewModel.presentationState.editingConfigurationRevision

        viewModel.selectTool(.adjusts)
        viewModel.setAdjusts(ColorAdjusts(brightness: 0.2))

        #expect(viewModel.presentationState.editingConfigurationRevision > initialRevision)
    }

    @Test
    func frameEditsAdvanceTheEditingConfigurationRevision() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock
        let initialRevision = viewModel.presentationState.editingConfigurationRevision

        viewModel.setFrameColor(.red)
        viewModel.setFrameScale(0.35)

        #expect(viewModel.presentationState.editingConfigurationRevision >= initialRevision + 2)
    }

    @Test
    func reapplyingSpeedCancelsThePendingResetRemovalTask() async {
        let sleepProbe = DeferredSleepProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { await Video.load(from: $0) },
                makeThumbnails: { video, containerSize, displayScale in
                    await video.makeThumbnails(
                        containerSize: containerSize,
                        displayScale: displayScale
                    )
                },
                sleep: { _ in
                    try await sleepProbe.sleep()
                    try Task.checkCancellation()
                }
            )
        )
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.rate = 2
        video.appliedTool(for: .speed)
        viewModel.currentVideo = video
        viewModel.selectTool(.speed)

        viewModel.reset(.speed, videoPlayer: videoPlayer)
        viewModel.updateRate(rate: 1.5)

        await sleepProbe.resumeNextWhenAvailable()
        try? await Task.sleep(for: .milliseconds(10))

        #expect(abs(Double(viewModel.currentVideo?.rate ?? 0) - 1.5) < 0.0001)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .speed) == true)
    }

    @Test
    func selectToolIgnoresBlockedAndHiddenToolsFromAvailability() {
        let viewModel = EditorViewModel()
        viewModel.setToolAvailability([
            .init(.adjusts),
            .init(.speed, access: .blocked),
        ])

        viewModel.selectTool(.adjusts)
        #expect(viewModel.presentationState.selectedTool == .adjusts)

        viewModel.selectTool(.speed)
        #expect(viewModel.presentationState.selectedTool == .adjusts)

        viewModel.selectTool(.audio)
        #expect(viewModel.presentationState.selectedTool == .adjusts)
    }

    @Test
    func changingAvailabilityClearsTheCurrentSelectionWhenItBecomesUnavailable() {
        let viewModel = EditorViewModel()
        viewModel.selectTool(.adjusts)

        viewModel.setToolAvailability([
            .init(.speed),
            .init(.presets),
        ])

        #expect(viewModel.presentationState.selectedTool == nil)
    }

    @Test
    func frameEditsMutateTheSharedFramesState() throws {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock

        viewModel.setFrameColor(.red)
        viewModel.setFrameScale(0.35)

        #expect(SystemColorPalette.matches(viewModel.frames.frameColor, .red))
        #expect(abs(viewModel.frames.scaleValue - 0.35) < 0.0001)
        let persistedFrameColor = try #require(viewModel.currentVideo?.videoFrames?.frameColor)
        #expect(SystemColorPalette.matches(persistedFrameColor, .red))
        #expect(abs((viewModel.currentVideo?.videoFrames?.scaleValue ?? 0) - 0.35) < 0.0001)
    }

    @Test
    func settingTheSameFrameValuesDoesNotAdvanceTheEditingConfigurationRevision() {
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video.mock
        viewModel.frames = .init(
            scaleValue: 0.35,
            frameColor: .red
        )
        viewModel.currentVideo?.videoFrames = viewModel.frames
        let initialRevision = viewModel.presentationState.editingConfigurationRevision

        viewModel.setFrameColor(.red)
        viewModel.setFrameScale(0.35)

        #expect(viewModel.presentationState.editingConfigurationRevision == initialRevision)
    }

    @Test
    func playerContainerSizeUsesWidthInsetAndMinimumHeight() {
        let viewModel = EditorViewModel()

        let compactSize = viewModel.playerContainerSize(in: CGSize(width: 300, height: 400))
        let tallSize = viewModel.playerContainerSize(in: CGSize(width: 300, height: 900))

        #expect(abs(compactSize.width - 268) < 0.0001)
        #expect(abs(compactSize.height - 220) < 0.0001)
        #expect(abs(tallSize.height - 360) < 0.0001)
    }

    @Test
    func presentExporterShowsTheQualitySheetAfterTheDeferredDelay() async {
        let viewModel = EditorViewModel()
        viewModel.selectTool(.adjusts)

        viewModel.presentExporter()

        #expect(viewModel.presentationState.selectedTool == nil)
        #expect(viewModel.presentationState.showVideoQualitySheet == false)

        for _ in 0..<10 where !viewModel.presentationState.showVideoQualitySheet {
            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(viewModel.presentationState.showVideoQualitySheet)
    }

    @Test
    func cancelDeferredTasksCancelsTheDeferredExporterPresentation() async {
        let sleepProbe = DeferredSleepProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { await Video.load(from: $0) },
                makeThumbnails: { video, containerSize, displayScale in
                    await video.makeThumbnails(
                        containerSize: containerSize,
                        displayScale: displayScale
                    )
                },
                sleep: { _ in
                    try await sleepProbe.sleep()
                    try Task.checkCancellation()
                }
            )
        )

        viewModel.presentExporter()
        viewModel.cancelDeferredTasks()

        await sleepProbe.resumeNext()
        try? await Task.sleep(for: .milliseconds(10))

        #expect(viewModel.presentationState.showVideoQualitySheet == false)
    }

    @Test
    func cancelDeferredTasksAlsoCancelsPendingToolResetRemoval() async {
        let sleepProbe = DeferredSleepProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { await Video.load(from: $0) },
                makeThumbnails: { video, containerSize, displayScale in
                    await video.makeThumbnails(
                        containerSize: containerSize,
                        displayScale: displayScale
                    )
                },
                sleep: { _ in
                    try await sleepProbe.sleep()
                    try Task.checkCancellation()
                }
            )
        )
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.rate = 2
        video.appliedTool(for: .speed)
        viewModel.currentVideo = video
        viewModel.selectTool(.speed)

        viewModel.reset(.speed, videoPlayer: videoPlayer)
        viewModel.cancelDeferredTasks()

        await sleepProbe.resumeNext()
        try? await Task.sleep(for: .milliseconds(10))

        #expect(viewModel.currentVideo?.isAppliedTool(for: .speed) == true)
    }

    @Test
    func pendingToolResetClearsTheAppliedStateAfterDelay() async {
        let sleepProbe = DeferredSleepProbe()
        let viewModel = EditorViewModel(
            .init(
                loadVideo: { await Video.load(from: $0) },
                makeThumbnails: { video, containerSize, displayScale in
                    await video.makeThumbnails(
                        containerSize: containerSize,
                        displayScale: displayScale
                    )
                },
                sleep: { _ in
                    try await sleepProbe.sleep()
                    try Task.checkCancellation()
                }
            )
        )
        let videoPlayer = VideoPlayerManager()
        var video = Video.mock
        video.rate = 2
        video.appliedTool(for: .speed)
        viewModel.currentVideo = video
        viewModel.selectTool(.speed)

        viewModel.reset(.speed, videoPlayer: videoPlayer)

        #expect(viewModel.currentVideo?.isAppliedTool(for: .speed) == true)

        await sleepProbe.resumeNextWhenAvailable()

        for _ in 0..<50 where viewModel.currentVideo?.isAppliedTool(for: .speed) != false {
            await Task.yield()
        }

        #expect(viewModel.currentVideo?.isAppliedTool(for: .speed) == false)
    }

    @Test
    func prepareEditingConfigurationForInitialLoadStartsPlaybackAtTrimBeginningAndRestoresPresentationState()
        async throws
    {
        let viewModel = EditorViewModel()
        let videoPlayer = VideoPlayerManager()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }
        let transcriptSegmentID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let editingConfiguration = VideoEditingConfiguration(
            trim: .init(lowerBound: 8, upperBound: 24),
            playback: .init(
                rate: 1.5,
                videoVolume: 0.55,
                currentTimelineTime: 11
            ),
            crop: .init(
                rotationDegrees: 90,
                isMirrored: true,
                freeformRect: .init(
                    x: 0.15,
                    y: 0.1,
                    width: 0.7,
                    height: 0.65
                )
            ),
            adjusts: .init(
                brightness: 0.1,
                contrast: 1.2,
                saturation: 0.7
            ),
            frame: .init(
                scaleValue: 0.2,
                colorToken: "palette:blue"
            ),
            audio: .init(
                recordedClip: .init(
                    url: audioURL,
                    duration: 2,
                    volume: 0.4
                ),
                selectedTrack: .recorded
            ),
            transcript: .init(
                featureState: .loaded,
                document: TranscriptDocument(
                    segments: [
                        EditableTranscriptSegment(
                            id: transcriptSegmentID,
                            timeMapping: .init(
                                sourceStartTime: 6,
                                sourceEndTime: 18,
                                timelineStartTime: nil,
                                timelineEndTime: nil
                            ),
                            originalText: "Original segment",
                            editedText: "Edited segment"
                        )
                    ]
                )
            ),
            presentation: .init(
                .adjusts,
                socialVideoDestination: .tikTok,
                showsSafeAreaGuides: true
            )
        )

        viewModel.prepareEditingConfigurationForInitialLoad(
            editingConfiguration,
            videoPlayer: videoPlayer
        )

        var video = Video.mock
        viewModel.applyPendingEditingConfiguration(
            to: &video,
            containerSize: CGSize(width: 320, height: 240)
        )
        viewModel.currentVideo = video
        viewModel.handleCurrentVideoChange(
            viewModel.currentVideo,
            videoPlayer: videoPlayer
        )
        await viewModel.restorePendingEditingPresentationState()

        #expect(abs(videoPlayer.currentTime - (8.0 / 1.5)) < 0.0001)
        #expect(viewModel.currentVideo?.rangeDuration == 8...24)
        #expect(abs(Double(viewModel.currentVideo?.rate ?? 0) - 1.5) < 0.0001)
        #expect(abs(Double(viewModel.currentVideo?.volume ?? 0) - 0.55) < 0.0001)
        #expect(viewModel.currentVideo?.rotation == 90)
        #expect(viewModel.currentVideo?.isMirror == true)
        #expect(viewModel.currentVideo?.audio?.url == audioURL)
        #expect(viewModel.presentationState.selectedAudioTrack == .recorded)
        #expect(viewModel.cropPresentationState.freeformRect == editingConfiguration.crop.freeformRect)
        #expect(viewModel.cropPresentationState.socialVideoDestination == .tikTok)
        #expect(viewModel.cropPresentationState.showsSafeAreaOverlay == false)
        #expect(viewModel.presentationState.selectedTool == .adjusts)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .cut) == true)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .speed) == true)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .presets) == true)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .audio) == true)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .adjusts) == true)
        #expect(viewModel.currentVideo?.isAppliedTool(for: .transcript) == true)
        #expect(viewModel.transcriptFeatureState == .loaded)
        #expect(viewModel.transcriptDocument?.segments.first?.id == transcriptSegmentID)
        #expect(
            viewModel.transcriptDocument?.segments.first?.timeMapping.timelineRange
                == 5.333333333333333...12.0
        )
    }

    @Test
    func currentEditingConfigurationBuildsSnapshotFromCurrentEditorState() throws {
        let viewModel = EditorViewModel()
        let audioURL = try TestFixtures.createTemporaryAudio()
        defer { FileManager.default.removeIfExists(for: audioURL) }
        let transcriptDocument = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 10,
                        sourceEndTime: 18,
                        timelineStartTime: 10,
                        timelineEndTime: 18
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

        viewModel.currentVideo = video
        viewModel.frames = VideoFrames(
            scaleValue: 0.3,
            frameColor: Color(uiColor: .systemOrange)
        )
        viewModel.presentationState.selectedAudioTrack = .recorded
        viewModel.cropPresentationState.freeformRect = .init(
            x: 0.12,
            y: 0.08,
            width: 0.72,
            height: 0.6
        )
        viewModel.transcriptFeatureState = .loaded
        viewModel.transcriptDocument = transcriptDocument
        viewModel.cropPresentationState.socialVideoDestination = .youtubeShorts
        viewModel.cropPresentationState.showsSafeAreaOverlay = true
        viewModel.selectTool(.adjusts)

        let configuration = viewModel.currentEditingConfiguration(currentTimelineTime: 9)

        #expect(configuration?.trim.lowerBound == 4)
        #expect(configuration?.trim.upperBound == 18)
        #expect(abs(Double(configuration?.playback.rate ?? 0) - 1.75) < 0.0001)
        #expect(abs(Double(configuration?.playback.currentTimelineTime ?? 0) - 9) < 0.0001)
        #expect(configuration?.crop.rotationDegrees == 180)
        #expect(configuration?.crop.isMirrored == true)
        #expect(configuration?.crop.freeformRect == viewModel.cropPresentationState.freeformRect)
        #expect(abs((configuration?.adjusts.brightness ?? 0) - 0.2) < 0.0001)
        #expect(configuration?.frame.colorToken == "palette:orange")
        #expect(configuration?.audio.selectedTrack == .recorded)
        #expect(configuration?.audio.recordedClip?.url == audioURL)
        #expect(configuration?.transcript.featureState == .loaded)
        #expect(configuration?.transcript.document == transcriptDocument)
        #expect(configuration?.presentation.selectedTool == .adjusts)
        #expect(configuration?.presentation.socialVideoDestination == .youtubeShorts)
        #expect(configuration?.presentation.showsSafeAreaGuides == false)
    }

    @Test
    func restoredNonSocialPresetGeometryMapsBackToThePresetLibrary() async throws {
        let viewModel = EditorViewModel()
        let cropRect = try #require(
            VideoCropFormatPreset.square1x1.makeFreeformRect(
                for: CGSize(width: 1920, height: 1080)
            )
        )
        let editingConfiguration = VideoEditingConfiguration(
            crop: .init(
                freeformRect: cropRect
            ),
            presentation: .init(
                .presets
            )
        )
        let videoPlayer = VideoPlayerManager()

        viewModel.prepareEditingConfigurationForInitialLoad(
            editingConfiguration,
            videoPlayer: videoPlayer
        )

        var video = Video.mock
        video.presentationSize = CGSize(width: 1920, height: 1080)
        viewModel.applyPendingEditingConfiguration(
            to: &video,
            containerSize: CGSize(width: 320, height: 240)
        )
        viewModel.currentVideo = video
        await viewModel.restorePendingEditingPresentationState()

        #expect(viewModel.cropPresentationSummary.selectedPreset == .square1x1)
        #expect(viewModel.cropPresentationSummary.badgeTitle == "Square")
        #expect(viewModel.cropPresentationSummary.badgeDimension == "1:1")
        #expect(viewModel.cropPresentationSummary.badgeText == "Square • 1:1")
        #expect(viewModel.cropPresentationState.socialVideoDestination == nil)
        #expect(viewModel.cropPresentationSummary.shouldUseCropPresetSpotlight)
    }

    @Test
    func closingPresetToolKeepsTheOverlayBadgeAndSafeAreaVisible() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.presentationSize = CGSize(width: 1080, height: 1920)
        viewModel.currentVideo = video
        viewModel.selectTool(.presets)
        viewModel.selectSocialVideoDestination(.tikTok)

        viewModel.closeSelectedTool()
        let cropSummary = viewModel.cropPresentationSummary

        #expect(viewModel.presentationState.selectedTool == nil)
        #expect(cropSummary.shouldShowCropOverlay)
        #expect(cropSummary.isCropOverlayInteractive == true)
        #expect(cropSummary.shouldShowCropPresetBadge)
        #expect(cropSummary.shouldUseCropPresetSpotlight)
        #expect(cropSummary.badgeTitle == "Social")
        #expect(cropSummary.badgeText == "Social • 9:16")
    }

    @Test
    func updateCurrentVideoLayoutUpdatesTheTrackedGeometry() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.geometrySize = CGSize(width: 200, height: 100)
        video.frameSize = CGSize(width: 200, height: 100)
        viewModel.currentVideo = video

        viewModel.updateCurrentVideoLayout(
            to: CGSize(width: 400, height: 200)
        )

        #expect(viewModel.currentVideo?.geometrySize == CGSize(width: 400, height: 200))
        #expect(viewModel.currentVideo?.frameSize == CGSize(width: 400, height: 200))
    }

    @Test
    func updateCurrentVideoLayoutDoesNotAdvanceTheEditingConfigurationRevision() {
        let viewModel = EditorViewModel()
        var video = Video.mock
        video.geometrySize = CGSize(width: 200, height: 100)
        video.frameSize = CGSize(width: 200, height: 100)
        viewModel.currentVideo = video
        let initialRevision = viewModel.presentationState.editingConfigurationRevision

        viewModel.updateCurrentVideoLayout(
            to: CGSize(width: 400, height: 200)
        )

        #expect(viewModel.presentationState.editingConfigurationRevision == initialRevision)
    }

}

private actor DeferredSleepProbe {

    // MARK: - Private Properties

    private var continuations = [CheckedContinuation<Void, any Error>]()

    // MARK: - Public Methods

    func sleep() async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeNextWhenAvailable() async {
        while continuations.isEmpty {
            await Task.yield()
        }

        continuations.removeFirst().resume()
    }

}

private actor ThumbnailLoaderProbe {

    // MARK: - Private Properties

    private var continuations = [CheckedContinuation<[ThumbnailImage], Never>]()

    // MARK: - Public Methods

    func load() async -> [ThumbnailImage] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(
        with thumbnails: [ThumbnailImage]
    ) async {
        while continuations.isEmpty {
            await Task.yield()
        }

        continuations.removeFirst().resume(returning: thumbnails)
    }

}

private struct ThumbnailSampledColor {

    // MARK: - Public Properties

    let redComponent: CGFloat
    let greenComponent: CGFloat
    let blueComponent: CGFloat
    let alphaComponent: CGFloat

}

extension UIImage {

    // MARK: - Private Methods

    fileprivate func sampledThumbnailColor(
        at point: CGPoint? = nil
    ) -> ThumbnailSampledColor? {
        guard let cgImage else { return nil }

        let resolvedPoint =
            point
            ?? CGPoint(
                x: size.width / 2,
                y: size.height / 2
            )
        let clampedPoint = CGPoint(
            x: min(max(resolvedPoint.x, 0), max(size.width - 1, 0)),
            y: min(max(resolvedPoint.y, 0), max(size.height - 1, 0))
        )
        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pixel.deallocate() }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.translateBy(x: -clampedPoint.x, y: clampedPoint.y - size.height + 1)
        context.draw(
            cgImage,
            in: CGRect(
                origin: .zero,
                size: size
            )
        )

        return ThumbnailSampledColor(
            redComponent: CGFloat(pixel[0]) / 255,
            greenComponent: CGFloat(pixel[1]) / 255,
            blueComponent: CGFloat(pixel[2]) / 255,
            alphaComponent: CGFloat(pixel[3]) / 255
        )
    }

}

private actor LoadedVideoURLProbe {

    // MARK: - Private Properties

    private var recordedURLs = [URL]()

    // MARK: - Public Methods

    func record(_ url: URL) {
        recordedURLs.append(url)
    }

    func urls() -> [URL] {
        recordedURLs
    }

}

private actor DeferredVideoLoadProbe {

    // MARK: - Private Properties

    private var continuations = [CheckedContinuation<Void, Never>]()

    // MARK: - Public Methods

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

}

private actor RecordingTranscriptionProvider: VideoTranscriptionProvider {

    // MARK: - Private Properties

    private let result: Result<VideoTranscriptionResult, TranscriptProviderProbeError>
    private var recordedInputs = [VideoEditorKit.VideoTranscriptionInput]()

    // MARK: - Initializer

    init(result: Result<VideoTranscriptionResult, TranscriptProviderProbeError>) {
        self.result = result
    }

    // MARK: - Public Methods

    func transcribeVideo(input: VideoEditorKit.VideoTranscriptionInput) async throws -> VideoTranscriptionResult {
        recordedInputs.append(input)
        return try result.get()
    }

    func inputs() -> [VideoEditorKit.VideoTranscriptionInput] {
        recordedInputs
    }

}

private actor StatefulTranscriptionComponentProbe: VideoTranscriptionComponentProtocol {

    // MARK: - Public Properties

    var state: TranscriptFeatureState {
        currentState
    }

    // MARK: - Private Properties

    private let outcome: Outcome
    private let initialAvailabilityError: TranscriptError?
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentState: TranscriptFeatureState = .idle
    private var recordedInputs = [VideoEditorKit.VideoTranscriptionInput]()

    // MARK: - Initializer

    init(success result: VideoTranscriptionResult) {
        outcome = .success(result)
        initialAvailabilityError = nil
    }

    init(failure error: TranscriptError) {
        outcome = .failure(error)
        initialAvailabilityError = nil
    }

    init(availabilityError error: TranscriptError) {
        outcome = .success(VideoTranscriptionResult())
        initialAvailabilityError = error
    }

    // MARK: - Public Methods

    func transcribeVideo(input: VideoEditorKit.VideoTranscriptionInput) async throws -> VideoTranscriptionResult {
        recordedInputs.append(input)
        currentState = .loading

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }

        switch outcome {
        case .success(let result):
            currentState = .loaded
            return result
        case .failure(let error):
            currentState = .failed(error)
            throw error
        }
    }

    func cancelCurrentTranscription() async {
        currentState = .failed(.cancelled)
        finish()
    }

    func availabilityError(
        preferredLocale: String?
    ) async -> TranscriptError? {
        initialAvailabilityError
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    func inputs() -> [VideoEditorKit.VideoTranscriptionInput] {
        recordedInputs
    }

}

extension StatefulTranscriptionComponentProbe {

    fileprivate enum Outcome {
        case success(VideoTranscriptionResult)
        case failure(TranscriptError)
    }

}

private enum TranscriptProviderProbeError: LocalizedError {
    case offline

    var errorDescription: String? {
        switch self {
        case .offline:
            "offline"
        }
    }
}

@MainActor
private func waitForTranscriptState(
    on viewModel: EditorViewModel,
    equals expectedState: TranscriptFeatureState
) async {
    for _ in 0..<20 {
        if viewModel.transcriptState == expectedState {
            return
        }

        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func waitForRecordedInputs(
    on component: StatefulTranscriptionComponentProbe,
    count expectedCount: Int
) async {
    for _ in 0..<20 {
        if await component.inputs().count == expectedCount {
            return
        }

        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForTranscriptFailure(on viewModel: EditorViewModel) async {
    for _ in 0..<20 {
        if case .failed = viewModel.transcriptState {
            return
        }

        try? await Task.sleep(for: .milliseconds(10))
    }
}

import Foundation
import Testing

@testable import VideoEditorKit

@Suite("VideoEditingConfigurationTests")
struct VideoEditingConfigurationTests {

    // MARK: - Public Methods

    @Test
    func configurationCodableRoundTripPreservesSerializableEditingState() throws {
        let segmentID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let wordID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))

        let configuration = VideoEditingConfiguration(
            trim: .init(lowerBound: 4, upperBound: 22),
            playback: .init(
                rate: 1.75,
                videoVolume: 0.45,
                currentTimelineTime: 12
            ),
            crop: .init(
                rotationDegrees: 180,
                isMirrored: true,
                freeformRect: .init(
                    x: 0.1,
                    y: 0.2,
                    width: 0.6,
                    height: 0.4
                )
            ),
            canvas: .init(
                snapshot: .init(
                    preset: .facebookPost,
                    freeCanvasSize: .init(width: 1080, height: 1350),
                    transform: .init(
                        normalizedOffset: .init(x: -0.22, y: 0.14),
                        zoom: 1.8,
                        rotationRadians: 0.42
                    ),
                    showsSafeAreaOverlay: true
                )
            ),
            adjusts: .init(
                brightness: 0.2,
                contrast: 1.1,
                saturation: 0.8
            ),
            frame: .init(
                scaleValue: 0.3,
                colorToken: "palette:teal"
            ),
            audio: .init(
                recordedClip: .init(
                    url: URL(fileURLWithPath: "/tmp/test-audio.m4a"),
                    duration: 3,
                    volume: 0.8
                ),
                selectedTrack: .recorded
            ),
            transcript: .init(
                featureState: .loaded,
                document: TranscriptDocument(
                    segments: [
                        EditableTranscriptSegment(
                            id: segmentID,
                            timeMapping: .init(
                                sourceStartTime: 4,
                                sourceEndTime: 6,
                                timelineStartTime: 0,
                                timelineEndTime: 1
                            ),
                            originalText: "Original segment",
                            editedText: "Edited segment",
                            words: [
                                EditableTranscriptWord(
                                    id: wordID,
                                    timeMapping: .init(
                                        sourceStartTime: 4,
                                        sourceEndTime: 4.5,
                                        timelineStartTime: 0,
                                        timelineEndTime: 0.25
                                    ),
                                    originalText: "Original",
                                    editedText: "Edited"
                                )
                            ]
                        )
                    ],
                    overlayPosition: .center,
                    overlaySize: .large
                )
            ),
            presentation: .init(
                .adjusts,
                socialVideoDestination: .tikTok,
                showsSafeAreaGuides: true
            )
        )

        let data = try JSONEncoder().encode(configuration)
        let decodedConfiguration = try JSONDecoder().decode(VideoEditingConfiguration.self, from: data)

        #expect(decodedConfiguration.version == VideoEditingConfiguration.currentSchemaVersion.rawValue)
        #expect(decodedConfiguration.schemaVersion == .current)
        #expect(decodedConfiguration == configuration)
        #expect(decodedConfiguration.presentation.showsSafeAreaGuides == true)
    }

    @Test
    func continuousSaveFingerprintIgnoresTransientEditingPresentationState() {
        let baseline = VideoEditingConfiguration(
            playback: .init(
                rate: 1.75,
                videoVolume: 0.45,
                currentTimelineTime: 12
            ),
            canvas: .init(
                snapshot: .init(
                    preset: .original,
                    freeCanvasSize: .init(width: 1080, height: 1080),
                    transform: .identity,
                    showsSafeAreaOverlay: true
                )
            ),
            audio: .init(selectedTrack: .recorded),
            presentation: .init(
                .adjusts,
                socialVideoDestination: .tikTok,
                showsSafeAreaGuides: true
            )
        )
        var transientOnlyChange = baseline
        transientOnlyChange.playback.currentTimelineTime = 3
        transientOnlyChange.audio.selectedTrack = .video
        transientOnlyChange.presentation.selectedTool = nil
        transientOnlyChange.presentation.showsSafeAreaGuides = false
        transientOnlyChange.canvas.snapshot.showsSafeAreaOverlay = false

        #expect(baseline.continuousSaveFingerprint == transientOnlyChange.continuousSaveFingerprint)
    }

    @Test
    func versionOneConfigurationMigratesToCurrentSchemaWithDefaultTranscript() throws {
        let json = """
            {
              "version": 1,
              "trim": {
                "lowerBound": 2,
                "upperBound": 8
              },
              "audio": {
                "selectedTrack": "recorded"
              }
            }
            """
            .data(using: .utf8)

        let data = try #require(json)
        let configuration = try JSONDecoder().decode(VideoEditingConfiguration.self, from: data)

        #expect(configuration.version == VideoEditingConfiguration.currentSchemaVersion.rawValue)
        #expect(configuration.schemaVersion == .current)
        #expect(configuration.audio.selectedTrack == .recorded)
        #expect(configuration.transcript == .init())
    }

    @Test
    func unknownFutureVersionRoundTripsWithoutDowngradingOrDroppingUnknownFields() throws {
        let futureJSON = """
            {
              "version": 99,
              "trim": {
                "lowerBound": 1,
                "upperBound": 2
              },
              "futureField": {
                "mode": "cinematic",
                "passes": [
                  1,
                  2,
                  3
                ]
              }
            }
            """
            .data(using: .utf8)

        let data = try #require(futureJSON)
        let configuration = try JSONDecoder().decode(VideoEditingConfiguration.self, from: data)
        let reencodedData = try JSONEncoder().encode(configuration)

        let originalObject = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let reencodedObject = try #require(JSONSerialization.jsonObject(with: reencodedData) as? NSDictionary)

        #expect(configuration.version == 99)
        #expect(configuration.schemaVersion == nil)
        #expect(reencodedObject == originalObject)
    }

}

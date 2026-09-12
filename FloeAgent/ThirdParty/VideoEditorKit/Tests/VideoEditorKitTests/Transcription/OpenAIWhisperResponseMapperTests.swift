import Foundation
import Testing

@testable import VideoEditorKit

@Suite("OpenAIWhisperResponseMapperTests")
struct OpenAIWhisperResponseMapperTests {

    // MARK: - Public Methods

    @Test
    func mapBuildsSegmentsAndWordsFromVerboseResponse() {
        let mapper = OpenAIWhisperResponseMapper()
        let response = WhisperVerboseTranscriptionResponseDTO(
            task: "transcribe",
            language: "portuguese",
            duration: 5,
            text: "  ola   mundo  ",
            segments: [
                .init(id: 1, start: 2, end: 4, text: "  mundo  "),
                .init(id: 0, start: 0, end: 1.5, text: "  ola  "),
            ],
            words: [
                .init(start: 2.1, end: 2.6, word: "  mundo "),
                .init(start: 0, end: 0.5, word: " ola"),
                .init(start: 0.6, end: 1.2, word: "  "),
            ]
        )

        let result = mapper.map(response)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "ola")
        #expect(result.segments[0].startTime == 0)
        #expect(result.segments[0].endTime == 1.5)
        #expect(result.segments[0].words.count == 1)
        #expect(result.segments[0].words[0].text == "ola")
        #expect(result.segments[1].text == "mundo")
        #expect(result.segments[1].words.count == 1)
        #expect(result.segments[1].words[0].text == "mundo")
    }

    @Test
    func mapDerivesSegmentTextFromWordsWhenSegmentTextIsBlank() {
        let mapper = OpenAIWhisperResponseMapper()
        let response = WhisperVerboseTranscriptionResponseDTO(
            text: "",
            segments: [
                .init(id: 0, start: 1, end: 3, text: " \n ")
            ],
            words: [
                .init(start: 1.1, end: 1.5, word: " hello "),
                .init(start: 1.6, end: 2.2, word: " world "),
            ]
        )

        let result = mapper.map(response)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "hello world")
        #expect(result.segments[0].words.count == 2)
        #expect(result.segments[0].words.map(\.text) == ["hello", "world"])
    }

    @Test
    func mapFallsBackToSingleSegmentWhenVerboseResponseHasNoSegments() {
        let mapper = OpenAIWhisperResponseMapper()
        let response = WhisperVerboseTranscriptionResponseDTO(
            duration: nil,
            text: "  hello   world  ",
            segments: [],
            words: [
                .init(start: -1, end: 0.4, word: "hello"),
                .init(start: 0.5, end: 1.2, word: "world"),
            ]
        )

        let result = mapper.map(response)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "hello world")
        #expect(result.segments[0].startTime == 0)
        #expect(result.segments[0].endTime == 1.2)
        #expect(result.segments[0].words.count == 2)
    }

    @Test
    func mapSkipsSegmentsThatRemainEmptyAfterNormalization() {
        let mapper = OpenAIWhisperResponseMapper()
        let response = WhisperVerboseTranscriptionResponseDTO(
            text: "   ",
            segments: [
                .init(id: 0, start: 0, end: 1, text: "   ")
            ],
            words: [
                .init(start: 0, end: 0.5, word: " \n ")
            ]
        )

        let result = mapper.map(response)

        #expect(result.segments.isEmpty)
    }

}

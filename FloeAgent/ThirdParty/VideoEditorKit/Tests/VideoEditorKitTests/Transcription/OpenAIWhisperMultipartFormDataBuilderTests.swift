import Foundation
import Testing

@testable import VideoEditorKit

@Suite("OpenAIWhisperMultipartFormDataBuilderTests")
struct WhisperFormDataBuilderTests {

    // MARK: - Public Methods

    @Test
    func makeBodyIncludesFieldsRepeatedFieldsAndFilePayload() throws {
        let builder = OpenAIWhisperMultipartFormDataBuilder("Boundary-Test")
        let fileData = Data("audio-data".utf8)

        let body = builder.makeBody(
            fields: [
                "model": "whisper-1",
                "response_format": "verbose_json",
            ],
            repeatedFields: [
                "timestamp_granularities[]": ["segment", "word"]
            ],
            filePart: .init(
                fieldName: "file",
                filename: "sample.m4a",
                mimeType: "audio/m4a",
                data: fileData
            )
        )

        let bodyString = try #require(String(data: body, encoding: .utf8))

        #expect(builder.contentTypeHeaderValue == "multipart/form-data; boundary=Boundary-Test")
        #expect(bodyString.contains("name=\"model\""))
        #expect(bodyString.contains("whisper-1"))
        #expect(bodyString.contains("name=\"response_format\""))
        #expect(bodyString.contains("verbose_json"))
        #expect(bodyString.contains("name=\"timestamp_granularities[]\""))
        #expect(bodyString.contains("segment"))
        #expect(bodyString.contains("word"))
        #expect(bodyString.contains("name=\"file\"; filename=\"sample.m4a\""))
        #expect(bodyString.contains("Content-Type: audio/m4a"))
        #expect(bodyString.contains("audio-data"))
        #expect(bodyString.contains("--Boundary-Test--"))
    }

}

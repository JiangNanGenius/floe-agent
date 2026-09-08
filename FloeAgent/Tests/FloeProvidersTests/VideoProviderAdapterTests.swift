import Foundation
import Testing
import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.VideoAdapters")
struct VideoProviderAdapterTests {
    @Test func latestVideoWireContracts() throws {
        let options = VideoGenerationOptions(aspectRatio: "9:16", resolution: "1080p", durationSeconds: 30, includeAudio: false, watermark: true)
        let ark = try VolcengineVideoAdapter.requestBody(.init(prompt: "test", modelRemoteID: "doubao-seedance-2-5-260628", options: options))
        #expect(ark["duration"] as? Int == 30)
        #expect(ark["generate_audio"] as? Bool == false)
        #expect(ark["resolution"] as? String == "1080p")
        #expect(ark["ratio"] as? String == "9:16")
        #expect(ark["seed"] == nil)
        let wan = try AlibabaVideoAdapter.requestBody(.init(prompt: "test", modelRemoteID: "wan3.0-video", options: options))
        let parameters = try #require(wan["parameters"] as? [String: Any])
        #expect(parameters["resolution"] as? String == "1080P")
        #expect(parameters["duration"] as? Int == 30)
        #expect(parameters["audio"] as? Bool == false)
        #expect(parameters["size"] == nil)
        #expect(JSONSerialization.isValidJSONObject(wan))
        #expect(JSONSerialization.isValidJSONObject(try AlibabaVideoAdapter.requestBody(.init(prompt: "test", modelRemoteID: "wan3.0-video"))))
        let image = URL(string: "https://example.com/reference.png")!
        let first = try VolcengineVideoAdapter.requestBody(.init(prompt: "test", modelRemoteID: "doubao-seedance-2-5-260628", options: options, referenceAssetURLs: [image]))
        #expect(first["ratio"] as? String == "adaptive")
        #expect((first["content"] as? [[String: Any]])?.last?["role"] as? String == "first_frame")
        #expect(throws: RemoteVideoError.self) {
            try VolcengineVideoAdapter.requestBody(.init(prompt: "test", modelRemoteID: "doubao-seedance-2-5-260628", options: .init(durationSeconds: 31)))
        }
        #expect(throws: RemoteVideoError.self) {
            try AlibabaVideoAdapter.requestBody(.init(prompt: "test", modelRemoteID: "wan3.0-video", options: .init(durationSeconds: 31)))
        }
    }

    @Test("Remote video failures expose readable descriptions instead of enum names")
    func remoteVideoErrorsAreReadable() {
        let values: [RemoteVideoError] = [
            .unsupportedProvider,
            .invalidRequest("unsupported size"),
            .invalidResponse("missing job id"),
            .requestFailed("HTTP 503")
        ]

        for value in values {
            let description = value.localizedDescription
            #expect(!description.isEmpty)
            #expect(!description.contains("RemoteVideoError"))
            #expect(!description.contains("FloeProviders"))
        }
    }
}

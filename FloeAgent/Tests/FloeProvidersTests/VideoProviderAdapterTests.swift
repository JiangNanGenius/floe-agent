import Foundation
import Testing
@testable import FloeProviders

@Suite("FloeProviders.VideoAdapters")
struct VideoProviderAdapterTests {
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

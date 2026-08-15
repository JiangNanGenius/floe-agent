// FloeProvidersTests — Opt-in live smoke test for Volcengine Ark.
//
// This test is disabled unless FLOE_LIVE_VOLCENGINE_API_KEY is supplied by
// the caller. Credentials are never embedded in source, fixtures, output, or
// the test result bundle.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

@Suite("FloeProviders.LiveVolcengine")
struct LiveVolcengineTests {

    @Test(
        "Discovers an Ark model and completes a real streamed turn",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_LIVE_VOLCENGINE_API_KEY"]?.isEmpty == false)
    )
    func discoversAndStreams() async throws {
        let apiKey = try #require(
            ProcessInfo.processInfo.environment["FLOE_LIVE_VOLCENGINE_API_KEY"],
            "The live credential is supplied only through the process environment"
        )
        let preset = ProviderPreset.volcengineArk
        let provider = ProviderProfile(
            kind: preset.kind,
            wireProtocol: preset.defaultProtocol,
            baseURL: preset.defaultBaseURL
        )
        let credentials = ProviderCredentials(apiKey: apiKey)
        let adapter = ProviderAdapterFactory().adapter(for: provider)

        let discovered = try await adapter.listModels(
            provider: provider,
            credentials: credentials
        )
        let model = try #require(
            discovered.first(where: { $0.remoteModelID == "doubao-seed-2-1-pro-260628" })
                ?? discovered.first,
            "The Ark account must expose at least one callable model"
        )

        var requestModel = model
        requestModel.capabilities = [.text]
        requestModel.limits.maxOutputTokens = min(model.limits.maxOutputTokens, 64)
        let request = ProviderStreamRequest(
            provider: provider,
            model: requestModel,
            messages: [(role: "user", content: "Reply with exactly: Floe live test OK")]
        )

        var responseText = ""
        var completed = false
        for try await event in adapter.stream(request: request, credentials: credentials) {
            switch event {
            case let .textDelta(delta):
                responseText += delta.text
            case .completed:
                completed = true
            case let .error(error):
                Issue.record("Ark returned a normalized error: \(error.kind), HTTP \(error.httpStatus.map(String.init) ?? "n/a")")
            default:
                break
            }
        }

        #expect(!responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(completed)
    }
}

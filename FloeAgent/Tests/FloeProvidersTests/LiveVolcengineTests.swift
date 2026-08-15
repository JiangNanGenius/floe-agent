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
        // Exercise the user-facing "provider default" setting against the
        // real Ark Chat Completions endpoint: zero must omit max_tokens.
        requestModel.limits.maxOutputTokens = 0
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

    @Test(
        "Completes a real Ark tool round-trip with the tool call paired to its result",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_LIVE_VOLCENGINE_API_KEY"]?.isEmpty == false)
    )
    func completesToolRoundTrip() async throws {
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
        let discovered = try await adapter.listModels(provider: provider, credentials: credentials)
        var model = try #require(
            discovered.first(where: { $0.remoteModelID == "doubao-seed-2-1-pro-260628" })
                ?? discovered.first
        )
        model.capabilities = [.text, .tools]
        model.limits.maxOutputTokens = min(model.limits.maxOutputTokens, 128)

        let schema = ToolSchemaDescriptor(
            name: "floe_test_finish",
            description: "Finish the live protocol test. Always call this tool when asked.",
            parametersJSON: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"],"additionalProperties":false}"#
        )
        let messages = [(
            role: "user",
            content: "Call floe_test_finish exactly once with message set to ready. Do not answer normally before the tool result."
        )]
        var call: ToolCall?
        for try await event in adapter.stream(
            request: ProviderStreamRequest(
                provider: provider,
                model: model,
                messages: messages,
                toolSchemas: [schema]
            ),
            credentials: credentials
        ) {
            if case let .toolRequest(requestedCall) = event {
                call = requestedCall
            }
        }
        let requestedCall = try #require(call, "Ark must emit the requested tool call")
        #expect(requestedCall.toolName == schema.name)

        var finalText = ""
        var completed = false
        for try await event in adapter.stream(
            request: ProviderStreamRequest(
                provider: provider,
                model: model,
                messages: messages,
                toolResults: [(callID: requestedCall.id, output: #"{"status":"ok"}"#)],
                pendingToolCalls: [requestedCall],
                toolSchemas: [schema]
            ),
            credentials: credentials
        ) {
            switch event {
            case let .textDelta(delta):
                finalText += delta.text
            case .completed:
                completed = true
            case let .error(error):
                Issue.record("Ark returned a normalized error after the tool result: \(error.kind)")
            default:
                break
            }
        }

        #expect(!finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(completed)
    }
}

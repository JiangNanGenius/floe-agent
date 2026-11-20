// SPDX-License-Identifier: MPL-2.0
//
// Request-recording tests for the bounded auxiliary vision adapter. Every
// fixture adapter below records the exact `ProviderStreamRequest` it
// received, so these tests prove what actually left the composition layer:
// verified image content, the fixed untrusted-brief prompt, no tool schemas,
// the binding's own credentials, and the iPad parity reasoning default.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Auxiliary vision adapter")
struct AuxiliaryVisionTests {

    // MARK: - Fixtures

    /// Minimal verified PNG image part.
    private func makeImage(bytes: Data = SelfCoreFixture.fixturePNGBytes) -> ConversationImagePart {
        ConversationImagePart(mimeType: "image/png", base64: bytes.base64EncodedString())
    }

    /// Runs the operation and returns the typed auxiliary vision error, or
    /// nil when no such error was thrown.
    private func visionError(
        _ operation: () async throws -> Void
    ) async -> FloeMacSelfAuxiliaryVisionError? {
        do {
            try await operation()
            return nil
        } catch let error as FloeMacSelfAuxiliaryVisionError {
            return error
        } catch {
            return nil
        }
    }

    /// A vision-capable binding around the supplied adapter with a non-empty
    /// fixture API key so the credential path is observable.
    private func visionBinding(adapter: any ProviderAdapter) -> FloeMacSelfProviderBinding {
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://localhost:8443")!,
            displayName: "Fixture Provider",
            secretRef: nil,
            region: nil,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncRevision: 0
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "fixture-vision-model",
            displayName: "Fixture Vision Model",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .vision],
            isEnabled: true
        )
        return FloeMacSelfProviderBinding(
            provider: provider,
            model: model,
            adapter: adapter,
            credentials: ProviderCredentials(apiKey: "fixture-key")
        )
    }

    /// Records requests and credentials, then yields the scripted events and
    /// optionally fails the stream so the failure-preservation path is
    /// exercised exactly as the iPad route sees it.
    private final class FailingVisionAdapter: ProviderAdapter, @unchecked Sendable {
        let protocolKind: ModelProtocol = .openAIResponses
        private let events: [AgentEvent]
        private let failure: Error?
        private let lock = NSLock()
        private var recordedRequests: [ProviderStreamRequest] = []
        private var recordedCredentials: [ProviderCredentials] = []

        init(events: [AgentEvent] = [], failure: Error? = nil) {
            self.events = events
            self.failure = failure
        }

        var requests: [ProviderStreamRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        var credentials: [ProviderCredentials] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCredentials
        }

        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            lock.lock()
            recordedRequests.append(request)
            recordedCredentials.append(credentials)
            lock.unlock()
            let events = self.events
            let failure = self.failure
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for event in events {
                        continuation.yield(event)
                    }
                    if let failure {
                        continuation.finish(throwing: failure)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        func listModels(
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> [ModelProfile] {
            []
        }
    }

    // MARK: - Happy path

    @Test("Describe records one request with verified text + image content and no tools")
    func describeRecordsVerifiedRequest() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [[
                .textDelta(.init(text: "A small red square.")),
                .completed(.init(stopReason: .endTurn)),
            ]],
            capabilities: [.text, .vision]
        )
        let image = makeImage()
        let description = try await FloeMacSelfAuxiliaryVision.describe([image], using: binding)

        #expect(description == "Image 1:\nA small red square.")
        // The handoff text never discloses the raw image bytes.
        #expect(!description.contains(image.base64))

        #expect(adapter.requests.count == 1)
        let request = try #require(adapter.requests.first)
        #expect(request.toolSchemas.isEmpty)
        #expect(request.allToolNames.isEmpty)
        #expect(request.reasoningPolicy == .disabled)
        #expect(request.model.reasoningEffort == .automatic)

        let message = try #require(request.contentMessages.first)
        #expect(message.role == "user")
        #expect(message.content.count == 2)
        guard case .text(let prompt) = message.content[0] else {
            Issue.record("the first content part must be the inspection brief")
            return
        }
        #expect(prompt.contains("untrusted content"))
        guard case .imageData(let mimeType, let base64) = message.content[1] else {
            Issue.record("the second content part must be verified inline image data")
            return
        }
        #expect(mimeType == "image/png")
        #expect(base64 == image.base64)
    }

    @Test("Reasoning enabled selects low effort with the model default policy, like iPad")
    func reasoningEnabledUsesModelDefault() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [[.textDelta(.init(text: "ok"))]],
            capabilities: [.text, .vision]
        )
        _ = try await FloeMacSelfAuxiliaryVision.describe(
            [makeImage()], using: binding, reasoningEnabled: true
        )
        let request = try #require(adapter.requests.first)
        #expect(request.reasoningPolicy == .modelDefault)
        #expect(request.model.reasoningEffort == .low)
    }

    private struct ImageRouter: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIResponses
        let replies: [String: FailingVisionAdapter]

        func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            for part in request.effectiveMessages.flatMap(\.content) {
                if case .imageData(_, let bytes) = part, let adapter = replies[bytes] {
                    return adapter.stream(request: request, credentials: credentials)
                }
            }
            return AsyncThrowingStream { $0.finish(throwing: CocoaError(.fileReadCorruptFile)) }
        }
        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }

    private func twoImages() throws -> [ConversationImagePart] {
        let second = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="))
        return [makeImage(), makeImage(bytes: second)]
    }

    @Test("Describe joins bounded per-image results in input order regardless of dispatch order")
    func joinsMultipleImagesInOrder() async throws {
        let images = try twoImages()
        let first = FailingVisionAdapter(events: [.textDelta(.init(text: "First"))])
        let second = FailingVisionAdapter(events: [.textDelta(.init(text: "Second"))])
        let binding = visionBinding(adapter: ImageRouter(replies: [images[0].base64: first, images[1].base64: second]))
        let description = try await FloeMacSelfAuxiliaryVision.describe(images, using: binding)
        #expect(description == "Image 1:\nFirst\n\nImage 2:\nSecond")
        #expect(first.requests.count == 1 && second.requests.count == 1)
    }

    @Test("The binding's own credentials reach the vision adapter")
    func bindingCredentialsAreUsed() async throws {
        let adapter = FailingVisionAdapter()
        let binding = visionBinding(adapter: adapter)
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        // No scripted events: the stream ends empty, which must fail closed.
        #expect(error == .emptyResponse)
        #expect(adapter.requests.count == 1)
        #expect(adapter.credentials.first?.apiKey == "fixture-key")
    }

    // MARK: - Input verification (fails before any provider call)

    @Test("Unverified image inputs are rejected before any provider request")
    func rejectsUnverifiedInputs() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            capabilities: [.text, .vision]
        )
        let valid = makeImage()
        let cases: [[ConversationImagePart]] = [
            [],
            Array(repeating: valid, count: FloeMacSelfAuxiliaryVision.maximumImages + 1),
            [ConversationImagePart(mimeType: "application/pdf", base64: valid.base64)],
            [ConversationImagePart(mimeType: "image/png", base64: "")],
            [ConversationImagePart(mimeType: "image/png", base64: "not-valid-base64!!!")],
        ]
        for images in cases {
            let error = await visionError {
                _ = try await FloeMacSelfAuxiliaryVision.describe(images, using: binding)
            }
            #expect(error != nil)
        }
        #expect(adapter.requests.isEmpty)
    }

    @Test("A non-vision or media-generator binding is rejected before any provider request")
    func rejectsUnsuitableModel() async throws {
        let (textBinding, textAdapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            capabilities: [.text]
        )
        let textError = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: textBinding)
        }
        #expect(textError == .bindingUnavailable("the model does not declare vision input"))
        #expect(textAdapter.requests.isEmpty)

        // A media generator may advertise vision for reference images, but it
        // is not a dedicated visual-understanding model.
        let (mediaBinding, mediaAdapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            capabilities: [.text, .vision, .imageGeneration]
        )
        let mediaError = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: mediaBinding)
        }
        #expect(mediaError == .bindingUnavailable("the model is not a dedicated visual-understanding model"))
        #expect(mediaAdapter.requests.isEmpty)
    }

    @Test("A disabled provider or model is rejected before any provider request")
    func rejectsDisabledBinding() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            capabilities: [.text, .vision]
        )
        var provider = binding.provider
        provider.isEnabled = false
        let disabled = FloeMacSelfProviderBinding(
            provider: provider,
            model: binding.model,
            adapter: adapter,
            credentials: binding.credentials
        )
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: disabled)
        }
        #expect(error == .bindingUnavailable("the provider is disabled"))
        #expect(adapter.requests.isEmpty)
    }

    @Test("An adapter speaking a different wire protocol is rejected before any provider request")
    func rejectsProtocolMismatch() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            protocolKind: .openAIChatCompletions,
            capabilities: [.text, .vision]
        )
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        #expect(error == .adapterProtocolMismatch(
            expected: "openai-responses",
            actual: "openai-chat-completions"
        ))
        #expect(adapter.requests.isEmpty)
    }

    // MARK: - Failure honesty (no fabricated success)

    @Test("A provider failure is thrown with its real identity, not an empty success")
    func providerFailureThrowsRealError() async throws {
        let adapter = FailingVisionAdapter(failure: NSError(
            domain: "FloeFixtureVision",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "unauthorized"]
        ))
        let binding = visionBinding(adapter: adapter)
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        #expect(error == .providerFailed(
            domain: "FloeFixtureVision",
            code: 401,
            message: "unauthorized"
        ))
        #expect(adapter.requests.count == 1)
    }

    @Test("Text received before a stream failure is preserved")
    func partialTextSurvivesFailure() async throws {
        let adapter = FailingVisionAdapter(
            events: [.textDelta(.init(text: "Partial"))],
            failure: NSError(domain: "FloeFixtureVision", code: 500, userInfo: [:])
        )
        let binding = visionBinding(adapter: adapter)
        let description = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        #expect(description == "Image 1:\nPartial")
    }

    @Test("An explicit stream error fails the request even after text deltas")
    func explicitStreamErrorFailsWithoutPartialSuccess() async throws {
        let adapter = FailingVisionAdapter(events: [
            .textDelta(.init(text: "Partial")),
            .error(.init(kind: .server, providerMessage: "boom", httpStatus: 502)),
        ])
        let binding = visionBinding(adapter: adapter)
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        #expect(error == .providerFailed(
            domain: "FloeProviderStream.server",
            code: 502,
            message: "boom"
        ))
        #expect(adapter.requests.count == 1)
    }

    @Test("One oversized delta is bounded before appending")
    func oversizedDeltaIsBounded() async throws {
        let oversized = String(repeating: "x", count: 4_500)
        let adapter = FailingVisionAdapter(events: [.textDelta(.init(text: oversized))])
        let binding = visionBinding(adapter: adapter)
        let description = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        let text = description.replacingOccurrences(of: "Image 1:\n", with: "")
        #expect(text.count == FloeMacSelfAuxiliaryVision.maximumDescriptionCharactersPerImage)
    }

    @Test("Binding credentials are redacted from the model-facing description")
    func credentialsRedactedFromDescription() async throws {
        let adapter = FailingVisionAdapter(events: [.textDelta(.init(text: "echo key=fixture-key"))])
        let binding = visionBinding(adapter: adapter)
        let description = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        #expect(!description.contains("fixture-key"))
        #expect(description.contains("[redacted]"))
    }

    @Test("Binding credentials are redacted from provider error messages")
    func credentialsRedactedFromErrorMessage() async throws {
        let adapter = FailingVisionAdapter(events: [
            .error(.init(kind: .auth, providerMessage: "bad key fixture-key")),
        ])
        let binding = visionBinding(adapter: adapter)
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        #expect(error == .providerFailed(
            domain: "FloeProviderStream.auth",
            code: 0,
            message: "bad key [redacted]"
        ))
    }

    @Test("A stream that ends without any text fails closed as an empty response")
    func emptyStreamThrowsEmptyResponse() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [[]],
            capabilities: [.text, .vision]
        )
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        #expect(error == .emptyResponse)
        #expect(adapter.requests.count == 1)
    }

    @Test("Failed images are omitted while successful images still describe")
    func partialSuccessOmitsFailedImages() async throws {
        let images = try twoImages()
        let first = FailingVisionAdapter(events: [.textDelta(.init(text: "Only first"))])
        let second = FailingVisionAdapter()
        let binding = visionBinding(adapter: ImageRouter(replies: [images[0].base64: first, images[1].base64: second]))
        let description = try await FloeMacSelfAuxiliaryVision.describe(images, using: binding)
        #expect(description == "Image 1:\nOnly first")
        #expect(!description.contains("Image 2"))
        #expect(first.requests.count == 1 && second.requests.count == 1)
    }

    @Test("When every image fails, the first real failure is thrown")
    func allFailedThrowsFirstFailure() async throws {
        let images = [makeImage(), makeImage()]
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [[], []],
            capabilities: [.text, .vision]
        )
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe(images, using: binding)
        }
        #expect(error == .emptyResponse)
        #expect(adapter.requests.count == 2)
    }

    // MARK: - Bounded time and cancellation

    @Test("A stalled vision request fails closed with a bounded timeout")
    func stalledRequestTimesOut() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            keepStreamOpen: true,
            capabilities: [.text, .vision]
        )
        let error = await visionError {
            _ = try await FloeMacSelfAuxiliaryVision.describe(
                [makeImage()],
                using: binding,
                reasoningEnabled: false,
                timeoutSeconds: 1
            )
        }
        #expect(error == .timedOut(seconds: 1))
        #expect(adapter.requests.count == 1)
    }

    @Test("Caller cancellation stops the in-flight vision request and propagates")
    func cancellationPropagates() async throws {
        let (binding, adapter) = SelfCoreFixture.makeProviderBinding(
            scripts: [],
            keepStreamOpen: true,
            capabilities: [.text, .vision]
        )
        let task = Task {
            try await FloeMacSelfAuxiliaryVision.describe([makeImage()], using: binding)
        }
        // Wait until the request is genuinely in flight before cancelling.
        _ = await eventually(timeout: 5) {
            adapter.requests.count == 1
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("describe unexpectedly completed after cancellation")
        } catch is CancellationError {
            // Expected: cancellation reaches the caller unchanged.
        }
        #expect(adapter.requests.count == 1)
    }
}

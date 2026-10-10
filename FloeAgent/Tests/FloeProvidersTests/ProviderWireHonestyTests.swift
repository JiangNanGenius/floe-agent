import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders
@testable import FloeTools

// FloeProvidersTests — Wire honesty for image payloads and secrets.
// Real fixtures (valid PNG/JPEG incl. ICC APP2/GIF/WebP), negative container
// cases (RIFF WAV/AVI, truncated), rejection before submission, and redaction
// tests that assert the secret is actually present pre-redaction.

@Suite("Provider wire honesty")
struct ProviderWireHonestyTests {
    // Valid minimal fixtures by magic structure.
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    private let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00])
    private let webp = Data([0x52, 0x49, 0x46, 0x46, 0x2A, 0x00, 0x00, 0x00,
                             0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38])
    private let jpegExif = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10])
    private let jpegICC = Data([0xFF, 0xD8, 0xFF, 0xE2, 0x00, 0x10])
    private let riffWav = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
                                0x57, 0x41, 0x56, 0x45])
    private let riffAvi = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
                                0x41, 0x56, 0x49, 0x20])
    private let truncatedPng = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func magicByteSniffingMatchesRealFormats() {
        #expect(ImageWireFormat.sniffMimeType(png) == "image/png")
        #expect(ImageWireFormat.sniffMimeType(gif) == "image/gif")
        #expect(ImageWireFormat.sniffMimeType(webp) == "image/webp")
        #expect(ImageWireFormat.sniffMimeType(jpegExif) == "image/jpeg")
        #expect(ImageWireFormat.sniffMimeType(jpegICC) == "image/jpeg")
        // Negative: RIFF without WEBP fourcc is a container, not WebP.
        #expect(ImageWireFormat.sniffMimeType(riffWav) == nil)
        #expect(ImageWireFormat.sniffMimeType(riffAvi) == nil)
        // Truncated signatures are not images.
        #expect(ImageWireFormat.sniffMimeType(truncatedPng) == nil)
        #expect(ImageWireFormat.sniffMimeType(Data()) == nil)
        #expect(ImageWireFormat.sniffMimeType(Data([0xFF, 0xD8, 0x00, 0x10])) == nil)
    }

    @Test func geminiEditRejectsUnsupportedBytesBeforeSubmission() async throws {
        let provider = ProviderProfile(
            kind: .googleGemini,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.com")!,
            displayName: "Gemini"
        )
        let adapter = GoogleGeminiImageAdapter()
        // A RIFF/WAV must fail with a request error, not be sent as jpeg.
        let request = RemoteImageRequest(
            operation: .edit,
            prompt: "edit",
            sourceImages: [riffWav]
        )
        // Requires a credentials object; empty key path also throws — we only
        // need the format check to happen before submission, so assert the
        // error is the format error when a key IS present, else a key error
        // (never a mislabeled submission).
        let credentials = ProviderCredentials(apiKey: "test-key")
        do {
            _ = try await adapter.perform(request, provider: provider, credentials: credentials)
            Issue.record("unsupported bytes must be rejected before submission")
        } catch RemoteImageError.requestFailed(let message) {
            #expect(message.contains("not a supported image format"))
        }
    }

    @Test func secretRedactionInURLsAndBodies() {
        let secret = "sk-test-secret-value-1234567890"
        let url = "https://example.com/v1/models?api_key=\(secret)&other=1"
        #expect(url.contains(secret)) // non-vacuous input
        let redactedURL = SecretRedactor.redact(url, secret: secret)
        #expect(!redactedURL.contains(secret))
        #expect(redactedURL.contains("⟨redacted⟩"))
        let body = "{\"error\": \"key \(secret) invalid\"}"
        #expect(body.contains(secret)) // non-vacuous input
        #expect(!SecretRedactor.redact(body, secret: secret).contains(secret))
        let header = "Authorization: Bearer \(secret)"
        #expect(!SecretRedactor.redact(header, secret: secret).contains(secret))
    }

    @Test func reasoningCompatibilityPreservesUserOverrides() throws {
        let profile = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://api.example.com")!,
            displayName: "OpenAI"
        )
        func model(remoteID: String, effort: ModelReasoningEffort?) -> ModelProfile {
            ModelProfile(
                providerID: UUID(), remoteModelID: remoteID,
                displayName: "m",
                limits: ModelLimits(contextTokens: 1000, maxOutputTokens: 1000),
                reasoningEffort: effort
            )
        }
        #expect(ReasoningCompatibility.responsesEffort(
            provider: profile, model: model(remoteID: "gpt-5", effort: .high)
        ) == "high")
        #expect(ReasoningCompatibility.responsesEffort(
            provider: profile, model: model(remoteID: "gpt-5", effort: nil)
        ) == nil)
        #expect(ReasoningCompatibility.responsesEffort(
            provider: profile, model: model(remoteID: "gpt-5.2", effort: nil), policy: .disabled
        ) == "none")
    }
}

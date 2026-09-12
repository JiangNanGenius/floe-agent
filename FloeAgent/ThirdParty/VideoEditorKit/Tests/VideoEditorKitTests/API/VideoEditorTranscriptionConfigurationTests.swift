import Testing

@testable import VideoEditorKit

@Suite("VideoEditorTranscriptionConfigurationTests", .serialized)
struct EditorTranscriptionConfigTests {

    // MARK: - Public Methods

    @MainActor
    @Test
    func explicitProviderKeepsThePreferredLocaleAndConfiguredState() {
        let configuration = VideoEditorView.Configuration.TranscriptionConfiguration(
            provider: ConfigurationProbeTranscriptionProvider(),
            preferredLocale: "pt-BR"
        )

        #expect(configuration.preferredLocale == "pt-BR")
        #expect(configuration.provider != nil)
        #expect(configuration.isConfigured)
    }

    @MainActor
    @Test
    func explicitProviderCanBeCreatedWithoutAPreferredLocale() {
        let configuration = VideoEditorView.Configuration.TranscriptionConfiguration(
            provider: ConfigurationProbeTranscriptionProvider()
        )

        #expect(configuration.preferredLocale == nil)
        #expect(configuration.provider != nil)
        #expect(configuration.isConfigured)
    }

    @MainActor
    @Test
    func openAIWhisperReturnsAnUnconfiguredStateWhenTheAPIKeyIsBlank() {
        let configuration = VideoEditorView.Configuration.TranscriptionConfiguration.openAIWhisper(
            apiKey: "   "
        )

        #expect(configuration.provider == nil)
        #expect(configuration.isConfigured == false)
    }

    @MainActor
    @Test
    func openAIWhisperKeepsThePreferredLocaleAndCreatesAProvider() {
        let configuration = VideoEditorView.Configuration.TranscriptionConfiguration.openAIWhisper(
            apiKey: "test-api-key",
            preferredLocale: "en-US"
        )

        #expect(configuration.preferredLocale == "en-US")
        #expect(configuration.provider != nil)
        #expect(configuration.isConfigured)
    }

}

private actor ConfigurationProbeTranscriptionProvider: VideoTranscriptionProvider {

    // MARK: - Public Methods

    func transcribeVideo(input _: VideoTranscriptionInput) async throws -> VideoTranscriptionResult {
        .init()
    }

}

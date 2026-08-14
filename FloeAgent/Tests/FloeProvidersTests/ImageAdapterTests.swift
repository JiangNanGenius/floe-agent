// FloeProvidersTests — Capability-aware remote image adapters. Unsupported
// operations must throw rather than fabricate output; the factory only
// returns adapters for provider families with real image capability.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders
import FloeTestSupport

@Suite("FloeProviders.ImageAdapters")
struct ImageAdapterTests {

    private func provider(kind: ProviderKind) -> ProviderProfile {
        ProviderProfile(
            kind: kind,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://localhost:8443")!
        )
    }

    @Test("Factory returns adapters only for image-capable provider families")
    func factoryCoverage() {
        let factory = ImageProviderAdapterFactory()
        #expect(factory.adapter(for: provider(kind: .openAI)) is OpenAIImageAdapter)
        #expect(factory.adapter(for: provider(kind: .volcengineArk)) is VolcengineImageAdapter)
        #expect(factory.adapter(for: provider(kind: .alibabaStudio)) is AlibabaImageAdapter)
        // Anthropic and custom endpoints expose no remote image adapter.
        #expect(factory.adapter(for: provider(kind: .anthropic)) == nil)
        #expect(factory.adapter(for: provider(kind: .custom)) == nil)
    }

    @Test("Each adapter declares an honest capability set")
    func capabilitySets() {
        let openai = OpenAIImageAdapter()
        #expect(openai.supportedOperations(for: provider(kind: .openAI)).contains(.generate))
        #expect(!openai.supportedOperations(for: provider(kind: .openAI)).contains(.upscale))

        let ark = VolcengineImageAdapter()
        #expect(ark.supportedOperations(for: provider(kind: .volcengineArk)).isEmpty)

        let alibaba = AlibabaImageAdapter()
        #expect(alibaba.supportedOperations(for: provider(kind: .alibabaStudio)).isEmpty)
    }

    @Test("Unsupported operations throw unsupportedOperation, never fabricate")
    func unsupportedThrows() async {
        let adapter = OpenAIImageAdapter()
        let openAIProvider = provider(kind: .openAI)
        let request = RemoteImageRequest(operation: .upscale, prompt: "bigger")
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(request, provider: openAIProvider, credentials: ProviderCredentials())
        }
    }

    @Test("supports() is consistent with supportedOperations()")
    func supportsConsistency() {
        let adapter = AlibabaImageAdapter()
        let alibabaProvider = provider(kind: .alibabaStudio)
        #expect(!adapter.supports(.generate, for: alibabaProvider))
        #expect(!adapter.supports(.edit, for: alibabaProvider))
        #expect(!adapter.supports(.removeBackground, for: alibabaProvider))
    }
}

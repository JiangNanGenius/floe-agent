// FloeProvidersTests — per-model catalog metadata, hidden presets, the pure
// capability resolver, the review-gated migration and the no-silent-migration
// merge contract. Offline: synthetic documents plus a read of the checked-in
// ProviderCatalog.json; no network and no credentials.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

// MARK: - Fixtures

private func metadataDocument(_ providers: [ProviderCatalogEntry]) -> ProviderCatalogDocument {
    ProviderCatalogDocument(
        schemaVersion: 1,
        source: .init(
            project: "models.dev",
            url: "https://models.dev",
            license: "MIT",
            documentSHA256: String(repeating: "b", count: 64),
            fetchedAt: "2026-10-15T00:00:00Z"
        ),
        providers: providers
    )
}

private func metadataEntry(
    _ presetID: String,
    name: String,
    kind: ProviderKind = .custom,
    defaultProtocol: ModelProtocol = .openAIChatCompletions,
    baseURL: String? = "https://api.example.com/v1",
    models: [String] = [],
    availability: ProviderCatalogAvailability = .available,
    unsupportedReason: String? = nil,
    authStyle: String = "bearer",
    serviceOffers: [ProviderCatalogServiceOffer]? = nil,
    modelMetadata: [String: ProviderCatalogModelMetadata]? = nil
) -> ProviderCatalogEntry {
    ProviderCatalogEntry(
        presetID: presetID,
        name: name,
        kind: kind,
        defaultProtocol: defaultProtocol,
        baseURL: baseURL.flatMap(URL.init(string:)),
        models: models,
        availability: availability,
        unsupportedReason: unsupportedReason,
        upstreamID: presetID,
        authStyle: authStyle,
        serviceOffers: serviceOffers,
        modelMetadata: modelMetadata
    )
}

private func validatedIndex(_ document: ProviderCatalogDocument) throws -> ProviderCatalogIndex {
    try ProviderCatalogIndex.validated(from: JSONEncoder().encode(document))
}

private func catalogMetadata(
    input: [String]? = nil,
    output: [String]? = nil,
    toolCall: Bool? = nil
) -> ProviderCatalogModelMetadata {
    ProviderCatalogModelMetadata(input: input, output: output, toolCall: toolCall)
}

private func savedModel(
    _ remoteID: String,
    capabilities: ModelCapabilities,
    explicitCapabilities: ModelCapabilities? = nil,
    providerID: UUID = UUID()
) -> ModelProfile {
    ModelProfile(
        providerID: providerID,
        remoteModelID: remoteID,
        displayName: remoteID,
        limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 4_096),
        capabilities: capabilities,
        explicitCapabilities: explicitCapabilities
    )
}

// MARK: - Metadata schema

@Suite("FloeProviders.ProviderCatalogModelMetadata")
struct ProviderCatalogModelMetadataTests {

    @Test("Model metadata JSON round-trips and absent flags stay absent")
    func metadataRoundTrip() throws {
        let metadata = ProviderCatalogModelMetadata(
            input: ["image", "text"],
            output: ["text"],
            toolCall: true,
            attachment: false,
            reasoning: nil
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ProviderCatalogModelMetadata.self, from: data)
        #expect(decoded == metadata)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reasoning"] == nil)
        #expect(object["attachment"] as? Bool == false)
    }

    @Test("A catalog with valid per-model metadata activates")
    func validMetadataAccepted() throws {
        let entry = metadataEntry(
            "vendor",
            name: "Vendor",
            models: ["chat-a"],
            modelMetadata: ["chat-a": catalogMetadata(input: ["text", "image"], output: ["text"], toolCall: true)]
        )
        let index = try validatedIndex(metadataDocument([entry]))
        #expect(index.all.first?.modelMetadata?["chat-a"]?.input == ["text", "image"])
    }

    @Test("Metadata for an undeclared model is rejected")
    func undeclaredModelRejected() throws {
        let entry = metadataEntry(
            "vendor",
            name: "Vendor",
            models: ["chat-a"],
            modelMetadata: ["ghost-model": catalogMetadata(input: ["text"])]
        )
        do {
            _ = try validatedIndex(metadataDocument([entry]))
            Issue.record("expected rejection")
        } catch let error as ProviderCatalogValidationError {
            #expect(error.message.contains("undeclared model"))
        }
    }

    @Test("Metadata keys may reference a declared service-offer model")
    func offerModelMetadataAccepted() throws {
        let offer = ProviderCatalogServiceOffer(
            role: .conversation,
            baseURL: URL(string: "https://api.example.com/v1beta")!,
            authStyle: "bearer",
            protocols: [.openAIChatCompletions],
            models: ["chat-offer"]
        )
        let entry = metadataEntry(
            "vendor",
            name: "Vendor",
            models: ["image-a"],
            serviceOffers: [offer],
            modelMetadata: ["chat-offer": catalogMetadata(input: ["image", "text"], output: ["text"])]
        )
        let index = try validatedIndex(metadataDocument([entry]))
        #expect(index.all.first?.modelMetadata?["chat-offer"] != nil)
    }

    @Test("Unknown, duplicate and oversized modality lists are rejected")
    func modalityRejections() throws {
        let cases: [([String], String)] = [
            (["hologram"], "unknown input modality"),
            (["text", "text"], "duplicate input modality"),
            (["text", "image", "audio", "video", "pdf", "text"], "input modalities")
        ]
        for (modalities, token) in cases {
            let entry = metadataEntry(
                "vendor",
                name: "Vendor",
                models: ["chat-a"],
                modelMetadata: ["chat-a": catalogMetadata(input: modalities)]
            )
            do {
                _ = try validatedIndex(metadataDocument([entry]))
                Issue.record("expected rejection for \(modalities)")
            } catch let error as ProviderCatalogValidationError {
                #expect(error.message.contains(token), "\(error.message)")
            }
        }
    }

    @Test("An empty metadata object is rejected, not silently accepted")
    func emptyMetadataRejected() throws {
        let entry = metadataEntry(
            "vendor",
            name: "Vendor",
            models: ["chat-a"],
            modelMetadata: ["chat-a": ProviderCatalogModelMetadata()]
        )
        do {
            _ = try validatedIndex(metadataDocument([entry]))
            Issue.record("expected rejection")
        } catch let error as ProviderCatalogValidationError {
            #expect(error.message.contains("empty model metadata"))
        }
    }
}

// MARK: - Hidden presets

@Suite("FloeProviders.HiddenProviderPresets")
struct HiddenProviderPresetTests {

    private func indexWithHiddenPresets() throws -> ProviderCatalogIndex {
        let hidden = metadataEntry(
            "github-copilot",
            name: "GitHub Copilot",
            baseURL: "https://api.githubcopilot.com",
            availability: .unsupported,
            unsupportedReason: "requires GitHub Copilot OAuth device flow"
        )
        // A remote catalog could claim availability; hiding is independent.
        let flippedHidden = metadataEntry(
            "azure",
            name: "Azure OpenAI",
            baseURL: "https://openai.azure.com/v1",
            availability: .available
        )
        let ordinaryUnsupported = metadataEntry(
            "mystery-cloud",
            name: "Mystery Cloud",
            availability: .unsupported,
            unsupportedReason: "requires a custom signature"
        )
        let normal = metadataEntry("normal", name: "Normal AI")
        return try validatedIndex(metadataDocument([hidden, flippedHidden, ordinaryUnsupported, normal]))
    }

    @Test("The four unsupported presets never appear in search, for every filter")
    func hiddenPresetsNeverSearchable() throws {
        let index = try indexWithHiddenPresets()
        for filter in ProviderCatalogFilter.allCases {
            let results = index.search(query: "", filter: filter, configuredPresetIDs: ["azure"])
            #expect(!results.contains { $0.presetID == "github-copilot" })
            #expect(!results.contains { $0.presetID == "azure" })
        }
        #expect(index.search(query: "Copilot", filter: .all, configuredPresetIDs: []).isEmpty)
        #expect(index.search(query: "Azure", filter: .all, configuredPresetIDs: []).isEmpty)
        #expect(index.hiddenPresetIDsContains("github-copilot", "azure", "amazon-bedrock", "google-vertex"))
    }

    @Test("Other unsupported presets stay searchable and hidden entries stay editable")
    func otherUnsupportedSearchableAndEntriesResolvable() throws {
        let index = try indexWithHiddenPresets()
        #expect(index.search(query: "Mystery", filter: .all, configuredPresetIDs: []).map(\.presetID) == ["mystery-cloud"])
        // A saved provider that references a hidden preset still resolves.
        #expect(index.entry(presetID: "github-copilot")?.name == "GitHub Copilot")
        #expect(index.offeredProviderCount == 2)
    }
}

private extension ProviderCatalogIndex {
    func hiddenPresetIDsContains(_ ids: String...) -> Bool {
        ids.allSatisfy { Self.hiddenPresetIDs.contains($0) }
    }
}

// MARK: - Resolver

@Suite("FloeProviders.ProviderCatalogCapabilityResolver")
struct ProviderCatalogCapabilityResolverTests {

    private let base: ModelCapabilities = [.text, .tools, .approval]

    @Test("Verified image input on an inference model adds vision")
    func imageInputAddsVision() {
        let capabilities = ProviderCatalogCapabilityResolver.capabilities(
            for: catalogMetadata(input: ["text", "image"], output: ["text"], toolCall: true),
            base: base
        )
        #expect(capabilities.contains(.vision))
        #expect(capabilities.contains(.tools))
        #expect(capabilities.contains(.text))
    }

    @Test("Image output marks a generator: image input is not vision")
    func generationModelsDoNotGainVision() {
        for output in [["image"], ["text", "image"], ["video"], ["text", "video"]] {
            let capabilities = ProviderCatalogCapabilityResolver.capabilities(
                for: catalogMetadata(input: ["text", "image"], output: output),
                base: base
            )
            #expect(!capabilities.contains(.vision), "output \(output)")
        }
    }

    @Test("toolCall false removes the assumed tools bit; nil keeps it")
    func toolCallFalseRemovesTools() {
        let withoutTools = ProviderCatalogCapabilityResolver.capabilities(
            for: catalogMetadata(input: ["text"], output: ["text"], toolCall: false),
            base: base
        )
        #expect(!withoutTools.contains(.tools))
        let unknown = ProviderCatalogCapabilityResolver.capabilities(
            for: catalogMetadata(input: ["text"], output: ["text"]),
            base: base
        )
        #expect(unknown.contains(.tools))
    }

    @Test("Audio and video modalities never become capability bits")
    func audioVideoNotMapped() {
        let capabilities = ProviderCatalogCapabilityResolver.capabilities(
            for: catalogMetadata(
                input: ["text", "audio", "video", "pdf"],
                output: ["text", "audio"],
                toolCall: true
            ),
            base: base
        )
        #expect(capabilities.contains(.vision) == false)
        #expect(capabilities.contains(.imageGeneration) == false)
        #expect(capabilities.contains(.videoGeneration) == false)
        #expect(capabilities == base)
    }

    @Test("Absent metadata keeps the legacy protocol default")
    func absentMetadataKeepsBase() {
        #expect(ProviderCatalogCapabilityResolver.capabilities(for: nil, base: base) == base)
    }
}

// MARK: - No silent migration

@Suite("FloeProviders.ModelCatalogMergerProvenance")
struct ModelCatalogMergerProvenanceTests {

    @Test("REGRESSION: discovered vision is NOT silently migrated into a legacy row")
    func legacyRowDoesNotGainVisionFromDiscovery() throws {
        let providerID = UUID()
        var existing = savedModel("legacy-chat", capabilities: [.text])
        existing.providerID = providerID
        var discovered = savedModel("legacy-chat", capabilities: [.text, .vision])
        discovered.providerID = providerID

        let merged = ModelCatalogMerger.merge(existing: [existing], discovered: [discovered])
        #expect(merged.count == 1)
        #expect(merged[0].capabilities.contains(.vision) == false)
        #expect(merged[0].explicitCapabilities == nil)
    }

    @Test("Legacy repair for the endpoint-reported bits still works")
    func legacyRowStillRepairsTextAndTools() throws {
        let providerID = UUID()
        var existing = savedModel("legacy-chat", capabilities: [.text])
        existing.providerID = providerID
        var discovered = savedModel("legacy-chat", capabilities: [.text, .tools, .vision])
        discovered.providerID = providerID

        let merged = ModelCatalogMerger.merge(existing: [existing], discovered: [discovered])
        #expect(merged[0].capabilities.contains(.tools))
        #expect(merged[0].capabilities.contains(.vision) == false)
    }

    @Test("An explicit off survives a refresh that reports the bit")
    func explicitOffSurvivesRefresh() throws {
        let providerID = UUID()
        var existing = savedModel(
            "vision-off",
            capabilities: [.text, .tools],
            explicitCapabilities: [.vision]
        )
        existing.providerID = providerID
        var discovered = savedModel("vision-off", capabilities: [.text, .tools, .vision])
        discovered.providerID = providerID

        let merged = ModelCatalogMerger.merge(existing: [existing], discovered: [discovered])
        #expect(merged[0].capabilities.contains(.vision) == false)
        #expect(merged[0].explicitCapabilities?.contains(.vision) == true)
    }

    @Test("A confirmed migration bit survives a later refresh")
    func reviewedVisionSurvivesLaterRefresh() throws {
        let providerID = UUID()
        let catalog = try validatedIndex(metadataDocument([
            metadataEntry(
                "vendor",
                name: "Vendor",
                models: ["gemini-like"],
                modelMetadata: ["gemini-like": catalogMetadata(input: ["text", "image"], output: ["text"])]
            )
        ]))
        let provider = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.com/v1")!,
            presetID: "vendor"
        )
        let legacy = savedModel(
            "gemini-like", capabilities: [.text, .tools, .approval], providerID: providerID)

        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [providerID: [legacy]],
            catalog: catalog
        )
        #expect(proposals.count == 1)
        #expect(proposals[0].addedCapabilities.contains(.vision))

        let applied = ProviderCatalogCapabilityMigration.applying(proposals[0], to: legacy)
        #expect(applied.capabilities.contains(.vision))
        #expect(applied.explicitCapabilities?.contains(.vision) == true)

        // A later discovery refresh cannot revert the reviewed decision.
        var discovered = savedModel(
            "gemini-like", capabilities: [.text, .tools], providerID: providerID)
        discovered.providerID = providerID
        let merged = ModelCatalogMerger.merge(existing: [applied], discovered: [discovered])
        #expect(merged[0].capabilities.contains(.vision))
        // Nor can a user turn it off and have the refresh re-enable it.
        var turnedOff = merged[0]
        turnedOff.capabilities.remove(.vision)
        let afterRefresh = ModelCatalogMerger.merge(existing: [turnedOff], discovered: [discovered])
        #expect(afterRefresh[0].capabilities.contains(.vision) == false)
    }

    @Test("Freshly discovered models keep metadata-driven capabilities")
    func newModelKeepsDiscoveredCapabilities() throws {
        let discovered = savedModel("fresh", capabilities: [.text, .tools, .vision])
        let merged = ModelCatalogMerger.merge(existing: [], discovered: [discovered])
        #expect(merged[0].capabilities.contains(.vision))
    }
}

// MARK: - Reviewed migration

@Suite("FloeProviders.ProviderCatalogCapabilityMigration")
struct ProviderCatalogCapabilityMigrationTests {

    private func catalog() throws -> ProviderCatalogIndex {
        try validatedIndex(metadataDocument([
            metadataEntry(
                "vendor",
                name: "Vendor",
                models: ["vision-chat", "plain-chat", "image-maker"],
                modelMetadata: [
                    "vision-chat": catalogMetadata(input: ["text", "image"], output: ["text"]),
                    "plain-chat": catalogMetadata(input: ["text"], output: ["text"]),
                    "image-maker": catalogMetadata(input: ["text", "image"], output: ["image"])
                ]
            ),
            metadataEntry(
                "other-vendor",
                name: "Other",
                models: ["vision-chat"],
                modelMetadata: ["vision-chat": catalogMetadata(input: ["text", "image"], output: ["text"])]
            )
        ]))
    }

    private func provider(_ presetID: String) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.com/v1")!,
            presetID: presetID
        )
    }

    @Test("Only real additions on inference models become proposals")
    func proposalsAreAdditionsOnly() throws {
        let catalog = try self.catalog()
        let provider = self.provider("vendor")
        let models = [
            savedModel("vision-chat", capabilities: [.text, .tools, .approval]),
            savedModel("plain-chat", capabilities: [.text, .tools, .approval]),
            savedModel("image-maker", capabilities: [.imageGeneration])
        ]
        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [provider.id: models],
            catalog: catalog
        )
        #expect(proposals.map(\.remoteModelID) == ["vision-chat"])
        #expect(proposals[0].addedCapabilities == [.vision])
        #expect(proposals[0].currentCapabilities == [.text, .tools, .approval])
        #expect(proposals[0].providerName == "Vendor")
    }

    @Test("Explicitly decided bits are never proposed")
    func explicitDecisionsAreNotProposed() throws {
        let catalog = try self.catalog()
        let provider = self.provider("vendor")
        let models = [
            savedModel(
                "vision-chat",
                capabilities: [.text, .tools, .approval],
                explicitCapabilities: [.vision]
            )
        ]
        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [provider.id: models],
            catalog: catalog
        )
        #expect(proposals.isEmpty)
    }

    @Test("Providers without a catalog identity are untouched")
    func unknownPresetProducesNothing() throws {
        let catalog = try self.catalog()
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.com/v1")!,
            presetID: nil
        )
        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [provider.id: [savedModel("vision-chat", capabilities: [.text])]],
            catalog: catalog
        )
        #expect(proposals.isEmpty)
        let hiddenProvider = self.provider("github-copilot")
        let hiddenProposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [hiddenProvider],
            modelsByProvider: [hiddenProvider.id: [savedModel("vision-chat", capabilities: [.text])]],
            catalog: catalog
        )
        #expect(hiddenProposals.isEmpty)
    }

    @Test("Applying preserves identity, limits and unrelated flags")
    func applyingPreservesEverythingElse() throws {
        let catalog = try self.catalog()
        let provider = self.provider("vendor")
        let model = savedModel(
            "vision-chat", capabilities: [.text, .tools, .approval], providerID: provider.id)
        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [provider.id: [model]],
            catalog: catalog
        )
        let updated = ProviderCatalogCapabilityMigration.applying(proposals[0], to: model)
        #expect(updated.id == model.id)
        #expect(updated.providerID == model.providerID)
        #expect(updated.remoteModelID == model.remoteModelID)
        #expect(updated.displayName == model.displayName)
        #expect(updated.limits == model.limits)
        #expect(updated.capabilities == [.text, .tools, .approval, .vision])
        #expect(updated.explicitCapabilities == [.vision])
    }

    @Test("An explicit off after the review makes apply keep the current row")
    func explicitOffAfterReviewKeepsCurrent() throws {
        let catalog = try self.catalog()
        let provider = self.provider("vendor")
        let model = savedModel(
            "vision-chat", capabilities: [.text, .tools, .approval], providerID: provider.id)
        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [provider.id: [model]],
            catalog: catalog
        )
        let proposal = try #require(proposals.first)
        #expect(ProviderCatalogCapabilityMigration.matches(proposal, current: model))

        // The user explicitly decides OFF before Apply: the mask owns the bit
        // while capabilities stay without it. The displayed review is now
        // stale and must not re-add the bit.
        var afterExplicitOff = model
        afterExplicitOff.explicitCapabilities = [.vision]
        #expect(!ProviderCatalogCapabilityMigration.matches(proposal, current: afterExplicitOff))
        let applied = ProviderCatalogCapabilityMigration.applying(proposal, to: afterExplicitOff)
        #expect(applied == afterExplicitOff)
        #expect(!applied.capabilities.contains(.vision))
    }

    @Test("A proposal never applies to a different model, provider or remote id")
    func proposalRejectsWrongIdentity() throws {
        let catalog = try self.catalog()
        let provider = self.provider("vendor")
        let model = savedModel(
            "vision-chat", capabilities: [.text, .tools, .approval], providerID: provider.id)
        let proposals = ProviderCatalogCapabilityMigration.proposals(
            providers: [provider],
            modelsByProvider: [provider.id: [model]],
            catalog: catalog
        )
        let proposal = try #require(proposals.first)
        // The unchanged row is the valid case; every identity drift below
        // must invalidate the reviewed snapshot.
        #expect(ProviderCatalogCapabilityMigration.matches(proposal, current: model))

        var wrongModel = model
        wrongModel.id = UUID()
        #expect(!ProviderCatalogCapabilityMigration.matches(proposal, current: wrongModel))
        #expect(ProviderCatalogCapabilityMigration.applying(proposal, to: wrongModel) == wrongModel)

        var wrongProvider = model
        wrongProvider.providerID = UUID()
        #expect(!ProviderCatalogCapabilityMigration.matches(proposal, current: wrongProvider))
        #expect(ProviderCatalogCapabilityMigration.applying(proposal, to: wrongProvider) == wrongProvider)

        var wrongRemote = model
        wrongRemote.remoteModelID = "vision-chat-2"
        #expect(!ProviderCatalogCapabilityMigration.matches(proposal, current: wrongRemote))
        #expect(ProviderCatalogCapabilityMigration.applying(proposal, to: wrongRemote) == wrongRemote)

        // The capability arriving through another path also invalidates the
        // reviewed snapshot (the shown before-state no longer holds).
        var bitArrived = model
        bitArrived.capabilities.insert(.vision)
        #expect(!ProviderCatalogCapabilityMigration.matches(proposal, current: bitArrived))
        #expect(ProviderCatalogCapabilityMigration.applying(proposal, to: bitArrived) == bitArrived)
    }
}

// MARK: - Bundled catalog

@Suite("FloeProviders.BundledCatalogCapabilities")
struct BundledCatalogCapabilitiesTests {

    private final class CatalogBundleToken {}

    /// The catalog ACTUALLY BUNDLED WITH THE APP is read first: in the App
    /// test host that is the app bundle on internal storage, and it is the
    /// file the shipped product really loads (the checkout path stays as the
    /// SwiftPM/macOS fallback). Reading the external-volume checkout path from
    /// a simulator app host was observed to block indefinitely in `open()`
    /// (sampled 2026-10-16), which is a test-environment hazard, not a
    /// product behavior.
    private func bundledIndex() throws -> ProviderCatalogIndex {
        let bundles = [
            Bundle(for: CatalogBundleToken.self),
            Bundle.main
        ]
        for bundle in bundles {
            if let url = bundle.url(forResource: "ProviderCatalog", withExtension: "json") {
                return try ProviderCatalogIndex.validated(from: Data(contentsOf: url))
            }
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = packageRoot.appendingPathComponent("FloeApp/Resources/ProviderCatalog.json")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            try Test.cancel("ProviderCatalog.json not present in this checkout")
        }
        return try ProviderCatalogIndex.validated(from: Data(contentsOf: catalogURL))
    }

    @Test("The bundled catalog now carries verified per-model metadata")
    func bundledCatalogCarriesMetadata() throws {
        let index = try bundledIndex()
        let entriesWithMetadata = index.all.filter { !($0.modelMetadata ?? [:]).isEmpty }
        #expect(entriesWithMetadata.count >= 10)
        var visionCandidates = 0
        for entry in entriesWithMetadata {
            for metadata in (entry.modelMetadata ?? [:]).values
            where ProviderCatalogCapabilityResolver.supportsImageInput(metadata) {
                visionCandidates += 1
            }
        }
        // Live models.dev data advertises image input for hundreds of the
        // bundled inference models; zero would mean the metadata was lost.
        #expect(visionCandidates > 100)
        // Unsupported (never offered) entries stay metadata-free.
        for entry in index.all where entry.availability == .unsupported {
            #expect((entry.modelMetadata ?? [:]).isEmpty, "\(entry.presetID)")
        }
    }

    @Test("The hidden presets are absent from bundled search but still resolvable")
    func bundledHiddenPresets() throws {
        let index = try bundledIndex()
        for hidden in ProviderCatalogIndex.hiddenPresetIDs {
            #expect(index.search(query: hidden, filter: .all, configuredPresetIDs: []).isEmpty)
            #expect(index.entry(presetID: hidden) != nil)
        }
        #expect(index.offeredProviderCount == index.all.count - ProviderCatalogIndex.hiddenPresetIDs.count)
    }

    @Test("Google's text role routes through the OpenAI-compatible endpoint, separate from images")
    func googleConversationRouteIsTruthful() throws {
        let index = try bundledIndex()
        let google = try #require(index.entry(presetID: "google"))
        // The image connection is unchanged: native v1 root + apiKeyHeader.
        #expect(google.baseURL?.absoluteString == "https://generativelanguage.googleapis.com/v1")
        #expect(google.authStyle == "apiKeyHeader")

        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: google.kind,
            baseURL: google.baseURL,
            authStyle: google.authStyle,
            availability: google.availability,
            declared: google.serviceOffers
        )
        let conversation = try #require(offers.first { $0.role == .conversation })
        #expect(conversation.isUsable)
        #expect(conversation.connection == .distinct)
        #expect(conversation.endpoint?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai")
        #expect(conversation.models.contains("gemini-2.5-flash"))
        // The declared chat models still come from verified metadata, and the
        // metadata marks the flash chat models as image-input capable.
        let flash = try #require(google.modelMetadata?["gemini-2.5-flash"])
        #expect(ProviderCatalogCapabilityResolver.supportsImageInput(flash))
        #expect(ProviderCatalogCapabilityResolver.capabilities(
            for: flash,
            base: ModelCapabilities.defaultTextModel(for: .openAIChatCompletions)
        ).contains(.vision))
        // Image output models are NOT vision chat models.
        let imageModel = try #require(google.modelMetadata?["gemini-2.5-flash-image"])
        #expect(ProviderCatalogCapabilityResolver.supportsImageInput(imageModel) == false)
    }
}

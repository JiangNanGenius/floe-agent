// FloeAppTests — Role-specific provider editor contracts.
//
// These tests pin the editor's role-specific decision rules WITHOUT a
// ConversationCenter, Keychain or network: every member under test is a pure
// static of ProviderEditorViewModel driven by the FloeProviders form spec.
// Offline only (the resolver probes shipped adapters, never the wire).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeProviders
@testable import FloeApp

@Suite("FloeApp.ProviderFormSpec")
@MainActor
struct ProviderFormSpecAppTests {

    private func chatModel(_ remoteID: String, providerID: UUID) -> ModelProfile {
        ModelProfile(
            providerID: providerID,
            remoteModelID: remoteID,
            displayName: remoteID,
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 16_384),
            capabilities: [.text, .tools]
        )
    }

    // MARK: - Supplier routes

    @Test("Role preset lists show implemented routes only")
    func rolePresetLists() {
        #expect(
            ProviderEditorViewModel.presets(for: .image).map(\.id)
                == [.openAI, .volcengineArk, .alibabaStudio, .googleGemini, .kimiCode]
        )
        #expect(
            ProviderEditorViewModel.presets(for: .video).map(\.id)
                == [.volcengineArk, .alibabaStudio, .googleGemini]
        )
        // The video list can no longer contain a generic custom endpoint and
        // the image list no longer offers the dead generic custom route.
        #expect(!ProviderEditorViewModel.presets(for: .video).map(\.id).contains(.custom))
        #expect(!ProviderEditorViewModel.presets(for: .image).map(\.id).contains(.custom))
        #expect(!ProviderEditorViewModel.presets(for: .video).map(\.id).contains(.openAI))
        let chat = ProviderEditorViewModel.presets(for: .conversation).map(\.id)
        #expect(chat.contains(.openAI))
        #expect(chat.contains(.custom))
        #expect(!chat.contains(.googleGemini))
        #expect(!chat.contains(.local))
    }

    // MARK: - Verified media merge (no blanket stamp)

    @Test("Chat listing results are never blanket-stamped as image models")
    func mediaMergeNeverStampsUnverified() {
        let providerID = UUID()
        let spec = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: .openAIResponses,
            baseURL: URL(string: "https://api.openai.com/v1")
        )
        let existing = ModelProfile(
            id: UUID(),
            providerID: providerID,
            remoteModelID: "gpt-image-2",
            displayName: "我的图像模型",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 0),
            capabilities: [.imageGeneration],
            useSurfaces: .imageGeneration,
            isEnabled: false,
            isHiddenFromPrimaryPicker: true,
            explicitCapabilities: [.imageGeneration]
        )
        let discovered = [
            chatModel("gpt-image-2", providerID: providerID),
            chatModel("gpt-image-2.5-flare", providerID: providerID),
            chatModel("deepseek-chat", providerID: providerID)
        ]
        let outcome = ProviderEditorViewModel.mediaMergePlan(
            existing: [existing],
            discovered: discovered,
            spec: spec,
            providerID: providerID
        )
        // Existing row preserved byte-for-byte (disabled + explicit bits).
        let expectedCapabilities = ModelCapabilities.imageGeneration
        let preservedExistingRow = outcome.models.contains { model in
            model.id == existing.id && model.isEnabled == false
                && model.capabilities == expectedCapabilities
                && model.explicitCapabilities == expectedCapabilities
        }
        #expect(preservedExistingRow)
        // No duplicate for the already-known verified ID.
        #expect(outcome.models.filter { $0.remoteModelID == "gpt-image-2" }.count == 1)
        // The verified manifest model is added with the role contract.
        let flare = outcome.models.first(where: { $0.remoteModelID == "gpt-image-2.5-flare" })
        #expect(flare != nil)
        #expect((flare?.capabilities ?? []) == [.imageGeneration, .imageEditing])
        #expect((flare?.useSurfaces ?? []) == .imageGeneration)
        #expect(flare?.isHiddenFromPrimaryPicker == true)
        #expect(flare?.providerID == providerID)
        // The chat model is skipped, never converted.
        #expect(outcome.skippedRemoteIDs == ["deepseek-chat"])
        #expect(!outcome.models.contains(where: { $0.remoteModelID == "deepseek-chat" }))
    }

    @Test("Kimi Code account listings remain the trusted image source")
    func mediaMergeTrustsKimiListing() {
        let providerID = UUID()
        let spec = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: .kimiCode,
            baseURL: ProviderPreset.kimiCode.defaultBaseURL
        )
        #expect(spec.trustsDiscoveryForMedia)
        let outcome = ProviderEditorViewModel.mediaMergePlan(
            existing: [],
            discovered: [chatModel("account-image-model-9", providerID: providerID)],
            spec: spec,
            providerID: providerID
        )
        #expect(outcome.skippedRemoteIDs.isEmpty)
        #expect(outcome.verifiedAddedIDs.count == 1)
        #expect(outcome.models.first?.capabilities.contains(.imageGeneration) == true)
    }

    @Test("Video verified merge follows the video manifest only")
    func mediaMergeVideo() {
        let providerID = UUID()
        let spec = ProviderFormSpecResolver.resolve(
            role: .video,
            preset: .volcengineArk,
            baseURL: ProviderPreset.volcengineArk.defaultBaseURL
        )
        let outcome = ProviderEditorViewModel.mediaMergePlan(
            existing: [],
            discovered: [
                chatModel("doubao-seedance-2-5-260628", providerID: providerID),
                chatModel("doubao-seed-1-6-250615", providerID: providerID)
            ],
            spec: spec,
            providerID: providerID
        )
        #expect(outcome.verifiedAddedIDs.count == 1)
        #expect(outcome.skippedRemoteIDs == ["doubao-seed-1-6-250615"])
        let staged = outcome.models.first
        #expect(staged?.capabilities.contains(.videoGeneration) == true)
        #expect(staged?.capabilities.contains(.imageGeneration) == false)
    }

    // MARK: - New-add selection gate

    @Test("A brand-new add requires one selection; edits keep the empty-provider path")
    func newAddSelectionGate() throws {
        let gate = ProviderEditorViewModel.newAddSelectionGateIssue(
            isNewProvider: true, selectedCount: 0
        )
        #expect(gate?.messageKey == "providers.no_models")
        #expect(ProviderEditorViewModel.newAddSelectionGateIssue(
            isNewProvider: true, selectedCount: 1
        ) == nil)
        #expect(ProviderEditorViewModel.newAddSelectionGateIssue(
            isNewProvider: false, selectedCount: 0
        ) == nil)
        // The message key is an existing bilingual catalog entry, so the
        // rejection is readable before any new string lands.
        let message = ProviderEditorViewModel.presentableMessage(for: try #require(gate))
        #expect(!message.isEmpty)
        #expect(message != "providers.no_models")
    }

    // MARK: - Role-default refresh without overwrite

    @Test("A saved video add fills only a missing default with an adapter-usable route")
    func videoDefaultFill() {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: ProviderPreset.volcengineArk.defaultBaseURL
        )
        let videoModel = ModelProfile(
            providerID: providerID,
            remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Seedance 2.5",
            limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
            capabilities: [.videoGeneration],
            useSurfaces: .videoGeneration,
            isHiddenFromPrimaryPicker: true
        )
        var preferences = ModelSelectionPreferences()
        preferences.defaultVideoModelID = nil
        let filled = ProviderEditorViewModel.fillingMissingRoleDefaults(
            preferences, canonical: [videoModel], role: .video, provider: provider
        )
        #expect(filled.defaultVideoModelID == videoModel.id)
        // An existing global default is never overwritten.
        let other = UUID()
        preferences.defaultVideoModelID = other
        #expect(ProviderEditorViewModel.fillingMissingRoleDefaults(
            preferences, canonical: [videoModel], role: .video, provider: provider
        ).defaultVideoModelID == other)
        // A model on a kind without a shipped video adapter never becomes
        // the default (this is exactly the UI/runtime filter mismatch).
        let openAIProvider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: ProviderPreset.openAIResponses.defaultBaseURL
        )
        let stale = ModelProfile(
            providerID: openAIProvider.id,
            remoteModelID: "gpt-no-video-route",
            displayName: "Stale",
            limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
            capabilities: [.videoGeneration],
            useSurfaces: .videoGeneration
        )
        var empty = ModelSelectionPreferences()
        empty.defaultVideoModelID = nil
        #expect(ProviderEditorViewModel.fillingMissingRoleDefaults(
            empty, canonical: [stale], role: .video, provider: openAIProvider
        ).defaultVideoModelID == nil)
        // A disabled provider fills nothing.
        var disabled = provider
        disabled.isEnabled = false
        var prefs2 = ModelSelectionPreferences()
        prefs2.defaultVideoModelID = nil
        #expect(ProviderEditorViewModel.fillingMissingRoleDefaults(
            prefs2, canonical: [videoModel], role: .video, provider: disabled
        ).defaultVideoModelID == nil)
    }

    @Test("A saved image add respects the auxiliary mode and never overwrites")
    func imageDefaultFill() {
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: ProviderPreset.openAIResponses.defaultBaseURL
        )
        let generateOnly = ModelProfile(
            providerID: providerID,
            remoteModelID: "gpt-image-2",
            displayName: "GPT Image 2",
            limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
            capabilities: [.imageGeneration],
            useSurfaces: .imageGeneration,
            isHiddenFromPrimaryPicker: true
        )
        let both = ModelProfile(
            providerID: providerID,
            remoteModelID: "gpt-image-2.5-flare",
            displayName: "GPT Image 2.5 Flare",
            limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0),
            capabilities: [.imageGeneration, .imageEditing],
            useSurfaces: .imageGeneration,
            isHiddenFromPrimaryPicker: true
        )
        // Shared mode needs a model that can do both operations.
        var shared = ModelSelectionPreferences(auxiliaryImageMode: .shared)
        shared.sharedImageModelID = nil
        let filledShared = ProviderEditorViewModel.fillingMissingRoleDefaults(
            shared, canonical: [generateOnly, both], role: .image, provider: provider
        )
        #expect(filledShared.sharedImageModelID == both.id)
        let keepID = UUID()
        shared.sharedImageModelID = keepID
        #expect(ProviderEditorViewModel.fillingMissingRoleDefaults(
            shared, canonical: [both], role: .image, provider: provider
        ).sharedImageModelID == keepID)
        // Separate mode fills only the missing slots.
        var separate = ModelSelectionPreferences(auxiliaryImageMode: .separate)
        let filledSeparate = ProviderEditorViewModel.fillingMissingRoleDefaults(
            separate, canonical: [generateOnly, both], role: .image, provider: provider
        )
        #expect(filledSeparate.imageGenerationModelID == generateOnly.id)
        #expect(filledSeparate.imageEditingModelID == both.id)
        separate.imageGenerationModelID = both.id
        #expect(ProviderEditorViewModel.fillingMissingRoleDefaults(
            separate, canonical: [generateOnly, both], role: .image, provider: provider
        ).imageGenerationModelID == both.id)
    }

    @Test("The conversation role path is untouched by the media fill")
    func conversationFillUnchanged() {
        var preferences = ModelSelectionPreferences()
        preferences.defaultAgentModelID = nil
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: ProviderPreset.openAIResponses.defaultBaseURL
        )
        let model = chatModel("gpt-5", providerID: provider.id)
        #expect(ProviderEditorViewModel.fillingMissingRoleDefaults(
            preferences, canonical: [model], role: .conversation, provider: provider
        ) == preferences)
    }
}
#endif

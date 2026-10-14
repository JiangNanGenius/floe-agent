// FloeAppTests — Provider save regression contract (T1).
//
// Installed 269 feedback: saving any provider showed
// "Invalid configuration: Provider display name must be 1...256 bytes
// without control characters". Investigation outcome (see
// Local/Private/unified-design-20261011/T1/REPORT.md):
//   * the shipped presets and every available ProviderCatalog.json name pass
//     the displayed-name rule (pinned here),
//   * the reproduced defects are save-ordering/side-effect defects: the editor
//     checked the profile AFTER writing the Keychain secret + sync preference,
//     and re-read still-mutable fields after awaits, so a failure could mutate
//     credentials while reporting nothing saved, and concurrent edits could
//     commit content that never passed preflight.
//
// These tests run in the FloeApp unit-test bundle (app module). The shared
// frozen-request mapping and runner live in FloeCore so the same code is
// covered on the macOS host (FloeCoreTests.ProviderProfileTests); this suite
// pins the App-facing pieces: bundled preset/catalog names, bilingual
// messages, editor message mapping and the full runner contract with fakes.
//
// Integration gate (serialized heavy slot): save a real preset and a real
// legacy provider in the Simulator with an invalid name (oversized/control),
// confirming zero Keychain/db side effects and field-level readable errors;
// then a valid edit during an in-flight save confirming the committed content
// is the frozen snapshot. See REPORT.md for the exact UI steps.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeProviders
import FloeExecution
@testable import FloeApp

@Suite("FloeApp.ProviderSaveRegression")
@MainActor
struct ProviderSaveRegressionTests {

    // MARK: - Bundled content

    @Test("Every shipped preset builds a provider identity the save gate accepts")
    func shippedPresetsValidate() throws {
        for preset in ProviderPreset.all {
            let profile = ProviderProfile(
                kind: preset.kind,
                wireProtocol: preset.defaultProtocol,
                baseURL: preset.defaultBaseURL,
                displayName: preset.displayName,
                allowsPlainHTTP: preset.defaultBaseURL.scheme?.lowercased() == "http"
            )
            #expect(
                ProviderConfigurationValidation.issues(for: profile).isEmpty,
                "preset \(preset.id.rawValue) must pass the display-name and endpoint rules"
            )
            try profile.validate()
        }
    }

    @Test("Every available catalog name produces a valid frozen save request")
    func catalogNamesProduceValidRequests() throws {
        guard let index = ProviderCatalogIndex.loadBundled(bundle: .main) else {
            try Test.cancel("ProviderCatalog.json not bundled in this test host")
        }
        var checked = 0
        for entry in index.all where entry.availability == .available {
            let draft = ProviderSaveDraft(
                providerID: UUID(),
                kind: entry.kind,
                wireProtocol: entry.defaultProtocol,
                baseURLString: entry.baseURL?.absoluteString ?? "",
                displayName: entry.name,
                presetID: entry.presetID,
                existingSecretRef: nil,
                nonSecretHeaders: [:],
                isEnabled: true,
                allowsPlainHTTP: false,
                toolNameCompatibility: entry.toolNameCompatibility || entry.presetID == "deepseek",
                syncEnabled: true,
                enteredAPIKey: "",
                selectedModels: [],
                managedCapabilities: .text,
                serviceRoleIsConversation: entry.kind != .googleGemini,
                defaultModelID: nil,
                existingCreatedAt: nil,
                existingSyncRevision: 0
            )
            switch draft.makeRequest() {
            case .success:
                checked += 1
            case .failure(let report):
                Issue.record("\(entry.presetID): \(report.issues.map(\.problem.rawValue))")
            }
        }
        #expect(checked >= 16)
    }

    // MARK: - Field-level messages

    @Test("Editor presents catalog or bilingual messages without echoing raw control characters")
    func presentableMessages() {
        let tooLong = ProviderConfigurationIssue(
            field: .displayName,
            problem: .displayNameTooLong,
            messageKey: "providers.validation.display_name_rules",
            arguments: ["256", "257"]
        )
        let message = ProviderEditorViewModel.presentableMessage(for: tooLong)
        #expect(!message.isEmpty)
        #expect(!message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        #expect(message.contains("257") || message.contains("256"))

        let forbiddenHeader = ProviderConfigurationIssue(
            field: .nonSecretHeader,
            problem: .headerForbidden,
            messageKey: "providers.validation.header_forbidden",
            arguments: ["Authorization"]
        )
        let headerMessage = ProviderEditorViewModel.presentableMessage(for: forbiddenHeader)
        #expect(headerMessage.contains("Authorization"))
    }

    @Test("Editor names with pasted formatting and emoji persist canonically")
    func pastedNamesPersistAndReadBack() async throws {
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: RecordingSecrets(), committer: committer)
        let frozen = try request(draft(name: "\u{FEFF}公司\n👩‍💻\u{200B} 网关"))
        try await runner.run(frozen)
        #expect(committer.committed.first?.profile.displayName == "公司 👩‍💻 网关")
        #expect(committer.verified.first?.profile.displayName == "公司 👩‍💻 网关")
    }

    @Test("Malformed BLE UUIDs fail safely before Bluetooth initialization")
    func invalidBluetoothEndpoints() async {
        let service = CoreBluetoothSerialService()
        for uuid in ["", "not-a-uuid", "123", "GGGG", "123456789", "12345678-1234-1234-1234-12345678901Z"] {
            do {
                _ = try await service.open(runID: UUID(), endpoint: .init(
                    peripheralID: UUID(), serviceUUID: uuid, writeCharacteristicUUID: "FFE1"
                ), timeout: 1)
                Issue.record("Malformed endpoint must be rejected")
            } catch let error as BluetoothSerialError {
                guard case .connectionFailed = error else {
                    Issue.record("Validation must precede CoreBluetooth/permission work"); continue
                }
            } catch { Issue.record("Unexpected endpoint error type") }
        }
        for uuid in ["FFE0", "1234abcd", "0000FFE0-0000-1000-8000-00805F9B34FB"] {
            do {
                try BluetoothSerialEndpoint(peripheralID: UUID(), serviceUUID: uuid,
                    writeCharacteristicUUID: "FFE1", notifyCharacteristicUUID: "FFE2").validate()
            } catch { Issue.record("Valid GATT UUID must be accepted") }
        }
    }

    // MARK: - Fakes

    private final class RecordingSecrets: ProviderSecretSaving, @unchecked Sendable {
        var syncChanges = 0
        var secrets: [Data] = []
        var failSecret = false

        func setSyncEnabled(_ enabled: Bool, for providerID: UUID) async throws {
            syncChanges += 1
        }
        func storeSecret(_ secret: Data, scopeProviderID: UUID) async throws {
            if failSecret { throw FloeError.internalError("keychain unavailable") }
            secrets.append(secret)
        }
    }

    private final class RecordingCommitter: ProviderBundleCommitting, @unchecked Sendable {
        var committed: [ProviderSaveRequest] = []
        var verified: [ProviderSaveRequest] = []
        var hold: Duration?
        var readbackFailure: String?
        var syncPending = false
        var syncError: String?

        func commitProviderBundle(_ request: ProviderSaveRequest) async throws -> ProviderBundleCommitResult {
            if let hold { try? await Task.sleep(for: hold) }
            committed.append(request)
            return ProviderBundleCommitResult(
                saved: request.selectedModels,
                syncPending: syncPending,
                syncError: syncError
            )
        }
        func verifyProviderPersisted(_ request: ProviderSaveRequest) async -> String? {
            verified.append(request)
            return readbackFailure
        }
    }

    private func draft(
        name: String = "DeepSeek",
        key: String = "",
        existing: ProviderProfile? = nil
    ) -> ProviderSaveDraft {
        ProviderSaveDraft(
            providerID: existing?.id ?? UUID(),
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURLString: "https://api.deepseek.com",
            displayName: name,
            presetID: existing?.presetID ?? "deepseek",
            existingSecretRef: existing?.secretRef,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            toolNameCompatibility: true,
            syncEnabled: existing?.secretRef?.synchronizable ?? true,
            enteredAPIKey: key,
            selectedModels: [],
            managedCapabilities: .text,
            serviceRoleIsConversation: true,
            defaultModelID: nil,
            existingCreatedAt: existing?.createdAt,
            existingSyncRevision: existing?.syncRevision ?? 0
        )
    }

    private func request(_ draft: ProviderSaveDraft) throws -> ProviderSaveRequest {
        switch draft.makeRequest() {
        case .success(let value): return value
        case .failure(let report):
            Issue.record("unexpected issues: \(report.issues.map(\.problem.rawValue))")
            throw report
        }
    }

    // MARK: - Ordering contract

    @Test("Invalid preflight performs zero secret/sync/commit work")
    func invalidPreflightZeroSideEffects() async throws {
        let secrets = RecordingSecrets()
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)

        guard case .failure = draft(name: "bad\0name").makeRequest() else {
            Issue.record("control-character name must be rejected"); return
        }
        guard case .failure = draft(name: String(repeating: "x", count: 257)).makeRequest() else {
            Issue.record("oversized name must be rejected"); return
        }
        #expect(secrets.syncChanges == 0)
        #expect(secrets.secrets.isEmpty)
        #expect(committer.committed.isEmpty)
        #expect(committer.verified.isEmpty)

        // The same gateways succeed for a valid request.
        try await runner.run(request(draft()))
        #expect(committer.committed.count == 1)
    }

    @Test("Edits during the commit await cannot change the frozen snapshot")
    func editsDuringSaveUseFrozenSnapshot() async throws {
        let secrets = RecordingSecrets()
        let committer = RecordingCommitter()
        committer.hold = .milliseconds(40)
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)

        let frozen = try request(draft(name: "Original", key: "sk-original"))
        let edited = try request(draft(name: "Edited later", key: "sk-edited"))
        #expect(frozen != edited)

        async let running = runner.run(frozen)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await running

        #expect(committer.committed.first?.profile.displayName == "Original")
        #expect(committer.committed.first?.apiKey == "sk-original")
        #expect(committer.verified.first?.profile.displayName == "Original")
        #expect(secrets.secrets == [Data("sk-original".utf8)])
    }

    @Test("Credential failure is classified before any local commit")
    func credentialFailurePhase() async throws {
        let secrets = RecordingSecrets()
        secrets.failSecret = true
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        do {
            _ = try await runner.run(request(draft(key: "sk")))
            Issue.record("expected failure")
        } catch let error as ProviderSaveRunError {
            guard case .credentialOrSync = error else {
                Issue.record("unexpected phase \(error.phase)"); return
            }
        }
        #expect(committer.committed.isEmpty)
    }

    @Test("Readback mismatch stays a distinct failure phase")
    func readbackFailurePhase() async throws {
        let secrets = RecordingSecrets()
        let committer = RecordingCommitter()
        committer.readbackFailure = "readback mismatch"
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        do {
            _ = try await runner.run(request(draft()))
            Issue.record("expected failure")
        } catch let error as ProviderSaveRunError {
            guard case .readbackMismatch = error else {
                Issue.record("unexpected phase \(error.phase)"); return
            }
        }
    }

    @Test("Local commit with pending sync is a success with explicit pending state")
    func syncPendingIsNotFailure() async throws {
        let secrets = RecordingSecrets()
        let committer = RecordingCommitter()
        committer.syncPending = true
        committer.syncError = "iCloud unavailable"
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        let result = try await runner.run(request(draft(name: "DeepSeek")))
        guard case .committed(_, let syncPending, let syncError) = result else {
            Issue.record("expected commit"); return
        }
        #expect(syncPending == true)
        #expect(syncError == "iCloud unavailable")
    }

    @Test("Legacy provider with nil name re-saves without fabricating one")
    func legacyNilNameReSave() throws {
        let legacy = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!,
            displayName: nil,
            secretRef: SecretReference(keychainAccount: "provider.legacy", synchronizable: true)
        )
        let frozen = try request(draft(name: "   ", existing: legacy))
        #expect(frozen.profile.displayName == nil)
        #expect(frozen.profile.id == legacy.id)
        #expect(frozen.profile.secretRef?.keychainAccount == "provider.legacy")
        // No new secret was entered: the Keychain item stays untouched.
        #expect(frozen.apiKey == nil)
    }
}

// MARK: - Embedded catalog selection and optional multi-service offers

/// Pins the editor wiring for the T1 contract: the catalog search lives in
/// the same add/edit form (no independent page), selection preserves
/// uncustomized form state, credentials never cross an incompatible
/// connection, and an additional role stages real models on the SAME
/// provider connection without touching the default model.
@Suite("FloeApp.ProviderServiceOfferEditor")
@MainActor
struct ProviderServiceOfferEditorTests {

    private func makeCatalog(_ providers: [ProviderCatalogEntry]) throws -> ProviderCatalogIndex {
        let document = ProviderCatalogDocument(
            schemaVersion: 1,
            source: .init(
                project: "tests",
                url: "https://example.invalid",
                license: "MIT",
                documentSHA256: String(repeating: "a", count: 64),
                fetchedAt: "2026-10-14T00:00:00Z"
            ),
            providers: providers
        )
        return try ProviderCatalogIndex.validated(from: JSONEncoder().encode(document))
    }

    private func openAIEntry(
        presetID: String,
        baseURL: String,
        serviceOffers: [ProviderCatalogServiceOffer]? = nil,
        kind: ProviderKind = .openAI
    ) -> ProviderCatalogEntry {
        ProviderCatalogEntry(
            presetID: presetID,
            name: presetID,
            aliases: [],
            kind: kind,
            defaultProtocol: .openAIChatCompletions,
            baseURL: URL(string: baseURL),
            domains: [],
            models: ["gpt-5"],
            availability: .available,
            unsupportedReason: nil,
            upstreamID: presetID,
            authStyle: "bearer",
            toolNameCompatibility: false,
            serviceOffers: serviceOffers
        )
    }

    @Test("Selection preserves a custom name, keeps same-origin credentials and clears them on a host change")
    func selectionPreservesFormStateAndBoundsCredentials() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let suiteName = "floe.provider.offer.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = try makeCatalog([
            openAIEntry(presetID: "alias", baseURL: "https://api.openai.com/v1/alias"),
            openAIEntry(presetID: "openai", baseURL: "https://api.openai.com/v1")
        ])
        let viewModel = ProviderEditorViewModel(
            center: environment.conversationCenter,
            existing: nil,
            initialRole: .image,
            catalog: catalog,
            promptStore: ProviderServiceOfferPromptStore(defaults: defaults)
        )
        viewModel.displayName = "My Gateway"
        viewModel.apiKey = "fixture-key"

        // Same origin, different path: the typed key and custom name survive.
        let alias = try #require(catalog.all.first { $0.presetID == "alias" })
        viewModel.applyCatalogEntry(alias)
        #expect(viewModel.displayName == "My Gateway")
        #expect(viewModel.apiKey == "fixture-key")

        // Different host (the OpenAI entry is on the same host here, so use a
        // cross-host catalog entry to prove the clearing rule).
        let remote = try makeCatalog([
            openAIEntry(presetID: "remote", baseURL: "https://api.remote.example.com/v1")
        ])
        let remoteEntry = try #require(remote.all.first)
        viewModel.apiKey = "fixture-key"
        viewModel.applyCatalogEntry(remoteEntry)
        #expect(viewModel.displayName == "My Gateway")
        #expect(viewModel.apiKey.isEmpty)
    }

    @Test("Image start offers verified conversation configuration on the same connection")
    func imageStartOffersConversationWithDeclaredModels() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let suiteName = "floe.provider.offer.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let conversationOffer = ProviderCatalogServiceOffer(
            role: .conversation,
            protocols: [.openAIChatCompletions],
            models: ["gemini-2.5-pro"]
        )
        let catalog = try makeCatalog([
            openAIEntry(
                presetID: "gemini-images",
                baseURL: "https://generativelanguage.googleapis.com/v1",
                serviceOffers: [conversationOffer],
                kind: .googleGemini
            )
        ])
        let viewModel = ProviderEditorViewModel(
            center: environment.conversationCenter,
            existing: nil,
            initialRole: .image,
            catalogEntry: catalog.all.first,
            catalog: catalog,
            promptStore: ProviderServiceOfferPromptStore(defaults: defaults)
        )
        let conversation = try #require(viewModel.serviceOffers.first { $0.role == .conversation })
        #expect(conversation.isUsable)
        #expect(!conversation.requiresDiscovery)
        #expect(conversation.models == ["gemini-2.5-pro"])

        // The prompt is transient and opt-in; confirming stages only the
        // selected extra role and records the rest as declined.
        let prompt = try #require(viewModel.pendingServiceOfferPrompt)
        #expect(prompt.primaryRole == .image)
        #expect(prompt.offers.map(\.role).contains(.conversation))
        viewModel.confirmServiceOfferSelection([.conversation])
        #expect(viewModel.pendingServiceOfferPrompt == nil)
        #expect(viewModel.serviceOffers.allSatisfy { $0.role != .video })
        let staged = viewModel.modelsForSave.filter { $0.remoteModelID == "gemini-2.5-pro" }
        #expect(staged.count == 1)
        #expect(staged.first?.providerID == viewModel.providerID)
        #expect(staged.first?.capabilities.contains(.text) == true)
        #expect(viewModel.managedCapabilitiesForSave.contains(.text))

        // The frozen request keeps the media role as the initiating role and
        // never touches the default model.
        switch viewModel.makeSaveRequest() {
        case .success(let request):
            #expect(request.serviceRoleIsConversation == false)
            #expect(request.selectedModels.contains { $0.remoteModelID == "gemini-2.5-pro" })
        case .failure(let report):
            Issue.record("preflight rejected: \(report.issues.map(\.problem.rawValue))")
        }
        #expect(viewModel.defaultModelID == nil)
    }

    @Test("Declining an optional role hides the prompt and is remembered")
    func declineIsRememberedOnce() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let suiteName = "floe.provider.offer.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let promptStore = ProviderServiceOfferPromptStore(defaults: defaults)

        let catalog = try makeCatalog([
            openAIEntry(presetID: "openai", baseURL: "https://api.openai.com/v1")
        ])
        let viewModel = ProviderEditorViewModel(
            center: environment.conversationCenter,
            existing: nil,
            initialRole: .image,
            catalogEntry: catalog.all.first,
            catalog: catalog,
            promptStore: promptStore
        )
        #expect(viewModel.hasPendingServiceOfferPrompt)
        #expect(viewModel.pendingServiceOfferPrompt != nil)
        // A dismissal that is not a confirmation records the decline once.
        viewModel.dismissServiceOfferPrompt()
        #expect(viewModel.pendingServiceOfferPrompt == nil)
        #expect(!viewModel.hasPendingServiceOfferPrompt)
        #expect(viewModel.serviceOffers.allSatisfy { $0.role != .conversation })
        #expect(promptStore.declinedRoles(for: viewModel.providerID).contains(.conversation))

        // A second editor for the same provider identity does not re-prompt.
        let existingProfile = ProviderProfile(
            id: viewModel.providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            presetID: "openai"
        )
        let reopened = ProviderEditorViewModel(
            center: environment.conversationCenter,
            existing: existingProfile,
            initialRole: .image,
            catalog: catalog,
            promptStore: promptStore
        )
        #expect(reopened.serviceOffers.allSatisfy { $0.role != .conversation })
    }
}#endif

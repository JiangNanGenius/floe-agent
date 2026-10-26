// FloeCoreTests — ProviderProfile validation boundaries.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.ProviderProfile")
struct ProviderProfileTests {

    private func profile(url: String, allowsPlainHTTP: Bool = false) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: url)!,
            allowsPlainHTTP: allowsPlainHTTP
        )
    }

    @Test("Public HTTPS passes validation")
    func publicHTTPSPasses() throws {
        try profile(url: "https://api.openai.com").validate()
    }

    @Test("Public plain HTTP is rejected without acknowledgement")
    func publicHTTPRejected() {
        #expect(throws: FloeError.self) {
            try profile(url: "http://api.example.com").validate()
        }
    }

    @Test("Public plain HTTP is rejected even with acknowledgement")
    func publicHTTPRejectedWithAck() {
        #expect(throws: FloeError.self) {
            try profile(url: "http://203.0.113.10:8080", allowsPlainHTTP: true).validate()
        }
    }

    @Test("Localhost plain HTTP passes with acknowledgement")
    func localhostHTTPPasses() throws {
        try profile(url: "http://localhost:11434", allowsPlainHTTP: true).validate()
        try profile(url: "http://127.0.0.1:11434", allowsPlainHTTP: true).validate()
        try profile(url: "http://[::1]:8080", allowsPlainHTTP: true).validate()
    }

    @Test("RFC 1918 plain HTTP passes with acknowledgement")
    func privateNetworkHTTPPasses() throws {
        try profile(url: "http://10.0.0.5:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://192.168.1.20:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://172.16.0.3:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://172.31.255.255:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://169.254.1.1:8080", allowsPlainHTTP: true).validate()
    }

    @Test("172.15.x and 172.32.x are NOT private (boundary)")
    func privateRangeBoundary() {
        #expect(throws: FloeError.self) {
            try profile(url: "http://172.15.0.1:8080", allowsPlainHTTP: true).validate()
        }
        #expect(throws: FloeError.self) {
            try profile(url: "http://172.32.0.1:8080", allowsPlainHTTP: true).validate()
        }
    }

    @Test("Non-HTTP schemes are rejected")
    func nonHTTPSchemesRejected() {
        #expect(throws: FloeError.self) {
            try profile(url: "ftp://example.com").validate()
        }
    }

    @Test("Endpoint URL user info is rejected")
    func endpointUserInfoRejected() {
        #expect(throws: FloeError.self) {
            try profile(url: "https://user:password@example.com").validate()
        }
    }

    @Test("Provider display names are bounded single-line metadata")
    func displayNameValidation() throws {
        var valid = profile(url: "https://example.com")
        valid.displayName = "Company Gateway"
        try valid.validate()

        var multiline = valid
        multiline.displayName = "Company\nGateway"
        #expect(throws: FloeError.self) { try multiline.validate() }

        var oversized = valid
        oversized.displayName = String(repeating: "a", count: 257)
        #expect(throws: FloeError.self) { try oversized.validate() }
    }

    @Test("Secret-shaped non-secret headers are rejected case-insensitively")
    func secretHeadersRejected() {
        for name in ["Authorization", "x-api-key", "Cookie", "Proxy-Authorization"] {
            var candidate = profile(url: "https://example.com")
            candidate.nonSecretHeaders = [name: "must-not-enter-synced-metadata"]
            #expect(throws: FloeError.self) {
                try candidate.validate()
            }
        }
    }

    @Test("ModelProtocol Codable round-trip for all cases")
    func modelProtocolRoundTrip() throws {
        for value in ModelProtocol.allCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ModelProtocol.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("ModelCapabilities OptionSet composition")
    func capabilitiesComposition() {
        let caps: ModelCapabilities = [.text, .tools, .approval]
        #expect(caps.contains(.text))
        #expect(caps.contains(.tools))
        #expect(caps.contains(.approval))
        #expect(!caps.contains(.vision))
    }

    @Test("Unspecified output uses a bounded local safety budget")
    func unspecifiedOutputSafetyBudget() {
        let ordinary = ModelLimits(contextTokens: 128_000, maxOutputTokens: 0)
        #expect(ordinary.configuredMaxOutputTokens == nil)
        #expect(ordinary.clientOutputSafetyBytes == 2_048_000)

        let extreme = ModelLimits(contextTokens: Int.max, maxOutputTokens: Int.max)
        #expect(extreme.clientOutputSafetyBytes == 8 * 1_024 * 1_024)
    }

    // MARK: - Canonical validation (T1 provider save regression)

    private func validProfile(name: String? = nil) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!,
            displayName: name
        )
    }

    @Test("Nil and blank-normalized names stay valid (preset fallback preserved)")
    func blankNameFallback() throws {
        try validProfile(name: nil).validate()
        let normalized = ProviderConfigurationValidation.normalizedDisplayName("   \n\t ")
        #expect(normalized == nil)
        let cjk = ProviderConfigurationValidation.normalizedDisplayName("  公司网关 ")
        #expect(cjk == "公司网关")
    }

    @Test("Display name UTF-8 byte boundaries are 256 accepted and 257 rejected")
    func displayNameUTF8Boundaries() throws {
        // CJK: 3 bytes per scalar. 85 chars = 255 bytes, +"x" = 256.
        let bytes255 = String(repeating: "深", count: 85)
        let bytes256 = bytes255 + "x"
        let bytes257 = bytes255 + "xx"
        #expect(bytes255.utf8.count == 255)
        #expect(bytes256.utf8.count == 256)
        #expect(bytes257.utf8.count == 257)
        try validProfile(name: bytes255).validate()
        try validProfile(name: bytes256).validate()
        let oversized = validProfile(name: bytes257)
        #expect(throws: FloeError.self) { try oversized.validate() }
        let issues = ProviderConfigurationValidation.issues(for: oversized)
        #expect(issues.contains { $0.problem == .displayNameTooLong })
        #expect(issues.first?.arguments.contains("257") == true)
    }

    @Test("Control characters are rejected with the specific problem, whitespace is not")
    func displayNameControls() {
        for bad in ["line\nbreak", "nul\0", "del\u{7F}", "tab\there", "cr\rhere"] {
            let issues = ProviderConfigurationValidation.issues(for: validProfile(name: bad))
            #expect(issues.contains { $0.problem == .displayNameControlCharacter },
                    "expected control rejection for \(bad.unicodeScalars.map { String(format: "%04x", $0.value) })")
        }
        // Foundation's control set (unchanged contract) additionally contains
        // format characters like ZWSP (U+200B) and BOM (U+FEFF): those are
        // rejected exactly as before, while separators/NBSP are not.
        for rejected in ["a\u{200B}b", "a\u{FEFF}b"] {
            let issues = ProviderConfigurationValidation.issues(for: validProfile(name: rejected))
            #expect(issues.contains { $0.problem == .displayNameControlCharacter },
                    "expected control rejection for \(rejected.unicodeScalars.map { String(format: "%04x", $0.value) })")
        }
        for accepted in ["a\u{2028}b", "a\u{00A0}b"] {
            let issues = ProviderConfigurationValidation.issues(for: validProfile(name: accepted))
            #expect(issues.isEmpty, "unexpected rejection \(accepted.unicodeScalars.map { String(format: "%04x", $0.value) })")
        }
    }

    @Test("Pasted names normalize before freezing without losing Unicode content")
    func pastedNameCompatibility() throws {
        for (raw, expected) in [
            ("\u{FEFF}OpenAI\u{200B}\nChat\tCompletions\u{202E}", "OpenAI Chat Completions"),
            ("  公司\r\n网关  ", "公司 网关"),
            ("👩‍💻 公司 e\u{301} 网关", "👩‍💻 公司 e\u{301} 网关"),
            ("a\u{200C}b", "a\u{200C}b")
        ] {
            let request = try requireRequest(makeDraft(name: raw))
            #expect(request.profile.displayName == expected)
            try request.profile.validate()
            #expect(ProviderConfigurationValidation.normalizedDisplayName(expected) == expected)
        }
        #expect(try requireRequest(makeDraft(name: "\u{FEFF}\u{200B}\t")).profile.displayName == nil)
        let oversized = String(repeating: "深", count: 85) + "xx"
        guard case .failure(let report) = makeDraft(name: "\u{200B}" + oversized).makeRequest() else {
            Issue.record("Normalized 257-byte name must still fail"); return
        }
        #expect(report.primary?.problem == .displayNameTooLong)
        #expect(report.primary?.arguments.last == "257")
    }

    @Test("Provider names and remote model IDs preserve dashes underscores and version dots")
    func punctuationCompatibility() throws {
        for id in ["qwen3.5-plus", "model_v2.1", "deepseek-v4-flash", "gpt-4.1-mini", "Qwen3.5-27B_Instruct"] {
            let model = ModelProfile(providerID: UUID(), remoteModelID: id, displayName: id,
                limits: .init(contextTokens: 128_000, maxOutputTokens: 4096))
            let request = try requireRequest(makeDraft(name: id, models: [model]))
            #expect(request.profile.displayName == id)
            #expect(request.selectedModels.first?.remoteModelID == id)
            #expect(request.selectedModels.first?.displayName == id)
        }
    }

    @Test("Validation messages are bilingual and never alter the rejected value")
    func bilingualMessages() {
        let issue = ProviderConfigurationIssue(
            field: .displayName,
            problem: .displayNameTooLong,
            messageKey: "providers.validation.display_name_rules",
            arguments: ["256", "257"]
        )
        let en = ProviderConfigurationValidation.message(for: issue, language: .english)
        let zh = ProviderConfigurationValidation.message(for: issue, language: .chinese)
        #expect(en.contains("257"))
        #expect(en.contains("256"))
        #expect(zh.contains("257"))
        #expect(zh.contains("256"))
        // Empty report must not trap.
        #expect(ProviderConfigurationValidationReport(issues: []).primary == nil)
    }

    @Test("Model validation mirrors the persistence codec rules")
    func modelValidationParity() {
        let good = ModelProfile(
            providerID: UUID(),
            remoteModelID: "gpt-x",
            displayName: "GPT X",
            limits: .init(contextTokens: 100, maxOutputTokens: 50)
        )
        #expect(ProviderConfigurationValidation.issues(for: good).isEmpty)
        let emptyID = ModelProfile(
            providerID: UUID(), remoteModelID: "   ", displayName: "X",
            limits: .init(contextTokens: 100, maxOutputTokens: 0)
        )
        #expect(ProviderConfigurationValidation.issues(for: emptyID).contains {
            $0.problem == .modelRemoteIDEmpty
        })
        let emptyName = ModelProfile(
            providerID: UUID(), remoteModelID: "m", displayName: "\n",
            limits: .init(contextTokens: 100, maxOutputTokens: 0)
        )
        #expect(ProviderConfigurationValidation.issues(for: emptyName).contains {
            $0.problem == .modelDisplayNameEmpty
        })
        let badLimits = ModelProfile(
            providerID: UUID(), remoteModelID: "m", displayName: "M",
            limits: .init(contextTokens: 0, maxOutputTokens: -1)
        )
        #expect(ProviderConfigurationValidation.issues(for: badLimits).contains {
            $0.problem == .modelLimitsInvalid
        })
        let outputOverContext = ModelProfile(
            providerID: UUID(), remoteModelID: "m", displayName: "M",
            limits: .init(contextTokens: 100, maxOutputTokens: 101)
        )
        #expect(ProviderConfigurationValidation.issues(for: outputOverContext).contains {
            $0.problem == .modelOutputExceedsContext
        })
    }

    // MARK: - Frozen save draft / runner

    private func makeDraft(
        providerID: UUID = UUID(),
        name: String = "DeepSeek",
        key: String = "",
        existing: ProviderProfile? = nil,
        models: [ModelProfile] = [],
        defaultModelID: UUID? = nil,
        syncEnabled: Bool? = nil
    ) -> ProviderSaveDraft {
        // Mirrors the editor: a fresh draft carries the catalog preset id and
        // the default sync toggle; editing an existing provider preserves its
        // stored preset identity and its secret-sync preference.
        let resolvedPresetID: String? = existing == nil ? "deepseek" : existing?.presetID
        return ProviderSaveDraft(
            providerID: existing?.id ?? providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURLString: "  https://api.deepseek.com  ",
            displayName: name,
            presetID: resolvedPresetID,
            existingSecretRef: existing?.secretRef,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            toolNameCompatibility: true,
            syncEnabled: syncEnabled ?? existing?.secretRef?.synchronizable ?? true,
            enteredAPIKey: key,
            selectedModels: models,
            managedCapabilities: .text,
            serviceRoleIsConversation: true,
            defaultModelID: defaultModelID,
            existingCreatedAt: existing?.createdAt,
            existingSyncRevision: existing?.syncRevision ?? 0,
            region: existing?.region
        )
    }

    @Test("Editing a provider preserves its saved region")
    func frozenDraftPreservesRegion() throws {
        let existing = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!, region: "saved-region")
        let request = try requireRequest(makeDraft(existing: existing))
        #expect(request.profile.region == "saved-region")
    }

    private func requireRequest(_ draft: ProviderSaveDraft) throws -> ProviderSaveRequest {
        switch draft.makeRequest() {
        case .success(let request): return request
        case .failure(let report):
            Issue.record("unexpected validation issues: \(report.issues.map(\.problem.rawValue))")
            throw report
        }
    }

    @Test("Draft freezes normalized names, trimmed URL, key and preset identity")
    func draftFreezesCanonicalContent() throws {
        let request = try requireRequest(makeDraft(name: "  DeepSeek  ", key: " sk-1 "))
        #expect(request.profile.displayName == "DeepSeek")
        #expect(request.profile.baseURL.absoluteString == "https://api.deepseek.com")
        #expect(request.apiKey == "sk-1")
        #expect(request.profile.presetID == "deepseek")
        #expect(request.profile.secretRef?.keychainAccount != nil)
    }

    @Test("Blank draft name persists nil while keeping the existing preset identity")
    func draftBlankNameKeepsFallback() throws {
        let legacy = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!,
            secretRef: SecretReference(keychainAccount: "provider.legacy", synchronizable: false)
        )
        let request = try requireRequest(makeDraft(name: "   ", existing: legacy))
        #expect(request.profile.displayName == nil)
        #expect(request.profile.presetID == nil)
        #expect(request.profile.secretRef?.keychainAccount == "provider.legacy")
        #expect(request.profile.secretRef?.synchronizable == false)
        #expect(request.apiKey == nil)
    }

    @Test("Invalid draft reports field issues and cannot produce a request")
    func invalidDraftIsGate() {
        let result = makeDraft(name: String(repeating: "中", count: 86)).makeRequest()
        guard case .failure(let report) = result else {
            Issue.record("expected failure"); return
        }
        #expect(report.issues.contains { $0.field == .displayName })
    }

    private final class RecordingSecretStore: ProviderSecretSaving, @unchecked Sendable {
        var syncChanges: [(Bool, UUID)] = []
        var secrets: [(Data, UUID)] = []
        var syncError: Error?
        var secretError: Error?

        func setSyncEnabled(_ enabled: Bool, for providerID: UUID) async throws {
            syncChanges.append((enabled, providerID))
            if let syncError { throw syncError }
        }
        func storeSecret(_ secret: Data, scopeProviderID: UUID) async throws {
            secrets.append((secret, scopeProviderID))
            if let secretError { throw secretError }
        }
    }

    private final class RecordingCommitter: ProviderBundleCommitting, @unchecked Sendable {
        var committed: [ProviderSaveRequest] = []
        var verified: [ProviderSaveRequest] = []
        var delay: Duration?
        var commitError: Error?
        var readbackFailure: String?
        var syncPending = false
        var syncError: String?

        func commitProviderBundle(_ request: ProviderSaveRequest) async throws -> ProviderBundleCommitResult {
            if let delay { try? await Task.sleep(for: delay) }
            committed.append(request)
            if let commitError { throw commitError }
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

    @Test("Invalid preflight causes zero secret/sync/db calls")
    func invalidPreflightZeroSideEffects() async throws {
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        // An invalid request can never be constructed, so the runner cannot be
        // invoked. Prove the gate plus untouched gateways together.
        guard case .failure = makeDraft(name: "bad\0name").makeRequest() else {
            Issue.record("expected invalid draft"); return
        }
        #expect(secrets.syncChanges.isEmpty)
        #expect(secrets.secrets.isEmpty)
        #expect(committer.committed.isEmpty)
        // A valid run on the same gateways still works.
        let request = try requireRequest(makeDraft(name: "DeepSeek"))
        try await runner.run(request)
        #expect(committer.committed.count == 1)
    }

    @Test("Edits arriving during the commit await cannot change the frozen snapshot")
    func editsDuringSaveUseFrozenSnapshot() async throws {
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        committer.delay = .milliseconds(50)
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)

        let first = try requireRequest(makeDraft(name: "Original Name", key: "sk-first"))
        // Simulate the user editing fields while the save is in flight: a
        // second draft produces a different request.
        let edited = try requireRequest(makeDraft(name: "Edited During Await", key: "sk-second"))
        #expect(first != edited)

        async let runTask = runner.run(first)
        try await Task.sleep(for: .milliseconds(5))
        // The "later edit" is never handed to the running save.
        let result = try await runTask
        guard case .committed(let models, let syncPending, _) = result else {
            Issue.record("expected commit"); return
        }
        #expect(models.map(\.remoteModelID) == [])
        #expect(syncPending == false)

        #expect(committer.committed.count == 1)
        #expect(committer.committed.first?.profile.displayName == "Original Name")
        #expect(committer.committed.first?.apiKey == "sk-first")
        #expect(committer.verified.first?.profile.displayName == "Original Name")
        #expect(secrets.secrets.first?.0 == Data("sk-first".utf8))
        #expect(secrets.secrets.count == 1)
    }

    @Test("A directly constructed invalid request performs zero writes")
    func directInvalidRequestZeroWrites() async throws {
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        // Bypass the draft factory via the internal initializer: the runner
        // must still reject the content before any side effect.
        let providerID = UUID()
        let profile = ProviderProfile(
            id: providerID,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!,
            displayName: String(repeating: "x", count: 300)
        )
        let illegal = ProviderSaveRequest(
            profile: profile,
            selectedModels: [],
            apiKey: "sk-should-never-be-written",
            syncEnabled: true,
            managedCapabilities: .text,
            serviceRoleIsConversation: true,
            defaultModelIntent: .automatic,
            providerEnabled: true
        )
        do {
            _ = try await runner.run(illegal)
            Issue.record("expected invalidRequest")
        } catch let error as ProviderSaveRunError {
            guard case .invalidRequest(let problems) = error else {
                Issue.record("unexpected phase \(error.phase)"); return
            }
            #expect(problems.contains { $0 == .displayNameTooLong })
        }
        #expect(secrets.syncChanges.isEmpty)
        #expect(secrets.secrets.isEmpty)
        #expect(committer.committed.isEmpty)
        #expect(committer.verified.isEmpty)
    }

    @Test("A concurrent save for the same provider is rejected, not interleaved")
    func concurrentSaveRejected() async throws {
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        committer.delay = .milliseconds(120)
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        let request = try requireRequest(makeDraft(name: "DeepSeek", key: "sk"))
        async let first = runner.run(request)
        try await Task.sleep(for: .milliseconds(10))
        do {
            _ = try await runner.run(request)
            Issue.record("expected concurrentSaveRejected")
        } catch let error as ProviderSaveRunError {
            guard case .concurrentSaveRejected = error else {
                Issue.record("unexpected phase \(error.phase)"); return
            }
        }
        _ = try await first
        // Exactly one credential write and one commit happened.
        #expect(secrets.secrets.count == 1)
        #expect(committer.committed.count == 1)
    }

    @Test("Frozen sync preference survives a provider with no secret")
    func frozenSyncEnabledWithoutSecret() async throws {
        let existing = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.deepseek.com")!,
            secretRef: nil
        )
        let draft = makeDraft(name: "DeepSeek", existing: existing, syncEnabled: false)
        let request = try requireRequest(draft)
        #expect(request.syncEnabled == false)
        #expect(request.profile.secretRef == nil)
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        _ = try await runner.run(request)
        #expect(secrets.syncChanges.count == 1)
        #expect(secrets.syncChanges.first?.0 == false)
        #expect(secrets.secrets.isEmpty)
    }

    @Test("A local commit with pending sync is reported as success, not failure")
    func syncPendingPropagation() async throws {
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        committer.syncPending = true
        committer.syncError = "iCloud unavailable"
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        let request = try requireRequest(makeDraft(name: "DeepSeek"))
        let result = try await runner.run(request)
        guard case .committed(_, let syncPending, let syncError) = result else {
            Issue.record("expected commit"); return
        }
        #expect(syncPending == true)
        #expect(syncError == "iCloud unavailable")
        #expect(committer.verified.count == 1)
    }

    @Test("Credential failure is phased and never reaches the local commit")
    func credentialFailurePhasing() async throws {
        let secrets = RecordingSecretStore()
        secrets.secretError = FloeError.internalError("keychain unavailable")
        let committer = RecordingCommitter()
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        let request = try requireRequest(makeDraft(name: "DeepSeek", key: "sk"))
        await #expect(throws: ProviderSaveRunError.self) { try await runner.run(request) }
        #expect(committer.committed.isEmpty)
        #expect(committer.verified.isEmpty)
    }

    @Test("Readback mismatch is reported as a distinct phase")
    func readbackMismatchPhasing() async throws {
        let secrets = RecordingSecretStore()
        let committer = RecordingCommitter()
        committer.readbackFailure = "mismatch"
        let runner = ProviderSaveRunner(secretStore: secrets, committer: committer)
        let request = try requireRequest(makeDraft(name: "DeepSeek"))
        do {
            _ = try await runner.run(request)
            Issue.record("expected readback failure")
        } catch let error as ProviderSaveRunError {
            guard case .readbackMismatch = error else { Issue.record("wrong phase \(error)"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("Chosen default-model intent is captured by stable remote identifier")
    func defaultModelIntentFreeze() throws {
        let providerID = UUID()
        let model = ModelProfile(
            providerID: providerID, remoteModelID: "deepseek-chat", displayName: "DeepSeek Chat",
            limits: .init(contextTokens: 100, maxOutputTokens: 10)
        )
        let draft = makeDraft(providerID: providerID, models: [model], defaultModelID: model.id)
        let request = try requireRequest(draft)
        guard case .chosen(let remoteID) = request.defaultModelIntent else {
            Issue.record("expected chosen intent"); return
        }
        #expect(remoteID == "deepseek-chat")
    }
}

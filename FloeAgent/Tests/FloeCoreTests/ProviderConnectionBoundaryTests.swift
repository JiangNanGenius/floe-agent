// FloeCoreTests — Provider connection boundary: what a stored credential may
// be silently reused for, and the form-state rules for selecting a preset or
// catalog entry. Pure host tests; no credentials or side effects.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.ProviderConnectionBoundary")
struct ProviderConnectionBoundaryTests {

    private func key(_ kind: ProviderKind, _ url: String) throws -> ProviderConfigurationValidation.ProviderConnectionIdentity.Key {
        try #require(
            ProviderConfigurationValidation.ProviderConnectionIdentity.key(
                kind: kind,
                baseURL: URL(string: url)!
            )
        )
    }

    @Test("Same origin, port, scheme and provider family are compatible across path/alias changes")
    func sameConnectionStaysCompatible() throws {
        #expect(
            ProviderConfigurationValidation.ProviderConnectionIdentity.isCompatible(
                from: .openAI,
                oldBaseURL: URL(string: "https://api.openai.com/v1")!,
                to: .openAI,
                newBaseURL: URL(string: "https://api.openai.com/v1/images")!
            )
        )
        // Trailing-dot host and case differences are the same connection.
        #expect(
            try key(.custom, "https://API.Example.com/v1")
                == key(.custom, "https://api.example.com/openai/v1")
        )
    }

    @Test("Different port, scheme or provider family are incompatible")
    func incompatibleConnectionsAreDetected() throws {
        #expect(
            try key(.openAI, "https://api.example.com/v1")
                != key(.openAI, "https://api.example.com:8443/v1")
        )
        #expect(
            try key(.openAI, "https://api.example.com/v1")
                != key(.openAI, "http://api.example.com/v1")
        )
        // Same host, different provider routing/auth family.
        #expect(
            try key(.custom, "https://api.example.com/v1")
                != key(.openAI, "https://api.example.com/v1")
        )
        #expect(
            !ProviderConfigurationValidation.ProviderConnectionIdentity.isCompatible(
                from: .custom,
                oldBaseURL: URL(string: "https://gateway.example.com/v1")!,
                to: .openAI,
                newBaseURL: URL(string: "https://gateway.example.com/v1")!
            )
        )
    }

    @Test("Auth style follows the provider family")
    func authStyleFollowsKind() {
        let identity = ProviderConfigurationValidation.ProviderConnectionIdentity.self
        #expect(identity.authStyle(for: .anthropic) == "apiKeyHeader")
        #expect(identity.authStyle(for: .googleGemini) == "apiKeyHeader")
        #expect(identity.authStyle(for: .local) == "none")
        #expect(identity.authStyle(for: .openAI) == "bearer")
        #expect(identity.authStyle(for: .custom) == "bearer")
    }

    // MARK: - Save draft credential boundary

    private func draft(
        existingBaseURL: URL?,
        existingKind: ProviderKind?,
        existingSecretRef: SecretReference?,
        enteredAPIKey: String,
        kind: ProviderKind = .custom,
        baseURLString: String = "https://api.example.com/v1",
        displayName: String = "Gateway"
    ) -> ProviderSaveDraft {
        ProviderSaveDraft(
            providerID: UUID(),
            kind: kind,
            wireProtocol: .openAIChatCompletions,
            baseURLString: baseURLString,
            displayName: displayName,
            presetID: "gateway",
            existingSecretRef: existingSecretRef,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            toolNameCompatibility: false,
            syncEnabled: true,
            enteredAPIKey: enteredAPIKey,
            selectedModels: [],
            managedCapabilities: .text,
            serviceRoleIsConversation: true,
            defaultModelID: nil,
            existingCreatedAt: nil,
            existingSyncRevision: 0,
            existingBaseURL: existingBaseURL,
            existingKind: existingKind
        )
    }

    private var storedSecret: SecretReference {
        SecretReference(keychainAccount: "provider.test", synchronizable: true)
    }

    @Test("Same connection keeps the stored credential without re-entry")
    func sameConnectionKeepsStoredCredential() {
        let result = draft(
            existingBaseURL: URL(string: "https://api.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: storedSecret,
            enteredAPIKey: "",
            baseURLString: "https://api.example.com/openai/v1"
        ).makeRequest()
        switch result {
        case .success(let request):
            #expect(request.profile.secretRef?.keychainAccount == "provider.test")
        case .failure(let report):
            Issue.record("same-connection path change must stay valid: \(report.issues)")
        }
    }

    @Test("A changed connection requires a fresh key before any side effect")
    func changedConnectionRequiresNewKey() {
        func expectRejected(
            _ draft: ProviderSaveDraft,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            switch draft.makeRequest() {
            case .success:
                Issue.record("expected credential-boundary rejection", sourceLocation: sourceLocation)
            case .failure(let report):
                let issue = report.issues.first
                #expect(
                    issue?.problem == .connectionChangedRequiresNewCredential,
                    "\(String(describing: issue))",
                    sourceLocation: sourceLocation
                )
                #expect(
                    issue?.messageKey == "providers.validation.connection_changed_requires_key",
                    sourceLocation: sourceLocation
                )
            }
        }

        // Different port.
        expectRejected(draft(
            existingBaseURL: URL(string: "https://api.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: storedSecret,
            enteredAPIKey: "",
            baseURLString: "https://api.example.com:8443/v1"
        ))
        // Different scheme.
        expectRejected(draft(
            existingBaseURL: URL(string: "https://api.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: storedSecret,
            enteredAPIKey: "",
            baseURLString: "http://api.example.com/v1"
        ))
        // Same host, different provider/auth family.
        expectRejected(draft(
            existingBaseURL: URL(string: "https://api.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: storedSecret,
            enteredAPIKey: "",
            kind: .openAI
        ))
        // Different host.
        expectRejected(draft(
            existingBaseURL: URL(string: "https://old.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: storedSecret,
            enteredAPIKey: "",
            baseURLString: "https://new.example.com/v1"
        ))
    }

    @Test("A new entered key or no stored credential makes the change valid")
    func newKeyOrNoSecretSkipsBoundary() {
        // Fresh key: allowed to move the connection.
        let withKey = draft(
            existingBaseURL: URL(string: "https://old.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: storedSecret,
            enteredAPIKey: "fixture-key",
            baseURLString: "https://new.example.com/v1"
        ).makeRequest()
        guard case .success = withKey else {
            Issue.record("a newly entered key must pass the boundary")
            return
        }
        // No stored credential: nothing to leak.
        let noSecret = draft(
            existingBaseURL: URL(string: "https://old.example.com/v1")!,
            existingKind: .custom,
            existingSecretRef: nil,
            enteredAPIKey: "",
            baseURLString: "https://new.example.com/v1"
        ).makeRequest()
        guard case .success = noSecret else {
            Issue.record("a provider without a stored secret must keep saving")
            return
        }
        // Legacy callers without the existing identity are never blocked.
        let legacy = draft(
            existingBaseURL: URL(string: "https://old.example.com/v1")!,
            existingKind: nil,
            existingSecretRef: storedSecret,
            enteredAPIKey: "",
            baseURLString: "https://new.example.com/v1"
        ).makeRequest()
        guard case .success = legacy else {
            Issue.record("missing legacy identity must not block saving")
            return
        }
    }

    // MARK: - Selection field policy

    @Test("A custom display name survives preset and catalog selection")
    func customDisplayNameSurvivesSelection() {
        let policy = ProviderConfigurationValidation.ProviderSelectionFieldPolicy.self
        #expect(!policy.shouldReplaceDisplayName(
            current: "公司网关",
            previousDefault: "Custom Compatible Endpoint"
        ))
        #expect(!policy.shouldReplaceDisplayName(
            current: "DeepSeek",
            previousDefault: "Custom Compatible Endpoint"
        ))
        #expect(policy.shouldReplaceDisplayName(
            current: "Custom Compatible Endpoint",
            previousDefault: "Custom Compatible Endpoint"
        ))
        #expect(policy.shouldReplaceDisplayName(
            current: "  ",
            previousDefault: "OpenAI"
        ))
        #expect(policy.shouldReplaceDisplayName(
            current: "",
            previousDefault: "OpenAI"
        ))
    }
}

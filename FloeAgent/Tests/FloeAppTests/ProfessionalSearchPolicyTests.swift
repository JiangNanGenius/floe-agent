// FloeAppTests — professional/public search readiness composition.
// Local accounts and UserDefaults suites only; no keychain/network fixtures.

import Foundation
import Testing
import FloeExecution
import FloeModels
import FloeAgentRuntime
@testable import FloeTools
@testable import FloeApp

@Suite("FloeApp.ProfessionalSearchPolicy", .serialized)
struct ProfessionalSearchPolicyTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "Floe.ProfessionalSearchPolicy.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func descriptors() -> [ToolCatalog.Descriptor] {
        ["web.search", "web.searchAI", "web.fetch", "notes.read"].map {
            ToolCatalog.Descriptor(
                name: $0,
                riskLabels: $0 == "notes.read" ? [.readsFiles] : [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            )
        }
    }

    private func register(
        _ registry: ToolRunnerRegistry,
        id: UUID = UUID(),
        name: String = "Volcengine DataPro"
    ) -> ProfessionalSearchAuthority.Account {
        ProfessionalSearchAuthority.register(
            serverID: id, displayName: name, registry: registry
        ) { _, _ in
            ToolExecutionOutput(summary: "{}", fullOutputSHA256: "")
        }
    }

    @Test("Professional-only setup is ordinary-ready but not temporary/fast-chat-ready")
    func professionalOnlyReadiness() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ToolRunnerRegistry()
        let account = register(registry)
        #expect(WebSearchSettingsCenter.toolIsAvailable(
            "web.search", defaults: defaults, cloudData: { _ in nil },
            professionalRegistry: registry
        ))
        #expect(!WebSearchSettingsCenter.publicWebToolIsAvailable(
            "web.search", defaults: defaults, cloudData: { _ in nil }
        ))
        let publicAvailability: (String) -> Bool = {
            WebSearchSettingsCenter.publicWebToolIsAvailable(
                $0, defaults: defaults, cloudData: { _ in nil }
            )
        }
        #expect(ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: descriptors(), webSearchAvailable: publicAvailability
        ) == ["web.fetch"])
        #expect(ConversationCenter.chatToolCeiling(
            offeredDescriptors: descriptors(), hasResourceContext: false,
            webSearchAvailable: publicAvailability
        ) == ["web.fetch"])
        let frozen = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: ["web.search"]
        )
        #expect(frozen.accounts == [account])
        let note = WebSearchSettingsCenter.runtimeProviderNote(
            defaults: defaults, cloudData: { _ in nil },
            frozenProfessionalAccounts: frozen.accounts
        )
        #expect(note?.contains("source=professional") == true)
        #expect(note?.contains("No public web search provider") == true)
        #expect(WebSearchSettingsCenter.runtimeProviderNote(
            defaults: defaults, cloudData: { _ in nil },
            frozenProfessionalAccounts: []
        ) == nil)
    }

    @Test("Public-provider-only readiness keeps the ordinary and restricted web source")
    func publicProviderReadiness() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([
            WebSearchProviderInstance(configuration: WebSearchProviderConfiguration(
                kind: .searxng,
                displayName: "Test SearXNG",
                endpoint: URL(string: "https://searx.example.org")!,
                credentialAccount: "web-search.searxng",
                enabled: true,
                priority: 0
            ), presetID: nil, appliedCatalogVersion: nil)
        ]), forKey: WebSearchSettingsCenter.instancesKey)
        let registry = ToolRunnerRegistry()
        #expect(WebSearchSettingsCenter.toolIsAvailable(
            "web.search", defaults: defaults, cloudData: { _ in nil },
            professionalRegistry: registry
        ))
        #expect(WebSearchSettingsCenter.publicWebToolIsAvailable(
            "web.search", defaults: defaults, cloudData: { _ in nil }
        ))
        let publicAvailability: (String) -> Bool = {
            WebSearchSettingsCenter.publicWebToolIsAvailable(
                $0, defaults: defaults, cloudData: { _ in nil }
            )
        }
        #expect(ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: descriptors(), webSearchAvailable: publicAvailability
        ) == ["web.search", "web.fetch"])
        #expect(ConversationCenter.chatToolCeiling(
            offeredDescriptors: descriptors(), hasResourceContext: false,
            webSearchAvailable: publicAvailability
        ) == ["web.search", "web.fetch"])
        let note = WebSearchSettingsCenter.runtimeProviderNote(
            defaults: defaults, cloudData: { _ in nil },
            frozenProfessionalAccounts: []
        )
        #expect(note?.contains("Test SearXNG") == true)
        #expect(note?.contains("source=professional") == false)
    }

    @Test("Restricted run surfaces and explicit task limits deny native professional authority")
    func runSurfaceAndTaskPolicyEligibility() {
        let policy = TaskPolicy(conversationID: UUID())
        func eligible(
            surface: AgentRunSurface = .ordinary,
            notes: Bool = false,
            temporary: Bool = false,
            fast: Bool = false,
            mode: ConversationMode = .goal,
            tools: Bool = true,
            local: Bool = false,
            taskPolicy taskPolicyOverride: TaskPolicy? = nil
        ) -> Bool {
            ConversationCenter.allowsNativeProfessionalSearch(
                runSurface: surface, isNotesAssistant: notes,
                isTemporary: temporary, chatFastMode: fast,
                conversationMode: mode, toolsEnabled: tools,
                isLocalProvider: local, taskPolicy: taskPolicyOverride ?? policy
            )
        }
        #expect(eligible())
        #expect(!eligible(surface: .canvas))
        #expect(!eligible(notes: true))
        #expect(!eligible(temporary: true))
        #expect(!eligible(fast: true))
        #expect(!eligible(mode: .plan))
        #expect(!eligible(tools: false))
        #expect(!eligible(local: true))
        var noNetwork = policy
        noNetwork.networkAllowed = false
        #expect(!eligible(taskPolicy: noNetwork))
        var noRemote = policy
        noRemote.remoteExecutionAllowed = false
        #expect(!eligible(taskPolicy: noRemote))
        var readOnly = policy
        readOnly.approvalMode = "readOnly"
        // The reviewed native query is intentionally a read, not the retired
        // mutating facade; an ordinary read-only task may therefore use it.
        #expect(eligible(taskPolicy: readOnly))
    }

    @Test("Search without a usable source is removed without widening the final ceiling")
    func unusableSearchIsPruned() {
        let offered: Set<String> = ["web.search", "web.fetch", "notes.read"]
        #expect(ConversationCenter.pruneUnavailableSearch(
            allowedToolNames: nil, offeredToolNames: offered,
            publicWebReady: false, professionalAccounts: []
        ) == ["web.fetch", "notes.read"])
        #expect(ConversationCenter.pruneUnavailableSearch(
            allowedToolNames: ["web.search", "web.fetch"], offeredToolNames: offered,
            publicWebReady: false, professionalAccounts: []
        ) == ["web.fetch"])
        #expect(ConversationCenter.pruneUnavailableSearch(
            allowedToolNames: ["web.fetch"], offeredToolNames: offered,
            publicWebReady: true, professionalAccounts: []
        ) == ["web.fetch"])
        let registry = ToolRunnerRegistry()
        let account = register(registry)
        #expect(ConversationCenter.pruneUnavailableSearch(
            allowedToolNames: ["web.search"], offeredToolNames: offered,
            publicWebReady: false, professionalAccounts: [account]
        ) == ["web.search"])
    }

    @Test("Runtime notes use frozen accounts, never live replacements or restricted registries")
    func providerNotesUseFrozenAccounts() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ToolRunnerRegistry()
        let id = UUID()
        let original = register(registry, id: id, name: "Original")
        let frozen = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: ["web.search"]
        )
        _ = register(registry, id: id, name: "Replacement")
        _ = register(registry, name: "New Account")
        let note = WebSearchSettingsCenter.runtimeProviderNote(
            defaults: defaults, cloudData: { _ in nil },
            professionalRegistry: registry,
            frozenProfessionalAccounts: frozen.accounts
        )
        #expect(note?.contains("Original") == true)
        #expect(note?.contains(id.uuidString) == true)
        #expect(note?.contains("Replacement") == false)
        #expect(note?.contains("New Account") == false)
        #expect(frozen.accounts == [original])
        let restrictedNote = WebSearchSettingsCenter.runtimeProviderNote(
            defaults: defaults, cloudData: { _ in nil },
            professionalRegistry: registry,
            frozenProfessionalAccounts: []
        )
        #expect(restrictedNote == nil)
    }
}

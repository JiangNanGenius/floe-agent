// FloeAgent — focused Volcengine settings and DataPro lifecycle tests.
//
// These tests use the REAL WebSearchSettingsCenter and the REAL
// VolcengineSettingsDraft/VolcengineDataProPlan mappings. Only the network
// stores are synthetic: an in-memory cloud store, an in-memory credential
// store and a feature-local MCP manager. The shared MCPSettingsCenter, the
// developer's iCloud defaults and the Keychain are never activated.
import XCTest
import Foundation
@testable import FloeExecution
import FloeTools
@testable import FloeApp

@MainActor
final class VolcengineSearchSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cloud: FakeWebSearchCloud!
    private var credentials: MemoryWebSearchCredentials!
    private var dataPro: FakeDataProManager!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "org.floeagent.tests.volcengine.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cloud = FakeWebSearchCloud()
        credentials = MemoryWebSearchCredentials()
        dataPro = FakeDataProManager()
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        cloud = nil
        credentials = nil
        dataPro = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeCenter() -> WebSearchSettingsCenter {
        WebSearchSettingsCenter(
            defaults: defaults,
            cloud: cloud,
            credentialStore: credentials.store,
            dataProManager: dataPro
        )
    }

    private func volcengineConfiguration(
        interface: VolcengineSearchInterface?,
        endpoint: URL? = nil,
        enabled: Bool = true,
        options: [String: String] = [:],
        id: UUID = UUID(),
        credentialAccount: String? = nil
    ) -> WebSearchProviderConfiguration {
        var values = options
        if let interface {
            values[VolcengineSearchOptions.Key.interface] = interface.rawValue
        }
        return WebSearchProviderConfiguration(
            id: id,
            kind: .volcengine,
            displayName: "Volcengine",
            endpoint: endpoint,
            credentialAccount: credentialAccount
                ?? defaultCredentialAccount(for: interface, providerID: id),
            enabled: enabled,
            priority: 2,
            options: values
        )
    }

    private func defaultCredentialAccount(
        for interface: VolcengineSearchInterface?,
        providerID: UUID
    ) -> String {
        switch interface {
        case .agentPlan, .arkResponses, .doubaoSearch:
            VolcengineSettingsDraft.perProviderCredentialAccount(
                for: providerID,
                interface: interface!
            )
        case nil:
            VolcengineSettingsDraft.legacyCredentialAccount
        }
    }

    // MARK: - Preset / legacy compatibility

    func testPresetsDefaultToAgentPlanButStayDisabled() throws {
        let center = makeCenter()
        let volcengine = try XCTUnwrap(center.providers.first { $0.kind == .volcengine })
        XCTAssertFalse(volcengine.enabled)
        XCTAssertEqual(
            volcengine.credentialAccount,
            VolcengineSettingsDraft.perProviderCredentialAccount(
                for: volcengine.id,
                interface: .agentPlan
            )
        )
        XCTAssertNotEqual(
            volcengine.credentialAccount,
            VolcengineSettingsDraft.agentPlanCredentialAccount
        )
        XCTAssertEqual(
            volcengine.options[VolcengineSearchOptions.Key.interface],
            VolcengineSearchInterface.agentPlan.rawValue
        )
        // Existing ordering: Bocha stays first and Volcengine stays third.
        XCTAssertEqual(center.providers.first?.kind, .bochaWeb)
        XCTAssertEqual(volcengine.priority, 2)
        XCTAssertEqual(center.providers.filter { $0.kind == .volcengine }.count, 1)
    }

    func testLegacyRecordWithoutInterfaceKeepsItsExactContract() throws {
        let legacyAccount = "web-search.volcengine.legacy-account-\(UUID().uuidString)"
        let legacy = volcengineConfiguration(
            interface: nil,
            endpoint: URL(string: "https://search.example.com/api"),
            credentialAccount: legacyAccount
        )
        var draft = try VolcengineSettingsDraft(configuration: legacy)
        XCTAssertEqual(draft.mode, .legacyCustom)
        let rebuilt = try draft.configuration()
        XCTAssertEqual(rebuilt.endpoint, legacy.endpoint)
        XCTAssertEqual(rebuilt.credentialAccount, legacyAccount)
        XCTAssertNil(rebuilt.options[VolcengineSearchOptions.Key.interface])
        let request = try WebSearchService.makeRequest(
            rebuilt,
            credential: WebSearchCredential(values: ["apiKey": "legacy-key"]),
            query: WebSearchQuery(text: "legacy")
        )
        XCTAssertEqual(request.url, legacy.endpoint)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["query"] as? String, "legacy")
        XCTAssertNil(body["Query"])

        // A nil-interface record without an endpoint is not promoted.
        let nilEndpoint = volcengineConfiguration(interface: nil, enabled: false)
        let nilDraft = try VolcengineSettingsDraft(configuration: nilEndpoint)
        XCTAssertEqual(nilDraft.mode, .legacyCustom)
        XCTAssertThrowsError(try nilDraft.configuration())
        XCTAssertFalse(WebSearchService.isConfigured(
            nilEndpoint,
            credential: WebSearchCredential(values: ["apiKey": "k"])
        ))
        // A malformed interface is surfaced, not silently treated as legacy.
        var malformed = legacy
        malformed.options[VolcengineSearchOptions.Key.interface] = "not-a-product"
        XCTAssertThrowsError(try VolcengineSettingsDraft(configuration: malformed))
    }

    func testTwoProviderIDsUseDistinctExplicitAccounts() throws {
        let first = volcengineConfiguration(interface: .agentPlan)
        let second = volcengineConfiguration(interface: .agentPlan)
        let firstDraft = try VolcengineSettingsDraft(configuration: first)
        let secondDraft = try VolcengineSettingsDraft(configuration: second)
        XCTAssertEqual(firstDraft.credentialAccount, first.credentialAccount)
        XCTAssertEqual(secondDraft.credentialAccount, second.credentialAccount)
        XCTAssertNotEqual(firstDraft.credentialAccount, secondDraft.credentialAccount)
        XCTAssertTrue(
            firstDraft.credentialAccount.contains(first.id.uuidString.lowercased())
        )
        XCTAssertTrue(
            secondDraft.credentialAccount.contains(second.id.uuidString.lowercased())
        )
        XCTAssertNotEqual(
            firstDraft.credentialAccount,
            VolcengineSettingsDraft.agentPlanCredentialAccount
        )
    }

    // MARK: - Per-interface credentials / persistence

    func testInterfaceSwitchKeepsOtherCredentialsAndPersists() throws {
        let center = makeCenter()
        let preset = try XCTUnwrap(center.providers.first { $0.kind == .volcengine })
        let legacyAccount = "web-search.volcengine.legacy-account-\(UUID().uuidString)"
        let legacy = volcengineConfiguration(
            interface: nil,
            endpoint: URL(string: "https://search.example.com/api"),
            id: preset.id,
            credentialAccount: legacyAccount
        )
        try center.upsert(
            legacy,
            credential: WebSearchCredential(values: ["apiKey": "legacy-key"])
        )
        XCTAssertEqual(
            center.credential(forAccount: legacyAccount)?.values["apiKey"],
            "legacy-key"
        )

        var draft = try VolcengineSettingsDraft(configuration: legacy)
        draft.mode = .agentPlan
        let agent = try draft.configuration()
        XCTAssertNil(agent.endpoint)
        XCTAssertEqual(
            agent.credentialAccount,
            VolcengineSettingsDraft.perProviderCredentialAccount(
                for: preset.id,
                interface: .agentPlan
            )
        )
        XCTAssertNotEqual(agent.credentialAccount, legacyAccount)
        try center.upsert(
            agent,
            credential: WebSearchCredential(values: ["apiKey": "agent-plan-key"])
        )

        // The legacy credential is not overwritten or deleted by the switch.
        XCTAssertEqual(
            center.credential(forAccount: legacyAccount)?.values["apiKey"],
            "legacy-key"
        )
        XCTAssertEqual(
            center.credential(forAccount: agent.credentialAccount)?.values["apiKey"],
            "agent-plan-key"
        )

        // Switching to Ark writes only the Ark account.
        var arkDraft = try VolcengineSettingsDraft(configuration: agent)
        arkDraft.mode = .arkResponses
        arkDraft.arkModel = "doubao-test-1"
        let ark = try arkDraft.configuration()
        XCTAssertEqual(
            ark.credentialAccount,
            VolcengineSettingsDraft.perProviderCredentialAccount(
                for: preset.id,
                interface: .arkResponses
            )
        )
        try center.upsert(
            ark,
            credential: WebSearchCredential(values: ["apiKey": "ark-key"])
        )
        XCTAssertEqual(
            center.credential(forAccount: agent.credentialAccount)?.values["apiKey"],
            "agent-plan-key"
        )
        XCTAssertEqual(
            center.credential(forAccount: ark.credentialAccount)?.values["apiKey"],
            "ark-key"
        )

        // A fresh center reconstructed from the same stores sees the saved
        // mode and all three credentials.
        let reloaded = makeCenter()
        let stored = try XCTUnwrap(reloaded.providers.first { $0.kind == .volcengine })
        let storedDraft = try VolcengineSettingsDraft(configuration: stored)
        XCTAssertEqual(storedDraft.mode, .arkResponses)
        XCTAssertEqual(storedDraft.arkModel, "doubao-test-1")
        XCTAssertEqual(
            reloaded.credential(forAccount: legacyAccount)?.values["apiKey"],
            "legacy-key"
        )
        XCTAssertEqual(
            reloaded.credential(forAccount: agent.credentialAccount)?.values["apiKey"],
            "agent-plan-key"
        )
        XCTAssertEqual(
            reloaded.credential(forAccount: ark.credentialAccount)?.values["apiKey"],
            "ark-key"
        )
        XCTAssertEqual(reloaded.providers.filter { $0.kind == .volcengine }.count, 1)
    }

    func testEditingOneDraftDoesNotOverwriteAnotherInterfaceCredential() throws {
        let center = makeCenter()
        let agent = volcengineConfiguration(interface: .agentPlan)
        try center.upsert(
            agent,
            credential: WebSearchCredential(values: ["apiKey": "agent-plan-key"])
        )
        var edited = try VolcengineSettingsDraft(configuration: agent)
        edited.mode = .doubaoSearch
        edited.queryRewrite = true
        // Deliberately do not save the edited draft (Cancel semantics).
        XCTAssertEqual(
            center.credential(forAccount: agent.credentialAccount)?.values["apiKey"],
            "agent-plan-key"
        )
        XCTAssertNil(center.credential(
            forAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                for: agent.id,
                interface: .doubaoSearch
            )
        ))
        let reopened = try VolcengineSettingsDraft(configuration: agent)
        XCTAssertEqual(reopened.mode, .agentPlan)
        XCTAssertEqual(
            center.credential(forAccount: reopened.credentialAccount)?.values["apiKey"],
            "agent-plan-key"
        )
    }

    func testKeychainWriteFailureDoesNotPublishEnabledConfiguration() throws {
        let center = makeCenter()
        let original = try XCTUnwrap(center.providers.first { $0.kind == .volcengine })
        var changed = original
        changed.options[VolcengineSearchOptions.Key.interface] =
            VolcengineSearchInterface.arkResponses.rawValue
        changed.credentialAccount = VolcengineSettingsDraft.perProviderCredentialAccount(
            for: original.id,
            interface: .arkResponses
        )
        changed.enabled = true

        credentials.failWrites = true
        XCTAssertThrowsError(
            try center.upsert(
                changed,
                credential: WebSearchCredential(values: ["apiKey": "ark-key"])
            )
        )
        let after = try XCTUnwrap(center.providers.first { $0.kind == .volcengine })
        XCTAssertEqual(after.credentialAccount, original.credentialAccount)
        XCTAssertEqual(
            after.options[VolcengineSearchOptions.Key.interface],
            original.options[VolcengineSearchOptions.Key.interface]
        )
        XCTAssertNil(center.credential(forAccount: changed.credentialAccount))

        // Enabled without any stored credential is rejected before Keychain
        // or provider state is touched.
        let enabledWithoutKey = volcengineConfiguration(interface: .doubaoSearch, enabled: true)
        XCTAssertThrowsError(
            try center.upsert(enabledWithoutKey, credential: nil)
        ) { error in
            XCTAssertEqual(error as? VolcengineSearchSettingsError, .missingCredential)
        }
        XCTAssertFalse(center.providers.contains { $0.credentialAccount == enabledWithoutKey.credentialAccount })
    }

    // MARK: - DataPro lifecycle

    func testDataProUsesOwnStableServerAndExistingLifecycle() async throws {
        let center = makeCenter()
        let providerID = UUID()
        let agent = WebSearchProviderConfiguration(
            id: providerID,
            kind: .volcengine,
            displayName: "Volcengine",
            credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(for: providerID, interface: .agentPlan),
            enabled: false,
            options: [
                VolcengineSearchOptions.Key.interface:
                    VolcengineSearchInterface.agentPlan.rawValue
            ]
        )
        let plan = try VolcengineDataProPlan.server(for: agent)
        XCTAssertEqual(plan.id, VolcengineDataProPlan.serverID(for: agent))
        XCTAssertEqual(plan.endpoint.absoluteString, "https://datapro.hqd.cn-beijing.volces.com/mcp")
        XCTAssertEqual(plan.authentication, .customHeader)
        XCTAssertEqual(plan.credentialHeaderName, "X-Agent-Plan-Key")
        XCTAssertTrue(plan.enabled)
        XCTAssertFalse(plan.allowInCanvas)

        try await center.setDataProEnabled(true, for: agent, credential: "agent-plan-key")
        XCTAssertEqual(dataPro.servers.count, 1)
        XCTAssertEqual(dataPro.servers[plan.id]?.id, plan.id)
        XCTAssertEqual(dataPro.lastCredential[plan.id] ?? nil, "agent-plan-key")
        XCTAssertEqual(dataPro.state(serverID: plan.id), .ready(2))

        // Re-enabling is idempotent: the same feature-owned ID, no duplicate.
        try await center.setDataProEnabled(true, for: agent, credential: "agent-plan-key")
        XCTAssertEqual(dataPro.servers.count, 1)
        XCTAssertEqual(dataPro.upsertCount, 2)

        // A refresh observes the real connection state seam.
        let refreshed = await center.refreshDataPro(for: agent)
        XCTAssertEqual(dataPro.refreshCount, 1)
        XCTAssertEqual(refreshed, .ready(3))

        // Disabling only touches this server.
        let unrelated = MCPServerConfiguration(
            displayName: "Other MCP",
            endpoint: URL(string: "https://mcp.example.com/mcp")!,
            enabled: true
        )
        dataPro.servers[unrelated.id] = unrelated
        try await center.setDataProEnabled(false, for: agent, credential: nil)
        XCTAssertEqual(dataPro.state(serverID: plan.id), .inactive)
        XCTAssertEqual(dataPro.servers[unrelated.id], unrelated)

        // The server identity survives a relaunch because it is derived from
        // the provider UUID (and persisted once saved).
        let sameID = WebSearchProviderConfiguration(
            id: providerID,
            kind: .volcengine,
            displayName: "Volcengine",
            credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                for: providerID,
                interface: .agentPlan
            ),
            enabled: false,
            options: [
                VolcengineSearchOptions.Key.interface:
                    VolcengineSearchInterface.agentPlan.rawValue
            ]
        )
        XCTAssertEqual(
            VolcengineDataProPlan.serverID(for: sameID),
            VolcengineDataProPlan.serverID(for: agent)
        )
    }

    func testDataProRejectsArkCredentialAndReportsFailure() async throws {
        let center = makeCenter()
        let ark = volcengineConfiguration(
            interface: .arkResponses,
            enabled: false,
            options: [
                VolcengineSearchOptions.Key.arkModel: "doubao-test-1"
            ]
        )
        do {
            try await center.setDataProEnabled(true, for: ark, credential: "ark-key")
            XCTFail("expected requiresAgentPlan")
        } catch {
            XCTAssertEqual(error as? VolcengineSearchSettingsError, .requiresAgentPlan)
        }
        XCTAssertTrue(dataPro.servers.isEmpty)

        let agent = volcengineConfiguration(interface: .agentPlan, enabled: false)
        dataPro.upsertError = FakeDataProError.network
        do {
            try await center.setDataProEnabled(true, for: agent, credential: "agent-plan-key")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FakeDataProError, .network)
        }
        XCTAssertEqual(
            center.dataProState(for: agent),
            .failed(FakeDataProError.network.localizedDescription)
        )
    }

    func testDataProServerIDPersistsAndDraftClearsModeSpecificOptions() throws {
        let id = UUID()
        var draft = try VolcengineSettingsDraft(
            configuration: WebSearchProviderConfiguration(
                id: id,
                kind: .volcengine,
                displayName: "Volcengine",
                credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                    for: id,
                    interface: .agentPlan
                ),
                enabled: false,
                options: [
                    VolcengineSearchOptions.Key.interface:
                        VolcengineSearchInterface.agentPlan.rawValue,
                    VolcengineSearchOptions.Key.dataProEnabled: "true",
                    VolcengineSearchOptions.Key.queryRewrite: "true",
                    VolcengineSearchOptions.Key.authoritativeOnly: "true"
                ]
            )
        )
        draft.dataProServerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let agent = try draft.configuration()
        XCTAssertEqual(
            agent.options[VolcengineSearchOptions.Key.dataProServerID],
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        XCTAssertEqual(VolcengineDataProPlan.serverID(for: agent), draft.dataProServerID)

        draft.mode = .arkResponses
        draft.arkEngine = .onlineContent
        draft.arkModel = "doubao-test-2"
        let ark = try draft.configuration()
        XCTAssertNil(ark.options[VolcengineSearchOptions.Key.queryRewrite])
        XCTAssertNil(ark.options[VolcengineSearchOptions.Key.authoritativeOnly])
        XCTAssertNil(ark.options[VolcengineSearchOptions.Key.dataProEnabled])
        XCTAssertEqual(
            ark.options[VolcengineSearchOptions.Key.dataProServerID],
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        XCTAssertEqual(
            VolcengineDataProPlan.serverID(for: ark),
            draft.dataProServerID
        )
        XCTAssertEqual(
            ark.options[VolcengineSearchOptions.Key.arkEngine],
            VolcengineArkSearchEngine.onlineContent.rawValue
        )

        draft.mode = .doubaoSearch
        let direct = try draft.configuration()
        XCTAssertNil(direct.options[VolcengineSearchOptions.Key.arkEngine])
        XCTAssertEqual(direct.options[VolcengineSearchOptions.Key.queryRewrite], "true")
    }

    func testDataProRefusesForeignMCPAtReservedIdentity() async throws {
        let center = makeCenter()
        let reservedID = UUID()
        let providerID = UUID()
        let agent = WebSearchProviderConfiguration(
            id: providerID,
            kind: .volcengine,
            displayName: "Volcengine",
            credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                for: providerID,
                interface: .agentPlan
            ),
            enabled: false,
            options: [
                VolcengineSearchOptions.Key.interface:
                    VolcengineSearchInterface.agentPlan.rawValue,
                VolcengineSearchOptions.Key.dataProServerID: reservedID.uuidString
            ]
        )
        let foreign = MCPServerConfiguration(
            id: reservedID,
            displayName: "User MCP",
            endpoint: URL(string: "https://mcp.example.com/mcp")!,
            enabled: true,
            authentication: .bearerToken
        )
        dataPro.servers[reservedID] = foreign

        do {
            try await center.setDataProEnabled(true, for: agent, credential: "agent-plan-key")
            XCTFail("expected serverIdentityConflict")
        } catch {
            XCTAssertEqual(
                error as? VolcengineSearchSettingsError,
                .serverIdentityConflict
            )
        }
        XCTAssertEqual(dataPro.servers[reservedID], foreign)
        XCTAssertEqual(dataPro.lastCredential[reservedID] ?? nil, nil)
        XCTAssertEqual(center.dataProState(for: agent), .inactive)

        // Disabling is a safe no-op; it must not overwrite the foreign MCP.
        try await center.setDataProEnabled(false, for: agent, credential: nil)
        XCTAssertEqual(dataPro.servers[reservedID], foreign)
    }

    func testDataProOwnedIdentitySurvivesInterfaceTransitionAndDisables() async throws {
        let center = makeCenter()
        let providerID = UUID()
        let agent = WebSearchProviderConfiguration(
            id: providerID,
            kind: .volcengine,
            displayName: "Volcengine",
            credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                for: providerID,
                interface: .agentPlan
            ),
            enabled: false,
            options: [
                VolcengineSearchOptions.Key.interface:
                    VolcengineSearchInterface.agentPlan.rawValue,
                VolcengineSearchOptions.Key.dataProEnabled: "true"
            ]
        )
        try await center.setDataProEnabled(true, for: agent, credential: "agent-plan-key")
        let serverID = VolcengineDataProPlan.serverID(for: agent)
        XCTAssertEqual(dataPro.servers.count, 1)

        var draft = try VolcengineSettingsDraft(configuration: agent)
        XCTAssertEqual(draft.dataProServerID, serverID)
        draft.mode = .arkResponses
        let ark = try draft.configuration()
        XCTAssertEqual(
            ark.options[VolcengineSearchOptions.Key.dataProServerID],
            serverID.uuidString
        )
        XCTAssertEqual(VolcengineDataProPlan.serverID(for: ark), serverID)
        XCTAssertNil(ark.options[VolcengineSearchOptions.Key.dataProEnabled])

        // The temporary Ark save must still be able to disable the owned
        // server; losing the ID here would strand it.
        try await center.setDataProEnabled(false, for: ark, credential: nil)
        XCTAssertEqual(dataPro.state(serverID: serverID), .inactive)
        XCTAssertEqual(dataPro.servers.count, 1)
        XCTAssertEqual(dataPro.servers[serverID]?.enabled, false)

        draft.mode = .agentPlan
        let agentAgain = try draft.configuration()
        XCTAssertEqual(VolcengineDataProPlan.serverID(for: agentAgain), serverID)
        XCTAssertEqual(dataPro.servers.count, 1)
    }

    func testDataProObservationFollowsLiveMCPState() async throws {
        let center = makeCenter()
        let agent = volcengineConfiguration(interface: .agentPlan, enabled: false)
        try await center.setDataProEnabled(true, for: agent, credential: "agent-plan-key")
        let serverID = VolcengineDataProPlan.serverID(for: agent)
        var observed: [VolcengineDataProState] = []
        let observation = try XCTUnwrap(center.observeDataPro(for: agent) { state in
            observed.append(state)
        })
        // The publisher's current value is delivered immediately.
        XCTAssertEqual(observed.last, .ready(2))

        dataPro.states[serverID] = .failed("timeout")
        dataPro.notify(serverID: serverID)
        XCTAssertEqual(observed.last, .failed("timeout"))

        dataPro.states[serverID] = .inactive
        dataPro.notify(serverID: serverID)
        XCTAssertEqual(observed.last, .inactive)

        observation.cancel()
        try await Task.sleep(for: .milliseconds(10))
        dataPro.states[serverID] = .ready(9)
        dataPro.notify(serverID: serverID)
        XCTAssertEqual(observed.last, .inactive)
    }

    func testDataProObservationFencesForeignServer() async throws {
        let center = makeCenter()
        let reservedID = UUID()
        let providerID = UUID()
        let agent = WebSearchProviderConfiguration(
            id: providerID,
            kind: .volcengine,
            displayName: "Volcengine",
            credentialAccount: VolcengineSettingsDraft.perProviderCredentialAccount(
                for: providerID,
                interface: .agentPlan
            ),
            enabled: false,
            options: [
                VolcengineSearchOptions.Key.interface:
                    VolcengineSearchInterface.agentPlan.rawValue,
                VolcengineSearchOptions.Key.dataProServerID: reservedID.uuidString
            ]
        )
        let foreign = MCPServerConfiguration(
            id: reservedID,
            displayName: "User MCP",
            endpoint: URL(string: "https://mcp.example.com/mcp")!,
            enabled: true,
            authentication: .bearerToken
        )
        dataPro.servers[reservedID] = foreign
        dataPro.states[reservedID] = .ready(4)

        var observed: [VolcengineDataProState] = []
        let observation = try XCTUnwrap(center.observeDataPro(for: agent) { state in
            observed.append(state)
        })
        XCTAssertEqual(observed.last, .inactive)
        dataPro.notify(serverID: reservedID)
        XCTAssertEqual(observed.last, .inactive)
        observation.cancel()
    }
}

// MARK: - Test-owned stores

@MainActor
private final class FakeWebSearchCloud: WebSearchCloudStoring {
    var storage: [String: Data] = [:]
    var synchronizeCount = 0
    var notificationObject: AnyObject? { nil }
    var externalChangeNotification: Notification.Name {
        Notification.Name("org.floeagent.tests.volcengine.cloud")
    }

    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data?, forKey key: String) { storage[key] = data }
    func synchronize() { synchronizeCount += 1 }
}

private final class MemoryWebSearchCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var writeFailure = false

    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return writeFailure }
        set { lock.lock(); writeFailure = newValue; lock.unlock() }
    }

    var store: WebSearchCredentialStore {
        WebSearchCredentialStore(
            read: { [self] account in
                lock.lock()
                defer { lock.unlock() }
                return storage[account]
            },
            write: { [self] account, data in
                lock.lock()
                defer { lock.unlock() }
                if writeFailure { throw FakeDataProError.keychain }
                storage[account] = data
            },
            delete: { [self] account in
                lock.lock()
                defer { lock.unlock() }
                storage.removeValue(forKey: account)
            }
        )
    }
}

private enum FakeDataProError: Error, LocalizedError, Equatable {
    case keychain
    case network

    var errorDescription: String? {
        switch self {
        case .keychain: "synthetic keychain failure"
        case .network: "synthetic network failure"
        }
    }
}

@MainActor
private final class FakeDataProManager: VolcengineDataProManaging {
    var servers: [UUID: MCPServerConfiguration] = [:]
    var lastCredential: [UUID: String?] = [:]
    var states: [UUID: VolcengineDataProState] = [:]
    var upsertError: Error?
    var upsertCount = 0
    var refreshCount = 0
    private typealias Observer = @MainActor (VolcengineDataProState) -> Void
    private var observers: [UUID: [UUID: Observer]] = [:]

    func upsert(_ server: MCPServerConfiguration, credential: String?) async throws {
        upsertCount += 1
        if let upsertError {
            states[server.id] = .failed(upsertError.localizedDescription)
            throw upsertError
        }
        servers[server.id] = server
        lastCredential[server.id] = credential
        states[server.id] = .ready(2)
        notify(serverID: server.id)
    }

    func setEnabled(_ enabled: Bool, serverID: UUID) {
        guard var server = servers[serverID] else { return }
        server.enabled = enabled
        servers[serverID] = server
        states[serverID] = enabled ? .ready(2) : .inactive
        notify(serverID: serverID)
    }

    func currentServer(serverID: UUID) -> MCPServerConfiguration? {
        servers[serverID]
    }

    func state(serverID: UUID) -> VolcengineDataProState {
        states[serverID] ?? .inactive
    }

    func refresh(serverID: UUID) async {
        refreshCount += 1
        states[serverID] = .ready(3)
        notify(serverID: serverID)
    }

    func observeState(
        serverID: UUID,
        onChange: @escaping @MainActor (VolcengineDataProState) -> Void
    ) -> VolcengineDataProObservation {
        let token = UUID()
        observers[serverID, default: [:]][token] = onChange
        onChange(state(serverID: serverID))
        return VolcengineDataProObservation { [weak self] in
            Task { @MainActor in
                self?.observers[serverID]?.removeValue(forKey: token)
            }
        }
    }

    func notify(serverID: UUID) {
        guard let serverObservers = observers[serverID] else { return }
        let current = state(serverID: serverID)
        for observer in serverObservers.values {
            observer(current)
        }
    }
}

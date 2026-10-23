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
        // Fresh installs no longer auto-create placeholder presets: the list
        // stays empty until the user adds a provider from the signed catalog.
        let center = makeCenter()
        XCTAssertTrue(center.providers.isEmpty)
        XCTAssertNil(defaults.data(forKey: WebSearchSettingsCenter.defaultsKey))

        // A catalog pick still defaults Volcengine to the Agent Plan account
        // and stays disabled.
        let entry = SearchProviderCatalogEntry(
            presetID: "volcengine",
            adapterKind: "volcengine",
            name: ["en": "Volcengine Web Search", "zh-Hans": "火山引擎联网搜索"],
            blurb: ["en": "Search", "zh-Hans": "搜索"],
            defaultEndpoint: nil,
            endpointRequired: false,
            credentialFields: [],
            optionFields: []
        )
        let draft = try XCTUnwrap(SearchProviderDraftFactory.draftInstance(
            for: entry,
            localePrimary: "en",
            volcengineCredentialAccount: { id in
                VolcengineSettingsDraft.perProviderCredentialAccount(
                    for: id, interface: .agentPlan
                )
            }
        ))
        XCTAssertFalse(draft.configuration.enabled)
        XCTAssertEqual(
            draft.configuration.options[VolcengineSearchOptions.Key.interface],
            VolcengineSearchInterface.agentPlan.rawValue
        )
        XCTAssertEqual(
            draft.configuration.credentialAccount,
            VolcengineSettingsDraft.perProviderCredentialAccount(
                for: draft.configuration.id, interface: .agentPlan
            )
        )
        XCTAssertNotEqual(
            draft.configuration.credentialAccount,
            VolcengineSettingsDraft.agentPlanCredentialAccount
        )
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
        let providerID = UUID()
        let legacyAccount = "web-search.volcengine.legacy-account-\(UUID().uuidString)"
        let legacy = volcengineConfiguration(
            interface: nil,
            endpoint: URL(string: "https://search.example.com/api"),
            id: providerID,
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
                for: providerID,
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
                for: providerID,
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
        let originalID = UUID()
        try center.upsert(
            volcengineConfiguration(interface: .agentPlan, enabled: false, id: originalID),
            credential: nil
        )
        let original = try XCTUnwrap(center.providers.first { $0.id == originalID })
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

    // MARK: - Dedicated-editor display-name ownership
    //
    // The dedicated Volcengine editor maps a form draft, so it saves through
    // `upsert` with the name identity it observed (opening title + the
    // catalog's official titles). The official supplier title stays
    // catalog-owned; only a name the user actually changed is an alias.

    private func volcengineEntry(
        name: [String: String] = ["en": "Volcengine Web Search", "zh-Hans": "火山引擎联网搜索"]
    ) -> SearchProviderCatalogEntry {
        SearchProviderCatalogEntry(
            presetID: SearchProviderPresets.volcengine,
            adapterKind: "volcengine",
            name: name,
            blurb: ["en": "Search", "zh-Hans": "搜索"],
            defaultEndpoint: nil,
            endpointRequired: false,
            credentialFields: [
                .init(key: "apiKey", required: true, label: ["en": "Key", "zh-Hans": "密钥"])
            ],
            optionFields: []
        )
    }

    private func volcengineCatalog(
        version: String,
        name: [String: String]
    ) -> SearchProviderCatalogIndex {
        SearchProviderCatalogIndex(document: SearchProviderCatalogDocument(
            schemaVersion: 1,
            id: SearchProviderCatalog.packageID,
            version: version,
            entries: [volcengineEntry(name: name)]
        ))
    }

    private var locale: String { WebSearchSettingsCenter.localePrimary }

    func testDraftEmptyNameUsesTheOfficialTitleAndIsNeverAnAlias() throws {
        let entry = volcengineEntry()
        let officialTitle = entry.displayName(localePrimary: locale)
        let center = makeCenter()
        let stored = volcengineConfiguration(interface: .agentPlan, enabled: false)
        try center.upsert(stored, credential: nil)

        var draft = try VolcengineSettingsDraft(configuration: stored)
        draft.officialName = officialTitle
        draft.displayName = "   "
        let saved = try draft.configuration()
        XCTAssertEqual(saved.displayName, officialTitle,
                       "an emptied field keeps the catalog-owned official title, not a literal")
        try center.upsert(
            saved,
            credential: nil,
            nameOwnership: SearchProviderNameOwnership(
                openingTitle: stored.displayName,
                officialTitle: officialTitle,
                officialTitles: [officialTitle, "Volcengine Web Search", "火山引擎联网搜索"]
            )
        )
        let instance = try XCTUnwrap(center.instances.first { $0.configuration.id == stored.id })
        XCTAssertEqual(instance.configuration.displayName, officialTitle)
        XCTAssertFalse(instance.overrides.contains("displayName"),
                       "clearing the field is not a user alias")

        // Without a catalog entry the draft keeps the opening name instead of
        // a hardcoded English literal.
        var legacy = try VolcengineSettingsDraft(configuration: stored)
        legacy.displayName = ""
        XCTAssertEqual(try legacy.configuration().displayName, stored.displayName)
    }

    func testDedicatedEditorSaveAcrossCatalogRefreshKeepsCatalogOwnedNameUnaliased() throws {
        let oldTitle = volcengineEntry().displayName(localePrimary: locale)
        let renamedEntry = volcengineEntry(
            name: ["en": "Volcengine Web Search Pro", "zh-Hans": "火山引擎联网搜索Pro"]
        )
        let newTitle = renamedEntry.displayName(localePrimary: locale)
        XCTAssertNotEqual(oldTitle, newTitle)

        let center = makeCenter()
        var opening = volcengineConfiguration(interface: .agentPlan, enabled: false)
        opening.displayName = oldTitle
        try center.upsert(opening, credential: nil)
        // The catalog title refreshes automatically while the editor is open.
        XCTAssertEqual(
            center.synchronizeCatalogTitles(
                catalog: volcengineCatalog(version: "1.1.0", name: renamedEntry.name)
            ),
            1
        )
        XCTAssertEqual(center.instances.first?.configuration.displayName, newTitle)

        // The user only changed a real option; the name field still shows the
        // opening official name. Saving must neither freeze that stale name
        // nor turn it into an alias.
        var draft = try VolcengineSettingsDraft(configuration: opening)
        draft.officialName = newTitle
        draft.queryRewrite = true
        let refreshedConfiguration = try XCTUnwrap(center.instances.first).configuration
        XCTAssertNotEqual(draft.openingDisplayName, refreshedConfiguration.displayName)
        XCTAssertEqual(draft.openingDisplayName, oldTitle)
        let saved = try draft.configuration()
        XCTAssertEqual(saved.displayName, oldTitle, "the untouched draft carries the opening name")
        try center.upsert(
            saved,
            credential: nil,
            provenance: SearchProviderCatalogProvenance(
                presetID: SearchProviderPresets.volcengine,
                catalogVersion: "1.1.0",
                credentialKeys: ["apiKey"]
            ),
            nameOwnership: SearchProviderNameOwnership(
                openingTitle: draft.openingDisplayName,
                officialTitle: newTitle,
                officialTitles: [newTitle, renamedEntry.name["en"]!, renamedEntry.name["zh-Hans"]!]
            )
        )
        let instance = try XCTUnwrap(center.instances.first)
        XCTAssertEqual(instance.configuration.displayName, newTitle,
                       "the refreshed official title is preserved, not overwritten")
        XCTAssertFalse(instance.overrides.contains("displayName"))
        XCTAssertEqual(instance.configuration.options[VolcengineSearchOptions.Key.queryRewrite], "true",
                       "the user's real option change persisted")
    }

    func testDedicatedEditorNameEditSurvivesSyncAndRevertingToOfficialClearsAlias() throws {
        let entry = volcengineEntry()
        let officialTitle = entry.displayName(localePrimary: locale)
        let officialTitles: Set<String> = [
            officialTitle, entry.name["en"]!, entry.name["zh-Hans"]!
        ]
        let alias = "我的火山引擎"
        let center = makeCenter()
        var opening = volcengineConfiguration(interface: .agentPlan, enabled: false)
        opening.displayName = officialTitle
        try center.upsert(opening, credential: nil)

        // 1. A genuine edit through the dedicated path is marked and kept.
        var edited = opening
        edited.displayName = alias
        try center.upsert(
            edited,
            credential: nil,
            nameOwnership: SearchProviderNameOwnership(
                openingTitle: officialTitle,
                officialTitle: officialTitle,
                officialTitles: officialTitles
            )
        )
        var instance = try XCTUnwrap(center.instances.first)
        XCTAssertEqual(instance.configuration.displayName, alias)
        XCTAssertTrue(instance.overrides.contains("displayName"))

        // 2. An automatic official-title refresh never renames the alias.
        let renamed = volcengineCatalog(
            version: "1.1.0",
            name: ["en": "Volcengine Web Search Pro", "zh-Hans": "火山引擎联网搜索Pro"]
        )
        XCTAssertEqual(center.synchronizeCatalogTitles(catalog: renamed), 0)
        XCTAssertEqual(center.instances.first?.configuration.displayName, alias)

        // 3. Re-saving the alias unchanged keeps the marking (a reloaded
        //    editor sees the alias as its opening name).
        try center.upsert(
            edited,
            credential: nil,
            nameOwnership: SearchProviderNameOwnership(
                openingTitle: alias,
                officialTitle: renamed.entries[0].displayName(localePrimary: locale),
                officialTitles: [renamed.entries[0].displayName(localePrimary: locale)]
            )
        )
        XCTAssertEqual(center.instances.first?.overrides.contains("displayName"), true)

        // 4. Clearing the field reverts to the current official title and
        //    removes the alias marking so the catalog owns the name again.
        let newOfficial = renamed.entries[0].displayName(localePrimary: locale)
        var cleared = try VolcengineSettingsDraft(configuration: edited)
        cleared.officialName = newOfficial
        cleared.displayName = ""
        let clearedSaved = try cleared.configuration()
        XCTAssertEqual(clearedSaved.displayName, newOfficial)
        try center.upsert(
            clearedSaved,
            credential: nil,
            nameOwnership: SearchProviderNameOwnership(
                openingTitle: alias,
                officialTitle: newOfficial,
                officialTitles: [newOfficial]
            )
        )
        instance = try XCTUnwrap(center.instances.first)
        XCTAssertEqual(instance.configuration.displayName, newOfficial)
        XCTAssertFalse(instance.overrides.contains("displayName"),
                       "reverting to the official title restores catalog ownership")
    }

    func testResolvedDisplayNameFollowsTheCatalogOwnershipRule() {
        let ownership = SearchProviderNameOwnership(
            openingTitle: "Bocha Search",
            officialTitle: "Bocha Web Search",
            officialTitles: ["Bocha Web Search", "博查网页搜索"]
        )
        // A user-typed alias is marked.
        XCTAssertEqual(
            WebSearchSettingsCenter.resolvedDisplayName(
                saved: "My Bocha", previous: "Bocha Search", aliased: false, ownership: ownership
            ).isUserAlias,
            true
        )
        // Entering a current official title is catalog-owned and adopts it.
        let reverted = WebSearchSettingsCenter.resolvedDisplayName(
            saved: "博查网页搜索", previous: "My Bocha", aliased: true, ownership: ownership
        )
        XCTAssertFalse(reverted.isUserAlias)
        XCTAssertEqual(reverted.displayName, "Bocha Web Search")
        // A carried-over former official title stays catalog-owned and adopts
        // the current official title.
        let carried = WebSearchSettingsCenter.resolvedDisplayName(
            saved: "Bocha Search", previous: "Bocha Web Search", aliased: false, ownership: ownership
        )
        XCTAssertFalse(carried.isUserAlias)
        XCTAssertEqual(carried.displayName, "Bocha Web Search")
        // An unchanged existing alias keeps its marking and its name.
        let keptAlias = WebSearchSettingsCenter.resolvedDisplayName(
            saved: "My Bocha", previous: "My Bocha", aliased: true, ownership: ownership
        )
        XCTAssertTrue(keptAlias.isUserAlias)
        XCTAssertEqual(keptAlias.displayName, "My Bocha")
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

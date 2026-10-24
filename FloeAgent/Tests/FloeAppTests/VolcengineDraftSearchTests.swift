// FloeAppTests — Agent Plan draft and saved request parity.
// Synthetic configurations only; no network, credentials or Keychain access.
import XCTest
import Foundation
@testable import FloeExecution
@testable import FloeApp

final class VolcengineDraftSearchTests: XCTestCase {
    private static let directEndpoint = "https://open.feedcoopapi.com/search_api/web_search"

    func testLegacyToAgentPlanDraftFreezesTheDirectContractAndItsOwnAccount() throws {
        let legacy = WebSearchProviderConfiguration(
            kind: .volcengine,
            displayName: "Volcengine",
            endpoint: URL(string: "https://search.example.com/api"),
            credentialAccount: VolcengineSettingsDraft.legacyCredentialAccount,
            enabled: true
        )
        var draft = try VolcengineSettingsDraft(configuration: legacy)
        draft.mode = .agentPlan
        // The switched draft never borrows the captured legacy credential
        // and never rewrites it: it resolves its own per-provider account.
        let account = draft.credentialAccount(for: .agentPlan)
        XCTAssertEqual(
            account,
            VolcengineSettingsDraft.perProviderCredentialAccount(
                for: draft.providerID, interface: .agentPlan
            )
        )
        XCTAssertNotEqual(account, VolcengineSettingsDraft.legacyCredentialAccount)

        // This is exactly what SearchTestSection's configuration closure
        // freezes for Test Search: no endpoint override, Agent Plan option
        // selected, canonical direct gateway with the draft key.
        let frozen = try draft.configuration()
        XCTAssertNil(frozen.endpoint)
        XCTAssertEqual(
            frozen.options[VolcengineSearchOptions.Key.interface],
            VolcengineSearchInterface.agentPlan.rawValue
        )
        let request = try WebSearchService.makeRequest(
            frozen,
            credential: WebSearchCredential(values: ["apiKey": "agent-plan-key"]),
            query: WebSearchQuery(text: "AppleiPad", mode: .balanced, maxResults: 5)
        )
        XCTAssertEqual(request.url?.absoluteString, Self.directEndpoint)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer agent-plan-key"
        )
    }

    func testDraftSavedRoundTripProducesTheByteIdenticalRequest() throws {
        // draft -> saved configuration -> re-opened draft -> configuration
        // must emit an identical request: the saved path cannot diverge from
        // the unsaved path, which matches the user's A/B observation (both
        // returned the same failure while only the adapter decode was wrong).
        var draft = try VolcengineSettingsDraft(configuration: WebSearchProviderConfiguration(
            kind: .volcengine,
            displayName: "Agent Plan",
            credentialAccount: "web-search.volcengine.\(UUID().uuidString.lowercased()).agentPlan",
            enabled: true,
            options: [
                VolcengineSearchOptions.Key.interface: VolcengineSearchInterface.agentPlan.rawValue,
                VolcengineSearchOptions.Key.queryRewrite: "true",
                VolcengineSearchOptions.Key.authoritativeOnly: "false"
            ]
        ))
        draft.queryRewrite = true
        let first = try draft.configuration()
        let second = try VolcengineSettingsDraft(configuration: first).configuration()
        XCTAssertEqual(first.options, second.options)
        XCTAssertEqual(first.credentialAccount, second.credentialAccount)
        XCTAssertNil(second.endpoint)
        let query = WebSearchQuery(text: "豆包大模型 最新版本 发布", mode: .balanced, maxResults: 5)
        let credential = WebSearchCredential(values: ["apiKey": "k"])
        let requestA = try WebSearchService.makeRequest(first, credential: credential, query: query)
        let requestB = try WebSearchService.makeRequest(second, credential: credential, query: query)
        XCTAssertEqual(requestA.url, requestB.url)
        XCTAssertEqual(
            requestA.httpBody.map { Array($0) },
            requestB.httpBody.map { Array($0) }
        )
    }
}

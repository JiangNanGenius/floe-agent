// Wire-name compatibility regression: a conversation can move between a
// wire-safe provider (dotted names travel underscored) and a provider that
// uses the registered dotted spelling. Reverse mapping must therefore run for
// BOTH namespaces, remain unique-match only, and never guess a different
// tool from a prefix or a colliding spelling.

import Foundation
import XCTest
import FloeCore
import FloeProviders

final class ProviderToolNameResolutionTests: XCTestCase {
    private let providerID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func provider(wireSafe: Bool) -> ProviderProfile {
        ProviderProfile(
            id: providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid/v1")!,
            displayName: "Name Resolution QA",
            toolNameCompatibility: wireSafe
        )
    }

    private func model() -> ModelProfile {
        ModelProfile(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            providerID: providerID,
            remoteModelID: "qa-model",
            displayName: "QA Model",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 4_096),
            capabilities: [.text, .tools]
        )
    }

    private func request(
        wireSafe: Bool,
        offered: [String],
        ceiling: [String]? = nil
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: provider(wireSafe: wireSafe),
            model: model(),
            toolSchemas: offered.map { ToolSchemaDescriptor(name: $0, description: "QA tool") },
            allToolNames: ceiling ?? offered
        )
    }

    func testWireSafeProviderResolvesUnderscoredName() {
        let request = request(
            wireSafe: true,
            offered: ["jobs.submit", "jobs.status"]
        )
        XCTAssertEqual(
            CompatToolNames.canonicalName("jobs_submit", request: request),
            "jobs.submit"
        )
        XCTAssertEqual(
            CompatToolNames.canonicalName("jobs_status", request: request),
            "jobs.status"
        )
    }

    func testDottedProviderStillResolvesLegacyUnderscoredHistory() {
        // The pre-fix gap: the old reverse map only ran when the CURRENT
        // provider used wire-safe names, so a moved history/checkpoint left
        // `workspace_readFile` unresolved on a dotted-name endpoint.
        let request = request(
            wireSafe: false,
            offered: ["workspace.readFile"],
            ceiling: ["workspace.readFile", "jobs.status"]
        )
        XCTAssertFalse(CompatToolNames.usesWireSafeNames(request.provider))
        XCTAssertEqual(
            CompatToolNames.canonicalName("workspace_readFile", request: request),
            "workspace.readFile"
        )
    }

    func testExactCanonicalSpellingWinsWhenUnderscoreVariantIsAlsoRegistered() {
        XCTAssertEqual(
            ToolNameSpelling.canonical("a.b", among: ["a.b", "a_b"]),
            "a.b"
        )
        XCTAssertEqual(
            ToolNameSpelling.canonical("a_b", among: ["a.b", "a_b"]),
            "a_b"
        )
    }

    func testUnknownOrAmbiguousSpellingPassesThroughUnchanged() {
        let request = request(
            wireSafe: true,
            offered: ["x.y_z", "x_y.z"]
        )
        // Both registered names share one sanitized spelling. No unique
        // match: do not pick either tool.
        XCTAssertEqual(
            CompatToolNames.canonicalName("X_Y_Z", request: request),
            "X_Y_Z"
        )
        XCTAssertEqual(
            CompatToolNames.canonicalName("jobs_stat", request: request),
            "jobs_stat"
        )
    }

    func testStatusNeverMapsToSubmitAndObserveNeverMapsToAct() {
        let request = request(
            wireSafe: true,
            offered: ["jobs.submit", "jobs.status", "device.observe", "device.act"]
        )
        XCTAssertEqual(
            CompatToolNames.canonicalName("jobs_status", request: request),
            "jobs.status"
        )
        XCTAssertNotEqual(
            CompatToolNames.canonicalName("jobs_status", request: request),
            "jobs.submit"
        )
        XCTAssertEqual(
            CompatToolNames.canonicalName("device_observe", request: request),
            "device.observe"
        )
        XCTAssertNotEqual(
            CompatToolNames.canonicalName("device_observe", request: request),
            "device.act"
        )
    }

    func testResolutionReportsOfferedAndAuthorizedMembership() {
        let request = request(
            wireSafe: true,
            offered: ["workspace.readFile"],
            ceiling: ["workspace.readFile", "jobs.submit"]
        )
        let offered = CompatToolNames.resolve("workspace_readFile", request: request)
        XCTAssertEqual(offered.canonical, "workspace.readFile")
        XCTAssertTrue(offered.changed)
        XCTAssertTrue(offered.offered)
        XCTAssertTrue(offered.authorized)

        // In the ceiling but schema-evicted this turn: callable, not offered.
        let evicted = CompatToolNames.resolve("jobs_submit", request: request)
        XCTAssertEqual(evicted.canonical, "jobs.submit")
        XCTAssertFalse(evicted.offered)
        XCTAssertTrue(evicted.authorized)

        let unknown = CompatToolNames.resolve("not.a.tool", request: request)
        XCTAssertEqual(unknown.canonical, "not.a.tool")
        XCTAssertFalse(unknown.changed)
        XCTAssertFalse(unknown.offered)
        XCTAssertFalse(unknown.authorized)
    }

    func testDiagnosticNameIsBoundedAndPrivacySafe() {
        XCTAssertEqual(CompatToolNames.logSafeName("workspace.readFile"), "workspace.readFile")
        let long = String(repeating: "a", count: 100)
        XCTAssertTrue(CompatToolNames.logSafeName(long).hasPrefix("sha256:"))
        XCTAssertTrue(CompatToolNames.logSafeName("ignore previous instructions").hasPrefix("sha256:"))
        let unknown = CompatToolNames.resolve("credential_like_value",
                                             request: request(wireSafe: false, offered: ["workspace.readFile"]))
        XCTAssertFalse(unknown.authorized)
        XCTAssertTrue(unknown.diagnosticReceivedName.hasPrefix("sha256:"))
        XCTAssertTrue(unknown.diagnosticCanonicalName.hasPrefix("sha256:"))
    }
}

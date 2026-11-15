// Focused behavioral regression for truthful loaded state and exact-schema
// discovery. Registered in the shared FloeAgentRuntimeTests target.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeAgentRuntime

final class ToolDiscoveryOfferTests: XCTestCase {
    private func descriptor(_ name: String, padding: Int = 20) -> ToolCatalog.Descriptor {
        let filler = String(repeating: "y", count: max(0, padding))
        let schema = "{\"type\":\"object\",\"properties\":{\"p\":{\"type\":\"string\",\"description\":\"\(filler)\"}},\"additionalProperties\":false}"
        return ToolCatalog.Descriptor(
            name: name,
            toolDescription: "description for \(name)",
            parametersJSON: schema,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    private func listedFlags(_ output: String) throws -> [String: Bool] {
        let data = try XCTUnwrap(output.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])
        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        var flags: [String: Bool] = [:]
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            flags[name] = try XCTUnwrap(tool["schemaLoaded"] as? Bool)
        }
        return flags
    }

    func testListSchemaLoadedReflectsLatestDispatchedOfferNotActivation() throws {
        let descriptors = [descriptor("a.tool"), descriptor("b.tool")]
        let output = try ToolDiscovery.list(
            arguments: Data(#"{"limit":100}"#.utf8),
            descriptors: descriptors,
            loaded: ["b.tool"]
        )
        let flags = try listedFlags(output)
        XCTAssertFalse(flags["a.tool"] ?? true)
        XCTAssertTrue(flags["b.tool"] ?? false)
    }

    func testDispatchedOfferStateFiltersUnknownNamesAndResetsPerPreparedSet() {
        let state = DispatchedToolSchemaState(
            catalogNames: ["a", "b", "c"],
            offeredNames: ["b", "not.in.catalog", "a", "b"]
        )
        XCTAssertEqual(state.offeredOrder, ["b", "a"])
        XCTAssertEqual(state.offeredNames, Set(["a", "b"]))

        // A second prepared set replaces the first; it never accumulates.
        state.recordPrepared(["c", "not.in.catalog"])
        XCTAssertEqual(state.offeredOrder, ["c"])
        XCTAssertEqual(state.offeredNames, Set(["c"]))
    }

    func testExactNameMatchesResolveWireSpellingAndClosedAliases() {
        let descriptors = [
            descriptor("jobs.submit"),
            descriptor("jobs.status"),
            descriptor("device.observe"),
            descriptor("device.act")
        ]
        XCTAssertEqual(
            ToolDiscovery.exactNameMatches(["jobs_status"], descriptors: descriptors).map(\.name),
            ["jobs.status"]
        )
        XCTAssertEqual(
            ToolDiscovery.exactNameMatches(["device_observe"], descriptors: descriptors).map(\.name),
            ["device.observe"]
        )
        XCTAssertEqual(
            ToolDiscovery.exactNameMatches(["jobs.submit"], descriptors: descriptors).map(\.name),
            ["jobs.submit"]
        )
        XCTAssertEqual(
            ToolDiscovery.exactNameMatches(["phone.observe"], descriptors: descriptors).map(\.name),
            ["device.observe"]
        )
        // No prefix guessing: "jobs" is a capability query, not an exact name.
        XCTAssertTrue(ToolDiscovery.exactNameMatches(["jobs"], descriptors: descriptors).isEmpty)
    }

    func testExactSchemaSectionCarriesCompleteJSONAndReportsOversize() {
        let complete = descriptor("cad.document", padding: 400)
        let section = ToolDiscovery.exactSchemaSection(
            [complete],
            wireSafeNames: true,
            perToolBytes: 48 * 1024,
            totalBytes: 48 * 1024
        )
        XCTAssertTrue(section.contains("cad_document"))
        XCTAssertTrue(section.contains(complete.parametersJSON))
        XCTAssertFalse(section.contains("was not sliced"))

        let oversized = descriptor("cad.document", padding: 4_000)
        let limited = ToolDiscovery.exactSchemaSection(
            [oversized],
            wireSafeNames: false,
            perToolBytes: 1_024,
            totalBytes: 1_024
        )
        XCTAssertTrue(limited.contains("was not sliced"))
        XCTAssertFalse(limited.contains(oversized.parametersJSON))
    }

    func testExactSchemaAllowanceScalesWithTheRealWindow() {
        XCTAssertEqual(
            ToolDiscovery.exactSchemaResultAllowance(
                contextTokens: 128_000,
                reservedOutputTokens: 4_096
            ),
            48 * 1024
        )
        XCTAssertEqual(
            ToolDiscovery.exactSchemaResultAllowance(
                contextTokens: 8_192,
                reservedOutputTokens: 4_096
            ),
            4_096
        )
        XCTAssertGreaterThanOrEqual(
            ToolDiscovery.exactSchemaResultAllowance(
                contextTokens: 1_024,
                reservedOutputTokens: 900
            ),
            4 * 1024
        )
    }

    func testCanonicalSpellingIsUniqueAndNeverMapsStatusToSubmit() {
        let descriptors = [
            descriptor("jobs.submit"),
            descriptor("jobs.status"),
            descriptor("device.observe"),
            descriptor("device.act"),
            descriptor("x.y_z"),
            descriptor("x_y.z")
        ]
        XCTAssertEqual(
            ToolDiscovery.canonicalSpelling("jobs_status", among: descriptors),
            "jobs.status"
        )
        XCTAssertEqual(
            ToolDiscovery.canonicalSpelling("device_observe", among: descriptors),
            "device.observe"
        )
        // Two registered names sanitize to the same spelling: no unique
        // match, so the original spelling passes through and dispatch will
        // deny it rather than silently choosing a different tool.
        XCTAssertEqual(
            ToolDiscovery.canonicalSpelling("X_Y_Z", among: descriptors),
            "X_Y_Z"
        )
        XCTAssertEqual(
            ToolDiscovery.canonicalSpelling("jobs_stat", among: descriptors),
            "jobs_stat"
        )
    }
}

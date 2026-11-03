import XCTest
@testable import FloeAndroidCore
import FloeAndroidDataExchange
import FloeTools

/// Authored NOTRUN regression source for the typed MCP exchange. Main runs
/// the focused XCTest filter after the unified build.
final class C07MCPConfigurationExchangeTests: XCTestCase {
    private let currentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let restoredID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func raw(_ configs: [MCPServerConfiguration]) throws -> String {
        let data = try JSONEncoder().encode(configs)
        return String(decoding: data, as: UTF8.self)
    }

    private func definition(
        id: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        name: String = "Command",
        command: String = "node",
        arguments: [String] = ["server.js"],
        workingDirectory: String = "apps/mcp"
    ) -> C07MCPServerDefinition {
        C07MCPServerDefinition(
            sourceID: id, displayName: name, transport: .stdio,
            endpoint: nil, authentication: "none",
            credentialHeaderName: nil, allowInsecureHTTP: false,
            timeoutSeconds: 30, command: command, arguments: arguments,
            workingDirectory: workingDirectory,
            requiresReauthentication: false,
            requiresEnvironmentBinding: true,
            requiresEndpointReconfiguration: false)
    }

    func testHTTPExportDropsUserInfoQueryFragmentAndKeepsSafeMetadata() throws {
        let endpoint = try XCTUnwrap(URL(
            string: "https://alice:secret@example.com:8443/mcp?token=abc#frag"))
        let config = MCPServerConfiguration(
            displayName: "Remote",
            endpoint: endpoint,
            authentication: .customHeader,
            credentialHeaderName: "X-Api-Key",
            timeoutSeconds: 30)
        let exported = try C07MCPConfigurationExchange.export(
            raw: raw([config]))
        XCTAssertEqual(exported.skipped.count, 0)
        let server = try XCTUnwrap(exported.document.servers.first)
        XCTAssertEqual(server.transport, .streamableHTTP)
        XCTAssertEqual(server.endpoint?.scheme, "https")
        XCTAssertEqual(server.endpoint?.host, "example.com")
        XCTAssertEqual(server.endpoint?.port, Optional(8443))
        XCTAssertTrue(server.endpoint?.omittedUserInfo == true)
        XCTAssertTrue(server.endpoint?.omittedQuery == true)
        XCTAssertTrue(server.endpoint?.omittedFragment == true)
        XCTAssertTrue(server.requiresReauthentication)
        XCTAssertTrue(server.requiresEndpointReconfiguration)
        let encoded = String(
            decoding: try JSONEncoder().encode(exported.document),
            as: UTF8.self)
        XCTAssertFalse(encoded.contains("alice"))
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("token=abc"))
    }

    func testStdioDefinitionExportsWithoutAnyRuntimeBindingIdentity() throws {
        let config = MCPServerConfiguration(
            displayName: "Local tool",
            transport: .stdio,
            stdioDefinition: .init(
                command: "node", arguments: ["server.js", "--safe"],
                workingDirectory: "apps/mcp"),
            enabled: true)
        let exported = try C07MCPConfigurationExchange.export(
            raw: raw([config]))
        let server = try XCTUnwrap(exported.document.servers.first)
        XCTAssertEqual(server.command, "node")
        XCTAssertEqual(server.arguments, ["server.js", "--safe"])
        XCTAssertEqual(server.workingDirectory, "apps/mcp")
        XCTAssertTrue(server.requiresEnvironmentBinding)
        let encoded = String(
            decoding: try JSONEncoder().encode(exported.document),
            as: UTF8.self)
        for forbidden in [
            "projectID", "environmentID", "rootIdentity", "taskID",
            "revision", "stdioBinding",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testSecretBearingCommandArgumentIsOmittedInsteadOfCopied() throws {
        let config = MCPServerConfiguration(
            displayName: "Leaky",
            transport: .stdio,
            stdioDefinition: .init(
                command: "node", arguments: ["--token=abc123"],
                workingDirectory: "apps"))
        let exported = try C07MCPConfigurationExchange.export(
            raw: raw([config]))
        XCTAssertTrue(exported.document.servers.isEmpty)
        XCTAssertEqual(exported.skipped.count, 1)
    }

    func testMergeUsesFreshIDsDisablesAndUnbindsWithoutOverwritingCurrent() throws {
        let existing = MCPServerConfiguration(
            id: currentID,
            displayName: "Current",
            endpoint: try XCTUnwrap(URL(string: "https://current.example/mcp")),
            authentication: .none)
        let currentRaw = try raw([existing])
        let source = C07MCPServerDefinition(
            sourceID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            displayName: "Command",
            transport: .stdio,
            authentication: "none",
            allowInsecureHTTP: false,
            timeoutSeconds: 30,
            command: "node",
            arguments: ["server.js"],
            workingDirectory: "apps",
            requiresReauthentication: false,
            requiresEnvironmentBinding: true,
            requiresEndpointReconfiguration: false)
        let ids = [source.sourceID.uuidString: restoredID.uuidString]
        let merged = try C07MCPConfigurationExchange.merge(
            currentRaw: currentRaw,
            definitions: [source],
            newIDs: ids)
        let decoded = try JSONDecoder().decode(
            [MCPServerConfiguration].self,
            from: Data(try XCTUnwrap(merged.raw).utf8))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, currentID)
        XCTAssertEqual(decoded[0].displayName, "Current")
        let restored = decoded[1]
        XCTAssertEqual(restored.id, restoredID)
        XCTAssertNotEqual(restored.id, source.sourceID)
        XCTAssertEqual(restored.displayName, "Command (restored)")
        XCTAssertFalse(restored.enabled)
        XCTAssertFalse(restored.allowInCanvas)
        XCTAssertNil(restored.stdioBinding)
        XCTAssertEqual(restored.stdioDefinition?.command, "node")
        XCTAssertEqual(restored.authentication, .none)
        XCTAssertEqual(restored.disabledRemoteToolNames, [])
        XCTAssertEqual(merged.inserted, [restoredID])
    }

    func testRollbackRemovesOnlyTheExactInsertedIDs() throws {
        let existing = MCPServerConfiguration(
            id: currentID,
            displayName: "Current",
            endpoint: try XCTUnwrap(URL(string: "https://current.example/mcp")),
            authentication: .none)
        let restored = MCPServerConfiguration(
            id: restoredID,
            displayName: "Command (restored)",
            transport: .stdio,
            stdioDefinition: .init(command: "node", arguments: ["server.js"]),
            enabled: false)
        let merged = try raw([existing, restored])
        let remainingRaw = try XCTUnwrap(
            C07MCPConfigurationExchange.removing(
                ids: [restoredID], fromRaw: merged,
                removeRowWhenEmpty: false))
        let remaining = try JSONDecoder().decode(
            [MCPServerConfiguration].self,
            from: Data(remainingRaw.utf8))
        XCTAssertEqual(remaining.map(\.id), [currentID])

        let onlyRestored = try raw([restored])
        XCTAssertNil(try C07MCPConfigurationExchange.removing(
            ids: [restoredID], fromRaw: onlyRestored,
            removeRowWhenEmpty: true))
    }

    func testRawDocumentRejectsUnknownOrSecretShapedKeys() throws {
        let sourceID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let valid = C07MCPConfigDocument(servers: [
            definition(id: sourceID),
        ])
        let validData = try JSONEncoder().encode(valid)
        XCTAssertNoThrow(try C07MCPConfigDocument.validateRaw(validData))

        let extra = """
        {"format":"floe.config.mcpServers","formatVersion":1,"servers":[
          {"sourceID":"\(sourceID.uuidString)","displayName":"Command",
           "transport":"stdio","authentication":"none","command":"node",
           "arguments":[],"requiresReauthentication":false,
           "requiresEnvironmentBinding":true,
           "requiresEndpointReconfiguration":false,
           "credentialToken":"must-not-travel"}
        ]}
        """
        XCTAssertThrowsError(
            try C07MCPConfigDocument.validateRaw(Data(extra.utf8)))
    }
}

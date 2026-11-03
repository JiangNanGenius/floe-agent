import XCTest
@testable import FloeTools

/// Authored NOTRUN DTO regression: a recovered stdio command is ordinary
/// saved configuration, while operational validation still requires the
/// C01-owned binding. No project/environment/root/task identity is invented.
final class MCPRecoveredDefinitionTests: XCTestCase {
    func testLegacyHTTPRowDecodesAsHTTP() throws {
        let json = """
        {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
         "displayName":"Legacy","endpoint":"https://example.com/mcp",
         "enabled":true,"authentication":"none"}
        """
        let config = try JSONDecoder().decode(
            MCPServerConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.transport, .streamableHTTP)
        XCTAssertNil(config.stdioBinding)
        XCTAssertNil(config.stdioDefinition)
        XCTAssertFalse(config.requiresStdioBinding)
        XCTAssertNoThrow(try config.validate())
    }

    func testStdioDefinitionOnlyIsSavedButRequiresBindingAtRuntime() throws {
        let config = MCPServerConfiguration(
            displayName: "Recovered",
            transport: .stdio,
            stdioDefinition: .init(
                command: "python3", arguments: ["server.py"],
                workingDirectory: "tools"))
        XCTAssertTrue(config.requiresStdioBinding)
        XCTAssertNoThrow(try config.validateSavedDefinition())
        XCTAssertThrowsError(try config.validate())

        let decoded = try JSONDecoder().decode(
            MCPServerConfiguration.self,
            from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded.stdioDefinition?.command, "python3")
        XCTAssertEqual(decoded.resolvedStdioDefinition, config.stdioDefinition)
        XCTAssertNil(decoded.stdioBinding)
    }

    func testBindingDecodeDerivesTheEditableCommand() throws {
        let binding = MCPServerConfiguration.StdioBinding(
            projectID: UUID(),
            environmentID: "env",
            rootIdentity: String(repeating: "b", count: 64),
            revision: 4,
            command: "node",
            arguments: ["server.js"],
            workingDirectory: "apps")
        let json = try JSONEncoder().encode(
            MCPServerConfiguration(displayName: "Bound",
                                   transport: .stdio,
                                   stdioBinding: binding))
        let config = try JSONDecoder().decode(
            MCPServerConfiguration.self, from: json)
        XCTAssertEqual(config.resolvedStdioDefinition,
                       MCPServerConfiguration.StdioDefinition(
                        command: "node", arguments: ["server.js"],
                        workingDirectory: "apps"))
        XCTAssertNoThrow(try config.validate())
    }
}

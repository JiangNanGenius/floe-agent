import XCTest
@testable import FloeAndroidCore
import FloeTools

/// Authored NOTRUN regression source for the saved-definition boundary:
/// HTTP rows stay HTTP, a rootless stdio definition remains saved/editable,
/// and operational validation still requires the C01-owned binding.
final class C02MCPSavedDefinitionTests: XCTestCase {
    private let projectID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let taskID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let root = String(repeating: "a", count: 64)

    func testLegacyHTTPJSONStillDecodesAsStreamableHTTP() throws {
        let json = """
        {"id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
         "displayName":"Legacy","endpoint":"https://example.com/mcp",
         "enabled":true,"authentication":"none"}
        """
        let config = try JSONDecoder().decode(
            MCPServerConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.transport, .streamableHTTP)
        XCTAssertNil(config.stdioDefinition)
        XCTAssertNil(config.stdioBinding)
        XCTAssertFalse(config.requiresStdioBinding)
        XCTAssertNoThrow(try config.validate())
    }

    func testRootlessStdioDefinitionRoundTripsAndRemainsSavedUnbound() throws {
        let config = MCPServerConfiguration(
            displayName: "Command",
            transport: .stdio,
            stdioDefinition: .init(
                command: "node", arguments: ["server.js"],
                workingDirectory: "apps/mcp"))
        XCTAssertTrue(config.requiresStdioBinding)
        XCTAssertNoThrow(try config.validateSavedDefinition())
        XCTAssertThrowsError(try config.validate())

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(
            MCPServerConfiguration.self, from: data)
        XCTAssertEqual(decoded.transport, .stdio)
        XCTAssertEqual(decoded.stdioDefinition, config.stdioDefinition)
        XCTAssertNil(decoded.stdioBinding)
        XCTAssertNil(MCPCredentialIdentity.account(for: decoded))
    }

    func testBindingOnlyRowDerivesDefinitionAndValidatesOperationally() throws {
        let binding = MCPServerConfiguration.StdioBinding(
            projectID: projectID,
            environmentID: "env-1",
            rootIdentity: root,
            taskID: taskID,
            revision: 7,
            command: "node",
            arguments: ["server.js"],
            workingDirectory: "apps")
        let config = MCPServerConfiguration(
            displayName: "Bound",
            transport: .stdio,
            stdioBinding: binding)
        XCTAssertEqual(config.resolvedStdioDefinition?.command, "node")
        XCTAssertNoThrow(try config.validate())

        let decoded = try JSONDecoder().decode(
            MCPServerConfiguration.self,
            from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded.stdioDefinition, config.stdioDefinition)
        XCTAssertEqual(decoded.stdioBinding, binding)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testBindingAndDefinitionMismatchIsRejectedAtTheOperationalBoundary() {
        let binding = MCPServerConfiguration.StdioBinding(
            projectID: projectID,
            environmentID: "env-1",
            rootIdentity: root,
            revision: 7,
            command: "node",
            arguments: ["one.js"],
            workingDirectory: "")
        let config = MCPServerConfiguration(
            displayName: "Mismatch",
            transport: .stdio,
            stdioDefinition: .init(command: "node", arguments: ["two.js"]),
            stdioBinding: binding)
        XCTAssertThrowsError(try config.validate())
    }

    func testSaveCandidateAcceptsRootlessStdioAndFullBindingShape() throws {
        let base: [String: Any] = [
            "id": UUID().uuidString,
            "displayName": "Command",
            "transport": "stdio",
            "authentication": "none",
            "stdio": [
                "command": "node",
                "arguments": ["server.js"],
                "workingDirectory": "apps",
            ],
            "createIntent": true,
        ]
        let rootless = try MCPDomain.MCPSaveCandidate.parse(base)
        let unbound = rootless.makeConfiguration()
        XCTAssertNil(unbound.stdioBinding)
        XCTAssertEqual(unbound.stdioDefinition?.command, "node")
        XCTAssertNoThrow(try unbound.validateSavedDefinition())
        XCTAssertThrowsError(try unbound.validate())

        var boundJSON = base
        boundJSON["stdio"] = [
            "projectID": projectID.uuidString,
            "environmentID": "env-1",
            "rootIdentity": root,
            "revision": 3,
            "command": "node",
            "arguments": ["server.js"],
            "workingDirectory": "apps",
        ]
        let bound = try MCPDomain.MCPSaveCandidate.parse(boundJSON)
        let configuration = bound.makeConfiguration()
        XCTAssertNotNil(configuration.stdioBinding)
        XCTAssertEqual(configuration.stdioBinding?.projectID, projectID)
        XCTAssertNoThrow(try configuration.validate())
    }

    func testSaveCandidateRejectsPartialBindingIdentity() {
        let candidate: [String: Any] = [
            "id": UUID().uuidString,
            "displayName": "Command",
            "transport": "stdio",
            "authentication": "none",
            "stdio": [
                "projectID": projectID.uuidString,
                "command": "node",
            ],
        ]
        XCTAssertThrowsError(try MCPDomain.MCPSaveCandidate.parse(candidate))
    }
}

import Foundation
import Testing
import FloeCore
import FloeTools
import FloeSSH
@testable import FloeExecution

/// Regression for Build235: cloud DeepSeek rejected the cloudWorkspace tools
/// because the serialized workspaceID `pattern` contained a doubled backslash
/// (`^[\\A-Za-z0-9]…`). After JSON decoding that becomes `^[\A-Za-z0-9]…`,
/// which a strict (Python `re`-based) JSON Schema validator rejects as
/// `bad escape \A`, so the whole tool schema was refused before any call.
@Suite("Cloud workspace workspaceID schema patterns")
struct CloudWorkspaceSchemaPatternTests {

    /// The single intended workspace ID grammar, shared with
    /// `valid_id` in the bundled floe_remote_agent.py daemon.
    private static let intendedPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#

    /// Every cloud tool whose arguments actually carry a workspaceID must
    /// advertise it with the same portable pattern.
    private static let patternSchemas: [(String, String)] = [
        ("cloudWorkspace.create", CloudWorkspaceProvisionTool.parametersJSON),
        ("cloudWorkspace.git.status", CloudWorkspaceGitStatusTool.parametersJSON),
        ("cloudWorkspace.git.diff", CloudWorkspaceGitDiffTool.parametersJSON),
        ("cloudWorkspace.git.log", CloudWorkspaceGitLogTool.parametersJSON),
        ("cloudWorkspace.git.initialize", CloudWorkspaceGitInitializeTool.parametersJSON),
        ("cloudWorkspace.git.stage", CloudWorkspaceGitStageTool.parametersJSON),
        ("cloudWorkspace.git.commit", CloudWorkspaceGitCommitTool.parametersJSON),
        ("cloudWorkspace.git.fetch", CloudWorkspaceGitFetchTool.parametersJSON),
        ("cloudWorkspace.git.pull", CloudWorkspaceGitPullTool.parametersJSON),
        ("cloudWorkspace.git.push", CloudWorkspaceGitPushTool.parametersJSON),
        ("cloudWorkspace.git.branch", CloudWorkspaceGitBranchTool.parametersJSON)
    ]

    /// Read-only/file tools and the catalog never consume a workspaceID, so
    /// they must not silently grow one through shared fragments.
    private static let schemasWithoutWorkspaceID: [(String, String)] = [
        ("cloudWorkspace.catalog", CloudWorkspaceCatalogTool.parametersJSON),
        ("cloudWorkspace.list", CloudWorkspaceListTool.parametersJSON),
        ("cloudWorkspace.read", CloudWorkspaceReadTool.parametersJSON),
        ("cloudWorkspace.write", CloudWorkspaceWriteTool.parametersJSON),
        ("cloudWorkspace.createDirectory", CloudWorkspaceCreateDirectoryTool.parametersJSON)
    ]

    private let validIDs = [
        "a",
        "Z9",
        "ws-1_x.test",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-",
        String(repeating: "a", count: 128)
    ]

    private let invalidIDs = [
        "",                        // empty
        "-leading-dash",           // first char outside [A-Za-z0-9]
        ".leading-dot",
        "_leading-underscore",
        "has space",               // whitespace
        "../escape",               // path traversal
        "a/b",                     // slash
        "name;rm",                 // shell metacharacter
        "caf\u{00e9}",             // non-ASCII letter
        "tab\there",
        "new\nline",
        String(repeating: "a", count: 129)  // over the 128-char ceiling
    ]

    private func decodedWorkspaceIDPattern(_ schema: String) throws -> String {
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        )
        let properties = try #require(parsed["properties"] as? [String: Any])
        let workspaceID = try #require(properties["workspaceID"] as? [String: Any])
        return try #require(workspaceID["pattern"] as? String)
    }

    private func fullMatches(_ pattern: String, _ value: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return regex.numberOfMatches(in: value, options: .anchored, range: range) == 1
    }

    @Test("every workspaceID schema decodes to the intended portable pattern")
    func patternsDecodeToIntendedGrammar() throws {
        for (name, schema) in Self.patternSchemas {
            let pattern = try decodedWorkspaceIDPattern(schema)
            #expect(pattern == Self.intendedPattern, Comment(rawValue: "\(name) pattern=\(pattern)"))
            // The Build235 defect was a doubled backslash surviving in the wire JSON.
            #expect(!schema.contains("[\\A-Za-z0-9]"), Comment(rawValue: name))
            #expect(!schema.contains("\\\\A"), Comment(rawValue: name))
            // Must compile as a real regex (ICU here; the daemon side uses Python re).
            _ = try NSRegularExpression(pattern: pattern)
        }
    }

    @Test("decoded workspaceID patterns accept valid and reject invalid IDs")
    func patternsClassifyIDs() throws {
        for (name, schema) in Self.patternSchemas {
            let pattern = try decodedWorkspaceIDPattern(schema)
            for value in validIDs {
                #expect(try fullMatches(pattern, value), Comment(rawValue: "\(name) should accept \(value)"))
            }
            for value in invalidIDs {
                #expect(try !fullMatches(pattern, value), Comment(rawValue: "\(name) should reject \(value.debugDescription)"))
            }
        }
    }

    @Test("tools without workspaceID in their arguments do not advertise it")
    func schemasWithoutWorkspaceIDStayLean() throws {
        for (name, schema) in Self.schemasWithoutWorkspaceID {
            let parsed = try #require(
                try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
            )
            let properties = try #require(parsed["properties"] as? [String: Any])
            #expect(properties["workspaceID"] == nil, Comment(rawValue: name))
        }
    }

    @Test("runtime workspaceID validation matches the advertised pattern")
    func runtimeValidationAgreesWithSchema() throws {
        let ssh = SSHCommandService(
            sessionFactory: { _ in FakeWorkspaceSession() },
            hostResolver: { RemotePythonService.RemotePythonHost(id: $0, displayName: "h") },
            defaultHostProvider: { UUID() }
        )
        let tool = CloudWorkspaceGitPullTool(service: CloudWorkspaceService(ssh: ssh))
        for value in validIDs {
            try tool.validate(.init(hostID: nil, workspaceID: value, path: nil, message: nil, name: nil, port: nil))
        }
        for value in invalidIDs {
            #expect(throws: FloeError.self, Comment(rawValue: "should reject \(value.debugDescription)")) {
                try tool.validate(.init(hostID: nil, workspaceID: value, path: nil, message: nil, name: nil, port: nil))
            }
        }
    }

    @Test("client grammar stays identical to the bundled daemon valid_id guard")
    func daemonGrammarParity() throws {
        let source = try RemoteAgentPayload.agentSource()
        #expect(source.contains(#"re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}""#))
        // Runtime validation accepts exactly the same valid/invalid corpus as
        // the schema (proven in runtimeValidationAgreesWithSchema); this pins
        // the advertised pattern text to the documented intended grammar.
        let advertised = try decodedWorkspaceIDPattern(CloudWorkspaceGitPullTool.parametersJSON)
        #expect(advertised == Self.intendedPattern)
    }
}

private struct FakeWorkspaceSession: RemotePythonSession {
    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> SSHExecResult {
        SSHExecResult(stdout: "", stderr: "", exitCode: 0, truncated: false)
    }
}

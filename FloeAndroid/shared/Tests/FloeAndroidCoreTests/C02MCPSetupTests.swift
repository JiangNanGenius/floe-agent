// SPDX-License-Identifier: MPL-2.0
// Authored for unified qualification; NOT RUN during source implementation.
import Foundation
import XCTest
@testable import FloeAndroidCore
import FloeCore
import FloeTools

final class C02MCPSetupTests: XCTestCase {
    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    // MARK: - Draft / platform identity

    func testRemoteDraftUsesOriginalRulesAndSeparatesEmbeddedCredentials() {
        let valid = C02MCPSetupDraft(
            mode: .remoteHTTP,
            displayName: "Company tools",
            endpointText: "https://mcp.example.com/mcp",
            authentication: .bearerToken)
        XCTAssertTrue(C02MCPSetupPreflightLogic.evaluate(valid).isValid)
        XCTAssertNoThrow(try C02MCPSetupPreflightLogic.remoteConfiguration(from: valid))

        let embedded = C02MCPSetupDraft(
            mode: .remoteHTTP,
            displayName: "Company tools",
            endpointText: "https://user:secret@mcp.example.com/mcp")
        XCTAssertTrue(C02MCPSetupPreflightLogic.evaluate(embedded).findings.contains(.credentialInURL))

        let insecure = C02MCPSetupDraft(
            mode: .remoteHTTP,
            displayName: "LAN tools",
            endpointText: "http://192.168.1.10:8080/mcp")
        XCTAssertTrue(C02MCPSetupPreflightLogic.evaluate(insecure).findings.contains(.insecureHTTPDisabled))

        let badHeader = C02MCPSetupDraft(
            mode: .remoteHTTP,
            displayName: "Header tools",
            endpointText: "https://mcp.example.com/mcp",
            authentication: .customHeader,
            credentialHeaderName: "Mcp-Session-Id")
        XCTAssertTrue(C02MCPSetupPreflightLogic.evaluate(badHeader).findings.contains(.headerNameInvalid))
    }

    func testLinuxServiceDraftRequiresExplicitProjectEnvironmentAndPort() {
        let invalid = C02MCPSetupDraft(
            mode: .linuxService,
            displayName: "Service",
            portText: "80",
            details: "")
        let findings = C02MCPSetupPreflightLogic.evaluate(invalid).findings
        XCTAssertTrue(findings.contains(.projectRequired))
        XCTAssertTrue(findings.contains(.environmentRequired))
        XCTAssertTrue(findings.contains(.portInvalid))
        XCTAssertTrue(findings.contains(.serviceAuthenticationUnsupported))

        let valid = C02MCPSetupDraft(
            mode: .linuxService,
            displayName: "Service",
            authentication: .none,
            allowInsecureHTTP: true,
            projectID: UUID(),
            environmentID: "env-1",
            portText: "8080")
        XCTAssertTrue(C02MCPSetupPreflightLogic.evaluate(valid).isValid)
    }

    func testClientCompatibilityVersionIsIndependentOfPrerelease() {
        XCTAssertEqual(C02MCPSetupLimits.clientCompatibilityVersion, "0.1.0")
        XCTAssertEqual(C02MCPSetupLimits.clientPlatform, "android")
        XCTAssertNotEqual(C02MCPSetupLimits.clientCompatibilityVersion, "0.1.0-alpha.22")
    }

    // MARK: - Template / build plan

    func testTemplateDigestIsRejectedOnAnyByteChange() {
        XCTAssertThrowsError(try C02MCPSetupTemplateIdentity.verifyArchive(Data())) { error in
            XCTAssertEqual((error as? C02MCPSetupFailure)?.code, .templateDigestMismatch)
        }
        XCTAssertEqual(C02MCPSetupTemplateIdentity.immutableProjectDigests.count, 9)
        XCTAssertEqual(C02MCPSetupTemplateIdentity.archiveSHA256.count, 64)
    }

    func testBuildPlanKeepsTheThreeDependencyPhasesAndExactPayload() throws {
        let recordID = UUID()
        let steps = C02MCPSetupBuildPlan.initialSteps(recordID: recordID)
        XCTAssertEqual(steps.map(\.name), [.probe, .install, .compile, .test])
        let payload = try XCTUnwrap(C02MCPSetupBuildPlan.expectedPayload(
            recordID: recordID, step: .install,
            workspaceRelativePath: "MCPServices/record"))
        XCTAssertTrue(C02MCPSetupBuildPlan.payloadMatches(payload, expected: payload))
        let changed = try XCTUnwrap(C02MCPSetupBuildPlan.payload(
            command: "npm ci --ignore-scripts --no-audit --no-fund",
            cwd: "MCPServices/record/node-http",
            timeoutSeconds: 600,
            maximumOutputBytes: 262_144))
        XCTAssertFalse(C02MCPSetupBuildPlan.payloadMatches(changed, expected: payload))
    }

    func testResumeNeverReplaysACompletedPhaseOrAFailure() {
        let id = UUID()
        var steps = C02MCPSetupBuildPlan.initialSteps(recordID: id)
        steps[0].state = .completed
        steps[1].state = .running
        XCTAssertEqual(C02MCPSetupBuildPlan.nextAction(steps), .attach(1))
        steps[1].state = .failed
        XCTAssertEqual(C02MCPSetupBuildPlan.nextAction(steps), .attach(1))
        steps[1].state = .pending
        XCTAssertEqual(C02MCPSetupBuildPlan.nextAction(steps), .submit(1))
        for index in steps.indices { steps[index].state = .completed }
        XCTAssertEqual(C02MCPSetupBuildPlan.nextAction(steps), .allCompleted)
    }

    func testProbeBindsRealLinuxAndNodeAndNeverGuessesAndroidAbi() throws {
        let evidence = try C02MCPSetupBuildPlan.parseProbe("""
        FLOE_OS=Linux
        FLOE_ARCH=aarch64
        FLOE_NODE=v20.19.0
        FLOE_NPM=10.8.2
        """)
        XCTAssertEqual(evidence.os, "Linux")
        XCTAssertEqual(evidence.architecture, "aarch64")

        XCTAssertThrowsError(try C02MCPSetupBuildPlan.parseProbe("""
        FLOE_OS=Android
        FLOE_ARCH=arm64-v8a
        FLOE_NODE=v22.0.0
        FLOE_NPM=10.0.0
        """)) { error in
            XCTAssertEqual((error as? C02MCPSetupFailure)?.code, .platformMismatch)
        }
        XCTAssertThrowsError(try C02MCPSetupBuildPlan.parseProbe("""
        FLOE_OS=Linux
        FLOE_ARCH=aarch64
        FLOE_NODE=v20.18.9
        FLOE_NPM=10.0.0
        """)) { error in
            XCTAssertEqual((error as? C02MCPSetupFailure)?.code, .nodeVersionUnsupported)
        }
        XCTAssertThrowsError(try C02MCPSetupBuildPlan.parseProbe("FLOE_OS=Linux")) { error in
            XCTAssertEqual((error as? C02MCPSetupFailure)?.code, .dependencyProbeMissing)
        }
    }

    // MARK: - Stdio framing

    func testStdioClientNegotiatesListsPagesAndCallsTheFixedStatusTool() async throws {
        let pipe = MockStdioPipe { request in
            let method = request["method"] as? String
            let responseID: Any = (request["id"] as? Int) ?? 0
            switch method {
            case "initialize":
                return [
                    "jsonrpc": "2.0", "id": responseID,
                    "result": [
                        "protocolVersion": "2025-06-18",
                        "capabilities": [:] as [String: Any],
                        "serverInfo": ["name": "mock", "version": "1"],
                    ],
                ]
            case "notifications/initialized":
                return nil
            case "tools/list":
                let params = request["params"] as? [String: Any] ?? [:]
                if params["cursor"] == nil {
                    return [
                        "jsonrpc": "2.0", "id": responseID,
                        "result": [
                            "tools": [[
                                "name": "service_status",
                                "description": "status",
                                "inputSchema": ["type": "object"],
                                "annotations": ["readOnlyHint": true],
                            ]],
                            "nextCursor": "page-2",
                        ],
                    ]
                }
                return [
                    "jsonrpc": "2.0", "id": responseID,
                    "result": ["tools": [[String: Any]]()],
                ]
            case "tools/call":
                return [
                    "jsonrpc": "2.0", "id": responseID,
                    "result": [
                        "content": [[
                            "type": "text",
                            "text": #"{"status":"ready","service":"floe-mcp-service","label":"floe-native-verification"}"#,
                        ]],
                        "isError": false,
                    ],
                ]
            default:
                return ["jsonrpc": "2.0", "id": responseID, "error": ["code": -32601, "message": "unknown"]]
            }
        }
        let config = C02MCPSetupStdioConfig(
            projectID: UUID(), environmentID: "env",
            rootIdentity: String(repeating: "b", count: 64),
            taskID: UUID(), serverRevision: 1,
            displayName: "Mock", command: "node",
            arguments: ["server.js"], cwdRelative: "MCPServices/mock/node-http")
        let client = C02MCPStdioClient(config: config, channel: pipe, isLive: { true })
        let revision = try await client.initialize()
        XCTAssertEqual(revision, "2025-06-18")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.remoteName), ["service_status"])
        let output = try await client.callTool(
            name: "service_status",
            argumentsJSON: Data(#"{"label":"floe-native-verification"}"#.utf8))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("\"status\":\"ready\""))
        await client.close()
    }

    func testStdioEchoIsNotAcceptedAsAJsonRpcPeer() async throws {
        let pipe = MockStdioPipe { request in request }
        let config = C02MCPSetupStdioConfig(
            projectID: UUID(), environmentID: "env",
            rootIdentity: String(repeating: "b", count: 64),
            taskID: nil, serverRevision: 1,
            displayName: "Echo", command: "node",
            arguments: [], cwdRelative: "MCPServices/echo/node-http")
        let client = C02MCPStdioClient(config: config, channel: pipe, isLive: { true })
        do {
            _ = try await client.initialize()
            XCTFail("A PTY echo must not satisfy the stdio transport")
        } catch let failure as C02MCPSetupFailure {
            XCTAssertEqual(failure.code, .stdioResponseInvalid)
        }
    }

    func testStdioRefusesWhenTheTaskOrRevisionIsNoLongerLive() async {
        let pipe = MockStdioPipe { _ in nil }
        let config = C02MCPSetupStdioConfig(
            projectID: UUID(), environmentID: "env",
            rootIdentity: String(repeating: "b", count: 64),
            taskID: nil, serverRevision: 1,
            displayName: "Dead", command: "node",
            arguments: [], cwdRelative: "MCPServices/dead/node-http")
        let client = C02MCPStdioClient(config: config, channel: pipe, isLive: { false })
        do {
            _ = try await client.initialize()
            XCTFail("A retired configuration must not start a stdio request")
        } catch let failure as C02MCPSetupFailure {
            XCTAssertEqual(failure.code, .stdioUnavailable)
        }
    }

    // MARK: - Original factory / config / lifecycle wiring

    private func stdioBinding(workingDirectory: String = "MCPServices/mock/node-http")
        -> MCPServerConfiguration.StdioBinding {
        MCPServerConfiguration.StdioBinding(
            projectID: UUID(),
            environmentID: "env-1",
            rootIdentity: String(repeating: "d", count: 64),
            taskID: UUID(),
            revision: 7,
            command: "node",
            arguments: ["server.mjs"],
            workingDirectory: workingDirectory)
    }

    private func stdioConfiguration() -> MCPServerConfiguration {
        MCPServerConfiguration(displayName: "Stdio mock",
                               transport: .stdio,
                               stdioBinding: stdioBinding())
    }

    func testOriginalFactorySelectsTheInjectedStdioAdapterAndRefusesWithoutTheLane() async throws {
        let configuration = stdioConfiguration()
        XCTAssertNoThrow(try configuration.validate())
        let pipe = MockStdioPipe { request in
            let id: Any = (request["id"] as? Int) ?? 0
            switch request["method"] as? String {
            case "initialize":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["protocolVersion": "2025-06-18",
                                   "capabilities": [:] as [String: Any]]]
            case "notifications/initialized":
                return nil
            case "tools/list":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["tools": [[
                            "name": "service_status", "description": "status",
                            "inputSchema": ["type": "object"],
                            "annotations": ["readOnlyHint": true],
                        ]] as [[String: Any]]]]
            case "tools/call":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["content": [[
                            "type": "text",
                            "text": #"{"status":"ready"}"#,
                        ]] as [[String: Any]], "isError": false]]
            default:
                return ["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32601, "message": "unknown"]]
            }
        }
        let maker = ScriptedStdioMaker { _, _ in
            try C02MCPStdioTransport(configuration: configuration,
                                     binding: try XCTUnwrap(configuration.stdioBinding),
                                     channel: pipe,
                                     isLive: { true })
        }
        let factory = OriginalMCPClientFactory(stdio: maker)
        let client = try await factory.make(configuration: configuration, credential: nil)
        let tools = try await client.discoverTools()
        XCTAssertEqual(tools.map(\.remoteName), ["service_status"])
        let output = try await client.callTool(name: "service_status",
                                               argumentsJSON: Data("{}".utf8))
        XCTAssertEqual(output.exitStatus, 0)
        await client.disconnectTransport()
        XCTAssertEqual(pipe.stderrDrainCount, 1)

        let noLane = OriginalMCPClientFactory()
        do {
            _ = try await noLane.make(configuration: configuration, credential: nil)
            XCTFail("A stdio configuration must not be served without the C01 pipe port")
        } catch let error as MCPClientError {
            guard case .transportUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOriginalFactoryKeepsTheHTTPPathOnTheOriginalClient() async throws {
        let configuration = MCPServerConfiguration(
            displayName: "HTTP mock",
            endpoint: URL(string: "https://mcp.example.invalid/mcp")!,
            allowInsecureHTTP: false)
        let factory = OriginalMCPClientFactory(stdio: nil)
        let client = try await factory.make(configuration: configuration, credential: nil)
        XCTAssertTrue(client is MCPRemoteClient)
        await client.disconnectTransport()
    }

    func testStdioConfigurationRoundTripsAndLegacyRowsRemainHTTP() throws {
        let legacy = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","displayName":"Old",
         "endpoint":"https://mcp.example.invalid/mcp","enabled":true,
         "allowInCanvas":false,"allowInsecureHTTP":false,
         "authentication":"none","credentialHeaderName":"Authorization",
         "timeoutSeconds":30,"disabledRemoteToolNames":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: legacy)
        XCTAssertEqual(decoded.transport, .streamableHTTP)
        XCTAssertNil(decoded.stdioBinding)
        XCTAssertEqual(decoded.endpoint?.absoluteString, "https://mcp.example.invalid/mcp")

        let stdio = stdioConfiguration()
        let roundTrip = try JSONDecoder().decode(
            MCPServerConfiguration.self, from: JSONEncoder().encode(stdio))
        XCTAssertEqual(roundTrip, stdio)
        XCTAssertNil(roundTrip.endpoint)

        var escaped = stdio
        escaped.stdioBinding?.workingDirectory = "../outside"
        XCTAssertThrowsError(try escaped.validate())
    }

    func testStdioAdapterDropsRequestsAfterCloseAndDrainsSeparatedStderr() async throws {
        let configuration = stdioConfiguration()
        let pipe = MockStdioPipe { request in
            let id: Any = (request["id"] as? Int) ?? 0
            if request["method"] as? String == "initialize" {
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["protocolVersion": "2025-06-18",
                                   "capabilities": [:] as [String: Any]]]
            }
            if request["method"] as? String == "notifications/initialized" { return nil }
            return ["jsonrpc": "2.0", "id": id,
                    "result": ["tools": [[String: Any]]()]]
        }
        pipe.stderr = Data("diagnostic line".utf8)
        let transport = try C02MCPStdioTransport(
            configuration: configuration,
            binding: try XCTUnwrap(configuration.stdioBinding),
            channel: pipe,
            isLive: { true })
        _ = try await transport.discoverTools()
        await transport.disconnectTransport()
        XCTAssertEqual(pipe.stderrDrainCount, 1)
        do {
            _ = try await transport.callTool(name: "service_status",
                                             argumentsJSON: Data("{}".utf8))
            XCTFail("A closed stdio transport must not dispatch")
        } catch let error as MCPClientError {
            guard case .disconnected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStdioClientHonorsTaskCancellationDuringARead() async throws {
        let pipe = BlockingStdioPipe()
        let config = C02MCPSetupStdioConfig(
            projectID: UUID(), environmentID: "env",
            rootIdentity: String(repeating: "e", count: 64),
            taskID: nil, serverRevision: 1,
            displayName: "Blocked", command: "node",
            arguments: [], cwdRelative: "MCPServices/blocked/node-http")
        let client = C02MCPStdioClient(config: config, channel: pipe, isLive: { true })
        let task = Task { try await client.initialize(timeout: 30) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not be reported as a completed handshake")
        } catch is CancellationError {
            // Expected: the bounded read observed task cancellation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        await client.close()
    }

    func testStdioClientRefusesALateReplyAfterTheLiveBindingChanges() async throws {
        let live = LiveFlag(true)
        let pipe = MockStdioPipe { request in
            let id: Any = (request["id"] as? Int) ?? 0
            if request["method"] as? String == "initialize" {
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["protocolVersion": "2025-06-18",
                                   "capabilities": [:] as [String: Any]]]
            }
            if request["method"] as? String == "notifications/initialized" { return nil }
            return ["jsonrpc": "2.0", "id": id,
                    "result": ["tools": [[String: Any]]()]]
        }
        let config = C02MCPSetupStdioConfig(
            projectID: UUID(), environmentID: "env",
            rootIdentity: String(repeating: "f", count: 64),
            taskID: nil, serverRevision: 2,
            displayName: "Fenced", command: "node",
            arguments: [], cwdRelative: "MCPServices/fenced/node-http")
        let client = C02MCPStdioClient(config: config, channel: pipe,
                                       isLive: { live.value })
        _ = try await client.initialize()
        live.value = false
        do {
            _ = try await client.listTools()
            XCTFail("A changed live binding must fence the next request")
        } catch let failure as C02MCPSetupFailure {
            XCTAssertEqual(failure.code, .stdioUnavailable)
        }
    }

    func testOriginalMCPDomainConsumesTheStdioAdapterThroughSaveConnectAndDisconnect() async throws {
        let fixture = try await RB6TestFixture.make(id: "c02-mcp-stdio")
        let gateway = RB6ScriptedGateway(registered: true)
        let registry = ToolRunnerRegistry()
        let configuration = stdioConfiguration()
        let pipe = MockStdioPipe { request in
            let id: Any = (request["id"] as? Int) ?? 0
            switch request["method"] as? String {
            case "initialize":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["protocolVersion": "2025-06-18",
                                   "capabilities": [:] as [String: Any]]]
            case "notifications/initialized":
                return nil
            case "tools/list":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["tools": [[
                            "name": "service_status", "description": "status",
                            "inputSchema": ["type": "object"],
                            "annotations": ["readOnlyHint": true],
                        ]] as [[String: Any]]]]
            case "tools/call":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["content": [[
                            "type": "text",
                            "text": #"{"status":"ready","service":"floe-mcp-service"}"#,
                        ]] as [[String: Any]], "isError": false]]
            default:
                return ["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32601, "message": "unknown"]]
            }
        }
        let maker = ScriptedStdioMaker { _, _ in
            try C02MCPStdioTransport(configuration: configuration,
                                     binding: try XCTUnwrap(configuration.stdioBinding),
                                     channel: pipe,
                                     isLive: { true })
        }
        let domain = MCPDomain(services: .init(
            database: fixture.database,
            gateway: gateway,
            routeContext: RB6RouteContext(token: "route-c02-stdio", generation: fixture.epoch),
            transportAdmission: StdioOnlyAdmission(),
            clientFactory: OriginalMCPClientFactory(stdio: maker),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: registry,
            hostContext: fixture.hostContext))
        let binding = try XCTUnwrap(configuration.stdioBinding)
        let candidate: [String: Any] = [
            "id": configuration.id.uuidString,
            "displayName": configuration.displayName,
            "transport": "stdio",
            "authentication": "none",
            "enabled": true,
            "allowInCanvas": false,
            "stdio": [
                "projectID": binding.projectID.uuidString,
                "environmentID": binding.environmentID,
                "rootIdentity": binding.rootIdentity,
                "taskID": binding.taskID?.uuidString ?? NSNull(),
                "revision": Int(binding.revision),
                "command": binding.command,
                "arguments": binding.arguments,
                "workingDirectory": binding.workingDirectory,
            ] as [String: Any],
            "createIntent": true,
        ]
        let candidateData = try JSONSerialization.data(withJSONObject: candidate,
                                                       options: [.sortedKeys])
        let saved = await domain.save(candidateJSON: candidateData,
                                      secretIntent: "clear",
                                      envelopeRevision: nil)
        XCTAssertEqual(saved["state"] as? String, "committed")
        let savedConnect = try XCTUnwrap(saved["connect"] as? [String: Any])
        XCTAssertEqual(savedConnect["state"] as? String, "connected",
                       "The original save/connect path must consume the stdio adapter")

        let listed = try await domain.list(cursor: nil)
        let row = try XCTUnwrap((listed["servers"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["transport"] as? String, "stdio")
        XCTAssertEqual(row["toolCount"] as? Int, 1)
        let revision = try XCTUnwrap(row["revision"] as? [String: Any])
        let disconnected = await domain.disconnect(
            serverID: configuration.id,
            revision: ConfigRevision(
                resourceID: try XCTUnwrap(revision["resourceID"] as? String),
                version: try XCTUnwrap(revision["version"] as? String)))
        XCTAssertEqual(disconnected["state"] as? String, "disconnected")
        XCTAssertEqual(pipe.stderrDrainCount, 1,
                       "Disconnect must drain the separated stderr stream")
    }

    func testOriginalSaveCandidateAcceptsASecretFreeStdioBinding() throws {
        let serverID = UUID()
        let projectID = UUID()
        let candidate = try MCPDomain.MCPSaveCandidate.parse([
            "id": serverID.uuidString,
            "displayName": "Stdio saved",
            "transport": "stdio",
            "authentication": "none",
            "stdio": [
                "projectID": projectID.uuidString,
                "environmentID": "env-1",
                "rootIdentity": String(repeating: "a", count: 64),
                "command": "node",
                "arguments": ["server.mjs"],
                "workingDirectory": "MCPServices/stdio",
                "revision": 3,
            ] as [String: Any],
            "createIntent": true,
        ])
        let configuration = candidate.makeConfiguration()
        XCTAssertEqual(configuration.transport, .stdio)
        XCTAssertNil(configuration.endpoint)
        XCTAssertEqual(configuration.authentication, .none)
        XCTAssertNoThrow(try configuration.validate())

        XCTAssertThrowsError(try MCPDomain.MCPSaveCandidate.parse([
            "id": UUID().uuidString,
            "displayName": "Bad stdio",
            "transport": "stdio",
            "authentication": "bearerToken",
            "stdio": [
                "projectID": projectID.uuidString,
                "environmentID": "env-1",
                "rootIdentity": String(repeating: "a", count: 64),
                "command": "node",
            ] as [String: Any],
        ]))
    }

    func testRemoteToolRegistrationCallsThroughTheStdioAdapter() async throws {
        let configuration = stdioConfiguration()
        let pipe = MockStdioPipe { request in
            let id: Any = (request["id"] as? Int) ?? 0
            switch request["method"] as? String {
            case "initialize":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["protocolVersion": "2025-06-18",
                                   "capabilities": [:] as [String: Any]]]
            case "notifications/initialized":
                return nil
            case "tools/call":
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["content": [[
                            "type": "text",
                            "text": #"{"status":"ready","service":"floe-mcp-service"}"#,
                        ]] as [[String: Any]], "isError": false]]
            default:
                return ["jsonrpc": "2.0", "id": id,
                        "result": ["tools": [[
                            "name": "service_status", "description": "status",
                            "inputSchema": ["type": "object"],
                            "annotations": ["readOnlyHint": true],
                        ]] as [[String: Any]]]]
            }
        }
        let transport = try C02MCPStdioTransport(
            configuration: configuration,
            binding: try XCTUnwrap(configuration.stdioBinding),
            channel: pipe,
            isLive: { true })
        let tools = try await transport.discoverTools()
        let registry = ToolRunnerRegistry()
        MCPRemoteToolSource.register(configuration: configuration,
                                     client: transport,
                                     tools: tools,
                                     registry: registry)
        let localName = MCPRemoteToolSource.namespacedName(
            prefix: configuration.namespacePrefix + "_",
            remoteName: "service_status")
        let runner = try XCTUnwrap(registry.runner(named: localName))
        let context = ToolContext(runID: UUID(), toolCallID: "call-1",
                                  scope: .local,
                                  cancellation: CancellationToken(),
                                  conversationID: UUID())
        let output = try await runner.run(Data("{}".utf8), context)
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("\"status\":\"ready\""))
        MCPRemoteToolSource.unregister(configuration: configuration, registry: registry)
        XCTAssertNil(registry.runner(named: localName))
        await transport.disconnectTransport()
    }

    // MARK: - Record semantics

    func testSetupRecordKeepsTheC01RevisionWithoutPersistingARootPath() throws {
        let revision = "2026-11-02 10:00:00.123"
        let record = C02MCPSetupRecord(
            draft: C02MCPSetupDraft(mode: .linuxService, displayName: "S",
                                    authentication: .none, allowInsecureHTTP: true,
                                    projectID: UUID(), environmentID: "env",
                                    portText: "8080"),
            projectID: UUID(), projectName: "P", projectRevision: revision,
            environmentID: "env", environmentLabel: "Linux",
            containerID: "container", baseRevision: "base",
            rootIdentity: String(repeating: "c", count: 64))
        let decoded = try JSONDecoder().decode(
            C02MCPSetupRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.projectRevision, revision)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("/Volumes/"))
    }

    func testBusyPhasesAreNotTerminalAndARecordNeverStoresARootPath() {
        let record = C02MCPSetupRecord(
            draft: C02MCPSetupDraft(mode: .linuxService, displayName: "S",
                                    authentication: .none, allowInsecureHTTP: true,
                                    projectID: UUID(), environmentID: "env",
                                    portText: "8080"),
            projectID: UUID(), projectName: "P",
            environmentID: "env", environmentLabel: "Linux",
            containerID: "container", baseRevision: "base",
            rootIdentity: String(repeating: "c", count: 64))
        XCTAssertTrue(record.phase.isBusy)
        XCTAssertFalse(record.phase == .added)
        let encoded = try? JSONEncoder().encode(record)
        XCTAssertNotNil(encoded)
        let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("secret"))
    }
}

// MARK: - Scripted separated pipe (test-only; no PTY emulation)

private final class MockStdioPipe: C02MCPSetupStdioChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (([String: Any]) -> [String: Any]?)
    private var responses: [Data] = []
    var stderr = Data()
    private(set) var stderrDrainCount = 0

    init(handler: @escaping ([String: Any]) -> [String: Any]?) {
        self.handler = handler
    }

    func write(_ data: Data) async throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        if let response = handler(object),
           let encoded = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
            lock.lock()
            responses.append(encoded)
            lock.unlock()
        }
    }

    func readLine(maxBytes: Int, timeout: TimeInterval) async throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }

    func drainStderr(maxBytes: Int) async -> Data {
        lock.lock(); defer { lock.unlock() }
        stderrDrainCount += 1
        return Data(stderr.prefix(maxBytes))
    }

    func close() async {}
}

private final class BlockingStdioPipe: C02MCPSetupStdioChannel, @unchecked Sendable {
    func write(_ data: Data) async throws {}

    func readLine(maxBytes: Int, timeout: TimeInterval) async throws -> Data? {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return nil
    }

    func drainStderr(maxBytes: Int) async -> Data { Data() }

    func close() async {}
}

private final class LiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private struct StdioOnlyAdmission: MCPTransportAdmitting {
    var admitsMCPNetwork: Bool { false }
    var admitsMCPStdio: Bool { true }
}

private struct ScriptedStdioMaker: MCPStdioClientMaking {
    let make: @Sendable (MCPServerConfiguration, String?) async throws -> any MCPClientTransporting

    init(_ make: @escaping @Sendable (MCPServerConfiguration, String?) async throws -> any MCPClientTransporting) {
        self.make = make
    }

    func makeClient(configuration: MCPServerConfiguration,
                    credential: String?) async throws -> any MCPClientTransporting {
        try await make(configuration, credential)
    }
}

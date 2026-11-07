// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import GRDB
import FloePersistence
import FloeToolboxCore
@testable import FloeApp

@Suite("Toolbox connection input feedback", .serialized)
@MainActor struct ToolboxConnectionInputTests {
    @Test func missingAndMalformedFieldsIdentifyTheirActualControl() throws {
        var setup = ToolboxConnectionSetup()
        #expect(setup.inputIssues(for: .webSocket) == [.webSocketURLRequired])
        #expect(setup.inputIssues(for: .mqtt) == [.addressRequired, .portRequired])
        #expect(setup.inputIssues(for: .mqtt).map(\.field) == [.address, .port])
        setup.address = "broker.example.test"
        for value in ["0", "65536", "-1", "1.5", "port", "1883 "] {
            setup.port = value
            #expect(setup.inputIssues(for: .mqtt) == [.invalidPort])
        }
        setup.port = "1883"
        for host in ["mqtt://broker.example.test", "user@broker.example.test", "broker host", "broker.example.test/path"] {
            setup.address = host
            #expect(setup.inputIssues(for: .mqtt) == [.invalidHost])
        }
        for address in ["https://example.test", "ws://", "ws://example.test:0", "ws://example.test:65536", "ws://user:password@example.test", "wss://example.test/#fragment"] {
            setup.address = address
            #expect(setup.inputIssues(for: .webSocket) == [.invalidWebSocketURL])
        }
    }

    @Test func validNativeTargetsKeepTheirExactAddressAndSeparatePort() throws {
        var setup = ToolboxConnectionSetup()
        for address in ["ws://127.0.0.1:8080/socket", "wss://example.test/socket?access_token=synthetic", "ws://[::1]:8080/socket"] {
            setup.address = address
            #expect(setup.inputIssues(for: .webSocket).isEmpty)
            let endpoint = try SerialEndpoint(title: "WS", transport: .webSocket, wireProtocol: .webSocketMessage, host: address)
            #expect(endpoint.host == address)
        }
        for host in ["broker.example.test", "127.0.0.1", "::1"] {
            for port in ["1", "1883", "8883", "65535"] {
                setup.address = host; setup.port = port
                #expect(setup.inputIssues(for: .mqtt).isEmpty)
                let endpoint = try SerialEndpoint(title: "MQTT", transport: .tcp, wireProtocol: .mqtt5, host: host, port: Int(port))
                #expect(endpoint.host == host && endpoint.port == Int(port))
            }
        }
    }

    @Test func actualOpenAndCenterRejectInputWithoutCreatingCapturesOrStartingSessions() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolboxInvalidInput-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ToolboxCaptureStore(database: environment.database, exportRoot: root)
        _ = try await repository.summaries() // Prepare the real existing SQLite schema before the snapshot.
        func counts() async throws -> [Int] {
            try await environment.database.reader { db in
                [try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM toolbox_captures") ?? 0,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM toolbox_capture_index") ?? 0]
            }
        }
        let before = try await counts()
        let center = ToolboxCenter(environment: environment)
        var setup = ToolboxConnectionSetup()
        for (tool, expected) in [(ToolboxTool.webSocket, ToolboxConnectionInputIssue.webSocketURLRequired), (.mqtt, .addressRequired)] {
            center.connect(tool, setup: setup)
            #expect(center.connecting.isEmpty && center.connections.isEmpty)
            #expect(center.failures[tool] == expected.localizedDescription)
            do {
                _ = try await ToolboxConnection.open(tool: tool, setup: setup, environment: environment)
                Issue.record("An empty connection opened instead of reporting its field")
            } catch let issue as ToolboxConnectionInputIssue {
                #expect(issue == expected && issue.field == .address)
            }
        }
        setup.address = "127.0.0.1"; setup.port = "0"
        center.connect(.mqtt, setup: setup)
        #expect(center.connecting.isEmpty && center.connections.isEmpty)
        do {
            _ = try await ToolboxConnection.open(tool: .mqtt, setup: setup, environment: environment)
            Issue.record("An invalid port reached a connection")
        } catch let issue as ToolboxConnectionInputIssue {
            #expect(issue == .invalidPort && issue.field == .port)
        }
        #expect(try await counts() == before)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
#endif

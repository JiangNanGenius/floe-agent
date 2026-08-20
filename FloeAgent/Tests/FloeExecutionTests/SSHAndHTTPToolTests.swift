import Foundation
import Testing
import FloeCore
import FloeTools
import FloeSSH
@testable import FloeExecution

@Suite("FloeExecution.SSHExec & HTTPRequest")
struct SSHAndHTTPToolTests {

    // MARK: - ssh.execute

    @Test("ssh.execute descriptor is side-effecting and remote")
    func sshDescriptor() {
        #expect(SSHExecTool.name == "ssh.execute")
        #expect(SSHExecTool.isSideEffecting)
        #expect(SSHExecTool.riskLabels.contains(.executesRemoteCommand))
    }

    @Test("ssh.execute maps a successful command result")
    func sshSuccess() async throws {
        let hostID = UUID()
        let service = SSHCommandService(
            sessionFactory: { _ in FakeSession(result: SSHExecResult(stdout: "hello", stderr: "", exitCode: 0, truncated: false)) },
            hostResolver: { _ in RemotePythonService.RemotePythonHost(id: UUID(), displayName: "h") },
            defaultHostProvider: { UUID() }
        )
        let tool = SSHExecTool(service: service)
        let output = try await tool.execute(
            .init(command: "ls", hostID: hostID.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("hello"))
    }

    @Test("ssh.execute maps timeout to exit 124")
    func sshTimeout() async throws {
        let hostID = UUID()
        let service = SSHCommandService(
            sessionFactory: { _ in FakeSession(error: SSHExecError.timedOut) },
            hostResolver: { _ in RemotePythonService.RemotePythonHost(id: UUID(), displayName: "h") },
            defaultHostProvider: { UUID() }
        )
        let tool = SSHExecTool(service: service)
        let output = try await tool.execute(
            .init(command: "sleep 100", hostID: hostID.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 124)
    }

    @Test("ssh.execute rejects an invalid hostID")
    func sshValidation() async {
        let tool = SSHExecTool(service: SSHCommandService(
            sessionFactory: { _ in FakeSession(result: .init(stdout: "", stderr: "", exitCode: 0, truncated: false)) },
            hostResolver: { _ in RemotePythonService.RemotePythonHost(id: UUID(), displayName: "h") },
            defaultHostProvider: { UUID() }
        ))
        #expect(throws: FloeError.self) {
            try tool.validate(.init(command: "ls", hostID: "not-a-uuid"))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(command: "ls"))
        }
    }

    // MARK: - network.http

    @Test("network.http descriptor is network-flagged")
    func httpDescriptor() {
        #expect(HTTPRequestTool.name == "network.http")
        #expect(HTTPRequestTool.isSideEffecting)
        #expect(HTTPRequestTool.riskLabels.contains(.networkAccess))
    }

    @Test("network.http rejects a non-http scheme")
    func httpValidation() async {
        let tool = HTTPRequestTool()
        #expect(throws: FloeError.self) {
            try tool.validate(.init(url: "file:///etc/passwd"))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(url: "not a url"))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(url: "http://example.com"))
        }
    }

    @Test("network.http rejects loopback and private literal targets")
    func httpRejectsPrivateTargets() async {
        let tool = HTTPRequestTool()
        for value in [
            "https://localhost/status",
            "https://127.0.0.1/status",
            "https://10.0.0.1/status",
            "https://169.254.169.254/latest/meta-data",
            "https://[::1]/status"
        ] {
            #expect(throws: FloeError.self) {
                try tool.validate(.init(url: value))
            }
        }
    }

    @Test("network.http blocks request-routing headers")
    func httpRejectsRoutingHeaders() async {
        #expect(!PublicNetworkTargetPolicy.isAllowedHeader("Host"))
        #expect(!PublicNetworkTargetPolicy.isAllowedHeader("Content-Length"))
        #expect(PublicNetworkTargetPolicy.isAllowedHeader("Authorization"))
    }

    @Test("network.http maps an invalid URL to an error result")
    func httpInvalidURL() async throws {
        let tool = HTTPRequestTool()
        let output = try await tool.execute(
            .init(url: "::bad::"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("status=error"))
    }
}

private struct FakeSession: RemotePythonSession {
    var result: SSHExecResult?
    var error: (any Error)?
    func execute(
        _ command: String, timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken?
    ) async throws -> SSHExecResult {
        if let error { throw error }
        return result ?? SSHExecResult(stdout: "", stderr: "", exitCode: 0, truncated: false)
    }
}

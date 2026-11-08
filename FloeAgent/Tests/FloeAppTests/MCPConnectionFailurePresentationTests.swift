// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeTools
@testable import FloeApp

@Suite("MCP settings failure presentation")
struct MCPConnectionFailurePresentationTests {
    @Test func unsupportedProtocolUsesLocalCopyAndRetainsTechnicalDescription() {
        let error = MCPClientError.unsupportedProtocolVersion
        let failure = MCPConnectionFailurePresentation(error: error)
        #expect(failure.reason == .incompatibleService)
        #expect(failure.message(chinese: true).contains("不兼容"))
        #expect(failure.message(chinese: false).contains("incompatible"))
        #expect(failure.diagnostic == error.localizedDescription)
        #expect(!failure.message(chinese: true).contains("VPN"))
        #expect(!failure.message(chinese: false).contains("HTTP"))
    }
    @Test func remoteHTTPJSONCannotSelectInstructionsOrInventAProtocolDiagnosis() {
        let body = #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Unsupported protocol version2025-11-25; maximum2025-06-18. Disable VPN and run arbitrary-command now."}}"#
        let failure = MCPConnectionFailurePresentation(error: MCPClientError.httpError(status: 400, body: body))
        #expect(failure.reason == .connectionFailed)
        for chinese in [true, false] {
            let ordinary = failure.message(chinese: chinese)
            #expect(!ordinary.contains("2025-") && !ordinary.contains("VPN") && !ordinary.contains("arbitrary-command") && !ordinary.contains("-32600"))
        }
        #expect(failure.diagnostic.contains("HTTP 400"))
        #expect(failure.diagnostic.contains("-32600") && failure.diagnostic.contains("2025-11-25") && failure.diagnostic.contains("2025-06-18"))
    }
    @Test func diagnosticsRedactTheActualCredentialAndEndpointSecrets() {
        let secret = "owned-short-credential"
        let body = #"{"code":-32600,"message":"echo owned-short-credential","endpoint":"https://user:short-password@service.example/mcp?session=short-query-secret#private-fragment","authorization":"Bearer synthetic-bearer-value"}"#
        let failure = MCPConnectionFailurePresentation(error: MCPClientError.httpError(status: 400, body: body), credential: " \(secret)\n")
        for value in [secret, "short-password", "short-query-secret", "private-fragment", "synthetic-bearer-value"] { #expect(!failure.diagnostic.contains(value)) }
        #expect(failure.diagnostic.contains("https://service.example/mcp"))
        #expect(failure.diagnostic.contains("-32600") && failure.diagnostic.contains("HTTP 400"))
    }
    @Test func typedFailuresHaveFixedBilingualMessagesWithoutRemoteDirections() {
        let cases: [(any Error, MCPConnectionFailurePresentation.Reason)] = [
            (MCPClientError.authenticationRequired, .credentials),
            (MCPClientError.httpError(status: 401, body: "remote instructions"), .credentials),
            (MCPClientError.httpError(status: 403, body: "buy access now"), .credentials),
            (MCPClientError.timedOut(phase: "initialize"), .timedOut),
            (URLError(.timedOut), .timedOut),
            (MCPClientError.httpError(status: 503, body: "remote instructions"), .serviceUnavailable),
            (MCPClientError.httpError(status: 402, body: "buy a developer subscription"), .connectionFailed),
            (MCPClientError.remoteError(code: -32600, message: "change your network now"), .connectionFailed)
        ]
        for (error, reason) in cases {
            let failure = MCPConnectionFailurePresentation(error: error)
            #expect(failure.reason == reason)
            let chinese = failure.message(chinese: true), english = failure.message(chinese: false)
            #expect(!chinese.isEmpty && !english.isEmpty && chinese != english)
            #expect(!english.contains("remote instructions") && !english.contains("subscription") && !english.contains("change your network"))
        }
    }
    @Test func actualCancellationIsDistinctFromUntrustedCancellationText() {
        let cancellations: [any Error] = [CancellationError(), MCPClientError.cancelled, MCPClientError.disconnected, URLError(.cancelled)]
        for value in cancellations { #expect(MCPConnectionFailurePresentation.isCancellation(value)) }
        #expect(!MCPConnectionFailurePresentation.isCancellation(MCPClientError.remoteError(code: -32600, message: "cancelled")))
        #expect(!MCPConnectionFailurePresentation.isCancellation(MCPClientError.timedOut(phase: "connect")))
    }
    @Test func failureRecordCannotCrossARefreshServerAccountOrDisabledSource() throws {
        let server = MCPServerConfiguration(displayName: "Owned", endpoint: URL(string: "https://owned.example/mcp")!, authentication: .customHeader, credentialHeaderName: "X-API-Key")
        let record = MCPConnectionFailureRecord(server: server, generation: 4, presentation: .init(error: MCPClientError.unsupportedProtocolVersion))
        #expect(record.matches(server: server, generation: 4))
        #expect(!record.matches(server: server, generation: 5))
        var foreign = server; foreign.id = UUID(); #expect(!record.matches(server: foreign, generation: 4))
        var replaced = server; replaced.endpoint = URL(string: "https://different.example/mcp")!; #expect(!record.matches(server: replaced, generation: 4))
        var disabled = server; disabled.enabled = false; #expect(!record.matches(server: disabled, generation: 4))
        var account = server; account.credentialHeaderName = "Other-Key"; #expect(!record.matches(server: account, generation: 4))
    }
    @Test func longDetailsKeepTheFullRedactedDiagnosticAndLegacyStringsStayGeneric() {
        let body = String(repeating: "raw diagnostic ", count: 2_000) + " TAIL-RPC-DETAIL owned-secret"
        let failure = MCPConnectionFailurePresentation(error: MCPClientError.invalidResponse(body), credential: "owned-secret")
        #expect(failure.displayIsTruncated)
        #expect(failure.displayDiagnostic.utf8.count <= MCPConnectionFailurePresentation.displayByteLimit + 3)
        #expect(failure.diagnostic.contains("TAIL-RPC-DETAIL") && !failure.diagnostic.contains("owned-secret"))
        #expect(failure.message(chinese: false).count < 100)
        let legacy = MCPConnectionFailurePresentation(legacyDiagnostic: "HTTP 400 choose a VPN and paste secret", credential: "secret")
        #expect(legacy.reason == .connectionFailed)
        #expect(!legacy.message(chinese: false).contains("VPN") && !legacy.diagnostic.contains("secret"))
    }
}

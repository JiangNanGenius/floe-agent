import Foundation
import Testing
import FloeCore
import FloeTools
import FloeSSH
@testable import FloeExecution

@Suite("FloeExecution.SSHShell")
struct SSHShellToolTests {

    private struct FakePTYBackend {
        var script: [Data]
    }

    /// Builds a service whose direct factory fails (no hosts), driving tests
    /// through the guardian client only.
    private func makeGuardianService(
        outputs: [String],
        aliveSequence: [Bool] = []
    ) -> (InteractiveShellSessionService, Recorder) {
        let recorder = Recorder()
        let guardian = GuardianShellClient(
            open: { _, _, _, _ in
                await recorder.log("open")
                return (shellID: "shell-1", output: Data((outputs.first ?? "").utf8), alive: true)
            },
            io: { _, shellID, input, _, _, _ in
                await recorder.log("io:\(shellID):\(input.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")
                let index = await recorder.ioCount - 1
                let text = index + 1 < outputs.count ? outputs[index + 1] : ""
                let alive = index < aliveSequence.count ? aliveSequence[index] : true
                return (output: Data(text.utf8), alive: alive)
            },
            close: { _, shellID in
                await recorder.log("close:\(shellID)")
            }
        )
        let service = InteractiveShellSessionService(
            directFactory: { _, _, _, _ in throw RemotePythonError.noHostConfigured },
            defaultHostProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000001") },
            guardian: guardian
        )
        return (service, recorder)
    }

    private actor Recorder {
        var entries: [String] = []
        var ioCount = 0
        func log(_ entry: String) {
            entries.append(entry)
            if entry.hasPrefix("io:") { ioCount += 1 }
        }
    }

    @Test("descriptors declare the interactive shell contract")
    func descriptors() {
        #expect(SSHShellOpenTool.name == "ssh.shellOpen")
        #expect(SSHShellExchangeTool.name == "ssh.shellExchange")
        #expect(SSHShellCloseTool.name == "ssh.shellClose")
        #expect(SSHShellOpenTool.riskLabels.contains(.executesRemoteCommand))
        #expect(SSHShellOpenTool.isSideEffecting)
        #expect(SSHShellOpenTool.toolDescription.contains("ssh.execute"))
    }

    @Test("validation rejects bad ids and oversized payloads")
    func validation() {
        let (service, _) = makeGuardianService(outputs: [])
        let open = SSHShellOpenTool(service: service)
        let exchange = SSHShellExchangeTool(service: service)
        #expect(throws: FloeError.self) { try open.validate(.init(hostID: "not-a-uuid")) }
        #expect(throws: FloeError.self) { try open.validate(.init(executionMode: "pty")) }
        #expect(throws: FloeError.self) { try exchange.validate(.init(sessionID: "bogus")) }
        #expect(throws: FloeError.self) { try exchange.validate(.init(sessionID: UUID().uuidString, input: String(repeating: "x", count: 70000))) }
        try! open.validate(.init(hostID: UUID().uuidString, executionMode: "host", cols: 120, rows: 40))
        try! exchange.validate(.init(sessionID: UUID().uuidString, input: "ls\n"))
    }

    @Test("guardian open→exchange→close reuses the session and redacts output")
    func guardianRoundTrip() async throws {
        let (service, recorder) = makeGuardianService(
            outputs: ["$ ", "total 0\npassword: hunter2secretvalue\n", "bye"]
        )
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())

        let opened = try await SSHShellOpenTool(service: service)
            .execute(.init(executionMode: "host"), context: context)
        #expect(opened.exitStatus == 0)
        #expect(opened.summary.contains("environment=guardian"))
        let sessionID = String(opened.summary.components(separatedBy: "sessionID=").last?.prefix(36) ?? "")

        let exchanged = try await SSHShellExchangeTool(service: service)
            .execute(.init(sessionID: sessionID, input: "ls -la\n"), context: context)
        #expect(exchanged.exitStatus == 0)
        #expect(exchanged.summary.contains("alive=true"))
        // Shell output passes through SecretRedactor (key/token/password shapes).
        #expect(!exchanged.summary.contains("hunter2secretvalue") || exchanged.summary.contains("redacted"))

        let closed = try await SSHShellCloseTool(service: service)
            .execute(.init(sessionID: sessionID), context: context)
        #expect(closed.summary.contains("closed=true"))

        let entries = await recorder.entries
        #expect(entries.first == "open")
        #expect(entries.contains("close:shell-1"))
    }

    @Test("exchange on an unknown session reports not-found, close is idempotent")
    func unknownSession() async throws {
        let (service, _) = makeGuardianService(outputs: [])
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let bogus = UUID().uuidString
        let exchanged = try await SSHShellExchangeTool(service: service)
            .execute(.init(sessionID: bogus), context: context)
        #expect(exchanged.exitStatus == 2)
        let closed = try await SSHShellCloseTool(service: service)
            .execute(.init(sessionID: bogus), context: context)
        #expect(closed.summary.contains("closed=true"))
    }

    @Test("guardian 404 maps to a redeploy hint")
    func oldGuardianError() async throws {
        let guardian = GuardianShellClient(
            open: { _, _, _, _ in throw FloeError.notFound("not_found") },
            io: { _, _, _, _, _, _ in throw FloeError.notFound("not_found") },
            close: { _, _ in }
        )
        let service = InteractiveShellSessionService(
            directFactory: { _, _, _, _ in throw RemotePythonError.noHostConfigured },
            defaultHostProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000001") },
            guardian: guardian
        )
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let opened = try await SSHShellOpenTool(service: service)
            .execute(.init(executionMode: "host"), context: context)
        #expect(opened.exitStatus == 2)
        #expect(opened.summary.contains("bootstrapFloeRemoteAgent"))
    }

    @Test("Cancellation during open closes the newly created guardian session")
    func cancelDuringOpen() async throws {
        let cancellation = CancellationToken()
        let recorder = Recorder()
        let guardian = GuardianShellClient(
            open: { _, _, _, _ in
                cancellation.cancel()
                return (shellID: "late-shell", output: Data(), alive: true)
            },
            io: { _, _, _, _, _, _ in (Data(), false) },
            close: { _, id in await recorder.log("close:\(id)") }
        )
        let service = InteractiveShellSessionService(
            directFactory: { _, _, _, _ in throw RemotePythonError.noHostConfigured },
            defaultHostProvider: { UUID() }, guardian: guardian)
        await #expect(throws: (any Error).self) {
            try await service.open(runID: UUID(), hostID: nil, environment: .guardian,
                term: "xterm", columns: 80, rows: 24, cancellation: cancellation)
        }
        #expect(await recorder.entries == ["close:late-shell"])
    }
}

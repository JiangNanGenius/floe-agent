#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeExecution
@testable import FloeApp

private struct TimeoutOnlyGuestRunner: LinuxCommandRunning {
    func supports(environmentID: String) async -> Bool { false }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { false }
    func run(environmentID: String, argv: [String], workingDirectory: String?,
             standardInput: String?, timeout: TimeInterval, maxOutputBytes: Int,
             cancellation: CancellationToken?) async throws -> LinuxCommandResult {
        throw FloeError.internalError("Timeout normalization must not run a command")
    }
}

@Suite("App routed shell timeout receipts")
struct RoutingShellTimeoutTests {
    @Test("The real App router forwards the configured guest clamp before rendering a receipt")
    func forwardsActualGuestLimits() {
        let backend = RoutingLocalShellBackend(native: UnavailableShellBackend(),
            guests: TimeoutOnlyGuestRunner(), limits: LinuxGuestLimits(maxCommandTimeout: 90))
        let service = LocalShellService(backend: backend, rootProvider: { nil })
        #expect(service.normalizedTimeout(0.01, isBackground: false) == 1)
        #expect(service.normalizedTimeout(300, isBackground: false) == 90)
        #expect(service.normalizedTimeout(300, isBackground: true) == 90)
    }
}
#endif

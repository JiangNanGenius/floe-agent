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

@Suite("App routed shell deadline receipts")
struct RoutingShellTimeoutTests {
    @Test("The real App router forwards the guest deadline resolution before rendering a receipt")
    func forwardsActualGuestLimits() {
        let backend = RoutingLocalShellBackend(native: UnavailableShellBackend(),
            guests: TimeoutOnlyGuestRunner(), limits: LinuxGuestLimits())
        let service = LocalShellService(backend: backend, rootProvider: { nil })
        // The guest's documented 1-second floor applies to real finite
        // deadlines and the receipt must name it.
        #expect(service.resolvedDeadline(0.01, policy: .hard).deadline == .seconds(1))
        #expect(service.resolvedDeadline(0.01, policy: .hard).clampReason == "minimumFloor")
        // An explicit hard deadline is honored at its exact value: no
        // foreground/background product ceiling exists anymore.
        #expect(service.resolvedDeadline(300, policy: .hard).deadline == .seconds(300))
        #expect(service.resolvedDeadline(300, policy: .hard).clampReason == "none")
        #expect(service.resolvedDeadline(7_200, policy: .hard).deadline == .seconds(7_200))
        // The policy default and ANY bare number (including the legacy taught
        // 600) stay unlimited: advisory hints never kill.
        #expect(service.resolvedDeadline(nil, policy: .advisory).deadline == .unlimited)
        #expect(service.resolvedDeadline(300, policy: .advisory).deadline == .unlimited)
        #expect(service.resolvedDeadline(600, policy: .advisory).deadline == .unlimited)
        #expect(service.resolvedDeadline(600, policy: .advisory).clampReason == "advisoryDefault")
        // Unlimited must never be synthesized as a cap by the router: the
        // guest backend reports it as-is.
        #expect(backend.normalizedRunDeadline(.unlimited) == .unlimited)
        #expect(backend.normalizedRunDeadline(.seconds(4_800)) == .seconds(4_800))
    }
}
#endif

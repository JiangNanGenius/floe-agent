// SPDX-License-Identifier: MPL-2.0
//
// Owner lifecycle proofs. These tests use no remote target: validation is
// pure, and transport failures exercise the real RoyalVNCKit stack against
// the loopback closed port 1, which refuses immediately.

import Foundation
import Testing
@testable import FloeMacVNC

@Suite("VNC session owner lifecycle", .serialized)
@MainActor
struct MacVNCSessionOwnerLifecycleTests {
    private func waitFor(
        _ predicate: () -> Bool,
        timeout: Duration = .seconds(15)
    ) async -> Bool {
        let start = ContinuousClock.now
        while !predicate() {
            if start.duration(to: .now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func invalidConfigurationNeverLeavesIdle() {
        let owner = MacVNCSessionOwner()
        #expect(throws: MacVNCValidationError.self) {
            try owner.connect(using: MacVNCConfiguration(host: ""))
        }
        #expect(throws: MacVNCValidationError.self) {
            try owner.connect(using: MacVNCConfiguration(host: "host", port: 0))
        }
        #expect(owner.state == .idle)
        #expect(owner.isSettled)
        #expect(owner.canConnect)
    }

    @Test func secondConnectWhileActiveIsRejected() async throws {
        let owner = MacVNCSessionOwner()
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        #expect(owner.state == .connecting)
        #expect(!owner.canConnect)
        #expect(throws: MacVNCValidationError.connectionActive) {
            try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        }
        // Let the refused loopback connection settle so nothing leaks between tests.
        _ = await owner.drain()
    }

    @Test func refusedLoopbackConnectionFailsClosedAndSettles() async throws {
        let owner = MacVNCSessionOwner()
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        let failed = await waitFor {
            if case .failed = owner.state { return true }
            return false
        }
        #expect(failed, "loopback refused port must produce a terminal failure")
        let failure = try #require(owner.lastFailure)
        #expect(failure.category == .connectionRefused)
        #expect(failure.stage == .transport)
        #expect(failure.retryable)
        #expect(owner.isSettled)
        #expect(owner.canConnect)
        #expect(owner.displaySurface == nil)
        let didSettle = await owner.drain()
        #expect(didSettle)
    }

    @Test func closeDuringConnectingBecomesClosingThenClosedAndClearsPassword() async throws {
        let owner = MacVNCSessionOwner()
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1, password: "secret"))
        owner.close()
        #expect(owner.state == .closing)
        #expect(!owner.canConnect, "connect stays disabled until the transport settles")
        let closed = await waitFor { owner.state == .closed }
        #expect(closed)
        #expect(owner.isSettled)
        #expect(owner.canConnect)
        let config = try #require(owner.lastConfiguration)
        #expect(config.host == "127.0.0.1")
        #expect(config.password == nil, "close must drop the password from memory")
        let didSettle = await owner.drain()
        #expect(didSettle)
    }

    @Test func drainIsIdempotentAndConcurrentSafe() async throws {
        let owner = MacVNCSessionOwner()
        async let first: Bool = owner.drain()
        async let second: Bool = owner.drain()
        let results = await [first, second]
        #expect(results == [true, true])
        #expect(throws: MacVNCValidationError.ownerDrained) {
            try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        }
        // resume() revives the owner for a new manual connection.
        owner.resume()
        #expect(owner.state == .idle)
        #expect(owner.canConnect)
        _ = await owner.drain()
    }

    @Test func resumeOnlyAppliesToTerminalStates() async throws {
        let owner = MacVNCSessionOwner()
        owner.resume()
        #expect(owner.state == .idle)
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        owner.resume()
        #expect(owner.state == .connecting, "resume must not disturb an active connection")
        _ = await owner.drain()
    }

    @Test func drainedOwnerRejectsNewConnectionsUntilResumed() async throws {
        let owner = MacVNCSessionOwner()
        _ = await owner.drain()
        #expect(throws: MacVNCValidationError.ownerDrained) {
            try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        }
        owner.resume()
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: 1))
        #expect(owner.state == .connecting)
        _ = await owner.drain()
    }
}

// Focused integrated-service lifecycle tests.
//
// Every fixture lives under a unique temporary directory. The HTTP listener
// uses an ephemeral loopback port and the control socket is a temporary Unix
// socket. No Keychain, user Bridge data, fixed 43871 listener or external
// process is used. The process-exit hook records the code instead of exiting.

import CryptoKit
import Darwin
import Foundation
import FloeMacBridgeProtocol
import XCTest

private final class LifecycleExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var recorded: [Int32] = []

    func record(_ code: Int32) {
        lock.withLock { recorded.append(code) }
        semaphore.signal()
    }

    var codes: [Int32] { lock.withLock { recorded } }

    func wait(timeout: TimeInterval) -> Int32? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { recorded.last }
    }
}

private final class LifecycleParentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current: pid_t

    init(_ initial: pid_t) { current = initial }

    func set(_ value: pid_t) { lock.withLock { current = value } }
    func get() -> pid_t { lock.withLock { current } }
}

private actor ControlGate {
    let point: String
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ point: String) { self.point = point }
    func pause(_ name: String) async {
        guard name == point else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BridgeControlFailure.remote("fixture barrier did not open")
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// The server has marked its socket closed, but has not yet delivered the
/// disconnect callback to the runtime. The bounded wait prevents test hangs.
private final class DisconnectCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var isEntered: Bool { lock.withLock { entered } }
    func pause() {
        lock.withLock { entered = true }
        _ = semaphore.wait(timeout: .now() + 8)
    }
    func release() { semaphore.signal() }
}

private struct LifecycleHarness {
    let fixture: URL
    let serviceHome: URL
    let paths: BridgePaths
    let runtime: BridgeServiceRuntime
    let exit: LifecycleExitRecorder
    let parent: LifecycleParentProbe
    let discoveryURL: URL

    func cleanup() async {
        await runtime.service.jobs.stopAllAndWait()
        runtime.cancelTimersForTesting()
        runtime.storeLock.release()
        try? FileManager.default.removeItem(at: fixture)
    }

    func discovery() throws -> BridgeControlDiscovery {
        let data = try Data(contentsOf: discoveryURL)
        return try JSONDecoder().decode(BridgeControlDiscovery.self, from: data)
    }

    func connect() throws -> BridgeControlClient {
        let value = try discovery()
        return try BridgeControlClient.connect(socketPath: value.socket, token: value.token, timeout: 2)
    }

    func challengeAndClaim(_ client: BridgeControlClient) async throws -> BridgeControlStatus {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let reply = try await client.request(
            BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()),
            timeout: 2
        )
        guard let keyText = reply.publicKeyBase64,
              let key = Data(base64Encoded: keyText),
              let signatureText = reply.signatureBase64,
              let signature = Data(base64Encoded: signatureText),
              key == runtime.identity.publicKey,
              try Curve25519.Signing.PublicKey(rawRepresentation: key)
                .isValidSignature(signature, for: BridgeControlCodec.identityChallenge(nonce)) else {
            throw BridgeControlFailure.remote("fixture identity challenge was invalid")
        }
        let claimed = try await client.request(BridgeControlMessage(kind: .claim), timeout: 2)
        guard let status = claimed.status else {
            throw BridgeControlFailure.remote("claim returned no status")
        }
        return status
    }

    func signedRequest(_ clientKey: Curve25519.Signing.PrivateKey, method: String,
                       payload: [String: BridgeValue]) throws -> BridgeRequest {
        try BridgeRequest(
            body: BridgeRequestBody(clientKey: clientKey.publicKey.rawRepresentation,
                                    method: method, payload: payload),
            key: clientKey
        )
    }
}

@MainActor
final class BridgeServiceLifecycleTests: XCTestCase {
    private func makeHarness(_ label: String, grace: TimeInterval,
                             parentAlive: Bool = true) async throws -> LifecycleHarness {
        // Unix domain socket paths are limited to ~104 bytes. Use a short
        // /tmp root, while still using a unique task-owned directory.
        let fixture = URL(fileURLWithPath: "/tmp/floe-bridge-life-\(UUID().uuidString.prefix(12))",
                          isDirectory: true)
        let control = fixture.appendingPathComponent("Control", isDirectory: true)
        let serviceHome = fixture.appendingPathComponent("service-home", isDirectory: true)
        let workerHome = fixture.appendingPathComponent("worker-home", isDirectory: true)
        for directory in [control, serviceHome, workerHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let paths = try BridgePaths(home: serviceHome)
        let storeLock = try BridgeStoreLock(root: paths.root)
        let identity = try BridgeIdentity.resolveTestFixture(fixture)
        var arguments = ServiceArguments()
        arguments.mode = .test
        arguments.testFixture = fixture
        arguments.controlSocket = control.appendingPathComponent("b.sock", isDirectory: false)
        arguments.readyFile = control.appendingPathComponent("ready.json", isDirectory: false)
        arguments.discoveryFile = control.appendingPathComponent("discovery.json", isDirectory: false)
        arguments.parentPID = 999_999
        arguments.orphanIdleGrace = grace
        let parent = LifecycleParentProbe(parentAlive ? 999_999 : 1)
        let exit = LifecycleExitRecorder()
        let runtime = try BridgeServiceRuntime(
            arguments: arguments,
            identity: identity,
            paths: paths,
            storeLock: storeLock,
            httpPort: 0,
            parentPIDProvider: { parent.get() },
            shutdownExit: { exit.record($0) }
        )
        runtime.installControlHandler()
        try runtime.start()
        let deadline = Date().addingTimeInterval(6)
        var ready = false
        while Date() < deadline {
            let status = await runtime.statusForTesting()
            if status.state == "ready", status.port != nil {
                ready = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard ready else {
            runtime.cancelTimersForTesting()
            storeLock.release()
            throw XCTSkip("The ephemeral Bridge listener did not become ready.")
        }
        let harness = LifecycleHarness(fixture: fixture, serviceHome: serviceHome, paths: paths,
                                       runtime: runtime, exit: exit, parent: parent,
                                       discoveryURL: arguments.discoveryFile!)
        addTeardownBlock { await harness.cleanup() }
        return harness
    }

    private func errorMessage(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testStatusProbeDoesNotExtendOwnershipAndGraceStopsIdleService() async throws {
        let harness = try await makeHarness("probe", grace: 0.4)
        let probe = try harness.connect()
        defer { probe.close() }
        let status = try await probe.request(BridgeControlMessage(kind: .status), timeout: 2)
        XCTAssertEqual(status.status?.hostClaimed, false)
        XCTAssertEqual(harness.runtime.ownerConnectionForTesting, nil)
        // A probe is authenticated but never claims. Parent death must still
        // start the ordinary orphan grace.
        harness.parent.set(1)
        XCTAssertEqual(harness.exit.wait(timeout: 6), 0)
        XCTAssertEqual(harness.runtime.ownerConnectionForTesting, nil)
    }

    func testStopRefusesConsentAndInFlightReplyThenAdmitsAfterRelease() async throws {
        let harness = try await makeHarness("stop-admission", grace: 2)
        let owner = try harness.connect()
        defer { owner.close() }
        _ = try await harness.challengeAndClaim(owner)

        let client = Curve25519.Signing.PrivateKey()
        let nonce = String(repeating: "a", count: 64)
        let pair = try harness.signedRequest(client, method: "pair",
                                             payload: ["name": .string("Stop Fixture"), "nonce": .string(nonce)])
        let pairDelivery = try await harness.runtime.service.respondForDelivery(pair)
        var snapshot = await harness.runtime.service.pairingSnapshot()
        XCTAssertEqual(snapshot.pending.count, 1)
        let refusedConsent = await errorMessage {
            _ = try await owner.request(BridgeControlMessage(kind: .stop), timeout: 2)
        }
        XCTAssertNotNil(refusedConsent)
        XCTAssertTrue(refusedConsent?.localizedCaseInsensitiveContains("still in progress") == true,
                      "unexpected refusal: \(refusedConsent ?? "none")")
        XCTAssertTrue(harness.exit.codes.isEmpty)
        XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)

        let cancel = try harness.signedRequest(client, method: "pairCancel",
                                               payload: ["nonce": .string(nonce)])
        let cancelled = try await harness.runtime.service.respondForDelivery(cancel)
        harness.runtime.service.finishDelivery(cancelled.lease)
        harness.runtime.service.finishDelivery(pairDelivery.lease)
        snapshot = await harness.runtime.service.pairingSnapshot()
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertEqual(harness.runtime.service.updateActivity.activityCount, 0)

        let ping = try harness.signedRequest(client, method: "ping", payload: [:])
        let inFlight = try await harness.runtime.service.respondForDelivery(ping)
        let refusedReply = await errorMessage {
            _ = try await owner.request(BridgeControlMessage(kind: .stop), timeout: 2)
        }
        XCTAssertNotNil(refusedReply)
        XCTAssertTrue(harness.exit.codes.isEmpty)
        harness.runtime.service.finishDelivery(inFlight.lease)
        XCTAssertEqual(harness.runtime.service.updateActivity.activityCount, 0)
        let stopped = try await owner.request(BridgeControlMessage(kind: .stop), timeout: 3)
        XCTAssertNil(stopped.error)
        XCTAssertEqual(harness.exit.wait(timeout: 5), 0)
        // The reservation is retained through listener closure and the exit
        // hook; no late request may slip into the stopped runtime.
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        let latePing = try harness.signedRequest(client, method: "ping", payload: [:])
        do {
            _ = try await harness.runtime.service.respondForDelivery(latePing)
            XCTFail("A stopped service admitted a new request")
        } catch { }
    }

    func testStopAndSignalRefuseActiveJobButExitWhenIdle() async throws {
        let harness = try await makeHarness("job", grace: 2)
        let owner = try harness.connect()
        defer { owner.close() }
        _ = try await harness.challengeAndClaim(owner)
        let jobID = UUID().uuidString
        _ = try await harness.runtime.service.jobs.start(
            id: jobID, clientID: "fixture", workspaceID: "fixture",
            command: "sleep 1.0", cwd: harness.paths.root,
            environment: [:], columns: 80, rows: 24
        )
        XCTAssertGreaterThan(harness.runtime.service.updateActivity.activityCount, 0)
        let refusedStop = await errorMessage {
            _ = try await owner.request(BridgeControlMessage(kind: .stop), timeout: 2)
        }
        XCTAssertTrue(refusedStop?.localizedCaseInsensitiveContains("still running") == true,
                      "unexpected refusal: \(refusedStop ?? "none")")
        harness.runtime.signalForTesting(SIGTERM)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(harness.exit.codes.isEmpty, "Signal ended an active job")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if await harness.runtime.service.jobs.activeTaskIDs().isEmpty
                && harness.runtime.service.updateActivity.activityCount == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let remaining = await harness.runtime.service.jobs.activeTaskIDs()
        XCTAssertTrue(remaining.isEmpty)
        harness.runtime.signalForTesting(SIGTERM)
        XCTAssertEqual(harness.exit.wait(timeout: 5), 0)
    }

    func testClaimAcrossOrphanGraceAndOwnerDisconnect() async throws {
        let harness = try await makeHarness("takeover", grace: 2)
        let owner = try harness.connect()
        let nonce = Data(repeating: 3, count: 32)
        _ = try await owner.request(BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()), timeout: 2)
        // A status/challenge connection is not an owner yet.
        var status = await harness.runtime.statusForTesting()
        XCTAssertFalse(status.hostClaimed)
        harness.parent.set(1)
        let orphanDeadline = Date().addingTimeInterval(4)
        while Date() < orphanDeadline, !(await harness.runtime.statusForTesting().orphaned) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let orphaned = await harness.runtime.statusForTesting().orphaned
        XCTAssertTrue(orphaned)
        _ = try await harness.challengeAndClaim(owner)
        status = await harness.runtime.statusForTesting()
        XCTAssertTrue(status.hostClaimed)
        XCTAssertFalse(status.orphaned)
        // The claim cancelled the pending grace; the original parent is gone.
        try await Task.sleep(for: .milliseconds(2_400))
        XCTAssertTrue(harness.exit.codes.isEmpty, "A claimed service exited on the old parent grace")
        owner.close()
        XCTAssertEqual(harness.exit.wait(timeout: 6), 0)
    }

    func testHostAOldConnectionCannotControlOrDelayHostB() async throws {
        let harness = try await makeHarness("handover", grace: 2)
        let first = try harness.connect()
        _ = try await harness.challengeAndClaim(first)
        harness.parent.set(1)
        // The first owner keeps the service alive even though its parent is gone.
        try await Task.sleep(for: .milliseconds(1_400))
        XCTAssertTrue(harness.exit.codes.isEmpty)
        let second = try harness.connect()
        defer { second.close() }
        let claimed = try await harness.challengeAndClaim(second)
        XCTAssertTrue(claimed.hostClaimed)
        let staleClaim = await errorMessage {
            _ = try await first.request(BridgeControlMessage(kind: .claim), timeout: 2)
        }
        XCTAssertNotNil(staleClaim, "An old challenge reclaimed ownership after handover")
        let staleStop = await errorMessage {
            _ = try await first.request(BridgeControlMessage(kind: .stop), timeout: 2)
        }
        XCTAssertNotNil(staleStop, "The superseded connection stopped the new owner's service")
        first.close()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(harness.exit.codes.isEmpty, "Closing the old connection affected the new owner")
        let status = try await second.request(BridgeControlMessage(kind: .status), timeout: 2)
        XCTAssertEqual(status.status?.hostClaimed, true)
        second.close()
        XCTAssertEqual(harness.exit.wait(timeout: 6), 0)
    }

    func testSupersededConnectionCannotReclaimAfterFreshChallenge() async throws {
        let harness = try await makeHarness("fresh-reclaim", grace: 2)
        let first = try harness.connect(), second = try harness.connect()
        defer { first.close(); second.close() }
        _ = try await harness.challengeAndClaim(first)
        let firstOwner = try XCTUnwrap(harness.runtime.ownerConnectionForTesting)
        _ = try await harness.challengeAndClaim(second)
        let secondOwner = try XCTUnwrap(harness.runtime.ownerConnectionForTesting)
        XCTAssertNotEqual(firstOwner, secondOwner)
        // A fresh challenge must not let the superseded connection create a
        // new ownership epoch. It must reconnect to ask for ownership again.
        let challenge = await errorMessage {
            _ = try await first.request(BridgeControlMessage(kind: .challenge,
                nonce: Data(repeating: 0x45, count: 32).base64EncodedString()), timeout: 2)
        }
        XCTAssertNotNil(challenge)
        let claim = await errorMessage { _ = try await first.request(BridgeControlMessage(kind: .claim), timeout: 2) }
        XCTAssertNotNil(claim)
        XCTAssertEqual(harness.runtime.ownerConnectionForTesting, secondOwner)
        let reconnected = try harness.connect()
        defer { reconnected.close() }
        _ = try await harness.challengeAndClaim(reconnected)
        let replacementOwner = try XCTUnwrap(harness.runtime.ownerConnectionForTesting)
        XCTAssertNotEqual(replacementOwner, firstOwner)
        XCTAssertNotEqual(replacementOwner, secondOwner)
        second.close()
        let staleAfterDisconnect = await errorMessage {
            _ = try await first.request(BridgeControlMessage(kind: .challenge,
                nonce: Data(repeating: 0x46, count: 32).base64EncodedString()), timeout: 2)
        }
        XCTAssertNotNil(staleAfterDisconnect)
        XCTAssertEqual(harness.runtime.ownerConnectionForTesting, replacementOwner)
    }

    func testDelayedChallengeAndClaimCannotReviveDisconnectedConnection() async throws {
        for point in ["challenge", "claim"] {
            let harness = try await makeHarness("late-\(point)", grace: 2)
            let client = try harness.connect()
            if point == "claim" {
                _ = try await client.request(BridgeControlMessage(kind: .challenge,
                    nonce: Data(repeating: 7, count: 32).base64EncodedString()), timeout: 2)
            }
            let gate = ControlGate(point)
            harness.runtime.setControlHookForTesting { await gate.pause($0) }
            let pending = Task {
                try await client.request(BridgeControlMessage(kind: point == "claim" ? .claim : .challenge,
                    nonce: point == "challenge" ? Data(repeating: 6, count: 32).base64EncodedString() : nil), timeout: 3)
            }
            try await gate.waitUntilEntered()
            client.close()
            for _ in 0..<200 {
                if harness.runtime.liveConnectionsForTesting == 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(harness.runtime.liveConnectionsForTesting, 0)
            await gate.release()
            _ = try? await pending.value
            XCTAssertNil(harness.runtime.ownerConnectionForTesting)
            harness.runtime.setControlHookForTesting(nil)
            let next = try harness.connect()
            _ = try await harness.challengeAndClaim(next)
            next.close()
        }
    }

    func testDisconnectedOwnerCannotCreateReservationAfterItsLeaseWasAcquired() async throws {
        let harness = try await makeHarness("reserve-disconnect", grace: 2)
        let first = try harness.connect()
        _ = try await harness.challengeAndClaim(first)
        let gate = ControlGate("reserve")
        addTeardownBlock { await gate.release() }
        harness.runtime.setControlHookForTesting { await gate.pause($0) }
        let pending = Task { try await first.request(BridgeControlMessage(kind: .reserve), timeout: 4) }
        try await gate.waitUntilEntered()
        first.close()
        for _ in 0..<200 {
            if harness.runtime.ownerConnectionForTesting == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(harness.runtime.ownerConnectionForTesting)

        // A replacement cannot take ownership while the stale handler still
        // holds its mutation lease, but can take over after it unwinds.
        let next = try harness.connect()
        defer { next.close() }
        let nonce = Data(repeating: 31, count: 32).base64EncodedString()
        _ = try await next.request(BridgeControlMessage(kind: .challenge, nonce: nonce), timeout: 2)
        let earlyClaim = await errorMessage { _ = try await next.request(BridgeControlMessage(kind: .claim), timeout: 2) }
        XCTAssertNotNil(earlyClaim)
        await gate.release()
        _ = try? await pending.value
        for _ in 0..<200 {
            if !harness.runtime.mutationInFlightForTesting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(harness.runtime.mutationInFlightForTesting)
        XCTAssertNil(harness.runtime.updateReservationTokenForTesting)
        XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
        harness.runtime.setControlHookForTesting(nil)
        _ = try await next.request(BridgeControlMessage(kind: .claim), timeout: 2)
        let lease = try harness.runtime.service.updateActivity.begin(.request)
        harness.runtime.service.updateActivity.finish(lease)
    }

    func testOwnerCanReserveCancelAndCommitWithoutReopeningAdmission() async throws {
        let harness = try await makeHarness("reserve-lifecycle", grace: 2)
        let owner = try harness.connect(), observer = try harness.connect()
        defer { owner.close(); observer.close() }
        _ = try await harness.challengeAndClaim(owner)
        let initial = try await owner.request(BridgeControlMessage(kind: .reserve), timeout: 2)
        let token = try XCTUnwrap(initial.token)
        let repeated = try await owner.request(BridgeControlMessage(kind: .reserve), timeout: 2)
        XCTAssertEqual(repeated.token, token)
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        XCTAssertThrowsError(try harness.runtime.service.updateActivity.begin(.request))
        let foreignCancel = await errorMessage {
            _ = try await observer.request(BridgeControlMessage(kind: .cancel, token: token), timeout: 2)
        }
        XCTAssertNotNil(foreignCancel)
        let wrongCancel = await errorMessage {
            _ = try await owner.request(BridgeControlMessage(kind: .cancel, token: UUID().uuidString), timeout: 2)
        }
        XCTAssertNotNil(wrongCancel)
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        _ = try await owner.request(BridgeControlMessage(kind: .cancel, token: token), timeout: 2)
        let work = try harness.runtime.service.updateActivity.begin(.request)
        harness.runtime.service.updateActivity.finish(work)

        let again = try await owner.request(BridgeControlMessage(kind: .reserve), timeout: 2)
        let newToken = try XCTUnwrap(again.token)
        XCTAssertNotEqual(newToken, token)
        _ = try await owner.request(BridgeControlMessage(kind: .commit, token: newToken), timeout: 2)
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        XCTAssertNotNil(harness.runtime.shutdownInstallationForTesting)
        XCTAssertThrowsError(try harness.runtime.service.updateActivity.begin(.request))
        for _ in 0..<500 {
            if !harness.exit.codes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(harness.exit.codes.first, 0)
    }

    func testHostControllerHoldsAndCancelsRealServiceReservation() async throws {
        let harness = try await makeHarness("host-reservation", grace: 2)
        let connection = try harness.connect()
        let statusReply = try await connection.request(BridgeControlMessage(kind: .status), timeout: 2)
        let status = try XCTUnwrap(statusReply.status)
        let controller = BridgeComponentController(dataRoot: harness.fixture, testFixture: harness.fixture)
        let installed = await controller.testClaimAndInstall(connection, status: status)
        XCTAssertTrue(installed)
        XCTAssertTrue(controller.beginHostTerminationFence())
        let preparation = await controller.reserveForHostExit()
        guard case .reserved(let reservation) = preparation else {
            XCTFail("Host did not acquire its real service reservation")
            return
        }
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        XCTAssertThrowsError(try harness.runtime.service.updateActivity.begin(.request))
        let cancelled = await controller.cancelHostExit(reservation)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
        let lease = try harness.runtime.service.updateActivity.begin(.request)
        harness.runtime.service.updateActivity.finish(lease)
        controller.cancelHostTerminationFence()
        controller.detachForTermination()
    }

    func testHostReservationRefusesActiveServiceWork() async throws {
        let harness = try await makeHarness("host-active-work", grace: 2)
        let connection = try harness.connect()
        let reply = try await connection.request(BridgeControlMessage(kind: .status), timeout: 2)
        let status = try XCTUnwrap(reply.status)
        let controller = BridgeComponentController(dataRoot: harness.fixture, testFixture: harness.fixture)
        let installed = await controller.testClaimAndInstall(connection, status: status)
        XCTAssertTrue(installed)
        XCTAssertTrue(controller.beginHostTerminationFence())
        let work = try harness.runtime.service.updateActivity.begin(.request)
        let preparation = await controller.reserveForHostExit()
        guard case .refused = preparation else {
            harness.runtime.service.updateActivity.finish(work)
            XCTFail("An active request must prevent host exit")
            return
        }
        XCTAssertEqual(harness.runtime.service.updateActivity.activityCount, 1)
        XCTAssertNil(harness.runtime.updateReservationTokenForTesting)
        XCTAssertTrue(connection.isConnected)
        harness.runtime.service.updateActivity.finish(work)
        controller.cancelHostTerminationFence()
        controller.detachForTermination()
    }

    func testHostReserveTimeoutClosesConnectionAndReconcilesRelease() async throws {
        let harness = try await makeHarness("host-reserve-timeout", grace: 2)
        let connection = try harness.connect()
        let statusReply = try await connection.request(BridgeControlMessage(kind: .status), timeout: 2)
        let status = try XCTUnwrap(statusReply.status)
        let controller = BridgeComponentController(dataRoot: harness.fixture, testFixture: harness.fixture)
        let installed = await controller.testClaimAndInstall(connection, status: status)
        XCTAssertTrue(installed)
        XCTAssertTrue(controller.beginHostTerminationFence())
        controller.setHostExitRequestTimeoutForTesting(0.2)
        let gate = ControlGate("reserveAfterAdmission")
        addTeardownBlock { await gate.release() }
        harness.runtime.setControlHookForTesting { await gate.pause($0) }
        let attempt = Task { await controller.reserveForHostExit() }
        try await gate.waitUntilEntered()
        XCTAssertNotNil(harness.runtime.updateReservationTokenForTesting)
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        let result = await attempt.value
        guard case .refused = result else {
            XCTFail("A timed-out reserve cannot authorize host exit")
            await gate.release()
            return
        }
        XCTAssertFalse(connection.isConnected)
        await gate.release()
        for _ in 0..<200 {
            if !harness.runtime.mutationInFlightForTesting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(harness.runtime.updateReservationTokenForTesting)
        XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
        let lease = try harness.runtime.service.updateActivity.begin(.request)
        harness.runtime.service.updateActivity.finish(lease)
        controller.cancelHostTerminationFence()
        controller.detachForTermination()
    }

    func testHostCancelTimeoutReleasesHeldReservationOnDisconnect() async throws {
        let harness = try await makeHarness("host-cancel-timeout", grace: 2)
        let connection = try harness.connect()
        let statusReply = try await connection.request(BridgeControlMessage(kind: .status), timeout: 2)
        let status = try XCTUnwrap(statusReply.status)
        let controller = BridgeComponentController(dataRoot: harness.fixture, testFixture: harness.fixture)
        let installed = await controller.testClaimAndInstall(connection, status: status)
        XCTAssertTrue(installed)
        XCTAssertTrue(controller.beginHostTerminationFence())
        let preparation = await controller.reserveForHostExit()
        guard case .reserved(let reservation) = preparation else {
            XCTFail("Host did not acquire its service reservation")
            return
        }
        controller.setHostExitRequestTimeoutForTesting(0.2)
        let gate = ControlGate("cancel")
        addTeardownBlock { await gate.release() }
        harness.runtime.setControlHookForTesting { await gate.pause($0) }
        let cancellation = Task { await controller.cancelHostExit(reservation) }
        try await gate.waitUntilEntered()
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        let confirmed = await cancellation.value
        XCTAssertTrue(confirmed, "The fresh authenticated probe must confirm the gate reopened")
        XCTAssertFalse(connection.isConnected)
        await gate.release()
        for _ in 0..<200 {
            if !harness.runtime.mutationInFlightForTesting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(harness.runtime.updateReservationTokenForTesting)
        XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
        controller.cancelHostTerminationFence()
        controller.detachForTermination()
    }

    func testHostReserveTransportDisconnectIsReconciled() async throws {
        let harness = try await makeHarness("host-reserve-disconnect", grace: 2)
        let connection = try harness.connect()
        let statusReply = try await connection.request(BridgeControlMessage(kind: .status), timeout: 2)
        let status = try XCTUnwrap(statusReply.status)
        let controller = BridgeComponentController(dataRoot: harness.fixture, testFixture: harness.fixture)
        let installed = await controller.testClaimAndInstall(connection, status: status)
        XCTAssertTrue(installed)
        XCTAssertTrue(controller.beginHostTerminationFence())
        let ownerID = try XCTUnwrap(harness.runtime.ownerConnectionForTesting)
        let gate = ControlGate("reserveAfterAdmission")
        addTeardownBlock { await gate.release() }
        harness.runtime.setControlHookForTesting { await gate.pause($0) }
        let attempt = Task { await controller.reserveForHostExit() }
        try await gate.waitUntilEntered()
        XCTAssertTrue(harness.runtime.service.updateActivity.isAdmissionClosed)
        harness.runtime.closeConnectionForTesting(ownerID)
        let result = await attempt.value
        guard case .refused(let message) = result else {
            await gate.release()
            XCTFail("A disconnected reservation cannot authorize exit")
            return
        }
        XCTAssertTrue(message.contains("Reconnect and retry"), "Expected confirmed release: \(message)")
        XCTAssertFalse(connection.isConnected)
        await gate.release()
        for _ in 0..<200 {
            if !harness.runtime.mutationInFlightForTesting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(harness.runtime.updateReservationTokenForTesting)
        XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
        controller.cancelHostTerminationFence()
        controller.detachForTermination()
    }

    func testDisconnectedOwnerCannotCommitReservationOrStopService() async throws {
        for point in ["commitBeforeCommit", "stopBeforeCommit"] {
            let harness = try await makeHarness("late-\(point)", grace: 2)
            let owner = try harness.connect()
            _ = try await harness.challengeAndClaim(owner)
            let reserved = try await owner.request(BridgeControlMessage(kind: .reserve), timeout: 2)
            let token = try XCTUnwrap(reserved.token)
            let gate = ControlGate(point)
            addTeardownBlock { await gate.release() }
            harness.runtime.setControlHookForTesting { await gate.pause($0) }
            let command = BridgeControlMessage(kind: point == "stopBeforeCommit" ? .stop : .commit, token: token)
            let pending = Task { try await owner.request(command, timeout: 4) }
            try await gate.waitUntilEntered()
            owner.close()
            for _ in 0..<200 {
                if harness.runtime.ownerConnectionForTesting == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(harness.runtime.ownerConnectionForTesting)
            await gate.release()
            _ = try? await pending.value
            XCTAssertNil(harness.runtime.updateReservationTokenForTesting)
            XCTAssertNil(harness.runtime.shutdownInstallationForTesting)
            XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
            XCTAssertTrue(harness.exit.codes.isEmpty)
            harness.runtime.setControlHookForTesting(nil)
            let next = try harness.connect()
            _ = try await harness.challengeAndClaim(next)
            let lease = try harness.runtime.service.updateActivity.begin(.request)
            harness.runtime.service.updateActivity.finish(lease)
            next.close()
        }
    }

    func testClosedSocketCannotCommitBeforeDisconnectCallbackAcquiresRuntime() async throws {
        for (beforePoint, afterPoint, kind) in [
            ("commitBeforeCommit", "commitAfterCommit", BridgeControlKind.commit),
            ("stopBeforeCommit", "stopAfterCommit", BridgeControlKind.stop)
        ] {
            let harness = try await makeHarness("closed-before-callback", grace: 2)
            let owner = try harness.connect()
            _ = try await harness.challengeAndClaim(owner)
            let reserved = try await owner.request(BridgeControlMessage(kind: .reserve), timeout: 2)
            let token = try XCTUnwrap(reserved.token)
            let before = ControlGate(beforePoint), after = ControlGate(afterPoint)
            let disconnect = DisconnectCallbackGate()
            addTeardownBlock {
                disconnect.release()
                await before.release()
                await after.release()
            }
            harness.runtime.setControlHookForTesting { point in
                await before.pause(point)
                await after.pause(point)
            }
            harness.runtime.setClosedBeforeCallbackHookForTesting { _ in disconnect.pause() }
            let pending = Task { try await owner.request(BridgeControlMessage(kind: kind, token: token), timeout: 4) }
            try await before.waitUntilEntered()
            owner.close()
            for _ in 0..<200 {
                if disconnect.isEntered { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(disconnect.isEntered)
            XCTAssertNotNil(harness.runtime.ownerConnectionForTesting)
            XCTAssertFalse(harness.runtime.ownerConnectionActiveForTesting)
            await before.release()
            try await after.waitUntilEntered()
            // The shutdown decision has run, while the old owner ID has not
            // yet been cleared by the deliberately delayed disconnect.
            XCTAssertNotNil(harness.runtime.ownerConnectionForTesting)
            XCTAssertNil(harness.runtime.shutdownInstallationForTesting)
            XCTAssertTrue(harness.exit.codes.isEmpty)
            await after.release()
            disconnect.release()
            _ = try? await pending.value
            for _ in 0..<200 {
                if harness.runtime.ownerConnectionForTesting == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(harness.runtime.ownerConnectionForTesting)
            XCTAssertFalse(harness.runtime.service.updateActivity.isAdmissionClosed)
            harness.runtime.setClosedBeforeCallbackHookForTesting(nil)
            harness.runtime.setControlHookForTesting(nil)
        }
    }

    func testMutationLeaseFencesTakeoverAcrossActorAwait() async throws {
        let harness = try await makeHarness("mutation-lease", grace: 2)
        let first = try harness.connect(), second = try harness.connect()
        defer { first.close(); second.close() }
        _ = try await harness.challengeAndClaim(first)
        let secondNonce = Data(repeating: 3, count: 32).base64EncodedString()
        _ = try await second.request(BridgeControlMessage(kind: .challenge, nonce: secondNonce), timeout: 2)
        let client = Curve25519.Signing.PrivateKey()
        let nonce = String(repeating: "a", count: 64)
        let request = try harness.signedRequest(client, method: "pair", payload: ["name": .string("fixture"), "nonce": .string(nonce)])
        let delivery = try await harness.runtime.service.respondForDelivery(request)
        harness.runtime.service.finishDelivery(delivery.lease)
        let snapshot = await harness.runtime.service.pairingSnapshot()
        let pending = try XCTUnwrap(snapshot.pending.first)
        let missingID = await errorMessage {
            _ = try await first.request(BridgeControlMessage(kind: .pairingDecision, clientID: pending.clientID,
                verification: pending.verification, allow: true), timeout: 2)
        }
        XCTAssertNotNil(missingID)
        let gate = ControlGate("pairingLease")
        harness.runtime.setControlHookForTesting { await gate.pause($0) }
        let decision = Task {
            try await first.request(BridgeControlMessage(kind: .pairingDecision, clientID: pending.clientID,
                attemptID: pending.attemptID, verification: pending.verification, allow: true), timeout: 4)
        }
        try await gate.waitUntilEntered()
        let earlyClaim = await errorMessage { _ = try await second.request(BridgeControlMessage(kind: .claim), timeout: 2) }
        XCTAssertNotNil(earlyClaim)
        first.close()
        let claimAfterDisconnect = await errorMessage { _ = try await second.request(BridgeControlMessage(kind: .claim), timeout: 2) }
        XCTAssertNotNil(claimAfterDisconnect)
        await gate.release()
        _ = try? await decision.value
        for _ in 0..<200 {
            if !harness.runtime.mutationInFlightForTesting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pairedAfterDecision = await harness.runtime.service.pairedClients()
        XCTAssertEqual(pairedAfterDecision.count, 1)
        XCTAssertFalse(harness.runtime.mutationInFlightForTesting)
        harness.runtime.setControlHookForTesting(nil)
        _ = try await second.request(BridgeControlMessage(kind: .claim), timeout: 2)
        let third = try harness.connect()
        defer { third.close() }
        _ = try await third.request(BridgeControlMessage(kind: .challenge, nonce: secondNonce), timeout: 2)
        let revokeGate = ControlGate("revokeLease")
        harness.runtime.setControlHookForTesting { await revokeGate.pause($0) }
        let revoke = Task { try await second.request(BridgeControlMessage(kind: .revoke, clientID: pending.clientID), timeout: 4) }
        try await revokeGate.waitUntilEntered()
        let revokeClaim = await errorMessage { _ = try await third.request(BridgeControlMessage(kind: .claim), timeout: 2) }
        XCTAssertNotNil(revokeClaim)
        await revokeGate.release()
        _ = try await revoke.value
        let pairedAfterRevoke = await harness.runtime.service.pairedClients()
        XCTAssertTrue(pairedAfterRevoke.isEmpty)
        harness.runtime.setControlHookForTesting(nil)
        _ = try await third.request(BridgeControlMessage(kind: .claim), timeout: 2)
    }

    func testClaimAfterShutdownIsRefused() async throws {
        let harness = try await makeHarness("claim-stop", grace: 2)
        let first = try harness.connect()
        defer { first.close() }
        _ = try await harness.challengeAndClaim(first)
        let second = try harness.connect()
        defer { second.close() }
        _ = try await second.request(
            BridgeControlMessage(kind: .challenge, nonce: Data(repeating: 4, count: 32).base64EncodedString()),
            timeout: 2
        )
        // The first host closes admission; the already-authenticated second
        // connection must not be able to claim during stopping.
        _ = try await first.request(BridgeControlMessage(kind: .stop), timeout: 3)
        let claimError = await errorMessage {
            _ = try await second.request(BridgeControlMessage(kind: .claim), timeout: 2)
        }
        XCTAssertNotNil(claimError)
        XCTAssertTrue(harness.exit.wait(timeout: 5) == 0)
    }

    func testClaimRequiresAChallengeOnTheSameConnection() async throws {
        let harness = try await makeHarness("claim-binding", grace: 2)
        let first = try harness.connect()
        defer { first.close() }
        let second = try harness.connect()
        defer { second.close() }
        let nonce = Data(repeating: 8, count: 32)
        _ = try await first.request(
            BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()),
            timeout: 2
        )
        // Another authenticated connection cannot inherit the challenge.
        let crossClaim = await errorMessage {
            _ = try await second.request(BridgeControlMessage(kind: .claim), timeout: 2)
        }
        XCTAssertNotNil(crossClaim)
        XCTAssertNil(harness.runtime.ownerConnectionForTesting)
        // The exact challenged connection can claim.
        let claimed = try await first.request(BridgeControlMessage(kind: .claim), timeout: 2)
        XCTAssertEqual(claimed.status?.hostClaimed, true)
        XCTAssertNotNil(harness.runtime.ownerConnectionForTesting)
    }

    func testOrphanGraceDoesNotCancelActiveJob() async throws {
        let harness = try await makeHarness("orphan-job", grace: 0.3, parentAlive: false)
        let jobID = UUID().uuidString
        _ = try await harness.runtime.service.jobs.start(
            id: jobID, clientID: "fixture", workspaceID: "fixture",
            command: "sleep 2.5", cwd: harness.paths.root,
            environment: [:], columns: 80, rows: 24
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(await harness.runtime.statusForTesting().orphaned) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let orphaned = await harness.runtime.statusForTesting().orphaned
        XCTAssertTrue(orphaned)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(harness.exit.codes.isEmpty, "Orphan grace killed an active job")
        XCTAssertEqual(harness.exit.wait(timeout: 8), 0)
        let remaining = await harness.runtime.service.jobs.activeTaskIDs()
        XCTAssertTrue(remaining.isEmpty)
    }
}

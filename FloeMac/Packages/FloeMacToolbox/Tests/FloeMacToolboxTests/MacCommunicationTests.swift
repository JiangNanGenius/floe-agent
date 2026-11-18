// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxClients
@testable import FloeMacToolbox

/// Close hook fixture: parks each close until released so tests can prove
/// `drain` waits for the actual teardown instead of observing a nil owner.
private actor CloseGate {
    private var count = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var pendingRelease: CheckedContinuation<Void, Never>?
    func close() async {
        count += 1
        entered?.resume(); entered = nil
        await withCheckedContinuation { pendingRelease = $0 }
    }
    func waitUntilEntered() async {
        if count > 0 { return }
        await withCheckedContinuation { entered = $0 }
    }
    func releasePending() { pendingRelease?.resume(); pendingRelease = nil }
    var closeCount: Int { count }
}

/// Opener fixture: parks the open until released, then returns a fixture
/// session (or throws), modelling a transport connect that ignores cancel.
private actor ParkingOpener {
    private var continuation: CheckedContinuation<MacCommunicationSession, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var calls = 0
    private let gate: CloseGate
    private let throwsOnRelease: Bool
    init(gate: CloseGate, throwsOnRelease: Bool = false) { self.gate = gate; self.throwsOnRelease = throwsOnRelease }
    func open(_: MacCommunicationRequest, _: SessionLease, _: CaptureJournal, _: CaptureRedactor,
              _: @escaping SerialAuthorizer) async throws -> MacCommunicationSession {
        calls += 1
        entered?.resume(); entered = nil
        let session = await withCheckedContinuation { continuation = $0 }
        if throwsOnRelease { throw CancellationError() }
        return session
    }
    func waitUntilEntered(_ expected: Int = 1) async {
        if calls >= expected { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release(_ session: MacCommunicationSession) { continuation?.resume(returning: session); continuation = nil }
}

@Suite("Communication workbench owner")
@MainActor struct MacCommunicationTests {
    private func makeOwner(_ opener: @escaping (MacCommunicationRequest, SessionLease, CaptureJournal, CaptureRedactor, @escaping SerialAuthorizer) async throws -> MacCommunicationSession) throws -> (MacCommunicationOwner, URL) {
        let root = try MacToolboxTestRoot.unique("communication-owner")
        return (MacCommunicationOwner(storageRoot: root, networkTimeout: 5, opener: opener), root)
    }

    @Test func gateAllowsOnlyItsOwnOpenLease() {
        let lease = SessionLease(ownerID: UUID())
        let request = MacCommunicationRequest.mqtt(host: "example.test", port: 1883, tls: false,
                                                   version: .v5, username: nil, password: nil)
        let gate = MacCommunicationGate(request: request, lease: lease)
        #expect(gate.allows(lease))
        #expect(!gate.allows(SessionLease(ownerID: UUID())))
        gate.close()
        #expect(!gate.allows(lease))
    }

    @Test func validationRejectsBadInputBeforeAnySession() {
        #expect(MacCommunicationValidation.issues(for: .http(URL(string: "ftp://example.test")!)) == [.invalidHTTPURL])
        #expect(MacCommunicationValidation.issues(for: .webSocket(URL(string: "http://example.test")!)) == [.invalidWebSocketURL])
        #expect(MacCommunicationValidation.issues(for: .mqtt(host: "", port: 1883, tls: false, version: .v5, username: nil, password: nil)) == [.addressRequired])
        #expect(MacCommunicationValidation.issues(for: .mqtt(host: "example.test", port: 0, tls: false, version: .v5, username: nil, password: nil)) == [.invalidPort])
        let modbusUnframed = SerialAssistantConfiguration(connection: .tcp, protocolType: .modbus, modbusFraming: nil)
        #expect(MacCommunicationValidation.issues(for: .serial(host: "example.test", port: 502, tls: false, configuration: modbusUnframed)) == [.invalidSerialConfiguration])
        #expect(MacCommunicationValidation.issues(for: .http(URL(string: "https://example.test")!)) == [])
        #expect(MacCommunicationValidation.issues(for: .webSocket(URL(string: "wss://example.test/socket")!)) == [])
        #expect(MacCommunicationValidation.issues(for: .mqtt(host: "example.test", port: 1883, tls: false, version: .v5, username: nil, password: nil)) == [])
        #expect(MacCommunicationValidation.issues(for: .serial(host: "example.test", port: 502, tls: false,
                                                               configuration: SerialAssistantConfiguration())) == [])
    }

    @Test func startBlocksAdmissionUntilOpenReturnsAndOnlyOneSessionExists() async throws {
        let gate = CloseGate()
        let parking = ParkingOpener(gate: gate)
        let (owner, root) = try makeOwner { try await parking.open($0, $1, $2, $3, $4) }
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(await owner.start(.http(URL(string: "https://example.test")!)))
        #expect(owner.connecting)
        #expect(owner.session == nil)
        let late = MacCommunicationSession.fixture(tool: .http, endpointSummary: "example.test")
        await parking.waitUntilEntered()
        await parking.release(late)
        while owner.session == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!owner.connecting)
        // A second admission is refused while the first session lives.
        #expect(!(await owner.start(.http(URL(string: "https://other.test")!))))
        owner.cancel()
        #expect(await owner.drain(timeout: 2))
    }

    @Test func cancelClosesSessionAndDrainWaitsForTheActualTeardown() async throws {
        let gate = CloseGate()
        var immediate: ((MacCommunicationRequest, SessionLease, CaptureJournal, CaptureRedactor, @escaping SerialAuthorizer) async throws -> MacCommunicationSession)!
        immediate = { _, _, _, _, _ in MacCommunicationSession.fixture(tool: .webSocket, endpointSummary: "wss://example.test") { await gate.close() } }
        let (owner, root) = try makeOwner(immediate)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await owner.start(.webSocket(URL(string: "wss://example.test")!)))
        while owner.session == nil { try await Task.sleep(for: .milliseconds(10)) }
        owner.cancel()
        #expect(owner.session == nil)
        await gate.waitUntilEntered()
        // The close is still parked: drain must report incomplete work.
        #expect(!(await owner.drain(timeout: 0.05)))
        #expect(owner.closing)
        await gate.releasePending()
        #expect(await owner.drain(timeout: 2))
        #expect(!owner.closing)
        #expect(await gate.closeCount == 1)
    }

    @Test func cancelledOpenNeverPublishesLateSessionAndStaysTrackedUntilClosed() async throws {
        let gate = CloseGate()
        let parking = ParkingOpener(gate: gate)
        let (owner, root) = try makeOwner { try await parking.open($0, $1, $2, $3, $4) }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await owner.start(.mqtt(host: "example.test", port: 1883, tls: false, version: .v5, username: nil, password: nil)))
        await parking.waitUntilEntered()
        owner.cancel()
        // The opener still produces a session after cancellation; it must be
        // closed under a tracked task and never become visible.
        let late = MacCommunicationSession.fixture(tool: .mqtt, endpointSummary: "example.test:1883") { await gate.close() }
        await parking.release(late)
        await gate.waitUntilEntered()
        #expect(owner.session == nil)
        #expect(!(await owner.drain(timeout: 0.05)))
        await gate.releasePending()
        #expect(await owner.drain(timeout: 2))
        #expect(!owner.closing)
        #expect(await gate.closeCount == 1)
        // Cancel alone does not close admissions: a new start is admitted.
        try #require(await owner.start(.http(URL(string: "https://example.test")!)))
        await parking.waitUntilEntered(2)
        owner.cancel()
        await parking.release(MacCommunicationSession.fixture(tool: .http, endpointSummary: "example.test"))
        #expect(await owner.drain(timeout: 2))
    }

    @Test func closeAdmissionsBlocksStartsAndResumeReopens() async throws {
        var immediate: ((MacCommunicationRequest, SessionLease, CaptureJournal, CaptureRedactor, @escaping SerialAuthorizer) async throws -> MacCommunicationSession)!
        immediate = { _, _, _, _, _ in MacCommunicationSession.fixture(tool: .serialAssistant, endpointSummary: "example.test:502") }
        let (owner, root) = try makeOwner(immediate)
        defer { try? FileManager.default.removeItem(at: root) }
        owner.closeAdmissions()
        #expect(!(await owner.start(.http(URL(string: "https://example.test")!))))
        owner.resumeAfterCancelledTermination()
        #expect(await owner.start(.http(URL(string: "https://example.test")!)))
    }

    @Test func serviceTerminationDrainsTheCommunicationOwner() async throws {
        let root = try MacToolboxTestRoot.unique("communication-services")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = MacToolboxServices(storageRoot: root)
        // An HTTP workbench opens its configured target without sending a request.
        let request = MacCommunicationRequest.http(URL(string: "https://example.test")!)
        try #require(await services.communicationOwner.start(request))
        let deadline = ContinuousClock.now + .seconds(2)
        while services.communicationOwner.session == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(services.communicationOwner.session != nil)
        services.closeAdmissionsForTermination()
        #expect(!(await services.communicationOwner.start(request)))
        #expect(await services.drainNonScannerForTermination())
        #expect(services.communicationOwner.session == nil)
        services.resumeAfterCancelledTermination()
        try #require(await services.communicationOwner.start(request))
        services.closeAdmissionsForTermination()
        #expect(await services.drainNonScannerForTermination())
        services.shutdown()
    }
}

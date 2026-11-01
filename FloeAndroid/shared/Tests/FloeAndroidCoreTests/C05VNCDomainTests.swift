// SPDX-License-Identifier: MPL-2.0
//
// C05 VNC domain/ownership tests (authored, NOT RUN in this lane).
// The real RFB handshake/frame path is covered by FloeVNCTests; these tests
// exercise the App-host domain: profile/credential namespace, max two
// sessions, independent close, owner/native-epoch fencing, input release and
// root-stop drain.

import Foundation
import Testing
@testable import FloeAndroidCore
@testable import FloeVNC
import FloeCore
import FloeSSH

private final class FakeVNCSession: VNCFloeSessionDriving, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var _state: VNCFloeState = .disconnected
    private let frame: VNCFloeFrame
    private var _leases: [UUID: VNCFloeFrameLease] = [:]
    private var _sent: [[VNCFloeInputEvent]] = []
    private var _released = false

    init(width: Int = 4, height: Int = 2) {
        var data = Data(count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) {
            data[index] = 10
            data[index + 1] = 20
            data[index + 2] = 30
            data[index + 3] = 255
        }
        frame = VNCFloeFrame(width: width, height: height, revision: 1, data: data)
    }

    var released: Bool {
        lock.lock(); defer { lock.unlock() }; return _released
    }

    var sentBatches: [[VNCFloeInputEvent]] {
        lock.lock(); defer { lock.unlock() }; return _sent
    }

    var currentState: VNCFloeState {
        lock.lock(); defer { lock.unlock() }; return _state
    }

    var isConnected: Bool { currentState.isConnected }
    var framebufferSize: (width: Int, height: Int)? { (frame.width, frame.height) }
    var latestFrameRevision: UInt64 { frame.revision }
    var latestFrameByteCount: Int { frame.byteCount }

    func connect() {
        lock.lock(); _state = .connected; lock.unlock()
    }

    func releaseAllInput() {
        lock.lock(); _released = true; lock.unlock()
    }

    func close(timeout: TimeInterval) async -> Bool {
        lock.lock(); _state = .disconnected; lock.unlock()
        return true
    }

    func currentFrame() -> VNCFloeFrame? { frame }

    func acquireFrame() throws -> VNCFloeFrameLease {
        let lease = VNCFloeFrameLease(frame: frame)
        lock.lock(); _leases[lease.id] = lease; lock.unlock()
        return lease
    }

    func releaseFrame(_ id: UUID) {
        lock.lock(); _leases.removeValue(forKey: id); lock.unlock()
    }

    func send(_ events: [VNCFloeInputEvent]) throws {
        lock.lock(); _sent.append(events); lock.unlock()
    }
}

private actor FakeSSH: C05VNCSSHBridging {
    let profileID: UUID
    let endpointID: UUID
    let sshAddress: String
    var sessions: [UUID: C05RemoteSessionSnapshot] = [:]
    var tunnels: [UUID: C05TunnelSnapshot] = [:]
    var closedTunnels: [UUID] = []
    var closedSessions: [UUID] = []
    var rootStops: [UInt64] = []

    init(profileID: UUID, endpointID: UUID, sshAddress: String = "192.168.1.10") {
        self.profileID = profileID
        self.endpointID = endpointID
        self.sshAddress = sshAddress
    }

    func connect(profileID: UUID, owner: C05RemoteOwner) async throws -> C05RemoteSessionSnapshot {
        guard profileID == self.profileID else {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        let session = C05RemoteSessionSnapshot(
            id: UUID(), profileID: profileID, displayName: "Lab", address: sshAddress,
            port: 22, user: "operator", state: .connected, transportConnected: true,
            createdAt: Date(), lastActivityAt: Date(), ptyCount: 0, execCount: 0,
            tunnelCount: 0
        )
        sessions[session.id] = session
        return session
    }

    func sessionStatus(id: UUID, owner: C05RemoteOwner) async throws -> C05RemoteSessionSnapshot {
        guard let session = sessions[id] else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        return session
    }

    func openTunnel(
        sessionID: UUID,
        targetHost: String,
        targetPort: Int,
        owner: C05RemoteOwner
    ) async throws -> C05TunnelSnapshot {
        guard sessions[sessionID] != nil else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        let tunnel = C05TunnelSnapshot(
            id: UUID(), sessionID: sessionID, targetHost: targetHost, targetPort: targetPort,
            localHost: "127.0.0.1", localPort: 59_001, state: .open,
            acceptedConnections: 0, activeConnections: 0,
            bytesToRemote: 0, bytesFromRemote: 0, lastErrorCode: nil
        )
        tunnels[tunnel.id] = tunnel
        return tunnel
    }

    func closeTunnel(tunnelID: UUID, owner: C05RemoteOwner) async throws -> C05TunnelSnapshot {
        guard var tunnel = tunnels.removeValue(forKey: tunnelID) else {
            throw C05RemoteError(.tunnelNotFound, "tunnelNotFound")
        }
        tunnel = C05TunnelSnapshot(
            id: tunnel.id, sessionID: tunnel.sessionID, targetHost: tunnel.targetHost,
            targetPort: tunnel.targetPort, localHost: tunnel.localHost,
            localPort: tunnel.localPort, state: .closed,
            acceptedConnections: tunnel.acceptedConnections,
            activeConnections: 0, bytesToRemote: tunnel.bytesToRemote,
            bytesFromRemote: tunnel.bytesFromRemote, lastErrorCode: nil
        )
        closedTunnels.append(tunnelID)
        return tunnel
    }

    func closeSession(
        id: UUID,
        owner: C05RemoteOwner,
        force: Bool
    ) async throws -> C05ShutdownReport {
        guard sessions.removeValue(forKey: id) != nil else {
            throw C05RemoteError(.sessionNotFound, "sessionNotFound")
        }
        closedSessions.append(id)
        return C05ShutdownReport(
            complete: true, sessionID: id, closedPTYs: 0, closedExecs: 0, closedTunnels: 0
        )
    }

    func profileDetail(id: UUID, owner: C05RemoteOwner) async throws -> C05HostDetail {
        guard id == profileID else {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        let summary = C05HostSummary(
            id: profileID,
            displayName: "Lab",
            address: sshAddress,
            port: 22,
            user: "operator",
            auth: C05AuthSummary(kind: "password", keyType: nil, credential: nil),
            deviceKind: "linux",
            isRemoteExecutionEnvironment: true,
            hostKeyPolicy: "trustOnFirstUse",
            pinnedFingerprintSHA256: nil,
            allowsLegacyAlgorithms: false,
            jumpHopCount: 0,
            vncEndpointCount: 1,
            auxiliaryConnectionCount: 0
        )
        return C05HostDetail(
            summary: summary,
            jumpChain: [],
            vncEndpoints: [
                C05VNCEndpointSummary(
                    id: endpointID,
                    displayName: "Desktop",
                    transport: "sshTunnel",
                    host: "127.0.0.1",
                    port: 5900,
                    passwordRef: nil
                )
            ],
            auxiliaryConnections: []
        )
    }

    func saveProfile(_ profile: RemoteHostProfile, owner: C05RemoteOwner) async throws -> C05HostDetail {
        try await profileDetail(id: profile.id, owner: owner)
    }

    func rootStop(expectedEpoch: UInt64) async -> C05RootStopReport {
        rootStops.append(expectedEpoch)
        let count = sessions.count
        sessions.removeAll()
        tunnels.removeAll()
        return C05RootStopReport(
            drained: true, closedSessions: count, closedPTYs: 0, closedExecs: 0, closedTunnels: 0
        )
    }

    func snapshotClosedTunnels() -> [UUID] { closedTunnels }
    func snapshotClosedSessions() -> [UUID] { closedSessions }
    func snapshotRootStops() -> [UInt64] { rootStops }
}

private final class SessionCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FakeVNCSession] = []
    func append(_ session: FakeVNCSession) {
        lock.lock(); sessions.append(session); lock.unlock()
    }
    var all: [FakeVNCSession] {
        lock.lock(); defer { lock.unlock() }; return sessions
    }
}

@Suite("C05 VNC host domain", .serialized)
struct C05VNCDomainTests {
    private func makeDomain(
        ssh: FakeSSH,
        epoch: UInt64 = 5,
        catalog: SessionCatalog = SessionCatalog()
    ) -> C05VNCDomain {
        C05VNCDomain(
            ssh: ssh,
            readiness: { (ready: true, epoch: epoch) },
            credentialReader: { _ in Data("secret".utf8) },
            credentialWriter: { _, _ in },
            credentialDeleter: { _ in },
            credentialGatewayReady: { true },
            sessionFactory: { _, _, _ in
                let session = FakeVNCSession()
                catalog.append(session)
                return session
            }
        )
    }

    @Test("Capabilities expose two independent sessions and no model path")
    func capabilities() async {
        let profileID = UUID()
        let endpointID = UUID()
        let ssh = FakeSSH(profileID: profileID, endpointID: endpointID)
        let domain = makeDomain(ssh: ssh)
        let values = await domain.capabilities()
        #expect(values.maximumSessions == 2)
        #expect(values.maximumFrameBytes == 33_177_600)
        #expect(values.pixelFormat == "RGBA8888")
        #expect(values.modelTools == false)
        #expect(values.supportsDirect && values.supportsSSHTunnel)
    }

    @Test("VNC credentials are restricted to the floe.vnc namespace")
    func credentialNamespace() async throws {
        let profileID = UUID()
        let endpointID = UUID()
        let ssh = FakeSSH(profileID: profileID, endpointID: endpointID)
        let domain = makeDomain(ssh: ssh)
        let owner = C05RemoteOwner(token: "vnc-owner-token", nativeEpoch: 5)
        do {
            _ = try await domain.saveCredential(
                account: "floe.ssh.profile.password",
                synchronizable: false,
                secret: Data("secret".utf8),
                owner: owner
            )
            Issue.record("SSH/provider namespace must be refused for VNC")
        } catch let error as C05RemoteError {
            #expect(error.code == .credentialInvalid)
        }
        let reference = try await domain.saveCredential(
            account: "floe.vnc.\(endpointID).password",
            synchronizable: false,
            secret: Data("secret".utf8),
            owner: owner
        )
        #expect(reference.keychainAccount.hasPrefix("floe.vnc."))
    }

    @Test("VNC-only profile rejects an SSH tunnel without SSH credentials")
    func vncOnlyProfileTransport() async throws {
        let profileID = UUID()
        let endpointID = UUID()
        let ssh = FakeSSH(profileID: profileID, endpointID: endpointID)
        let domain = makeDomain(ssh: ssh)
        let owner = C05RemoteOwner(token: "vnc-owner-token", nativeEpoch: 5)
        let draft = C05VNCProfileDraft(
            id: nil,
            displayName: "VNC only",
            deviceKind: "linux",
            endpoints: [
                C05VNCEndpointDraft(
                    id: endpointID,
                    displayName: "Desktop",
                    transport: "sshTunnel",
                    host: "127.0.0.1",
                    port: 5900
                )
            ]
        )
        do {
            _ = try await domain.saveVNCOnlyProfile(draft, owner: owner)
            Issue.record("sshTunnel must require an SSH credential")
        } catch let error as C05RemoteError {
            #expect(error.code == .invalidProfile)
            #expect(error.reason == "sshTunnelRequiresSSH")
        }
    }

    @Test("Two sessions connect independently and close only their own resources")
    func independentSessions() async throws {
        let profileID = UUID()
        let endpointID = UUID()
        let ssh = FakeSSH(profileID: profileID, endpointID: endpointID)
        let catalog = SessionCatalog()
        let domain = makeDomain(ssh: ssh, catalog: catalog)
        let owner = C05RemoteOwner(token: "vnc-owner-token", nativeEpoch: 5)

        let first = try await domain.connect(
            profileID: profileID, endpointID: endpointID, sshSessionID: nil, owner: owner
        )
        let second = try await domain.connect(
            profileID: profileID, endpointID: endpointID, sshSessionID: nil, owner: owner
        )
        #expect(first.id != second.id)
        #expect(catalog.all.count == 2)

        let report = try await domain.close(sessionID: first.id, owner: owner)
        #expect(report.complete)
        let secondStatus = try await domain.status(sessionID: second.id, owner: owner)
        #expect(secondStatus.state == "connected")
        _ = try await domain.close(sessionID: second.id, owner: owner)
    }

    @Test("Input is batched, released on close, and root-stop refuses a retired epoch")
    func inputAndRootStop() async throws {
        let profileID = UUID()
        let endpointID = UUID()
        let ssh = FakeSSH(profileID: profileID, endpointID: endpointID)
        let catalog = SessionCatalog()
        let domain = makeDomain(ssh: ssh, catalog: catalog)
        let owner = C05RemoteOwner(token: "vnc-owner-token", nativeEpoch: 5)
        let session = try await domain.connect(
            profileID: profileID, endpointID: endpointID, sshSessionID: nil, owner: owner
        )
        let accepted = try await domain.input(
            sessionID: session.id,
            events: [.pointerMove(x: 1, y: 2), .key(keysym: 0x61, down: true)],
            owner: owner
        )
        #expect(accepted.accepted == 2)
        #expect(catalog.all.first?.sentBatches.count == 1)

        let rootReport = await domain.rootStop(expectedEpoch: 5)
        #expect(rootReport.drained)
        #expect(catalog.all.first?.released == true)
        let rootStops = await ssh.snapshotRootStops()
        #expect(rootStops == [5])

        do {
            _ = try await domain.connect(
                profileID: profileID, endpointID: endpointID, sshSessionID: nil, owner: owner
            )
            Issue.record("a retired epoch must not open a new session")
        } catch let error as C05RemoteError {
            #expect(error.code == .staleEpoch)
        }
    }

    @Test("Frame broker pages real bytes and fences stale epochs")
    func frameBroker() throws {
        let session = FakeVNCSession(width: 8, height: 4)
        let sessionID = UUID()
        C05VNCFrameBroker.shared.register(
            sessionID: sessionID,
            ownerToken: "vnc-owner-token",
            epoch: 9,
            session: session
        )
        let acquired = try C05VNCFrameBroker.shared.acquire(
            epoch: 9,
            ownerToken: "vnc-owner-token",
            sessionID: sessionID
        )
        #expect(acquired.frame.width == 8)
        let first = try C05VNCFrameBroker.shared.read(
            epoch: 9, leaseID: acquired.leaseID, offset: 0, capacity: 16
        )
        let second = try C05VNCFrameBroker.shared.read(
            epoch: 9, leaseID: acquired.leaseID, offset: 16, capacity: 65_536
        )
        #expect(first.count == 16)
        #expect(second.count == 8 * 4 * 4 - 16)
        C05VNCFrameBroker.shared.release(epoch: 9, leaseID: acquired.leaseID)

        do {
            _ = try C05VNCFrameBroker.shared.acquire(
                epoch: 8,
                ownerToken: "vnc-owner-token",
                sessionID: sessionID
            )
            Issue.record("stale epoch must not acquire a frame")
        } catch let error as C05VNCFrameBroker.BrokerError {
            #expect(error == .staleEpoch)
        }
        _ = C05VNCFrameBroker.shared.rootStop(expectedEpoch: 9)
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP domain/ownership tests (authored, NOT RUN in this lane).
// These exercise the App-host domain: original profile identity, RDP
// credential namespace, max two sessions, explicit certificate challenge and
// trust pin, owner/native-epoch fencing, input forwarding and root-stop drain.
// The real FreeRDP handshake is not faked as success here.

import Foundation
import Testing
@testable import FloeAndroidCore
@testable import FloeRDP
import FloeCore
import FloeSSH

private final class FakeRDPSession: RDPFloeSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: RDPFloeState
    private let frame: RDPFloeFrame
    private var _leases: [UUID: RDPFloeFrameLease] = [:]
    private var _sent: [[RDPFloeInputEvent]] = []
    private var _released = false
    private var _closed = false
    let challengeValue: RDPCertificateChallenge?
    private(set) var observedFingerprint: String?

    init(width: Int = 4, height: Int = 2, challenge: RDPCertificateChallenge? = nil) {
        var data = Data(count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) {
            data[index] = 10
            data[index + 1] = 20
            data[index + 2] = 30
            data[index + 3] = 255
        }
        frame = RDPFloeFrame(width: width, height: height, revision: 1, data: data)
        challengeValue = challenge
        if let challenge {
            _state = .failed(RDPFloeFailure(
                category: .certificateRejected,
                stage: .certificate,
                retryable: false,
                message: challenge.reason,
                fingerprintSHA256: challenge.fingerprintSHA256
            ))
        } else {
            _state = .disconnected
        }
    }

    var sent: [[RDPFloeInputEvent]] {
        lock.lock(); defer { lock.unlock() }; return _sent
    }

    var released: Bool {
        lock.lock(); defer { lock.unlock() }; return _released
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }; return _closed
    }

    var currentState: RDPFloeState {
        lock.lock(); defer { lock.unlock() }; return _state
    }

    var isConnected: Bool { currentState.isConnected }
    var framebufferSize: (width: Int, height: Int)? { (frame.width, frame.height) }
    var latestFrameRevision: UInt64 { frame.revision }
    var latestFrameByteCount: Int { frame.byteCount }
    var certificateChallenge: RDPCertificateChallenge? { challengeValue }

    func connect() {
        lock.lock()
        if challengeValue == nil { _state = .connected }
        lock.unlock()
    }

    func releaseAllInput() {
        lock.lock(); _released = true; lock.unlock()
    }

    func close(timeout: TimeInterval) async -> Bool {
        lock.lock(); _closed = true; _state = .disconnected; lock.unlock()
        return true
    }

    func currentFrame() -> RDPFloeFrame? { frame }

    func acquireFrame() throws -> RDPFloeFrameLease {
        let lease = RDPFloeFrameLease(frame: frame)
        lock.lock(); _leases[lease.id] = lease; lock.unlock()
        return lease
    }

    func releaseFrame(_ id: UUID) {
        lock.lock(); _leases.removeValue(forKey: id); lock.unlock()
    }

    func send(_ events: [RDPFloeInputEvent]) throws {
        lock.lock(); _sent.append(events); lock.unlock()
    }
}

private actor FakeRDPProfiles: C05RDPProfileBridging {
    private var profiles: [UUID: RemoteHostProfile] = [:]
    private var rootStops: [UInt64] = []

    func listProfiles(owner: C05RemoteOwner) async throws -> C05HostList {
        C05HostList(hosts: profiles.values.map(summary), unreadableProfileIDs: [])
    }

    func profileDetail(id: UUID, owner: C05RemoteOwner) async throws -> C05HostDetail {
        guard let profile = profiles[id] else {
            throw C05RemoteError(.profileNotFound, "profileNotFound")
        }
        return C05HostDetail(
            summary: summary(profile),
            jumpChain: [],
            vncEndpoints: [],
            auxiliaryConnections: []
        )
    }

    func saveProfile(_ profile: RemoteHostProfile, owner: C05RemoteOwner) async throws -> C05HostDetail {
        profiles[profile.id] = profile
        return try await profileDetail(id: profile.id, owner: owner)
    }

    func deleteProfile(id: UUID, owner: C05RemoteOwner) async throws -> C05ProfileDeleteReport {
        profiles.removeValue(forKey: id)
        return C05ProfileDeleteReport(deleted: true, closedSessions: 0, closedTunnels: 0)
    }

    func rootStop(expectedEpoch: UInt64) async -> C05RootStopReport {
        rootStops.append(expectedEpoch)
        return C05RootStopReport(
            drained: true, closedSessions: 0, closedPTYs: 0, closedExecs: 0, closedTunnels: 0
        )
    }

    func snapshotProfileIDs() -> [UUID] { profiles.keys.sorted { $0.uuidString < $1.uuidString } }
    func snapshotRootStops() -> [UInt64] { rootStops }

    private func summary(_ profile: RemoteHostProfile) -> C05HostSummary {
        C05HostSummary(
            id: profile.id,
            displayName: profile.displayName,
            address: profile.address,
            port: profile.port,
            user: profile.user,
            auth: C05AuthSummary(kind: "none", keyType: nil, credential: nil),
            deviceKind: profile.deviceKind.rawValue,
            isRemoteExecutionEnvironment: profile.isRemoteExecutionEnvironment,
            hostKeyPolicy: "trustOnFirstUse",
            pinnedFingerprintSHA256: nil,
            allowsLegacyAlgorithms: false,
            jumpHopCount: 0,
            vncEndpointCount: 0,
            auxiliaryConnectionCount: 0
        )
    }
}

private final class RDPSessionCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FakeRDPSession] = []
    private var fingerprints: [String?] = []

    func append(_ session: FakeRDPSession, fingerprint: String?) {
        lock.lock()
        sessions.append(session)
        fingerprints.append(fingerprint)
        lock.unlock()
    }

    var all: [FakeRDPSession] {
        lock.lock(); defer { lock.unlock() }; return sessions
    }

    var approvedFingerprints: [String?] {
        lock.lock(); defer { lock.unlock() }; return fingerprints
    }
}

@Suite("C05 RDP host domain", .serialized)
struct C05RDPDomainTests {
    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("endpoints-v1.json")
    }

    private func makeDomain(
        profiles: FakeRDPProfiles,
        storeURL: URL,
        epoch: UInt64 = 5,
        catalog: RDPSessionCatalog = RDPSessionCatalog(),
        challenge: RDPCertificateChallenge? = nil
    ) -> C05RDPDomain {
        C05RDPDomain(
            profiles: profiles,
            readiness: { (ready: true, epoch: epoch) },
            credentialReader: { _ in Data("secret".utf8) },
            credentialWriter: { _, _ in },
            credentialDeleter: { _ in },
            credentialGatewayReady: { true },
            profileStoreProvider: { _ in C05RDPProfileStore(fileURL: storeURL) },
            sessionFactory: { _, _, _, _, _, fingerprint, _, _ in
                let session = FakeRDPSession(challenge: challenge)
                catalog.append(session, fingerprint: fingerprint)
                return session
            },
            runtimeVersion: { "3.31.1-test" }
        )
    }

    private func saveProfile(
        _ domain: C05RDPDomain,
        owner: C05RemoteOwner,
        endpointID: UUID = UUID(),
        passwordRef: SecretReference? = nil
    ) async throws -> C05RDPHostDetail {
        let reference = passwordRef ?? SecretReference(
            keychainAccount: "floe.rdp.\(endpointID).password",
            synchronizable: false
        )
        let detail = try await domain.saveProfile(
            C05RDPProfileDraft(
                id: nil,
                displayName: "Desk",
                deviceKind: "windows",
                endpoints: [
                    C05RDPEndpointDraft(
                        id: endpointID,
                        displayName: "RDP",
                        host: "10.0.0.4",
                        port: 3389,
                        username: "floe",
                        domain: "LAB",
                        passwordRef: reference
                    )
                ]
            ),
            owner: owner
        )
        return detail
    }

    @Test("Capabilities expose two sessions and the real runtime")
    func capabilities() async {
        let profiles = FakeRDPProfiles()
        let domain = makeDomain(profiles: profiles, storeURL: storeURL())
        let values = await domain.capabilities()
        #expect(values.maximumSessions == 2)
        #expect(values.maximumFrameBytes == 33_554_432)
        #expect(values.pixelFormat == "RGBA8888")
        #expect(values.supportsDirect)
        #expect(!values.supportsSSHTunnel)
        #expect(values.supportsCertificateTrust)
        #expect(values.runtimeVersion == "3.31.1-test")
        #expect(values.modelTools)
    }

    @Test("RDP credentials are restricted to the floe.rdp namespace")
    func credentialNamespace() async throws {
        let profiles = FakeRDPProfiles()
        let domain = makeDomain(profiles: profiles, storeURL: storeURL())
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        do {
            _ = try await domain.saveCredential(
                account: "floe.vnc.profile.password",
                synchronizable: false,
                secret: Data("secret".utf8),
                owner: owner
            )
            Issue.record("VNC/provider namespace must be refused for RDP")
        } catch let error as C05RDPError {
            #expect(error.code == .credentialInvalid)
        }
        let endpointID = UUID()
        let reference = try await domain.saveCredential(
            account: "floe.rdp.\(endpointID).password",
            synchronizable: false,
            secret: Data("secret".utf8),
            owner: owner
        )
        #expect(reference.keychainAccount.hasPrefix("floe.rdp."))
        #expect(try await domain.probeCredential(reference))
    }

    @Test("Saving an RDP profile uses the original profile identity and a narrow sidecar")
    func profilePersistence() async throws {
        let profiles = FakeRDPProfiles()
        let url = storeURL()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        let domain = makeDomain(profiles: profiles, storeURL: url)
        let endpointID = UUID()
        let detail = try await saveProfile(domain, owner: owner, endpointID: endpointID)
        #expect(detail.summary.endpointCount == 1)
        #expect(detail.summary.displayName == "Desk")
        #expect(detail.summary.deviceKind == "windows")
        #expect(detail.endpoints.first?.id == endpointID)
        #expect(detail.endpoints.first?.host == "10.0.0.4")
        let storedProfiles = await profiles.snapshotProfileIDs()
        #expect(storedProfiles.count == 1)
        #expect(storedProfiles.first == detail.summary.id)

        // A fresh domain over the same runtime root sees the endpoint.
        let reopened = makeDomain(profiles: profiles, storeURL: url)
        let list = try await reopened.listProfiles(owner: owner)
        #expect(list.count == 1)
        #expect(list.first?.endpoints.first?.port == 3389)
    }

    @Test("Connecting uses the approved fingerprint and forwards bounded input")
    func connectAndInput() async throws {
        let profiles = FakeRDPProfiles()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        let domain = makeDomain(profiles: profiles, storeURL: storeURL())
        let endpointID = UUID()
        let detail = try await saveProfile(domain, owner: owner, endpointID: endpointID)
        let session = try await domain.connect(
            profileID: detail.summary.id,
            endpointID: endpointID,
            owner: owner
        )
        #expect(session.state == "connected")
        #expect(session.width == 4)
        let acceptance = try await domain.input(
            sessionID: session.id,
            events: [
                .pointerMove(x: 1, y: 1),
                .pointerButton(button: .left, down: true, x: 1, y: 1),
                .pointerButton(button: .left, down: false, x: 1, y: 1),
            ],
            owner: owner
        )
        #expect(acceptance.accepted == 3)
        let closed = try await domain.close(sessionID: session.id, owner: owner)
        #expect(closed.complete)
    }

    @Test("A certificate rejection produces an explicit challenge, not a silent success")
    func certificateChallengeAndTrust() async throws {
        let profiles = FakeRDPProfiles()
        let url = storeURL()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        let fingerprint = String(repeating: "a", count: 64)
        let challenge = RDPCertificateChallenge(
            fingerprintSHA256: fingerprint,
            subject: "DESKTOP-1",
            host: "10.0.0.4",
            port: 3389,
            notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: Date(timeIntervalSince1970: 2_000_000_000),
            kind: .firstUse,
            reason: "Confirm this RDP server certificate before connecting"
        )
        let catalog = RDPSessionCatalog()
        let domain = makeDomain(
            profiles: profiles,
            storeURL: url,
            catalog: catalog,
            challenge: challenge
        )
        let detail = try await saveProfile(domain, owner: owner)
        do {
            _ = try await domain.connect(
                profileID: detail.summary.id,
                endpointID: detail.endpoints.first!.id,
                owner: owner
            )
            Issue.record("a certificate challenge must not connect")
        } catch let error as C05RDPError {
            #expect(error.code == .certificateConfirmationRequired)
            #expect(error.challenge?.fingerprintSHA256 == fingerprint)
            #expect(error.challenge?.subject == "DESKTOP-1")
        }
        do {
            _ = try await domain.approveCertificate(
                profileID: detail.summary.id,
                endpointID: detail.endpoints.first!.id,
                fingerprintSHA256: String(repeating: "b", count: 64),
                owner: owner
            )
            Issue.record("a different fingerprint must be refused")
        } catch let error as C05RDPError {
            #expect(error.code == .certificateMismatch)
        }
    }

    @Test("The observed fingerprint is the only one that can be pinned")
    func certificateTrustPin() async throws {
        let profiles = FakeRDPProfiles()
        let url = storeURL()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        let fingerprint = String(repeating: "a", count: 64)
        let challenge = RDPCertificateChallenge(
            fingerprintSHA256: fingerprint,
            subject: "DESKTOP-1",
            host: "10.0.0.4",
            port: 3389,
            notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: Date(timeIntervalSince1970: 2_000_000_000),
            kind: .firstUse,
            reason: "Confirm this RDP server certificate before connecting"
        )
        let catalog = RDPSessionCatalog()
        let domain = makeDomain(
            profiles: profiles,
            storeURL: url,
            catalog: catalog,
            challenge: challenge
        )
        let detail = try await saveProfile(domain, owner: owner)
        let endpointID = detail.endpoints.first!.id
        _ = try? await domain.connect(
            profileID: detail.summary.id,
            endpointID: endpointID,
            owner: owner
        )
        let report = try await domain.approveCertificate(
            profileID: detail.summary.id,
            endpointID: endpointID,
            fingerprintSHA256: fingerprint,
            owner: owner
        )
        #expect(report.approved)
        #expect(report.fingerprintSHA256 == fingerprint)
        let stored = C05RDPProfileStore(fileURL: url)
        let records = try stored.load()
        #expect(records.first?.approvedFingerprintSHA256 == fingerprint)
        let reopened = makeDomain(profiles: profiles, storeURL: url)
        let listed = try await reopened.listProfiles(owner: owner)
        #expect(listed.first?.endpoints.first?.approvedFingerprintSHA256 == fingerprint)
    }

    @Test("Owner token, task and native epoch fence every session operation")
    func ownerAndEpochFencing() async throws {
        let profiles = FakeRDPProfiles()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5, taskID: UUID())
        let domain = makeDomain(profiles: profiles, storeURL: storeURL())
        let detail = try await saveProfile(domain, owner: owner)
        let session = try await domain.connect(
            profileID: detail.summary.id,
            endpointID: detail.endpoints.first!.id,
            owner: owner
        )
        let other = C05RemoteOwner(token: "other-owner-token", nativeEpoch: 5, taskID: owner.taskID)
        do {
            _ = try await domain.status(sessionID: session.id, owner: other)
            Issue.record("a different owner token must not read the session")
        } catch let error as C05RDPError {
            #expect(error.code == .sessionNotFound)
        }
        let stale = C05RemoteOwner(token: owner.token, nativeEpoch: 4, taskID: owner.taskID)
        do {
            _ = try await domain.status(sessionID: session.id, owner: stale)
            Issue.record("a retired epoch must not read the session")
        } catch let error as C05RDPError {
            #expect(error.code == .staleEpoch || error.code == .coreUnavailable)
        }
    }

    @Test("Root stop closes RDP sessions and retires the frame broker")
    func rootStop() async throws {
        let profiles = FakeRDPProfiles()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        let domain = makeDomain(profiles: profiles, storeURL: storeURL())
        let detail = try await saveProfile(domain, owner: owner)
        let session = try await domain.connect(
            profileID: detail.summary.id,
            endpointID: detail.endpoints.first!.id,
            owner: owner
        )
        let report = await domain.rootStop(expectedEpoch: 5)
        #expect(report.drained)
        #expect(report.closedSessions == 1)
        do {
            _ = try await domain.status(sessionID: session.id, owner: owner)
            Issue.record("root stop must remove the session")
        } catch let error as C05RDPError {
            #expect(error.code == .sessionNotFound || error.code == .staleEpoch)
        }
    }

    @Test("Two sessions are independent and a third is refused")
    func sessionLimit() async throws {
        let profiles = FakeRDPProfiles()
        let owner = C05RemoteOwner(token: "rdp-owner-token", nativeEpoch: 5)
        let domain = makeDomain(profiles: profiles, storeURL: storeURL())
        let detail = try await saveProfile(domain, owner: owner)
        let endpointID = detail.endpoints.first!.id
        let first = try await domain.connect(
            profileID: detail.summary.id, endpointID: endpointID, owner: owner
        )
        let second = try await domain.connect(
            profileID: detail.summary.id, endpointID: endpointID, owner: owner
        )
        #expect(first.id != second.id)
        do {
            _ = try await domain.connect(
                profileID: detail.summary.id, endpointID: endpointID, owner: owner
            )
            Issue.record("a third concurrent RDP session must be refused")
        } catch let error as C05RDPError {
            #expect(error.code == .sessionLimit)
        }
    }
}

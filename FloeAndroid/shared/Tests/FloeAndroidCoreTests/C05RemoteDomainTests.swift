// SPDX-License-Identifier: MPL-2.0
//
// C05 SSH remote-domain tests. Authored source, NOT RUN by this lane.
// They exercise the real domain lifecycle over injected fakes: host-key
// approval, changed-key confirmation, PTY/channel ownership, bounded exec,
// tunnel listener lifecycle and root-stop draining. No network, device,
// credential or real secret participates.

import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSSH
@testable import FloeAndroidCore

private func makeStoredProfile(
    id: UUID = UUID(),
    auth: SSHAuthMethod = .password(SecretReference(
        keychainAccount: "floe.ssh.test.password", synchronizable: false))
) throws -> RemoteHostStore.StoredHost {
    try RemoteHostProfile(
        id: id,
        displayName: "Test host",
        address: "server.example",
        port: 22,
        user: "operator",
        auth: auth
    ).storedHost()
}

private actor FakeHostStore: C05RemoteHostStoring {
    private var rows: [UUID: RemoteHostStore.StoredHost] = [:]
    private var known: [String: KnownHostRecord] = [:]

    func seed(_ host: RemoteHostStore.StoredHost) { rows[host.id] = host }
    func seedKnown(_ record: KnownHostRecord) {
        known[key(record.address, record.port, record.keyType)] = record
    }
    func knownRecord(address: String, port: Int, keyType: String) -> KnownHostRecord? {
        known[key(address, port, keyType)]
    }

    func hosts() async throws -> [RemoteHostStore.StoredHost] {
        rows.values.sorted { $0.displayName < $1.displayName }
    }
    func host(id: UUID) async throws -> RemoteHostStore.StoredHost? { rows[id] }
    func saveHost(_ host: RemoteHostStore.StoredHost) async throws { rows[host.id] = host }
    func deleteHost(id: UUID) async throws {
        rows.removeValue(forKey: id)
        known = known.filter { $0.value.hostID != id }
    }
    func knownHost(address: String, port: Int, keyType: String) async throws -> KnownHostRecord? {
        known[key(address, port, keyType)]
    }
    func trust(_ record: KnownHostRecord) async throws {
        known[key(record.address, record.port, record.keyType)] = record
    }
    func touch(id: UUID, at date: Date) async throws {
        let snapshot = known
        for (key, value) in snapshot where value.id == id {
            var updated = value
            updated.lastSeenAt = date
            known[key] = updated
        }
    }
    private func key(_ address: String, _ port: Int, _ keyType: String) -> String {
        "\(address)|\(port)|\(keyType)"
    }
}

private struct FakeConnector: SSHTransportConnecting {
    let body: @Sendable (RemoteHostProfile, HostKeyDecisionHandler) async throws -> any SSHSessionTransport

    func connectTransport(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> any SSHSessionTransport {
        try await body(profile, hostKeyDecision)
    }
}

private final class FakePTY: SSHSessionPTY, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var writes: [Data] = []
    private var resizes: [(Int, Int)] = []
    private var closeCount = 0

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        self.output = pair.stream
        self.continuation = pair.continuation
    }
    func yield(_ data: Data) { continuation.yield(data) }
    func write(_ data: Data) async throws {
        lock.lock(); writes.append(data); lock.unlock()
    }
    func resize(columns: Int, rows: Int) async throws {
        lock.lock(); resizes.append((columns, rows)); lock.unlock()
    }
    func close() async {
        lock.lock(); closeCount += 1; lock.unlock()
        continuation.finish()
    }
    var written: [Data] {
        lock.lock(); defer { lock.unlock() }; return writes
    }
    var resized: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }; return resizes
    }
}

private final class FakeExec: SSHSessionExec, @unchecked Sendable {
    let events: AsyncThrowingStream<SSHExecEvent, Error>
    private let continuation: AsyncThrowingStream<SSHExecEvent, Error>.Continuation
    private let lock = NSLock()
    private var cancelled = false

    init() {
        let pair = AsyncThrowingStream<SSHExecEvent, Error>.makeStream()
        self.events = pair.stream
        self.continuation = pair.continuation
    }
    func emit(_ event: SSHExecEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        continuation.finish()
    }
    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

private final class FakeByteChannel: SSHSessionByteChannel, @unchecked Sendable {
    let inbound: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        self.inbound = pair.stream
        self.continuation = pair.continuation
    }
    func write(_ data: Data) async throws {}
    func close() async { continuation.finish() }
}

private final class FakeSession: SSHSessionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true
    private var closeCount = 0
    private var ptys: [FakePTY] = []
    private var execs: [FakeExec] = []

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return connected
    }
    func openPTY(term: String, columns: Int, rows: Int) async throws -> any SSHSessionPTY {
        let value = FakePTY()
        lock.lock(); ptys.append(value); lock.unlock()
        return value
    }
    func openExec(_ command: String) async throws -> any SSHSessionExec {
        let value = FakeExec()
        lock.lock(); execs.append(value); lock.unlock()
        return value
    }
    func openDirectTCPIP(host: String, port: Int) async throws -> any SSHSessionByteChannel {
        FakeByteChannel()
    }
    func close() async {
        lock.lock(); connected = false; closeCount += 1; lock.unlock()
    }
    var allPTYs: [FakePTY] {
        lock.lock(); defer { lock.unlock() }; return ptys
    }
    var allExecs: [FakeExec] {
        lock.lock(); defer { lock.unlock() }; return execs
    }
    var closeCalls: Int {
        lock.lock(); defer { lock.unlock() }; return closeCount
    }
}

private func makeDomain(
    store: FakeHostStore,
    connector: FakeConnector,
    epoch: UInt64 = 1
) -> C05RemoteDomain {
    C05RemoteDomain(
        storeProvider: { _ in store },
        connectorFactory: { _ in connector },
        readiness: { (true, epoch) },
        credentialResolver: { _ in Data("synthetic-password".utf8) },
        credentialWriter: { _, _ in },
        credentialReader: { _ in Data("synthetic-secret".utf8) },
        credentialDeleter: { _ in },
        credentialReady: { true }
    )
}

private let owner = C05RemoteOwner(token: "owner-token-123456", nativeEpoch: 1)

@Suite("C05 remote domain")
struct C05RemoteDomainTests {

    @Test("Profile save persists references only and validates the shape")
    func profileSaveAndReferenceValidation() async throws {
        let store = FakeHostStore()
        let connector = FakeConnector { _, _ in FakeSession() }
        let domain = makeDomain(store: store, connector: connector)
        let reference = SecretReference(keychainAccount: "floe.ssh.test.profile", synchronizable: false)
        let profile = RemoteHostProfile(
            displayName: "Saved",
            address: "server.example",
            port: 22,
            user: "operator",
            auth: .password(reference)
        )

        let detail = try await domain.saveProfile(profile, owner: owner)
        #expect(detail.summary.id == profile.id)
        #expect(detail.summary.auth.kind == "password")
        #expect(detail.summary.auth.credential?.keychainAccount == "floe.ssh.test.profile")
        let row = try await store.host(id: profile.id)
        #expect(row?.authJSON.contains("floe.ssh.test.profile") == true)

        let noSSH = RemoteHostProfile(
            displayName: "No SSH",
            address: "",
            user: "",
            auth: .none,
            isRemoteExecutionEnvironment: true
        )
        await #expect(throws: C05RemoteError.self) {
            _ = try await domain.saveProfile(noSSH, owner: owner)
        }

        let foreignReference = SecretReference(
            keychainAccount: "provider.openai.key", synchronizable: false)
        let invalid = RemoteHostProfile(
            displayName: "Foreign",
            address: "server.example",
            user: "operator",
            auth: .password(foreignReference)
        )
        await #expect(throws: C05RemoteError.self) {
            _ = try await domain.saveProfile(invalid, owner: owner)
        }
    }

    @Test("A TOFU challenge is refused until explicitly approved")
    func hostKeyChallengeRequiresApproval() async throws {
        let store = FakeHostStore()
        let id = UUID()
        await store.seed(try makeStoredProfile(id: id))
        let fingerprint = "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
        let connector = FakeConnector { profile, decision in
            let challenge = HostKeyChallenge(
                hostID: profile.id,
                address: profile.address,
                port: profile.port,
                keyType: "ssh-ed25519",
                fingerprintSHA256: fingerprint
            )
            _ = await decision(challenge)
            throw SSHConnectionError.hostKeyRejected(challenge)
        }
        let domain = makeDomain(store: store, connector: connector)

        do {
            _ = try await domain.connect(profileID: id, owner: owner)
            Issue.record("Expected a host-key challenge")
        } catch let error as C05RemoteError {
            #expect(error.code == .hostKeyChallenge)
            #expect(error.challenge?.fingerprintSHA256 == fingerprint)
            #expect(error.challenge?.kind == .firstUse)
        }

        let challenges = try await domain.listHostKeyChallenges(owner: owner)
        #expect(challenges.count == 1)
        let challenge = try #require(challenges.first)
        let approval = try await domain.approveHostKey(
            id: challenge.id,
            accept: true,
            replaceChanged: false,
            expectedFingerprint: nil,
            owner: owner
        )
        #expect(approval.trusted)
        #expect(approval.fingerprintSHA256 == fingerprint)
        let known = await store.knownRecord(
            address: "server.example", port: 22, keyType: "ssh-ed25519")
        #expect(known?.fingerprintSHA256 == fingerprint)
    }

    @Test("A changed key requires an explicit replacement confirmation")
    func changedKeyRequiresConfirmation() async throws {
        let store = FakeHostStore()
        let id = UUID()
        await store.seed(try makeStoredProfile(id: id))
        await store.seedKnown(KnownHostRecord(
            hostID: id,
            address: "server.example",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:old"
        ))
        let connector = FakeConnector { profile, _ in
            let challenge = HostKeyChallenge(
                hostID: profile.id,
                address: profile.address,
                port: profile.port,
                keyType: "ssh-ed25519",
                fingerprintSHA256: "SHA256:new"
            )
            throw SSHConnectionError.hostKeyChanged(
                expected: "SHA256:old",
                received: "SHA256:new",
                challenge: challenge
            )
        }
        let domain = makeDomain(store: store, connector: connector)

        var changed: C05RemoteError?
        do {
            _ = try await domain.connect(profileID: id, owner: owner)
        } catch let error as C05RemoteError {
            changed = error
        }
        #expect(changed?.code == .hostKeyChanged)
        let challenge = try #require(changed?.challenge)
        #expect(challenge.kind == .changed)
        #expect(challenge.expectedFingerprintSHA256 == "SHA256:old")

        await #expect(throws: C05RemoteError.self) {
            _ = try await domain.approveHostKey(
                id: challenge.id,
                accept: true,
                replaceChanged: false,
                expectedFingerprint: "SHA256:old",
                owner: owner
            )
        }
        let approval = try await domain.approveHostKey(
            id: challenge.id,
            accept: true,
            replaceChanged: true,
            expectedFingerprint: "SHA256:old",
            owner: owner
        )
        #expect(approval.trusted)
        #expect(approval.changed)
        let known = await store.knownRecord(
            address: "server.example", port: 22, keyType: "ssh-ed25519")
        #expect(known?.fingerprintSHA256 == "SHA256:new")
    }

    @Test("Session owns independent PTYs and really closes them")
    func sessionPTYLifecycle() async throws {
        let store = FakeHostStore()
        let id = UUID()
        await store.seed(try makeStoredProfile(id: id))
        let fake = FakeSession()
        let domain = makeDomain(
            store: store,
            connector: FakeConnector { _, _ in fake }
        )
        let session = try await domain.connect(profileID: id, owner: owner)

        let pty = try await domain.openPTY(
            sessionID: session.id, term: "xterm-256color", columns: 120, rows: 32,
            owner: owner)
        let fakePTY = try #require(fake.allPTYs.first)
        fakePTY.yield(Data("hello".utf8))

        var read: C05PTYRead?
        for _ in 0..<50 {
            let value = try await domain.readPTY(ptyID: pty.id, cursor: 0, maxBytes: 1024, owner: owner)
            if !value.chunks.isEmpty { read = value; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(read?.chunks.first == Data("hello".utf8))
        #expect(read?.nextCursor == 5)

        _ = try await domain.writePTY(ptyID: pty.id, data: Data("ls\n".utf8), owner: owner)
        _ = try await domain.resizePTY(ptyID: pty.id, columns: 100, rows: 40, owner: owner)
        #expect(fakePTY.written.last == Data("ls\n".utf8))
        #expect(fakePTY.resized.last?.0 == 100)

        for _ in 0..<3 {
            _ = try await domain.openPTY(
                sessionID: session.id, term: nil, columns: 80, rows: 24, owner: owner)
        }
        await #expect(throws: C05RemoteError.self) {
            _ = try await domain.openPTY(
                sessionID: session.id, term: nil, columns: 80, rows: 24, owner: owner)
        }

        let report = try await domain.closeSession(id: session.id, owner: owner)
        #expect(report.complete)
        #expect(report.closedPTYs == 4)
        #expect(!fake.isConnected)
        #expect(fake.closeCalls == 1)
    }

    @Test("Bounded exec reports channel-tagged output and cancellation")
    func execOutputAndCancel() async throws {
        let store = FakeHostStore()
        let id = UUID()
        await store.seed(try makeStoredProfile(id: id))
        let fake = FakeSession()
        let domain = makeDomain(store: store, connector: FakeConnector { _, _ in fake })
        let session = try await domain.connect(profileID: id, owner: owner)
        let exec = try await domain.startExec(sessionID: session.id, command: "printf hi", owner: owner)
        let fakeExec = try #require(fake.allExecs.first)
        fakeExec.emit(.stdout(Data("out".utf8)))
        fakeExec.emit(.stderr(Data("err".utf8)))
        fakeExec.emit(.exited(0))

        var read: C05ExecRead?
        for _ in 0..<50 {
            let value = try await domain.readExec(execID: exec.id, cursor: 0, maxBytes: 1024, owner: owner)
            if !value.chunks.isEmpty { read = value; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(read?.chunks.map(\.channel) == ["stdout", "stderr"])
        #expect(read?.chunks.map(\.data) == [Data("out".utf8), Data("err".utf8)])
        #expect(read?.snapshot.exitCode == 0)
        let released = try await domain.releaseExec(execID: exec.id, owner: owner)
        #expect(released)

        let second = try await domain.startExec(
            sessionID: session.id, command: "sleep 5", owner: owner)
        let fakeSecond = try #require(fake.allExecs.last)
        let cancelled = try await domain.cancelExec(execID: second.id, owner: owner)
        #expect(fakeSecond.wasCancelled)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.remoteOutcomeUnknown)
    }

    @Test("Tunnel binds loopback, reports real endpoint and closes")
    func tunnelLifecycle() async throws {
        let store = FakeHostStore()
        let id = UUID()
        await store.seed(try makeStoredProfile(id: id))
        let fake = FakeSession()
        let domain = makeDomain(store: store, connector: FakeConnector { _, _ in fake })
        let session = try await domain.connect(profileID: id, owner: owner)
        let tunnel = try await domain.openTunnel(
            sessionID: session.id,
            targetHost: "127.0.0.1",
            targetPort: 5900,
            owner: owner
        )
        #expect(tunnel.localHost == "127.0.0.1")
        #expect(tunnel.localPort != nil)
        #expect(tunnel.state == .open)
        let closed = try await domain.closeTunnel(tunnelID: tunnel.id, owner: owner)
        #expect(closed.state == .closed)
    }

    @Test("Root stop drains sessions and removes tunnel listeners")
    func rootStopDrains() async throws {
        let store = FakeHostStore()
        let id = UUID()
        await store.seed(try makeStoredProfile(id: id))
        let fake = FakeSession()
        let domain = makeDomain(store: store, connector: FakeConnector { _, _ in fake })
        _ = try await domain.connect(profileID: id, owner: owner)
        let live = try await domain.listSessions(owner: owner)
        let sessionID = try #require(live.first).id
        _ = try await domain.openTunnel(
            sessionID: sessionID,
            targetHost: "127.0.0.1",
            targetPort: 22,
            owner: owner
        )
        let report = await domain.rootStop(expectedEpoch: 1)
        #expect(report.drained)
        #expect(report.closedSessions == 1)
        #expect(report.closedTunnels == 1)
        #expect(!fake.isConnected)
    }

    @Test("Owner epoch is a fence and short tokens are rejected")
    func ownerFence() async throws {
        let store = FakeHostStore()
        let domain = makeDomain(
            store: store,
            connector: FakeConnector { _, _ in FakeSession() },
            epoch: 2
        )
        await #expect(throws: C05RemoteError.self) {
            _ = try await domain.listProfiles(owner: owner)
        }
        let short = C05RemoteOwner(token: "short", nativeEpoch: 2)
        await #expect(throws: C05RemoteError.self) {
            _ = try await domain.listProfiles(owner: short)
        }
    }

    @Test("Bounded byte ring reports rollover without corrupting chunk order")
    func byteRingRollover() {
        let ring = C05ByteRing(capacity: 4, maximumChunks: 2)
        ring.append(Data("aa".utf8))
        ring.append(Data("bb".utf8))
        ring.append(Data("cc".utf8))
        let read = ring.read(cursor: 0, maxBytes: 1024)
        #expect(read.lostBytes == 2)
        #expect(read.chunks.map(\.data) == [Data("bb".utf8), Data("cc".utf8)])
        #expect(read.nextCursor == 6)
        #expect(read.rolledOverBytes == 2)
        let empty = ring.read(cursor: 6, maxBytes: 1024)
        #expect(empty.chunks.isEmpty)
        #expect(empty.nextCursor == 6)
    }

    @Test("Profile codec rejects malformed jump and pinned values")
    func profileCodecValidation() throws {
        let reference: [String: Any] = [
            "keychainAccount": "floe.ssh.codec.key",
            "synchronizable": false,
        ]
        let base: [String: Any] = [
            "displayName": "Codec",
            "address": "server.example",
            "port": 22,
            "user": "operator",
            "auth": ["kind": "password", "credential": reference],
            "hostKeyPolicy": ["kind": "trustOnFirstUse"],
        ]
        let decoded = try C05RemoteProfileCodec.decode(base)
        #expect(decoded.address == "server.example")

        var tooManyHops = base
        tooManyHops["jumpChain"] = (0...5).map { index in
            [
                "address": "jump\(index).example",
                "port": 22,
                "user": "jump",
                "auth": ["kind": "password", "credential": reference],
            ] as [String: Any]
        }
        #expect(throws: C05RemoteError.self) {
            try C05RemoteProfileCodec.decode(tooManyHops)
        }

        var badPinned = base
        badPinned["hostKeyPolicy"] = ["kind": "pinned", "fingerprintSHA256": "bad"]
        #expect(throws: C05RemoteError.self) {
            try C05RemoteProfileCodec.decode(badPinned)
        }
    }
}

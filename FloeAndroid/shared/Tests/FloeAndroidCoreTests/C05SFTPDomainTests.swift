// SPDX-License-Identifier: MPL-2.0
//
// C05 SFTP domain tests (authored, NOT RUN in this source lane).
//
// The transport is a deterministic in-memory SFTP channel; the real
// Citadel path is covered by FloeSSHTests. These tests exercise the
// authority rules: explicit host-key approval, owner/epoch fencing,
// untrusted path refusal, staged download/upload commit, revision CAS and
// root-stop drain.

import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSSH
import FloeWorkspace
@testable import FloeAndroidCore

private actor FakeHostStore: C05RemoteHostStoring {
    var rows: [UUID: RemoteHostStore.StoredHost] = [:]
    var known: [String: KnownHostRecord] = [:]

    init(rows: [RemoteHostStore.StoredHost] = []) {
        for row in rows { self.rows[row.id] = row }
    }

    func hosts() async throws -> [RemoteHostStore.StoredHost] {
        rows.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func host(id: UUID) async throws -> RemoteHostStore.StoredHost? { rows[id] }

    func saveHost(_ host: RemoteHostStore.StoredHost) async throws { rows[host.id] = host }

    func deleteHost(id: UUID) async throws { rows.removeValue(forKey: id) }

    func knownHost(address: String, port: Int, keyType: String) async throws -> KnownHostRecord? {
        known["\(address):\(port):\(keyType)"]
    }

    func trust(_ record: KnownHostRecord) async throws {
        known["\(record.address):\(record.port):\(record.keyType)"] = record
    }

    func touch(id: UUID, at date: Date) async throws {}
}

private final class FakeSFTPChannel: SSHSFTPChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var directories: Set<String>
    private var closed = false
    var renameHook: ((String, String) throws -> Void)?
    private(set) var lastListMaxEntries: Int?

    init(files: [String: Data] = [:], directories: Set<String> = ["/home/test"]) {
        self.files = files
        self.directories = directories
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }; return !closed
    }

    func data(at path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return files[path]
    }

    func listDirectory(at path: String, maxEntries: Int) async throws -> [SSHSFTPDirectoryEntry] {
        lock.lock()
        lastListMaxEntries = maxEntries
        defer { lock.unlock() }
        let prefix = path == "/" ? "/" : path + "/"
        var values: [SSHSFTPDirectoryEntry] = []
        for directory in directories where directory != path && directory.hasPrefix(prefix) {
            let remainder = String(directory.dropFirst(prefix.count))
            guard !remainder.isEmpty, !remainder.contains("/") else { continue }
            values.append(SSHSFTPDirectoryEntry(
                name: remainder,
                longName: nil,
                attributes: SSHSFTPAttributes(
                    isDirectory: true, isSymbolicLink: false, size: 0,
                    modifiedAt: nil, permissions: 0o040755)
            ))
        }
        for (file, data) in files where file.hasPrefix(prefix) {
            let remainder = String(file.dropFirst(prefix.count))
            guard !remainder.isEmpty, !remainder.contains("/") else { continue }
            values.append(SSHSFTPDirectoryEntry(
                name: remainder,
                longName: nil,
                attributes: SSHSFTPAttributes(
                    isDirectory: false, isSymbolicLink: false,
                    size: Int64(data.count), modifiedAt: nil, permissions: 0o100644)
            ))
        }
        return Array(values.prefix(maxEntries))
    }

    func stat(path: String) async throws -> SSHSFTPAttributes {
        lock.lock(); defer { lock.unlock() }
        if directories.contains(path) {
            return SSHSFTPAttributes(
                isDirectory: true, isSymbolicLink: false, size: 0,
                modifiedAt: nil, permissions: 0o040755)
        }
        guard let data = files[path] else { throw SSHSFTPError.notFound }
        return SSHSFTPAttributes(
            isDirectory: false, isSymbolicLink: false, size: Int64(data.count),
            modifiedAt: nil, permissions: 0o100644)
    }

    func canonicalPath(_ path: String) async throws -> String {
        path == "." ? "/home/test" : path
    }

    func openRead(path: String) async throws -> any SSHSFTPReadHandle {
        guard data(at: path) != nil else { throw SSHSFTPError.notFound }
        return FakeRead(channel: self, path: path)
    }

    func openWrite(path: String, createNew: Bool) async throws -> any SSHSFTPWriteHandle {
        lock.lock()
        defer { lock.unlock() }
        if createNew, files[path] != nil { throw SSHSFTPError.alreadyExists }
        files[path] = Data()
        return FakeWrite(channel: self, path: path)
    }

    func createDirectory(path: String) async throws {
        lock.lock(); directories.insert(path); lock.unlock()
    }

    func removeFile(path: String) async throws {
        lock.lock(); files.removeValue(forKey: path); lock.unlock()
    }

    func removeDirectory(path: String) async throws {
        lock.lock(); directories.remove(path); lock.unlock()
    }

    func rename(from: String, to: String) async throws {
        let hook = renameHook
        if let hook { try hook(from, to) }
        lock.lock(); defer { lock.unlock() }
        if let data = files.removeValue(forKey: from) {
            guard files[to] == nil else { throw SSHSFTPError.alreadyExists }
            files[to] = data
            return
        }
        if directories.remove(from) != nil {
            directories.insert(to)
            return
        }
        throw SSHSFTPError.notFound
    }

    fileprivate func mutate(_ data: Data, path: String) {
        lock.lock(); files[path] = data; lock.unlock()
    }

    fileprivate func moveNow(from: String, to: String) {
        lock.lock()
        if let data = files.removeValue(forKey: from) { files[to] = data }
        lock.unlock()
    }

    func close() async {
        lock.lock(); closed = true; lock.unlock()
    }

    fileprivate func write(_ data: Data, at offset: UInt64, path: String) {
        lock.lock()
        var current = files[path] ?? Data()
        let end = Int(offset) + data.count
        if current.count < end { current.append(Data(count: end - current.count)) }
        current.replaceSubrange(Int(offset)..<end, with: data)
        files[path] = current
        lock.unlock()
    }
}

private final class FakeRead: SSHSFTPReadHandle, @unchecked Sendable {
    private let channel: FakeSFTPChannel
    private let path: String
    init(channel: FakeSFTPChannel, path: String) {
        self.channel = channel
        self.path = path
    }

    func read(at offset: UInt64, maxBytes: Int) async throws -> Data {
        guard let data = channel.data(at: path) else { throw SSHSFTPError.notFound }
        guard offset < UInt64(data.count) else { return Data() }
        let start = Int(offset)
        let end = min(data.count, start + maxBytes)
        return data.subdata(in: start..<end)
    }

    func close() async {}
}

private final class FakeWrite: SSHSFTPWriteHandle, @unchecked Sendable {
    private let channel: FakeSFTPChannel
    private let path: String
    init(channel: FakeSFTPChannel, path: String) {
        self.channel = channel
        self.path = path
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        channel.write(data, at: offset, path: path)
    }

    func close() async throws {}
}

private final class FakeTransport: SSHSessionTransport, SSHSFTPTransportProviding, @unchecked Sendable {
    let channel: FakeSFTPChannel
    private let lock = NSLock()
    private var closed = false

    init(channel: FakeSFTPChannel) { self.channel = channel }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return !closed
    }

    func openPTY(term: String, columns: Int, rows: Int) async throws -> any SSHSessionPTY {
        throw SSHConnectionError.transport("not used")
    }

    func openExec(_ command: String) async throws -> any SSHSessionExec {
        throw SSHConnectionError.transport("not used")
    }

    func openDirectTCPIP(host: String, port: Int) async throws -> any SSHSessionByteChannel {
        throw SSHConnectionError.transport("not used")
    }

    func openSFTPChannel() async throws -> any SSHSFTPChannel { channel }

    func close() async {
        lock.lock(); closed = true; lock.unlock()
        await channel.close()
    }
}

private final class FakeConnector: SSHTransportConnecting, @unchecked Sendable {
    let transport: FakeTransport
    let challenge: HostKeyChallenge
    private let lock = NSLock()
    private var trusted: Bool

    init(transport: FakeTransport, challenge: HostKeyChallenge, trusted: Bool = false) {
        self.transport = transport
        self.challenge = challenge
        self.trusted = trusted
    }

    func markTrusted() {
        lock.lock(); trusted = true; lock.unlock()
    }

    func connectTransport(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> any SSHSessionTransport {
        lock.lock()
        let isTrusted = trusted
        lock.unlock()
        if !isTrusted {
            if await hostKeyDecision(challenge) {
                markTrusted()
            } else {
                throw SSHConnectionError.hostKeyRejected(challenge)
            }
        }
        _ = try await credentialResolver(
            SecretReference(keychainAccount: "floe.ssh.test.password",
                            synchronizable: false))
        return transport
    }
}

private struct FakeRootResolver: C05SFTPOwnedRootResolving {
    let root: URL
    func resolve(
        target: C05SFTPOwnedTarget,
        owner: C05RemoteOwner
    ) async throws -> C05SFTPOwnedAccess {
        C05SFTPOwnedAccess(
            fileService: WorkspaceFileService(
                guard: WorkspacePathGuard(rootURL: root)),
            relativePath: target.relativePath
        )
    }
}

private let c05TestProfileID = UUID()

private func profile() -> RemoteHostProfile {
    RemoteHostProfile(
        id: c05TestProfileID,
        displayName: "Lab",
        address: "lab.example",
        port: 22,
        user: "operator",
        auth: .password(SecretReference(
            keychainAccount: "floe.ssh.test.password", synchronizable: false))
    )
}

private func makeDomain(
    channel: FakeSFTPChannel,
    root: URL,
    connector: FakeConnector
) -> C05SFTPDomain {
    let store = FakeHostStore(rows: [try! profile().storedHost()])
    return C05SFTPDomain(
        storeProvider: { _ in store },
        connectorFactory: { _ in connector },
        readiness: { (true, 7) },
        credentialResolver: { _ in Data("secret".utf8) },
        credentialReady: { true },
        rootResolver: FakeRootResolver(root: root),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
}

private func waitFor(
    _ condition: @escaping () async -> Bool,
    timeout: TimeInterval = 5
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

@Suite("C05 SFTP domain")
struct C05SFTPDomainTests {
    private func owner(_ token: String = "test-owner-123") -> C05RemoteOwner {
        C05RemoteOwner(token: token, nativeEpoch: 7, taskID: UUID(), temporary: false)
    }

    @Test("Unknown host key is refused until the exact challenge is approved")
    func hostKeyApproval() async throws {
        let channel = FakeSFTPChannel()
        let transport = FakeTransport(channel: channel)
        let challenge = HostKeyChallenge(
            hostID: UUID(), address: "lab.example", port: 22,
            keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new")
        let connector = FakeConnector(transport: transport, challenge: challenge)
        let domain = makeDomain(channel: channel, root: FileManager.default.temporaryDirectory, connector: connector)

        do {
            _ = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
            Issue.record("Expected hostKeyChallenge")
        } catch let error as C05SFTPError {
            #expect(error.code == .hostKeyChallenge)
            #expect(error.challenge?.fingerprintSHA256 == "SHA256:new")
        }
        let pending = try await domain.listHostKeyChallenges(owner: owner())
        #expect(pending.count == 1)
        let approval = try await domain.approveHostKey(
            id: pending[0].id, accept: true, replaceChanged: false,
            expectedFingerprint: nil, owner: owner())
        #expect(approval.trusted)
        connector.markTrusted()
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        #expect(lane.state == .connected)
        #expect(lane.homePath == "/home/test")
    }

    @Test("Parent traversal and backslash remote paths are refused")
    func remotePathRefusal() async throws {
        let channel = FakeSFTPChannel()
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: FileManager.default.temporaryDirectory, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        for path in ["/home/../etc", "..", "/home/\\test"] {
            do {
                _ = try await domain.list(laneID: lane.id, path: path, offset: 0, limit: 10, owner: owner())
                Issue.record("Expected invalidPath for \(path)")
            } catch let error as C05SFTPError {
                #expect(error.code == .invalidPath)
            }
        }
    }

    @Test("Download stages, verifies and commits into an owned workspace file")
    func downloadCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c05-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = FakeSFTPChannel(files: ["/home/test/hello.txt": Data("hello".utf8)])
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: root, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        let target = C05SFTPOwnedTarget(kind: .task, taskID: UUID(), relativePath: "Downloads/hello.txt")
        let transfer = try await domain.startDownload(
            laneID: lane.id, remotePath: "/home/test/hello.txt", destination: target,
            overwrite: false, expectedRevision: nil, owner: owner())
        #expect(await waitFor {
            (try? await domain.transferStatus(transferID: transfer.id, owner: owner()))?.state == .completed
        })
        let committed = try Data(contentsOf: root.appendingPathComponent("Downloads/hello.txt"))
        #expect(committed == Data("hello".utf8))
        let final = try await domain.transferStatus(transferID: transfer.id, owner: owner())
        #expect(final.sha256 == FloeDigest.sha256Hex(Data("hello".utf8)))
    }

    @Test("Download revision mismatch preserves the original workspace file")
    func downloadRevisionMismatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c05-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Downloads", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("Downloads/hello.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = FakeSFTPChannel(files: ["/home/test/hello.txt": Data("hello".utf8)])
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: root, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        let target = C05SFTPOwnedTarget(kind: .task, taskID: UUID(), relativePath: "Downloads/hello.txt")
        do {
            _ = try await domain.startDownload(
                laneID: lane.id, remotePath: "/home/test/hello.txt", destination: target,
                overwrite: true, expectedRevision: "sha256:deadbeef", owner: owner())
            Issue.record("Expected revisionMismatch")
        } catch let error as C05SFTPError {
            #expect(error.code == .revisionMismatch)
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("Downloads/hello.txt")) == Data("old".utf8))
    }

    @Test("Upload writes a verified remote temp and commits only after revision checks")
    func uploadCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c05-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = FakeSFTPChannel()
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: root, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        let data = Data("uploaded".utf8)
        let start = try await domain.startUpload(
            laneID: lane.id, remotePath: "/home/test/out.txt", displayName: "out.txt",
            totalBytes: Int64(data.count), sha256: FloeDigest.sha256Hex(data),
            overwrite: false, expectedRevision: nil, owner: owner())
        _ = try await domain.writeUpload(
            transferID: start.id, offset: 0, data: data, owner: owner())
        let done = try await domain.finishUpload(
            transferID: start.id, declaredSHA256: FloeDigest.sha256Hex(data), owner: owner())
        #expect(done.state == .completed)
        #expect(channel.data(at: "/home/test/out.txt") == data)
    }

    @Test("Root stop drains every lane and rejects later owner calls")
    func rootStopDrain() async throws {
        let channel = FakeSFTPChannel()
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: FileManager.default.temporaryDirectory, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        let report = await domain.rootStop(expectedEpoch: 7)
        #expect(report.drained)
        #expect(report.closedLanes == 1)
        do {
            _ = try await domain.list(laneID: lane.id, path: "/home/test", offset: 0, limit: 10, owner: owner())
            Issue.record("Expected laneNotFound")
        } catch let error as C05SFTPError {
            #expect(error.code == .laneNotFound || error.code == .staleEpoch)
        }
    }
    @Test("Directory listing passes a hard transport bound")
    func boundedListingBound() async throws {
        let channel = FakeSFTPChannel(
            files: [
                "/home/test/a": Data("a".utf8),
                "/home/test/b": Data("b".utf8),
                "/home/test/c": Data("c".utf8),
            ]
        )
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: FileManager.default.temporaryDirectory, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        _ = try await domain.list(laneID: lane.id, path: "/home/test", offset: 0, limit: 200, owner: owner())
        #expect((channel.lastListMaxEntries ?? -1) == C05SFTPWire.maximumDirectoryEntries)
    }

    @Test("Overwrite race preserves the changed original at a recovery path")
    func overwriteRacePreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c05-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("old".utf8)
        let channel = FakeSFTPChannel(files: ["/home/test/out.txt": original])
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: root, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        let expected = "sha256:\(FloeDigest.sha256Hex(original))"
        let data = Data("new".utf8)
        let start = try await domain.startUpload(
            laneID: lane.id, remotePath: "/home/test/out.txt", displayName: "out.txt",
            totalBytes: Int64(data.count), sha256: FloeDigest.sha256Hex(data),
            overwrite: true, expectedRevision: expected, owner: owner())
        _ = try await domain.writeUpload(transferID: start.id, offset: 0, data: data, owner: owner())
        channel.renameHook = { from, to in
            if from == "/home/test/out.txt", to.contains(".floe-backup-") {
                channel.mutate(Data("changed".utf8), path: from)
            }
        }
        do {
            _ = try await domain.finishUpload(
                transferID: start.id, declaredSHA256: FloeDigest.sha256Hex(data), owner: owner())
            Issue.record("Expected revisionMismatch")
        } catch let error as C05SFTPError {
            #expect(error.code == .revisionMismatch)
            let retained = try #require(error.retainedPath)
            #expect(channel.data(at: retained) == Data("changed".utf8))
            #expect(channel.data(at: "/home/test/out.txt") == nil)
        }
    }

    @Test("Ambiguous final rename verifies actual destination bytes before success")
    func ambiguousRenameVerifiesDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c05-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = FakeSFTPChannel()
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: root, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        let data = Data("ambiguous".utf8)
        let start = try await domain.startUpload(
            laneID: lane.id, remotePath: "/home/test/out.txt", displayName: "out.txt",
            totalBytes: Int64(data.count), sha256: FloeDigest.sha256Hex(data),
            overwrite: false, expectedRevision: nil, owner: owner())
        _ = try await domain.writeUpload(transferID: start.id, offset: 0, data: data, owner: owner())
        channel.renameHook = { from, to in
            if to == "/home/test/out.txt", from.contains(".floe-sftp-") {
                channel.moveNow(from: from, to: to)
                throw SSHSFTPError.connectionLost
            }
        }
        let done = try await domain.finishUpload(
            transferID: start.id, declaredSHA256: FloeDigest.sha256Hex(data), owner: owner())
        #expect(done.state == .completed)
        #expect(channel.data(at: "/home/test/out.txt") == data)
    }

    @Test("Whole-body uploadData shares the same recovery-preserving commit path")
    func uploadDataRacePreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c05-sftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("old".utf8)
        let channel = FakeSFTPChannel(files: ["/home/test/out.txt": original])
        let connector = FakeConnector(
            transport: FakeTransport(channel: channel),
            challenge: HostKeyChallenge(hostID: UUID(), address: "lab.example", port: 22,
                                        keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:new"),
            trusted: true)
        let domain = makeDomain(channel: channel, root: root, connector: connector)
        let lane = try await domain.connect(profileID: try profile().storedHost().id, owner: owner())
        channel.renameHook = { from, to in
            if from == "/home/test/out.txt", to.contains(".floe-backup-") {
                channel.mutate(Data("changed".utf8), path: from)
            }
        }
        do {
            _ = try await domain.uploadData(
                laneID: lane.id,
                remotePath: "/home/test/out.txt",
                data: Data("new".utf8),
                expectedRevision: "sha256:\(FloeDigest.sha256Hex(original))",
                overwrite: true,
                owner: owner())
            Issue.record("Expected revisionMismatch")
        } catch let error as C05SFTPError {
            #expect(error.code == .revisionMismatch)
            let retained = try #require(error.retainedPath)
            #expect(channel.data(at: retained) == Data("changed".utf8))
            #expect(channel.data(at: "/home/test/out.txt") == nil)
        }
    }

}

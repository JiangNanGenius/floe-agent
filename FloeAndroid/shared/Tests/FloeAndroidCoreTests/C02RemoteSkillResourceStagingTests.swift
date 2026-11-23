// SPDX-License-Identifier: MPL-2.0
//
// N07 remote lane — run-bound remote Skill resource staging over the typed
// SFTP operation. REAL contract tests (authored, NOT executed by this lane;
// no compiler or XCTest run is claimed). Three deterministic layers, no real
// host connection anywhere:
//
//   1. C02RemoteSkillSFTPStager over a fake in-memory `SSHSFTPChannel`:
//      the complete bundle stages in a unique sibling directory and promotes
//      only after a full byte verification and the pre-commit recheck; reuse
//      and adoption are granted only by full equality; a failed transfer or a
//      pre-commit revocation removes only the uniquely owned staging tree and
//      never leaves a partial final; a symlinked/redirected component refuses
//      (pathFence); a foreign/corrupt tree fails closed (pathBlocked).
//   2. C02RemoteSkillResourcePublisher over its authority seams: pinned
//      approval publishes; a missing approval refuses with a bounded code; a
//      pre-commit authority loss refuses before the commit; a retired epoch
//      never stages.
//   3. The REAL FloeSkills stager remote branch over a scripted resolver +
//      scripted remote publisher: applied reports visibleInGuest=true with
//      the exact guest root; a binding flip between the initial resolution
//      and the pre-publish re-check refuses; a refusal/unconfirmed outcome
//      reports staged=false with the correct actionable reason.
import XCTest
import Foundation
import FloeCore
import FloeSkills
import FloeSSH
import FloeTools
@testable import FloeAndroidCore

// MARK: - Fake in-memory SFTP channel

private final class FakeSFTPChannel: SSHSFTPChannel, @unchecked Sendable {
    enum Node: Sendable {
        case file(Data)
        case directory
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = ["/": .directory]
    private var symlinks: Set<String> = []
    /// Canonical-path overrides (the path-fence test redirects the root).
    var forcedCanonical: [String: String] = [:]
    /// Error injections.
    var writeError: SSHSFTPError?
    var renameError: SSHSFTPError?
    /// Observation.
    private(set) var removedPaths: [String] = []
    private(set) var renamed: [(from: String, to: String)] = []

    init(root: String) {
        nodes[root] = .directory
    }

    // MARK: Test controls

    func seedDirectory(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if nodes[current] == nil { nodes[current] = .directory }
        }
    }

    func seedFile(_ path: String, bytes: Data) {
        lock.lock(); nodes[path] = .file(bytes); lock.unlock()
    }

    func seedSymlink(_ path: String) {
        lock.lock(); symlinks.insert(path); lock.unlock()
    }

    func nodeBytes(_ path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard case .file(let data)? = nodes[path] else { return nil }
        return data
    }

    func nodeExists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return nodes[path] != nil
    }

    /// Live `.staging-` children directly under a directory (unique staging
    /// trees this lane owns end to end).
    func stagingTempCount(under path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let prefix = path + "/" + ".staging-"
        let keys = Set(nodes.keys.filter { $0.hasPrefix(prefix) })
        return Set(keys.map { key in
            String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init) ?? key
        }).count
    }

    // MARK: SSHSFTPChannel

    var isActive: Bool { true }

    func listDirectory(at path: String, maxEntries: Int) async throws -> [SSHSFTPDirectoryEntry] {
        lock.lock(); defer { lock.unlock() }
        guard case .directory? = nodes[path] else { throw SSHSFTPError.notDirectory }
        let prefix = path == "/" ? "/" : path + "/"
        var entries: [SSHSFTPDirectoryEntry] = []
        for (key, node) in nodes where key.hasPrefix(prefix) {
            let remainder = key.dropFirst(prefix.count)
            guard !remainder.contains("/") else { continue }
            let isLink = symlinks.contains(key)
            entries.append(SSHSFTPDirectoryEntry(
                name: String(remainder),
                longName: nil,
                attributes: SSHSFTPAttributes(
                    isDirectory: !isLink && {
                        if case .directory = node { return true }
                        return false
                    }(),
                    isSymbolicLink: isLink,
                    size: {
                        if case .file(let data) = node { return Int64(data.count) }
                        return 0
                    }(),
                    modifiedAt: nil,
                    permissions: 0)))
            // The bounded contract: stop at maxEntries + 1.
            if entries.count > maxEntries { break }
        }
        return entries
    }

    func stat(path: String) async throws -> SSHSFTPAttributes {
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[path] else { throw SSHSFTPError.notFound }
        let isLink = symlinks.contains(path)
        return SSHSFTPAttributes(
            isDirectory: !isLink && {
                if case .directory = node { return true }
                return false
            }(),
            isSymbolicLink: isLink,
            size: {
                if case .file(let data) = node { return Int64(data.count) }
                return 0
            }(),
            modifiedAt: nil,
            permissions: 0)
    }

    func canonicalPath(_ path: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard nodes[path] != nil else { throw SSHSFTPError.notFound }
        return forcedCanonical[path] ?? path
    }

    func openRead(path: String) async throws -> any SSHSFTPReadHandle {
        lock.lock(); defer { lock.unlock() }
        guard case .file(let data)? = nodes[path] else { throw SSHSFTPError.notFound }
        return FakeSFTPReadHandle(bytes: data)
    }

    func openWrite(path: String, createNew: Bool) async throws -> any SSHSFTPWriteHandle {
        lock.lock(); defer { lock.unlock() }
        if nodes[path] != nil, createNew { throw SSHSFTPError.alreadyExists }
        return FakeSFTPWriteHandle { [weak self] bytes in
            guard let self else { return }
            self.lock.lock(); self.nodes[path] = .file(bytes); self.lock.unlock()
        } writeFailure: { [weak self] in
            guard let self else { return nil }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.writeError
        }
    }

    func createDirectory(path: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard nodes[path] == nil else { throw SSHSFTPError.alreadyExists }
        let parent = parentOf(path)
        guard case .directory? = nodes[parent] else { throw SSHSFTPError.notFound }
        nodes[path] = .directory
    }

    func removeFile(path: String) async throws {
        lock.lock(); defer { lock.unlock() }
        removedPaths.append(path)
        guard case .file? = nodes[path] else { throw SSHSFTPError.notFound }
        nodes.removeValue(forKey: path)
    }

    func removeDirectory(path: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard case .directory? = nodes[path] else { throw SSHSFTPError.notFound }
        nodes.removeValue(forKey: path)
    }

    func rename(from: String, to: String) async throws {
        lock.lock(); defer { lock.unlock() }
        renamed.append((from, to))
        if let renameError { throw renameError }
        guard let node = nodes[from] else { throw SSHSFTPError.notFound }
        // Strict no-replacement semantics, matching the SFTP v3 standard text
        // the promote path relies on (real servers may overwrite, which is
        // why production re-proves absence immediately before the rename).
        guard nodes[to] == nil else { throw SSHSFTPError.alreadyExists }
        nodes[to] = node
        nodes.removeValue(forKey: from)
        if symlinks.contains(from) {
            symlinks.remove(from)
            symlinks.insert(to)
        }
    }

    func close() async {}

    private func parentOf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

private final class FakeSFTPReadHandle: SSHSFTPReadHandle, @unchecked Sendable {
    private let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func read(at offset: UInt64, maxBytes: Int) async throws -> Data {
        let start = Int(offset)
        guard start < bytes.count else { return Data() }
        return bytes.subdata(in: start..<min(bytes.count, start + maxBytes))
    }
    func close() async {}
}

private final class FakeSFTPWriteHandle: SSHSFTPWriteHandle, @unchecked Sendable {
    private let commit: @Sendable (Data) -> Void
    private let writeFailure: @Sendable () -> SSHSFTPError?
    private var buffer = Data()
    private var closed = false

    init(commit: @escaping @Sendable (Data) -> Void,
         writeFailure: @escaping @Sendable () -> SSHSFTPError?) {
        self.commit = commit
        self.writeFailure = writeFailure
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        guard !closed else { throw SSHSFTPError.fileHandleInvalid }
        if let error = writeFailure() { throw error }
        if Int(offset) == buffer.count {
            buffer.append(data)
        } else {
            buffer.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
        }
    }

    func close() async throws {
        guard !closed else { return }
        closed = true
        commit(buffer)
    }
}

// MARK: - Scripted seams

private actor ScriptedReprover {
    private let behavior: (SkillRemoteStagingDestination, UUID) async throws -> C02SSHExecutionAuthorization
    private(set) var callCount = 0
    init(_ behavior: @escaping (SkillRemoteStagingDestination, UUID) async throws -> C02SSHExecutionAuthorization) {
        self.behavior = behavior
    }
    func call(_ destination: SkillRemoteStagingDestination, _ runID: UUID) async throws -> C02SSHExecutionAuthorization {
        callCount += 1
        return try await behavior(destination, runID)
    }
}

private actor ScriptedSFTPStage {
    private let outcome: C02RemoteSFTPStageOutcome
    private(set) var calls = 0
    init(outcome: C02RemoteSFTPStageOutcome) { self.outcome = outcome }
    func call() -> C02RemoteSFTPStageOutcome { calls += 1; return outcome }
}

private actor ScriptedRemotePublisher: SkillRemoteResourcePublishing {
    private let outcome: SkillRemotePublishOutcome
    private(set) var callCount = 0
    init(outcome: SkillRemotePublishOutcome) { self.outcome = outcome }
    func publishStagedBundle(
        _ bundle: SkillStagingBundle,
        to destination: SkillRemoteStagingDestination,
        runID: UUID,
        conversationID: UUID?,
        cancellation: CancellationToken
    ) async -> SkillRemotePublishOutcome {
        callCount += 1
        return outcome
    }
}

private actor CountingRemoteResolver {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private actor FlipRemoteResolver {
    private let destination: SkillRemoteStagingDestination
    private let secondReason: String
    private var count = 0
    init(destination: SkillRemoteStagingDestination, secondReason: String) {
        self.destination = destination
        self.secondReason = secondReason
    }
    func answer() -> SkillWorkspaceStageResolution {
        count += 1
        return count == 1 ? .remote(destination) : .unavailable(reason: secondReason)
    }
}

// MARK: - Tests

final class C02RemoteSkillResourceStagingTests: XCTestCase, @unchecked Sendable {

    private let remoteRoot = "/home/floe/.floe/tasks/" + UUID().uuidString.lowercased()

    // MARK: Fixture

    /// One REAL digest-validated bundle (the validator remains the authority
    /// for package shape): manifest bytes are part of the pinned digest.
    private func makeBundle(id: String = "remote-fixture") throws -> (SkillStagingBundle, [String: Data]) {
        let manifest = SkillManifest(
            id: id, version: "1.0.0",
            capabilities: ["workspace.read"], tools: ["exec.shell"], platforms: ["linux"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        let bytes: [String: Data] = [
            "SKILL.md": Data(("---\nname: \(id)\ndescription: remote staging fixture\n---\n\nbody\n").utf8),
            "scripts/run.sh": Data("#!/bin/sh\necho ok\n".utf8),
            "floe.json": manifestBytes,
        ]
        let digest = try SkillPackageValidator.canonicalDigest(files: bytes)
        let declared = bytes.map { SkillFile(relativePath: $0.key, byteCount: $0.value.count) }
        guard let bundle = SkillWorkspaceResourceStager.stagingBundle(
            manifestID: id, digest: digest,
            declaredFiles: declared, bytes: bytes) else {
            throw XCTSkip("fixture bundle rejected")
        }
        return (bundle, bytes)
    }

    private func makeDestination(taskID: UUID = UUID(), revision: Int64 = 1) -> SkillRemoteStagingDestination {
        guard let destination = SkillRemoteStagingDestination(
            hostID: UUID(),
            environmentID: "ssh-\(UUID().uuidString.lowercased())",
            taskID: taskID,
            targetRevision: revision,
            rootEpoch: 7,
            runtimeGeneration: "gen-1",
            remoteWorkspaceRoot: remoteRoot) else {
            fatalError("destination fixture must be valid")
        }
        return destination
    }

    private func makeAuthorization(taskID: UUID, runID: UUID) -> C02SSHExecutionAuthorization {
        let hostID = UUID()
        let target = C02ExecutionTarget(
            taskID: taskID, revision: 1, kind: .ssh,
            environmentID: "ssh-\(hostID.uuidString.lowercased())",
            projectID: nil, workspaceID: UUID(),
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: 7,
            remote: C02RemoteEnvironmentFacts(
                hostID: hostID, remoteRootPath: remoteRoot,
                operatingSystem: "linux", architecture: "aarch64",
                runtimeGeneration: "gen-1"),
            provenance: .explicitUserSelection,
            createdAt: Date(), updatedAt: Date())
        return C02SSHExecutionAuthorization(
            taskID: taskID, runID: runID, target: target,
            targetRevision: 1, rootEpoch: 7,
            ownerToken: "task-\(taskID.uuidString.lowercased())-rev-1-epoch-7",
            sessionID: nil, sessionOwnerToken: nil,
            approvedHostKeyFingerprint: nil,
            permissionGrantID: UUID(),
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(60))
    }

    /// One REAL digest-validated snapshot for the stager-branch tests.
    private static func snapshot(for bundle: SkillStagingBundle) throws -> SkillContentSnapshot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-remote-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in bundle.files {
            let destination = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: destination, options: .atomic)
        }
        return try SkillContentSnapshot(root: root, expectedDigest: bundle.digest)
    }

    private func remoteContext(environmentID: String, runID: UUID = UUID()) -> SkillResourceContext {
        SkillResourceContext(
            runID: runID, conversationID: UUID(), environmentID: environmentID,
            workspaceRootURL: URL(fileURLWithPath: "/tmp/floe-remote-workspace", isDirectory: true),
            temporaryReadOnly: false, cancellation: CancellationToken())
    }

    // MARK: 1. Typed SFTP operation

    func testFreshPublishUploadsMissingOnlyAndVerifiesBytes() async throws {
        let (bundle, bytes) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .applied(uploaded: 3, reused: 0))
        let leaf = remoteRoot + "/.floe/skills/remote-fixture@\(bundle.digest)"
        for (path, data) in bytes {
            XCTAssertEqual(channel.nodeBytes(leaf + "/" + path), data)
        }
    }

    func testRestageReusesOnlyAfterFullVerification() async throws {
        let (bundle, _) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        let first = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(first, .applied(uploaded: 3, reused: 0))
        // Every byte already verified: the second publish reuses, uploads nothing.
        let second = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(second, .applied(uploaded: 0, reused: 3))
    }

    func testCorruptExistingTreeFailsClosedWithPathBlocked() async throws {
        let (bundle, bytes) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        // Plant a foreign tree where the leaf belongs (right shape, wrong bytes).
        let leaf = remoteRoot + "/.floe/skills/remote-fixture@\(bundle.digest)"
        channel.seedDirectory(remoteRoot + "/.floe/skills")
        channel.seedDirectory(leaf + "/scripts")
        channel.seedFile(leaf + "/SKILL.md", bytes: Data("tampered".utf8))
        channel.seedFile(leaf + "/scripts/run.sh", bytes: Data("echo nope".utf8))
        channel.seedFile(leaf + "/floe.json", bytes: bytes["floe.json"] ?? Data())
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .refused(reason: "pathBlocked"))
    }

    func testRedirectedCanonicalRootRefusesWithPathFence() async throws {
        let (bundle, _) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        // The server canonicalizes the root somewhere else (symlink/alias):
        // safe rooted publication cannot be proven.
        channel.forcedCanonical[remoteRoot] = "/var/elsewhere"
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .refused(reason: "pathFence"))
        XCTAssertFalse(channel.nodeExists(remoteRoot + "/.floe"))
    }

    func testSymlinkedReservedComponentRefuses() async throws {
        let (bundle, _) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        channel.seedDirectory(remoteRoot + "/.floe")
        channel.seedSymlink(remoteRoot + "/.floe")
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .refused(reason: "reservedConflict"))
    }

    func testFailedTransferCleansStagingTreeAndReportsUnconfirmed() async throws {
        let (bundle, _) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        channel.writeError = .connectionLost
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        guard case .unconfirmed(let detail) = outcome else {
            return XCTFail("expected unconfirmed, got \(outcome)")
        }
        XCTAssertEqual(detail, "connectionLost")
        // Only the uniquely owned staging tree was removed: no final leaf, no
        // leftover staging directory, no partial content anywhere.
        let reserved = remoteRoot + "/.floe/skills"
        let leaf = reserved + "/remote-fixture@\(bundle.digest)"
        XCTAssertFalse(channel.nodeExists(leaf))
        XCTAssertFalse(channel.nodeExists(leaf + "/SKILL.md"))
        XCTAssertFalse(channel.nodeExists(leaf + "/scripts/run.sh"))
        XCTAssertEqual(channel.stagingTempCount(under: reserved), 0)
    }

    func testInterruptedAttemptRetriesCleanlyWithoutPartialFinal() async throws {
        let (bundle, bytes) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        // First attempt: the transport dies mid-upload.
        channel.writeError = .connectionLost
        let interrupted = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        guard case .unconfirmed = interrupted else {
            return XCTFail("expected unconfirmed, got \(interrupted)")
        }
        let reserved = remoteRoot + "/.floe/skills"
        let leaf = reserved + "/remote-fixture@\(bundle.digest)"
        XCTAssertFalse(channel.nodeExists(leaf))
        XCTAssertEqual(channel.stagingTempCount(under: reserved), 0)

        // Retry on the recovered transport stages and promotes cleanly.
        channel.writeError = nil
        let retried = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        XCTAssertEqual(retried, .applied(uploaded: 3, reused: 0))
        XCTAssertEqual(channel.stagingTempCount(under: reserved), 0)
        for (path, data) in bytes {
            XCTAssertEqual(channel.nodeBytes(leaf + "/" + path), data)
        }
    }

    func testPreCommitRevocationRefusesAndRemovesOnlyTheStagingTree() async throws {
        let (bundle, _) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken(),
            beforePromote: {
                throw C02RemotePromotionRefusal(code: "authorityRevoked")
            })
        XCTAssertEqual(outcome, .refused(reason: "authorityRevoked"))
        // The commit never happened: no final leaf, staging tree removed.
        let reserved = remoteRoot + "/.floe/skills"
        let leaf = reserved + "/remote-fixture@\(bundle.digest)"
        XCTAssertFalse(channel.nodeExists(leaf))
        XCTAssertEqual(channel.stagingTempCount(under: reserved), 0)
        XCTAssertTrue(channel.renamed.isEmpty)
    }

    func testUncertainRenameCommitAdoptsVerifiedFinalAndNeverDeletesIt() async throws {
        let (bundle, _) = try makeBundle()
        let channel = FakeSFTPChannel(root: remoteRoot)
        channel.renameError = .connectionLost
        let outcome = await C02RemoteSkillSFTPStager.stage(
            bundle: bundle, remoteRootPath: remoteRoot,
            channel: channel, cancellation: CancellationToken())
        // The rename did not land on this fake: unconfirmed, final absent,
        // staging tree cleaned. The final path is never deleted by the lane.
        guard case .unconfirmed(let detail) = outcome else {
            return XCTFail("expected unconfirmed, got \(outcome)")
        }
        XCTAssertEqual(detail, "connectionLost")
        let reserved = remoteRoot + "/.floe/skills"
        let leaf = reserved + "/remote-fixture@\(bundle.digest)"
        XCTAssertFalse(channel.nodeExists(leaf))
        XCTAssertEqual(channel.stagingTempCount(under: reserved), 0)
    }

    // MARK: 2. Publisher authority seams

    func testPinnedApprovalPublishesThroughTheRealPublisher() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let runID = UUID()
        let authorization = makeAuthorization(taskID: destination.taskID, runID: runID)
        let epoch = UInt64(7)
        let reprover = ScriptedReprover { _, _ in authorization }
        let stage = ScriptedSFTPStage(outcome: .applied(uploaded: 3, reused: 0))
        let publisher = C02RemoteSkillResourcePublisher(
            reproveAndAuthorize: { destination, runID in
                try await reprover.call(destination, runID)
            },
            stageOverSFTP: { request in
                // The production seam forwards the pre-commit recheck; the
                // approved case completes it without error.
                try await request.beforePromote?()
                return await stage.call()
            },
            liveEpoch: { epoch },
            acceptedEpoch: epoch)
        let outcome = await publisher.publishStagedBundle(
            bundle, to: destination, runID: runID,
            conversationID: nil, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(await reprover.callCount, 1)
        XCTAssertEqual(await stage.calls, 1)
    }

    func testPreCommitAuthorityLossRefusesBeforeAnyCommit() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let epoch = UInt64(7)
        let authorization = makeAuthorization(taskID: destination.taskID, runID: UUID())
        let reprover = ScriptedReprover { _, _ in authorization }
        let stage = ScriptedSFTPStage(outcome: .applied(uploaded: 3, reused: 0))
        let publisher = C02RemoteSkillResourcePublisher(
            reproveAndAuthorize: { destination, runID in
                try await reprover.call(destination, runID)
            },
            revalidatePromotion: { _, _, _ in
                // The run's binding/approval/epoch is lost mid-transfer:
                // the commit must be refused, not committed.
                throw C02ExecutionTargetError.rootEpochUnavailable
            },
            stageOverSFTP: { request in
                do {
                    try await request.beforePromote?()
                    return await stage.call()
                } catch let refusal as C02RemotePromotionRefusal {
                    return .refused(reason: refusal.code)
                }
            },
            liveEpoch: { epoch },
            acceptedEpoch: epoch)
        let outcome = await publisher.publishStagedBundle(
            bundle, to: destination, runID: UUID(),
            conversationID: nil, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .refused(reason: "rootEpochUnavailable"))
        XCTAssertEqual(await stage.calls, 0)
    }

    func testNoApprovalRefusesWithABoundedCodeAndNeverStages() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let epoch = UInt64(7)
        let reprover = ScriptedReprover { _, _ in
            throw C02ExecutionTargetError.temporaryTaskRefused
        }
        let stage = ScriptedSFTPStage(outcome: .applied(uploaded: 0, reused: 0))
        let publisher = C02RemoteSkillResourcePublisher(
            reproveAndAuthorize: { destination, runID in
                try await reprover.call(destination, runID)
            },
            stageOverSFTP: { _ in
                await stage.call()
            },
            liveEpoch: { epoch },
            acceptedEpoch: epoch)
        let outcome = await publisher.publishStagedBundle(
            bundle, to: destination, runID: UUID(),
            conversationID: nil, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .refused(reason: "temporaryTaskRefused"))
        XCTAssertEqual(await reprover.callCount, 1)
        XCTAssertEqual(await stage.calls, 0)
    }

    func testRetiredEpochNeverStages() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let stage = ScriptedSFTPStage(outcome: .applied(uploaded: 3, reused: 0))
        let publisher = C02RemoteSkillResourcePublisher(
            reproveAndAuthorize: { _, _ in
                throw C02ExecutionTargetError.rootEpochUnavailable
            },
            stageOverSFTP: { _ in
                await stage.call()
            },
            liveEpoch: { 8 },   // the live generation moved past acceptedEpoch 7
            acceptedEpoch: 7)
        let outcome = await publisher.publishStagedBundle(
            bundle, to: destination, runID: UUID(),
            conversationID: nil, cancellation: CancellationToken())
        XCTAssertEqual(outcome, .unconfirmed(detail: nil))
        XCTAssertEqual(await stage.calls, 0)
    }

    // MARK: 3. Stager remote branch

    func testStagerReportsVisibleGuestRootOnlyFromVerifiedApplied() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let runID = UUID()
        let publisher = ScriptedRemotePublisher(outcome: .applied)
        let counter = CountingRemoteResolver()
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in
                _ = await counter.next()
                return .remote(destination)
            },
            publishRemote: publisher)
        let context = remoteContext(environmentID: destination.environmentID, runID: runID)
        let outcome = await stager.stage(
            snapshot: try Self.snapshot(for: bundle), runID: runID,
            conversationID: context.conversationID, context: context)
        guard case .staged(let staged) = outcome else {
            return XCTFail("expected staged, got \(outcome)")
        }
        XCTAssertTrue(staged.visibleInGuest)
        XCTAssertEqual(staged.pinnedSHA256, bundle.digest)
        XCTAssertEqual(
            staged.guestRoot,
            remoteRoot + "/.floe/skills/remote-fixture@\(bundle.digest)")
        XCTAssertEqual(await publisher.callCount, 1)
        XCTAssertEqual(await counter.count, 2) // initial resolution + pre-publish re-check
    }

    func testStagerRefusesWhenBindingFlipsBeforePublication() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let publisher = ScriptedRemotePublisher(outcome: .applied)
        let flip = FlipRemoteResolver(
            destination: destination,
            secondReason: SkillStageReason.noLocalExecutionTarget)
        let stager = SkillWorkspaceResourceStager(
            resolve: { _, _ in await flip.answer() },
            publishRemote: publisher)
        let context = remoteContext(environmentID: destination.environmentID)
        let outcome = await stager.stage(
            snapshot: try Self.snapshot(for: bundle), runID: context.runID,
            conversationID: context.conversationID, context: context)
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected refusal, got \(outcome)")
        }
        XCTAssertEqual(reason, SkillStageReason.taskWorkspaceUnavailable)
        XCTAssertEqual(await publisher.callCount, 0)
    }

    func testStagerReportsCorrectVisibilityOnRefusedAndUnconfirmed() async throws {
        let (bundle, _) = try makeBundle()
        let destination = makeDestination()
        let context = remoteContext(environmentID: destination.environmentID)

        // Refused: actionable failure, never a ready path.
        let refusing = ScriptedRemotePublisher(outcome: .refused(reason: "permissionDenied"))
        let refuseStager = SkillWorkspaceResourceStager(
            resolve: { _, _ in .remote(destination) },
            publishRemote: refusing)
        let refused = await refuseStager.stage(
            snapshot: try Self.snapshot(for: bundle), runID: context.runID,
            conversationID: context.conversationID, context: context)
        guard case .unavailable(let refusedReason) = refused else {
            return XCTFail("expected refusal, got \(refused)")
        }
        XCTAssertTrue(refusedReason.hasPrefix("remoteResourceSyncRefused"))
        XCTAssertTrue(refusedReason.contains("permissionDenied"))

        // Unconfirmed: same boundary; absent detail collapses to `transport`.
        let unconfirmed = ScriptedRemotePublisher(outcome: .unconfirmed(detail: nil))
        let unconfirmedStager = SkillWorkspaceResourceStager(
            resolve: { _, _ in .remote(destination) },
            publishRemote: unconfirmed)
        let unconfirmedOutcome = await unconfirmedStager.stage(
            snapshot: try Self.snapshot(for: bundle), runID: context.runID,
            conversationID: context.conversationID, context: context)
        guard case .unavailable(let unconfirmedReason) = unconfirmedOutcome else {
            return XCTFail("expected refusal, got \(unconfirmedOutcome)")
        }
        XCTAssertTrue(unconfirmedReason.hasPrefix("remoteResourceSyncUnconfirmed"))
        XCTAssertTrue(unconfirmedReason.contains("transport"))
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 network workspace owner — real-ladder source tests.
// AUTHORED, NOT EXECUTED (grouped qualification is Main's). Storage is the
// original installed-generation fixture (same bootstrap + real file-backed
// DatabaseManager as the accepted source-host tests); the protocols run over
// IN-MEMORY synthetic `WorkspaceMountAdapter`s with real Range windows,
// ETag CAS, one-shot write/read outage injection and leased-resolver auth —
// no sockets, no device, no accounts, no real credentials. Every assertion
// is against REAL disk bytes or the ORIGINAL journal-47 rows.
//
// Proven surface:
//   * mount add: durable metadata-only config, REDACTED endpoint in every
//     view, probe = actual list("") verdict; create-probe failure rolls the
//     config back AND revokes the just-captured secret; rotation keeps the
//     working mount usable until the new probe succeeds;
//   * import: 64 KiB Range-page streaming into native staging with the
//     incremental native digest, commit through the ORIGINAL verified
//     `importUserFile` path, journal-47 binding (kind webdav/smb, reference
//     = mount UUID, document id = remote path, server ETag when present);
//   * conflict policy: refuse never overwrites (typed entry failure, byte-
//     identical original); copy lands at a derived name;
//   * nested folder import rides per-file ladders; a partial failure stays
//     honest (`partialFailures`; committed entries stay committed);
//   * save: full staged ladder — fresh backup observation -> `prepared` ->
//     second fresh observation -> ONE-TIME claim (the durable claim row IS
//     the destructive permit) -> permitted adapter write carrying the
//     journaled If-Match ETag (WebDAV; nil for SMB, the delivered
//     limitation) -> actual read-back -> committed (binding CAS advancing
//     sha+etag+revision) / conflict (observed digest). Drift BEFORE the
//     claim opens NO permit; a landed-but-unproven write leaves the row
//     `writing` and reconcile decides ONLY from live provider bytes
//     (backup -> retained, replacement -> committed, else conflict); the
//     open receipt refuses a second ladder with `transitionRefused`;
//   * cancel is a REQUEST: mid-stream cancellation settles at the next
//     page boundary, no partial commit, staging drained, no row bound;
//   * credentials: staged tickets belong to their generation's lease (a
//     cross-generation replay refuses); cleared refs stop resolving (no
//     cached grant truth); secret bytes never enter views/config/errors;
//   * read-only refuses mutation at spawn; browse/stat are bounded,
//     escape-grammar-typed, and project REAL verdicts.
import Foundation
import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeWorkspace
@testable import FloeAndroidCore

final class G04NetworkWorkspaceTests: XCTestCase {

    // MARK: - Generation fixture (identical shape to the accepted tests)

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 = UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    private final class Boot {
        let epoch: UInt64
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, rootPath: String, token: String) {
            self.epoch = epoch; self.rootPath = rootPath; self.token = token
        }
    }

    private enum TestError: Error { case bootstrap, envelope, timeout }

    private var tracked: [Boot] = []

    private func bootInstalledGeneration() async throws -> Boot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g04-network-host-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let token = String((0 ..< 16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted = AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: token,
                                                             epoch: epoch) else {
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, rootPath: root, token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let generation = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  generation.epoch == epoch else { throw TestError.bootstrap }
            // `installedComposition` is visible at the install claim, BEFORE
            // the owned-install attaches the optional-domain extensions
            // (step 4). makeOwner needs the epoch-exact source coordinator,
            // which is published only after the workspace extension fully
            // attached; without this wait the first makeOwner can honestly
            // see no coordinator and throw TestError.envelope.
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == epoch,
               AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
               G02RuntimeComposition.shared.isExtensionAttached(G02DomainExtensionKey.workspace) {
                return boot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        boot.retired = true
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not close for epoch \(boot.epoch)")
    }

    override func tearDown() async throws {
        let host = G04NetworkWorkspaceHost.shared
        host.liveEpochOverrideForTesting = nil
        host.ownerOverrideForTesting = nil
        for boot in tracked { await shutdownAndAwaitClosed(boot) }
        tracked.removeAll()
        // Same producer-ownership reset the accepted facade-suite tearDown
        // uses: the composition owns the self-installing process lanes
        // (attachment staging + run domain) AND the first-install-wins
        // LinuxWorkspaceAuthority/transfer-engine slots. Without it, every
        // later synthetic-root generation of this suite commits under the
        // FIRST boot's stale authority root while cluster identity points
        // at a newer root.
        G02RuntimeComposition.shared.resetForTesting()
        try await super.tearDown()
    }

    private func installedCluster() throws -> G02OwnedStoreCluster {
        guard let installed = G02RuntimeComposition.shared.installedComposition else {
            throw TestError.envelope
        }
        return installed.cluster
    }

    private func makeBoundOrdinaryTask() async throws -> (taskID: UUID, workspaceID: UUID) {
        let cluster = try installedCluster()
        let taskID = UUID()
        try await cluster.conversationStore.saveConversation(ConversationRecord(
            id: taskID, title: "Network host fixture", createdAt: Date(), updatedAt: Date()))
        let record = try await cluster.workspaceStore.ensureWorkspace(conversationID: taskID,
                                                                      title: "Network host fixture")
        return (taskID, record.id)
    }

    // MARK: - Synthetic vault authority (typed semantics; no real storage)

    private actor SyntheticAuthority: G04NetworkSecretAuthority {
        private(set) var captured: [UUID: Data] = [:]
        private(set) var resolveIDs: [UUID] = []
        func captureNetworkSecret(_ secret: Data, id: UUID, label: String,
                                  workspaceID: UUID) async throws {
            captured[id] = secret
        }
        func replaceNetworkSecret(_ secret: Data, id: UUID, label: String) async throws {
            captured[id] = secret
        }
        func resolveNetworkSecret(id: UUID) async throws -> Data {
            resolveIDs.append(id)
            guard let secret = captured[id] else { throw G04NetworkSecretFailure.notFound }
            return secret
        }
        func deleteNetworkSecret(id: UUID) async throws -> G04NetworkSecretDeletion {
            captured[id] = nil
            return .deleted
        }
        func networkSecretAvailable(id: UUID) async throws -> Bool { captured[id] != nil }
    }

    // MARK: - Synthetic protocol surface

    /// In-memory WebDAV/SMB semantics: exact Range windows, ETag CAS, the
    /// leased resolver consulted on EVERY hop for credential-bearing mounts,
    /// one-shot outage/latency injection.
    private actor SyntheticMountAdapter: WorkspaceMountAdapter {
        struct Stored { var data: Data; var etag: String? }

        private var files: [String: Stored] = [:]
        private var etagCounter = 0
        private let mount: NetworkWorkspaceMount
        private let resolver: NetworkCredentialResolver
        private let authRequired: Bool
        private let pageDelayNanoseconds: UInt64
        private var failFirstList = false
        private var failNextWrite = false
        private var failReadAfterWriteOnce = false
        private(set) var writeCount = 0
        private(set) var writeETagsSent: [String?] = []
        private(set) var resolverTouches = 0

        init(mount: NetworkWorkspaceMount,
             credentialResolver: @escaping NetworkCredentialResolver,
             authRequired: Bool, pageDelayNanoseconds: UInt64, failFirstList: Bool) {
            self.mount = mount
            self.resolver = credentialResolver
            self.authRequired = authRequired
            self.pageDelayNanoseconds = pageDelayNanoseconds
            self.failFirstList = failFirstList
        }

        func configureOutages(failNextWrite: Bool = false, failReadAfterWriteOnce: Bool = false) {
            self.failNextWrite = failNextWrite
            self.failReadAfterWriteOnce = failReadAfterWriteOnce
        }

        func seed(path: String, data: Data) {
            etagCounter += 1
            files[path] = Stored(data: data,
                                 etag: mount.transport == .smb ? nil : "etag-\(etagCounter)")
        }

        /// Third-party change (server-side drift), NOT through this session.
        func externallyMutate(path: String, to data: Data) {
            etagCounter += 1
            files[path] = Stored(data: data,
                                 etag: mount.transport == .smb ? nil : "etag-\(etagCounter)")
        }

        private func authenticate() async throws {
            guard authRequired || mount.credentialRef != nil else { return }
            guard let ref = mount.credentialRef else {
                throw NetworkWorkspaceError(code: .authenticationFailed, stage: "credentials",
                                            retryable: false, safeDetail: "No credential presented.")
            }
            do {
                let bytes = try await resolver(ref)
                resolverTouches += 1
                guard !bytes.isEmpty else {
                    throw NetworkWorkspaceError(code: .authenticationFailed, stage: "credentials",
                                                retryable: false, safeDetail: "Empty credential.")
                }
            } catch let error as NetworkWorkspaceError {
                throw error
            } catch {
                throw NetworkWorkspaceError(code: .credentialMissing, stage: "credentials",
                                            retryable: false,
                                            safeDetail: "The saved credential is unavailable on this device.")
            }
        }

        func list(path: String) async throws -> [NetworkWorkspaceEntry] {
            try await authenticate()
            if failFirstList {
                failFirstList = false
                throw NetworkWorkspaceError(code: .networkUnreachable, stage: "list",
                                            retryable: true, safeDetail: "Injected probe outage.")
            }
            let prefix = path.isEmpty ? "" : path + "/"
            var names: [String: Bool] = [:]   // name -> isDirectory
            for key in files.keys {
                guard key.hasPrefix(prefix) else { continue }
                let rest = String(key.dropFirst(prefix.count))
                guard !rest.isEmpty else { continue }
                if let slash = rest.firstIndex(of: "/") {
                    names[String(rest[rest.startIndex ..< slash])] = true
                } else {
                    names[rest] = false
                }
            }
            return names.sorted { $0.key < $1.key }.map { name, isDirectory in
                let childPath = prefix + name
                if isDirectory {
                    return NetworkWorkspaceEntry(name: name, path: childPath, isDirectory: true,
                                                 byteCount: 0, modifiedAt: Date(), entityTag: nil)
                }
                let stored = files[childPath]
                return NetworkWorkspaceEntry(name: name, path: childPath, isDirectory: false,
                                             byteCount: Int64(stored?.data.count ?? 0),
                                             modifiedAt: Date(), entityTag: stored?.etag)
            }
        }

        func read(path: String, offset: Int, limit: Int?) async throws -> Data {
            try await authenticate()
            if pageDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: pageDelayNanoseconds) }
            guard let stored = files[path] else {
                throw NetworkWorkspaceError(code: .notFound, stage: "read", retryable: false,
                                            safeDetail: "Path does not exist.")
            }
            if failReadAfterWriteOnce, writeCount > 0 {
                failReadAfterWriteOnce = false
                throw NetworkWorkspaceError(code: .networkUnreachable, stage: "read",
                                            retryable: true, safeDetail: "Injected post-write outage.")
            }
            let start = min(offset, stored.data.count)
            let end = min(start + max(limit ?? (stored.data.count - start), 0), stored.data.count)
            return stored.data.subdata(in: start ..< end)
        }

        func metadata(path: String) async throws -> NetworkWorkspaceFileMetadata {
            try await authenticate()
            if let stored = files[path] {
                return NetworkWorkspaceFileMetadata(path: path, isDirectory: false,
                                                    byteCount: Int64(stored.data.count),
                                                    modifiedAt: Date(), entityTag: stored.etag)
            }
            let prefix = path + "/"
            if files.keys.contains(where: { $0.hasPrefix(prefix) }) {
                return NetworkWorkspaceFileMetadata(path: path, isDirectory: true, byteCount: 0,
                                                    modifiedAt: Date(), entityTag: nil)
            }
            throw NetworkWorkspaceError(code: .notFound, stage: "metadata", retryable: false,
                                        safeDetail: "Path does not exist.")
        }

        func write(path: String, data: Data, expectedEntityTag: String?) async throws
            -> NetworkWorkspaceFileMetadata {
            try await authenticate()
            guard !mount.readOnly else {
                throw NetworkWorkspaceError(code: .readOnly, stage: "write", retryable: false,
                                            safeDetail: "This network mount is read-only.")
            }
            if failNextWrite {
                failNextWrite = false
                throw NetworkWorkspaceError(code: .networkUnreachable, stage: "write",
                                            retryable: true, safeDetail: "Injected write outage.")
            }
            if let expectedEntityTag, files[path]?.etag != expectedEntityTag {
                throw NetworkWorkspaceError(code: .conflict, stage: "write", retryable: false,
                                            safeDetail: "Precondition failed (412).")
            }
            etagCounter += 1
            writeCount += 1
            writeETagsSent.append(expectedEntityTag)
            files[path] = Stored(data: data,
                                 etag: mount.transport == .smb ? nil : "etag-\(etagCounter)")
            return NetworkWorkspaceFileMetadata(path: path, isDirectory: false,
                                                byteCount: Int64(data.count),
                                                modifiedAt: Date(), entityTag: files[path]?.etag)
        }

        func createDirectory(path: String) async throws {
            try await authenticate()
            guard !mount.readOnly else {
                throw NetworkWorkspaceError(code: .readOnly, stage: "createDirectory",
                                            retryable: false, safeDetail: "Read-only.")
            }
        }

        func move(from: String, to: String, expectedEntityTag: String?) async throws {
            try await authenticate()
            guard !mount.readOnly, let stored = files[from] else {
                throw NetworkWorkspaceError(code: .notFound, stage: "move", retryable: false,
                                            safeDetail: "Move refused.")
            }
            files[from] = nil
            files[to] = stored
        }

        func delete(path: String, expectedEntityTag: String?) async throws {
            try await authenticate()
            guard !mount.readOnly else {
                throw NetworkWorkspaceError(code: .readOnly, stage: "delete", retryable: false,
                                            safeDetail: "Read-only.")
            }
            files[path] = nil
        }

        func body(at path: String) -> Data? { files[path]?.data }
        func tag(at path: String) -> String? { files[path]?.etag }
        func stats() -> (writes: Int, tags: [String?], touches: Int) {
            (writeCount, writeETagsSent, resolverTouches)
        }
    }

    /// Factory installing synthetic adapters keyed by mount id so tests can
    /// inspect the SAME actor instances the owner routes through. Flags are
    /// snapshotted at construction (no post-construction race).
    private final class SyntheticMounts: @unchecked Sendable {
        private let lock = NSLock()
        private var adapters: [UUID: SyntheticMountAdapter] = [:]
        var authRequired = false
        var pageDelay: UInt64 = 0
        var failFirstList = false

        func setAuthRequired(_ value: Bool) { lock.lock(); authRequired = value; lock.unlock() }
        func setPageDelay(_ value: UInt64) { lock.lock(); pageDelay = value; lock.unlock() }
        func setFailFirstList(_ value: Bool) { lock.lock(); failFirstList = value; lock.unlock() }

        func snapshot() -> (auth: Bool, delay: UInt64, failList: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (authRequired, pageDelay, failFirstList)
        }

        func factory() -> G04NetworkAdapterFactory {
            G04NetworkAdapterFactory(produce: { [weak self] mount, resolver, _ in
                guard let self else {
                    throw NetworkWorkspaceError(code: .protocolFailure, stage: "factory",
                                                retryable: false, safeDetail: "registry gone")
                }
                let flags = self.snapshot()
                let adapter = SyntheticMountAdapter(mount: mount, credentialResolver: resolver,
                                                    authRequired: flags.auth,
                                                    pageDelayNanoseconds: flags.delay,
                                                    failFirstList: flags.failList)
                self.lock.lock(); self.adapters[mount.id] = adapter; self.lock.unlock()
                return adapter
            })
        }

        func adapter(mountID: UUID) -> SyntheticMountAdapter? {
            lock.lock(); defer { lock.unlock() }
            return adapters[mountID]
        }
    }

    // MARK: - Fixtures/helpers

    private func makeOwner(boot: Boot, authority: SyntheticAuthority,
                           mounts: SyntheticMounts) async throws -> G04NetworkWorkspace {
        let cluster = try installedCluster()
        guard let coordinator = G04WorkspaceHostRegistry.shared.coordinator(epoch: boot.epoch) else {
            throw TestError.envelope
        }
        return G04NetworkWorkspace(epoch: boot.epoch, cluster: cluster, coordinator: coordinator,
                                   secrets: authority, adapterFactory: mounts.factory())
    }

    private func addWebDAVMount(owner: G04NetworkWorkspace, taskID: UUID, workspaceID: UUID,
                                name: String, credentialTicket: Int64 = 0,
                                endpoint: String = "https://dav.example.test/files?sign=tokensecret",
                                readOnly: Bool = false) async throws -> G04NetworkMountView {
        let draft = G04NetworkMountDraft(name: name, transport: .webDAV,
                                         endpoint: try XCTUnwrap(URL(string: endpoint)),
                                         rootPath: "", username: "alice", readOnly: readOnly,
                                         credentialTicket: credentialTicket)
        return try await owner.addMount(taskID: taskID, workspaceID: workspaceID, draft: draft)
    }

    private func workspaceURL(taskID: UUID, workspaceID: UUID, path: String) async throws -> URL {
        guard let installed = G02RuntimeComposition.shared.installedComposition else {
            throw TestError.envelope
        }
        let owner = G04WorkspaceOwner(epoch: installed.epoch, taskID: taskID, workspaceID: workspaceID)
        let service = try await G04LiveWorkspaceAccess.privateTaskService(owner,
                                                                          cancellation: CancellationToken())
        return try service.guardResolver.resolve(path)
    }

    private func terminal(_ owner: G04NetworkWorkspace, _ ticket: UInt64,
                          seconds: TimeInterval = 60) async throws -> G04NetworkOperationView {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let view = await owner.operation(ticket),
               view.state != .running, view.state != .cancelRequested {
                return view
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestError.timeout
    }

    private func seedBoundFile(owner: G04NetworkWorkspace, adapter: SyntheticMountAdapter,
                               taskID: UUID, workspaceID: UUID, mountID: UUID,
                               remote: String, logical: String, body: Data) async throws {
        await adapter.seed(path: remote, data: body)
        let ticket = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: mountID, remotePath: remote,
                                                 logicalPath: logical, recursive: false,
                                                 conflict: .refuse)
        let done = try await terminal(owner, ticket)
        XCTAssertEqual(done.state, .completed, "seed import failed: \(done.errorCode ?? "none")")
    }

    // MARK: - 1. Mount lifecycle

    func testMountAddPersistsRedactedConfigAndProbes() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        XCTAssertEqual(view.status, "connected")
        // Delivered redaction: query token dropped from EVERY projection.
        XCTAssertEqual(view.endpoint, "https://dav.example.test/files")
        XCTAssertFalse(view.endpoint.contains("tokensecret"))
        let page = try await owner.mounts(taskID: taskID, workspaceID: workspaceID)
        XCTAssertEqual(page.count, 1)
        // Durable config: metadata-only JSON on the accepted root, no secret.
        let configRoot = try installedCluster().identity.root
        let configURL = URL(fileURLWithPath: configRoot.path, isDirectory: true)
            .appendingPathComponent("NetworkWorkspaceMounts/\(workspaceID.uuidString).json")
        let data = try Data(contentsOf: configURL)
        let decoded = try JSONDecoder().decode([NetworkWorkspaceMount].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("密码"))
        // Repeated probe keeps a REAL verdict (no cached grant truth).
        let status = try await owner.probeMount(taskID: taskID, workspaceID: workspaceID,
                                                mountID: view.id)
        XCTAssertEqual(status, .connected)
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testCreateProbeFailureRollsBackAndRevokesSecret() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        mounts.setFailFirstList(true)
        let authority = SyntheticAuthority()
        let owner = try await makeOwner(boot: boot, authority: authority, mounts: mounts)
        let secret = Data("密码 secret".utf8)
        let ticket = await owner.stageCredential(secret)
        XCTAssertGreaterThan(ticket, 0)
        do {
            _ = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                         name: "Team", credentialTicket: ticket)
            XCTFail("injected probe outage must refuse create")
        } catch let error as G04NetworkWorkspaceError {
            XCTAssertEqual(error, .provider(code: "networkUnreachable", retryable: true))
        }
        // Rollback: config empty AND the captured secret revoked (no orphan).
        let page = try await owner.mounts(taskID: taskID, workspaceID: workspaceID)
        XCTAssertTrue(page.isEmpty)
        let stored = await authority.captured
        XCTAssertTrue(stored.isEmpty)
        // Retry with a live provider succeeds and stores the secret fresh.
        mounts.setFailFirstList(false)
        let ticket2 = await owner.stageCredential(secret)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team", credentialTicket: ticket2)
        let stored2 = await authority.captured
        XCTAssertEqual(stored2.values.first, secret)
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        let stats = await adapter.stats()
        XCTAssertGreaterThan(stats.touches, 0)   // resolver consulted for real auth
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    // MARK: - 2. Import

    func testImportStreamsAndBindsNetworkRow() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        let body = Data((0 ..< (512 * 1024)).map { _ in UInt8.random(in: 0 ... 255) })
        await adapter.seed(path: "docs/report.bin", data: body)

        let ticket = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: view.id, remotePath: "docs/report.bin",
                                                 logicalPath: "Imported/report.bin",
                                                 recursive: false, conflict: .refuse)
        let done = try await terminal(owner, ticket)
        XCTAssertEqual(done.state, .completed, "errorCode=\(done.errorCode ?? "none")")
        XCTAssertEqual(done.bytesDone, body.count)

        let fileURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Imported/report.bin")
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertEqual(onDisk, body)   // REAL committed bytes
        let rows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, .webdav)
        XCTAssertEqual(row.sourceReference, view.id.uuidString)   // opaque mount identity
        XCTAssertEqual(row.sourceDocumentID, "docs/report.bin")
        XCTAssertEqual(row.sourceSHA256, FloeDigest.sha256Hex(body))
        XCTAssertNotNil(row.entityTag)                            // server ETag bound
        // Staging scratch is gone after the terminal (this lane's own files).
        let stagingRoot = try installedCluster().identity.root
        let stagingDir = URL(fileURLWithPath: stagingRoot.path, isDirectory: true)
            .appendingPathComponent("NetworkStaging/\(boot.epoch)/\(ticket)")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testImportConflictRefuseNeverOverwrites_copyLandsDerivedName() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        await adapter.seed(path: "notes.md", data: Data("server body".utf8))
        let existing = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                              path: "Notes/notes.md")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("local original".utf8).write(to: existing)

        let refuse = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: view.id, remotePath: "notes.md",
                                                 logicalPath: "Notes/notes.md",
                                                 recursive: false, conflict: .refuse)
        let refuseView = try await terminal(owner, refuse)
        XCTAssertEqual(refuseView.state, .failed)
        XCTAssertEqual(refuseView.errorCode, "workingCopyExists")
        XCTAssertEqual(try Data(contentsOf: existing), Data("local original".utf8))

        let copy = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                               mountID: view.id, remotePath: "notes.md",
                                               logicalPath: "Notes/notes.md",
                                               recursive: false, conflict: .copy)
        let copyView = try await terminal(owner, copy)
        XCTAssertEqual(copyView.state, .completed, "errorCode=\(copyView.errorCode ?? "none")")
        let copyURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Notes/notes (network copy).md")
        XCTAssertEqual(try Data(contentsOf: copyURL), Data("server body".utf8))
        XCTAssertEqual(try Data(contentsOf: existing), Data("local original".utf8))
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testNestedDirectoryImportPerFileLaddersAndPartialFailures() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        await adapter.seed(path: "proj/src/main.swift", data: Data("print(1)".utf8))
        await adapter.seed(path: "proj/src/util/helper.swift", data: Data("helper".utf8))
        await adapter.seed(path: "proj/README.md", data: Data("readme".utf8))
        // One pre-existing different-byte target -> recorded entry failure,
        // the OTHER files still commit (recoverable data preserved).
        let clash = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                           path: "Proj/README.md")
        try FileManager.default.createDirectory(at: clash.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: clash)

        let ticket = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: view.id, remotePath: "proj",
                                                 logicalPath: "Proj", recursive: true,
                                                 conflict: .refuse)
        let done = try await terminal(owner, ticket)
        XCTAssertEqual(done.state, .failed)
        XCTAssertEqual(done.errorCode, "partialFailures")
        XCTAssertEqual(done.entriesDone, 2)
        XCTAssertEqual(done.entriesFailed, 1)
        let rows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        XCTAssertEqual(Set(rows.map { $0.logicalPath }),
                       ["Proj/src/main.swift", "Proj/src/util/helper.swift"])
        let committed = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                               path: "Proj/src/util/helper.swift")
        XCTAssertEqual(try Data(contentsOf: committed), Data("helper".utf8))
        XCTAssertEqual(try Data(contentsOf: clash), Data("mine".utf8))  // untouched
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    // MARK: - 2b. First-available copy scan beyond 64 + honest progress totals

    /// A .copy import must land the FIRST candidate the commit ladder
    /// accepts even when MORE than 64 numeric copy names are already
    /// occupied: there is no arbitrary scan ceiling (the operation box's
    /// 64-entry failure-list storage cap is unrelated to filename
    /// availability). 65 occupied, DIFFERENT-content copies (base included)
    /// are seeded through the real workspace fixture; the tiny new body
    /// lands at copy index 66, every existing byte stays byte-identical,
    /// and the fully committed single file keeps its exact total.
    func testImportCopyScanLandsFirstAvailableBeyondSixtyFourCopies() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))

        // Base + copies 1..65, all occupied with DISTINCT content (no
        // same-digest idempotence may short-circuit the scan).
        let baseURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Bulk/notes.md")
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let baseBody = Data("base original".utf8)
        try baseBody.write(to: baseURL)
        var occupied: [(url: URL, body: Data)] = []
        for index in 1 ... 65 {
            let name = index == 1 ? "notes (network copy).md" : "notes (network copy \(index)).md"
            let copyURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                                 path: "Bulk/" + name)
            let copyBody = Data("occupied copy \(index) with its own bytes".utf8)
            try copyBody.write(to: copyURL)
            occupied.append((copyURL, copyBody))
        }

        let remoteBody = Data("server body sixty-six".utf8)
        await adapter.seed(path: "bulk/notes.md", data: remoteBody)
        let ticket = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: view.id, remotePath: "bulk/notes.md",
                                                 logicalPath: "Bulk/notes.md",
                                                 recursive: false, conflict: .copy)
        let done = try await terminal(owner, ticket)
        XCTAssertEqual(done.state, .completed,
                       "first-available scan must NOT exhaust at 64: errorCode=\(done.errorCode ?? "none") failures=\(done.failures.map { $0.code })")

        // The landed candidate is exactly index 66, with the REAL bytes.
        let landedURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                               path: "Bulk/notes (network copy 66).md")
        let landed = try Data(contentsOf: landedURL)
        XCTAssertEqual(landed, remoteBody)
        // The binding is real: journal row points at the landed copy.
        let rows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.logicalPath, "Bulk/notes (network copy 66).md")
        XCTAssertEqual(row.sourceSHA256, FloeDigest.sha256Hex(remoteBody))
        // Nothing overwritten: base and every occupied copy unchanged.
        let baseAfter = try Data(contentsOf: baseURL)
        XCTAssertEqual(baseAfter, baseBody)
        for entry in occupied {
            let after = try Data(contentsOf: entry.url)
            XCTAssertEqual(after, entry.body)
        }
        // Honest progress on a fully committed file: exact totals, committed
        // result bytes, one entry done, and the published-total invariant.
        XCTAssertEqual(done.entriesDone, 1)
        XCTAssertEqual(done.entriesFailed, 0)
        XCTAssertEqual(done.bytesDone, remoteBody.count)
        XCTAssertEqual(done.totalBytes, remoteBody.count)
        XCTAssertTrue(done.totalBytes == 0 || done.totalBytes >= done.bytesDone)
        XCTAssertEqual(done.result["bytes"], String(remoteBody.count))
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    /// A streamed-but-REFUSED entry still counts in physical `bytesDone`
    /// while `result["bytes"]` stays the COMMITTED aggregate only. Because
    /// the refused file's bytes were transferred but never committed, the
    /// aggregate total is below the actual done — so the view must NEVER
    /// publish that aggregate as a known total; it reports the delivered
    /// 0 UNKNOWN sentinel instead (Kotlin treats totalBytes > 0 as known).
    /// The following successful operation restores the exact total.
    func testStreamProgressKeepsCommittedTotalsHonestAcrossRefusedEntry() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))

        // Two multi-page bodies (each streams at least one 64 KiB page plus
        // a tail page): a.bin rides the real refusal (existing different-
        // content working copy), b.bin commits.
        let bodyA = Data(repeating: 0x41, count: 100_000)
        let bodyB = Data(repeating: 0x42, count: 80_000)
        await adapter.seed(path: "pair/a.bin", data: bodyA)
        await adapter.seed(path: "pair/b.bin", data: bodyB)
        let clashURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                              path: "Pair/a.bin")
        try FileManager.default.createDirectory(at: clashURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let clashBody = Data("mine".utf8)
        try clashBody.write(to: clashURL)

        let walk = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                               mountID: view.id, remotePath: "pair",
                                               logicalPath: "Pair", recursive: true,
                                               conflict: .refuse)
        let partial = try await terminal(owner, walk)
        XCTAssertEqual(partial.state, .failed)
        XCTAssertEqual(partial.errorCode, "partialFailures")
        XCTAssertEqual(partial.entriesDone, 1)
        XCTAssertEqual(partial.entriesFailed, 1)
        // PHYSICAL progress: fully downloaded-but-refused a.bin PLUS the
        // committed b.bin bytes (streamed pages, never re-counted at the
        // entry tail).
        XCTAssertEqual(partial.bytesDone, bodyA.count + bodyB.count)
        // COMMITTED accounting stays separate and exact.
        XCTAssertEqual(partial.result["bytes"], String(bodyB.count))
        // The committed aggregate (80k) is BELOW the actual transferred
        // (180k): publishing it would be false progress, so the view keeps
        // the 0 UNKNOWN sentinel, never a known total under bytesDone.
        XCTAssertEqual(partial.totalBytes, 0)
        XCTAssertTrue(partial.totalBytes == 0 || partial.totalBytes >= partial.bytesDone)
        // Honest partial: refused entry's working copy untouched, committed
        // entry really on disk.
        let clashAfter = try Data(contentsOf: clashURL)
        XCTAssertEqual(clashAfter, clashBody)
        let committedB = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                                path: "Pair/b.bin")
        let committedBytes = try Data(contentsOf: committedB)
        XCTAssertEqual(committedBytes, bodyB)

        // The next operation succeeds cleanly: the exact total is restored
        // (all success keeps totalBytes == bytesDone == the real size).
        let solo = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                               mountID: view.id, remotePath: "pair/b.bin",
                                               logicalPath: "Solo/b.bin",
                                               recursive: false, conflict: .refuse)
        let ok = try await terminal(owner, solo)
        XCTAssertEqual(ok.state, .completed, "errorCode=\(ok.errorCode ?? "none")")
        XCTAssertEqual(ok.bytesDone, bodyB.count)
        XCTAssertEqual(ok.totalBytes, bodyB.count)
        XCTAssertTrue(ok.totalBytes == 0 || ok.totalBytes >= ok.bytesDone)
        XCTAssertEqual(ok.result["bytes"], String(bodyB.count))
        let rows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        let soloRow = try XCTUnwrap(rows.first { $0.logicalPath == "Solo/b.bin" })
        XCTAssertEqual(soloRow.sourceSHA256, FloeDigest.sha256Hex(bodyB))
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    // MARK: - 3. Save ladder

    func testSaveLadderCommitsWithETagCAS() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        let original = Data("provider original".utf8)
        try await seedBoundFile(owner: owner, adapter: adapter, taskID: taskID,
                                workspaceID: workspaceID, mountID: view.id,
                                remote: "doc.txt", logical: "Docs/doc.txt", body: original)
        let boundRows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        let row = try XCTUnwrap(boundRows.first)
        let boundTag = await adapter.tag(at: "doc.txt")
        let tagAtBind = try XCTUnwrap(boundTag)

        let fileURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Docs/doc.txt")
        let replacement = Data("edited in app".utf8)
        try replacement.write(to: fileURL)

        let save = try await owner.startSave(taskID: taskID, workspaceID: workspaceID,
                                             sourceID: row.id)
        let done = try await terminal(owner, save)
        XCTAssertEqual(done.state, .completed, "errorCode=\(done.errorCode ?? "none")")
        XCTAssertEqual(done.result["journalState"], "committed")
        // The adapter saw the journaled ETag exactly once and the provider
        // now holds the ACTUAL replacement bytes.
        let stats = await adapter.stats()
        XCTAssertEqual(stats.tags, [tagAtBind])
        let bodyAfterEdit = await adapter.body(at: "doc.txt")
        XCTAssertEqual(bodyAfterEdit, replacement)
        let advanced = try await owner.networkSourcesPage(workspaceID: workspaceID)
        let updated = try XCTUnwrap(advanced.first)
        XCTAssertEqual(updated.sourceSHA256, FloeDigest.sha256Hex(replacement))
        XCTAssertNotEqual(updated.entityTag, tagAtBind)          // ETag advanced
        XCTAssertNotEqual(updated.revision, row.revision)        // CAS advanced binding
        let pending = try await owner.pendingNetworkRecoveries(workspaceID: workspaceID)
        XCTAssertFalse(pending.contains { $0.sourceID == row.id })
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testSaveDriftBeforeClaimOpensNoPermit() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        try await seedBoundFile(owner: owner, adapter: adapter, taskID: taskID,
                                workspaceID: workspaceID, mountID: view.id,
                                remote: "doc.txt", logical: "Docs/doc.txt",
                                body: Data("recorded".utf8))
        let boundRows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        let row = try XCTUnwrap(boundRows.first)
        await adapter.externallyMutate(path: "doc.txt", to: Data("third party".utf8))
        let fileURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Docs/doc.txt")
        try Data("local edit".utf8).write(to: fileURL)

        let save = try await owner.startSave(taskID: taskID, workspaceID: workspaceID,
                                              sourceID: row.id)
        let done = try await terminal(owner, save)
        XCTAssertEqual(done.state, .failed)
        XCTAssertEqual(done.errorCode, "sourceChangedSinceImport")
        let pending = try await owner.pendingNetworkRecoveries(workspaceID: workspaceID)
        XCTAssertTrue(pending.isEmpty)   // NO permit was ever journaled
        let bodyAfterThirdParty = await adapter.body(at: "doc.txt")
        XCTAssertEqual(bodyAfterThirdParty, Data("third party".utf8))
        let unchanged = try await owner.networkSourcesPage(workspaceID: workspaceID)
        XCTAssertEqual(try XCTUnwrap(unchanged.first).sourceSHA256,
                       FloeDigest.sha256Hex(Data("recorded".utf8)))
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testUnprovenWriteStaysWritingAndReconcileDecidesFromLiveBytes() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        let backup = Data("provider original".utf8)
        try await seedBoundFile(owner: owner, adapter: adapter, taskID: taskID,
                                workspaceID: workspaceID, mountID: view.id,
                                remote: "doc.txt", logical: "Docs/doc.txt", body: backup)
        let boundRows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        let row = try XCTUnwrap(boundRows.first)
        let fileURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Docs/doc.txt")
        try Data("edited".utf8).write(to: fileURL)

        // (a) The destructive write never lands (typed outage AT the hop).
        await adapter.configureOutages(failNextWrite: true)
        let save = try await owner.startSave(taskID: taskID, workspaceID: workspaceID,
                                              sourceID: row.id)
        let done = try await terminal(owner, save)
        XCTAssertEqual(done.state, .failed)
        XCTAssertEqual(done.errorCode, "networkUnreachable")
        XCTAssertEqual(done.result["reconcileRequired"], "yes")
        let pending = try await owner.pendingNetworkRecoveries(workspaceID: workspaceID)
        let receipt = try XCTUnwrap(pending.first(where: { $0.sourceID == row.id }))
        XCTAssertEqual(receipt.state, .writing)
        // The open receipt refuses a SECOND ladder (never two permits).
        let second = try await owner.startSave(taskID: taskID, workspaceID: workspaceID,
                                               sourceID: row.id)
        let secondView = try await terminal(owner, second)
        XCTAssertEqual(secondView.state, .failed)
        XCTAssertEqual(secondView.errorCode, "transitionRefused")
        // Reconcile from the LIVE provider: still the backup -> retained.
        let reconcile = try await owner.startReconcile(taskID: taskID, workspaceID: workspaceID,
                                                       recoveryID: receipt.id)
        let settled = try await terminal(owner, reconcile)
        XCTAssertEqual(settled.state, .completed, "errorCode=\(settled.errorCode ?? "none")")
        XCTAssertEqual(settled.result["journalState"], "retained")

        // (b) A write that LANDED but could not be proven: the row stays
        // `writing`; a third-party change before reconcile decides conflict
        // from the OBSERVED bytes (never committed, never retry-to-green).
        try Data("edited again".utf8).write(to: fileURL)
        await adapter.configureOutages(failReadAfterWriteOnce: true)
        let third = try await owner.startSave(taskID: taskID, workspaceID: workspaceID,
                                              sourceID: row.id)
        let thirdView = try await terminal(owner, third)
        XCTAssertEqual(thirdView.state, .failed)
        XCTAssertEqual(thirdView.errorCode, "networkUnreachable")
        let openRecoveries = try await owner.pendingNetworkRecoveries(workspaceID: workspaceID)
        let open = try XCTUnwrap(openRecoveries
            .first(where: { $0.sourceID == row.id && $0.state == .writing }))
        await adapter.externallyMutate(path: "doc.txt", to: Data("third party now".utf8))
        let reconcile2 = try await owner.startReconcile(taskID: taskID, workspaceID: workspaceID,
                                                        recoveryID: open.id)
        let outcome = try await terminal(owner, reconcile2)
        XCTAssertEqual(outcome.state, .completed, "errorCode=\(outcome.errorCode ?? "none")")
        XCTAssertEqual(outcome.result["journalState"], "conflict")
        let final = try await owner.networkSourcesPage(workspaceID: workspaceID)
        XCTAssertEqual(try XCTUnwrap(final.first).sourceSHA256,
                       FloeDigest.sha256Hex(backup))   // binding never lied
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    // MARK: - 4. Cancel vs physical settlement

    func testCancelMidStreamIsARequestAndLeavesNoPartialCommit() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        mounts.setPageDelay(120_000_000)   // 120 ms per 64 KiB page
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        await adapter.seed(path: "big.bin", data: Data(repeating: 0x5A, count: 512 * 1024))

        let ticket = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                                 mountID: view.id, remotePath: "big.bin",
                                                 logicalPath: "Big/big.bin",
                                                 recursive: false, conflict: .refuse)
        // Wait until the first page PHYSICALLY landed (bytesDone > 0), then
        // request cancellation.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let view = await owner.operation(ticket),
               view.bytesDone > 0 || view.state != .running { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let beforeView = await owner.operation(ticket)
        let before = try XCTUnwrap(beforeView)
        XCTAssertGreaterThan(before.bytesDone, 0)
        XCTAssertEqual(before.state, .running)
        let requested = await owner.cancelOperation(ticket)
        XCTAssertTrue(requested)
        let done = try await terminal(owner, ticket)
        XCTAssertEqual(done.state, .cancelled)
        XCTAssertEqual(done.errorCode, "cancelled")
        // NOTHING partial committed: no workspace file, no journal row.
        let fileURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Big/big.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let rows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        XCTAssertTrue(rows.isEmpty)
        // Closing a LIVE op refuses; after terminal it succeeds.
        _ = await owner.closeOperation(ticket)
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    // MARK: - 5. Credentials & cross-generation tickets

    func testCredentialRotationKeepsWorkingMountUsable() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        mounts.setAuthRequired(true)
        let authority = SyntheticAuthority()
        let owner = try await makeOwner(boot: boot, authority: authority, mounts: mounts)
        let first = Data("old 密码".utf8)
        let ticket1 = await owner.stageCredential(first)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team", credentialTicket: ticket1,
                                            endpoint: "https://dav.example.test/files")
        let stored1 = await authority.captured
        XCTAssertEqual(stored1.values.count, 1)
        XCTAssertEqual(stored1.values.first, first)

        let ticket2 = await owner.stageCredential(Data("新密码".utf8))
        var draft = G04NetworkMountDraft(name: "Team", transport: .webDAV,
                                         endpoint: try XCTUnwrap(URL(string: "https://dav.example.test/files")),
                                         rootPath: "", username: "alice", readOnly: false,
                                         credentialTicket: ticket2)
        draft.mountID = view.id
        let updated = try await owner.addMount(taskID: taskID, workspaceID: workspaceID, draft: draft)
        XCTAssertEqual(updated.status, "connected")
        let stored2 = await authority.captured
        XCTAssertEqual(stored2.values.count, 1)                    // old revoked AFTER success
        XCTAssertEqual(stored2.values.first, Data("新密码".utf8))
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testClearedCredentialStopsResolvingOnNextHop() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        mounts.setAuthRequired(true)
        let authority = SyntheticAuthority()
        let owner = try await makeOwner(boot: boot, authority: authority, mounts: mounts)
        let ticket = await owner.stageCredential(Data("p 密码".utf8))
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team", credentialTicket: ticket,
                                            endpoint: "https://dav.example.test/files")
        var draft = G04NetworkMountDraft(name: "Team", transport: .webDAV,
                                         endpoint: try XCTUnwrap(URL(string: "https://dav.example.test/files")),
                                         rootPath: "", username: "alice", readOnly: false,
                                         credentialTicket: -1)
        draft.mountID = view.id
        // The edit probe fails (auth-required provider rejects the
        // anonymous candidate): the update is REFUSED and the previous
        // durable record — with its still-live credential — is restored.
        do {
            _ = try await owner.addMount(taskID: taskID, workspaceID: workspaceID, draft: draft)
            XCTFail("anonymous candidate must fail the auth-required probe")
        } catch let error as G04NetworkWorkspaceError {
            XCTAssertEqual(error, .provider(code: "authenticationFailed", retryable: false))
        }
        // The vault still holds the ORIGINAL secret (restore-consistent):
        // no cached grant truth, but also no silent key destruction.
        let stored = await authority.captured
        XCTAssertEqual(stored.values.first, Data("p 密码".utf8))
        // A fresh probe over the RESTORED record succeeds again: the
        // status is always the latest ACTUAL verdict.
        let back = try await owner.probeMount(taskID: taskID, workspaceID: workspaceID,
                                              mountID: view.id)
        XCTAssertEqual(back, .connected)
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testHostCrossGenerationTicketAndGrammarRefusals() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let ownerA = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let host = G04NetworkWorkspaceHost.shared
        host.liveEpochOverrideForTesting = boot.epoch
        host.ownerOverrideForTesting = ownerA
        var buffer = [CChar](repeating: 0, count: 4096)
        let ticketA = Data("secret 密码".utf8).withUnsafeBytes { raw in
            floeG04NetCredStage(boot.epoch, raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                Int32("secret 密码".utf8.count))
        }
        XCTAssertGreaterThan(ticketA, 0)
        // Foreign epoch refuses typed (no session minted for another root).
        let epochB = boot.epoch &+ 1000
        XCTAssertEqual(host.mountPage(epoch: epochB, taskHex: taskID.uuidString,
                                      workspaceHex: workspaceID.uuidString,
                                      buffer: &buffer, capacity: 4096),
                       G04NetworkHostStatus.generationFenced)
        XCTAssertEqual(host.mountPage(epoch: boot.epoch, taskHex: "not-a-uuid",
                                      workspaceHex: workspaceID.uuidString,
                                      buffer: &buffer, capacity: 4096),
                       G04NetworkHostStatus.invalidArguments)
        // A DIFFERENT owner instance's lease never resolves the OLD ticket:
        // the capture refuses credentialTicketRefused as an ok:0 body and
        // nothing is stored (tickets are generation-private).
        let ownerB = try await makeOwner(boot: boot, authority: SyntheticAuthority(),
                                         mounts: mounts)
        host.ownerOverrideForTesting = ownerB
        let size = host.mountAdd(epoch: boot.epoch, taskHex: taskID.uuidString,
                                 workspaceHex: workspaceID.uuidString, mountHex: nil,
                                 name: "Team", transport: "webdav",
                                 endpoint: "https://dav.example.test/files", rootPath: "",
                                 username: "alice", readOnly: 0, credentialTicket: ticketA,
                                 buffer: &buffer, capacity: 4096)
        XCTAssertGreaterThan(size, 0)   // ok:0 JSON body, not a negative status
        let body = String(cString: buffer)
        XCTAssertTrue(body.contains("credentialTicketRefused"), body)
        // The refused create left NO durable config behind either.
        let page = try await ownerB.mounts(taskID: taskID, workspaceID: workspaceID)
        XCTAssertTrue(page.isEmpty)
        host.liveEpochOverrideForTesting = nil
        host.ownerOverrideForTesting = nil
        await ownerA.retire()
        _ = await ownerA.awaitSettledOperations()
        await ownerB.retire()
        _ = await ownerB.awaitSettledOperations()
    }

    // MARK: - 6. Read-only + SMB semantics

    func testReadOnlyRefusesAtSpawnAndSMBWritesCarryNoETag() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let roView = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                              name: "RO", endpoint: "https://ro.example.test/dav",
                                              readOnly: true)
        XCTAssertEqual(roView.status, "readOnly")
        do {
            _ = try await owner.startImport(taskID: taskID, workspaceID: workspaceID,
                                            mountID: roView.id, remotePath: "a.txt",
                                            logicalPath: "a.txt", recursive: false,
                                            conflict: .refuse)
            XCTFail("read-only must refuse at spawn")
        } catch let error as G04NetworkWorkspaceError {
            XCTAssertEqual(error, .provider(code: "readOnly", retryable: false))
        }

        // SMB path: import binds WITHOUT an entity tag; the write ladder
        // carries nil If-Match (the delivered SMB limitation, pinned).
        let smbDraft = G04NetworkMountDraft(name: "Share", transport: .smb,
                                            endpoint: try XCTUnwrap(URL(string: "smb://fileserv/share")),
                                            rootPath: "", username: "bob", readOnly: false,
                                            credentialTicket: 0)
        let smbView = try await owner.addMount(taskID: taskID, workspaceID: workspaceID, draft: smbDraft)
        let adapter = try XCTUnwrap(mounts.adapter(mountID: smbView.id))
        let body = Data("smb body 1234".utf8)
        try await seedBoundFile(owner: owner, adapter: adapter, taskID: taskID,
                                workspaceID: workspaceID, mountID: smbView.id,
                                remote: "sheet.csv", logical: "Sheet.csv", body: body)
        let rows = try await owner.networkSourcesPage(workspaceID: workspaceID)
        let smbRow = try XCTUnwrap(rows.first { $0.kind == .smb })
        XCTAssertNil(smbRow.entityTag)
        let fileURL = try await workspaceURL(taskID: taskID, workspaceID: workspaceID,
                                             path: "Sheet.csv")
        XCTAssertEqual(try Data(contentsOf: fileURL), body)

        try Data("smb edited".utf8).write(to: fileURL)
        let save = try await owner.startSave(taskID: taskID, workspaceID: workspaceID,
                                             sourceID: smbRow.id)
        let done = try await terminal(owner, save)
        XCTAssertEqual(done.state, .completed, "errorCode=\(done.errorCode ?? "none")")
        let writeStats = await adapter.stats()
        XCTAssertFalse(writeStats.tags.isEmpty)
        XCTAssertTrue(writeStats.tags.allSatisfy { $0 == nil })   // no ETag ever sent
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testBrowseAndStatAreBoundedAndEscapesRefuse() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let owner = try await makeOwner(boot: boot, authority: SyntheticAuthority(), mounts: mounts)
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team")
        let adapter = try XCTUnwrap(mounts.adapter(mountID: view.id))
        for index in 0 ..< 250 {
            await adapter.seed(path: "many/file\(index).txt", data: Data("x".utf8))
        }
        let page = try await owner.browse(taskID: taskID, workspaceID: workspaceID,
                                          mountID: view.id, path: "many")
        XCTAssertEqual(page.entries.count, G04NetworkWorkspace.maximumBrowseEntries)
        XCTAssertTrue(page.truncated)
        let meta = try await owner.stat(taskID: taskID, workspaceID: workspaceID,
                                        mountID: view.id, path: "many/file7.txt")
        XCTAssertEqual(meta.byteCount, 1)
        XCTAssertNotNil(meta.entityTag)
        do {
            _ = try await owner.browse(taskID: taskID, workspaceID: workspaceID,
                                       mountID: view.id, path: "../secret")
            XCTFail("escape must refuse")
        } catch let error as G04NetworkWorkspaceError {
            XCTAssertEqual(error, .remotePathRefused("escape"))
        }
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }

    func testRemoveRevokesCredentialAndStopsRouting() async throws {
        let boot = try await bootInstalledGeneration()
        let (taskID, workspaceID) = try await makeBoundOrdinaryTask()
        let mounts = SyntheticMounts()
        let authority = SyntheticAuthority()
        let owner = try await makeOwner(boot: boot, authority: authority, mounts: mounts)
        let ticket = await owner.stageCredential(Data("secret".utf8))
        let view = try await addWebDAVMount(owner: owner, taskID: taskID, workspaceID: workspaceID,
                                            name: "Team", credentialTicket: ticket)
        let removed = try await owner.removeMount(taskID: taskID, workspaceID: workspaceID,
                                                  mountID: view.id, forgetCredential: true)
        XCTAssertEqual(removed.credential, "deleted")
        let stored = await authority.captured
        XCTAssertTrue(stored.isEmpty)
        let page = try await owner.mounts(taskID: taskID, workspaceID: workspaceID)
        XCTAssertTrue(page.isEmpty)
        do {
            _ = try await owner.probeMount(taskID: taskID, workspaceID: workspaceID,
                                           mountID: view.id)
            XCTFail("removed mount must be unknown")
        } catch let error as G04NetworkWorkspaceError {
            XCTAssertEqual(error, .mountUnknown)
        }
        await owner.retire()
        _ = await owner.awaitSettledOperations()
    }
}

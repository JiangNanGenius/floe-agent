// SPDX-License-Identifier: MPL-2.0
//
// Local G04-R1 native-cohort notes (build lane job-c6f5bbdae8cd4e70):
//   * explicit stat()/S_IFMT/S_IFREG mode comparisons with Int casts —
//     bionic imports the mode mask as Int while st_mode is mode_t; same
//     regular-file test on every platform.
//   * lock-guarded static registries carry nonisolated(unsafe) with the
//     existing NSLock discipline (same pattern as RuntimeFacadeRunBridge).
//
// G04GitActionsDomain — the Root-owned composition around the ORIGINAL
// durable GitHub Actions engine for one accepted native generation.
//
// Reuse contract (job-7bb726c11c6449e0, G04-R1):
//   * the state machine is the immutable iOS `GitHubActionsJobEngine` +
//     `GitHubActionsJobStore` + `IDEGitHubActionsPolicy` ports in this module
//     (provenance headers there); this file supplies ONLY the Android
//     dependency wiring the original app-side `GitHubActionsJobCenter`
//     supplied on iOS, mapped onto the accepted G04 seams:
//       - one token per call through the existing leased credential seam
//         (`GitHubCredentialStore` over `G04GitCredentialLease`) — never a
//         stored token, never a second vault;
//       - the real `GitHubActionsClient` (mirrored iOS FloeGit service);
//       - workspace bytes only through `G04WorkspaceAccessPort` leases over
//         the SAME selected conversation-private root; payloads never supply
//         a root; `.git` metadata containment is validated before any walk;
//       - durable job records live under the accepted private-task root in a
//         Floe-owned directory (`.floe/github-actions-jobs`), re-derived per
//         generation from the ORIGINAL store resolution — never
//         applicationSupport, never temp, never the first project;
//   * artifact BYTES stream through the qualified incremental
//     `GitHubActionsArtifactStreamer` (bounded, hashed while streaming,
//     GitHub-digest verified BEFORE the atomic commit, `.part` staging and
//     same-directory rename). The engine's buffered `downloadArtifact` seam
//     stays intact for fidelity and unit tests but is refused in production
//     here, because swift-corelibs would silently full-buffer it — a
//     self-computed hash alone is never presented as remote verification:
//     `downloadVerified` is set true only when GitHub attested a `sha256:`
//     digest that matched, exactly like the original honesty rule.
//   * dispatch/register happens through the engine BEFORE any remote side
//     effect (the durable record is the first write), the wire's document
//     mutation barrier refuses dirty native drafts so the reviewed snapshot
//     is the actual disk truth, and an uncertain dispatch is re-associated by
//     the persisted snapshot identity WITHOUT redispatch.
import Foundation
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif
import FloeCore
import FloeTools
import FloeGit
import FloeWorkspace

/// Per-workspace durable-run state box. The engine publishes through these
/// closures while the domain actor may be re-entrant elsewhere, so the box is
/// a separate actor: no engine callback can ever block on, or be blocked by,
/// the domain's own call stack.
private actor G04ActionsRunBox {
    var records: [GitHubActionsJobRecord] = []
    var lastError: String?
    func publish(_ record: GitHubActionsJobRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.insert(record, at: 0) }
    }
    func publishAll(_ rows: [GitHubActionsJobRecord]) { records = rows }
    func report(_ message: String?) { lastError = message }
    func snapshot() -> ([GitHubActionsJobRecord], String?) { (records, lastError) }
}

/// Android composition of the durable engine for one generation. Created by
/// `G04WorkspaceGit` and bound through `bindDispatchJobs`; there is no raw
/// unowned Actions HTTP dispatch path outside this type.
actor G04GitActionsDomain {
    enum Failure: Error, Sendable {
        case invalidArguments
        case reviewStale
        case recordMissing
        case workflowNotRegistered
        case artifactNotReady
        case retired
    }

    /// Wire actions owned by this domain (the durable engine path). The raw
    /// `actions.workflows/runs/run/jobs/artifacts/cancel` read/query actions
    /// stay in `G04WorkspaceGit.perform` exactly as reviewed.
    static let engineActions: Set<String> = [
        "actions.snapshotPreview", "actions.templates", "actions.records", "actions.record",
        "actions.refresh", "actions.jobLog", "actions.loadArtifacts", "actions.downloadArtifact",
        "actions.cancelJob", "actions.installTemplate", "actions.dispatch",
    ]

    /// Floe-owned durable directory below the accepted private-task root.
    static let storeRelativePath = ".floe/github-actions-jobs"
    private static let artifactRelativeRoot = IDEGitHubActionsArtifactPolicy.artifactRoot

    private struct WorkspaceState {
        let rootPath: String
        let store: GitHubActionsJobStore
        let engine: GitHubActionsJobEngine
        let box: G04ActionsRunBox
    }

    private let epoch: UInt64
    private let access: any G04WorkspaceAccessPort
    private let credentials: GitHubCredentialStore
    private let github = GitHubService()
    private let actions = GitHubActionsClient()
    private let current: @Sendable () -> Bool
    private var workspaces: [UUID: WorkspaceState] = [:]
    private var sceneIDs: Set<String> = []
    private var retired = false

    init(epoch: UInt64, installed: G02InstalledComposition, access: any G04WorkspaceAccessPort,
         credentials: GitHubCredentialStore) {
        self.epoch = epoch
        self.access = access
        self.credentials = credentials
        self.current = {
            epoch == G02NativeRootEpoch.readback()
                && G02RuntimeComposition.shared.installedComposition === installed
        }
    }

    /// Generation retirement: stops every LOCAL poller (an inactive scene
    /// never claims the remote run stopped — durable records re-query at the
    /// next attach) and refuses later binding.
    func retire() {
        retired = true
        for state in workspaces.values { Task { await state.engine.pausePolling() } }
        workspaces.removeAll()
        sceneIDs.removeAll()
    }

    /// App foreground/background fan-out — the original multi-scene rules
    /// stay INSIDE each engine (first active scene starts the bounded poller,
    /// last deactivation pauses it, per scene id). The domain only mirrors
    /// the id set (for honest `sceneActive` reporting and for newly created
    /// engines) and forwards every event to every live engine.
    func scene(active: Bool, sceneID: String) {
        guard !retired, current(), sceneID.utf8.count <= 64, !sceneID.isEmpty else { return }
        if active { sceneIDs.insert(sceneID) } else { sceneIDs.remove(sceneID) }
        for state in workspaces.values {
            Task {
                if active { await state.engine.sceneDidActivate(id: sceneID) }
                else { await state.engine.sceneDidDeactivate(id: sceneID) }
            }
        }
    }

    // MARK: - Wire entry points

    /// The `bindDispatchJobs` port. The durable engine, not a cancellable UI
    /// call, owns the dispatch acknowledgement/association. `nonisolated` so
    /// `G04WorkspaceGit.init` can bind it synchronously; the closure hops into
    /// this actor exactly like every other engine entry point.
    nonisolated var dispatchPort: G04WorkspaceGit.DispatchJobPort {
        { owner, values, cancellation in
            try await self.handle(action: "actions.dispatch",
                                  args: G04WorkspaceGit.Arguments(action: "actions.dispatch",
                                                                   values: values, write: true),
                                  owner: owner, root: nil, service: nil, cancellation: cancellation)
        }
    }

    func handle(action: String, args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner,
                root: URL?, service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        guard !retired, current(), owner.epoch == epoch else { throw Failure.retired }
        switch action {
        case "actions.snapshotPreview": return try await preview(args: args, owner: owner,
            root: root, service: service, cancellation: cancellation)
        case "actions.templates": return try templates(args: args)
        case "actions.records": return try await records(owner: owner, root: root, service: service)
        case "actions.record": return try await record(args: args, owner: owner, root: root, service: service)
        case "actions.refresh": return try await refresh(args: args, owner: owner, root: root,
            service: service, cancellation: cancellation)
        case "actions.jobLog": return try await jobLog(args: args, owner: owner, root: root,
            service: service, cancellation: cancellation)
        case "actions.loadArtifacts": return try await loadArtifacts(args: args, owner: owner,
            root: root, service: service, cancellation: cancellation)
        case "actions.downloadArtifact": return try await download(args: args, owner: owner,
            root: root, service: service, cancellation: cancellation)
        case "actions.cancelJob": return try await cancelJob(args: args, owner: owner, root: root,
            service: service, cancellation: cancellation)
        case "actions.installTemplate": return try await installTemplate(args: args, owner: owner,
            root: root, service: service, cancellation: cancellation)
        case "actions.dispatch": return try await dispatch(args: args, owner: owner, root: root,
            service: service, cancellation: cancellation)
        default: throw G04WorkspaceGit.Failure.unsupportedAction
        }
    }

    // MARK: - Engine acquisition (accepted storage ownership only)

    /// Resolves the lease pair the walk/publish needs. When called from
    /// `G04WorkspaceGit.execute` the caller already holds a lease; the engine
    /// path re-acquires its OWN operation lease so long remote waits stay
    /// attached to real owned work and are held until actual IO settlement,
    /// never to a view lifetime.
    private func resolveLease(owner: G04WorkspaceOwner, root: URL?, service: WorkspaceFileService?,
                              intent: G04WorkspaceIntent, cancellation: CancellationToken)
        async throws -> (URL, WorkspaceFileService, G04WorkspaceAccessLease?) {
        if let root, let service {
            try G04GitMetadataBoundary.validate(root: root)
            return (root, service, nil)
        }
        let lease = try await access.acquire(owner: owner, intent: intent, relativePath: nil)
        do {
            try cancellation.throwIfCancelled()
            let resolved = lease.service.guardResolver.rootURL
            try G04GitMetadataBoundary.validate(root: resolved)
            return (resolved, lease.service, lease)
        } catch {
            await lease.release()
            throw error
        }
    }


    /// Runs one engine helper under the SAME lease discipline as
    /// `G04WorkspaceGit.execute`: when the caller (the wire path) already
    /// holds the accepted lease its service/root are reused directly; when
    /// the durable port path calls in, the helper acquires its OWN operation
    /// lease and releases it exactly once on success AND on every failure —
    /// never a fire-and-forget detachment.
    private func withResolved<R: Sendable>(owner: G04WorkspaceOwner, root: URL?,
            service: WorkspaceFileService?, intent: G04WorkspaceIntent,
            cancellation: CancellationToken,
            _ body: (URL, WorkspaceFileService) async throws -> R) async throws -> R {
        let (resolved, fileService, lease) = try await resolveLease(owner: owner, root: root,
            service: service, intent: intent, cancellation: cancellation)
        do {
            let output = try await body(resolved, fileService)
            if let lease { await lease.release() }
            return output
        } catch {
            if let lease { await lease.release() }
            throw error
        }
    }

    private func state(owner: G04WorkspaceOwner, root: URL, store: GitHubActionsJobStore? = nil)
        async -> WorkspaceState {
        if let existing = workspaces[owner.workspaceID], existing.rootPath == root.path {
            return existing
        }
        if let stale = workspaces[owner.workspaceID] {
            // The accepted binding moved (rebind/retire): stop the stale
            // LOCAL poller so it can never observe or save through an
            // older root. Its durable records stay on disk, honest and
            // queryable by the replacement engine over the new root.
            Task { await stale.engine.pausePolling() }
            workspaces[owner.workspaceID] = nil
        }
        let directory = root.appendingPathComponent(Self.storeRelativePath, isDirectory: true)
        let jobStore = store ?? GitHubActionsJobStore(directory: directory)
        let box = G04ActionsRunBox()
        let engine = GitHubActionsJobEngine(
            dependencies: GitHubActionsEngineDependencies(
                remote: G04ActionsRemoteAdapter(client: actions),
                store: jobStore,
                credentials: G04DomainTokenProvider(store: credentials),
                clock: SystemGitHubActionsClock(),
                digest: { FloeDigest.sha256Hex($0) },
                redact: { SecretRedactor.redact($0) },
                commitArtifact: { _, _, _, _ in
                    // Production artifact bytes commit through the streaming
                    // seam below; a buffered engine commit is never reached
                    // and never silently succeeds.
                    throw GitHubActionsEngineError.artifactDestination(
                        "artifact bytes stream through the qualified Android artifact seam")
                },
                publish: { record in await box.publish(record) },
                publishAll: { records in await box.publishAll(records) },
                reportError: { message in await box.report(message) }
            ),
            maximumConcurrentRefreshes: 3
        )
        // Launch recovery re-queries NOTHING by itself: load the durable
        // records first (no network), then the scene rules gate polling.
        await engine.recover()
        if !sceneIDs.isEmpty {
            for id in sceneIDs { await engine.sceneDidActivate(id: id) }
        }
        let created = WorkspaceState(rootPath: root.path, store: jobStore, engine: engine, box: box)
        // A changed root means the accepted binding moved; replace honestly.
        workspaces[owner.workspaceID] = created
        return created
    }

    // MARK: - Snapshot preview (reviewed inclusion/exclusion)

    private func preview(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner,
                         root: URL?, service: WorkspaceFileService?,
                         cancellation: CancellationToken) async throws -> DesignJSONValue {
        let directory = try args.optional("directory", maximum: 4096) ?? "."
        guard directory == "." || (IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath(directory)
            && !Self.isDeniedWalkComponent(directory)) else { throw Failure.invalidArguments }
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: cancellation) { _, fileService in
            let manifest = try Self.buildManifest(directory: directory, fileService: fileService)
            return try Self.encoded([
                "directory": .string(directory),
                "manifest": Self.manifestValue(manifest),
                "reviewedSHA256": .string(Self.manifestDigest(manifest)),
            ])
        }
    }

    /// Deterministic, policy-filtered manifest for one walk.
    static func buildManifest(directory: String, fileService: WorkspaceFileService) throws
        -> IDEGitHubActionsSnapshotManifest {
        let guardResolver = WorkspacePathGuard(
            rootURL: fileService.guardResolver.rootURL,
            maxReadBytes: IDEGitHubActionsSnapshotPolicy.maximumFileBytes,
            maxWriteBytes: IDEGitHubActionsSnapshotPolicy.maximumTotalBytes
        )
        var candidates: [IDEGitHubActionsSnapshotCandidate] = []
        var seen = Set<String>()
        collectSnapshotCandidates(directory: directory, depth: 0, fileService: fileService,
                                  guardResolver: guardResolver, candidates: &candidates, seen: &seen)
        return try IDEGitHubActionsSnapshotPolicy.manifest(candidates: candidates)
    }

    /// Bounded breadth-first walk — the original `collectSnapshotCandidates`
    /// rules: pages followed to completion, depth/count bounded, symlinks and
    /// oversized files rejected by light metadata BEFORE any hashing.
    private static func collectSnapshotCandidates(
        directory: String, depth: Int, fileService: WorkspaceFileService,
        guardResolver: WorkspacePathGuard,
        candidates: inout [IDEGitHubActionsSnapshotCandidate], seen: inout Set<String>
    ) {
        guard depth <= IDEGitHubActionsSnapshotPolicy.maximumDirectoryDepth else { return }
        guard candidates.count <= IDEGitHubActionsSnapshotPolicy.maximumFileCount else { return }
        var pageToken: String?
        var pages = 0
        repeat {
            pages += 1
            guard pages <= IDEGitHubActionsSnapshotPolicy.maximumDirectoryPages else { return }
            let page: DirectoryPage
            do {
                page = try fileService.listDirectory(directory, pageToken: pageToken,
                                                     includeDirectories: true, includeFiles: true)
            } catch { return }
            for node in page.entries {
                guard candidates.count <= IDEGitHubActionsSnapshotPolicy.maximumFileCount else { return }
                guard !seen.contains(node.relativePath) else { continue }
                // Link refusal FIRST, before any directory classification
                // (review revision 1, GIT_PRIVATE_PATCH_REVIEW_01.json):
                // `listDirectory` derives `isDirectory` through
                // `resourceValues`, which follows symlinks, so a
                // directory-symlink would otherwise be traversed before it is
                // ever seen. `lstat` on the RAW entry is the only light
                // metadata that describes the entry itself; links refuse
                // BEFORE any hashing or descent, exactly as the walk contract
                // documents.
                let entryURL = guardResolver.rootURL.appendingPathComponent(node.relativePath)
                var entryInfo = stat()
                guard lstat(entryURL.path, &entryInfo) == 0 else { continue }
                if (Int(entryInfo.st_mode) & Int(S_IFMT)) == Int(S_IFLNK) {
                    seen.insert(node.relativePath)
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: false, isSymlink: true,
                        byteCount: 0, sha256: ""))
                    continue
                }
                if node.isDirectory {
                    if IDEGitHubActionsSnapshotPolicy.isSnapshotSkipDirectory(node.name) { continue }
                    seen.insert(node.relativePath)
                    collectSnapshotCandidates(directory: node.relativePath, depth: depth + 1,
                                              fileService: fileService, guardResolver: guardResolver,
                                              candidates: &candidates, seen: &seen)
                    continue
                }
                // The guard's secret denylist throws on resolve. Review
                // revision 2: the guard stays the authoritative choke point,
                // but a typed manifest row is emitted only when the plan-level
                // policy ALSO recognizes the relative path as a secret — so
                // the two mirror vocabs decide the same exclusion and no other
                // guard refusal (race, unreadable, escaping chain) can become
                // an accepted regular empty-SHA entry. Silent refusal for
                // unrecognized denials matches the original walker behavior.
                // No secret bytes are ever read for a secretFile row.
                let resolved: URL
                do {
                    resolved = try guardResolver.resolve(node.relativePath)
                } catch let error as WorkspaceToolError {
                    if case .secretFile = error,
                       IDEGitHubActionsSnapshotPolicy.isSecretPath(node.relativePath) {
                        seen.insert(node.relativePath)
                        candidates.append(IDEGitHubActionsSnapshotCandidate(
                            path: node.relativePath,
                            isRegularFile: (Int(entryInfo.st_mode) & Int(S_IFMT)) == Int(S_IFREG),
                            isSymlink: false,
                            byteCount: Int(entryInfo.st_size), sha256: ""))
                    }
                    continue
                } catch { continue }
                guard let properties = try? resolved
                    .resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
                    continue
                }
                if properties.isSymbolicLink == true {
                    seen.insert(node.relativePath)
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: false, isSymlink: true,
                        byteCount: 0, sha256: ""))
                    continue
                }
                guard properties.isRegularFile == true else { continue }
                let byteCount = Int(properties.fileSize ?? 0)
                seen.insert(node.relativePath)
                if byteCount > IDEGitHubActionsSnapshotPolicy.maximumFileBytes {
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: true, isSymlink: false,
                        byteCount: byteCount, sha256: ""))
                    continue
                }
                guard let meta = try? fileService.metadata(node.relativePath) else { continue }
                if meta.isSymlink {
                    candidates.append(IDEGitHubActionsSnapshotCandidate(
                        path: node.relativePath, isRegularFile: false, isSymlink: true,
                        byteCount: 0, sha256: ""))
                    continue
                }
                candidates.append(IDEGitHubActionsSnapshotCandidate(
                    path: node.relativePath, isRegularFile: !meta.isDirectory,
                    isSymlink: meta.isSymlink, byteCount: Int(meta.size), sha256: meta.sha256))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
    }

    static func manifestValue(_ manifest: IDEGitHubActionsSnapshotManifest) -> DesignJSONValue {
        .object([
            "entries": .array(manifest.entries.map { entry in
                DesignJSONValue.object(["path": .string(entry.path),
                                        "byteCount": .integer(Int64(entry.byteCount)),
                                        "sha256": .string(entry.sha256)]) }),
            "excluded": .array(manifest.excluded.map(Self.exclusionValue)),
            "totalBytes": .integer(Int64(manifest.totalBytes)),
            "fileCount": .integer(Int64(manifest.entries.count)),
        ])
    }

    private static func exclusionValue(_ exclusion: IDEGitHubActionsSnapshotExclusion) -> DesignJSONValue {
        switch exclusion {
        case .unsafePath: return .object(["reason": .string("unsafePath")])
        case .gitMetadata: return .object(["reason": .string("gitMetadata")])
        case .generatedArtifact: return .object(["reason": .string("generatedArtifact")])
        case .secretFile: return .object(["reason": .string("secretFile")])
        case .notRegularFile: return .object(["reason": .string("notRegularFile")])
        case .symlink: return .object(["reason": .string("symlink")])
        case .fileTooLarge(let path, let limit):
            return .object(["reason": .string("fileTooLarge"), "path": .string(path),
                            "limit": .integer(Int64(limit))])
        case .totalTooLarge(let limit):
            return .object(["reason": .string("totalTooLarge"), "limit": .integer(Int64(limit))])
        case .tooManyFiles(let limit):
            return .object(["reason": .string("tooManyFiles"), "limit": .integer(Int64(limit))])
        }
    }

    /// Canonical digest over the exact reviewed entry list; dispatch must
    /// reproduce it or the user re-reviews (no silent extra uploads).
    static func manifestDigest(_ manifest: IDEGitHubActionsSnapshotManifest) -> String {
        struct DigestRow: Encodable {
            let path: String
            let byteCount: Int
            let sha256: String
        }
        let rows = manifest.entries.map { DigestRow(path: $0.path, byteCount: $0.byteCount, sha256: $0.sha256) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(rows)) ?? Data()
        return FloeDigest.sha256Hex(data)
    }

    private static func isDeniedWalkComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".git" || $0 == ".floe" }
    }

    // MARK: - Catalog

    private func templates(args: G04WorkspaceGit.Arguments) throws -> DesignJSONValue {
        let languageID = try args.text("languageID", maximum: 64)
        let rows = IDEGitHubActionsWorkflowCatalog.templates(for: languageID)
        return try Self.encoded([
            "languageID": .string(languageID),
            "templates": .array(rows.map { template in
                DesignJSONValue.object([
                    "id": .string(template.id), "workflowPath": .string(template.workflowPath),
                    "role": .string(template.role.rawValue), "platform": .string(template.runnerPlatform.rawValue),
                    "expectedArtifactName": template.expectedArtifactName.map { DesignJSONValue.string($0) } ?? .null,
                    "yamlBytes": .integer(Int64(template.yaml.utf8.count)),
                    "yaml": .string(String(template.yaml.prefix(160 * 1024))),
                ]) }),
        ])
    }

    // MARK: - Records (durable store truth; no network)

    private func records(owner: G04WorkspaceOwner, root: URL?, service: WorkspaceFileService?)
        async throws -> DesignJSONValue {
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: CancellationToken()) { resolved, _ in
        let state = await state(owner: owner, root: resolved)
        let load = try await state.store.load()
        let rows = load.records.filter { $0.workspaceID == owner.workspaceID }
        let lastError = await state.box.snapshot().1
        return try Self.encoded([
            "records": .array(rows.map(Self.recordValue)),
            "corruptFiles": .array(load.corruptFiles.map { DesignJSONValue.string($0) }),
            "engineError": lastError.map { DesignJSONValue.string($0) } ?? .null,
            "sceneActive": .bool(!sceneIDs.isEmpty),
        ])
        }
    }

    private func record(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                        service: WorkspaceFileService?) async throws -> DesignJSONValue {
        let id = try Self.identifier(args.text("recordID", maximum: 64))
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: CancellationToken()) { resolved, _ in
            let state = await state(owner: owner, root: resolved)
            guard let record = try await state.store.record(id: id) else { throw Failure.recordMissing }
            guard record.workspaceID == owner.workspaceID else { throw Failure.recordMissing }
            return try Self.encoded(["record": Self.recordValue(record),
                                     "recoveryActions": .array(Self.recoverySummary(record))])
        }
    }

    static func recordValue(_ record: GitHubActionsJobRecord) -> DesignJSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record),
              let value = try? JSONDecoder().decode(DesignJSONValue.self, from: data) else {
            return .object(["id": .string(record.id.uuidString),
                            "state": .string(record.state.rawValue)])
        }
        return value
    }

    private static func recoverySummary(_ record: GitHubActionsJobRecord) -> [DesignJSONValue] {
        IDEGitHubActionsReconciler.actions(for: record).map { action in
            switch action {
            case .queryKnownRun(let runID): return .string("queryKnownRun:\(runID)")
            case .reAssociateSnapshot: return .string("reAssociateSnapshot")
            case .awaitingManualRedispatch: return .string("awaitingManualRedispatch")
            case .resumeArtifactDownload(let artifactID):
                return .string("resumeArtifactDownload:\(artifactID)")
            }
        }
    }

    // MARK: - Refresh / cancel (durable intent first)

    private func refresh(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                         service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let id = try Self.identifier(args.text("recordID", maximum: 64))
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: cancellation) { resolved, fileService in
            let state = await state(owner: owner, root: resolved)
            guard let existing = try await state.store.record(id: id),
                  existing.workspaceID == owner.workspaceID else { throw Failure.recordMissing }
            let outcome = await state.engine.refreshOne(id: id, reason: .explicit)
            try cancellation.throwIfCancelled()
            guard current(), !retired else { throw Failure.retired }
            let updated = try await state.store.record(id: id)
            return try Self.encoded([
                "outcome": .string(Self.outcomeName(outcome)),
                "record": updated.map(Self.recordValue) ?? .null,
            ])
        }
    }

    private func cancelJob(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                           service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let id = try Self.identifier(args.text("recordID", maximum: 64))
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: cancellation) { resolved, fileService in
            let state = await state(owner: owner, root: resolved)
            guard let existing = try await state.store.record(id: id),
                  existing.workspaceID == owner.workspaceID else { throw Failure.recordMissing }
            // Intent persists inside engine.cancel BEFORE any network request.
            await state.engine.cancel(recordID: id)
            // The caller's cancellation may stop this waiter; the durable
            // intent is already persisted inside the engine.
            try cancellation.throwIfCancelled()
            guard current(), !retired else { throw Failure.retired }
            let updated = try await state.store.record(id: id)
            return try Self.encoded([
                "requested": .bool(updated?.cancelRequestedAt != nil),
                "record": updated.map(Self.recordValue) ?? .null,
            ])
        }
    }

    private static func outcomeName(_ outcome: GitHubActionsJobEngine.RefreshOutcome) -> String {
        switch outcome {
        case .idle: return "idle"
        case .progressed: return "progressed"
        case .rateLimited: return "rateLimited"
        case .failed: return "failed"
        }
    }

    // MARK: - Jobs / logs / artifacts

    private func jobLog(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                        service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let id = try Self.identifier(args.text("recordID", maximum: 64))
        let jobID = try args.number("jobID")
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: cancellation) { resolved, _ in
        let state = await state(owner: owner, root: resolved)
        guard let record = try await state.store.record(id: id),
              record.workspaceID == owner.workspaceID else { throw Failure.recordMissing }
        _ = state
        try cancellation.throwIfCancelled()
        guard let token = try await credentials.token() else {
            throw G04WorkspaceGit.Failure.needsAccount }
        try cancellation.throwIfCancelled()
        let slice = try await actions.jobLog(owner: record.owner, repository: record.repository,
                                             jobID: jobID, token: token)
        try cancellation.throwIfCancelled()
        return try Self.encoded([
            "text": .string(slice.text), "truncated": .bool(slice.truncated),
            "byteCount": .integer(Int64(slice.byteCount)),
        ])
        }
    }

    private func loadArtifacts(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                               service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let id = try Self.identifier(args.text("recordID", maximum: 64))
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: cancellation) { resolved, fileService in
            let state = await state(owner: owner, root: resolved)
            guard let existing = try await state.store.record(id: id),
                  existing.workspaceID == owner.workspaceID else { throw Failure.recordMissing }
            await state.engine.loadArtifacts(recordID: id)
            try cancellation.throwIfCancelled()
            guard current(), !retired else { throw Failure.retired }
            let updated = try await state.store.record(id: id)
            return try Self.encoded(["record": updated.map(Self.recordValue) ?? .null])
        }
    }

    /// Verified streaming download + merge-safe durable record update. The
    /// digest GitHub attested is checked BEFORE the atomic commit; with no
    /// attestation the result is honestly labelled checksum-only.
    private func download(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                          service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let id = try Self.identifier(args.text("recordID", maximum: 64))
        let artifactID = try args.number("artifactID")
        let overwrite = try args.flag("overwrite")
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .fileMutation, cancellation: cancellation) { resolved, fileService in
            _ = fileService
            let state = await state(owner: owner, root: resolved)
            guard let record = try await state.store.record(id: id),
                  record.workspaceID == owner.workspaceID, let runID = record.runID,
                  let artifact = record.artifacts.first(where: { $0.id == artifactID }) else {
                throw Failure.artifactNotReady
            }
            guard !artifact.expired, let archiveURL = Self.archiveURL(owner: record.owner,
                repository: record.repository, artifactID: artifactID) else { throw Failure.artifactNotReady }
            try cancellation.throwIfCancelled()
            guard let token = try await credentials.token() else { throw G04WorkspaceGit.Failure.needsAccount }
            try cancellation.throwIfCancelled()
            let directory = "\(Self.artifactRelativeRoot)/\(runID)"
            if overwrite {
                try Self.removeFloeOwnedDownload(root: resolved, directory: directory, artifact: artifact)
            }
            let model = GitHubActionsArtifact(
                id: artifact.id, name: artifact.name, sizeInBytes: artifact.sizeInBytes,
                expired: artifact.expired, archiveDownloadURL: archiveURL,
                createdAt: artifact.createdAt, expiresAt: artifact.expiresAt, digest: artifact.remoteDigest)
            let streamer = GitHubActionsArtifactStreamer()
            let staged: GitHubActionsStagedArtifact
            do {
                staged = try await streamer.stage(
                    artifact: model, token: token, intoTrustedRoot: resolved, relativeDirectory: directory,
                    isCancellationRequested: { cancellation.isCancelled })
            } catch {
                await streamer.finish()
                throw error
            }
            await streamer.finish()
            try cancellation.throwIfCancelled()
            guard current(), !retired, G02NativeRootEpoch.readback() == epoch else { throw Failure.retired }
            let relative = "\(directory)/\(staged.suggestedFileName)"
            var updated = record
            if let index = updated.artifacts.firstIndex(where: { $0.id == artifactID }) {
                updated.artifacts[index].downloadedSHA256 = staged.sha256
                updated.artifacts[index].downloadedRelativePath = relative
                updated.artifacts[index].remoteDigest = artifact.remoteDigest
                // Honesty rule: verified requires a GitHub-attested digest that
                // matched BEFORE commit. The streamer throws on mismatch, so a
                // successful staged result with serverAttested == true is the
                // only path that may set downloadVerified.
                updated.artifacts[index].downloadVerified = staged.serverAttested
            }
            // Merge-safe save: a concurrent engine refresh cannot be clobbered.
            try await state.store.save(updated)
            guard let saved = try await state.store.record(id: id) else { throw Failure.recordMissing }
            await state.box.publish(saved)
            return try Self.encoded(["artifact": Self.artifactValue(updated.artifacts.first { $0.id == artifactID } ?? updated.artifacts[0]),
                                     "record": Self.recordValue(saved)])
        }
    }

    static func artifactValue(_ artifact: GitHubActionsArtifactRecord) -> DesignJSONValue {
        .object([
            "id": .integer(artifact.id), "name": .string(artifact.name),
            "sizeInBytes": .integer(artifact.sizeInBytes), "expired": .bool(artifact.expired),
            "downloadedSHA256": artifact.downloadedSHA256.map { DesignJSONValue.string($0) } ?? .null,
            "downloadedRelativePath": artifact.downloadedRelativePath.map { DesignJSONValue.string($0) } ?? .null,
            "remoteDigest": artifact.remoteDigest.map { DesignJSONValue.string($0) } ?? .null,
            "downloadVerified": artifact.downloadVerified.map { DesignJSONValue.bool($0) } ?? .null,
        ])
    }

    private static func archiveURL(owner: String, repository: String, artifactID: Int64) -> URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/actions/artifacts/\(artifactID)/zip")
    }

    /// Explicit overwrite replaces ONLY a file Floe itself downloaded inside
    /// the deterministic `.floe/artifacts/<runID>/` tree. Anything else — a
    /// user path, a symlink target or a non-regular file — is refused, and
    /// the default (non-overwrite) path never touches an existing file.
    private static func removeFloeOwnedDownload(root: URL, directory: String,
                                                artifact: GitHubActionsArtifactRecord) throws {
        let ownerPrefix = root.standardizedFileURL.appendingPathComponent(directory).standardizedFileURL.path
        guard ownerPrefix.hasPrefix(root.standardizedFileURL.path + "/" + Self.artifactRelativeRoot + "/") else {
            throw Failure.invalidArguments
        }
        let base = (artifact.downloadedRelativePath ?? "").replacingOccurrences(of: "\\", with: "/")
        guard base.hasPrefix("\(directory)/"), !base.contains(".."), !base.isEmpty,
              let last = base.split(separator: "/").last else {
            // No recorded path: the streamer's deterministic name still
            // refuses an existing destination; nothing pre-deleted here.
            return
        }
        let candidate = URL(fileURLWithPath: ownerPrefix).appendingPathComponent(String(last))
        let expected = ownerPrefix + "/" + String(last)
        var info = stat()
        guard stat(candidate.path, &info) == 0,
              candidate.path == expected,
              (Int(info.st_mode) & Int(S_IFMT)) == Int(S_IFREG) else { return }
        try FileManager.default.removeItem(at: candidate)
    }

    // MARK: - Workflow template install (default branch, explicit)

    private func installTemplate(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                                 service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let ownerName = try args.segment("owner")
        let repositoryName = try args.segment("repository")
        let templateID = try args.text("templateID", maximum: 64)
        guard let template = IDEGitHubActionsWorkflowCatalog.templates.first(where: { $0.id == templateID }) else {
            throw Failure.invalidArguments
        }
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .fileMutation, cancellation: cancellation) { resolved, fileService in
            _ = resolved
            try cancellation.throwIfCancelled()
            guard let token = try await credentials.token() else { throw G04WorkspaceGit.Failure.needsAccount }
            let selection = try await Self.repositorySelection(owner: github, actions: actions,
                credentials: credentials, ownerName: ownerName, repositoryName: repositoryName,
                token: token, cancellation: cancellation)
            let branch = selection.defaultBranch
            let existingPaths = (try? await actions.workflowFilePaths(owner: ownerName,
                repository: repositoryName, ref: branch, token: token)) ?? []
            let existing = try await actions.fileContent(owner: ownerName, repository: repositoryName,
                path: template.workflowPath, ref: branch, token: token)
            let templateSHA = FloeDigest.sha256Hex(Data(template.yaml.utf8))
            let decision = IDEGitHubActionsWorkflowInstallationPolicy.decision(
                existingSHA256: existing.map { FloeDigest.sha256Hex($0) },
                templateSHA256: templateSHA, templatePath: template.workflowPath,
                existingPaths: existingPaths)
            try cancellation.throwIfCancelled()
            switch decision {
            case .alreadyInstalled:
                return try Self.encoded(["outcome": .string("alreadyInstalled"),
                                         "path": .string(template.workflowPath),
                                         "templateID": .string(template.id),
                                         "yaml": .string(String(template.yaml.prefix(160 * 1024)))])
            case .conflict(let suggested):
                let exported = try Self.exportTemplate(template, fileService: fileService)
                return try Self.encoded(["outcome": .string("conflict"),
                                         "path": .string(template.workflowPath),
                                         "templateID": .string(template.id),
                                         "suggestedPath": .string(suggested),
                                         "exportedRelativePath": exported.map { DesignJSONValue.string($0) } ?? .null,
                                         "yaml": .string(String(template.yaml.prefix(160 * 1024)))])
            case .install:
                try await Self.commitWorkflowFile(template.yaml, path: template.workflowPath,
                    branch: branch, message: "Floe IDE: install \(template.id) workflow",
                    owner: ownerName, repository: repositoryName, github: github,
                    actions: actions, token: token, cancellation: cancellation)
                try cancellation.throwIfCancelled()
                guard current(), !retired else { throw Failure.retired }
                return try Self.encoded(["outcome": .string("installed"),
                                         "path": .string(template.workflowPath),
                                         "templateID": .string(template.id),
                                         "branch": .string(branch),
                                         "yaml": .string(String(template.yaml.prefix(160 * 1024)))])
            }
        }
    }

    /// Exports the template into the workspace for manual review (no network):
    /// a NEW file below `.floe/workflows` only — `createFile(overwrite:false)`
    /// keeps an existing review copy intact.
    private static func exportTemplate(_ template: IDEGitHubActionsWorkflowTemplate,
                                       fileService: WorkspaceFileService) throws -> String? {
        let file = template.workflowPath.split(separator: "/").last.map(String.init) ?? template.fileName
        let relative = ".floe/workflows/\(file)"
        guard IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath(relative),
              relative.utf8.count <= 4096, template.yaml.utf8.count <= IDEGitHubActionsWorkflowCatalog.maximumTemplateBytes else {
            return nil
        }
        do {
            _ = try fileService.createFile(relative, content: template.yaml, overwrite: false)
            return relative
        } catch {
            // An existing review copy is honestly reported as not-exported;
            // the conflict result still carries the full YAML for review.
            return nil
        }
    }

    /// Fast-forward-only workflow file commit onto the repository's default
    /// branch — the original `commitWorkflowFile` sequence, unchanged.
    private static func commitWorkflowFile(_ yaml: String, path: String, branch: String, message: String,
                                           owner ownerName: String, repository: String,
                                           github: GitHubService, actions: GitHubActionsClient,
                                           token: String, cancellation: CancellationToken) async throws {
        let baseSHA = try await actions.refSHA(owner: ownerName, repository: repository,
                                               branch: branch, token: token)
        try cancellation.throwIfCancelled()
        let baseTree = try await actions.commitTreeSHA(owner: ownerName, repository: repository,
                                                       commitSHA: baseSHA, token: token)
        let blob = try await actions.createBlob(owner: ownerName, repository: repository,
            content: Data(yaml.utf8).base64EncodedString(), token: token)
        let tree = try await actions.createTree(owner: ownerName, repository: repository,
            baseTreeSHA: baseTree, entries: [GitHubActionsTreeEntry(path: path, sha: blob)], token: token)
        let identity = try await github.account(token: token)
        let commit = try await actions.createCommit(owner: ownerName, repository: repository,
            message: message, treeSHA: tree, parentSHAs: [baseSHA],
            authorName: identity.name ?? identity.login,
            authorEmail: "\(identity.login)@users.noreply.github.com",
            date: Date(), token: token)
        try cancellation.throwIfCancelled()
        try await actions.updateRef(owner: ownerName, repository: repository, branch: branch,
                                    sha: commit, token: token)
    }

    /// The selected repository's truth comes from the account query, never
    /// from the payload: the default branch and id are read natively.
    private static func repositorySelection(owner github: GitHubService, actions: GitHubActionsClient,
                                            credentials: GitHubCredentialStore, ownerName: String,
                                            repositoryName: String, token: String,
                                            cancellation: CancellationToken) async throws
        -> GitHubActionsRepositorySelection {
        _ = actions
        try cancellation.throwIfCancelled()
        let rows = try await github.repositories(token: token, limit: 100)
        let fullName = "\(ownerName)/\(repositoryName)"
        guard let match = rows.first(where: { $0.fullName.caseInsensitiveCompare(fullName) == .orderedSame })
        else { throw GitHubActionsError.invalidConfiguration("repository is not on the connected account") }
        return GitHubActionsRepositorySelection(id: match.id, fullName: match.fullName,
                                                defaultBranch: match.defaultBranch, isPrivate: match.isPrivate)
    }

    // MARK: - Dispatch (durable engine, original state machine)

    private func dispatch(args: G04WorkspaceGit.Arguments, owner: G04WorkspaceOwner, root: URL?,
                          service: WorkspaceFileService?, cancellation: CancellationToken)
        async throws -> DesignJSONValue {
        let ownerName = try args.segment("owner")
        let repositoryName = try args.segment("repository")
        let workflowPath = try args.text("workflowPath", maximum: 512)
        guard IDEGitHubActionsWorkflowCatalog.isWorkflowPath(workflowPath) else { throw Failure.invalidArguments }
        let requestID = try args.text("requestID", maximum: 64)
        let languageID = try args.text("languageID", maximum: 64)
        let roleRaw = try args.text("role", maximum: 32)
        let platformRaw = try args.text("platform", maximum: 32)
        guard let role = IDEGitHubActionsRunRole(rawValue: roleRaw),
              let platform = GitHubActionsRunnerPlatform(rawValue: platformRaw) else {
            throw Failure.invalidArguments
        }
        let reviewedSHA = try args.digestLike("reviewedManifestSHA")
        let inputs = try args.stringMap("inputs")
        var targetFile: String?
        if let raw = try args.optional("targetFile", maximum: 4096) {
            guard IDEGitHubActionsSafePath.isSafeWorkspaceRelativePath(raw) else { throw Failure.invalidArguments }
            targetFile = raw
        }
        return try await withResolved(owner: owner, root: root, service: service,
            intent: .read, cancellation: cancellation) { resolved, fileService in
            let state = await state(owner: owner, root: resolved)

            // Fresh disk truth, then compare against what the user reviewed. The
            // document mutation barrier (begin in G04WorkspaceGit.execute) already
            // refused dirty drafts, so disk == what the editor shows.
            let manifest = try Self.buildManifest(directory: ".", fileService: fileService)
            guard Self.manifestDigest(manifest) == reviewedSHA else { throw Failure.reviewStale }

            let selection = try await Self.repositorySelection(owner: github, actions: actions,
                credentials: credentials, ownerName: ownerName, repositoryName: repositoryName,
                token: try await token(), cancellation: cancellation)
            let template = IDEGitHubActionsWorkflowCatalog.template(languageID: languageID, role: role,
                                                                    platform: platform)
            let isFloeTemplate = (template?.workflowPath == workflowPath)
            let runBranch = IDEGitHubActionsSnapshotPolicy.runBranch(runToken: requestID)
            var dispatchInputs: [String: String] = [:]
            if isFloeTemplate {
                if let targetFile { dispatchInputs["target_file"] = targetFile }
            } else {
                dispatchInputs = inputs
            }
            let draft = GitHubActionsJobRecord(
                requestID: requestID,
                workspaceID: owner.workspaceID,
                environmentID: nil,
                workspaceRootPath: resolved.path,
                languageID: languageID,
                role: role.rawValue,
                repositoryFullName: selection.fullName,
                owner: ownerName,
                repository: repositoryName,
                baseRef: selection.defaultBranch,
                runBranch: runBranch,
                workflowPath: workflowPath,
                installsTemplate: isFloeTemplate,
                expectedArtifactName: isFloeTemplate ? template?.expectedArtifactName : nil,
                snapshotCommitSHA: nil,
                snapshotTreeSHA: nil,
                snapshotFiles: manifest.entries.map {
                    GitHubActionsSnapshotEntryRecord(path: $0.path, byteCount: $0.byteCount, sha256: $0.sha256)
                },
                snapshotTotalBytes: manifest.totalBytes,
                state: .preparing
            )
            let actions = self.actions
            let github = self.github
            let defaultBranch = selection.defaultBranch
            let baseRef = selection.defaultBranch
            let snapshotGuard = WorkspacePathGuard(
                rootURL: resolved,
                maxReadBytes: IDEGitHubActionsSnapshotPolicy.maximumFileBytes,
                maxWriteBytes: IDEGitHubActionsSnapshotPolicy.maximumTotalBytes)
            let record = await state.engine.dispatch(
                draft: draft,
                workflowPath: workflowPath,
                inputs: dispatchInputs,
                injectSnapshotInput: isFloeTemplate,
                resolveWorkflow: { ownerName, repositoryName, path, token in
                    for attempt in 0..<5 {
                        if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
                        let workflows = try await actions.workflows(owner: ownerName,
                                                                    repository: repositoryName, token: token)
                        if let match = workflows.first(where: { $0.path == path }) { return match.id }
                    }
                    return nil
                },
                publishSnapshot: { record, token in
                    try await Self.publishSnapshot(
                        record: record, manifest: manifest, guardResolver: snapshotGuard,
                        baseRef: baseRef, defaultBranch: defaultBranch,
                        actions: actions, github: github, token: token)
                }
            )
            guard current(), !retired else { throw Failure.retired }
            if let record {
                return try Self.encoded(["record": Self.recordValue(record),
                                         "recoveryActions": .array(Self.recoverySummary(record))])
            }
            // The engine already persisted whatever it proved (including
            // .associationPending with the snapshot identity). Surface the typed
            // engine error honestly instead of a bare nil.
            let lastError = await state.box.snapshot().1
            if let lastError { throw GitHubActionsEngineError.unresolved(lastError) }
            throw Failure.workflowNotRegistered
        }
    }

    private func token() async throws -> String {
        guard let value = try await credentials.token() else { throw G04WorkspaceGit.Failure.needsAccount }
        return value
    }

    /// Publishes exactly the reviewed manifest as a commit on the run-owned
    /// branch — the original `publishSnapshot` rules: every file re-hashed and
    /// compared to the reviewed entry BEFORE any remote write, the default
    /// branch's workflow file carried onto the run ref, and a NEW ref only
    /// (never a user branch moved).
    static func publishSnapshot(record: GitHubActionsJobRecord,
                                manifest: IDEGitHubActionsSnapshotManifest,
                                guardResolver: WorkspacePathGuard,
                                baseRef: String, defaultBranch: String,
                                actions: GitHubActionsClient, github: GitHubService,
                                token: String) async throws -> GitHubActionsPublishedSnapshot {
        let baseSHA = try await actions.refSHA(owner: record.owner, repository: record.repository,
                                               branch: baseRef, token: token)
        let baseTreeSHA = try await actions.commitTreeSHA(owner: record.owner,
            repository: record.repository, commitSHA: baseSHA, token: token)
        var treeEntries: [GitHubActionsTreeEntry] = []
        for entry in manifest.entries {
            let url = try guardResolver.resolve(entry.path)
            let data = try Self.readRegularFile(at: url, maxBytes: IDEGitHubActionsSnapshotPolicy.maximumFileBytes)
            guard FloeDigest.sha256Hex(data) == entry.sha256.lowercased() else {
                throw GitHubActionsError.invalidConfiguration("snapshot file changed during publish: \(entry.path)")
            }
            let blobSHA = try await actions.createBlob(owner: record.owner, repository: record.repository,
                content: data.base64EncodedString(), token: token)
            treeEntries.append(GitHubActionsTreeEntry(path: entry.path, sha: blobSHA))
        }
        if let workflowPath = record.workflowPath,
           let workflowData = try await actions.fileContent(owner: record.owner,
            repository: record.repository, path: workflowPath, ref: defaultBranch, token: token) {
            let blobSHA = try await actions.createBlob(owner: record.owner, repository: record.repository,
                content: workflowData.base64EncodedString(), token: token)
            treeEntries.append(GitHubActionsTreeEntry(path: workflowPath, sha: blobSHA))
        }
        let treeSHA = try await actions.createTree(owner: record.owner, repository: record.repository,
            baseTreeSHA: baseTreeSHA, entries: treeEntries, token: token)
        let identity = try await github.account(token: token)
        let authorName = identity.name ?? identity.login
        let commitSHA = try await actions.createCommit(owner: record.owner, repository: record.repository,
            message: "Floe IDE snapshot \(record.requestID)", treeSHA: treeSHA, parentSHAs: [baseSHA],
            authorName: authorName, authorEmail: "\(identity.login)@users.noreply.github.com",
            date: Date(), token: token)
        try await actions.createRef(owner: record.owner, repository: record.repository,
            ref: "refs/heads/\(record.runBranch)", sha: commitSHA, token: token)
        return GitHubActionsPublishedSnapshot(commitSHA: commitSHA, treeSHA: treeSHA)
    }

    /// Bounded regular-file read for snapshot publishing — the original
    /// `IDERunSourceReader.readRegularFile` rules: symlinks and non-regular
    /// files refuse, and a byte over the bound refuses BEFORE any read.
    /// Review revision 3 (GIT_PRIVATE_PATCH_REVIEW_01.json): validation binds
    /// to the ACTUAL descriptor — a separate `lstat` + `FileHandle(url)` pair
    /// still followed a link swapped between check and open. `O_NOFOLLOW`
    /// refuses the final-component link at open time, `O_NONBLOCK` prevents a
    /// swapped FIFO from blocking the read, `O_CLOEXEC` keeps the descriptor
    /// from leaking into children, and `fstat` on the opened fd performs the
    /// regular/size refusal BEFORE any bytes. The fd closes on every failure
    /// and success path; the bounded `maxBytes + 1` read and the typed
    /// refusals are unchanged, and the internal signature stays identical.
    static func readRegularFile(at url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT {
                throw GitHubActionsError.invalidConfiguration("snapshot file missing: \(url.lastPathComponent)")
            }
            if code == EMLINK || code == ELOOP {
                throw GitHubActionsError.invalidConfiguration("snapshot entry is not a regular file: \(url.lastPathComponent)")
            }
            throw GitHubActionsError.invalidConfiguration("snapshot file could not be opened: \(url.lastPathComponent)")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw GitHubActionsError.invalidConfiguration("snapshot file could not be opened: \(url.lastPathComponent)")
        }
        guard (Int(info.st_mode) & Int(S_IFMT)) == Int(S_IFREG) else {
            throw GitHubActionsError.invalidConfiguration("snapshot entry is not a regular file: \(url.lastPathComponent)") }
        guard info.st_size <= Int64(maxBytes) else {
            throw GitHubActionsError.responseTooLarge(limit: maxBytes) }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxBytes {
            let want = min(buffer.count, maxBytes + 1 - data.count)
            if want == 0 { break }
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if got < 0 {
                throw GitHubActionsError.invalidConfiguration("snapshot read failed: \(url.lastPathComponent)")
            }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
        }
        guard data.count <= maxBytes else { throw GitHubActionsError.responseTooLarge(limit: maxBytes) }
        return data
    }

    // MARK: - Shared helpers

    private static func identifier(_ raw: String) throws -> UUID {
        guard let uuid = UUID(uuidString: raw), raw.lowercased() == uuid.uuidString.lowercased() else {
            throw Failure.invalidArguments
        }
        return uuid
    }

    static func encoded(_ object: [String: DesignJSONValue]) throws -> DesignJSONValue {
        .object(object)
    }
}

extension G04WorkspaceGit.Arguments {
    /// A lowercase 64-hex digest field (same rule the workspace wire applies).
    func digestLike(_ key: String) throws -> String {
        let value = try text(key, maximum: 64)
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw G04WorkspaceGit.Failure.invalidArguments
        }
        return value
    }
}

// MARK: - Credential seam

/// Per-call token fetch through the ONE existing leased vault seam — the
/// original center rule, made `async` for the Android secure gateway.
private struct G04DomainTokenProvider: GitHubActionsTokenProviding {
    let store: GitHubCredentialStore
    func token() async throws -> String? { try await store.token() }
}

// MARK: - Remote adapter (maps FloeGit onto the engine's transport-neutral API)

/// Port of the original `CenterGitHubActionsRemote`. Delta: `downloadArtifact`
/// refuses with a typed error because production artifact bytes must stream
/// through `GitHubActionsArtifactStreamer` (see the header); every other
/// mapping is unchanged.
private struct G04ActionsRemoteAdapter: GitHubActionsRemoteClient {
    let client: GitHubActionsClient

    func queryRun(owner: String, repository: String, runID: Int64, token: String) async throws -> GitHubActionsRemoteRun {
        do {
            let run = try await client.run(owner: owner, repository: repository, runID: runID, token: token)
            return Self.observe(run)
        } catch { throw Self.map(error) }
    }

    func associateRun(
        owner: String, repository: String, workflowID: Int64, ref: String, headSHA: String,
        dispatchedAt: Date, baselineRunIDs: [Int64], returnedRunID: Int64?,
        token: String, maxAttempts: Int, pollInterval: TimeInterval
    ) async throws -> GitHubActionsRemoteRun {
        let receipt = GitHubActionsDispatchReceipt(
            owner: owner, repository: repository, workflowID: workflowID, ref: ref,
            headSHA: headSHA, dispatchedAt: dispatchedAt,
            baselineRunIDs: Set(baselineRunIDs), returnedRunID: returnedRunID
        )
        do {
            let run = try await client.associateRun(
                receipt, token: token, maxAttempts: maxAttempts, pollInterval: pollInterval
            )
            return Self.observe(run)
        } catch { throw Self.map(error) }
    }

    func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws {
        do {
            try await client.cancelRun(owner: owner, repository: repository, runID: runID, token: token)
        } catch { throw Self.map(error) }
    }

    func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GitHubActionsRemoteArtifact] {
        do {
            return try await client.artifacts(owner: owner, repository: repository, runID: runID, token: token)
                .map {
                    GitHubActionsRemoteArtifact(
                        id: $0.id, name: $0.name, sizeInBytes: $0.sizeInBytes,
                        expired: $0.expired, createdAt: $0.createdAt, expiresAt: $0.expiresAt,
                        digest: $0.digest
                    )
                }
        } catch { throw Self.map(error) }
    }

    func downloadArtifact(
        owner: String, repository: String, runID: Int64, artifactID: Int64,
        name: String, sizeInBytes: Int64, archiveURL: URL, token: String
    ) async throws -> GitHubActionsRemoteArtifactBytes {
        // Never reached: the durable record update happens in the streaming
        // download path that has already verified + committed the bytes.
        throw GitHubActionsEngineError.artifactDestination(
            "artifact bytes stream through the qualified Android artifact seam")
    }

    func dispatchBaseline(
        owner: String, repository: String, workflowID: Int64, branch: String, token: String
    ) async throws -> GitHubActionsRemoteBaseline {
        do {
            let baseline = try await client.dispatchBaseline(
                owner: owner, repository: repository, workflowID: workflowID, branch: branch, token: token
            )
            return GitHubActionsRemoteBaseline(runIDs: baseline.runIDs.sorted(), capturedAt: baseline.capturedAt)
        } catch { throw Self.map(error) }
    }

    func triggerDispatch(
        owner: String, repository: String, workflowID: Int64, ref: String,
        inputs: [String: String], token: String
    ) async throws -> GitHubActionsRemoteTrigger {
        do {
            let trigger = try await client.triggerDispatch(
                owner: owner, repository: repository, workflowID: workflowID,
                ref: ref, inputs: inputs, token: token
            )
            return GitHubActionsRemoteTrigger(runID: trigger.runID, htmlURL: trigger.htmlURL?.absoluteString)
        } catch { throw Self.map(error) }
    }

    private static func observe(_ run: GitHubActionsRun) -> GitHubActionsRemoteRun {
        GitHubActionsRemoteRun(
            id: run.id, status: run.status, conclusion: run.conclusion,
            htmlURL: run.htmlURL?.absoluteString
        )
    }

    static func map(_ error: Error) -> GitHubActionsEngineError {
        if GitHubActionsClient.isRateLimited(error) { return .rateLimited }
        if let typed = error as? GitHubActionsError {
            switch typed {
            case .invalidConfiguration(let detail): return .invalidConfiguration(detail)
            case .transport(let detail): return .transport(detail)
            case .http(let status, let message):
                if status == 403 {
                    return .invalidConfiguration(workflowDeniedText(message: message))
                }
                return .http(status: status, message: message)
            case .decoding(let detail): return .transport("unexpected GitHub response: \(detail)")
            case .responseTooLarge(let limit): return .responseTooLarge(limit: limit)
            case .associationUnresolved(let detail): return .unresolved(detail)
            case .redirectWithoutLocation: return .transport("download redirect had no destination")
            }
        }
        return .transport(error.localizedDescription)
    }

    /// A GitHub 403 on workflow setup almost always means the login lacks the
    /// `workflow` scope (or the fine-grained token lacks Workflows write).
    /// Same instruction as the original `workflowErrorText`, without the iOS
    /// localization table (the Android UI localizes by code).
    static func workflowDeniedText(message: String) -> String {
        "GitHub denied this workflow request (403): \(message) Connect GitHub with the workflow scope, "
        + "or install a workflow that the token can read."
    }
}

// MARK: - Generation registry for the trusted App lifecycle seam

/// Process-retained only for as long as the accepted generation lives:
/// `G04WorkspaceGit` registers at construction and deregisters at retirement.
/// This is the lookup the JNI scene hook uses so the ORIGINAL engine scene
/// rules (first active scene starts polling, last deactivation pauses it) can
/// be driven from the App lifecycle without any new model-facing surface.
enum G04GitActionsRegistry {
    private static let lock = NSLock()
    // Every access goes through `lock` above (same discipline as the
    // pre-existing RuntimeFacadeRunBridge static slot).
    nonisolated(unsafe) private static var domains: [UInt64: G04GitActionsDomain] = [:]

    /// Registration is keyed by the ACCEPTED epoch; liveness is enforced at
    /// every lookup (`domain(epoch:)` re-reads the native root epoch), so an
    /// attach that precedes the final readback publication still ends up
    /// with a correct, epoch-exact binding rather than a lost scene hook.
    static func register(epoch: UInt64, domain: G04GitActionsDomain) {
        guard epoch > 0 else { return }
        lock.withLock { domains[epoch] = domain }
    }

    static func deregister(epoch: UInt64) {
        lock.withLock { domains[epoch] = nil }
    }

    static func domain(epoch: UInt64) -> G04GitActionsDomain? {
        guard epoch > 0, G02NativeRootEpoch.readback() == epoch else { return nil }
        return lock.withLock { domains[epoch] }
    }
}

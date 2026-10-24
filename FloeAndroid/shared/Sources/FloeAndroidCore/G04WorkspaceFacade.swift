// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 workspace facade — the ONE root/epoch-owned service behind the
// closed `workspace.read` / `workspace.write` / `workspace.activate` bridge
// commands.
//
// Authority chain (nothing here is a stub or a second truth):
//   * documents/edits/bytes: MAIN's frozen `G04WorkspaceDocumentSession` over
//     the ORIGINAL FloeWorkspace `WorkspaceFileService` + `WorkspacePathGuard`;
//   * ownership/lifecycle: `G04LiveWorkspaceAccess` attaches the real
//     `.conversation` `RuntimeOwnedWorkToken` through `FacadeRunDomain` before
//     awaits and detaches only after actual IO settles;
//   * durable records: the SAME installed cluster stores (one DatabaseManager);
//   * oversized complete-query snapshots: the ORIGINAL bounded
//     `FacadeContentReader`, instantiated BY this facade for this epoch only —
//     handles are dispatch-disjoint from the session's document export
//     handles, so a workspace query never reads another domain's content and
//     vice versa;
//   * source/recovery metadata: MAIN's `AndroidWorkspaceSourceStore` journal
//     (47) stays metadata-only; the trusted `G04WorkspaceSourceCoordinator`
//     independently validates actual owned bytes/paths/digests and the OS
//     transport before any provider write is permitted.
//
// Lifecycle ordering (reviewed against RuntimeFacadeBootstrap.runShutdownJob
// + G02CompositionRoot.beginRetirement): the mailbox drain (registry count
// zero) happens BEFORE composition.beginRetirement, and the extension retires
// BEFORE the installed pointer is cleared and before `owner.close()`. Root
// retirement therefore gets one honest synchronous window to preserve dirty
// drafts to verified native-owned recovery storage using the ORIGINAL file
// service directly (registry admission is fenced at that point; no owned
// operation lease exists or may be fabricated there). Drafts whose durable
// copy cannot be PROVEN by read-back stay honestly pending: referenced by the
// process-retained extension and re-driven at the next attach. Explicit
// successful conversation deletion DISCARDS their carried drafts (task-deletion
// intent owns them; a next attach never resurrects deleted-task bytes).
import Foundation
import FloeCore
import FloeGit
import FloePersistence
import FloeTools
import FloeWorkspace

/// Typed reply of one admitted workspace request. `completed` carries a JSON
/// OBJECT document (the frozen effect-carrier rule); `refused` is the exact
/// closed wire code + reason — never a fabricated success, never a truncated
/// list claimed as complete.
public enum G04WorkspaceReply: Sendable {
    case completed(DesignJSONValue)
    case refused(code: String, reason: String?)
}

/// A dirty draft plus the root its bytes must be preserved under. Carried
/// across an epoch boundary ONLY when the durable copy could not be proven.
public struct G04CarriedWorkspaceDraft: Sendable {
    public let draft: G04RetainedDraft
    public let rootPath: String
    public var byteCount: Int { draft.text.utf8.count }
}

/// Root-owned facade service. Exactly one instance per accepted generation,
/// created ONLY by a successful `G04WorkspaceDomainExtension.attach`.
public actor G04WorkspaceFacade {
    /// One session per exact task+workspace (never per payload).
    private struct Key: Hashable { let taskID: UUID; let workspaceID: UUID }

    /// Bounded complete-query snapshot provenance. The reader owns the bytes;
    /// this map owns the owner proof and the honest expiry.
    private struct QuerySnapshot: Sendable {
        let owner: G04WorkspaceOwner
        let expires: Date
    }

    public static let maximumSessions = 8
    public static let maximumQuerySnapshotsPerConversation = 4
    public static let querySnapshotTTL: TimeInterval = 120
    /// Serialized query results above this size stage through the ORIGINAL
    /// bounded reader instead of being truncated into the carrier. 24 KiB
    /// keeps the inline reply inside the frozen 48 KiB page budget with the
    /// same headroom the document byte channel uses.
    public static let inlineBudgetBytes = 24 * 1024
    /// Hard ceiling for honestly-pending carried drafts. New session
    /// admissions refuse typed while the carry is at the ceiling; carried
    /// bytes are NEVER dropped to make room.
    public static let maximumCarriedBytes = 64 * 1024 * 1024

    public let epoch: UInt64
    public let rootPath: String
    /// The trusted source/recovery authority port for the frozen SAF
    /// gateway (and later webdav/smb producers). Built over the SAME
    /// installed cluster + journal 47; Main's JNI/SAF adapter attaches the
    /// platform transport exactly once via `source.attachTransport(_:)`.
    /// While unbound every provider-touching call answers typed
    /// `transportNotBound` — normal workspace payloads cannot reach or widen
    /// this surface.
    public let source: G04WorkspaceSourceCoordinator
    private let installed: G02InstalledComposition
    private let runDomain: FacadeRunDomain
    private let access: any G04WorkspaceAccessPort
    private let queries: FacadeContentReader
    private let git: G04WorkspaceGit
    /// Main-owned bounded projection recovery (G04-R1 2026-10-24 hook). This
    /// facade only routes the four closed subops and forwards retirement;
    /// the actor independently acquires the ORIGINAL access lease and
    /// verifies Root/task/workspace/purpose/target per operation, so a full
    /// unconfirmed JVM draft can settle durably even while all eight editor
    /// sessions are dirty (session admission is deliberately bypassed).
    private let projectionRecovery: G04ProjectionRecovery

    private var sessions: [Key: G04WorkspaceDocumentSession] = [:]
    private var activity: [Key: UInt64] = [:]
    private var admissionCounter: UInt64 = 0
    private var querySnapshots: [String: QuerySnapshot] = [:]
    private var retired = false
    /// Composition-installed handle for the ORIGINAL fourteen Git model tool
    /// runners (G04GitToolBindings). Installed at this facade's init tail —
    /// the point where the FloeGit/native Git dependency is proven bound for
    /// this generation — and retired inside `beginRetirement`, so discovery
    /// never advertises a runner the retired generation cannot execute.
    private var gitToolsHandle: G04GitToolBindings.Handle? = nil

    init(epoch: UInt64, installed: G02InstalledComposition,
         runDomain: FacadeRunDomain, access: any G04WorkspaceAccessPort) {
        self.epoch = epoch
        self.installed = installed
        self.rootPath = installed.cluster.identity.root.path
        self.runDomain = runDomain
        self.access = access
        self.queries = FacadeContentReader(generation: epoch)
        self.source = G04WorkspaceSourceCoordinator(epoch: epoch, cluster: installed.cluster)
        self.git = G04WorkspaceGit(epoch: epoch, installed: installed, access: access)
        self.projectionRecovery = G04ProjectionRecovery(epoch: epoch, access: access)
        // Swift 6: a nonisolated actor `init` may not capture `self` into the
        // escaping routing closure below. `bindGitTools` performs the exact
        // same install as the first isolated step of the trusted attach,
        // BEFORE transport publication, handler registration or any registry
        // publish — the externally observable install-before-publish order is
        // unchanged and a refused attach still retires through the same
        // handle path (`gitToolsHandle?.retire()`).
    }

    /// Installs the original fourteen Git tools through the guarded
    /// bindings, exactly once. Trusted composition calls this immediately
    /// after construction; double calls are ignored.
    public func bindGitTools() {
        guard gitToolsHandle == nil else { return }
        self.gitToolsHandle = G04GitToolBindings.install(routing: G04GitToolRouting(
            epoch: epoch,
            isLive: { [installed] in
                self.epoch == G02NativeRootEpoch.readback()
                    && G02RuntimeComposition.shared.installedComposition === installed
            },
            resolveOwner: { [cluster = installed.cluster, epoch] taskID in
                guard let conversation = try? await cluster.conversationStore.conversation(id: taskID),
                      conversation.purpose == .ordinary,
                      let workspaceID = try? await cluster.workspaceStore.workspaceID(conversationID: taskID),
                      let record = try? await cluster.workspaceStore.workspace(id: workspaceID),
                      record.kind == .privateTask,
                      G02NativeRootEpoch.readback() == epoch else { return nil }
                return G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: workspaceID)
            },
            access: access,
            session: { owner in await self.admittedToolSession(owner) },
            tools: GitToolEnvironment(
                rootProvider: { nil },
                git: LocalGitService(),
                github: GitHubService(),
                // The SAME one vault seam: a stateless lease over the epoch's
                // physical observer registry, exactly like G04WorkspaceGit's
                // own store. Token is read per call and never cached here.
                credentials: GitHubCredentialStore(
                    lease: G04GitCredentialLease(epoch: epoch, installed: installed)),
                localAuthor: nil)
        ))
    }

    // MARK: - Composition freshness (exact root/epoch, across awaits)

    /// True while THIS facade's accepted generation is the live installed
    /// composition. Checked before and after every suspension-bearing step;
    /// a stale epoch can never mutate a newer generation's state.
    private var compositionIsLive: Bool {
        !retired && epoch == G02NativeRootEpoch.readback()
            && G02RuntimeComposition.shared.installedComposition === installed
            && RunDomainFacade.current(epoch: epoch) != nil
    }

    private var cluster: G02OwnedStoreCluster { installed.cluster }

    /// Drafts whose durable recovery has NOT yet been proven. Referenced by
    /// the process-retained extension across epochs and re-driven at the next
    /// attach; never advertised as recovered.
    public private(set) var pendingRetirement: [G04CarriedWorkspaceDraft] = []

    public var pendingRetirementBytes: Int {
        pendingRetirement.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - Session admission

    /// Re-validates, for EVERY admission across its awaits: the durable
    /// conversation exists with `ordinary` purpose (temporary sessions never
    /// enter SQLite; Notes documents live in a different workspace), the
    /// payload workspaceID equals the exact ORIGINAL ownership binding, and
    /// the bound record is the accepted private-task shape. A managed/source
    /// write layer needs its own explicit ORIGINAL record/source binding and
    /// native validated ownership, so it stays typed `backendUnavailable`
    /// here — never a guessed first project, never a reinterpreted
    /// `content://` as a POSIX path.
    /// Result carrier: `G04WorkspaceReply` is the closed JNI reply enum;
    /// Result requires an Error, so refusal passes through this thin
    /// typed carrier and the dispatch sites return the EXACT reply below.
    private struct AdmissionRefusal: Error { let reply: G04WorkspaceReply }

    private func admittedSession(taskID: UUID, workspaceID: UUID) async
        -> Result<G04WorkspaceDocumentSession, AdmissionRefusal> {
        guard compositionIsLive else { return .failure(AdmissionRefusal(reply: .refused(code: "retired", reason: nil))) }
        guard pendingRetirementBytes < Self.maximumCarriedBytes else {
            // Honest saturation: carried unrecovered drafts are never evicted
            // to make room; new workspaces refuse until a reconcile settles.
            return .failure(AdmissionRefusal(reply: .refused(code: "backendUnavailable", reason: "recoveryCarrySaturated")))
        }
        do {
            guard let conversation = try await cluster.conversationStore.conversation(id: taskID)
            else { return .failure(AdmissionRefusal(reply: .refused(code: "notFound", reason: "conversationMissing"))) }
            guard conversation.purpose == .ordinary else {
                return .failure(AdmissionRefusal(reply: .refused(code: "purposeNotOrdinary", reason: nil)))
            }
            guard try await cluster.workspaceStore.workspaceID(conversationID: taskID) == workspaceID,
                  let workspace = try await cluster.workspaceStore.workspace(id: workspaceID)
            else { return .failure(AdmissionRefusal(reply: .refused(code: "ownerChanged", reason: "workspaceBindingMismatch"))) }
            guard compositionIsLive else { return .failure(AdmissionRefusal(reply: .refused(code: "retired", reason: nil))) }
            guard workspace.kind == .privateTask else {
                return .failure(AdmissionRefusal(reply: .refused(code: "backendUnavailable",
                                                                  reason: "managedSourceLayerRequiresExplicitBinding")))
            }
        } catch {
            return .failure(AdmissionRefusal(reply: Self.refusal(for: error)))
        }
        let key = Key(taskID: taskID, workspaceID: workspaceID)
        admissionCounter &+= 1
        activity[key] = admissionCounter
        if let existing = sessions[key] { return .success(existing) }
        if sessions.count >= Self.maximumSessions {
            // Bounded registry: evict ONLY a proven-clean session (no dirty
            // drafts, no open transfers); never silently drop unsaved work.
            var victim: Key?
            for candidate in sessions.keys.sorted(by: { (activity[$0] ?? 0) < (activity[$1] ?? 0) }) {
                if let session = sessions[candidate], await session.isEvictable { victim = candidate; break }
            }
            guard let victim else {
                return .failure(AdmissionRefusal(reply: .refused(code: "transferLimit", reason: "workspaceSessionsSaturated")))
            }
            await retireSession(victim, preserve: true)
        }
        let owner = G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: workspaceID)
        let session = G04WorkspaceDocumentSession(owner: owner, access: access)
        sessions[key] = session
        return .success(session)
    }

    /// The SAME admission path as wire operations: durable ordinary
    /// conversation + exact original workspace binding + accepted private-task
    /// shape, then the live session for that task+workspace under the bounded
    /// registry rules. The Git model tools' document mutation barrier uses
    /// ONLY this resolver — never a guessed or second session.
    func admittedToolSession(_ owner: G04WorkspaceOwner) async -> G04WorkspaceDocumentSession? {
        guard owner.epoch == epoch, !retired else { return nil }
        switch await admittedSession(taskID: owner.taskID, workspaceID: owner.workspaceID) {
        case .success(let session): return session
        case .failure: return nil
        }
    }

    // MARK: - Closed grammar dispatch

    public func execute(command: String, taskID: UUID?, payload: SettingsDomainV1.JSONValue) async -> G04WorkspaceReply {
        guard let taskID else { return .refused(code: "invalidPayload", reason: "conversationOwnerMissing") }
        let request: G04WorkspaceWireRequest
        do {
            request = try G04WorkspaceWireRequest(payload: payload, command: command)
        } catch {
            return Self.refusal(for: error)
        }
        guard request.nativeEpoch == epoch else { return .refused(code: "epochMismatch", reason: nil) }
        // Main recovery hook (G04-R1 2026-10-24): the four closed projection
        // recovery subops deliberately BYPASS editor-session admission and
        // eviction, because a lost full-text draft must be able to settle
        // durably even when all eight sessions hold dirty drafts. The
        // recovery actor independently acquires the ORIGINAL access lease
        // and re-verifies Root/task/workspace/purpose/target per operation —
        // this is not an authorization bypass, and no other operation can
        // reach it.
        if Self.isProjectionRecovery(request.operation) {
            guard compositionIsLive else { return .refused(code: "retired", reason: nil) }
            let owner = G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: request.workspaceID)
            do {
                return .completed(try await projectionRecovery.execute(request, owner: owner))
            } catch {
                return Self.refusal(for: error)
            }
        }
        switch await admittedSession(taskID: taskID, workspaceID: request.workspaceID) {
        case .failure(let refusal): return refusal.reply
        case .success(let session):
            let owner = G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: request.workspaceID)
            do {
                return try await dispatch(request, owner: owner, session: session)
            } catch {
                // An ownership refusal on a live session means the durable
                // binding changed under us: fence that session honestly. A
                // committed task deletion DISCARDS its drafts (the user's
                // delete intent owns the workspace cleanup); a rebind or
                // retirement preserves them durably first.
                if Self.isOwnershipRefusal(error) {
                    await fenceSession(taskID: taskID, workspaceID: request.workspaceID)
                }
                return Self.refusal(for: error)
            }
        }
    }

    /// The four closed workspace.write projection-recovery subops owned by
    /// Main's `G04ProjectionRecovery` actor. Routing lives ONLY in `execute`
    /// (before session admission); this predicate defers to the actor's own
    /// exclusive set so the grammar cannot drift from the implementation.
    static func isProjectionRecovery(_ operation: G04WorkspaceWireRequest.Operation) -> Bool {
        G04ProjectionRecovery.operations.contains(operation)
    }

    private func dispatch(_ request: G04WorkspaceWireRequest, owner: G04WorkspaceOwner,
                          session: G04WorkspaceDocumentSession) async throws -> G04WorkspaceReply {
        switch request.operation {
        case .beginProjectionRecovery, .appendProjectionRecovery,
             .commitProjectionRecovery, .cancelProjectionRecovery:
            // Unreachable by construction: `execute` answers these BEFORE
            // admission. The branch exists only so the closed-grammar switch
            // stays exhaustive; a routed recovery op can never open a
            // session, consume a draft slot or invent a revision.
            throw G04WorkspaceWireRequest.Failure.wrongFamily
        case .gitQuery, .gitMutate:
            let value = try await git.execute(owner: owner,
                action: request.text("action", maxBytes: 64),
                arguments: request.fieldsObject("arguments"), write: request.operation == .gitMutate, documents: session)
            return await stageIfOversized(value, owner: owner, path: nil)
        // MARK reads
        case .list:
            let path = try request.text("path", default: ".")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            // MAIN contract review 2026-10-24: `list` keeps the ORIGINAL
            // one-page/pageToken behavior. The native facade NEVER drains a
            // whole tree up front; the App host follows the actual
            // `nextPageToken` and assembles/lazily presents rows with bounded
            // UI state. Each returned page is a COMPLETE page — staging only
            // carries that page's full JSON when the page itself exceeds the
            // inline carrier budget.
            let page = try await session.list(path,
                                               page: try request.optionalText("pageToken", maxBytes: 8192))
            return await stageIfOversized(Self.directoryDocument(page, path: path), owner: owner, path: path)
        case .search:
            let query = try request.text("query", maxBytes: 8192)
            let path = try request.text("path", default: ".")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            let hits = try await session.search(query, in: path)
            let document: DesignJSONValue = .object([
                "query": .string(query), "path": .string(path),
                "hits": .array(hits.map(Self.searchHit)),
                "capped": .bool(hits.count == WorkspaceFileService.maxSearchHits),
            ])
            return await stageIfOversized(document, owner: owner, path: path)
        case .findFileNames:
            let query = try request.text("query", maxBytes: 8192)
            let path = try request.text("path", default: ".")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            let names = try await session.findFileNames(query, in: path)
            let document: DesignJSONValue = .object([
                "query": .string(query), "path": .string(path),
                "names": .array(names.map { DesignJSONValue.string($0) }),
                "capped": .bool(names.count == WorkspaceFileService.maxSearchHits),
            ])
            return await stageIfOversized(document, owner: owner, path: path)
        case .metadata:
            let value = try await session.metadata(try request.text("path"))
            return .completed(Self.metadataDocument(value))
        case .tabs:
            let headers = try await session.tabs()
            let document: DesignJSONValue = .object(["documents": .array(headers.map(Self.headerDocument))])
            return await stageIfOversized(document, owner: owner, path: nil)
        case .open:
            let path = try request.text("path")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            return .completed(Self.headerDocument(try await session.open(path)))
        case .beginContent:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let part = G04DocumentContentPart(rawValue:
                try request.text("part", default: "document", maxBytes: 32)) ?? .document
            let content = try await session.beginContent(documentID, revision: revision, part: part)
            return .completed(.object([
                "documentID": .string(documentID.uuidString), "part": .string(part.rawValue),
                "handle": .string(content.handle.uuidString), "byteCount": .integer(Int64(content.byteCount)),
                "sha256": .string(content.sha256), "header": Self.headerDocument(content.header),
            ]))
        case .readContent:
            let handle = try request.identifier("handle")
            let offset = try request.integer("offset", maximum: 17 * 1024 * 1024)
            let limit = try request.integer("limit", maximum: G04WorkspaceDocumentSession.maximumChunkBytes)
            guard limit > 0 else { throw G04WorkspaceWireRequest.Failure.invalidField("limit") }
            let chunk = try await session.readContent(handle, offset: offset, limit: limit)
            return .completed(Self.chunkDocument(chunk.bytes, nextOffset: chunk.nextOffset, finished: chunk.finished))
        case .releaseContent:
            let handle = try request.identifier("handle")
            await session.releaseContent(handle)
            return .completed(.object(["released": .bool(true)]))
        case .find:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let found = try await session.find(documentID, revision: revision,
                                                query: try request.text("query", maxBytes: 8192),
                                                caseSensitive: try request.flag("caseSensitive"),
                                                wholeWord: try request.flag("wholeWord"),
                                                backwards: try request.flag("backwards"))
            return .completed(Self.findDocument(found))
        case .queryContent:
            return await queryContent(request, owner: owner)
        case .releaseQuery:
            return releaseQuery(request, owner: owner)
        // MARK writes
        case .createFile:
            let path = try request.text("path")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            let content = try request.text("content", default: "", maxBytes: 24 * 1024)
            let outcome = try await session.createFile(path, content: content)
            return .completed(.object([
                "relativePath": .string(path), "bytesWritten": .integer(Int64(outcome.bytesWritten)),
                "sha256": .string(outcome.sha256), "mtime": .number(outcome.mtime),
            ]))
        case .createDirectory:
            let path = try request.text("path")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            try await session.createDirectory(path)
            return .completed(.object(["relativePath": .string(path), "created": .bool(true)]))
        case .move:
            let from = try request.text("from")
            let to = try request.text("to")
            guard Self.isRelative(from), Self.isRelative(to) else {
                throw G04WorkspaceWireRequest.Failure.invalidField("path")
            }
            let headers = try await session.move(from, to: to)
            return .completed(.object([
                "from": .string(from), "to": .string(to), "documents": .array(headers.map(Self.headerDocument)),
            ]))
        case .copy:
            let from = try request.text("from")
            let to = try request.text("to")
            guard Self.isRelative(from), Self.isRelative(to) else {
                throw G04WorkspaceWireRequest.Failure.invalidField("path")
            }
            try await session.copy(from, to: to)
            return .completed(.object(["from": .string(from), "to": .string(to), "copied": .bool(true)]))
        case .delete:
            let path = try request.text("path")
            guard Self.isRelative(path) else { throw G04WorkspaceWireRequest.Failure.invalidField("path") }
            let closed = try await session.delete(path, recursive: try request.flag("recursive"))
            return .completed(.object([
                "relativePath": .string(path),
                "closedDocuments": .array(closed.map { DesignJSONValue.string($0.uuidString) }),
            ]))
        case .edit:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let range = try request.range()
            let replacement = try request.text("replacement", maxBytes: 24 * 1024)
            var selection: NSRange?
            if request.hasField("selectionLocation") || request.hasField("selectionLength") {
                let location = try request.integer("selectionLocation",
                                                    maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
                let length = try request.integer("selectionLength",
                                                  maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
                guard length <= G04WorkspaceDocumentSession.maximumDocumentBytes - location else {
                    throw G04WorkspaceWireRequest.Failure.invalidField("selectionLength")
                }
                selection = NSRange(location: location, length: length)
            }
            return .completed(Self.headerDocument(try await session.edit(documentID, revision: revision,
                                                                          range: range, replacement: replacement,
                                                                          selection: selection)))
        case .selection:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let range = try request.range()
            return .completed(Self.headerDocument(try await session.updateSelection(documentID, revision: revision,
                                                                                     selection: range)))
        case .replace:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let result = try await session.replace(documentID, revision: revision,
                                                    query: try request.text("query", maxBytes: 8192),
                                                    replacement: try request.text("replacement", maxBytes: 24 * 1024),
                                                    caseSensitive: try request.flag("caseSensitive"),
                                                    wholeWord: try request.flag("wholeWord"),
                                                    all: try request.flag("all"))
            return .completed(.object([
                "header": Self.headerDocument(result.header), "replacements": .integer(Int64(result.replacements)),
            ]))
        case .beginEditUpload:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let range = try request.range()
            let byteCount = try request.integer("byteCount",
                                                 maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
            let handle = try await session.beginEditUpload(documentID, revision: revision, range: range,
                                                            byteCount: byteCount,
                                                            sha256: try request.digest("sha256"))
            return .completed(.object(["handle": .string(handle.uuidString), "accepted": .bool(true)]))
        case .appendEditUpload:
            let handle = try request.identifier("handle")
            let offset = try request.integer("offset", maximum: G04WorkspaceDocumentSession.maximumDocumentBytes)
            let base64 = try request.text("bytes", maxBytes: 32 * 1024)
            guard let data = Data(base64Encoded: base64),
                  data.count <= G04WorkspaceDocumentSession.maximumChunkBytes else {
                throw G04WorkspaceWireRequest.Failure.invalidField("bytes")
            }
            let next = try await session.appendEditUpload(handle, offset: offset, bytes: data)
            return .completed(.object(["nextOffset": .integer(Int64(next))]))
        case .commitEditUpload:
            let handle = try request.identifier("handle")
            return .completed(Self.headerDocument(try await session.commitEditUpload(handle)))
        case .cancelEditUpload:
            let handle = try request.identifier("handle")
            await session.cancelEditUpload(handle)
            return .completed(.object(["cancelled": .bool(true)]))
        case .undo, .redo:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let header = request.operation == .undo
                ? try await session.undo(documentID, revision: revision)
                : try await session.redo(documentID, revision: revision)
            return .completed(Self.headerDocument(header))
        case .save:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let outcome = try await session.save(documentID, revision: revision)
            switch outcome {
            case .saved(let header):
                return .completed(.object(["state": .string("saved"), "header": Self.headerDocument(header)]))
            case .conflict(let header, let conflict):
                // Identity-only conflict: base/draft/current text NEVER rides
                // this control reply — fetch them via beginContent parts.
                return .completed(.object([
                    "state": .string("conflict"), "header": Self.headerDocument(header),
                    "conflict": .object([
                        "path": .string(conflict.path), "currentSHA256": .string(conflict.currentSHA256),
                        "currentMtime": .number(conflict.currentMtime),
                        "recoveryPath": conflict.recoveryPath.map { DesignJSONValue.string($0) } ?? .null,
                        "basePresent": .bool(conflict.base != nil),
                        "draftSHA256": .string(FloeDigest.sha256Hex(Data(conflict.draft.utf8))),
                    ]),
                ]))
            }
        case .resolveConflictUsingDraft:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            return .completed(Self.headerDocument(try await session.resolveConflictUsingDraft(
                documentID, revision: revision, reviewedSHA256: try request.digest("reviewedSHA256"))))
        case .close:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            try await session.closeDocument(documentID, revision: revision,
                                             discardDraft: try request.flag("discardDraft"))
            return .completed(.object(["documentID": .string(documentID.uuidString), "closed": .bool(true)]))
        case .forkDraft:
            let documentID = try request.identifier("documentID")
            let revision = try request.revision()
            let destination = try request.optionalText("destination", maxBytes: 4096)
            if let destination, !Self.isRelative(destination) {
                throw G04WorkspaceWireRequest.Failure.invalidField("destination")
            }
            let fork = try await session.forkDraft(documentID, revision: revision, destination: destination,
                                                    discardAfterCopy: try request.flag("discardAfterCopy"))
            return .completed(.object([
                "state": .string("forked"),
                "source": fork.sourceClosedAfterCopy ? .null : Self.headerDocument(fork.source),
                "copy": Self.headerDocument(fork.copy),
                "sourceClosedAfterCopy": .bool(fork.sourceClosedAfterCopy),
            ]))
        }
    }

    static func isRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains("\0")
    }

    // MARK: - Bounded complete-page snapshots (ORIGINAL reader)

    /// Inline when the FULL page fits the carrier budget; otherwise stage the
    /// COMPLETE page JSON (never a shortened result claimed as whole). Reader
    /// saturation and TTL expiry are reported truthfully. The staged echo
    /// mirrors the page's own `complete`/`nextPageToken` facts — a page with
    /// a `nextPageToken` never claims tree completeness.
    private func stageIfOversized(_ document: DesignJSONValue, owner: G04WorkspaceOwner,
                                 path: String?) async -> G04WorkspaceReply {
        guard let data = try? JSONEncoder().encode(document) else {
            return .refused(code: "internalError", reason: "queryEncoding")
        }
        if data.count <= Self.inlineBudgetBytes {
            guard case .object(var pairs) = document else { return .completed(document) }
            pairs["staged"] = .bool(false)
            return .completed(.object(pairs))
        }
        pruneQuerySnapshots()
        let sameOwner = querySnapshots.values.filter { $0.owner == owner }.count
        guard sameOwner < Self.maximumQuerySnapshotsPerConversation else {
            return .refused(code: "transferLimit", reason: "querySnapshotsPerConversation")
        }
        switch queries.stage(data) {
        case .staged(let handle):
            querySnapshots[handle] = QuerySnapshot(owner: owner,
                                                    expires: Date().addingTimeInterval(Self.querySnapshotTTL))
            var echo: [String: DesignJSONValue] = [
                "staged": .bool(true), "handle": .string(handle),
                "byteCount": .integer(Int64(data.count)),
                "sha256": .string(FloeDigest.sha256Hex(data)), "encoding": .string("utf8-json"),
            ]
            if case .object(let pairs) = document {
                for key in ["path", "query", "complete", "nextPageToken", "capped"] where pairs[key] != nil {
                    echo[key] = pairs[key]!
                }
            }
            if let path, echo["path"] == nil { echo["path"] = .string(path) }
            return .completed(.object(echo))
        case .rejected(let reason):
            // Honest saturation: the consumer narrows with pageToken/path.
            return .refused(code: reason == .contentSaturated ? "contentSaturated" : "tooLarge",
                            reason: reason.rawValue)
        }
    }

    private func queryContent(_ request: G04WorkspaceWireRequest, owner: G04WorkspaceOwner) async -> G04WorkspaceReply {
        guard let handle = try? request.text("handle", maxBytes: 256),
              let offset = try? request.integer("offset", maximum: 17 * 1024 * 1024),
              let limit = try? request.integer("limit", maximum: G04WorkspaceDocumentSession.maximumChunkBytes),
              limit > 0 else { return .refused(code: "invalidPayload", reason: "chunkRange") }
        pruneQuerySnapshots()
        guard let snapshot = querySnapshots[handle], snapshot.owner == owner else {
            // Unknown OR foreign-owner handles resolve identically: a
            // workspace query handle never reads another owner's snapshot,
            // and foreign/document handles never enter this reader.
            return .refused(code: "queryHandleUnknown", reason: nil)
        }
        guard snapshot.expires > Date() else {
            queries.release(handle: handle); querySnapshots[handle] = nil
            return .refused(code: "queryHandleExpired", reason: nil)
        }
        switch queries.read(handle: handle, offset: offset, maxBytes: limit) {
        case .slice(let bytes, let nextOffset, let complete):
            return .completed(Self.chunkDocument(bytes, nextOffset: nextOffset, finished: complete))
        case .notFound:
            querySnapshots[handle] = nil
            return .refused(code: "queryHandleUnknown", reason: nil)
        case .invalidOffset:
            return .refused(code: "invalidPayload", reason: "chunkRange")
        }
    }

    private func releaseQuery(_ request: G04WorkspaceWireRequest, owner: G04WorkspaceOwner) -> G04WorkspaceReply {
        guard let handle = try? request.text("handle", maxBytes: 256) else {
            return .refused(code: "invalidPayload", reason: nil)
        }
        guard let snapshot = querySnapshots[handle], snapshot.owner == owner else {
            return .completed(.object(["released": .bool(false)]))
        }
        queries.release(handle: handle)
        querySnapshots[handle] = nil
        return .completed(.object(["released": .bool(true)]))
    }

    private func pruneQuerySnapshots() {
        let now = Date()
        for (handle, snapshot) in querySnapshots where snapshot.expires <= now {
            queries.release(handle: handle)
            querySnapshots[handle] = nil
        }
    }

    // MARK: - workspace.activate (D14)

    /// THIRD closed conversationLifecycle command: carries ONLY the actual
    /// native epoch. Validates the durable ORDINARY conversation under the
    /// original owned-operation lease/fences and calls the ORIGINAL
    /// `SQLiteWorkspaceStore.ensureWorkspace` only when the task is truly
    /// unbound; an existing association is returned untouched (never
    /// re-pointed, never switched to a guessed private/first project).
    /// `conversation.get` stays a pure read. The physical private-task root
    /// materializes lazily through the ORIGINAL authority on first file use.
    public func activate(taskID: UUID?, payload: SettingsDomainV1.JSONValue) async -> G04WorkspaceReply {
        guard let taskID else { return .refused(code: "invalidPayload", reason: "conversationOwnerMissing") }
        let request: G04WorkspaceActivationRequest
        do { request = try G04WorkspaceActivationRequest(payload: payload) }
        catch { return Self.refusal(for: error) }
        guard request.nativeEpoch == epoch else { return .refused(code: "epochMismatch", reason: nil) }
        guard compositionIsLive else { return .refused(code: "retired", reason: nil) }
        let conversation: ConversationRecord
        do {
            guard let record = try await cluster.conversationStore.conversation(id: taskID)
            else { return .refused(code: "notFound", reason: "conversationMissing") }
            guard record.purpose == .ordinary else {
                return .refused(code: "purposeNotOrdinary", reason: nil)
            }
            guard compositionIsLive else { return .refused(code: "retired", reason: nil) }
            conversation = record
        } catch { return Self.refusal(for: error) }
        guard let operation = await runDomain.beginG04WorkspaceOperation(conversationID: taskID,
                                                                          expectedEpoch: epoch) else {
            return .refused(code: "retired", reason: nil)
        }
        let reply: G04WorkspaceReply
        do {
            let store = cluster.workspaceStore
            var workspaceID = try await store.workspaceID(conversationID: taskID)
            var created = false
            if workspaceID == nil {
                try operation.cancellation.throwIfCancelled()
                let ensured = try await store.ensureWorkspace(conversationID: taskID,
                                                               title: conversationTitle(for: conversation))
                workspaceID = ensured.id
                created = true
            }
            guard let bound = workspaceID, let record = try await store.workspace(id: bound) else {
                throw G04DocumentError.ownerChanged
            }
            guard await runDomain.validateG04WorkspaceOperation(operation) else {
                throw G04DocumentError.retired
            }
            reply = .completed(.object([
                "workspaceID": .string(bound.uuidString),
                "name": .string(String(record.name.prefix(120))),
                "kind": .string(record.kind.rawValue),
                "created": .bool(created),
            ]))
        } catch {
            reply = Self.refusal(for: error)
        }
        await runDomain.endG04WorkspaceOperation(operation)
        return reply
    }

    /// Same canonical bounded title projection the ORIGINAL launch ownership
    /// statement applies (trimmed, 80-character prefix; empty → "Chat").
    private func conversationTitle(for conversation: ConversationRecord) -> String {
        let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chat" : String(trimmed.prefix(80))
    }


    // MARK: - Session fencing / retirement

    /// Fence ONE session after a durable-binding refusal. A committed task
    /// deletion owns its workspace cleanup: those drafts are discarded, never
    /// re-driven at a later attach. A rebind preserves dirty drafts durably
    /// BEFORE dropping references; anything not proven durable stays honestly
    /// pending.
    private func fenceSession(taskID: UUID, workspaceID: UUID) async {
        let key = Key(taskID: taskID, workspaceID: workspaceID)
        guard sessions[key] != nil else { return }
        let deleted: Bool
        do { deleted = try await cluster.conversationStore.conversation(id: taskID) == nil }
        catch { deleted = false }
        await retireSession(key, preserve: !deleted)
    }

    private func retireSession(_ key: Key, preserve shouldPreserve: Bool) async {
        guard let session = sessions.removeValue(forKey: key) else { return }
        activity[key] = nil
        guard shouldPreserve else { return }   // deleted task: drafts die with it
        let drafts = await session.beginRetirement()
        for draft in drafts {
            if await preserve(draft) == false {
                pendingRetirement.append(G04CarriedWorkspaceDraft(draft: draft, rootPath: rootPath))
            }
        }
    }

    /// Durably preserve one retained draft as a VERIFIED copy inside the
    /// ORIGINAL native-owned recovery location that
    /// `WorkspaceFileService.editConflict(preserveDraft:true)` already owns
    /// (`Recovered Edits/<name>-<digest>.txt`): content-addressed names make
    /// the write no-overwrite by construction, and a digest-equal existing
    /// copy is an idempotent already-durable answer. The REAL owned operation
    /// lease is attached before the IO and released only after the actual
    /// write + independent read-back digest settle. Returns true ONLY after
    /// that read-back proof.
    ///
    /// Lifecycle honesty (Main review 2026-10-24): at ROOT retirement the
    /// bootstrap is already `.draining`, so registry admission refuses and
    /// this path cannot fabricate a lease. Drafts that cannot be proven
    /// durable there stay honestly PENDING (carried by the process-retained
    /// extension, re-driven at the next live attach) — the lane never claims
    /// process-death proof for RAM-retained bytes, and an explicit successful
    /// conversation deletion always discards them instead of resurrecting
    /// deleted-task content.
    private func preserve(_ draft: G04RetainedDraft) async -> Bool {
        let digest = FloeDigest.sha256Hex(Data(draft.text.utf8))
        let lease: G04WorkspaceAccessLease
        do {
            lease = try await access.acquire(owner: draft.header.owner, intent: .fileMutation,
                                              relativePath: draft.header.relativePath)
        } catch {
            return false
        }
        let verified = Self.preserved(draft, digest: digest, via: lease.service)
        await lease.release()
        return verified
    }

    /// Pre-drain preservation under the retirement GATE lease: the ORIGINAL
    /// private-task resolution + content-addressed durable copy + independent
    /// read-back, with NO new owned-work attach (registry admission is
    /// fenced while draining; the single gate token already owns the drain).
    fileprivate func preserveUnderGate(_ draft: G04RetainedDraft) async -> Bool {
        let digest = FloeDigest.sha256Hex(Data(draft.text.utf8))
        do {
            let service = try await G04LiveWorkspaceAccess.privateTaskService(
                draft.header.owner, cancellation: CancellationToken())
            return Self.preserved(draft, digest: digest, via: service)
        } catch {
            return false
        }
    }

    /// The ORIGINAL durable recovery write used by both paths: the frozen
    /// content-addressed `Recovered Edits/<name>-<digest>.txt` copy via
    /// `editConflict(preserveDraft:true)` (no-overwrite; a digest-equal
    /// existing copy is the idempotent already-durable answer), followed by
    /// an INDEPENDENT metadata read-back digest check.
    static func preserved(_ draft: G04RetainedDraft, digest: String,
                          via service: WorkspaceFileService) -> Bool {
        var recoveryPath: String?
        do {
            recoveryPath = try service.editConflict(path: draft.header.relativePath, base: nil,
                                                      draft: draft.text, preserveDraft: true).recoveryPath
        } catch let recovery as WorkspaceDraftRecoveryError {
            // The durable copy already landed; only the external original
            // review failed (missing/unreadable). The copy remains the proof.
            recoveryPath = recovery.recoveryPath
        } catch {
            return false
        }
        guard let path = recoveryPath else { return false }
        return (try? service.metadata(path).sha256) == digest
    }

    /// Pre-drain retirement-preservation pass driven by
    /// `G02RuntimeComposition.runRetirementPreservationIO` BEFORE the first
    /// `waitForLifecycleDrain` pass, under the ONE attached
    /// `G04WorkspaceRetirementGate` lease. Fences admissions, snapshots every
    /// session under the actor's serial isolation, and settles each dirty
    /// draft into a VERIFIED durable copy through the ORIGINAL private-task
    /// authority (direct write; the gate token — not a fabricated per-draft
    /// lease — owns the drain while owned admission is fenced). Returns true
    /// ONLY when nothing remains unproven so the gate token may be
    /// exact-released; false leaves the token attached, the EXISTING bounded
    /// drain then times out into `retirementPending = .shutdownTimeout` /
    /// `failedDrainPending`, ownership (database + root) is retained, and the
    /// existing retirement watch re-runs this SAME control which re-invokes
    /// this pass. Explicit successful conversation deletion DISCARDS its
    /// carry — deleted bytes are never resurrected.
    public func retirementPreservationPass() async -> Bool {
        if !retired {
            retired = true
            for key in Array(sessions.keys) {
                guard let session = sessions.removeValue(forKey: key) else { continue }
                activity[key] = nil
                let drafts = await session.beginRetirement()
                for draft in drafts {
                    if await preserveUnderGate(draft) == false {
                        pendingRetirement.append(G04CarriedWorkspaceDraft(draft: draft, rootPath: rootPath))
                    }
                }
            }
            for handle in querySnapshots.keys { queries.release(handle: handle) }
            querySnapshots.removeAll()
            queries.retireAll()
            await source.retire()
        }
        var remaining: [G04CarriedWorkspaceDraft] = []
        for carried in pendingRetirement {
            guard carried.rootPath == rootPath else { remaining.append(carried); continue }
            let exists: Bool
            do {
                exists = try await cluster.conversationStore
                    .conversation(id: carried.draft.header.owner.taskID) != nil
            } catch { remaining.append(carried); continue }
            guard exists else { continue }   // committed deletion: discard
            let header = carried.draft.header
            let liveOwner = G04WorkspaceOwner(epoch: epoch, taskID: header.owner.taskID,
                                              workspaceID: header.owner.workspaceID)
            let remapped = G04DocumentHeader(owner: liveOwner, documentID: header.documentID,
                                              relativePath: header.relativePath, revision: header.revision,
                                              utf8Bytes: header.utf8Bytes, selection: header.selection,
                                              dirty: header.dirty, canUndo: header.canUndo,
                                              canRedo: header.canRedo)
            let draft = G04RetainedDraft(header: remapped, text: carried.draft.text,
                                          baselineSHA256: carried.draft.baselineSHA256,
                                          baselineMtime: carried.draft.baselineMtime)
            if await preserveUnderGate(draft) == false {
                remaining.append(G04CarriedWorkspaceDraft(draft: draft, rootPath: rootPath))
            }
        }
        pendingRetirement = remaining
        return pendingRetirement.isEmpty
    }

    /// Composition-time retirement fence (post-drain `beginRetirement`, and
    /// the failed-bootstrap `retireFailed` path that reaches the composition
    /// without the pre-drain gate). Runs the SAME synchronous preservation
    /// pass, so BOTH shutdown orderings settle verified durable copies
    /// before the generation is dropped. With the pre-drain gate wired this
    /// normally finds everything already settled; a still-unproven draft
    /// keeps the facade (and its referenced draft) alive until the ORIGINAL
    /// lifecycle's failedDrainPending + watch-retry finishes it — a newer
    /// generation cannot bind while this one owns the root, so there is no
    /// cross-generation RAM carry (that claim is exactly what Main rejected)
    /// and nothing is silently dropped or falsely declared durable.
    @discardableResult
    public func beginRetirement() async -> Bool {
        // Stop advertising the frozen fourteen runners for THIS generation
        // first, then retire the Git/Actions service and recovery RAM.
        gitToolsHandle?.retire()
        await git.retire()
        // Recovery retirement drops only INCOMPLETE upload RAM. Committed
        // recovery files live in the ORIGINAL durable Recovered Drafts tree
        // and are never deleted here; a rejected UI tail stays held by the
        // host preflight until its complete disk read-back proof.
        await projectionRecovery.retire()
        return await retirementPreservationPass()
    }

    // MARK: - Typed refusals

    static func refusal(for error: any Error) -> G04WorkspaceReply {
        if let typed = error as? G04DocumentError { return .refused(code: wireCode(typed), reason: nil) }
        if let git = error as? G04WorkspaceGit.Failure {
            switch git {
            case .invalidArguments: return .refused(code: "invalidPayload", reason: "gitArguments")
            case .needsAccount: return .refused(code: "gitNeedsAccount", reason: nil)
            case .pathRefused: return .refused(code: "notAdmitted", reason: "gitMetadataOutsideWorkspace")
            case .unsupportedAction: return .refused(code: "gitActionUnavailable", reason: nil)
            case .jobsUnavailable: return .refused(code: "gitActionsJobsUnavailable", reason: nil)
            }
        }
        if let credential = error as? G04GitCredentialLease.Failure {
            return .refused(code: "gitCredentialUnavailable", reason: String(describing: credential))
        }
        // Durable Actions engine refusals: typed codes; the reason carries
        // ONLY redacted, bounded diagnostic text (never tokens, headers or
        // raw response bodies — the FloeGit client already redacts against
        // the bearer token before these errors exist).
        if let actions = error as? G04GitActionsDomain.Failure {
            switch actions {
            case .invalidArguments: return .refused(code: "invalidPayload", reason: "gitActionsArguments")
            case .reviewStale: return .refused(code: "gitActionsReviewStale", reason: nil)
            case .recordMissing: return .refused(code: "gitActionsRecordMissing", reason: nil)
            case .workflowNotRegistered: return .refused(code: "gitActionsWorkflowNotRegistered", reason: nil)
            case .artifactNotReady: return .refused(code: "gitActionsArtifactNotReady", reason: nil)
            case .retired: return .refused(code: "retired", reason: nil)
            }
        }
        if let remote = error as? GitHubActionsError {
            return .refused(code: "gitActionsRemote",
                            reason: String(SecretRedactor.redact(remote.localizedDescription).prefix(256)))
        }
        if let engine = error as? GitHubActionsEngineError {
            return .refused(code: "gitActionsRemote",
                            reason: String(SecretRedactor.redact(engine.localizedDescription).prefix(256)))
        }
        if let streaming = error as? GitHubActionsStreamingError {
            return .refused(code: "gitActionsRemote",
                            reason: String(SecretRedactor.redact(streaming.localizedDescription).prefix(256)))
        }
        if let tool = error as? WorkspaceToolError { return .refused(code: tool.code, reason: nil) }
        if let failure = error as? G04WorkspaceWireRequest.Failure {
            return .refused(code: wireCode(failure), reason: nil)
        }
        if let activation = error as? G04WorkspaceActivationRequest.Failure {
            switch activation {
            case .invalidPayload: return .refused(code: "invalidPayload", reason: nil)
            case .invalidField: return .refused(code: "epochMismatch", reason: "nativeEpochMalformed")
            }
        }
        if let source = error as? AndroidWorkspaceSourceError {
            return .refused(code: wireCode(source), reason: nil)
        }
        if error is CancellationError { return .refused(code: "cancelled", reason: nil) }
        if let floe = error as? FloeError {
            switch floe {
            case .cancelled: return .refused(code: "cancelled", reason: nil)
            default: return .refused(code: "persistenceUnavailable", reason: nil)
            }
        }
        return .refused(code: "internalError", reason: nil)
    }

    static func isOwnershipRefusal(_ error: any Error) -> Bool {
        guard let typed = error as? G04DocumentError else { return false }
        return typed == .ownerChanged || typed == .retired
    }

    static func wireCode(_ error: G04DocumentError) -> String {
        switch error {
        case .retired: "retired"
        case .ownerChanged: "ownerChanged"
        case .missingDocument: "missingDocument"
        case .staleRevision: "staleRevision"
        case .invalidRange: "invalidRange"
        case .invalidTransfer: "invalidTransfer"
        case .transferLimit: "transferLimit"
        case .invalidUTF8: "invalidUTF8"
        case .dirtyDocument: "dirtyDocument"
        case .historyUnavailable: "historyUnavailable"
        case .bufferLimit: "bufferLimit"
        case .workspaceBusy: "workspaceBusy"
        }
    }

    static func wireCode(_ failure: G04WorkspaceWireRequest.Failure) -> String {
        switch failure {
        case .invalidPayload: "invalidPayload"
        case .unknownOperation: "unknownOperation"
        case .wrongFamily: "wrongFamily"
        case .invalidField: "invalidPayload"
        }
    }

    static func wireCode(_ failure: AndroidWorkspaceSourceError) -> String {
        switch failure {
        case .invalidMetadata: "invalidPayload"
        case .missingSource: "notFound"
        case .staleRevision: "staleRevision"
        case .receiptMismatch: "conflict"
        case .invalidTransition: "invalidTransfer"
        }
    }

    // MARK: - Reply document encoders (exact frozen shapes)

    static func headerDocument(_ header: G04DocumentHeader) -> DesignJSONValue {
        .object([
            "documentID": .string(header.documentID.uuidString),
            "relativePath": .string(header.relativePath),
            "revision": .string(header.revision),
            "utf8Bytes": .integer(Int64(header.utf8Bytes)),
            "selection": .object(["location": .integer(Int64(header.selection.location)),
                                   "length": .integer(Int64(header.selection.length))]),
            "dirty": .bool(header.dirty), "canUndo": .bool(header.canUndo), "canRedo": .bool(header.canRedo),
        ])
    }

    static func chunkDocument(_ bytes: Data, nextOffset: Int, finished: Bool) -> DesignJSONValue {
        .object([
            "bytes": .string(bytes.base64EncodedString()),
            "nextOffset": .integer(Int64(nextOffset)),
            "finished": .bool(finished),
        ])
    }

    static func fileNode(_ node: FileNode) -> DesignJSONValue {
        .object(["name": .string(node.name), "relativePath": .string(node.relativePath),
                  "isDirectory": .bool(node.isDirectory), "size": .integer(node.size)])
    }

    static func directoryDocument(_ page: DirectoryPage, path: String) -> DesignJSONValue {
        .object([
            "path": .string(path), "complete": .bool(page.nextPageToken == nil),
            "entries": .array(page.entries.map(fileNode)),
            "nextPageToken": page.nextPageToken.map { DesignJSONValue.string($0) } ?? .null,
        ])
    }

    static func searchHit(_ hit: SearchHit) -> DesignJSONValue {
        .object(["relativePath": .string(hit.relativePath), "lineNumber": .integer(Int64(hit.lineNumber)),
                  "context": .string(hit.context)])
    }

    static func metadataDocument(_ value: WorkspaceFileMetadata) -> DesignJSONValue {
        .object([
            "relativePath": .string(value.relativePath), "size": .integer(value.size),
            "mtime": .number(value.mtime), "uti": .string(value.uti), "sha256": .string(value.sha256),
            "isSymlink": .bool(value.isSymlink), "isDirectory": .bool(value.isDirectory),
        ])
    }

    static func findDocument(_ found: G04DocumentFind) -> DesignJSONValue {
        .object([
            "revision": .string(found.revision),
            "ranges": .array(found.ranges.map {
                DesignJSONValue.object(["location": .integer(Int64($0.location)),
                                          "length": .integer(Int64($0.length))])
            }),
            "selection": found.selection.map {
                DesignJSONValue.object(["location": .integer(Int64($0.location)),
                                          "length": .integer(Int64($0.length))])
            } ?? .null,
            "truncated": .bool(found.truncated),
        ])
    }
}

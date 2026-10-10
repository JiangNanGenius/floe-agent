// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeWorkspace
import FloeWorkbench
import FloeCore

/// Exact staged-document identity for a Canvas CAD drawing under edit. When
/// a review capture carries this, the Drawing Assistant binds its durable
/// conversation and its proposals to THIS staged draft (canvas draft root +
/// staged path, owned by the canvas project) — never to the global workspace
/// or whichever task happens to be selected. The canvas node itself only
/// changes when the user explicitly Finishes; assistant proposals therefore
/// remain draft edits on the staged copy until then.
struct CanvasStagedReviewDocument: Equatable {
    /// Canvas project id: namespace of the durable assistant-conversation
    /// binding and the CAD document owner id.
    var canvasID: UUID
    /// App-owned canvas draft root (becomes `CadDocumentAccess.workspacePath`).
    var draftRootPath: String
    /// Staged editable copy path, relative to the draft root (the document
    /// id the CAD center resolves).
    var stagedRelativePath: String
}

struct EngineeringReviewCapture: Identifiable {
    let id = UUID()
    let context: String
    let image: Data
    /// Workspace-relative drawing path and root, captured at review time so
    /// the Drawing Assistant can bind proposals to the exact document.
    var documentID: String? = nil
    var workspaceRoot: URL? = nil
    /// Set for Canvas CAD staged drafts; takes precedence over the workspace
    /// identity above for assistant binding and ownership.
    var canvasStagedDocument: CanvasStagedReviewDocument? = nil
}

/// Durable binding between one canonical drawing document (workspace id +
/// relative path) and the assistant conversation that discusses it. The
/// Drawing Assistant therefore stays bound to the same chat across sheet
/// open/close and app restarts, instead of whichever conversation happens to
/// be selected in the router. Writes are serialized so concurrent binds can
/// never persist out of order and lose the newest mapping; a persistence
/// failure is reported, never silently dropped to a non-durable location.
final class DrawingAssistantConversationStore: @unchecked Sendable {
    struct PersistenceFailure: Error, LocalizedError {
        var errorDescription: String? {
            FloeL10n.l("workspace.engineering_file_preview.cannot_persist_conversation_binding")
        }
    }

    static let shared = DrawingAssistantConversationStore()

    private let lock = NSLock()
    private var bindings: [String: String] = [:]
    private var loaded = false
    private let fileURL: URL
    /// Serializes snapshot writes so the newest mapping always wins.
    private let writeQueue = DispatchQueue(label: "floe.drawing-assistant.store")

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("FloeAgent/DrawingAssistant", isDirectory: true)
        if let root {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("conversations.json")
        } else {
            // No silent temporaryDirectory fallback: without an Application
            // Support location there is nothing durable to write to.
            fileURL = URL(fileURLWithPath: "/dev/null")
        }
    }

    var isDurable: Bool { fileURL.path != "/dev/null" }

    private func key(workspaceID: UUID, relativePath: String) -> String {
        "\(workspaceID.uuidString)|\(relativePath)"
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard isDurable, let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        bindings = object
    }

    func conversationID(workspaceID: UUID, relativePath: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard let raw = bindings[key(workspaceID: workspaceID, relativePath: relativePath)] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Reverse lookup for the runtime tool context: the staged document
    /// whose assistant conversation is `conversationID`. Deterministic when
    /// several bindings exist (sorted keys). This is the ONLY authority for
    /// seeding `ToolContext.canvasStagedDocument`; model output never is.
    func stagedDocument(conversationID: UUID) -> CanvasStagedReviewDocument? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        let target = conversationID.uuidString
        for key in bindings.keys.sorted() where bindings[key] == target {
            guard let separator = key.firstIndex(of: "|") else { continue }
            guard let canvasID = UUID(uuidString: String(key[..<separator])) else { continue }
            let stagedRelativePath = String(key[key.index(after: separator)...])
            guard !stagedRelativePath.isEmpty else { continue }
            return CanvasStagedReviewDocument(canvasID: canvasID,
                                              draftRootPath: "",
                                              stagedRelativePath: stagedRelativePath)
        }
        return nil
    }

    /// Persists the newest mapping. The mutation AND the write are serialized
    /// together (writeQueue, re-entrant via lock ordering), so two rapid binds
    /// keep the latest value on disk and a write failure is thrown, never
    /// silently swallowed.
    func bind(workspaceID: UUID, relativePath: String, conversationID: UUID) throws {
        guard isDurable else { throw PersistenceFailure() }
        let url = fileURL
        try writeQueue.sync {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            bindings[key(workspaceID: workspaceID, relativePath: relativePath)] = conversationID.uuidString
            let snapshot = bindings
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Persists Drawing Assistant proposal decisions durably (append-only)
/// so an enqueue failure or a crash right after apply/discard can never
/// lose the user's decision; delivery is retried until acknowledged.
///
/// A decision is written in two phases. `intent` is recorded BEFORE the
/// proposal is sent to the engine, so a crash between commit and notify leaves
/// a recoverable record. `committed` carries the receipt (revision + sha256)
/// and is written as soon as the center returns it. Recovery can therefore
/// rebuild the delivered event from the committed receipt
/// (`CadAppliedReceiptJournal`) instead of claiming delivery from a window that
/// was never covered.
final class DrawingAssistantDecisionStore: @unchecked Sendable {
    enum Phase: String, Codable, Sendable {
        case intent
        case committed
    }

    struct Decision: Codable, Sendable {
        var id: String
        var conversationID: UUID
        var proposalID: UUID
        var decision: String
        var revision: Int64?
        var sha256: String?
        var recordedAt: Date
        var delivered: Bool
        var phase: Phase

        // Persisted files from earlier builds have no `phase`; an old record
        // is a committed decision (its receipt fields were written with it).
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            conversationID = try container.decode(UUID.self, forKey: .conversationID)
            proposalID = try container.decode(UUID.self, forKey: .proposalID)
            decision = try container.decode(String.self, forKey: .decision)
            revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
            sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
            recordedAt = try container.decode(Date.self, forKey: .recordedAt)
            delivered = try container.decode(Bool.self, forKey: .delivered)
            phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .committed
        }

        init(id: String, conversationID: UUID, proposalID: UUID, decision: String,
             revision: Int64?, sha256: String?, recordedAt: Date, delivered: Bool,
             phase: Phase) {
            self.id = id
            self.conversationID = conversationID
            self.proposalID = proposalID
            self.decision = decision
            self.revision = revision
            self.sha256 = sha256
            self.recordedAt = recordedAt
            self.delivered = delivered
            self.phase = phase
        }
    }

    /// Write/persistence failure is shared by the local stores; callers
    /// surface it instead of assuming durability.
    struct StoreFailure: Error, LocalizedError {
        var errorDescription: String? { FloeL10n.l("workspace.engineering_file_preview.cannot_persist_records") }
    }

    static let shared = DrawingAssistantDecisionStore()
        private let lock = NSLock()
        private let fileURL: URL
        private let writeQueue = DispatchQueue(label: "floe.drawing-assistant.decisions")
        private var loaded = false
        private var decisions: [Decision] = []

        private init() {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("FloeAgent/DrawingAssistant", isDirectory: true)
            if let root {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                fileURL = root.appendingPathComponent("decisions.jsonl")
            } else {
                fileURL = URL(fileURLWithPath: "/dev/null")
            }
        }

        var isDurable: Bool { fileURL.path != "/dev/null" }

        private func loadLocked() {
            guard !loaded else { return }
            loaded = true
            guard isDurable, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            decisions = text.split(separator: "\n").compactMap { line in
                try? decoder.decode(Decision.self, from: Data(line.utf8))
            }
        }

        /// Records the decision BEFORE any delivery attempt. Mutation and
        /// write are serialized together; a write failure throws so callers
        /// never claim durability that did not happen. `phase` defaults to
        /// `committed` for the discard/reject path, which has no mutation
        /// window; an apply records `.intent` first and upgrades the SAME
        /// record to `.committed` with the receipt after the center returns it.
        func record(conversationID: UUID, proposalID: UUID, decision: String,
                    revision: Int64?, sha256: String?, phase: Phase = .committed) throws -> Decision {
            guard isDurable else { throw StoreFailure() }
            let entry = Decision(
                id: "\(conversationID.uuidString)|\(proposalID.uuidString)|\(decision)",
                conversationID: conversationID, proposalID: proposalID, decision: decision,
                revision: revision, sha256: sha256, recordedAt: Date(), delivered: false,
                phase: phase)
            let url = fileURL
            try writeQueue.sync {
                lock.lock(); defer { lock.unlock() }
                loadLocked()
                decisions.removeAll { $0.id == entry.id }
                decisions.append(entry)
                try Self.persist(decisions, to: url)
            }
            return entry
        }

        /// Upgrades an intent record to its committed receipt (same id, so the
        /// write replaces the intent line) and returns the durable record.
        /// Throws on a persistence failure so the caller can report that the
        /// receipt was not durably recorded.
        @discardableResult
        func markCommitted(id: String, revision: Int64?, sha256: String?) throws -> Decision? {
            guard isDurable else { throw StoreFailure() }
            let url = fileURL
            return try writeQueue.sync {
                lock.lock(); defer { lock.unlock() }
                loadLocked()
                guard let index = decisions.firstIndex(where: { $0.id == id }) else { return nil }
                decisions[index].phase = .committed
                decisions[index].revision = revision ?? decisions[index].revision
                decisions[index].sha256 = sha256 ?? decisions[index].sha256
                decisions[index].recordedAt = Date()
                let updated = decisions[index]
                try Self.persist(decisions, to: url)
                return updated
            }
        }

        /// Records the receipt recovered from the committed journal for an
        /// intent whose `.committed` upgrade never reached disk (crash between
        /// commit and notify). No-op when the record is unknown.
        @discardableResult
        func recoverCommit(id: String, receiptRevision: Int64?, sha256: String?) throws -> Decision? {
            guard isDurable else { throw StoreFailure() }
            let url = fileURL
            return try writeQueue.sync {
                lock.lock(); defer { lock.unlock() }
                loadLocked()
                guard let index = decisions.firstIndex(where: { $0.id == id }) else { return nil }
                if decisions[index].phase == .intent {
                    decisions[index].phase = .committed
                    decisions[index].revision = receiptRevision ?? decisions[index].revision
                    decisions[index].sha256 = sha256 ?? decisions[index].sha256
                }
                let updated = decisions[index]
                try Self.persist(decisions, to: url)
                return updated
            }
        }

        private static func persist(_ decisions: [Decision], to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var lines = [String]()
            for decision in decisions {
                let data = try encoder.encode(decision)
                lines.append(String(decoding: data, as: UTF8.self))
            }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        func pendingDeliveries() -> [Decision] {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            return decisions.filter { !$0.delivered }
        }

        func markDelivered(id: String) throws {
            guard isDurable else { throw StoreFailure() }
            let url = fileURL
            try writeQueue.sync {
                lock.lock(); defer { lock.unlock() }
                loadLocked()
                for index in decisions.indices where decisions[index].id == id {
                    decisions[index].delivered = true
                }
                try Self.persist(decisions, to: url)
            }
        }
    }

/// Write-ahead record of a CAD proposal apply, keyed by proposal id. The
/// decision intent is persisted before the engine mutates; this journal is
/// prepared with the EXPECTED resulting SHA *before* the file commit and
/// completed with the receipt after it. A crash between the disk write and the
/// decision upgrade is reconciled by comparing the current file SHA with the
/// prepared SHA: only the exact expected bytes reconstruct an "applied"
/// receipt. A missing completion is therefore recoverable, never a silently
/// lost event. Writes are atomic; a failed prepare refuses the commit.
final class CadAppliedReceiptJournal: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        var proposalID: UUID
        var expectedSHA256: String
        var pendingReceipt: CadDocumentReceipt
        var completedReceipt: CadDocumentReceipt?
        var preparedAt: Date
    }

    static let shared = CadAppliedReceiptJournal()

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "floe.drawing-assistant.receipts")
    private let fileURL: URL
    private var loaded = false
    private var entries: [String: Entry] = [:]
    private var testWriteFailure = false
    private let maximumEntries = 200

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("FloeAgent/DrawingAssistant", isDirectory: true)
        if let root {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("applied-receipts.json")
        } else {
            fileURL = URL(fileURLWithPath: "/dev/null")
        }
    }

    var isDurable: Bool { fileURL.path != "/dev/null" }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard isDurable, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    /// Records the expected result BEFORE the file commit. Throws when the
    /// durable write fails: the caller must then refuse to commit, because an
    /// interrupted commit would otherwise be unrecoverable. The in-memory map
    /// is only swapped after the write succeeds, so a failed write never
    /// pretends the record was persisted.
    func prepare(proposalID: UUID, expectedSHA256: String, pendingReceipt: CadDocumentReceipt) throws {
        let url = fileURL
        try writeQueue.sync {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            var staged = entries
            staged[proposalID.uuidString] = Entry(proposalID: proposalID,
                                                  expectedSHA256: expectedSHA256.lowercased(),
                                                  pendingReceipt: pendingReceipt,
                                                  completedReceipt: nil,
                                                  preparedAt: Date())
            if staged.count > maximumEntries {
                let ordered = staged.sorted { $0.value.preparedAt > $1.value.preparedAt }
                staged = Dictionary(uniqueKeysWithValues: ordered.prefix(maximumEntries).map { ($0.key, $0.value) })
            }
            guard isDurable else { throw StoreFailure() }
            if testWriteFailure { throw StoreFailure() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(staged)
            try data.write(to: url, options: .atomic)
            entries = staged
        }
    }

    /// Attaches the committed receipt. A failure leaves the prepared entry,
    /// which reconciliation can still validate against the file SHA.
    func complete(proposalID: UUID, receipt: CadDocumentReceipt) throws {
        let url = fileURL
        try writeQueue.sync {
            lock.lock(); defer { lock.unlock() }
            loadLocked()
            guard isDurable else { throw StoreFailure() }
            guard var entry = entries[proposalID.uuidString] else { return }
            entry.completedReceipt = receipt
            var staged = entries
            staged[proposalID.uuidString] = entry
            if testWriteFailure { throw StoreFailure() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(staged)
            try data.write(to: url, options: .atomic)
            entries = staged
        }
    }

    /// Test-only failure seam for the durable write.
    func setTestWriteFailure(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        testWriteFailure = value
    }

    func entry(proposalID: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        return entries[proposalID.uuidString]
    }

    struct StoreFailure: Error, LocalizedError {
        var errorDescription: String? { FloeL10n.l("workspace.engineering_file_preview.cannot_persist_receipts") }
    }
}

/// Central registry of live (on-screen) CAD editor drafts, keyed by canonical
/// root + relative path. The visible editor registers its session while the
/// page is mounted; the mutation authority (`CadDocumentCenter`) consults this
/// before ANY apply/save so a model-confirmed write can never commit over an
/// unsaved manual draft held in the open viewer — for UI and tool callers
/// alike.
///
/// A mutation takes a *lease*: it refuses to start while the viewer is dirty,
/// suspends viewer interaction for the duration of the engine transaction, and
/// re-validates the draft revision immediately before the file commit. An edit
/// that landed while the engine transaction was awaiting (possible even with
/// interaction off, e.g. a queued JS event) therefore aborts the commit and
/// the engine draft is rolled back — the user's draft is preserved instead of
/// being overwritten or silently merged. The reference is weak: a closed or
/// released session cannot block later edits.
@MainActor
final class CadLiveDraftRegistry {
    static let shared = CadLiveDraftRegistry()

    enum LiveDraftError: LocalizedError {
        case dirty

        var errorDescription: String? {
            "The open drawing has unsaved manual edits, so the confirmed change was not applied; "
                + "the draft is preserved. Save or discard those edits first, then retry."
        }
    }

    enum LeaseValidation: Equatable {
        case clean
        case dirty
        case baselineChanged
        case sessionGone
    }

    struct Lease {
        let key: String
        let baselineSHA: String?
    }

    private struct Entry {
        weak var session: EngineeringWebSession?
        /// Document-level suspension: set by a lease and kept while a viewer is
        /// replaced, so a session that registers mid-transaction starts
        /// suspended and cannot slip a dirty draft past the commit boundary.
        var suspended: Bool
    }
    private var entries: [String: Entry] = [:]

    static func key(rootPath: String?, relativePath: String) -> String {
        let root = rootPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
        return "\(root)|\(relativePath)"
    }

    func register(key: String, session: EngineeringWebSession) {
        let suspended = entries[key]?.suspended ?? false
        entries[key] = Entry(session: session, suspended: suspended)
        if suspended { session.web?.isUserInteractionEnabled = false }
    }

    func unregister(key: String, session: EngineeringWebSession) {
        guard entries[key]?.session === session else { return }
        // Keep the document-level suspension flag: a replacement viewer must
        // stay suspended until the lease ends.
        entries[key] = Entry(session: nil, suspended: entries[key]?.suspended ?? false)
    }

    /// Whether a live viewer for this document currently holds unsaved manual
    /// edits. `.none` means no live viewer is registered (no draft to protect).
    func liveDraftDirty(rootPath: String?, relativePath: String) -> Bool? {
        guard let session = entries[Self.key(rootPath: rootPath, relativePath: relativePath)]?.session else {
            return nil
        }
        return session.isCADDirty
    }

    /// Takes a mutation lease for the document, or throws `.dirty` when the
    /// registered viewer already has unsaved edits. The suspension is
    /// document-level: it is recorded even when no viewer is open yet, so a
    /// viewer that registers while the transaction runs starts suspended.
    func beginLease(rootPath: String?, relativePath: String) throws -> Lease {
        let key = Self.key(rootPath: rootPath, relativePath: relativePath)
        var entry = entries[key] ?? Entry(session: nil, suspended: false)
        if let session = entry.session, session.isCADDirty { throw LiveDraftError.dirty }
        entry.suspended = true
        entries[key] = entry
        entry.session?.web?.isUserInteractionEnabled = false
        return Lease(key: key, baselineSHA: entry.session?.coordinator?.baselineSHA)
    }

    /// Re-validates the CURRENT viewer at the final commit boundary (a viewer
    /// replaced during the transaction is checked too, not bypassed).
    func validateLease(_ lease: Lease) -> LeaseValidation {
        guard let entry = entries[lease.key], entry.suspended else { return .sessionGone }
        guard let session = entry.session else { return .sessionGone }
        if session.isCADDirty { return .dirty }
        if session.coordinator?.baselineSHA != lease.baselineSHA { return .baselineChanged }
        return .clean
    }

    /// Ends the document lease and restores interaction on whichever session
    /// currently owns the document.
    func endLease(_ lease: Lease?) {
        guard let lease, var entry = entries[lease.key], entry.suspended else { return }
        entry.suspended = false
        entries[lease.key] = entry
        entry.session?.web?.isUserInteractionEnabled = true
    }
}

    /// Owns the single WKWebView used by an engineering preview. The same web
    /// view is re-parented between the embedded preview and the fullscreen
    /// presentation, so an unsaved CAD editing session (JS state, undo history,
    /// camera, ink readiness) survives the transition instead of reloading from
    /// disk. The reload generation lives HERE (not in any view instance), so two
    /// different EngineeringFilePreview instances attaching the same session can
    /// never tear each other down; only an explicit `retry()` reloads the page.
    ///
    /// Presentation ownership is arbitrated here too. During an embedded ↔
    /// fullscreen transition UIKit keeps BOTH `EngineeringContainerView`s in the
    /// window for a moment. If each container adopted the web view from its
    /// `layoutSubviews`, they would ping-pong (`removeFromSuperview` +
    /// `addSubview`) and each move invalidates the other's layout, spinning the
    /// main thread forever. Exactly one container may host the web view:
    /// ownership is claimed only when a container explicitly enters a window
    /// (the newest appearance wins) and is released when the owning container
    /// leaves it. `layoutSubviews` may position the web view only while this
    /// session still names that container as the host; it never steals it back.
    @MainActor
    final class EngineeringWebSession: ObservableObject {
    /// Identity of the currently loaded page; nil while no page is loaded.
    private(set) var generation: UUID?
    /// Full identity of the document the current page was loaded from
    /// (name + content digest, never name alone).
    private(set) var loadedDocumentKey: String?
    /// Edit capability of the loaded page (from the first attach).
    private(set) var loadedCanEdit = false
    /// Set by `retry()`: the next attach rebuilds the web view.
    private var pendingRebuild = false
    /// Canonical key this session registered with `CadLiveDraftRegistry`, so a
    /// teardown/document switch removes exactly its own entry.
    private var registeredDraftKey: String?
    private(set) var web: WKWebView?
    private(set) var coordinator: EngineeringWebView.Coordinator?
    private(set) var server: LocalPreviewServer?
    private(set) var startup: Task<Void, Never>?
    private(set) var watchdog: Task<Void, Never>?
    /// The one container currently allowed to host the shared web view. Weak,
    /// so a host that is deallocated without leaving its window cannot block a
    /// later host from claiming.
    private(set) weak var presentationHost: EngineeringWebView.EngineeringContainerView?
    /// Every live container, so that when the current host leaves its window
    /// the session can PROMOTE the remaining on-screen container immediately:
    /// a dismissal must never leave the web view parented to a container that
    /// is leaving (a blank editor) just because no layout pass happened to
    /// run on the survivor.
    private final class WeakContainerBox {
        weak var view: EngineeringWebView.EngineeringContainerView?
        init(_ view: EngineeringWebView.EngineeringContainerView?) { self.view = view }
    }
    private var liveContainers: [WeakContainerBox] = []

    /// Claims presentation ownership for `host`. Only a container that is
    /// entering (or already in) a window may claim; a live newer appearance
    /// (the fullscreen cover mounting or the embedded view returning on
    /// dismissal) takes over from the older host, which then stops touching
    /// the web view. `window` is the window being entered: during
    /// `willMove(toWindow:)` the view's own `.window` still reports the OLD
    /// window, so the caller must pass the incoming one. Call only from view
    /// lifecycle events, never from a layout pass that may race another
    /// container.
    @discardableResult
    func claimPresentationHost(_ host: EngineeringWebView.EngineeringContainerView,
                               in window: UIWindow?) -> Bool {
        guard window != nil else { return false }
        registerLiveContainer(host)
        presentationHost = host
        return true
    }

    private func registerLiveContainer(_ container: EngineeringWebView.EngineeringContainerView) {
        liveContainers.removeAll { $0.view == nil || $0.view === container }
        liveContainers.append(WeakContainerBox(container))
    }

    /// A container is leaving its window or being dismantled. It is removed
    /// from the candidate registry FIRST so no promotion path (including a
    /// stale release while its `window` still reports the old one) can
    /// reselect it. If it owned the host, the newest remaining on-screen
    /// container is promoted and asked to lay out immediately — this is what
    /// makes fullscreen dismissal restore the embedded editor even when the
    /// survivor received no layout pass of its own (the reported
    /// blank-return regression). A non-owner leaving never disturbs the
    /// newer active host.
    func releasePresentationHost(_ host: EngineeringWebView.EngineeringContainerView) {
        liveContainers.removeAll { $0.view === host || $0.view == nil }
        guard presentationHost === host else { return }
        presentationHost = nil
        promoteAvailableHost(excluding: host)
    }

    private func promoteAvailableHost(excluding releasedHost: EngineeringWebView.EngineeringContainerView) {
        for box in liveContainers.reversed() {
            guard let candidate = box.view,
                  candidate !== releasedHost,
                  candidate.window != nil else { continue }
            presentationHost = candidate
            candidate.setNeedsLayout()
            return
        }
    }

    /// Explicit user retry: tear down now so the next attach reloads.
    func retry() {
        pendingRebuild = true
        tearDown()
    }

    /// Stable full identity for a package: name plus a digest of the first
    /// file's bytes, so two different documents with the same filename can
    /// never share a session.
    /// Canonical identity for a document shown by a preview: workspace root
    /// plus relative path. Stable across saves and unique across roots.
    static func documentKey(rootPath: String?, relativePath: String) -> String {
        if let rootPath, !rootPath.isEmpty { return "\(rootPath)|\(relativePath)" }
        return relativePath
    }

    func attach(package: EngineeringPreviewPackage,
                identity: String? = nil,
                error: Binding<String?>,
                onReview: ((EngineeringReviewCapture) -> Void)?,
                onSave: ((Data, String) async throws -> String)?,
                onDirty: ((Bool) -> Void)?,
                dark: Bool, locale: String) -> WKWebView {
        // Canonical document identity (workspace root + relative path) when
        // the caller supplies one: saving changes bytes but never identity,
        // and two same-name copies in different roots stay separate.
        let key = identity ?? package.name
        let canEdit = onSave != nil
        if let web, coordinator != nil, generation != nil, !pendingRebuild,
           key == loadedDocumentKey {
            coordinator?.update(callbacks: error, onReview: onReview, onSave: onSave, onDirty: onDirty)
            // Capability upgrade (embedded read-only → fullscreen editable)
            // must NOT reload the page: enable editing inside the live page.
            // The page may still be parsing when the upgrade arrives, so the
            // JavaScript side waits (bounded) for the CAD engine and reports
            // whether the edit surface was actually installed; a false result
            // keeps the upgrade pending for the next attachment instead of
            // silently losing the edit entry.
            if canEdit, !loadedCanEdit {
                loadedCanEdit = true
                // The page evaluates viewer.js asynchronously and may still be
                // parsing when the upgrade arrives, so retry (bounded) until
                // the edit surface confirms installation; a failure keeps the
                // upgrade pending for the next attachment.
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web else { return }
                    if await self.installEditSurface(on: web) == false {
                        self.loadedCanEdit = false
                    }
                }
            }
            return web
        }
        tearDown()
        pendingRebuild = false
        generation = UUID()
        loadedDocumentKey = key
        loadedCanEdit = canEdit
        registerLiveDraft(key: key)
        let coordinator = EngineeringWebView.Coordinator(package: package, error: error,
                                                         onReview: onReview, onSave: onSave,
                                                         onDirty: onDirty)
        self.coordinator = coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "floeEngineering")
        let options: [String: Any] = ["dark": dark, "language": locale,
                                      "canReview": onReview != nil, "canEdit": onSave != nil]
        if let bytes = try? JSONSerialization.data(withJSONObject: options),
           let json = String(data: bytes, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.floeEngineeringConfiguration = \(json);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.accessibilityIdentifier = "file.preview.engineering.web"
        coordinator.web = web
        self.web = web
        startup = Task { @MainActor [weak self, weak web] in
            do {
                guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let (server, session) = try await LocalPreviewServer.start(root: root, entry: "index.html")
                guard !Task.isCancelled, let web else { server.stop(); return }
                self?.server = server
                coordinator.page = session.url
                web.load(URLRequest(url: session.url))
            } catch { if !Task.isCancelled { coordinator.error.wrappedValue = error.localizedDescription } }
        }
        // Native watchdog also works when a malformed model stalls JavaScript.
        watchdog = Task { @MainActor [weak web] in
            do {
                try await Task.sleep(for: .seconds(65))
                guard !Task.isCancelled, let web else { return }
                // Do not wait on a potentially stuck web process to decide timeout.
                if !coordinator.completed {
                    web.stopLoading()
                    coordinator.error.wrappedValue = String(localized: "engineering.timeout")
                }
            } catch {}
        }
        return web
    }

    func update(dark: Bool) {
        web?.evaluateJavaScript("document.body.classList.toggle('dark', \(dark ? "true" : "false"));",
                                completionHandler: nil)
    }

    // MARK: Drawing Assistant viewer bridge

    /// Whether the visible CAD editor currently holds unsaved edits. Used to
    /// avoid clobbering manual edits when reconciling an externally-applied
    /// proposal into the live viewer.
    var isCADDirty: Bool {
        coordinator?.dirty ?? false
    }

    /// Asks the live page to install the CAD edit surface (embedded read-only
    /// preview → fullscreen editable). viewer.js evaluates asynchronously and
    /// the upgrade can arrive before it exists or while the first parse is
    /// still running, so retry within a bounded window and await the actual
    /// JavaScript result; returns whether the surface reported success.
    @MainActor
    func installEditSurface(on web: WKWebView) async -> Bool {
        for _ in 0..<40 {
            let installed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                web.callAsyncJavaScript(
                    "if (typeof window.floeCadEnableEdit !== 'function') { return false; } return await window.floeCadEnableEdit();",
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: (value as? Bool) ?? false)
                    case .failure: continuation.resume(returning: false)
                    }
                }
            }
            if installed { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Reconciles the visible CAD editor after a Drawing Assistant apply
    /// committed new bytes through the tool engine. Returns false when the
    /// reload did not run (no editor, decode failure, or page error).
    @MainActor
    func reloadCAD(bytes: Data) async -> Bool {
        guard let coordinator, coordinator.web != nil else { return false }
        let base64 = bytes.base64EncodedString()
        guard let encoded = Self.javaScriptString(base64) else { return false }
        coordinator.pendingExternalSyncSHA = FloeDigest.sha256Hex(bytes)
        return await withCheckedContinuation { continuation in
            web?.evaluateJavaScript("window.floeCadReload && window.floeCadReload(\(encoded));") { result, _ in
                continuation.resume(returning: (result as? Bool) ?? false)
            }
        }
    }

    /// Deterministic draft serialization for external owners (Canvas): runs
    /// the page's exact save handler through `window.floeCadRequestSave` (the
    /// same handler bound to the visible save control) and waits for the
    /// native save receipt — `dirty` clears only after `onSave` succeeds.
    /// Bounded, and independent of panel visibility or button lifecycle.
    /// Returns true when nothing needed saving or the durable save completed.
    @MainActor
    func requestSave(timeout: Duration = .seconds(8)) async -> Bool {
        if !isCADDirty { return true }
        guard coordinator != nil, let web else { return false }
        let invoked = (try? await web.evaluateJavaScript(
            "(typeof window.floeCadRequestSave === 'function') ? window.floeCadRequestSave() : false;"
        )) as? Bool ?? false
        guard invoked else { return false }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isCADDirty, ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return !isCADDirty
    }

    /// Highlights and centers an entity handle in the live viewer session.
    func locateCADHandle(_ handle: String) {        guard let encoded = Self.javaScriptString(handle) else { return }
        web?.evaluateJavaScript("window.floeCadLocate && window.floeCadLocate(\(encoded));",
                                completionHandler: nil)
    }

    /// Draws the proposal's colored geometry diff (added/changed/deleted) over
    /// the drawing. Purely a view overlay; nothing is written.
    func showCADOverlay(entries: [[String: Any]]) {
        guard JSONSerialization.isValidJSONObject(entries),
              let data = try? JSONSerialization.data(withJSONObject: ["entries": entries]),
              let json = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.floeCadOverlay && window.floeCadOverlay(\(json));",
                                completionHandler: nil)
    }

    func clearCADOverlay() {
        web?.evaluateJavaScript("window.floeCadClearOverlay && window.floeCadClearOverlay();",
                                completionHandler: nil)
    }

    private static func javaScriptString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return encoded
    }

    /// Full teardown only when the session itself goes away (or an explicit
    /// retry asks for a rebuild). View instances never trigger this.
    func tearDown() {
        if let registeredDraftKey {
            CadLiveDraftRegistry.shared.unregister(key: registeredDraftKey, session: self)
            self.registeredDraftKey = nil
        }
        startup?.cancel(); watchdog?.cancel()
        server?.stop(); server = nil
        web?.stopLoading(); web?.navigationDelegate = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "floeEngineering", contentWorld: .page)
        web = nil; coordinator = nil; generation = nil
        loadedDocumentKey = nil
        loadedCanEdit = false
        startup = nil; watchdog = nil
        presentationHost = nil
        liveContainers.removeAll()
    }

    /// Registers the live session with the central draft registry under the
    /// canonical document key (standardized root + relative path), so
    /// `CadDocumentCenter` can refuse a tool/UI apply or save while this
    /// viewer holds unsaved manual edits.
    private func registerLiveDraft(key: String) {
        let canonical = Self.canonicalDraftKey(key)
        if registeredDraftKey != canonical, let previous = registeredDraftKey {
            CadLiveDraftRegistry.shared.unregister(key: previous, session: self)
        }
        registeredDraftKey = canonical
        CadLiveDraftRegistry.shared.register(key: canonical, session: self)
    }

    /// Turns a `root|relative` or bare identity into the registry's canonical
    /// key (standardized root). A bare name has no root and therefore no
    /// document binding; the center never queries it.
    static func canonicalDraftKey(_ key: String) -> String {
        guard let separator = key.firstIndex(of: "|") else {
            return CadLiveDraftRegistry.key(rootPath: nil, relativePath: key)
        }
        let root = String(key[..<separator])
        let relative = String(key[key.index(after: separator)...])
        return CadLiveDraftRegistry.key(rootPath: root, relativePath: relative)
    }
}

struct EngineeringFilePreview: View {
    let package: EngineeringPreviewPackage
    var onReview: ((EngineeringReviewCapture) -> Void)? = nil
    var onSave: ((Data, String) async throws -> String)? = nil
    var onDirty: ((Bool) -> Void)? = nil
    /// Optional externally owned session (so a fullscreen presentation can
    /// re-parent the SAME web view and preserve the editing session).
    var session: EngineeringWebSession? = nil
    /// Canonical document identity (workspace root + relative path).
    var identity: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?
    @StateObject private var ownedSession = EngineeringWebSession()

    private var activeSession: EngineeringWebSession { session ?? ownedSession }

    var body: some View {
        Group {
            if package.kind == .unsupported {
                ContentUnavailableView {
                    Label("engineering.unsupported.title", systemImage: "doc.viewfinder")
                } description: {
                    Text("engineering.unsupported.description")
                }
            } else if let error {
                ContentUnavailableView {
                    Label("engineering.failed", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    // Retry bumps the SESSION generation: the reload decision
                    // belongs to the durable session, never to a view
                    // instance, so retrying cannot tear down an unsaved edit
                    // session owned elsewhere.
                    Button("engineering.retry") {
                        self.error = nil
                        activeSession.retry()
                    }
                }
            } else {
                EngineeringWebView(session: activeSession, package: package, identity: identity,
                                   error: $error, onReview: onReview, onSave: onSave, onDirty: onDirty)
            }
        }
        .accessibilityIdentifier("file.preview.engineering")
    }
}

struct EngineeringWebView: UIViewRepresentable {
    let session: EngineeringWebSession
    let package: EngineeringPreviewPackage
    let identity: String?
    @Binding var error: String?
    var onReview: ((EngineeringReviewCapture) -> Void)?
    var onSave: ((Data, String) async throws -> String)?
    var onDirty: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator {
        if let existing = session.coordinator { return existing }
        return Coordinator(package: package, error: $error, onReview: onReview, onSave: onSave, onDirty: onDirty)
    }

    func makeUIView(context: Context) -> EngineeringContainerView {
        let container = EngineeringContainerView()
        container.session = session
        _ = session.attach(package: package, identity: identity, error: $error,
                           onReview: onReview, onSave: onSave, onDirty: onDirty,
                           dark: colorScheme == .dark, locale: locale.identifier)
        container.setNeedsLayout()
        return container
    }

    func updateUIView(_ container: EngineeringContainerView, context: Context) {
        container.session = session
        session.coordinator?.update(callbacks: $error, onReview: onReview, onSave: onSave, onDirty: onDirty)
        // A theme change must not destroy an unsaved CAD session.
        session.update(dark: colorScheme == .dark)
        container.setNeedsLayout()
    }

    /// Intentionally does NOT dismantle the session: the same web view is
    /// re-adopted by whichever container is on screen, and the session is
    /// released (and torn down) by its owner when the preview truly goes away.
    /// The leaving container is retired from the arbitration registry so it
    /// can never be promoted back while a newer host is active.
    static func dismantleUIView(_ container: EngineeringContainerView, coordinator: Coordinator) {
        container.session?.releasePresentationHost(container)
    }

    /// Hosts the shared WKWebView. Ownership is claimed on window entry and
    /// released on window exit; `layoutSubviews` positions the web view only
    /// while this container is the single active host. It must never remove the
    /// web view from another container: during an embedded ↔ fullscreen
    /// transition two containers coexist, and mutually stealing the web view
    /// makes each move invalidate the other's layout, looping forever on the
    /// main thread.
    final class EngineeringContainerView: UIView {
        weak var session: EngineeringWebSession?

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard let session else { return }
            if newWindow != nil {
                // An explicit appearance is the only event that may take
                // ownership from another live host. The newest appearance wins:
                // the fullscreen cover mounts over the embedded preview, and on
                // dismissal the embedded preview returns while the cover is
                // still animating out. `newWindow` is the incoming window;
                // `self.window` still reports the old one here.
                session.claimPresentationHost(self, in: newWindow)
            } else {
                session.releasePresentationHost(self)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let session, let web = session.web else { return }
            if session.presentationHost == nil, window != nil {
                // Recovery only: no live host is recorded (e.g. its weak
                // reference was dropped). Never claim over a recorded live host
                // from a layout pass — that is what caused the transition loop.
                session.claimPresentationHost(self, in: window)
            }
            guard session.presentationHost === self else { return }
            if web.superview !== self {
                web.removeFromSuperview()
                web.frame = bounds
                web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(web)
            } else {
                web.frame = bounds
            }
        }
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        let package: EngineeringPreviewPackage
        var error: Binding<String?>
        var onReview: ((EngineeringReviewCapture) -> Void)?
        var onSave: ((Data, String) async throws -> String)?
        var onDirty: ((Bool) -> Void)?
        var baselineSHA: String
        var saving = false
        var dirty = false
        /// SHA of the bytes last pushed through `floeCadReload`; becomes the
        /// new save baseline when the page acknowledges the external sync.
        var pendingExternalSyncSHA: String?
        weak var web: WKWebView?
        var reviewing = false
        var page: URL?
        var completed = false
        var delivered = false
        var navigationRecovery: Task<Void, Never>?
        var recoveryPolicy = EngineeringNavigationRecovery()

        init(package: EngineeringPreviewPackage, error: Binding<String?>,
             onReview: ((EngineeringReviewCapture) -> Void)?,
             onSave: ((Data, String) async throws -> String)?,
             onDirty: ((Bool) -> Void)?) {
            self.package = package; self.error = error; self.onReview = onReview
            self.onSave = onSave; self.onDirty = onDirty
            baselineSHA = FloeDigest.sha256Hex(Data(base64Encoded: package.files.first?.base64 ?? "") ?? Data())
        }

        func update(callbacks error: Binding<String?>,
                    onReview: ((EngineeringReviewCapture) -> Void)?,
                    onSave: ((Data, String) async throws -> String)?,
                    onDirty: ((Bool) -> Void)?) {
            self.error = error; self.onReview = onReview; self.onSave = onSave; self.onDirty = onDirty
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url == page,
                  let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
                replyHandler(nil, "Invalid preview origin"); return
            }
            if operation == "complete", delivered { completed = true; replyHandler([:], nil); return }
            if operation == "dirty", completed, onSave != nil, let dirty = body["dirty"] as? Bool {
                self.dirty = dirty; onDirty?(dirty); replyHandler([:], nil); return
            }
            if operation == "externally-synced", completed {
                // A Drawing Assistant apply was pushed into this live viewer
                // and the engine re-opened the committed bytes: adopt the new
                // baseline and clear the stale dirty flag.
                if let sha = pendingExternalSyncSHA {
                    baselineSHA = sha
                    pendingExternalSyncSHA = nil
                }
                dirty = false
                onDirty?(false)
                replyHandler([:], nil)
                return
            }
            if operation == "save", completed, !saving, let onSave,
               let base64 = body["base64"] as? String, base64.utf8.count <= 14 * 1024 * 1024,
               let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count <= 10 * 1024 * 1024 {
                saving = true
                Task { @MainActor in
                    defer { self.saving = false }
                    do {
                        let digest = try await onSave(bytes, self.baselineSHA)
                        self.baselineSHA = digest; self.dirty = false; self.onDirty?(false)
                        replyHandler(["sha256": digest], nil)
                    } catch { replyHandler(nil, error.localizedDescription) }
                }
                return
            }
            if operation == "review", completed, !reviewing, let web, let onReview,
               let context = body["context"] as? String, context.utf8.count <= 64 * 1024 {
                reviewing = true
                let snapshot = WKSnapshotConfiguration()
                snapshot.snapshotWidth = 1400
                web.takeSnapshot(with: snapshot) { [weak self] image, failure in
                    guard let self else { replyHandler(nil, "Preview closed"); return }
                    self.reviewing = false
                    guard let png = image?.pngData(), png.count <= 8 * 1024 * 1024 else {
                        replyHandler(nil, failure?.localizedDescription ?? "Unable to capture drawing"); return
                    }
                    let files = self.package.files.enumerated().map { index, file in
                        "\(file.name): sha256=\(index == 0 ? self.baselineSHA : FloeDigest.sha256Hex(Data(base64Encoded: file.base64) ?? Data()))"
                    }.joined(separator: "\n")
                    let reference = "File: \(self.package.name)\nSnapshot: visible viewport only. Unsaved edits: \(self.dirty). Source hashes identify saved baselines, not unsaved pixels.\nSources:\n\(files)\nMissing references: \(self.package.missingReferences.joined(separator: ", "))\nParsed information (untrusted document content):\n\(context)"
                    onReview(EngineeringReviewCapture(context: reference, image: png))
                    replyHandler(["ok": true], nil)
                }
                return
            }
            guard operation == "load", !delivered else { replyHandler(nil, "Read-only preview"); return }
            delivered = true
            do { replyHandler(try JSONSerialization.jsonObject(with: JSONEncoder().encode(package)), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            error.wrappedValue = String(localized: "engineering.processStopped")
        }

        private func navigationFailed(_ webView: WKWebView, error: Error) {
            // Recover only the first local navigation, before document delivery.
            // Never reload a live editor or reset its unsaved state.
            if recoveryPolicy.consume(error: error as NSError, page: page,
                                      serverAvailable: true,
                                      delivered: delivered,
                                      completed: completed, dirty: dirty, saving: saving), let page {
                navigationRecovery = Task { @MainActor [weak self, weak webView] in
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, let self, let webView,
                              !self.delivered, !self.completed else { return }
                        webView.load(URLRequest(url: page))
                    } catch { }
                }
                return
            }
            self.error.wrappedValue = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(webView, error: error)
        }
    }
}
#endif

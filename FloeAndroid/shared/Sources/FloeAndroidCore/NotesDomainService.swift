// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes native service binding. One process-wide service maps the
// accepted runtime generation to one NotesEngine and one real NotesStore.
// Binding is lazy: `notes.bind` never creates a library, and ordinary chat
// never opens Notes as a side effect. The first explicit Notes command does.
import Foundation
import Crypto
import FloeCore
import FloeNotes

public final class NotesDomainService: @unchecked Sendable {
    public static let shared = NotesDomainService()

    public static let actions: [String] = [
        "library.summary", "poll",
        "notebook.list", "notebook.create", "notebook.rename", "notebook.delete",
        "document.list", "document.recent", "document.get", "document.summary",
        "document.create", "document.duplicate", "document.saveMessage",
        "document.createLinkedMindMap", "document.apply", "document.undo",
        "document.setTrashed", "document.permanentlyDelete", "document.history",
        "document.markOpened", "document.setFavorite", "document.setTags",
        "document.coverRead", "document.coverApply", "document.cacheOfficePreview",
        "document.editingSnapshot", "document.pageOCRState",
        "document.cachePageOCR", "document.cacheOfficeText", "document.officeTextState",
        "document.conflictReviews", "document.conflictReview",
        "document.saveConflictReview", "document.keepBothConflictVersions",
        "search.query",
        "text.stageBegin", "text.stageAppend", "text.stageCommit", "text.stageAbort",
        "batch.stageBegin", "batch.stageAppend", "batch.stageCommit", "batch.stageAbort",
        "resource.importBegin", "resource.importAppend", "resource.importCommit",
        "resource.importAbort", "resource.metadata", "resource.read",
        "resource.discardUnreferenced", "resources.collectDeleted",
        "assistant.grantAccess", "assistant.bind", "assistant.revokeAccess",
        "assistant.grants", "assistant.scopedDocuments", "assistant.setFocus",
        "assistant.runtimeContext", "assistant.thread",
        "archive.export", "archive.exportRead", "archive.exportClose",
        "archive.importBegin", "archive.importAppend", "archive.importCommit",
        "archive.importAbort",
        "proposal.preview", "proposal.create", "proposal.get", "proposal.list",
        "proposal.issueGrant", "proposal.apply", "proposal.resolve",
        "proposal.outbox", "proposal.outboxAck",
    ] + NotesAssistantActions.all + NotesOCRActions.all

    private struct Bound {
        let epoch: UInt64
        let root: URL
        var engine: NotesEngine?
    }

    private let lock = NSLock()
    private var bound: Bound?
    private var lastEpoch: UInt64 = 0
    private var requireLiveBootstrap = true

    private init() {}

    /// Trusted lifecycle binding. The root is derived by the runtime owner;
    /// this method never accepts a caller-supplied store path from the wire.
    @discardableResult
    func bind(epoch: UInt64, root: URL) -> [String: Any] {
        lock.lock()
        if let current = bound, current.epoch == epoch {
            let sameRoot = current.root.standardizedFileURL == root.standardizedFileURL
            let open = current.engine != nil
            lock.unlock()
            guard sameRoot else {
                return ["ok": false, "error": "epochAlreadyBound",
                        "reason": "differentRoot", "retryable": false]
            }
            return ["ok": true, "bound": true, "epochAccepted": true,
                    "storeOpen": open,
                    "fingerprint": Self.fingerprint(root)]
        }
        guard epoch > lastEpoch else {
            lock.unlock()
            return ["ok": false, "error": "staleGeneration", "retryable": true]
        }
        let previous = bound?.engine
        bound = Bound(epoch: epoch, root: root.standardizedFileURL, engine: nil)
        lastEpoch = epoch
        lock.unlock()
        if let previous {
            Task { await previous.retire() }
        }
        return ["ok": true, "bound": true, "epochAccepted": true,
                "storeOpen": false, "fingerprint": Self.fingerprint(root)]
    }

    /// Trusted test/qualification seam: binds an isolated root without the
    /// runtime bootstrap. Production bridge ingress never calls this.
    func bindForTesting(epoch: UInt64, root: URL) {
        lock.lock()
        bound = Bound(epoch: epoch, root: root.standardizedFileURL, engine: nil)
        lastEpoch = max(lastEpoch, epoch)
        requireLiveBootstrap = false
        lock.unlock()
    }

    func status() -> [String: Any] {
        lock.lock()
        let value = bound
        let open = value?.engine != nil
        lock.unlock()
        return ["ok": true, "bound": value != nil, "storeOpen": open,
                "protocol": BridgeV4.version, "schema": BridgeV4.schema]
    }

    func handle(epoch: UInt64, requestID: String, action: String,
                payload: NotesJSONValue?) async throws -> Data {
        guard Self.actions.contains(action) else {
            throw NotesDomainError.unsupportedAction(NotesWire.bounded(action, limit: 80))
        }
        if liveBootstrapRequired() {
            guard AndroidRuntimeBootstrap.notesBinding(epoch: epoch, ownerToken: nil) != nil else {
                throw NotesDomainError.staleGeneration
            }
        }
        if NotesAssistantActions.handles(action) {
            // Validate the existing lazy Notes binding without opening its store
            // for a readiness query. No stale epoch may rebind the assistant.
            guard hasBoundEpoch(epoch) else { throw NotesDomainError.staleGeneration }
            return try await NotesAssistantDomain.shared.handle(
                epoch: epoch, requestID: requestID, action: action, payload: payload)
        }
        if NotesOCRActions.handles(action) {
            guard hasBoundEpoch(epoch) else { throw NotesDomainError.staleGeneration }
            return try await NotesOCRDomain.shared.handle(
                epoch: epoch, requestID: requestID, action: action, payload: payload)
        }
        let engine = try engine(for: epoch)
        if action == "assistant.thread" {
            return try await engine.assistantThreadProjection(payload)
        }
        return try await engine.perform(requestID: requestID, action: action, payload: payload)
    }

    private func hasBoundEpoch(_ epoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bound?.epoch == epoch
    }

    private func liveBootstrapRequired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requireLiveBootstrap
    }

    private func engine(for epoch: UInt64) throws -> NotesEngine {
        lock.lock()
        guard let current = bound, current.epoch == epoch else {
            lock.unlock()
            throw NotesDomainError.staleGeneration
        }
        if let engine = current.engine {
            lock.unlock()
            return engine
        }
        do {
            let engine = try NotesEngine(root: current.root)
            bound?.engine = engine
            lock.unlock()
            return engine
        } catch {
            lock.unlock()
            throw NotesDomainError.storageUnavailable
        }
    }

    /// Exact-epoch retirement. A stale epoch never closes a newer store.
    func retire(epoch: UInt64) async {
        let engine = takeEngineForRetirement(epoch: epoch)
        if let engine { await engine.retire() }
    }

    private func takeEngineForRetirement(epoch: UInt64) -> NotesEngine? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = bound, current.epoch == epoch else { return nil }
        let engine = current.engine
        bound = nil
        return engine
    }

    private static func fingerprint(_ root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// Bridge protocol v4 — dedicated Notes action/event channel.
///
/// This is additive to v1/v2/v3: those version handlers and their response
/// bytes are unchanged. The v4 channel has no task/run/provider scope and is
/// not advertised as a model-facing tool; only the trusted Android host
/// adapter calls it through the existing `floe_bridge_exchange` C ABI.
public enum BridgeV4 {
    public static let version = 4
    public static let schema = "floe.notes/4"
    public static let maximumRequestBytes = NotesWire.maximumRequestBytes
    public static let maximumResponseBytes = NotesWire.maximumResponseBytes

    private struct Request: Decodable {
        let version: Int
        let operation: String
        let requestID: String?
        let epoch: UInt64?
        let ownerToken: String?
        let action: String?
        let cursor: Int64?
        let limit: Int?
        let payload: NotesJSONValue?
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, Error>?
        func set(_ result: Result<Data, Error>) { lock.lock(); value = result; lock.unlock() }
        func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func blocking(_ body: @escaping @Sendable () async throws -> Data) -> Result<Data, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do { box.set(.success(try await body())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? .failure(NotesDomainError.busy)
    }

    private static func failure(_ code: String, _ reason: String? = nil,
                                retryable: Bool = false) -> [String: Any] {
        var object: [String: Any] = ["ok": false, "error": code, "retryable": retryable]
        if let reason { object["reason"] = reason }
        return object
    }

    /// `floe.notes/4` publishes the `notes.*` operation names in the App
    /// contract, while the first host tests addressed the same five closed
    /// operations without the prefix. Accept exactly those two spellings;
    /// no other operation reaches the switch below. This is not a generic
    /// version/action bypass: the vocabulary remains the same five entries.
    private static func canonicalOperation(_ operation: String) -> String? {
        switch operation {
        case "handshake", "notes.handshake": return "handshake"
        case "status", "notes.status": return "status"
        case "bind", "notes.bind": return "bind"
        case "command", "notes.command": return "command"
        case "poll", "notes.poll": return "poll"
        default: return nil
        }
    }

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        guard requestData.count <= maximumRequestBytes else {
            return failure("requestTooLarge")
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: requestData),
              request.version == version else {
            return failure("invalidRequest")
        }
        guard let operation = canonicalOperation(request.operation) else {
            return failure("unsupportedOperation")
        }
        switch operation {
        case "handshake":
            return handshake()
        case "status":
            return NotesDomainService.shared.status()
        case "bind":
            guard let epoch = request.epoch, epoch > 0 else {
                return failure("invalidRequest", "missingEpoch")
            }
            guard let root = AndroidRuntimeBootstrap.notesBinding(
                epoch: epoch, ownerToken: request.ownerToken) else {
                return failure("runtimeUnavailable", "acceptedRootNotLive", retryable: true)
            }
            return NotesDomainService.shared.bind(epoch: epoch, root: root.artifactStoreURL.appendingPathComponent("Notes", isDirectory: true))
        case "command":
            guard let epoch = request.epoch, epoch > 0 else {
                return failure("invalidRequest", "missingEpoch")
            }
            guard let action = request.action, !action.isEmpty else {
                return failure("invalidRequest", "missingAction")
            }
            guard let correlation = request.requestID ?? fallbackRequestID,
                  !correlation.isEmpty, correlation.utf8.count <= 256 else {
                return failure("invalidRequest", "missingRequestID")
            }
            guard NotesDomainService.actions.contains(action) else {
                return failure("unsupportedAction", NotesWire.bounded(action, limit: 80))
            }
            let result = blocking {
                try await NotesDomainService.shared.handle(
                    epoch: epoch, requestID: correlation,
                    action: action, payload: request.payload)
            }
            return decode(result)
        case "poll":
            guard let epoch = request.epoch, epoch > 0 else {
                return failure("invalidRequest", "missingEpoch")
            }
            guard let correlation = request.requestID ?? fallbackRequestID,
                  !correlation.isEmpty, correlation.utf8.count <= 256 else {
                return failure("invalidRequest", "missingRequestID")
            }
            let cursor = request.cursor ?? 0
            guard cursor >= 0, cursor <= Int64(Int.max) else {
                return failure("invalidPayload", "invalidCursor")
            }
            let limit = min(512, max(1, request.limit ?? 128))
            let payload = NotesJSONValue.object([
                "cursor": .integer(Int(cursor)),
                "limit": .integer(limit),
            ])
            let result = blocking {
                try await NotesDomainService.shared.handle(
                    epoch: epoch, requestID: correlation,
                    action: "poll", payload: payload)
            }
            return decode(result)
        default:
            return failure("unsupportedOperation")
        }
    }

    public static func handshake() -> [String: Any] {
        [
            "ok": true,
            "version": version,
            "schema": schema,
            "engine": "FloeNotes",
            "actions": NotesDomainService.actions,
            "requestMaxBytes": maximumRequestBytes,
            "responseMaxBytes": maximumResponseBytes,
            "chunkMaxBytes": NotesWire.maximumChunkBytes,
            "readMaxBytes": NotesWire.maximumReadBytes,
            "resourceMaxBytes": NotesWire.maximumResourceBytes,
            "archiveMaxBytes": NotesWire.maximumArchiveBytes,
            "maximumEdits": NotesWire.maximumEdits,
            "persistence": "sqlite-grdb-content-addressed",
            "chatAuthorities": false,
        ]
    }

    private static func decode(_ result: Result<Data, Error>) -> [String: Any] {
        switch result {
        case .success(let data):
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return failure("invalidBinderOutput", "malformedNotesResult")
            }
            return object
        case .failure(let error):
            let mapped = NotesWire.mappedError(error)
            return failure(mapped.code, mapped.reason, retryable: mapped.retryable)
        }
    }
}

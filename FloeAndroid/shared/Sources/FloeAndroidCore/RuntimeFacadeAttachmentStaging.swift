// SPDX-License-Identifier: MPL-2.0
//
// RB-7 attachment staging — host-owned staging authority (domain core).
//
// Scope authority (Main BRIDGE_V3 attachmentPreRunClarification +
// MAIN_REVIEW_ADDENDUM): the seven EXISTING attachment commands
//   attachment.stage / attachment.staging.read / attachment.staging.cancel /
//   attachment.staging.discard        (applicationConfiguration/attachmentStaging)
//   attachment.commit / attachment.read / attachment.cancel
//                                        (conversationLifecycle)
// gain their REAL host implementation here. No new wire command, label or
// matrix count is introduced (BridgeEnvelopeV3.swift and BridgeV3Contracts.kt
// stay byte-identical; the Kotlin rule mirror already declares these seven).
//
// Ownership model:
// * Bytes are produced ONLY by the trusted Android platform host streaming an
//   actual user-picked content URI through the narrow JNI ingress below. A
//   model-facing JSON envelope can never carry a path, URI, fd or byte
//   payload into this service; it references OPAQUE native-minted receipts.
//   A forged or stale receipt is a typed refusal BEFORE any file effect.
// * Handles are minted by the trusted native host under the EXACT accepted
//   root/epoch and the compose route (existing conversation OR the honest
//   new-composer route + incarnation + draft revision). They are
//   process-local: a new generation re-mints handles from its own salt, so
//   an old envelope can never address newer staging state (generation
//   fence). Nothing here pretends a handle is a durable identity: the durable
//   identities are the ORIGINAL schema-46 rows (attachments.id /
//   conversation_id / message_id) and the ORIGINAL atomic
//   `RunLaunchStore.prepare` (unmodified) remains the ONLY message-attachment
//   insertion path for launches.
// * Staged bytes live app-private:
//   `Attachments/<stagingUUID>/<sanitizedName>` under the accepted runtime
//   storage root — the SAME portable storage case as the original
//   (`AttachmentRef.Storage.applicationSupport` + attachments-directory
//   relative path, AgentThread.swift:54-108). No new Storage enum case, no
//   schema change, no iOS bookmark pretense, no contentUri column.
// * RuntimeOwnedWorkRegistry (RB1 reviewed) is attached BEFORE ingress IO
//   and detached only when the real stream + metadata + file effect settle;
//   retirement gating therefore waits on actual staging, and long staging
//   is owned by the SERVICE, never by a view: UI reconstruction, background
//   and lock are NOT navigation and never delete a normal staged draft.
//
// Binary NEVER crosses the JSON bridge: mailbox/effect details carry opaque
// handles + scalar-safe identifiers only; bytes move through the bounded JNI
// chunk streams (64 KiB hard page) in both directions.
//
// This source is NOT compiled/executed by the authoring package (grammar
// parse only — see evidence/grammar). Publication, Swift 6 object build,
// device 33/API37 acceptance and live wiring remain Main's serialized lane.
import Foundation
import Crypto
import FloeModels
import FloeAgentRuntime

// MARK: - Limits

/// Closed bounds. `maximumJSONBytes` mirrors the frozen bridge bound; the
/// streaming bounds are the staging lane's own file discipline.
public enum AttachmentStagingLimits {
    /// Same strict request bound as the frozen v1/v2/v3 JSON bridge.
    public static let maximumJSONBytes = 65_536
    /// One JNI write/read chunk. The platform pump MUST NOT accumulate a
    /// larger buffer; there is no whole-file `readBytes` path in this lane.
    public static let maximumChunkBytes = 65_536
    /// One staged file (documents/audio headroom for G02). Oversized
    /// sources fail typed at the stream boundary; temps are cleaned by the
    /// owning session, never silently truncated.
    public static let maximumStagedBytes = 128 * 1_024 * 1_024
    /// Aggregate staged bytes held for the current App instance.
    public static let maximumStagedAggregateBytes = 1_073_741_824
    public static let maximumLiveIngress = 16
    public static let maximumStagedRecords = 128
    /// Free-space low-water the authoritative service re-checks while
    /// streaming (the Kotlin advisory StatFs pre-check may be stricter).
    public static let minimumFreeBytes = 64 * 1_024 * 1_024
    /// Inline-image budget mirrors the ORIGINAL ConversationHistoryAssembler
    /// bound (AgentCheckpoint.swift `ConversationImagePart` provider path).
    public static let maximumInlineImageBytes = 8 * 1_024 * 1_024
    public static let maximumInlineImageAggregateBytes = 16 * 1_024 * 1_024
    /// Bounded after sanitization (UTF-8 bytes).
    public static let maximumDisplayNameBytes = 240
    public static let maximumMIMEBytes = 127
    public static let maximumHandlesPerOperation = 8
    /// The durable owner manifest is one small non-secret JSON document.
    public static let maximumManifestBytes = 256 * 1_024
}

// MARK: - Typed codes

/// Closed, path-free staging codes. These identifiers — never a raw path,
/// URI, name or byte — are what cross JNI, effect detail and diagnostics.
public enum AttachmentStagingCode: String, Sendable, Codable, CaseIterable {
    case notInstalled
    case generationFenced
    case routeUnknown
    case routeStale
    case temporaryRefused
    case ingressUnknown
    case ingressUnfinished
    case handleUnknown
    case stateConflict
    case launchMarked
    case alreadyConsumed
    case leaseUnknown
    case payloadInvalid
    case nameUnusable
    case sizeExceeded
    case aggregateExceeded
    case diskFull
    case saturated
    case cancelled
    case writeFailed
    case readFailed
    case renameFailed
    case digestMismatch
    case sourceUnavailable
    case grantRevoked
    case storeUnavailable
    case rowChanged
    case wrongOwner
    case rowBoundToMessage
    case `internal`
}

public struct AttachmentStagingError: Error, Sendable, Equatable {
    public let code: AttachmentStagingCode
    public init(_ code: AttachmentStagingCode) { self.code = code }
}

// MARK: - Opaque receipt grammar

/// Three opaque process-local receipt spaces, minted ONLY by the trusted
/// native host. Grammar mirrors the frozen `RuntimeOwnedWorkReceipt` rule
/// (prefix + 32 lowercase hex). A model envelope that guesses or replays an
/// old spelling resolves to typed `handleUnknown`/`ingressUnknown`/
/// `routeUnknown`, never to a filesystem effect.
public enum AttachmentReceipt {
    public static let stagingPrefix = "stag:v1:"
    public static let ingressPrefix = "sing:v1:"
    public static let routePrefix = "route:v1:"
    public static let leasePrefix = "lease:v1:"
    public static let hexLength = 32

    public static func isValid(_ value: String, prefix: String) -> Bool {
        let bytes = value.utf8
        let logical = prefix.utf8.count + hexLength
        guard bytes.count == logical, value.hasPrefix(prefix) else { return false }
        let hex = value[value.index(value.startIndex, offsetBy: prefix.count)...]
        guard hex.count == hexLength else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// Salted per App instance: handles cannot be reconstructed by an older
    /// generation's captured JSON (honest expiry, no revival).
    static func mint(prefix: String, salt: Data, fields: [String]) -> String {
        var input = salt
        for field in fields {
            input.append(contentsOf: field.utf8)
            input.append(0x00)
        }
        let hex = SHA256.hash(data: input).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return prefix + hex
    }
}

// MARK: - Compose route

/// One host-registered compose route: an EXISTING conversation (real id) or
/// the new-conversation composer (nil id — a valid host route exists before
/// any run; no fabricated conversation is required). `incarnation` is the
/// real flow-holder session epoch; `draftRevision` is the host's current
/// draft floor used for source-stage update guards. The service compares
/// parsed values; a late callback from an older incarnation is `routeStale`
/// and none of these fields ever becomes a file path.
public struct ComposeRouteDescriptor: Sendable, Equatable {
    public var conversationID: UUID?
    public var incarnation: UInt64
    public var draftRevision: UInt64
    public var isTemporarySession: Bool
    public init(conversationID: UUID?, incarnation: UInt64, draftRevision: UInt64,
                isTemporarySession: Bool) {
        self.conversationID = conversationID
        self.incarnation = incarnation
        self.draftRevision = draftRevision
        self.isTemporarySession = isTemporarySession
    }
}

public struct StagingRoute: Sendable, Equatable {
    public let receipt: String
    public let epoch: UInt64
    public let descriptor: ComposeRouteDescriptor
}

// MARK: - Staged record states

public enum StagedState: String, Sendable, Codable, Equatable {
    /// JNI ingress open; bytes streaming to the private temp area.
    case ingressing
    /// EOF reached on the stream; temp durable+fsynced, awaiting the
    /// `attachment.stage` publish command (crash-recoverable).
    case readyToPublish
    /// Published (atomic rename verified) and consumable via handle.
    case staged
    /// Terminal honest failure of this staging attempt (retry re-derives
    /// bytes under the SAME staging identity).
    case failed
    /// Held by a live launch lease (`reserveLaunchLease` .. commit/rollback).
    case reserved
    /// Committed into a message by the ORIGINAL atomic prepare.
    case consumed
    /// Persisted as a conversation-level attachment row by attachment.commit.
    case rowCommitted
    /// Explicitly discarded by the host/user (bytes already removed).
    case discarded
    /// Cancelled in-flight (bytes already removed, never published).
    case cancelled
}

/// One durable staging record. `relativePath` is ALWAYS
/// `<stagingID-uuid>/<sanitizedName>` — an attachments-directory-relative
/// path in the ORIGINAL AttachmentRef sense. The service derives it from the
/// record UUID and never accepts it from a caller.
public struct StagedRecord: Sendable {
    public let stagingID: UUID
    public var handle: String
    public let routeReceipt: String
    public let routeConversationID: UUID?
    public let routeIncarnation: UInt64
    public let epoch: UInt64
    public let kind: String
    public let displayName: String
    public let mimeType: String
    public var byteCount: Int
    public var sha256: String
    public let relativePath: String
    public var state: StagedState
    public let createdAt: Date
    /// Set when a launch (lease or parent resolve-only path) references this
    /// record; discard/lease checks refuse while marked. Cleared by
    /// `rollbackLaunchLease` or by the row-existence escape
    /// (`reconcileLaunchMarked`).
    public var launchMarkedCorrelation: String?

    var view: StagedRecordView {
        StagedRecordView(
            stagingID: stagingID.uuidString,
            handle: handle,
            state: state.rawValue,
            kind: kind,
            displayName: displayName,
            mimeType: mimeType,
            byteCount: byteCount,
            sha256: sha256,
            relativePath: relativePath,
            createdAt: createdAt,
            launchMarked: launchMarkedCorrelation != nil)
    }
}

/// The bounded, closed projection of one record for replies and metadata
/// pages. Wire settlements use identifier/scalar subsets (RB1 typed-carrier
/// decision); name/MIME remain in-process for the host UI and the typed page
/// only.
public struct StagedRecordView: Sendable, Equatable {
    public let stagingID: String
    public let handle: String
    public let state: String
    public let kind: String
    public let displayName: String
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public let relativePath: String
    public let createdAt: Date
    public let launchMarked: Bool
}

// MARK: - Launch lease

/// A pre-DB reservation over exact owned staged handles. The launch lane
/// (RB4-repair under Main composition) MUST pair every successful
/// `RunLaunchStore.prepare` with `commitLaunchLease` and EVERY pre-commit
/// failure with `rollbackLaunchLease`; staged bytes survive a failed DB
/// commit unchanged and become reusable exactly there. A committed lease is
/// never presented as "rolled back".
public struct StagedLease: Sendable, Equatable {
    public let leaseID: String
    public let correlation: String
    public let epoch: UInt64
    public let targetConversationID: UUID?
    public let handles: [String]
    public let stagingIDs: [UUID]
}

// MARK: - Owned-work attachment port (RB1 reviewed registry)

/// Mirror of the vault-07 `VaultOwnedWorkAttaching` pattern: production
/// forwards to the reviewed `RuntimeOwnedWorkRegistry`; tests inject a
/// double with the same contract. `attach` runs BEFORE any ingress file
/// effect; `detach` only after the stream + metadata + file effect settle.
///
/// Main-review note (exact minimal proposal, no invented alias): the frozen
/// registry kind vocabulary has no staging kind yet. This lane attaches
/// `.conversation` with ownerID = the record's route conversation UUID (or
/// the staging UUID for a new-draft route, which can never collide with a
/// real conversation id). Retirement gating is total-count and therefore
/// already correct; a dedicated `stagingAttachment` kind would be a
/// one-case RB1 producer addition for Main to decide at RB1 re-freeze.
public protocol StagingOwnedWorkAttaching: Sendable {
    func attach(epoch: UInt64, ownerID: String) -> RuntimeOwnedWorkAttachOutcome
    func detach(receipt: String, epoch: UInt64, ownerID: String) -> Bool
}

public struct RuntimeOwnedWorkRegistryStagingAttach: StagingOwnedWorkAttaching {
    public static let shared = RuntimeOwnedWorkRegistryStagingAttach()
    public let registry: RuntimeOwnedWorkRegistry
    public init(registry: RuntimeOwnedWorkRegistry = .shared) {
        self.registry = registry
    }
    public func attach(epoch: UInt64, ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        registry.attach(epoch: epoch, kind: .conversation, ownerID: ownerID)
    }
    public func detach(receipt: String, epoch: UInt64, ownerID: String) -> Bool {
        registry.detach(RuntimeOwnedWorkToken(receipt: receipt, epoch: epoch,
                                              kind: .conversation, ownerID: ownerID))
    }
}

// MARK: - Filesystem port (test seam; production = real FileManager)

/// The staging lane touches ONLY its derived paths under the accepted root:
/// `Attachments/` (final staged files), `Attachments/.staging-tmp/` (temps)
/// and `Staging/manifest.json` (the small owned recovery manifest). There is
/// no directory scan beyond this lane's own temp listing, no symlink
/// following (reads re-check each component), and never any external source
/// mutation.
public protocol StagingFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func createFile(at url: URL) throws
    func fileSize(atPath path: String) -> Int?
    func isRegularFile(atPath path: String) -> Bool
    func isSymbolicLink(atPath path: String) -> Bool
    func listFileNames(at url: URL) -> [String]
    func removeItem(at url: URL) throws
    func rename(from: URL, to: URL) throws
    func write(at offset: Int64, data: Data, to url: URL) throws
    func read(offset: Int64, length: Int, from url: URL) -> Data?
    func sync(_ url: URL) throws
    func availableCapacity(atPath path: String) -> Int64?
}

extension StagingFileSystem where Self == FileManagerStagingFileSystem {
    public static var floeStaging: FileManagerStagingFileSystem {
        FileManagerStagingFileSystem()
    }
}

public final class FileManagerStagingFileSystem: StagingFileSystem, @unchecked Sendable {
    public static let shared = FileManagerStagingFileSystem()
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func createFile(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    public func fileSize(atPath path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }
    public func isRegularFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return true
    }
    public func isSymbolicLink(atPath path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }
    public func listFileNames(at url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }
    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    public func rename(from: URL, to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
    }
    public func write(at offset: Int64, data: Data, to url: URL) throws {
        guard let handle = try? FileHandle(forUpdating: url) else {
            throw AttachmentStagingError(.writeFailed)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        try handle.write(contentsOf: data)
    }
    public func read(offset: Int64, length: Int, from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: max(0, length)) ?? Data()
        } catch {
            return nil
        }
    }
    public func sync(_ url: URL) throws {
        guard let handle = try? FileHandle(forUpdating: url) else {
            throw AttachmentStagingError(.writeFailed)
        }
        defer { try? handle.close() }
        try handle.synchronize()
    }
    public func availableCapacity(atPath path: String) -> Int64? {
        // The staging directories are created lazily; volume free space is
        // identical for a not-yet-created leaf, so resolve the NEAREST
        // EXISTING ancestor instead of failing the pre-IO disk check closed.
        var candidate = URL(fileURLWithPath: path)
        while (try? candidate.checkResourceIsReachable()) != true {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: candidate.path)
        return attributes?[.systemFreeSize] as? Int64
    }
}

// MARK: - Sanitization

/// Bounded sanitization of the UNTRUSTED name/MIME hints the platform host
/// reports from a picked URI. The rules mirror the original chat name guard
/// (ChatAttachmentOpen.swift:26-33) and extend it with byte-budget clamps.
public enum StagingNameSanitizer {
    /// Never returns nil: an unusable hint degrades to the staging-ID
    /// derived fallback name. Traversal/absolute spellings are stripped to
    /// their last component and `.`/`..` collapse to the fallback.
    public static func sanitize(displayNameHint: String?,
                                fallbackStagingID: UUID) -> String {
        var candidate = (displayNameHint ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
        if candidate.hasPrefix("/") || candidate.hasPrefix("~")
            || candidate.contains("/") || candidate.contains("\\") {
            candidate = candidate
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last.map(String.init) ?? ""
        }
        var view = String.UnicodeScalarView()
        for scalar in candidate.unicodeScalars
        where !CharacterSet.controlCharacters.contains(scalar) && scalar != "\u{0}" {
            view.append(scalar)
        }
        candidate = String(view)
        if candidate == "." || candidate == ".." { candidate = "" }
        if candidate.isEmpty {
            candidate = "attachment-\(fallbackStagingID.uuidString.prefix(8))"
        }
        // Clamp to the byte budget WITHOUT splitting a Unicode scalar.
        var bytes = 0
        var clamped = String.UnicodeScalarView()
        for scalar in candidate.unicodeScalars {
            let size = Utf8Encoding.size(scalar)
            if bytes + size > AttachmentStagingLimits.maximumDisplayNameBytes { break }
            bytes += size
            clamped.append(scalar)
        }
        let result = String(clamped)
        return result.isEmpty ? "attachment-\(fallbackStagingID.uuidString.prefix(8))"
                              : result
    }

    /// The MIME hint is a LOWERCASE-ASCII sanitized, byte-clamped untrusted
    /// class hint. Kind is DERIVED from it against the closed original
    /// `AttachmentRef.Kind` raw vocabulary; a caller hint can never widen it.
    public static func derive(mimeTypeHint: String?, declaredKindHint: String?)
        -> (mime: String, kind: String) {
        var view = String.UnicodeScalarView()
        for scalar in (mimeTypeHint ?? "").unicodeScalars
        where scalar.value >= 0x20 && scalar.value < 0x7F {
            view.append(scalar)
        }
        var text = String(view)
        if text.utf8.count > AttachmentStagingLimits.maximumMIMEBytes {
            var bytes = 0
            var clamped = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if bytes + 1 > AttachmentStagingLimits.maximumMIMEBytes { break }
                bytes += 1
                clamped.append(scalar)
            }
            text = String(clamped)
        }
        let lower = text.lowercased()
        let derived: String
        if lower.hasPrefix("image/") { derived = "image" }
        else if lower.hasPrefix("audio/") { derived = "audio" }
        else if lower.isEmpty || lower == "application/octet-stream" { derived = "other" }
        else { derived = "document" }
        let closed: Set<String> = ["image", "document", "audio", "other"]
        // The bytes-derived class wins over any declared hint; the declared
        // hint is consulted ONLY when the MIME cannot classify.
        let kind = closed.contains(derived) ? derived
            : (declaredKindHint.flatMap { closed.contains($0) ? $0 : nil } ?? "other")
        return (text.isEmpty ? "application/octet-stream" : lower, kind)
    }
}

/// Scalar-safe UTF-8 byte size without allocating per-scalar Data.
enum Utf8Encoding {
    static func size(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x00...0x7F: return 1
        case 0x80...0x7FF: return 2
        case 0x800...0xFFFF: return 3
        default: return 4
        }
    }
}

// MARK: - The staging service actor

/// Process-local, generation-scoped staging authority. One instance per
/// accepted epoch, installed by Main's generation composition AFTER the
/// owned store is ready and retired with the generation. All state is
/// actor-isolated; JNI/binder callers never hold a continuation — model
/// commands receive receipts and settle through the standard effect pump.
///
/// Threading discipline (RB1 precedent): a lock-guarded class, not an actor,
/// so the synchronous JNI ingress/egress pumps run short critical sections
/// WITHOUT an await hop and without ever holding a continuation. No lock is
/// held across a `store` await; DB-bound flows lock-validate, release,
/// await the guarded store seam, then lock-apply the settled truth. The
/// lock order is staging -> owned-work registry -> lifecycle (the reviewed
/// direction); the lifecycle never enters this lane while holding its lock.
public final class AttachmentStagingService: @unchecked Sendable {

    private let lock = NSLock()

    /// Short critical section helper (RB1 reviewed lock style). NEVER use
    /// this around an await.
    private func inside<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public struct Components: Sendable {
        /// The EXACT accepted root/epoch this service may touch. Derived
        /// from RB1's `RuntimeOwnerIdentity`, never from an envelope.
        public let identity: RuntimeOwnerIdentity
        /// The original conversation store plus this lane's two additive CAS
        /// seams (RuntimeFacadeAttachmentCommit.swift).
        public let store: any AttachmentCommittingStore
        public let ownedWork: any StagingOwnedWorkAttaching
        public let files: any StagingFileSystem
        public let now: @Sendable () -> Date
        public init(identity: RuntimeOwnerIdentity,
                    store: any AttachmentCommittingStore,
                    ownedWork: any StagingOwnedWorkAttaching =
                        RuntimeOwnedWorkRegistryStagingAttach.shared,
                    files: any StagingFileSystem = .floeStaging,
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.identity = identity
            self.store = store
            self.ownedWork = ownedWork
            self.files = files
            self.now = now
        }
    }

    public enum BeginOutcome: Sendable, Equatable {
        case opened(ingressReceipt: String, stagingID: String)
        case refused(AttachmentStagingCode)
    }
    public enum WriteOutcome: Sendable, Equatable {
        case accepted(writtenTotal: Int)
        case refused(AttachmentStagingCode)
    }
    public enum PublishOutcome: Sendable, Equatable {
        case published(view: StagedRecordView)
        case refused(AttachmentStagingCode)
    }

    // MARK: Stored state

    let components: Components
    private let salt: Data
    private let attachmentsDirectory: URL
    private let tempDirectory: URL
    private let manifestURL: URL
    private var routes: [String: StagingRoute] = [:]
    private var routeOrder: [String] = []

    private struct Ingress {
        let stagingID: UUID
        let routeReceipt: String
        var ownedWorkReceipt: String?
        var counted: Int
        var digest: SHA256
        var cancelled: Bool
        var finished: Bool
        var displayNameHint: String?
        var mimeHint: String?
        var kindHint: String?
        var startedAt: Date
    }

    private var ingresses: [String: Ingress] = [:]
    private var ingressByKey: [UUID: String] = [:]
    private var records: [UUID: StagedRecord] = [:]
    private var handleToStagingID: [String: UUID] = [:]
    private var leases: [String: StagedLease] = [:]
    private var stagedAggregateBytes = 0
    private var closed = false

    /// Streaming counters surfaced to the bounded-memory tests (ACTUAL chunk
    /// counts through the file seam — not a dictionary-only mock).
    public struct Counters: Sendable, Equatable {
        public var chunksAccepted = 0
        public var bytesIngressed = 0
        public var publishes = 0
        public var discards = 0
        public var refusedBeforeFileEffect = 0
    }
    public private(set) var counters = Counters()

    // MARK: Init + reconcile

    public init(components: Components) {
        self.components = components
        var random = Data(count: 16)
        for index in random.indices { random[index] = UInt8.random(in: 0...255) }
        self.salt = random
        let root = URL(fileURLWithPath: components.identity.root.path, isDirectory: true)
        self.attachmentsDirectory = root.appendingPathComponent("Attachments",
                                                                isDirectory: true)
        self.tempDirectory = attachmentsDirectory
            .appendingPathComponent(".staging-tmp", isDirectory: true)
        self.manifestURL = root
            .appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    /// Bounded startup reconciliation of THIS lane's own uncommitted
    /// staging, driven ONLY by the owned manifest + exact single-row store
    /// lookups:
    /// * no live ingress survives a process restart: every temp in
    ///   `.staging-tmp` is removed EXCEPT one matching a `.readyToPublish`
    ///   manifest record, whose deterministic publish (same stagingID, same
    ///   derived path) is completed after size+digest verification;
    /// * `.staged` manifest records whose file exists with matching size are
    ///   re-admitted with FRESH process handles (old handles are dead);
    /// * committed bytes are NEVER pruned because a RAM handle went away;
    /// * a `.rowCommitted`/`.consumed` record whose exact row provably no
    ///   longer exists keeps its file (conservative: only the RB3 deletion
    ///   lifecycle may remove conversation-owned bytes, via
    ///   `cleanupDeletedConversation(attachmentIDs:)`).
    public func reconcile() async -> [String: Int] {
        // Phase 1 — synchronous, lock-guarded: manifest/file work and RAM
        // re-admission. Phase 2 — awaits the ORIGINAL store for committed-row
        // truth (counters only; no state is deleted on this pass).
        var outcome: [String: Int] = ["recovered": 0, "completed": 0, "tempRemoved": 0,
                                      "orphansKept": 0, "rowsVerified": 0]
        var committedChecks: [UUID] = []
        inside {
            guard !closed else { return }
            try? components.files.createDirectory(at: attachmentsDirectory)
            try? components.files.createDirectory(at: tempDirectory)
            var manifest = StagingManifest.load(from: manifestURL, files: components.files)
            var keepTempIDs: Set<String> = []
            for entry in manifest.entries {
                guard let id = UUID(uuidString: entry.stagingID) else { continue }
                if entry.state == StagedState.readyToPublish.rawValue {
                    keepTempIDs.insert(entry.stagingID)
                    if completePublishFromManifest(entry) != nil {
                        manifest.upsert(state: .staged, stagingID: entry.stagingID)
                        outcome["completed", default: 0] += 1
                        outcome["recovered", default: 0] += 1
                    } else {
                        manifest.upsert(state: .failed, stagingID: entry.stagingID)
                        keepTempIDs.remove(entry.stagingID)
                    }
                    continue
                }
                if entry.state == StagedState.staged.rawValue {
                    let url = stagedURL(stagingID: id, name: entry.displayName)
                    if components.files.isRegularFile(atPath: url.path),
                       !components.files.isSymbolicLink(atPath: url.path),
                       components.files.fileSize(atPath: url.path) == entry.byteCount {
                        reAdmit(entry: entry)
                        outcome["recovered", default: 0] += 1
                    } else {
                        // File vanished out-of-band: the record fails honestly;
                        // the DB was never told, so any later row is guarded by
                        // its own digest re-verification at read time.
                        manifest.upsert(state: .failed, stagingID: entry.stagingID)
                    }
                    continue
                }
                if entry.state == StagedState.rowCommitted.rawValue
                    || entry.state == StagedState.consumed.rawValue {
                    committedChecks.append(id)
                }
            }
            manifest.prune()
            manifest.save(to: manifestURL, files: components.files)
            // Owned temp sweep: ONLY files named by a staging UUID this lane
            // owns and kept by no manifest entry. Nothing else is scanned.
            for name in components.files.listFileNames(at: tempDirectory)
                where !keepTempIDs.contains(name) {
                guard let id = UUID(uuidString: name) else { continue }
                if records[id] == nil, ingressByKey[id] == nil,
                   components.files.isRegularFile(
                        atPath: tempDirectory.appendingPathComponent(name).path) {
                    try? components.files.removeItem(
                        at: tempDirectory.appendingPathComponent(name))
                    outcome["tempRemoved", default: 0] += 1
                }
            }
        }
        for id in committedChecks {
            if (try? await components.store.attachment(id: id)) != nil {
                outcome["rowsVerified", default: 0] += 1
            } else {
                outcome["orphansKept", default: 0] += 1
            }
        }
        return outcome
    }

    // MARK: Route registration (trusted JNI)

    public func registerRoute(_ descriptor: ComposeRouteDescriptor) -> StagingRoute? {
        return inside {
            guard !closed else { return nil }
            guard descriptor.incarnation > 0 else { return nil }
            if descriptor.isTemporarySession {
                // Temporary sessions never hold a staging route: the RAM
                // incarnation is owned by RB5 and attachments are unavailable
                // BEFORE any source open/file write. Registering would lie.
                counters.refusedBeforeFileEffect += 1
                return nil
            }
            let receipt = AttachmentReceipt.mint(
                prefix: AttachmentReceipt.routePrefix, salt: salt,
                fields: [descriptor.conversationID.map { $0.uuidString } ?? "new",
                         String(descriptor.incarnation),
                         String(components.identity.epoch)])
            let route = StagingRoute(receipt: receipt, epoch: components.identity.epoch,
                                     descriptor: descriptor)
            routes[receipt] = route
            routeOrder.append(receipt)
            while routeOrder.count > 32 {
                let old = routeOrder.removeFirst()
                routes.removeValue(forKey: old)
            }
            return route
            }
    }

    /// Navigation-away / root shutdown for one route: aborts ONLY that
    /// route's live in-flight ingresses (typed, pre-first-byte where
    /// possible) and invalidates the route receipt. NORMAL staged records of
    /// the route SURVIVE until explicit discard/consumption — UI
    /// reconstruction/background/lock are not navigation deletion; a later
    /// same-conversation route re-registers (new incarnation) and re-mints
    /// handles from the durable manifest re-admission.
    public func closeRoute(receipt: String) {
        inside {
            guard routes[receipt] != nil else { return }
            for (key, ingress) in ingresses where ingress.routeReceipt == receipt {
                abortIngressLocked(key, finalState: .cancelled)
            }
            routes.removeValue(forKey: receipt)
            if let index = routeOrder.firstIndex(of: receipt) { routeOrder.remove(at: index) }
            }
    }

    // MARK: Ingress lifecycle (trusted JNI; bounded streams)

    /// Open one bounded ingress under a live route. EVERY refusal returns a
    /// typed code BEFORE the temp file exists: temporary routes, stale or
    /// unknown routes, wrong epoch, saturation and low free space never
    /// touch a source and never create a file (asserted by the
    /// zero-file-effect tests through the seam counters).
    ///
    /// `reusingStagingID`: the retry flow ("same attachment id, host
    /// re-derives bytes") passes the failed staging identity it is
    /// re-deriving. Reuse is refused for any id with a live record/ingress
    /// and for cross-conversation ids; the durable path stays keyed by the
    /// SAME UUID so the original id semantics hold.
    public func beginIngress(routeReceipt: String,
                             reusingStagingID: String? = nil) -> BeginOutcome {
        return inside {
            guard !closed else { return .refused(.notInstalled) }
            guard let route = routes[routeReceipt] else { return .refused(.routeUnknown) }
            if route.descriptor.isTemporarySession {
                counters.refusedBeforeFileEffect += 1
                return .refused(.temporaryRefused)
            }
            guard route.epoch == components.identity.epoch else {
                return .refused(.generationFenced)
            }
            guard ingresses.count < AttachmentStagingLimits.maximumLiveIngress,
                  records.count + ingresses.count
                    < AttachmentStagingLimits.maximumStagedRecords else {
                counters.refusedBeforeFileEffect += 1
                return .refused(.saturated)
            }
            guard freeSpaceOK() else {
                counters.refusedBeforeFileEffect += 1
                return .refused(.diskFull)
            }
            var stagingID = UUID()
            if let reusing = reusingStagingID {
                guard let reused = UUID(uuidString: reusing) else {
                    return .refused(.payloadInvalid)
                }
                guard records[reused] == nil, ingressByKey[reused] == nil else {
                    return .refused(.stateConflict)
                }
                let manifestEntry = StagingManifest
                    .load(from: manifestURL, files: components.files)
                    .entries.first { $0.stagingID == reused.uuidString }
                if let manifestEntry,
                   manifestEntry.state != StagedState.failed.rawValue,
                   manifestEntry.state != StagedState.cancelled.rawValue,
                   manifestEntry.state != StagedState.ingressing.rawValue {
                    return .refused(.stateConflict)
                }
                if let owner = manifestEntry?.routeConversationID,
                   let conversationID = route.descriptor.conversationID,
                   owner != conversationID.uuidString {
                    return .refused(.wrongOwner)
                }
                stagingID = reused
            }
            // Owned work BEFORE the first file effect.
            let ownerID = route.descriptor.conversationID.map { $0.uuidString }
                ?? stagingID.uuidString
            switch components.ownedWork.attach(epoch: components.identity.epoch,
                                               ownerID: ownerID) {
            case .attached(let token):
                let key = AttachmentReceipt.mint(prefix: AttachmentReceipt.ingressPrefix,
                                                 salt: salt,
                                                 fields: [stagingID.uuidString])
                installIngress(stagingID: stagingID, routeReceipt: routeReceipt,
                               ingressReceipt: key, ownedWorkReceipt: token.receipt)
                return .opened(ingressReceipt: key, stagingID: stagingID.uuidString)
            case .rejected, .invalidIdentity:
                counters.refusedBeforeFileEffect += 1
                return .refused(.generationFenced)
            }
            }
    }

    private func installIngress(stagingID: UUID, routeReceipt: String,
                                ingressReceipt: String, ownedWorkReceipt: String) {
        let tempURL = tempDirectory.appendingPathComponent(stagingID.uuidString)
        try? components.files.createDirectory(at: tempDirectory)
        try? components.files.createFile(at: tempURL)
        ingresses[ingressReceipt] = Ingress(stagingID: stagingID,
                                            routeReceipt: routeReceipt,
                                            ownedWorkReceipt: ownedWorkReceipt,
                                            counted: 0, digest: SHA256(),
                                            cancelled: false, finished: false,
                                            displayNameHint: nil, mimeHint: nil,
                                            kindHint: nil, startedAt: components.now())
        ingressByKey[stagingID] = ingressReceipt
        let routeConversation = routes[routeReceipt]?.descriptor.conversationID
        upsertManifest(StagingManifest.Entry(
            stagingID: stagingID.uuidString,
            state: StagedState.ingressing.rawValue,
            routeConversationID: routeConversation.map { $0.uuidString },
            displayName: "", mimeType: "", kind: "other",
            byteCount: 0, sha256: "", createdAt: components.now()))
    }

    /// One bounded chunk of the REAL source stream (never a JSON channel).
    /// The digest, byte count and free-space watermark update per chunk; a
    /// flagged cancel takes effect on the next chunk; an interrupted pump
    /// leaves a typed-failed session, never a half-published staged file.
    public func writeIngress(ingressReceipt: String, chunk: Data) -> WriteOutcome {
        return inside {
            guard !closed, var ingress = ingresses[ingressReceipt] else {
                return .refused(.ingressUnknown)
            }
            guard !ingress.cancelled, !ingress.finished else {
                return .refused(.stateConflict)
            }
            guard chunk.count > 0,
                  chunk.count <= AttachmentStagingLimits.maximumChunkBytes else {
                return .refused(.payloadInvalid)
            }
            guard ingress.counted + chunk.count <= AttachmentStagingLimits.maximumStagedBytes
            else { return .refused(.sizeExceeded) }
            let projected = stagedAggregateBytes + projectedIngressBytes() + chunk.count
            guard projected <= AttachmentStagingLimits.maximumStagedAggregateBytes
            else { return .refused(.aggregateExceeded) }
            guard freeSpaceOK() else {
                abortIngressLocked(ingressReceipt, finalState: .failed)
                return .refused(.diskFull)
            }
            // The temp path is derived ONLY from the minted staging UUID; no
            // caller-provided name can redirect this write.
            let tempURL = tempDirectory.appendingPathComponent(ingress.stagingID.uuidString)
            do {
                try components.files.write(at: Int64(ingress.counted), data: chunk,
                                           to: tempURL)
            } catch {
                abortIngressLocked(ingressReceipt, finalState: .failed)
                return .refused(.writeFailed)
            }
            ingress.digest.update(data: chunk)
            ingress.counted += chunk.count
            ingresses[ingressReceipt] = ingress
            counters.chunksAccepted += 1
            counters.bytesIngressed += chunk.count
            return .accepted(writtenTotal: ingress.counted)
            }
    }

    /// EOF: fsync the temp, clamp+record the untrusted hints, flip the
    /// durable manifest to `.readyToPublish`. The atomic rename+verify runs
    /// at the `attachment.stage` publish so a crash in between stays
    /// recoverable — the bytes are neither lost nor half-committed.
    public func endIngress(ingressReceipt: String, displayNameHint: String?,
                           mimeHint: String?, kindHint: String?) -> AttachmentStagingCode? {
        return inside {
            guard !closed, var ingress = ingresses[ingressReceipt] else {
                return .ingressUnknown
            }
            guard !ingress.cancelled, !ingress.finished else { return .stateConflict }
            guard ingress.counted > 0 else { return .sourceUnavailable }
            let tempURL = tempDirectory.appendingPathComponent(ingress.stagingID.uuidString)
            do {
                try components.files.sync(tempURL)
            } catch {
                abortIngressLocked(ingressReceipt, finalState: .failed)
                return .writeFailed
            }
            guard components.files.fileSize(atPath: tempURL.path) == ingress.counted else {
                abortIngressLocked(ingressReceipt, finalState: .failed)
                return .digestMismatch
            }
            ingress.finished = true
            ingress.displayNameHint = displayNameHint
            ingress.mimeHint = mimeHint
            ingress.kindHint = kindHint
            ingresses[ingressReceipt] = ingress
            let sanitized = StagingNameSanitizer.sanitize(
                displayNameHint: displayNameHint, fallbackStagingID: ingress.stagingID)
            let derived = StagingNameSanitizer.derive(mimeTypeHint: mimeHint,
                                                      declaredKindHint: kindHint)
            upsertManifest(StagingManifest.Entry(
                stagingID: ingress.stagingID.uuidString,
                state: StagedState.readyToPublish.rawValue,
                routeConversationID: routes[ingress.routeReceipt]?
                    .descriptor.conversationID.map { $0.uuidString },
                displayName: sanitized, mimeType: derived.mime, kind: derived.kind,
                byteCount: ingress.counted,
                sha256: ingress.digest.finalize().map { String(format: "%02x", $0) }.joined(),
                createdAt: ingress.startedAt))
            return nil
            }
    }

    /// Host fast abort of a live ingress (used behind
    /// `attachment.staging.cancel` and chunk-pump interruption): closes the
    /// stream, removes the temp, detaches owned work. Never touches another
    /// route and never deletes a published file.
    public func abortIngress(ingressReceipt: String) -> AttachmentStagingCode? {
        return inside {
            guard ingresses[ingressReceipt] != nil else { return .ingressUnknown }
            abortIngressLocked(ingressReceipt, finalState: .cancelled)
            return nil
            }
    }

    private func abortIngressLocked(_ ingressReceipt: String,
                                    finalState: StagedState) {
        guard let ingress = ingresses.removeValue(forKey: ingressReceipt) else { return }
        ingressByKey.removeValue(forKey: ingress.stagingID)
        if let receipt = ingress.ownedWorkReceipt {
            let ownerID = routes[ingress.routeReceipt]?.descriptor.conversationID
                .map { $0.uuidString } ?? ingress.stagingID.uuidString
            _ = components.ownedWork.detach(receipt: receipt,
                                            epoch: components.identity.epoch,
                                            ownerID: ownerID)
        }
        let tempURL = tempDirectory.appendingPathComponent(ingress.stagingID.uuidString)
        if components.files.isRegularFile(atPath: tempURL.path) {
            try? components.files.removeItem(at: tempURL)
        }
        markManifestState(stagingID: ingress.stagingID.uuidString, state: finalState)
    }

    // MARK: Publish (drives attachment.stage)

    /// Publish one finished ingress: derive the final path
    /// `Attachments/<stagingID>/<sanitized name>`, atomic rename, verify
    /// size and (on replay) digest, mint the process handle. A failed
    /// publish preserves recoverable staged bytes: the temp stays and the
    /// manifest keeps the honest state; nothing half-written becomes staged.
    public func publish(ingressReceipt: String) -> PublishOutcome {
        return inside {
            guard !closed else { return .refused(.notInstalled) }
            guard let ingress = ingresses[ingressReceipt] else { return .refused(.ingressUnknown) }
            guard ingress.finished, !ingress.cancelled else {
                return .refused(.ingressUnfinished)
            }
            guard let route = routes[ingress.routeReceipt] else {
                return .refused(.routeStale)
            }
            let digestHex = ingress.digest.finalize()
                .map { String(format: "%02x", $0) }.joined()
            let name = StagingNameSanitizer.sanitize(
                displayNameHint: ingress.displayNameHint,
                fallbackStagingID: ingress.stagingID)
            let derived = StagingNameSanitizer.derive(mimeTypeHint: ingress.mimeHint,
                                                      declaredKindHint: ingress.kindHint)
            let finalURL = stagedURL(stagingID: ingress.stagingID, name: name)
            do {
                try components.files.createDirectory(
                    at: finalURL.deletingLastPathComponent())
            } catch {
                return .refused(.renameFailed)
            }
            let tempURL = tempDirectory.appendingPathComponent(ingress.stagingID.uuidString)
            if components.files.isRegularFile(atPath: finalURL.path) {
                // Replay after a crash between rename and record: verify the
                // existing bytes; never overwrite anything.
                guard components.files.fileSize(atPath: finalURL.path) == ingress.counted,
                      let data = readAllBounded(url: finalURL),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                        == digestHex else {
                    return .refused(.digestMismatch)
                }
                try? components.files.removeItem(at: tempURL)
            } else {
                guard components.files.fileSize(atPath: tempURL.path) == ingress.counted
                else { return .refused(.digestMismatch) }
                do {
                    try components.files.rename(from: tempURL, to: finalURL)
                } catch {
                    return .refused(.renameFailed)
                }
            }
            guard components.files.fileSize(atPath: finalURL.path) == ingress.counted,
                  !components.files.isSymbolicLink(atPath: finalURL.path) else {
                return .refused(.digestMismatch)
            }
            // File effect settled: retire the session and its owned work.
            ingresses.removeValue(forKey: ingressReceipt)
            ingressByKey.removeValue(forKey: ingress.stagingID)
            if let receipt = ingress.ownedWorkReceipt {
                let ownerID = route.descriptor.conversationID.map { $0.uuidString }
                    ?? ingress.stagingID.uuidString
                _ = components.ownedWork.detach(receipt: receipt,
                                                epoch: components.identity.epoch,
                                                ownerID: ownerID)
            }
            let handle = AttachmentReceipt.mint(prefix: AttachmentReceipt.stagingPrefix,
                                                salt: salt,
                                                fields: [ingress.stagingID.uuidString,
                                                         route.receipt])
            let record = StagedRecord(
                stagingID: ingress.stagingID, handle: handle,
                routeReceipt: ingress.routeReceipt,
                routeConversationID: route.descriptor.conversationID,
                routeIncarnation: route.descriptor.incarnation,
                epoch: components.identity.epoch,
                kind: derived.kind, displayName: name, mimeType: derived.mime,
                byteCount: ingress.counted, sha256: digestHex,
                relativePath: ingress.stagingID.uuidString + "/" + name,
                state: .staged, createdAt: ingress.startedAt,
                launchMarkedCorrelation: nil)
            records[record.stagingID] = record
            handleToStagingID[handle] = record.stagingID
            stagedAggregateBytes += record.byteCount
            counters.publishes += 1
            upsertManifest(StagingManifest.Entry(
                stagingID: record.stagingID.uuidString,
                state: StagedState.staged.rawValue,
                routeConversationID: record.routeConversationID.map { $0.uuidString },
                displayName: record.displayName, mimeType: record.mimeType,
                kind: record.kind, byteCount: record.byteCount,
                sha256: record.sha256, createdAt: record.createdAt))
            return .published(view: record.view)
            }
    }

    /// Internal recovery publish for a `.readyToPublish` manifest entry
    /// (restart path). The temp still holds the exact streamed bytes; the
    /// manifest holds size + digest, so the completion is verifiable without
    /// the (dead) process state.
    private func completePublishFromManifest(_ entry: StagingManifest.Entry)
        -> StagedRecordView? {
        guard let id = UUID(uuidString: entry.stagingID) else { return nil }
        let tempURL = tempDirectory.appendingPathComponent(entry.stagingID)
        let finalURL = stagedURL(stagingID: id, name: entry.displayName)
        guard components.files.isRegularFile(atPath: tempURL.path),
              components.files.fileSize(atPath: tempURL.path) == entry.byteCount,
              entry.sha256.count == 64 else {
            if components.files.isRegularFile(atPath: finalURL.path),
               components.files.fileSize(atPath: finalURL.path) == entry.byteCount {
                reAdmit(entry: entry)
                return records[id]?.view
            }
            return nil
        }
        if let data = readAllBounded(url: tempURL) {
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                    == entry.sha256 else { return nil }
        } else {
            return nil
        }
        do {
            if !components.files.isRegularFile(atPath: finalURL.path) {
                try components.files.createDirectory(at: finalURL.deletingLastPathComponent())
                try components.files.rename(from: tempURL, to: finalURL)
            } else {
                try components.files.removeItem(at: tempURL)
            }
        } catch {
            return nil
        }
        reAdmit(entry: entry)
        return records[id]?.view
    }

    // MARK: Views / reads

    public func snapshot(handle: String) -> StagedRecordView? {
        return inside {
            guard let id = handleToStagingID[handle], let record = records[id] else { return nil }
            return record.view
            }
    }

    public func snapshot(stagingID: String) -> StagedRecordView? {
        return inside {
            guard let id = UUID(uuidString: stagingID), let record = records[id] else {
                return nil
            }
            return record.view
            }
    }

    /// Bounded staged-bytes page for the TRUSTED host only (preview). No
    /// JSON channel carries these bytes. Offsets are absolute file offsets.
    public func readStaged(handle: String, offset: Int64, maxBytes: Int) -> Data? {
        return inside {
            guard maxBytes >= 0, maxBytes <= AttachmentStagingLimits.maximumChunkBytes,
                  let id = handleToStagingID[handle], let record = records[id],
                  record.state == .staged || record.state == .reserved else { return nil }
            guard offset >= 0, offset <= Int64(record.byteCount) else { return nil }
            let url = stagedURL(stagingID: id, name: record.displayName)
            let length = min(maxBytes, record.byteCount - Int(offset))
            return components.files.read(offset: offset, length: length, from: url)
            }
    }

    /// In-process progress of a live ingress — the authoritative counter the
    /// host projects into its own UI row (the wire never needs the fraction
    /// because the host already streams).
    public func ingressProgress(ingressReceipt: String) -> (bytes: Int,
                                                             finished: Bool,
                                                             cancelled: Bool)? {
        return inside {
            guard let ingress = ingresses[ingressReceipt] else { return nil }
            return (ingress.counted, ingress.finished, ingress.cancelled)
            }
    }

    // MARK: Discard / cancel

    /// `attachment.staging.discard`: removes a STAGED record's bytes and
    /// fails-typed every other state. A launch-marked or leased record is
    /// refused so a consumed file is never deleted and a late discard can
    /// never race a launch; a published-but-committed record can only be
    /// removed by the ordinary conversation lifecycle (RB3), never here.
    public func discard(handle: String) -> AttachmentStagingCode? {
        return inside {
            guard let id = handleToStagingID[handle], let record = records[id] else {
                return .handleUnknown
            }
            switch record.state {
            case .staged:
                break
            case .reserved, .consumed, .rowCommitted:
                return .alreadyConsumed
            default:
                return .stateConflict
            }
            guard record.launchMarkedCorrelation == nil else { return .launchMarked }
            removeStagedBytesLocked(id: id, record: record)
            records.removeValue(forKey: id)
            handleToStagingID.removeValue(forKey: record.handle)
            stagedAggregateBytes -= record.byteCount
            counters.discards += 1
            removeManifestEntry(stagingID: id.uuidString)
            return nil
            }
    }

    /// `attachment.staging.cancel` (model-visible path): cancels a LIVE
    /// ingress by staging identity. A finished-but-unpublished session is
    /// aborted too (bytes were never published); staged records require
    /// `discard` — the two truths are never conflated.
    public func cancelIngress(stagingID: String) -> AttachmentStagingCode? {
        return inside {
            guard let id = UUID(uuidString: stagingID) else { return .payloadInvalid }
            if let key = ingressByKey[id] {
                abortIngressLocked(key, finalState: .cancelled)
                return nil
            }
            if records[id] != nil { return .stateConflict }
            return .ingressUnknown
            }
    }

    private func removeStagedBytesLocked(id: UUID, record: StagedRecord) {
        let url = stagedURL(stagingID: id, name: record.displayName)
        if components.files.isRegularFile(atPath: url.path) {
            try? components.files.removeItem(at: url)
        }
        // Remove the per-attachment directory ONLY if it is ours and empty
        // (never a parent sweep, never with unknown files inside).
        let directory = url.deletingLastPathComponent()
        if directory.lastPathComponent == id.uuidString,
           components.files.listFileNames(at: directory).isEmpty {
            try? components.files.removeItem(at: directory)
        }
    }

    // MARK: Launch lease API (typed reservation + commit-once + rollback)

    /// Reserve exact owned staged handles for one launch BEFORE any DB
    /// effect. All-or-nothing: any conflict refuses the whole reservation so
    /// the transaction never sees a partially held set. Double-launch of the
    /// same handle is refused here (typed `stateConflict`), and the original
    /// PK/transaction remains the durable backstop.
    public func reserveLaunchLease(handles: [String], conversationID: UUID?,
                                   correlation: String) -> Result<StagedLease,
                                                                   AttachmentStagingError> {
        return inside {
            guard !closed else { return .failure(AttachmentStagingError(.notInstalled)) }
            guard !handles.isEmpty,
                  handles.count <= AttachmentStagingLimits.maximumHandlesPerOperation
            else { return .failure(AttachmentStagingError(.payloadInvalid)) }
            var stagedIDs: [UUID] = []
            for handle in handles {
                guard let id = handleToStagingID[handle], let record = records[id] else {
                    return .failure(AttachmentStagingError(.handleUnknown))
                }
                guard record.state == .staged, record.launchMarkedCorrelation == nil else {
                    return .failure(AttachmentStagingError(.stateConflict))
                }
                if let owner = record.routeConversationID, let conversationID,
                   owner != conversationID {
                    return .failure(AttachmentStagingError(.wrongOwner))
                }
                // Temporary routes can never have produced staged records (the
                // begin gate refuses pre-IO and registerRoute refuses at
                // registration), so no extra probe is needed here.
                stagedIDs.append(id)
            }
            let leaseID = AttachmentReceipt.mint(prefix: AttachmentReceipt.leasePrefix,
                                                 salt: salt,
                                                 fields: [correlation,
                                                         handles.joined(separator: ",")])
            let lease = StagedLease(leaseID: leaseID, correlation: correlation,
                                    epoch: components.identity.epoch,
                                    targetConversationID: conversationID,
                                    handles: handles, stagingIDs: stagedIDs)
            for id in stagedIDs {
                records[id]?.state = .reserved
                records[id]?.launchMarkedCorrelation = correlation
            }
            leases[leaseID] = lease
            return .success(lease)
            }
    }

    /// The staged-handle → ORIGINAL AttachmentRef projection: conversation/
    /// message ids stay nil here; the prepare transaction binds them.
    public func attachmentRef(for record: StagedRecord) -> AttachmentRef {
        inside { Self.attachmentRefLocked(for: record) }
    }

    /// Lock-held projection shared by `attachmentRef(for:)` and
    /// `refs(forLease:)`. `NSLock` is NON-recursive: the previous
    /// `refs(forLease:)` -> `attachmentRef(for:)` nesting re-entered the
    /// same lock and deadlocked the launch path (Main-identified defect).
    private static func attachmentRefLocked(for record: StagedRecord) -> AttachmentRef {
        AttachmentRef(
            id: record.stagingID,
            conversationID: nil,
            messageID: nil,
            kind: AttachmentRef.Kind(rawValue: record.kind) ?? .other,
            displayName: record.displayName,
            uti: record.mimeType,
            byteCount: record.byteCount,
            sha256: record.sha256,
            storage: .applicationSupport,
            urlBookmark: nil,
            relativePath: record.relativePath,
            createdAt: record.createdAt)
    }

    /// Public lease projection for the launch adapter (needs the ref before
    /// the transaction; the ORIGINAL prepare remains the only inserter).
    /// ONE lock acquisition for the whole projection (no re-entrant call).
    public func refs(forLease lease: StagedLease) -> [AttachmentRef] {
        inside { lease.stagingIDs.compactMap { records[$0] }.map(Self.attachmentRefLocked(for:)) }
    }

    /// After the ORIGINAL prepare committed: mark consumed and un-mint the
    /// handles. A late commit for an unknown/stale lease is refused and
    /// NEVER applied to a newer generation. The staged BYTES are now the
    /// message-attachment files: this method deletes nothing, ever.
    public func commitLaunchLease(_ leaseID: String) -> AttachmentStagingCode? {
        return inside {
            guard let lease = leases[leaseID], lease.epoch == components.identity.epoch else {
                return .leaseUnknown
            }
            for id in lease.stagingIDs {
                guard var record = records[id], record.state == .reserved else { continue }
                record.state = .consumed
                record.launchMarkedCorrelation = nil
                records[id] = record
                handleToStagingID.removeValue(forKey: record.handle)
                stagedAggregateBytes -= record.byteCount
                markManifestState(stagingID: id.uuidString, state: .consumed)
            }
            leases.removeValue(forKey: leaseID)
            return nil
            }
    }

    /// Pre-commit failure path: staged bytes remain owned and reusable;
    /// handles keep their minting. Truthfully refuses AFTER the DB commit —
    /// a committed launch is never presented as "rolled back".
    public func rollbackLaunchLease(_ leaseID: String) -> AttachmentStagingCode? {
        return inside {
            guard let lease = leases[leaseID], lease.epoch == components.identity.epoch else {
                return .leaseUnknown
            }
            var released = 0
            var consumed = 0
            for id in lease.stagingIDs {
                guard var record = records[id] else { continue }
                switch record.state {
                case .reserved:
                    record.state = .staged
                    record.launchMarkedCorrelation = nil
                    records[id] = record
                    handleToStagingID[record.handle] = id
                    released += 1
                case .consumed:
                    consumed += 1
                default:
                    break
                }
            }
            leases.removeValue(forKey: leaseID)
            if released == 0, consumed > 0 { return .alreadyConsumed }
            return nil
            }
    }

    /// The PARENT RB4 binding (`RunStagedAttachmentAuthority.resolve`) marks
    /// a launch reference WITHOUT a full lease so the current resolve-only
    /// composition still protects bytes until Main's repair wires the lease
    /// API. Marked records are released by `reconcileLaunchMarked` (exact
    /// row truth) or cleared at generation retire (RAM only).
    public func markLaunchReference(handle: String, correlation: String)
        -> AttachmentStagingCode? {
        return inside {
            guard let id = handleToStagingID[handle], var record = records[id] else {
                return .handleUnknown
            }
            guard record.state == .staged else {
                if record.state == .reserved { return nil }
                return record.state == .consumed ? .alreadyConsumed : .stateConflict
            }
            record.launchMarkedCorrelation = correlation
            records[id] = record
            return nil
            }
    }

    /// Release a launch/commit mark previously taken with the SAME
    /// correlation (pre-commit rollback for the resolve-only and
    /// commit-in-flight paths). A foreign or late clear is refused and
    /// NEVER touches a newer operation's mark.
    func clearLaunchMark(handle: String, correlation: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let id = handleToStagingID[handle], var record = records[id] else { return false }
        guard record.launchMarkedCorrelation == correlation else { return false }
        record.launchMarkedCorrelation = nil
        records[id] = record
        return true
    }

    /// Ownership truth for discard-time guards: if a launch-marked record's
    /// EXACT row exists in the ORIGINAL store, the record is consumed-by-DB;
    /// otherwise the mark is stale and the record returns to staged. One
    /// indexed row lookup — no scanning, no second store.
    public func reconcileLaunchMarked(stagingID: String) async -> StagedState? {
        guard let id = UUID(uuidString: stagingID) else { return nil }
        let needsRowCheck = inside {
            guard let record = records[id] else { return false }
            return record.launchMarkedCorrelation != nil || record.state == .reserved
        }
        guard needsRowCheck else {
            return inside { records[id]?.state }
        }
        let rowExists: Bool = (try? await components.store.attachment(id: id)) != nil
        return inside {
            guard var record = records[id] else { return nil }
            if rowExists {
                let wasCounted = record.state == .reserved || record.state == .staged
                record.state = .consumed
                record.launchMarkedCorrelation = nil
                records[id] = record
                handleToStagingID.removeValue(forKey: record.handle)
                if wasCounted { stagedAggregateBytes -= record.byteCount }
                markManifestState(stagingID: id.uuidString, state: .consumed)
                return .consumed
            }
            record.state = .staged
            record.launchMarkedCorrelation = nil
            records[id] = record
            return .staged
        }
    }

    // MARK: Generation lifecycle

    public var epoch: UInt64 { components.identity.epoch }
    public var ownerIdentity: RuntimeOwnerIdentity { components.identity }

    /// Root shutdown: RB1's retirement gate already waits for the REAL
    /// registry drain, and every live ingress holds a registry token until
    /// its stream/metadata/file effect settles — so by the time this runs,
    /// IO is done. This method aborts any residual session (temps removed),
    /// invalidates ALL RAM handles/routes/leases (durable files and rows are
    /// untouched), and refuses every later call.
    public func retire() {
        inside {
            // A FINISHED (readyToPublish) ingress is durable-recoverable:
            // its bytes are fsynced and the manifest already owns the truth.
            // Aborting it here would delete recoverable bytes and mark the
            // manifest cancelled — only LIVE ingresses are aborted.
            for (key, ingress) in ingresses where !ingress.finished {
                abortIngressLocked(key, finalState: .cancelled)
            }
            ingresses.removeAll()
            routes.removeAll()
            routeOrder.removeAll()
            leases.removeAll()
            handleToStagingID.removeAll()
            records.removeAll()
            stagedAggregateBytes = 0
            closed = true
            }
    }

    public func statusCounters() -> [String: Int] {
        return inside {
            var out: [String: Int] = [:]
            out["liveIngress"] = ingresses.count
            out["stagedRecords"] = records.count
            out["liveRoutes"] = routes.count
            out["openLeases"] = leases.count
            out["stagedBytes"] = stagedAggregateBytes
            out["chunksAccepted"] = counters.chunksAccepted
            out["bytesIngressed"] = counters.bytesIngressed
            out["publishes"] = counters.publishes
            out["discards"] = counters.discards
            out["refusedBeforeFileEffect"] = counters.refusedBeforeFileEffect
            return out
            }
    }

    // MARK: - Internals

    private func freeSpaceOK() -> Bool {
        guard let free = components.files.availableCapacity(
            atPath: attachmentsDirectory.path) else { return false }
        return free >= Int64(AttachmentStagingLimits.minimumFreeBytes)
    }

    private func projectedIngressBytes() -> Int {
        ingresses.values.reduce(0) { partial, ingress in partial + ingress.counted }
    }

    func stagedURL(stagingID: UUID, name: String) -> URL {
        attachmentsDirectory
            .appendingPathComponent(stagingID.uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Strict containment check for any path derived from persisted data:
    /// rejects absolute, traversal, empty and symlinked components under the
    /// attachments directory. Used by reads/loads of staged AND committed
    /// relative paths (the same rule as the original
    /// ChatAttachmentOpenAdapter.checkedTarget + FloeArtifactStore.resolve).
    func resolveStagedPath(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return nil }
        let componentsOnly = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard componentsOnly.count == 2,
              componentsOnly.allSatisfy({ $0 != ".." && $0 != "." }),
              let dirName = componentsOnly.first, UUID(uuidString: dirName) != nil
        else { return nil }
        var url = attachmentsDirectory
        for component in componentsOnly {
            url = url.appendingPathComponent(component)
        }
        let standardized = url.standardizedFileURL
        let prefix = attachmentsDirectory.standardizedFileURL.path + "/"
        guard standardized.path.hasPrefix(prefix),
              standardized.path == url.path else { return nil }
        // No component may be a symlink (checked on the existing tree only;
        // writers always create regular files under UUID-named dirs).
        var cursor = standardized
        while cursor.path.count > prefix.count - 1 {
            if components.files.isSymbolicLink(atPath: cursor.path) { return nil }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return standardized
    }

    func readAllBounded(url: URL) -> Data? {
        guard let size = components.files.fileSize(atPath: url.path),
              size <= AttachmentStagingLimits.maximumStagedBytes else { return nil }
        var data = Data()
        var offset: Int64 = 0
        while offset < Int64(size) {
            let length = Int(min(Int64(AttachmentStagingLimits.maximumChunkBytes),
                                 Int64(size) - offset))
            guard let chunk = components.files.read(offset: offset, length: length,
                                                    from: url), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
            offset += Int64(chunk.count)
        }
        return data
    }

    // MARK: Manifest helpers (bounded owned metadata, small non-secret)

    private func reAdmit(entry: StagingManifest.Entry) {
        guard let id = UUID(uuidString: entry.stagingID) else { return }
        let handle = AttachmentReceipt.mint(prefix: AttachmentReceipt.stagingPrefix,
                                            salt: salt,
                                            fields: [id.uuidString, "readmit"])
        let name = StagingNameSanitizer.sanitize(displayNameHint: entry.displayName,
                                                 fallbackStagingID: id)
        let record = StagedRecord(
            stagingID: id, handle: handle,
            routeReceipt: "route:readmit",
            routeConversationID: entry.routeConversationID.flatMap { UUID(uuidString: $0) },
            routeIncarnation: 0,
            epoch: components.identity.epoch,
            kind: StagingNameSanitizer.derive(mimeTypeHint: entry.mimeType,
                                              declaredKindHint: entry.kind).kind,
            displayName: name, mimeType: entry.mimeType,
            byteCount: entry.byteCount, sha256: entry.sha256,
            relativePath: id.uuidString + "/" + name,
            state: .staged, createdAt: entry.createdAt,
            launchMarkedCorrelation: nil)
        records[id] = record
        handleToStagingID[handle] = id
        stagedAggregateBytes += record.byteCount
    }

    func upsertManifest(_ entry: StagingManifest.Entry) {
        var manifest = StagingManifest.load(from: manifestURL, files: components.files)
        manifest.upsert(entry)
        manifest.save(to: manifestURL, files: components.files)
    }

    func markManifestState(stagingID: String, state: StagedState) {
        var manifest = StagingManifest.load(from: manifestURL, files: components.files)
        manifest.upsert(state: state, stagingID: stagingID)
        manifest.save(to: manifestURL, files: components.files)
    }

    func removeManifestEntry(stagingID: String) {
        var manifest = StagingManifest.load(from: manifestURL, files: components.files)
        manifest.entries.removeAll { $0.stagingID == stagingID }
        manifest.save(to: manifestURL, files: components.files)
    }

    // MARK: - Committed-flow helpers (RuntimeFacadeAttachmentCommit extension)

    /// Pure file-seam passthroughs (no RAM state, no lock needed).
    func isRegularFile(atPath path: String) -> Bool {
        components.files.isRegularFile(atPath: path)
    }
    func fileSize(atPath path: String) -> Int? {
        components.files.fileSize(atPath: path)
    }
    func readFile(offset: Int64, length: Int, at url: URL) -> Data? {
        components.files.read(offset: offset, length: length, from: url)
    }
    func listFileNamesForCleanup(at url: URL) -> [String] {
        components.files.listFileNames(at: url)
    }

    /// Exact staged record lookup for the same-module commit/cancel flows.
    func stagedRecord(id: UUID) -> StagedRecord? {
        return inside {     records[id]         }
    }

    /// The durable row for `handle` exists (message_id NULL, conversation
    /// set): transition the RAM record to `.rowCommitted` and retire the
    /// handle minting. Bytes and row ownership are now DB truth; the
    /// staging lane never deletes them afterwards except via an
    /// `attachment.cancel` that proves row deletion first.
    func markRowCommitted(stagingID: UUID) {
        inside {
            guard var record = records[stagingID], record.state == .staged else { return }
            record.state = .rowCommitted
            records[stagingID] = record
            handleToStagingID.removeValue(forKey: record.handle)
            stagedAggregateBytes -= record.byteCount
            markManifestState(stagingID: stagingID.uuidString, state: .rowCommitted)
            }
    }

    /// Remove ONLY this lane's derived file path (never a scan, never a
    /// symlink target, only the empty per-attachment directory we own).
    func removeStagedFile(stagingID: UUID, name: String) {
        inside {
            let url = stagedURL(stagingID: stagingID, name: name)
            if components.files.isRegularFile(atPath: url.path) {
                try? components.files.removeItem(at: url)
            }
            let directory = url.deletingLastPathComponent()
            if directory.lastPathComponent == stagingID.uuidString,
               components.files.listFileNames(at: directory).isEmpty {
                try? components.files.removeItem(at: directory)
            }
            }
    }

    func removeStagedRecordAfterRowDeletion(id: UUID) {
        inside {
            guard let record = records.removeValue(forKey: id) else { return }
            handleToStagingID.removeValue(forKey: record.handle)
            if record.state == .staged || record.state == .reserved {
                stagedAggregateBytes -= record.byteCount
            }
            }
    }

    /// Public AttachmentRef projection for the launch adapter. ONE lock
    /// acquisition for lookup + projection: `attachmentRef(for:)` takes the
    /// same NON-recursive lock, so the projection uses the lock-held helper.
    public func attachmentRef(handle: String) -> AttachmentRef? {
        inside {
            guard let id = handleToStagingID[handle], let record = records[id] else {
                return nil
            }
            return Self.attachmentRefLocked(for: record)
        }
    }

    /// Route truth for the adapter's cross-owner guard (opaque; never a
    /// path). Returns nil for unknown handles.
    public func routeInfo(handle: String) -> (conversationID: UUID?, incarnation: UInt64,
                                              epoch: UInt64, state: StagedState,
                                              launchMarked: Bool)? {
        return inside {
            guard let id = handleToStagingID[handle], let record = records[id] else { return nil }
            return (record.routeConversationID, record.routeIncarnation, record.epoch,
                    record.state, record.launchMarkedCorrelation != nil)
            }
    }

    // MARK: - Trusted bounded image loader (host-native equivalent)

    /// Loads one staged image into the ORIGINAL `ConversationImagePart`
    /// (provider memory path only; never a bridge value). Byte budget is
    /// re-checked on the ACTUAL file, the digest re-verified by streaming
    /// the whole bounded file through the same seam, and the format
    /// detected from MAGIC (never trusted from the staged name/MIME).
    public func loadStagedInlineImage(handle: String, remainingBudget: Int)
        -> ConversationImagePart? {
        return inside {
            guard let id = handleToStagingID[handle], let record = records[id],
                  record.state == .staged || record.state == .reserved else { return nil }
            return inlineImageIfNeeded(url: stagedURL(stagingID: id, name: record.displayName),
                                       byteCount: record.byteCount,
                                       sha256: record.sha256,
                                       declaredKind: record.kind,
                                       remainingBudget: remainingBudget)
            }
    }

    /// Same loader for a committed (DB-owned) attachment row; the CALLER
    /// must have passed `verifyReadableAttachment` ownership first — this
    /// only re-validates the bytes against the durable row values.
    public func loadCommittedInlineImage(attachment: AttachmentRef,
                                         remainingBudget: Int) -> ConversationImagePart? {
        return inside {
            guard attachment.kind == .image,
                  attachment.storage == .applicationSupport,
                  let relative = attachment.relativePath,
                  let url = resolveStagedPath(relativePath: relative) else { return nil }
            return inlineImageIfNeeded(url: url, byteCount: attachment.byteCount,
                                       sha256: attachment.sha256,
                                       declaredKind: "image",
                                       remainingBudget: remainingBudget)
            }
    }

    private func inlineImageIfNeeded(url: URL, byteCount: Int, sha256: String,
                                     declaredKind: String, remainingBudget: Int)
        -> ConversationImagePart? {
        guard declaredKind == "image",
              byteCount > 0,
              byteCount <= AttachmentStagingLimits.maximumInlineImageBytes,
              // base64 grows ~4/3; the ORIGINAL bound is on the encoded form.
              byteCount * 4 / 3 + 4 <= remainingBudget else { return nil }
        guard components.files.isRegularFile(atPath: url.path),
              !components.files.isSymbolicLink(atPath: url.path),
              components.files.fileSize(atPath: url.path) == byteCount else { return nil }
        guard let data = readAllBounded(url: url), data.count == byteCount else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { return nil }
        guard let mime = AttachmentImageMagic.sniff(data) else { return nil }
        let encoded = data.base64EncodedString()
        guard encoded.utf8.count <= remainingBudget else { return nil }
        return ConversationImagePart(mimeType: mime, base64: encoded)
    }
}

/// Magic-byte format detection — the SAME four sniffs as the original
/// `ConversationHistoryAssembler.normalizedImage` (ImageIO is Apple-only;
/// on Android non-matching payloads honestly omit rather than rasterize).
public enum AttachmentImageMagic {
    public static func sniff(_ data: Data) -> String? {
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.count >= 8,
           data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.count >= 6, data.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "image/webp" }
        return nil
    }
}


// MARK: - Owned staging manifest (small non-secret recovery record)

/// The lane's OWN durable manifest — explicitly permitted by the task
/// ("explicit owned staging manifest, not second general business store").
/// Written atomically (temp + rename) under the accepted root and bounded in
/// size, it contains ONLY: staging ids, closed state names, sanitized name,
/// MIME, size, digest, route conversation id and timestamps. No URI, no
/// absolute path, no secret. It never replaces DB truth: the ORIGINAL
/// attachments table stays the durable ownership authority; the manifest
/// only describes this lane's uncommitted staging for restart
/// reconciliation.
public struct StagingManifest: Sendable {

    public struct Entry: Sendable, Codable, Equatable {
        public var stagingID: String
        public var state: String
        public var routeConversationID: String?
        public var displayName: String
        public var mimeType: String
        public var kind: String
        public var byteCount: Int
        public var sha256: String
        public var createdAt: Date
        public init(stagingID: String, state: String, routeConversationID: String?,
                    displayName: String, mimeType: String, kind: String,
                    byteCount: Int, sha256: String, createdAt: Date) {
            self.stagingID = stagingID
            self.state = state
            self.routeConversationID = routeConversationID
            self.displayName = displayName
            self.mimeType = mimeType
            self.kind = kind
            self.byteCount = byteCount
            self.sha256 = sha256
            self.createdAt = createdAt
        }
    }

    public var entries: [Entry]

    static let closedStates: Set<String> = Set(
        [StagedState.ingressing, StagedState.readyToPublish, StagedState.staged,
         StagedState.failed, StagedState.reserved, StagedState.consumed,
         StagedState.rowCommitted, StagedState.discarded, StagedState.cancelled]
            .map(\.rawValue))

    public static func load(from url: URL, files: any StagingFileSystem) -> StagingManifest {
        guard let size = files.fileSize(atPath: url.path),
              size > 0,
              size <= AttachmentStagingLimits.maximumManifestBytes,
              let data = files.read(offset: 0, length: size, from: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return StagingManifest(entries: [])
        }
        let bounded = Array(decoded.prefix(AttachmentStagingLimits.maximumStagedRecords))
        return StagingManifest(entries: bounded.filter {
            Self.closedStates.contains($0.state)
                && $0.sha256.utf8.count <= 64
                && $0.displayName.utf8.count <= AttachmentStagingLimits.maximumDisplayNameBytes
                && $0.byteCount >= 0
        })
    }

    mutating func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.stagingID == entry.stagingID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
            if entries.count > AttachmentStagingLimits.maximumStagedRecords {
                entries.removeFirst(entries.count - AttachmentStagingLimits.maximumStagedRecords)
            }
        }
    }

    /// State-only transition for an existing entry; unknown ids are ignored
    /// (the manifest never grows from a mark).
    mutating func upsert(state: StagedState, stagingID: String) {
        guard let index = entries.firstIndex(where: { $0.stagingID == stagingID }) else {
            return
        }
        entries[index].state = state.rawValue
    }

    /// Drop non-recoverable states; everything left drives reconciliation.
    mutating func prune() {
        entries.removeAll { entry in
            entry.state == StagedState.discarded.rawValue
                || entry.state == StagedState.cancelled.rawValue
        }
    }

    func save(to url: URL, files: any StagingFileSystem) {
        guard let data = try? JSONEncoder().encode(entries),
              data.count <= AttachmentStagingLimits.maximumManifestBytes else { return }
        let directory = url.deletingLastPathComponent()
        try? files.createDirectory(at: directory)
        let temp = directory.appendingPathComponent("manifest.json.tmp")
        try? files.createFile(at: temp)
        do {
            try files.write(at: 0, data: data, to: temp)
            try files.sync(temp)
            if files.isRegularFile(atPath: url.path) {
                try files.removeItem(at: url)
            }
            try files.rename(from: temp, to: url)
        } catch {
            try? files.removeItem(at: temp)
        }
    }

    public init(entries: [Entry]) { self.entries = entries }
}

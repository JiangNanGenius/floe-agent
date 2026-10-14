// FloeApp — Durable design launch binding.
//
// A normal chat task can carry an independent design artifact page, but the
// run must know WHICH typed target it addresses and WHICH work mode
// (制作/修改/重构) is frozen for it BEFORE the provider streams a single
// token. The navigation callback fires only after `ConversationCenter.
// startTask` returns, so binding in `onTaskCreated` is too late: a mock
// provider that requests tools immediately would already see an unbound
// run. This store freezes (typed target, work mode, preservation, original
// task identity) inside the launch transaction window — after the
// conversation/run are durable, before the deferred run task starts
// provider I/O.
//
// Trust boundary: only the trusted UI/launch path writes here. Model tool
// arguments never reach this store — the design tools READ the binding to
// derive the work mode, so a model that omits or changes the mode cannot
// downgrade an active 重构 to 修改. The binding is DATA for mode routing;
// 重构 authority still requires the single-use grant claim burned through
// `DesignRestructureAuthorization` before any mutation (data ≠ authority).

import Foundation
import FloeCore

/// Frozen design identity for one launched task.
struct DesignLaunchBinding: Codable, Sendable, Equatable {
    /// The typed owner target (file/chat-attachment/creative request). The
    /// launch rebound carries the NEW conversation as its origin.
    var target: DesignTarget
    /// Frozen work mode. Mode downgrades by model omission are impossible:
    /// tools read this value, never model text.
    var workMode: DesignWorkMode
    /// Confirmed preservation constraints (重构 only; nil otherwise).
    var preservation: DesignPreservationConstraints?
    /// `preservation?.canonicalDigest`, denormalized for grant matching.
    var preservationDigest: String?
    /// The ORIGINAL task this design work continues (attribution only).
    var originalConversationID: String?
    /// 重构 only: the frozen operation identity minted by the trusted
    /// confirmation; the propose must use exactly this operationID.
    var frozenRestructureOperationID: String?
    /// When the binding was frozen (audit).
    var frozenAt: Date

    init(
        target: DesignTarget,
        workMode: DesignWorkMode,
        preservation: DesignPreservationConstraints? = nil,
        originalConversationID: String? = nil,
        frozenRestructureOperationID: String? = nil,
        frozenAt: Date = Date()
    ) {
        self.target = target
        self.workMode = workMode
        self.preservation = preservation
        self.preservationDigest = preservation?.canonicalDigest
        self.originalConversationID = originalConversationID
        self.frozenRestructureOperationID = frozenRestructureOperationID
        self.frozenAt = frozenAt
    }

    /// The work intent a design tool derives from this frozen binding.
    /// `format` is the real payload format of the bytes being proposed; the
    /// core validates it against the artifact family.
    func makeWorkIntent(actualDesiredFormat: String, operationID: String) -> DesignWorkIntent {
        let confirmation: DesignPreservationConfirmation? = workMode == .restructure
            ? preservation.map {
                DesignPreservationConfirmation(constraints: $0, source: .trustedUI)
            }
            : nil
        return DesignWorkIntent(
            mode: workMode,
            actualDesiredFormat: actualDesiredFormat,
            scope: nil,
            preservation: workMode == .restructure ? preservation : nil,
            frozenRevisionID: target.revision,
            originalTaskOwnerID: originalConversationID,
            confirmation: confirmation,
            operationID: operationID
        )
    }
}

/// Per-conversation durable binding store. One small JSON file per
/// conversation under Application Support (never tmp): decision-grade
/// durability is not required here — the owner envelope holds the real
/// state — but the binding must survive an app restart so a relaunched task
/// keeps its frozen mode. Writes are atomic (staged + move), reads are
/// tolerant of missing fields from older builds, and the store never
/// fabricates a binding: a missing file is simply nil.
enum DesignLaunchBindingStore {
    private static let directoryName = "DesignLaunchBindings"

    /// Test seam: when set, bindings are read/written under this directory
    /// instead of Application Support. The app never sets it; unit tests do.
    /// `nonisolated(unsafe)`: a process-global seam swapped only in tests,
    /// never touched by app code paths.
    nonisolated(unsafe) static var storageDirectoryOverride: URL?

    static func fileURL(conversationID: UUID) -> URL? {
        let root: URL?
        if let override = storageDirectoryOverride {
            root = override
        } else {
            root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FloeAgent", isDirectory: true)
        }
        guard let root else { return nil }
        return root
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(conversationID.uuidString.lowercased()).json")
    }

    /// Read-only lookup. Returns nil when no binding was frozen for this
    /// conversation (ordinary chat tasks, panel-only design use).
    static func load(conversationID: UUID) -> DesignLaunchBinding? {
        guard let url = fileURL(conversationID: conversationID),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DesignLaunchBinding.self, from: data)
    }

    /// Atomic staged write. Throws on failure; the caller (the launch
    /// transaction) must abort before provider I/O rather than leave a
    /// design task running without its frozen identity.
    static func save(_ binding: DesignLaunchBinding, conversationID: UUID) throws {
        guard let url = fileURL(conversationID: conversationID) else {
            throw FloeError.invalidConfiguration("Application Support is unavailable")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(binding)
        let staging = directory.appendingPathComponent(
            ".binding-\(UUID().uuidString.lowercased()).staging")
        try data.write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
    }

    static func remove(conversationID: UUID) {
        guard let url = fileURL(conversationID: conversationID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

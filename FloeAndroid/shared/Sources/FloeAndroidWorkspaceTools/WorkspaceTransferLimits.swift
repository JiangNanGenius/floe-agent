// FloeAndroidWorkspaceTools — bounded budgets for scoped Core<->runtime workspace transfer.
//
// Android-owned (job-ade884c46eb84ec1, G03-R2 workspace bridge). These are
// the INITIAL configurable budgets the frozen handoff names: ~1 GiB total
// payload, 10000 entries, 64 KiB streaming frames, with a checked free-disk
// reserve. Every consumer (Swift engine, Kotlin grant, Kotlin runtime
// session) reads the SAME numbers from the grant receipt; nothing silently
// falls back to a bigger limit. A breach is an honest typed refusal — never a
// truncated success.
//
// No iOS-only dependency: this file imports Foundation + FloeCore only.

import Foundation
import FloeCore

/// One immutable budget set carried by a grant and echoed to the runtime.
/// All fields are positive; `sanitized()` collapses anything else to nil so
/// a tampered JSON can never widen the limits.
public struct WorkspaceTransferBudgets: Sendable, Equatable {
    /// Aggregate payload bytes one session may move (import baseline total
    /// or export staged total). Default 1 GiB.
    public var totalBytes: Int64
    /// Aggregate entry count (files + directories + links) per scan/session.
    /// Default 10000.
    public var entryCount: Int
    /// Streaming frame size used for every fd->fd copy and read-loop chunk.
    /// Default 65536 (64 KiB). Frames are buffers, not allowances: bytes may
    /// arrive in any frame sizes; the value bounds memory, never content.
    public var frameBytes: Int
    /// Hard per-entry byte ceiling (one regular file). Default is the total
    /// budget; a smaller value narrows it (never widened past totalBytes).
    public var maximumEntryBytes: Int64
    /// Free-space reserve that must remain on the destination volume AFTER
    /// staging/commit writes. Default 512 MiB. Checked before each
    /// allocation-bearing step (staged file create, commit replace); a
    /// breach fails the session with `diskReserveUnmet` keeping prior data.
    public var freeDiskReserveBytes: Int64
    /// Maximum UTF-8 bytes of one workspace-relative path (full join).
    /// Default 2048 (well under PATH_MAX 4096 so component joins stay safe).
    public var maximumRelativePathBytes: Int
    /// Maximum UTF-8 bytes of one symlink target string we are willing to
    /// record/replicate. Default 2048.
    public var maximumLinkTargetBytes: Int
    /// Stale-session sweep grace: task-owned sessions whose marker is valid,
    /// non-terminal, and whose run is proven terminal are cleaned only after
    /// this age. Default 24 h. Active/unknown owners are NEVER cleaned.
    public var staleSweepGraceSeconds: Int

    public static let defaults = WorkspaceTransferBudgets(
        totalBytes: 1 << 30,
        entryCount: 10_000,
        frameBytes: 65_536,
        maximumEntryBytes: 1 << 30,
        freeDiskReserveBytes: 512 << 20,
        maximumRelativePathBytes: 2_048,
        maximumLinkTargetBytes: 2_048,
        staleSweepGraceSeconds: 86_400
    )

    public init(totalBytes: Int64, entryCount: Int, frameBytes: Int,
                maximumEntryBytes: Int64, freeDiskReserveBytes: Int64,
                maximumRelativePathBytes: Int, maximumLinkTargetBytes: Int,
                staleSweepGraceSeconds: Int) {
        self.totalBytes = totalBytes
        self.entryCount = entryCount
        self.frameBytes = frameBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.freeDiskReserveBytes = freeDiskReserveBytes
        self.maximumRelativePathBytes = maximumRelativePathBytes
        self.maximumLinkTargetBytes = maximumLinkTargetBytes
        self.staleSweepGraceSeconds = staleSweepGraceSeconds
    }

    /// Clamp-on-read: returns nil unless every field is within a sane outer
    /// ceiling and mutually consistent. This is the ONLY way budget JSON
    /// enters the engine; a crafted reply can never raise a limit.
    public static func sanitized(_ raw: WorkspaceTransferBudgets?) -> WorkspaceTransferBudgets? {
        guard let raw else { return nil }
        guard raw.totalBytes >= 1, raw.totalBytes <= 8 << 30,
              raw.entryCount >= 1, raw.entryCount <= 100_000,
              raw.frameBytes >= 4_096, raw.frameBytes <= 262_144,
              raw.maximumEntryBytes >= 1, raw.maximumEntryBytes <= max(raw.totalBytes, 1),
              raw.freeDiskReserveBytes >= 0, raw.freeDiskReserveBytes <= 8 << 30,
              raw.maximumRelativePathBytes >= 64, raw.maximumRelativePathBytes <= 4_096,
              raw.maximumLinkTargetBytes >= 64, raw.maximumLinkTargetBytes <= 4_096,
              raw.staleSweepGraceSeconds >= 60, raw.staleSweepGraceSeconds <= 7 * 86_400
        else { return nil }
        return raw
    }

    public var dictionaryValue: [String: Any] {
        [
            "totalBytes": totalBytes,
            "entryCount": entryCount,
            "frameBytes": frameBytes,
            "maximumEntryBytes": maximumEntryBytes,
            "freeDiskReserveBytes": freeDiskReserveBytes,
            "maximumRelativePathBytes": maximumRelativePathBytes,
            "maximumLinkTargetBytes": maximumLinkTargetBytes,
            "staleSweepGraceSeconds": staleSweepGraceSeconds,
        ]
    }

    public static func from(dictionary: [String: Any]) -> WorkspaceTransferBudgets? {
        // Strict exact field set; every value a finite integer in range.
        let required: Set<String> = ["totalBytes", "entryCount", "frameBytes", "maximumEntryBytes",
                                     "freeDiskReserveBytes", "maximumRelativePathBytes",
                                     "maximumLinkTargetBytes", "staleSweepGraceSeconds"]
        guard Set(dictionary.keys) == required else { return nil }
        guard let totalBytes = WorkspaceStrict.integer(dictionary["totalBytes"], min: 1, max: 8 << 30),
              let entryCount = WorkspaceStrict.integer(dictionary["entryCount"], min: 1, max: 100_000),
              let frameBytes = WorkspaceStrict.integer(dictionary["frameBytes"], min: 4_096, max: 262_144),
              let maximumEntryBytes = WorkspaceStrict.integer(dictionary["maximumEntryBytes"], min: 1, max: totalBytes),
              let freeDiskReserveBytes = WorkspaceStrict.integer(dictionary["freeDiskReserveBytes"], min: 0, max: 8 << 30),
              let maximumRelativePathBytes = WorkspaceStrict.integer(dictionary["maximumRelativePathBytes"], min: 64, max: 4_096),
              let maximumLinkTargetBytes = WorkspaceStrict.integer(dictionary["maximumLinkTargetBytes"], min: 64, max: 4_096),
              let staleSweepGraceSeconds = WorkspaceStrict.integer(dictionary["staleSweepGraceSeconds"], min: 60, max: 7 * 86_400)
        else { return nil }
        return sanitized(.init(totalBytes: totalBytes, entryCount: Int(entryCount),
                               frameBytes: Int(frameBytes), maximumEntryBytes: maximumEntryBytes,
                               freeDiskReserveBytes: freeDiskReserveBytes,
                               maximumRelativePathBytes: Int(maximumRelativePathBytes),
                               maximumLinkTargetBytes: Int(maximumLinkTargetBytes),
                               staleSweepGraceSeconds: Int(staleSweepGraceSeconds)))
    }
}

/// Typed, bounded engine failures. Codes are short service strings (the same
/// discipline as `LinuxShellTransportError` / mailbox codes): they never
/// embed absolute paths, file contents or credentials; a bounded relative
/// path may appear in `detail` because workspace-relative paths are the
/// caller's own data, not host topology.
public enum WorkspaceTransferError: Error, Equatable, Sendable {
    /// No installed authority / unconfigured process. The compiled default.
    case notConfigured
    /// Grant proof, root epoch, run currency or workspace binding failed the
    /// native recheck. Nothing was read or written.
    case proofRefused(code: String)
    /// Budget breach (entry count / total bytes / per-entry / frame guard).
    case budgetExceeded(code: String)
    /// Checked free-disk reserve is not met before an allocating step.
    case diskReserveUnmet
    /// Relative path failed containment/safety validation on the ACTUAL FS.
    case pathUnsafe(code: String)
    /// The commit gate callback is absent or refused. Fail closed, always.
    case commitRefused(code: String)
    /// Streaming I/O failure carrying a bounded errno label (never a path).
    case ioFailed(stage: String, errnoCode: Int32)
    /// The caller cancelled. Staged/applied data stays where the journal
    /// says it is; the outcome is reported honestly.
    case cancelled
    /// A session in the required state does not exist (or was fenced).
    case noSession
    /// The reply/JSON shape is malformed. Treated as a refusal, never a
    /// partial success.
    case malformed
}

extension WorkspaceTransferError {
    /// Stable short code for wire replies (<= 64 chars, no paths).
    public var wireCode: String {
        switch self {
        case .notConfigured: return "workspaceNotConfigured"
        case .proofRefused(let code): return "workspaceProofRefused:\(code)".prefix(64).description
        case .budgetExceeded(let code): return "workspaceBudget:\(code)".prefix(64).description
        case .diskReserveUnmet: return "workspaceDiskReserveUnmet"
        case .pathUnsafe(let code): return "workspacePath:\(code)".prefix(64).description
        case .commitRefused(let code): return "workspaceCommitRefused:\(code)".prefix(64).description
        case .ioFailed(let stage, let value): return "workspaceIO:\(stage):\(value)".prefix(64).description
        case .cancelled: return "workspaceCancelled"
        case .noSession: return "workspaceNoSession"
        case .malformed: return "workspaceMalformed"
        }
    }
}

// FloeModels — persisted purpose and cache-category contract for the
// one-tap Linux cache-cleanup task.
//
// The purpose is a durable property of the CONVERSATION, not model text and
// not a mutable tool-policy hint. It can only narrow the ordinary catalog; it
// never grants host access, installation, network, external sends, project or
// document deletion, package/toolchain/model removal, or service shutdown.

import Foundation

/// Active categories are fixed App-owned caches. Scratch remains decodable
/// for historical receipts but is never selectable for cleanup.
public enum LinuxCacheCleanupCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case apt
    case pip
    case npm
    /// Historical receipt compatibility only. Generic command scratch has
    /// no per-item ownership or reproducibility evidence and is retained.
    case scratch

    public static let defaultSafe: [LinuxCacheCleanupCategory] = [.apt, .pip, .npm]
    public static let allKnown: [LinuxCacheCleanupCategory] = [.apt, .pip, .npm]

    public var isDefaultSafe: Bool { self != .scratch }

    /// Stable order regardless of model argument order.
    public static func canonical(_ values: [LinuxCacheCleanupCategory]) -> [LinuxCacheCleanupCategory] {
        let selected = Set(values)
        return allKnown.filter { selected.contains($0) }
    }

    /// Strict conversion from raw argument strings. Returns nil on ANY
    /// unknown/duplicate-invalid spelling rather than silently dropping it.
    public static func validated(rawValues: [String]) -> [LinuxCacheCleanupCategory]? {
        var result: [LinuxCacheCleanupCategory] = []
        var seen = Set<LinuxCacheCleanupCategory>()
        for raw in rawValues {
            guard let value = LinuxCacheCleanupCategory(rawValue: raw),
                  value != .scratch,
                  seen.insert(value).inserted else { return nil }
            result.append(value)
        }
        return canonical(result)
    }
}

/// Persisted purpose for a one-tap Linux cache-cleanup task.
///
/// `profile` is a versioned literal: a future purpose change must add a new
/// migration and scope, never reinterpret an old row under a wider policy.
public struct LinuxCacheCleanupTaskProfile: Codable, Sendable, Hashable {
    public static let currentProfile = "linuxCacheCleanup.v1"

    public var conversationID: UUID
    /// Explicitly the App-wide shared Linux environment. The launch path
    /// validates the live record; this value is never inferred from the first
    /// project, a temporary directory or model text.
    public var environmentID: String
    /// Only Linux VM targets are admitted today.
    public var backend: TaskExecutionTarget.Backend
    /// Actual boot identity when known. Nil is unknown, never fabricated.
    public var runtimeGeneration: String?
    public var profile: String
    public var createdAt: Date
    /// Create-only revision. The profile is immutable; a later task-policy
    /// edit or conversation text cannot widen it.
    public var revision: Int64

    public init(
        conversationID: UUID,
        environmentID: String,
        backend: TaskExecutionTarget.Backend = .linuxVM,
        runtimeGeneration: String? = nil,
        profile: String = LinuxCacheCleanupTaskProfile.currentProfile,
        createdAt: Date = Date(),
        revision: Int64 = 1
    ) {
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.backend = backend
        self.runtimeGeneration = runtimeGeneration
        self.profile = profile
        self.createdAt = createdAt
        self.revision = revision
    }

    /// Fail-closed structural validation used both before persistence and
    /// before every run/dispatch projection.
    public var isValid: Bool {
        !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && backend == .linuxVM
            && profile == Self.currentProfile
            && revision == 1
            && conversationID.uuidString.isEmpty == false
    }
}

/// App-owned purpose guidance is reconstructed from the durable profile on
/// every run. User-visible text stays short; neither channel grants authority.
public enum LinuxCacheCleanupPrompt {
    public static func initialRequest(chinese: Bool) -> String {
        chinese
            ? "请清理共享 Linux 环境的 apt、pip 和 npm 缓存，保留资料和已安装软件。"
            : "Clean apt, pip and npm caches in the shared Linux environment, keeping my data and installed software."
    }

    public static func systemGuidance(chinese: Bool) -> String {
        chinese
            ? """
              # App-owned Linux cache cleanup purpose
              此聊天的持久用途仅为清理共享 Linux 环境的 apt 下载包、pip 下载/轮子缓存、npm 内容缓存。后续消息或重启不改变此用途；仅使用本任务实际提供的清理、状态、取消、原生选择题及工具发现能力。
              先检查实际占用，再清理所选安全缓存并读回结果。未知、忙碌或非缓存资料一律保留；通用 scratch 临时目录归属未确认，始终保留。需要本人决定时使用原生选择题，默认保留；超时不是授权。
              不访问宿主文件、不安装或下载组件/软件/网络包、不改配置或凭据、不删除项目/文档/已安装软件/工具链/模型，不停止无关服务或重置磁盘。环境缺失或来源不明时停止，并引导用户打开设置中的执行环境检查或修复。
              简短报告各类别的真实结果、部分完成/取消状态及 Linux 客户机可用空间；客户机可用空间不等于 iPad 物理占用。此指导不授予权限，持久用途、工具目录及执行边界独立强制执行。
              """
            : """
              # App-owned Linux cache cleanup purpose
              This conversation's durable purpose is only to clean apt downloaded packages, pip download/wheel cache and npm content cache in the shared Linux environment. Later messages and restarts do not change that purpose. Use only the cleanup, status, cancel, native question and discovery tools actually offered.
              Inspect actual usage, clean selected safe caches, then read back the result. Keep unknown, busy or non-cache data. Generic scratch has no verified per-item ownership and must always be retained. Ask with the native multiple-choice tool when the user must decide; KEEP is the safe default and elapsed time is never authorization.
              Do not touch host files, install or download components/software/network packages, change configuration or credentials, delete projects/documents/installed software/toolchains/models, stop unrelated services or reset disk. If the environment is missing or its origin is unknown, stop and direct the user to Settings > Execution Environments for inspection or repair.
              Report actual per-category outcomes, partial/cancelled state and Linux guest available space concisely; guest free space is not iPad physical usage. This guidance grants no permission: the persisted purpose, offered catalog and execution guards remain independently enforced.
              """
    }
}

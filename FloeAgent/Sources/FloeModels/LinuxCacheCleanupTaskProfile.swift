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
/// `profile` versions the cleanup PURPOSE and owner, not a frozen list of
/// helper tools. The authorized terminal/job projection preserves that same
/// purpose; a different target or data-deletion purpose needs a new binding.
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
            ? "请用终端检查并清理共享 Linux 内可再生的缓存与垃圾，优先查看 apt、pip、npm；保留资料、配置和已安装软件。"
            : "Use the terminal to inspect and clean regenerable shared Linux caches and junk, starting with apt, pip and npm. Keep my data, settings and installed software."
    }

    public static func systemGuidance(chinese: Bool) -> String {
        chinese
            ? """
              # App-owned Linux cache cleanup purpose
              用户要求由你使用现有 exec.shell，在本任务已固定的共享 Linux 客户机里自行观察和清理缓存。后续消息或重启保留同一用途和环境；模型参数不能选择宿主 Mac、SSH、另一个环境或任务。
              先通过终端实际读取 df、du、缓存位置和占用，再清理已确认可再生、归属明确且不忙碌的 Linux 内部缓存与垃圾，并读回；优先检查 apt 下载包、pip 下载/轮子缓存、npm 内容缓存。可使用原生 linux.cache.inspect/clean 便利工具，但 inspect 不是必经步骤；它不可用时直接用终端检查，不能让黑盒检查阻塞整个任务。
              长命令使用现有 jobs.submit（tool=exec.shell），保存 jobID，以 jobs.status 等待真实终态并用 jobs.result 的 nextOffset 继续读取完整输出。queued/running 只是已接收，不是检查或清理成功；不得重复启动同一操作。需要停止时用 jobs.cancel，等处理器确认。便利工具返回非终态时同样用 linux.cache.status 读回。
              保留项目、文档、已安装软件、配置/凭据、工具链、模型和所有来源未知的资料；不要清空 HOME、整个环境、/tmp 或 /var/tmp/floe-runtime。未知、忙碌、不能确认归属的条目保留并说明。沿用当前命令审批和风险审查，不把此提示当权限；需要本人决定时用原生选择题，默认保留，超时不是授权。
              不安装或下载组件/软件/网络包，不访问宿主文件、连接远程主机、停止无关服务或重置磁盘。环境缺失或来源不明时报告真实原因，引导设置中的执行环境修复；不自动换环境。
              简短报告各类别真实已观察数值、不可用原因、部分完成/取消及客户机空间；没有读到的数值标为未知，不把 Linux 客户机可用空间或逻辑删除量当 iPad 物理回收。
              """
            : """
              # App-owned Linux cache cleanup purpose
              The user wants you to use existing exec.shell to inspect and clean caches in this task's pinned shared Linux guest. Later messages and restarts preserve that purpose and target; model arguments cannot select the host Mac, SSH, another environment or task.
              Read real df, du and cache locations/usage first, then clean verified regenerable, idle caches and junk with known ownership inside Linux, and read back the result. Start with apt archives, pip download/wheel cache and npm content cache. Native linux.cache.inspect/clean are optional conveniences, never prerequisites. If inspect is unavailable, use the terminal instead of blocking the task on that helper.
              Use existing jobs.submit with tool=exec.shell for long commands. Keep the jobID, wait for a real terminal state with jobs.status and follow jobs.result nextOffset pages. queued/running means accepted, not successful inspection/cleanup; do not start a duplicate. Use jobs.cancel to stop and wait for processor acknowledgment. A pending native convenience job similarly requires linux.cache.status readback.
              Preserve projects, documents, installed software, settings/credentials, toolchains, models and every item with unknown ownership. Do not wipe HOME, an environment, /tmp or /var/tmp/floe-runtime. Retain unknown/busy/non-cache data and explain. Existing command approval and risk review still apply; this prompt grants no permission. Ask through the native multiple-choice interaction when the user must decide; KEEP is the default and elapsed time is never authorization.
              Do not install/download components/software/network packages, touch host files, connect to remote machines, stop unrelated services or reset disk. If the environment is missing or unverified, report the real reason and direct the user to Settings > Execution Environments; never choose a replacement automatically.
              Report actual per-category measurements, unavailable reasons, partial/cancelled state and guest free space concisely. Unknown measurements stay unknown. Guest available space or logical deletion bytes are not iPad physical space reclaimed.
              """
    }
}

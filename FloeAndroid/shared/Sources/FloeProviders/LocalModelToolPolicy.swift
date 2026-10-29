import Foundation

/// Policy for tool capability offered to on-device (MLX) models.
///
/// On-device runs are limited to a **curated, concise ceiling**: web search
/// and local file lookup. Shell access, code execution (local
/// Python/JavaScript), Linux provisioning, complex environment lifecycle
/// management, file editing and arbitrary configuration mutation are never
/// offered — neither through the stable base set, nor through
/// `tools.list`/`tools.search` discovery, nor persisted discovery state.
///
/// Two layers:
/// - `pinnedToolNames` / `pinnedAdmissionOrder(for:)`: the small base set
///   admitted on every tool-capable local run without a discovery round-trip.
///   Admission order is intent-specific: an explicit file-lookup request
///   admits the read tools ahead of `web.search`, while a live-web request
///   admits `web.search` first. The adapter's per-window token/character
///   budget then drops schemas from the tail deterministically.
/// - `curatedCeilingNames`: every tool name a local run may ever load. The
///   runtime filters both discovery and remembered (persisted/checkpoint)
///   state through this same ceiling.
///
/// A name is admitted only when it is actually present in the run's
/// registered, configured capability set: an unconfigured `web.search` is
/// simply absent — never replaced with a fabricated tool and never satisfied
/// by forcing an unrelated file tool. Cloud providers are not gated by this
/// policy and keep their existing dynamic discovery behaviour.
///
/// There is deliberately no "settings" tool here: the app has no registered
/// agent-facing settings-mutation capability (settings are native views), so
/// adding one would be an invented arbitrary-configuration tool.
public enum LocalModelToolPolicy {
    /// Canonical web-search capability. It executes only against providers
    /// the app has configured and validated.
    public static let webSearchToolName = "web.search"

    /// Pinned base set: web search plus the read-only file lookup chain.
    /// Exactly these names are kept loaded without a discovery call.
    public static let pinnedToolNames: Set<String> = [
        webSearchToolName,
        "workspace.readFile",
        "workspace.listDirectory",
        "workspace.searchFiles",
        "workspace.inspectFileMetadata"
    ]

    /// File lookup admission order within the pinned set (read chain first).
    private static let fileLookupAdmissionOrder: [String] = [
        "workspace.readFile",
        "workspace.listDirectory",
        "workspace.searchFiles",
        "workspace.inspectFileMetadata"
    ]

    /// Default pinned admission order for a live-web request: search leads
    /// (the observed Build 235 failure picked a file tool for a news query).
    public static let webFirstAdmissionOrder: [String] =
        [webSearchToolName] + fileLookupAdmissionOrder

    /// File-first pinned admission order for an explicit file-lookup request,
    /// so a generic "搜索 …文件" turn spends the tight budget on read tools,
    /// not `web.search`.
    public static let fileFirstAdmissionOrder: [String] =
        fileLookupAdmissionOrder + [webSearchToolName]

    /// Pinned admission order for `text` (already lowercased). File lookup
    /// leads only when the turn names a file target and does not also name a
    /// live-web target; mixed and ordinary turns keep web first.
    public static func pinnedAdmissionOrder(for text: String) -> [String] {
        let fileIntent = requestsFileLookup(text)
        let liveWebIntent = requestsLiveWeb(text)
        if fileIntent && !liveWebIntent { return fileFirstAdmissionOrder }
        return webFirstAdmissionOrder
    }

    /// Complete curated ceiling: every tool name a local model may ever be
    /// offered, regardless of discovery or remembered state. Each name
    /// corresponds to an existing canonical, registered tool:
    /// discovery meta-tools (runtime), web retrieval (`FloeExecution`), and
    /// workspace read/lookup (`FloeWorkspace`). Anything absent stays hidden
    /// — shell, code execution, Linux provisioning and environment lifecycle
    /// management in particular.
    public static let curatedCeilingNames: Set<String> = [
        // Discovery meta-tools (enumerate/load within the ceiling only).
        "tools.list", "tools.search",
        // Web retrieval — present only when a provider is actually configured.
        "web.search", "web.searchAI", "web.fetch",
        // Workspace read/lookup chain.
        "workspace.readFile", "workspace.listDirectory", "workspace.searchFiles",
        "workspace.inspectFileMetadata"
    ]

    /// Terms that name a **live web** target (excludes the generic words
    /// 搜索/search, which also describe local file lookup).
    public static let liveWebIntentTerms: [String] = [
        "网页", "联网", "在线", "新闻", "资讯", "热点", "天气", "预报", "浏览器", "网站", "网址",
        "web", "online", "news", "headline", "weather", "forecast", "browser", "website"
    ]

    /// Generic search words: the turn asks a search engine for information.
    public static let genericSearchTerms: [String] = [
        "搜索", "搜一下", "搜搜", "查查", "查找", "检索",
        "search", "look up", "lookup", "find"
    ]

    /// Terms that indicate a **direct fetch** of a given URL/page rather than
    /// a search-engine query. Such turns keep `web.fetch` and must not be
    /// cleared as "search unavailable" on a generic keyword.
    public static let directFetchIntentTerms: [String] = [
        "http", "抓取", "网址", "url", "fetch", "web.fetch", "下载网页", "读取网页"
    ]

    /// Chinese/English terms naming a local file target.
    public static let fileLookupIntentTerms: [String] = [
        "文件", "目录", "文档", "代码", "工作区", "pdf",
        "file", "folder", "directory", "document", "workspace"
    ]

    /// True when `text` (already lowercased) names a live-web target.
    public static func requestsLiveWeb(_ text: String) -> Bool {
        liveWebIntentTerms.contains { text.contains($0) }
    }

    /// True when `text` contains a generic search word.
    public static func requestsGenericSearch(_ text: String) -> Bool {
        genericSearchTerms.contains { text.contains($0) }
    }

    /// True when `text` asks for direct retrieval of a URL/page.
    public static func requestsDirectFetch(_ text: String) -> Bool {
        directFetchIntentTerms.contains { text.contains($0) }
    }

    /// True when `text` names a local file target.
    public static func requestsFileLookup(_ text: String) -> Bool {
        fileLookupIntentTerms.contains { text.contains($0) }
    }

    /// True when `text` expresses a request that specifically needs the
    /// web-search capability: an explicit search/information term, with no
    /// direct-URL fetch target and no file-only target. Generic web words
    /// alone ("web", "browser") do not qualify.
    public static func requestsWebSearch(_ text: String) -> Bool {
        let searchSpecific = requestsLiveWeb(text) || requestsGenericSearch(text)
        guard searchSpecific else { return false }
        guard !requestsDirectFetch(text) else { return false }
        guard !requestsFileLookup(text) else { return false }
        return true
    }
}

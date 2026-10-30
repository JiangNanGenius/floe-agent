import Foundation

/// Presentation policy for the tools offered to on-device (MLX) models.
///
/// Authorization does **not** live here, and this type is not a capability
/// whitelist. The runtime's frozen catalog is the authority: the task's
/// permission ceiling, plan/temporary projection, configured and enabled
/// capabilities, the user's allowed names and the model's capabilities have
/// already been applied. An MLX run therefore receives the same
/// task-authorized tool set as a cloud run — Git, conversation/history,
/// notes, shell/Linux environment, browser, web and CAD tools included — and
/// the model chooses which tool (and which environment) to use. Nothing here
/// filters, hides or grants a capability.
///
/// What remains is presentation, used by the local adapter's bounded schema
/// admission:
/// - `pinnedToolNames(for:)` / `pinnedAdmissionOrder(for:)`: a small base set
///   kept loaded on a tool-capable local run without a discovery round-trip,
///   plus `cad.document` only for explicit CAD/3D/modeling intent. Admission
///   order is intent-specific: an explicit file-lookup request admits the
///   read tools ahead of `web.search`, a live-web request admits `web.search`
///   first, and a CAD turn admits the CAD schema first. The adapter's
///   per-window token/character budget then drops schemas from the tail
///   deterministically.
/// - `requestsLiveWeb`/`requestsGenericSearch`/`requestsDirectFetch`/
///   `requestsFileLookup`/`requestsCadWork`/`requestsWebSearch`: deterministic
///   intent hints for the same presentation and repair selection.
///
/// A pin is a hint, never a grant. A name is presented only when the run
/// actually registered and configured it: an unconfigured `web.search` is
/// simply absent — never replaced with a fabricated tool and never satisfied
/// by forcing an unrelated file tool. Authorized tools outside the pinned
/// hint set stay reachable through the run's own catalog and ordinary
/// discovery. Every call keeps its ordinary permission, approval,
/// revision/ownership, cancellation and environment checks, and
/// `cad.document` propose/apply stays bound to the existing CAD proposal,
/// revision/SHA, undoable-transaction and approval/runtime-authority rules.
///
/// The one real adapter-level restriction is Apple Foundation Models: their
/// native tool channel accepts only `apple.*` names, enforced by
/// `LocalProviderAdapter`, not by this policy. Cloud providers are not gated
/// by this policy and keep their existing dynamic discovery behaviour.
///
/// There is deliberately no "settings" tool here: the app has no registered
/// agent-facing settings-mutation capability (settings are native views), so
/// adding one would be an invented arbitrary-configuration tool.
public enum LocalModelToolPolicy {
    /// Canonical web-search capability. It executes only against providers
    /// the app has configured and validated.
    public static let webSearchToolName = "web.search"

    /// Pinned presentation base: web search plus the read-only file lookup
    /// chain. Exactly these names are kept loaded without a discovery call on
    /// a tool-capable local run. This is the always-on hint set; turn-aware
    /// runs use `pinnedToolNames(for:)`. Being listed here neither grants nor
    /// limits authority — a name is offered only when the run's authorized
    /// catalog actually contains it, and heavier authorized surfaces (Git,
    /// notes, shell/Linux, browser, document editing) simply are not eagerly
    /// loaded.
    public static let pinnedToolNames: Set<String> = [
        webSearchToolName,
        "workspace.readFile",
        "workspace.listDirectory",
        "workspace.searchFiles",
        "workspace.inspectFileMetadata"
    ]

    /// The CAD document tool whose schema is pinned by explicit CAD/3D/
    /// modeling intent only, never on every turn. Pinning is presentation
    /// only; propose/apply keep their proposal, revision and approval checks.
    public static let cadToolName = "cad.document"

    /// Pinned presentation set for ONE turn. The stable base plus
    /// `cad.document` when the user explicitly asks for CAD/3D/modeling work.
    /// Local pinned admission uses this variant so a generic web/file turn
    /// never spends its tight schema budget on a CAD schema. It does not
    /// change what the run is authorized to call.
    public static func pinnedToolNames(for text: String) -> Set<String> {
        var names = pinnedToolNames
        if requestsCadWork(text) { names.insert(cadToolName) }
        return names
    }

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

    /// Pinned admission order for `text` (already lowercased). An explicit
    /// CAD/3D/modeling turn puts `cad.document` first; otherwise file lookup
    /// leads only when the turn names a file target and does not also name a
    /// live-web target, and mixed/ordinary turns keep web first. Order is a
    /// presentation hint for the adapter's budget; the caller admits a name
    /// only when the run actually offers it.
    public static func pinnedAdmissionOrder(for text: String) -> [String] {
        let fileIntent = requestsFileLookup(text)
        let liveWebIntent = requestsLiveWeb(text)
        // Explicit CAD/3D/modeling turns lead with the CAD schema; the
        // remaining order keeps the existing file-vs-web priority unchanged.
        let base: [String]
        if fileIntent && !liveWebIntent {
            base = fileFirstAdmissionOrder
        } else {
            base = webFirstAdmissionOrder
        }
        return requestsCadWork(text) ? [cadToolName] + base : base
    }

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

    /// Terms that explicitly name CAD/3D/modeling work rather than generic
    /// chat, a file read or an AI model choice. Chinese "模型" alone is
    /// deliberately absent: it is far more often "switch/configure the model".
    public static let cadIntentTerms: [String] = [
        "cad", "dwg", "dxf", "floecad",
        "工程图", "图纸", "二维图", "三维图", "三维模型", "3d模型", "3d 模型",
        "建模", "模型设计", "装配图", "装配体", "网格模型",
        // Precise geometry-edit continuation terms. "模型" alone stays out:
        // it usually means an AI model, not a CAD feature.
        "孔径", "圆角", "倒角", "支架", "材质", "贴图",
        "3d", "3-d", "three-dimensional", "modeling", "modelling",
        "assembly model", "assembly file", "cad assembly",
        "mesh model", "solid model", "step file", "step 文件",
        "iges", "igs", "stl", "glb", ".obj", "obj file",
        "fillet", "chamfer", "bracket", "material", "texture",
        "fillets", "chamfers", "brackets", "materials", "textures"
    ]

    /// True when `text` explicitly asks for CAD/3D document work. This is an
    /// admission hint only; every `cad.document` read/write keeps its existing
    /// proposal, approval and authority checks.
    ///
    /// ASCII terms use token boundaries so "cadence" or "whistle" cannot pin
    /// the CAD schema. Mixed/CJK terms ("三维模型") stay substring matches.
    public static func requestsCadWork(_ text: String) -> Bool {
        let text = text.lowercased()
        for term in cadIntentTerms {
            if term.hasPrefix(".") {
                // File extensions such as `.obj` attach to the preceding
                // filename character, so a word-boundary check would miss
                // `bracket.obj`.
                if text.contains(term) { return true }
            } else if term.unicodeScalars.contains(where: { $0.value > 0x7F }) {
                if text.contains(term) { return true }
            } else if containsASCIIIntentTerm(term, in: text) {
                return true
            }
        }
        return false
    }

    private static func containsASCIIIntentTerm(_ term: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: term, range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !isASCIIAlphanumeric(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex
                || !isASCIIAlphanumeric(text[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
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

import Foundation

/// Capability roles, deliberately independent of historical wire-name prefixes.
public enum ToolCapabilityGroups {
    public static func group(_ name: String) -> String {
        if ["ssh.execute", "ssh.taskStatus", "ssh.cancelTask"].contains(name) { return "executor" }
        if ["ssh.shellOpen", "ssh.shellExchange", "ssh.shellClose"].contains(name)
            || name.hasPrefix("remote.connection.") || name.hasPrefix("bluetooth.serial.") { return "terminal" }
        if name.hasPrefix("ssh.") { return "hosts" }
        if name == "exec.localService" { return "jobs" }
        if name == "exec.shell" || name.hasPrefix("shell.") { return "shell" }
        if name == "apt" { return "packages" }
        if name == "exec.localPython" { return "python" }
        if name.hasPrefix("document.pdf.") { return "pdf" }
        if name.hasPrefix("document.") || name.hasPrefix("font.") { return "office" }
        if name == "network.http" { return "http" }
        return String(name.split(separator: ".").first ?? "other")
    }
}

/// Task-level, native-first routing policy shared by deferred discovery,
/// prompt composition, settings and audit output.
///
/// The default owner of a workload comes from `CapabilityExecutionRouter`, so
/// a tool can never be classified as native by discovery and as a guest
/// interpreter at execution time. The policy is intentionally *not* a ban on
/// Linux: high-cost image/video/audio/PDF work must not be mis-routed into the
/// emulated interpreter, while interpreter/CLI/package/server work and
/// explicitly scripted requests keep their normal route. It only ever reasons
/// about tool names that the caller actually offers, so disabled or
/// unconfigured capabilities are never invented.
public enum ToolRoutingPolicy {
    /// The task's dominant intent, derived from the user's own wording.
    public enum TaskIntent: String, Sendable, Hashable {
        /// The request concerns image/video/audio/PDF content.
        case nativeMedia
        /// The user explicitly asked for a script or command-line tool.
        case scripted
        /// Everything else.
        case general
    }

    /// Workload classes whose default owner is a native Apple framework.
    /// `.general` is excluded: compiled Swift tools are not necessarily heavy
    /// media capabilities.
    public static let nativeMediaWorkloads: Set<CapabilityWorkloadClass> = [
        .video, .audio, .image, .ocr, .pdf, .metal, .coreML
    ]

    /// True when the tool's declared backend is native and its workload is a
    /// heavy media/document class.
    public static func isNativeMediaTool(_ name: String) -> Bool {
        nativeMediaWorkloads.contains(CapabilityExecutionRouter.decision(for: name).workload)
    }

    /// True when the tool runs inside the Linux guest (shell, interpreter,
    /// package manager or guest server).
    public static func isInterpreterTool(_ name: String) -> Bool {
        CapabilityExecutionRouter.decision(for: name).backend == .linuxGuest
    }

    /// The group names that must not be auto-expanded for a native-media task
    /// when a native capability is actually offered. Derived from the offered
    /// descriptors, never from a static list, so a run without a Linux guest
    /// produces an empty set.
    public static func interpreterGroups(among names: [String]) -> Set<String> {
        Set(names.filter(isInterpreterTool).map { ToolCapabilityGroups.group($0) })
    }

    /// True when the task text asks for a script/command-line route.
    public static func requestsScript(_ query: String) -> Bool {
        containsAny(scriptTerms, in: query)
    }

    /// True when the task text concerns image/video/audio/PDF content.
    public static func concernsNativeMedia(_ query: String) -> Bool {
        containsAny(mediaTerms, in: query)
    }

    public static func intent(forTask query: String) -> TaskIntent {
        if requestsScript(query) { return .scripted }
        return concernsNativeMedia(query) ? .nativeMedia : .general
    }

    /// A routing decision over the tools this run actually offers.
    public struct Decision: Sendable, Equatable {
        public let intent: TaskIntent
        /// Every offered native media tool (not necessarily matching the task).
        public let nativeMediaTools: [String]
        /// Offered native media tools whose declared subject *and* operation
        /// both match the task wording. Only these justify preferring the
        /// native route; the prefix `video.` alone proves nothing about the
        /// requested operation.
        public let matchedNativeTools: [String]
        public let interpreterTools: [String]
        /// True when interpreter auto-expansion must be suppressed for this
        /// task because an offered native tool matches the requested
        /// operation. Suppression only changes discovery preference: explicit
        /// names, loaded schemas and tools.search remain available, and an
        /// unmatched media task keeps the interpreter fallback discoverable.
        public let prefersNativeTools: Bool
        public let reason: String
    }

    /// Decides how discovery should treat `query` for the offered tool names.
    ///
    /// - Media intent with at least one *matched* native tool and no explicit
    ///   script request: `prefersNativeTools` is true and interpreter groups
    ///   stay out of the automatic expansion. Explicit tool names remain
    ///   callable.
    /// - Media intent without a matching native tool (none offered, or only
    ///   unrelated native media tools such as OCR offered for a video-encode
    ///   request): false, so the interpreter fallback stays discoverable.
    /// - Scripted or general intent: false, preserving existing discovery.
    public static func decision(forTask query: String, offeredToolNames names: [String]) -> Decision {
        let intent = intent(forTask: query)
        let native = names.filter(isNativeMediaTool).sorted()
        let matched = matchedNativeTools(forTask: query, offeredNativeToolNames: native)
        let interpreters = names.filter(isInterpreterTool).sorted()
        let prefers: Bool
        let reason: String
        switch intent {
        case .scripted:
            prefers = false
            reason = "user explicitly asked for a script or command-line route"
        case .nativeMedia where matched.isEmpty:
            prefers = false
            reason = native.isEmpty
                ? "media task but no native media tool is offered; interpreter fallback stays discoverable"
                : "media task but no offered native tool matches the requested operation; interpreter fallback stays discoverable"
        case .nativeMedia:
            prefers = true
            reason = "media task matched \(matched.count) offered native tool(s) [\(matched.joined(separator: ", "))]; the guest interpreter is not the default route"
        case .general:
            prefers = false
            reason = "no media intent; discovery is unchanged"
        }
        return Decision(
            intent: intent,
            nativeMediaTools: native,
            matchedNativeTools: matched,
            interpreterTools: interpreters,
            prefersNativeTools: prefers,
            reason: reason
        )
    }

    /// Native tools whose declared subject and operation both appear in the
    /// task wording, or whose exact name/alias the user spelled out. The
    /// comparison is conservative: every name component must match, so an
    /// unknown operation never counts as covered.
    public static func matchedNativeTools(forTask query: String, offeredNativeToolNames names: [String]) -> [String] {
        names.filter { matches(task: query, toolName: $0) }.sorted()
    }

    static func matches(task query: String, toolName: String) -> Bool {
        let lowered = query.lowercased()
        let tokens = Set(lowered.split(whereSeparator: { $0.isWhitespace || "，,;；/、。".contains($0) }).map(String.init))
        if tokens.contains(toolName.lowercased()) { return true }
        if ToolAliasTable.aliases(of: toolName).contains(where: { tokens.contains($0.lowercased()) }) { return true }
        let parts = components(of: toolName)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { componentMatches($0, in: lowered) }
    }

    /// "superResolution" → ["super", "resolution"]; a one-word component keeps
    /// its name. Operation components stay part of the signature so a tool is
    /// never credited for an operation the task did not ask for.
    static func components(of toolName: String) -> [String] {
        toolName.split(separator: ".").flatMap { part -> [String] in
            var words: [String] = []
            var current = ""
            for character in part {
                if character.isUppercase, !current.isEmpty {
                    words.append(current.lowercased())
                    current = String(character)
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { words.append(current.lowercased()) }
            return words
        }
    }

    private static func componentMatches(_ component: String, in query: String) -> Bool {
        if let terms = componentSynonyms[component] {
            return terms.contains { containsAny([$0], in: query) }
        }
        return containsAny([component], in: query)
    }

    // MARK: - Intent vocabulary

    /// Terms that mark a script/command-line request. Kept deliberately small:
    /// these only *allow* the interpreter route, they never force it.
    static let scriptTerms: [String] = [
        "script", "python", "shell", "bash", "zsh", "command line", "ffmpeg",
        "imagemagick", "opencv", "pillow", "pandas", "numpy",
        "脚本", "命令行", "终端", "解释器"
    ]

    /// Terms that mark media/document content. Chinese terms are matched as
    /// substrings (CJK has no spaces); ASCII terms are matched with word
    /// boundaries, so avoid short ambiguous spellings.
    static let mediaTerms: [String] = [
        "image", "photo", "picture", "screenshot", "video", "movie", "audio",
        "voice", "speech", "transcribe", "transcription", "subtitle", "caption",
        "pdf", "ocr", "barcode", "qr", "watermark", "thumbnail", "frames",
        "frame rate", "remux", "codec", "mp4", "mov", "mp3", "wav", "heic",
        "png", "jpeg", "resolution",
        "图片", "图像", "照片", "截图", "视频", "影片", "动画", "音频", "语音",
        "录音", "字幕", "转写", "听写", "文字识别", "识别文字", "二维码", "条码",
        "水印", "抽帧", "转码", "修图", "抠图", "封面图", "海报"
    ]

    /// Subject and operation vocabulary for native tool-name components. Only
    /// used to decide whether the offered native tool actually matches the
    /// task; unmapped components must literally appear in the request.
    static let componentSynonyms: [String: [String]] = [
        // Subjects
        "image": ["图片", "图像", "照片", "image", "photo", "picture", "截图", "screenshot"],
        "photo": ["图片", "照片", "photo"],
        "video": ["视频", "影片", "video", "movie"],
        "audio": ["音频", "语音", "录音", "audio", "voice", "sound"],
        "pdf": ["pdf"],
        "ocr": ["ocr", "文字识别", "识别文字", "光学识别"],
        "barcode": ["二维码", "条码", "barcode", "qr"],
        "qr": ["二维码", "qr"],
        "media": ["媒体", "media", "音视频"],
        "document": ["文档", "document", "文件"],
        "presentation": ["幻灯片", "演示文稿", "ppt", "presentation", "slide"],
        "font": ["字体", "font"],
        "canvas": ["画布", "canvas"],
        // Operations
        "generate": ["生成", "画", "生图", "generate", "draw", "生成图片", "生成视频"],
        "transcode": ["转码", "编码", "转换", "转成", "transcode", "convert", "encode"],
        "convert": ["转换", "转成", "convert"],
        "remux": ["封装", "remux", "容器"],
        "merge": ["合并", "merge", "combine"],
        "split": ["拆分", "分割", "split"],
        "thumbnail": ["缩略图", "封面", "thumbnail", "poster"],
        "frames": ["抽帧", "帧", "frames"],
        "extract": ["提取", "抽取", "extract"],
        "proxy": ["代理", "proxy", "低码率"],
        "edit": ["编辑", "剪辑", "裁剪", "edit", "cut", "trim"],
        "process": ["处理", "process"],
        "inspect": ["查看", "检查", "分析", "inspect", "analyze", "examine"],
        "read": ["读取", "查看", "read"],
        "export": ["导出", "export"],
        "render": ["渲染", "render"],
        "transcribe": ["转写", "听写", "transcribe", "transcription"],
        "subtitle": ["字幕", "subtitle", "caption"],
        "interpolate": ["补帧", "插帧", "帧率", "interpolate"],
        "superresolution": ["超分", "超分辨率", "放大", "upscale", "super resolution", "superresolution"],
        "super": ["超分", "超分辨率", "super"],
        "resolution": ["分辨率", "resolution"],
        "models": ["模型", "models"],
        "capabilities": ["能力", "capabilities", "支持"],
        "unlock": ["解锁", "解密", "unlock", "decrypt"],
        "fillform": ["表单", "fill"],
        "fromimages": ["图片", "images"],
        "create": ["创建", "新建", "create"],
        "createword": ["word", "docx", "文档"],
        "createworkbook": ["excel", "xlsx", "表格"],
        "createdeck": ["幻灯片", "演示文稿", "ppt", "deck"],
        "qrcode": ["二维码", "qr"]
    ]

    private static func containsAny(_ terms: [String], in query: String) -> Bool {
        let lowered = query.lowercased()
        return terms.contains { term in
            term.unicodeScalars.allSatisfy(\.isASCII)
                ? asciiBoundaryMatch(term, in: lowered)
                : lowered.contains(term)
        }
    }

    /// ASCII terms must not match inside a longer ASCII word: "mov" must not
    /// trigger on "remove", while "转pdf" and "QR码" still match because the
    /// neighbouring character is not an ASCII letter.
    private static func asciiBoundaryMatch(_ term: String, in query: String) -> Bool {
        var searchStart = query.startIndex
        while searchStart < query.endIndex,
              let range = query.range(of: term, range: searchStart..<query.endIndex) {
            let beforeOK = range.lowerBound == query.startIndex
                || !isASCIILetter(query[query.index(before: range.lowerBound)])
            let afterOK = range.upperBound == query.endIndex
                || !isASCIILetter(query[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = query.index(after: range.lowerBound)
        }
        return false
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
    }
}

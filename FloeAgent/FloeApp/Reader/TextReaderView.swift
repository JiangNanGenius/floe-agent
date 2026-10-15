// FloeApp — Read-only text reading mode (TXT / Markdown / Notes text).
//
// SPDX-License-Identifier: MPL-2.0
//
// 阅读模式 is an alternate READ-ONLY view of the same original file or Notes
// document. It never edits, converts or saves the source:
//   - the core (FloeWorkspace.TextReader) streams bounded, line-aligned
//     windows over the original encoded bytes;
//   - this view renders those bounded blocks lazily (no whole-novel SwiftUI
//     layout on the main actor) and appends the next window while scrolling;
//   - typography (size / line spacing / column width / appearance) and the
//     reading position are user preferences only.
// PDF and Office documents keep their existing native previews; this view is
// never used to fake-render them as plain text.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeWorkspace

/// Inline en/zh strings for the reader surface, mirroring the
/// `OfficeInkText` pattern used elsewhere in the app. The primary agent may
/// move these keys into `Localizable.xcstrings` (see O/LOCALIZATION.json).
enum ReaderText {
    static var isChinese: Bool { FloeL10n.isChinese }
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

/// Appearance options for the reader surface only; the app-wide theme is
/// untouched.
enum ReaderAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, warmPaper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: ReaderText.t("跟随系统", "System")
        case .light: ReaderText.t("浅色", "Light")
        case .dark: ReaderText.t("深色", "Dark")
        case .warmPaper: ReaderText.t("暖纸", "Warm Paper")
        }
    }

    var background: Color {
        switch self {
        case .system: FloeTheme.readingSurface
        case .light: Color.white
        case .dark: Color(red: 0.07, green: 0.07, blue: 0.08)
        case .warmPaper: Color(red: 0.96, green: 0.93, blue: 0.86)
        }
    }

    var foreground: Color {
        switch self {
        case .system: Color.primary
        case .light: Color.black
        case .dark: Color(white: 0.92)
        case .warmPaper: Color(red: 0.20, green: 0.16, blue: 0.12)
        }
    }

    /// Markdown blocks draw their own colors; forcing the scheme keeps them
    /// readable on the fixed light/dark/warm surfaces.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .warmPaper: .light
        case .dark: .dark
        }
    }
}

/// Reading column width.
enum ReaderColumn: String, CaseIterable, Identifiable {
    case compact, comfortable, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: ReaderText.t("窄", "Narrow")
        case .comfortable: ReaderText.t("适中", "Comfortable")
        case .full: ReaderText.t("整页", "Full Width")
        }
    }

    var maximumWidth: CGFloat? {
        switch self {
        case .compact: 560
        case .comfortable: 720
        case .full: nil
        }
    }
}

/// Line spacing presets (points added between lines).
enum ReaderLineSpacing: String, CaseIterable, Identifiable {
    case compact, normal, relaxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: ReaderText.t("紧凑", "Compact")
        case .normal: ReaderText.t("标准", "Normal")
        case .relaxed: ReaderText.t("宽松", "Relaxed")
        }
    }

    var points: CGFloat {
        switch self {
        case .compact: 2
        case .normal: 6
        case .relaxed: 11
        }
    }
}

/// Where the current encoding came from. Shown explicitly so an
/// automatically detected value is never confused with the user's own choice.
enum ReaderEncodingOrigin {
    case auto
    case bom
    case userChosen

    var label: String {
        switch self {
        case .auto: ReaderText.t("自动识别", "Auto")
        case .bom: ReaderText.t("文件标记", "File Mark")
        case .userChosen: ReaderText.t("手动选择", "Manual")
        }
    }
}

/// Progress box shared with the core's `@Sendable` progress callback without
/// capturing the model in a nonisolated closure.
private final class ReaderProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func update(_ newValue: Double) {
        lock.lock(); value = newValue; lock.unlock()
    }

    var current: Double {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@MainActor
final class TextReaderModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case opening(progress: Double)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var blocks: [ReaderTextBlock] = []
    @Published private(set) var chapters: [ReaderChapterHeading] = []
    @Published private(set) var encodingLabel = ""
    /// Auto (default) or the encoding the user picked for the current read.
    @Published private(set) var encodingSelection: ReaderEncodingSelection = .auto
    /// The document was reread with a different encoding in this session.
    @Published private(set) var didSwitchEncoding = false
    @Published private(set) var notices: Set<ReaderNotice> = []
    @Published private(set) var hasMore = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lineNumber = 0
    @Published private(set) var totalLines = 0
    @Published private(set) var isAppending = false
    @Published private(set) var findHits: [ReaderFindHit] = []
    @Published private(set) var findTruncated = false
    @Published private(set) var isFinding = false
    /// A stored position was restored for this revision.
    @Published private(set) var restoredPosition = false
    /// A stored position existed but its fingerprint no longer matches.
    @Published private(set) var stalePositionIgnored = false

    private let session = ReaderSession()
    private let positionStore: ReaderPositionStoring
    private let source: TextReaderSource
    private var identity: ReaderDocumentIdentity?
    /// Staged bytes are fetched once per reader session and reused when the
    /// encoding changes, so a remote snapshot is not downloaded again.
    private var cachedBytes: TextReaderBytes?
    private var resolvedEncoding: ReaderTextEncoding?
    private var windowEnd: Int64 = 0
    private var topByte: Int64 = 0
    private var lastSave = Date.distantPast
    private var openGeneration = 0
    /// The in-flight open/index task. Superseding it CANCELS it (a second
    /// encoding choice must abort the previous bounded scan, not merely wait
    /// for it), and the progress loop below also checks the generation so a
    /// late tick can never write an old progress value into the new phase.
    private var openTask: Task<Void, Never>?
    private var switchedEncodingNotice = false
    private var findTask: Task<Void, Never>?

    init(source: TextReaderSource, positionStore: ReaderPositionStoring = ReaderUserDefaultsPositionStore()) {
        self.source = source
        self.positionStore = positionStore
    }

    var title: String { source.displayName }
    var canAppend: Bool { hasMore && !isAppending && phase == .ready }

    /// Explicit detected-vs-user-chosen state for the encoding readout.
    var encodingOrigin: ReaderEncodingOrigin {
        if encodingSelection.isManual { return .userChosen }
        if notices.contains(.byteOrderMarkStripped) { return .bom }
        return .auto
    }

    var encodingSummary: String {
        guard !encodingLabel.isEmpty else { return "" }
        return "\(encodingLabel) · \(encodingOrigin.label)"
    }

    /// Block id (byte offset) that contains `byte`, for scroll anchoring.
    func blockID(containing byte: Int64) -> Int64? {
        blocks.last(where: { $0.byteOffset <= byte })?.id ?? blocks.first?.id
    }

    func open() async {
        if case .ready = phase { return }
        await supersedeOpen(selection: encodingSelection, markSwitch: false)
    }

    /// Cancels any in-flight open/find work (view dismissal). Cancellation
    /// propagates into the bounded scan, so nothing keeps indexing a closed
    /// reader.
    func cancelOpen() {
        openTask?.cancel()
        openTask = nil
        findTask?.cancel()
        findTask = nil
    }

    /// Starts the open as one owned task and cancels any previous one first.
    /// Cancellation propagates into `ReaderSession.open`'s chunk loop, so a
    /// rapid encoding switch really aborts the outgoing scan.
    private func supersedeOpen(selection: ReaderEncodingSelection, markSwitch: Bool) async {
        openTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.openDocument(selection: selection, markSwitch: markSwitch)
        }
        openTask = task
        await task.value
    }

    /// Re-opens with a different encoding choice (or retries the same one
    /// after a failure). Cancels an in-flight find, supersedes the previous
    /// index/window inside the session and starts a fresh bounded read. The
    /// stored position is looked up again, but the core restores it only when
    /// both the revision fingerprint and the encoding it was measured in
    /// still match, so an anchor from another encoding is never restored.
    func selectEncoding(_ selection: ReaderEncodingSelection) async {
        let isRetry = selection == encodingSelection
        if isRetry {
            if case .failed = phase {} else { return }
        }
        findTask?.cancel()
        findHits = []
        findTruncated = false
        isFinding = false
        await supersedeOpen(selection: selection, markSwitch: !isRetry)
    }

    private func openDocument(selection: ReaderEncodingSelection, markSwitch: Bool) async {
        openGeneration += 1
        let generation = openGeneration
        let progressBox = ReaderProgressBox()
        switchedEncodingNotice = markSwitch
        phase = .opening(progress: 0)
        let progressTask = Task { @MainActor in
            // Every tick re-checks BOTH its own cancellation and the open
            // generation: after a newer open started, a late tick from this
            // loop must never overwrite the newer phase.
            while !Task.isCancelled, generation == openGeneration {
                phase = .opening(progress: progressBox.current)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progressTask.cancel() }
        do {
            let bytes = try await bytesForSource()
            try Task.checkCancellation()
            guard generation == openGeneration else { return }
            let identity = ReaderDocumentIdentity(
                kind: source.kind,
                ownerID: source.ownerID,
                documentKey: source.documentKey,
                displayName: source.displayName,
                format: source.format,
                fingerprint: bytes.fingerprint
            )
            self.identity = identity
            let stored = source.persistsPosition ? positionStore.position(for: identity.storageKey) : nil
            let stale = stored != nil && stored?.fingerprint != identity.fingerprint
            let fileSource = ReaderFileSource(
                source: bytes.source,
                identity: identity,
                markdown: source.markdown,
                limits: source.limits
            )
            let result = try await session.open(
                source: fileSource,
                restoring: source.persistsPosition ? stored : nil,
                preferredEncoding: selection,
                progress: { value in progressBox.update(value) }
            )
            guard generation == openGeneration else { return }
            apply(result, stalePosition: stale)
            await fillInitialWindow()
        } catch is CancellationError {
            // Dismissal or a document switch cancelled this open; keep state.
        } catch let error as ReaderError {
            guard generation == openGeneration else { return }
            switchedEncodingNotice = false
            if case .cancelled = error { return }
            if case .superseded = error { return }
            phase = .failed(message(for: error))
        } catch {
            guard generation == openGeneration else { return }
            switchedEncodingNotice = false
            phase = .failed(error.localizedDescription)
        }
    }

    /// Fetches the staged bytes once per reader session; an encoding switch
    /// rereads the same bounded source instead of re-downloading a snapshot.
    private func bytesForSource() async throws -> TextReaderBytes {
        if let cachedBytes { return cachedBytes }
        let bytes = try await source.makeBytes()
        cachedBytes = bytes
        return bytes
    }

    private func apply(_ result: ReaderOpenResult, stalePosition: Bool) {
        blocks = result.window.blocks
        windowEnd = result.window.endByte
        hasMore = result.window.hasMore
        progress = result.window.progress
        lineNumber = result.window.startLineNumber
        totalLines = result.totalLines
        chapters = result.chapters
        encodingLabel = result.encoding.displayName
        encodingSelection = result.encodingSelection
        resolvedEncoding = result.encoding
        didSwitchEncoding = switchedEncodingNotice
        switchedEncodingNotice = false
        notices = Set(result.notices)
        restoredPosition = result.restoredPosition != nil
        stalePositionIgnored = stalePosition
        topByte = result.window.blocks.first?.byteOffset ?? result.window.startByte
        phase = .ready
    }

    /// A window can be very short when lines are long; load a few more so the
    /// first screen is filled without waiting for a scroll gesture.
    private func fillInitialWindow() async {
        var rounds = 0
        while blocks.count < 12, hasMore, rounds < 8 {
            rounds += 1
            let before = blocks.count
            await appendNext()
            if blocks.count == before { break }
        }
    }

    func appendNext() async {
        guard canAppend else { return }
        isAppending = true
        defer { isAppending = false }
        do {
            let window = try await session.window(startByte: windowEnd)
            guard !window.blocks.isEmpty else {
                hasMore = false
                return
            }
            blocks.append(contentsOf: window.blocks)
            windowEnd = window.endByte
            hasMore = window.hasMore
            progress = window.progress
        } catch let error as ReaderError {
            if case .cancelled = error { return }
            if case .superseded = error { return }
        } catch {
            hasMore = false
        }
    }

    /// Replaces the visible window with the one containing `byte`. Returns the
    /// block to anchor the scroll at.
    @discardableResult
    func jump(toByte byte: Int64) async -> Int64? {
        guard case .ready = phase else { return nil }
        isAppending = true
        defer { isAppending = false }
        do {
            let window = try await session.window(startByte: byte)
            guard !window.blocks.isEmpty else { return nil }
            blocks = window.blocks
            windowEnd = window.endByte
            hasMore = window.hasMore
            progress = window.progress
            lineNumber = window.startLineNumber
            topByte = window.blocks.first?.byteOffset ?? byte
            return blockID(containing: byte)
        } catch let error as ReaderError {
            if case .cancelled = error { return nil }
            if case .superseded = error { return nil }
            return nil
        } catch {
            return nil
        }
    }

    func rememberTop(_ byteOffset: Int64) {
        topByte = byteOffset
        if Date().timeIntervalSince(lastSave) > 5 { savePosition() }
    }

    func savePosition() {
        guard source.persistsPosition, let identity, case .ready = phase else { return }
        lastSave = Date()
        let position = ReaderPosition(
            anchorByte: max(0, topByte),
            progress: progress,
            fingerprint: identity.fingerprint,
            encoding: resolvedEncoding
        )
        positionStore.save(position, for: identity.storageKey)
    }

    // MARK: - Find

    func find(_ query: String) {
        findTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, case .ready = phase else {
            findHits = []
            findTruncated = false
            isFinding = false
            return
        }
        isFinding = true
        findTask = Task { @MainActor in
            defer { isFinding = false }
            do {
                let result = try await session.find(needle)
                try Task.checkCancellation()
                findHits = result.hits
                findTruncated = result.truncated
            } catch {
                if Task.isCancelled { return }
                findHits = []
                findTruncated = false
            }
        }
    }

    func clearFind() {
        findTask?.cancel()
        findHits = []
        findTruncated = false
        isFinding = false
    }

    private func message(for error: ReaderError) -> String {
        switch error {
        case .fileTooLarge(let limit):
            let mebibytes = limit / (1024 * 1024)
            return ReaderText.t(
                "文件超过阅读模式的单文件上限（\(mebibytes) MB）。",
                "This file exceeds the reading-mode limit (\(mebibytes) MB)."
            )
        case .emptyDocument:
            return ReaderText.t("文档没有可显示的文字。", "The document has no readable text.")
        case .unrecognizedEncoding:
            return ReaderText.t(
                "无法识别文本编码，为避免乱码没有显示内容。",
                "The text encoding could not be recognized, so nothing was decoded."
            )
        case .corruptText(let offset):
            return ReaderText.t(
                "文件在第 \(offset) 字节处无法解码。",
                "The file could not be decoded at byte \(offset)."
            )
        case .encodingConflict(let chosen):
            return ReaderText.t(
                "文件自带的编码标记与所选编码（\(chosen.displayName)）不一致；请改用自动或匹配的编码。",
                "The file's own encoding mark does not match the selected encoding (\(chosen.displayName)). Choose Auto or the matching encoding."
            )
        case .encodingInvalid(let chosen):
            return ReaderText.t(
                "所选编码（\(chosen.displayName)）无法完整解码此文件；未显示替换字符。可改用自动。",
                "The selected encoding (\(chosen.displayName)) could not decode the whole file; no replacement characters were shown. Try Auto."
            )
        case .sourceUnavailable:
            return ReaderText.t("文件当前不可读取。", "The source could not be read.")
        case .cancelled, .superseded:
            return ""
        }
    }
}

/// Read-only reader sheet. Present it from the file preview or a Notes text
/// document; the existing edit entries stay exactly where they were.
struct TextReaderView: View {
    let source: TextReaderSource

    @StateObject private var model: TextReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @AppStorage("reader.fontSize") private var fontSize: Double = 18
    @AppStorage("reader.lineSpacing") private var lineSpacingRaw = ReaderLineSpacing.normal.rawValue
    @AppStorage("reader.column") private var columnRaw = ReaderColumn.comfortable.rawValue
    @AppStorage("reader.appearance") private var appearanceRaw = ReaderAppearance.system.rawValue

    @State private var topBlockID: Int64?
    @State private var showsChapters = false
    @State private var showsFind = false
    @State private var showsFindResults = false
    @State private var findQuery = ""
    @State private var noticeDismissed = false

    init(source: TextReaderSource) {
        self.source = source
        _model = StateObject(wrappedValue: TextReaderModel(source: source))
    }

    private var lineSpacing: ReaderLineSpacing {
        ReaderLineSpacing(rawValue: lineSpacingRaw) ?? .normal
    }

    private var column: ReaderColumn {
        ReaderColumn(rawValue: columnRaw) ?? .comfortable
    }

    private var appearance: ReaderAppearance {
        ReaderAppearance(rawValue: appearanceRaw) ?? .system
    }

    /// Encodings the UI may offer: GB18030 only when this runtime really has
    /// the codec, so an unavailable encoding is never advertised.
    private var encodingOptions: [ReaderTextEncoding] {
        ReaderEncodingSelection.selectableEncodings(gb18030Available: ReaderTextCodec.gb18030CodecAvailable)
    }

    private var encodingBinding: Binding<ReaderEncodingSelection> {
        Binding(
            get: { model.encodingSelection },
            set: { selection in
                topBlockID = nil
                Task { await model.selectEncoding(selection) }
            }
        )
    }

    private var encodingOriginDescription: String {
        switch model.encodingOrigin {
        case .userChosen:
            return ReaderText.t(
                "按所选编码读取；不会写回文件。",
                "Read with the chosen encoding. The file is never written."
            )
        case .bom:
            return ReaderText.t(
                "编码来自文件自带的标记。",
                "The encoding comes from the file's own mark."
            )
        case .auto:
            return ReaderText.t(
                "自动识别；文字显示不对时可手动选择。",
                "Detected automatically; choose manually if the text looks wrong."
            )
        }
    }

    /// Encoding recovery, reachable from reading settings and from the error
    /// state so an unrecognized document can still be read by choosing an
    /// encoding. Selecting never writes to the source and never installs a
    /// codec; the reader still validates the whole stream.
    private var encodingMenu: some View {
        Menu {
            Button(ReaderText.t("自动（默认）", "Auto (Default)")) {
                topBlockID = nil
                Task { await model.selectEncoding(.auto) }
            }
            ForEach(encodingOptions, id: \.self) { encoding in
                Button(encoding.displayName) {
                    topBlockID = nil
                    Task { await model.selectEncoding(.manual(encoding)) }
                }
            }
        } label: {
            Label(ReaderText.t("选择编码", "Choose Encoding"), systemImage: "textformat")
        }
        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        .accessibilityIdentifier("reader.encoding")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                appearance.background.ignoresSafeArea()
                content
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsFind { findBar }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if case .ready = model.phase { statusBar }
            }
            .task { await model.open() }
            .onChange(of: scenePhase) { _, value in
                if value != .active { model.savePosition() }
            }
            .onDisappear {
                model.savePosition()
                model.cancelOpen()
            }
            .sheet(isPresented: $showsChapters) { chaptersSheet }
            .sheet(isPresented: $showsFindResults) { findResultsSheet }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            openingView(progress: 0)
        case .opening(let progress):
            openingView(progress: progress)
        case .failed(let message):
            ContentUnavailableView {
                Label(ReaderText.t("无法打开", "Can't Open"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                encodingMenu
                Button(ReaderText.t("关闭", "Close")) { dismiss() }
            }
        case .ready:
            if model.blocks.isEmpty {
                ContentUnavailableView {
                    Label(ReaderText.t("没有文字", "No Text"), systemImage: "doc")
                } description: {
                    Text(ReaderText.t("这份文档没有可显示的文字内容。", "This document has no readable text."))
                }
            } else {
                readerScroll
            }
        }
    }

    private func openingView(progress: Double) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            if progress > 0.01 {
                Text(ReaderText.t("正在建立索引 \(Int(progress * 100))%", "Indexing \(Int(progress * 100))%"))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                Text(ReaderText.t("正在打开…", "Opening…"))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readerScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let notice = readingNotice, !noticeDismissed {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(notice).font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            noticeDismissed = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .accessibilityLabel(ReaderText.t("关闭提示", "Dismiss"))
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("reader.notice")
                }
                ForEach(model.blocks) { block in
                    blockView(block)
                        .id(block.id)
                }
                if model.isAppending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(ReaderText.t("载入后续内容…", "Loading more…"))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, sizeClass == .compact ? 16 : 24)
            .padding(.vertical, 16)
            .frame(maxWidth: column.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $topBlockID, anchor: .top)
        .accessibilityIdentifier("reader.content")
        .onChange(of: topBlockID) { _, value in
            guard let value else { return }
            model.rememberTop(value)
            if let index = model.blocks.firstIndex(where: { $0.id == value }),
               index >= model.blocks.count - 40 {
                Task { await model.appendNext() }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReaderTextBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(.system(size: headingFontSize(level), weight: .semibold))
                .foregroundStyle(appearance.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 1 ? 10 : 6)
                .textSelection(.enabled)
                .accessibilityIdentifier("reader.heading.\(block.id)")
        case .body:
            if source.markdown {
                // The existing renderer is reused per bounded block; the
                // whole document is never parsed at once here.
                MarkdownRendererView(source: block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(block.text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing.points)
                    .foregroundStyle(appearance.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reader.block.\(block.id)")
            }
        }
    }

    private func headingFontSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: fontSize + 6
        case 2: fontSize + 4
        case 3: fontSize + 2
        default: fontSize + 1
        }
    }

    /// One honest boundary line: what the reader could not include.
    private var readingNotice: String? {
        if source.hasNonTextContent {
            return ReaderText.t(
                "此手记包含墨迹或图片，阅读模式只显示文字内容。",
                "This note also contains ink or images; reading mode shows the text only."
            )
        }
        if source.isRemoteSnapshot {
            return ReaderText.t(
                "云端或网络文件已下载后阅读。",
                "The cloud or network file was downloaded for reading."
            )
        }
        if model.stalePositionIgnored {
            return ReaderText.t(
                "文件已更新，未恢复上次阅读位置。",
                "The document changed, so the last reading position was not restored."
            )
        }
        if model.restoredPosition {
            return ReaderText.t("已恢复上次阅读位置。", "Resumed from your last reading position.")
        }
        if model.didSwitchEncoding {
            return ReaderText.t("已按所选编码重新读取。", "Reread with the selected encoding.")
        }
        return nil
    }

    // MARK: - Find

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(ReaderText.t("查找", "Find"), text: $findQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    model.find(findQuery)
                    showsFindResults = true
                }
                .accessibilityIdentifier("reader.find.field")
            if model.isFinding {
                ProgressView()
            }
            Button {
                showsFind = false
                model.clearFind()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .accessibilityLabel(ReaderText.t("关闭查找", "Close Find"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FloeTheme.chromeMaterial)
    }

    private var chaptersSheet: some View {
        NavigationStack {
            List(model.chapters) { chapter in
                Button {
                    showsChapters = false
                    Task {
                        if let target = await model.jump(toByte: chapter.byteOffset) {
                            topBlockID = target
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(chapter.title)
                            .font(chapter.level <= 1 ? .body.weight(.semibold) : .body)
                            .padding(.leading, CGFloat(max(0, min(chapter.level, 3) - 1)) * 14)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if chapter.lineNumber > 0 {
                            Text(ReaderText.t("第 \(chapter.lineNumber) 行", "Line \(chapter.lineNumber)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("reader.chapter.\(chapter.byteOffset)")
            }
            .navigationTitle(ReaderText.t("目录", "Contents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ReaderText.t("完成", "Done")) { showsChapters = false }
                }
            }
            .overlay {
                if model.chapters.isEmpty {
                    ContentUnavailableView {
                        Label(ReaderText.t("没有章节", "No Chapters"), systemImage: "list.bullet")
                    } description: {
                        Text(ReaderText.t(
                            "未识别到“第…章/Chapter …”等确定性标题。",
                            "No deterministic headings (第…章 / Chapter …) were found."
                        ))
                    }
                }
            }
        }
    }

    private var findResultsSheet: some View {
        NavigationStack {
            Group {
                if model.isFinding {
                    ProgressView(ReaderText.t("查找中…", "Searching…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.findHits.isEmpty {
                    ContentUnavailableView(
                        ReaderText.t("没有找到", "No Matches"),
                        systemImage: "magnifyingglass",
                        description: Text(ReaderText.t("试试其他关键词。", "Try a different keyword."))
                    )
                } else {
                    List(model.findHits) { hit in
                        Button {
                            showsFindResults = false
                            Task {
                                if let target = await model.jump(toByte: hit.byteOffset) {
                                    topBlockID = target
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.snippet)
                                    .font(FloeTheme.Typography.body)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    if hit.lineNumber > 0 {
                                        Text(ReaderText.t("第 \(hit.lineNumber) 行", "Line \(hit.lineNumber)"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !hit.exactOffset {
                                        Text(ReaderText.t("位置为该窗口起始处", "Position points to the window start"))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if model.findTruncated {
                            Text(ReaderText.t("仅显示前 \(model.findHits.count) 条结果。", "Showing the first \(model.findHits.count) matches."))
                                .font(FloeTheme.Typography.metadata)
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(FloeTheme.chromeMaterial)
                        }
                    }
                }
            }
            .navigationTitle(ReaderText.t("查找结果", "Matches"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ReaderText.t("完成", "Done")) { showsFindResults = false }
                }
            }
        }
    }

    // MARK: - Toolbar and status

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                model.savePosition()
                dismiss()
            } label: {
                Label(ReaderText.t("关闭", "Close"), systemImage: "xmark")
            }
            .accessibilityIdentifier("reader.close")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showsChapters = true
            } label: {
                Label(ReaderText.t("目录", "Contents"), systemImage: "list.bullet")
            }
            .disabled(model.chapters.isEmpty)
            .accessibilityIdentifier("reader.chapters")

            Button {
                showsFind.toggle()
                if !showsFind { model.clearFind() }
            } label: {
                Label(ReaderText.t("查找", "Find"), systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("reader.find")

            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Section(ReaderText.t("字号", "Text Size")) {
                Button {
                    fontSize = max(13, fontSize - 2)
                } label: {
                    Label(ReaderText.t("减小", "Smaller"), systemImage: "textformat.size.smaller")
                }
                .disabled(fontSize <= 13)
                Button {
                    fontSize = min(32, fontSize + 2)
                } label: {
                    Label(ReaderText.t("增大", "Larger"), systemImage: "textformat.size.larger")
                }
                .disabled(fontSize >= 32)
            }
            Section(ReaderText.t("行距", "Line Spacing")) {
                Picker(ReaderText.t("行距", "Line Spacing"), selection: $lineSpacingRaw) {
                    ForEach(ReaderLineSpacing.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            }
            Section(ReaderText.t("栏宽", "Column Width")) {
                Picker(ReaderText.t("栏宽", "Column Width"), selection: $columnRaw) {
                    ForEach(ReaderColumn.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            }
            Section(ReaderText.t("外观", "Appearance")) {
                Picker(ReaderText.t("外观", "Appearance"), selection: $appearanceRaw) {
                    ForEach(ReaderAppearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            }
            Section(ReaderText.t("编码", "Encoding")) {
                Picker(ReaderText.t("编码", "Encoding"), selection: encodingBinding) {
                    Text(ReaderText.t("自动（默认）", "Auto (Default)")).tag(ReaderEncodingSelection.auto)
                    ForEach(encodingOptions, id: \.self) { encoding in
                        Text(encoding.displayName).tag(ReaderEncodingSelection.manual(encoding))
                    }
                }
                Text(encodingOriginDescription)
            }
            if model.notices.contains(.lineTableTruncated)
                || model.notices.contains(.displayLineShortened)
                || model.notices.contains(.chaptersTruncated) {
                Section(ReaderText.t("说明", "Details")) {
                    if model.notices.contains(.lineTableTruncated) {
                        Text(ReaderText.t(
                            "文件很大，行号索引未完整建立；阅读与位置保存不受影响。",
                            "This file is large, so the line index is partial; reading and positions still work."
                        ))
                    }
                    if model.notices.contains(.chaptersTruncated) {
                        Text(ReaderText.t("目录过多，仅列出前面部分。", "The contents list shows the first part only."))
                    }
                    if model.notices.contains(.displayLineShortened) {
                        Text(ReaderText.t("有个别超长行被分段显示。", "A few extremely long lines are shown in segments."))
                    }
                }
            }
        } label: {
            Label(ReaderText.t("阅读设置", "Reading Settings"), systemImage: "textformat")
        }
        .accessibilityIdentifier("reader.settings")
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(ReaderText.t("已读 \(Int(model.progress * 100))%", "\(Int(model.progress * 100))% read"))
            if model.lineNumber > 0, model.totalLines > 0 {
                Text(ReaderText.t("第 \(model.lineNumber) 行 / 共 \(model.totalLines) 行",
                                  "Line \(model.lineNumber) of \(model.totalLines)"))
            }
            Spacer(minLength: 0)
            Text(model.encodingSummary)
            if model.hasMore {
                Text(ReaderText.t("还有更多", "More below"))
            }
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(FloeTheme.chromeMaterial)
        .accessibilityIdentifier("reader.status")
    }
}
#endif

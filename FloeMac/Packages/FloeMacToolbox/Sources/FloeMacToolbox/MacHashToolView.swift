import AppKit
import Combine
import SwiftUI
import FloeToolboxUtilities

@MainActor
final class MacHashModel: ObservableObject {
    @Published var algorithm = ToolboxChecksumAlgorithm.sha256 {
        didSet {
            guard algorithm != oldValue else { return }
            cancel()
            result = nil
            title = ""
            completedBytes = 0
            expectedBytes = nil
            failed = false
            cancelled = false
        }
    }
    @Published var comparison = ""
    @Published private(set) var result: ToolboxChecksum?
    @Published private(set) var title = ""
    @Published private(set) var completedBytes: UInt64 = 0
    @Published private(set) var expectedBytes: UInt64?
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var cancelled = false
    @Published private(set) var stopping = false

    private let selectFile: @MainActor () async throws -> MacChecksumSelection?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(selectFile: @escaping @MainActor () async throws -> MacChecksumSelection?) {
        self.selectFile = selectFile
    }

    func selectAndCalculate() {
        guard !busy else { return }
        let selectedAlgorithm = algorithm
        let run = UUID()
        generation = run
        busy = true
        failed = false
        cancelled = false
        stopping = false
        completedBytes = 0
        expectedBytes = nil
        result = nil
        title = ""
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == run {
                    self.busy = false
                    self.stopping = false
                    self.operation = nil
                }
            }
            do {
                guard let selection = try await self.selectFile() else {
                    if self.generation == run { self.busy = false; self.operation = nil }
                    return
                }
                guard self.generation == run, !Task.isCancelled, self.algorithm == selectedAlgorithm else { return }
                self.title = selection.title
                self.expectedBytes = selection.byteCount
                let read = selection.read
                let work = Task.detached(priority: .userInitiated) { [weak self] in
                    try await ToolboxFileChecksum.calculate(
                        selectedAlgorithm,
                        expectedByteCount: selection.byteCount,
                        read: read,
                        progress: { [weak self] bytes in
                            await self?.progress(bytes, run: run)
                        }
                    )
                }
                let value = try await withTaskCancellationHandler(
                    operation: { try await work.value },
                    onCancel: { work.cancel() }
                )
                guard self.generation == run, !Task.isCancelled else { return }
                self.result = value
                self.busy = false
                self.operation = nil
            } catch {
                guard self.generation == run else { return }
                let wasCancelled = error is CancellationError || Task.isCancelled
                self.failed = !wasCancelled
                self.cancelled = wasCancelled
            }
        }
    }

    func cancel() {
        guard busy || operation != nil else { return }
        operation?.cancel()
        stopping = true
        cancelled = true
    }

    private func progress(_ bytes: UInt64, run: UUID) {
        guard generation == run, busy, !stopping else { return }
        completedBytes = bytes
    }
}

struct MacHashToolView: View {
    @Environment(\.locale) private var locale
    @StateObject private var model: MacHashModel
    @StateObject private var textModel = MacTextChecksumModel()
    @State private var mode: ChecksumMode = .file
    @State private var copied = false

    private enum ChecksumMode: Hashable { case file, text }

    init(selectFile: @escaping @MainActor () async throws -> MacChecksumSelection?) {
        _model = StateObject(wrappedValue: MacHashModel(selectFile: selectFile))
    }

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(t("校验内容", "Checksum input"), selection: $mode) {
                Text(t("文件", "File")).tag(ChecksumMode.file)
                Text(t("文本", "Text")).tag(ChecksumMode.text)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(16)
            .accessibilityIdentifier("mac.toolbox.hash.input-mode")
            Divider()
            if mode == .file { fileContent }
            else { MacTextChecksumView(model: textModel) }
        }
        .onChange(of: mode) { _, value in
            if value == .text { model.cancel() }
            else { textModel.cancel() }
        }
        .onDisappear { model.cancel(); textModel.cancel() }
        .background(MacHashWindowCloseObserver { model.cancel(); textModel.cancel() }.frame(width: 0, height: 0))
    }

    private var fileContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                selectionCard
                if model.busy { progressCard }
                if let result = model.result { resultCard(result) }
                if model.failed { failureCard }
                if model.cancelled, !model.busy { cancelledCard }
                if !model.busy, model.result == nil, !model.failed, !model.cancelled { emptyCard }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.result) { _, _ in copied = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(t("校验文件", "Verify a file"), systemImage: "checkmark.seal")
                .font(.title2.weight(.semibold))
            Text(t("计算 SHA-256、SHA-512、SHA-1、MD5 或 CRC32，并与来源提供的校验值比较。",
                   "Calculate SHA-256, SHA-512, SHA-1, MD5 or CRC32 and compare it with the value supplied by the source."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Picker(t("算法", "Algorithm"), selection: $model.algorithm) {
                    ForEach(ToolboxChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.rawValue.uppercased()).tag(algorithm)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .disabled(model.busy)
                .accessibilityIdentifier("mac.toolbox.hash.algorithm")

                Button {
                    model.selectAndCalculate()
                } label: {
                    Label(model.failed ? t("重新选择文件并计算", "Choose a file and retry") : t("选择文件并计算", "Choose file and calculate"),
                          systemImage: "doc.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.busy)
                .accessibilityIdentifier("mac.toolbox.hash.choose")

                if model.busy {
                    Button(t("停止校验", "Stop"), systemImage: "stop.circle") {
                        model.cancel()
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.stopping)
                    .accessibilityIdentifier("mac.toolbox.hash.cancel")
                }
                Spacer()
            }
            if !model.title.isEmpty {
                LabeledContent(t("文件", "File")) {
                    Text(model.title)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if let expected = model.expectedBytes {
                LabeledContent(t("文件大小", "File size"), value: bytesText(expected))
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.stopping {
                ProgressView(t("正在停止校验", "Stopping checksum"))
            } else if let total = model.expectedBytes, total > 0 {
                ProgressView(t("正在计算摘要", "Calculating checksum"),
                             value: Double(min(model.completedBytes, total)),
                             total: Double(total))
            } else {
                ProgressView(t("正在计算摘要", "Calculating checksum"))
            }
            HStack {
                Text(bytesText(model.completedBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .background(cardBackground)
        .accessibilityIdentifier("mac.toolbox.hash.progress")
    }

    private func resultCard(_ result: ToolboxChecksum) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(t("校验结果", "Checksum result"), systemImage: "checkmark.circle")
                .font(.headline)
            LabeledContent(t("算法", "Algorithm"), value: result.algorithm.rawValue.uppercased())
            LabeledContent(t("文件大小", "File size"), value: bytesText(result.byteCount))
            Text(result.hexadecimal)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("mac.toolbox.hash.result")
            HStack(spacing: 12) {
                Button(copied ? t("已复制", "Copied") : t("复制校验值", "Copy checksum"),
                       systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copy(result.hexadecimal)
                    copied = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityIdentifier("mac.toolbox.hash.copy")
                ShareLink(item: result.hexadecimal) {
                    Label(t("分享校验值", "Share checksum"), systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(t("比较校验值", "Compare checksum")).font(.headline)
                TextField(t("粘贴来源提供的校验值", "Paste the checksum supplied by the source"),
                          text: $model.comparison, axis: .vertical)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.toolbox.hash.comparison")
                if !model.comparison.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let matches = result.matches(model.comparison)
                    Label(matches ? t("校验值一致", "Checksums match") : t("校验值不一致", "Checksums do not match"),
                          systemImage: matches ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(matches ? Color.green : Color.red)
                        .accessibilityIdentifier("mac.toolbox.hash.match")
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t("未能完成校验", "Unable to complete checksum"), systemImage: "exclamationmark.triangle")
            Text(t("请重新选择文件再试，未生成新的校验结果。",
                   "Choose the file again to retry. No new checksum was produced."))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var cancelledCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t("校验已停止", "Checksum stopped"), systemImage: "stop.circle")
            Text(t("可以重新选择文件继续。", "Choose a file to start again."))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var emptyCard: some View {
        ContentUnavailableView {
            Label(t("尚无校验结果", "No checksum yet"), systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(t("选择文件后计算摘要，并可与来源提供的校验值比较。",
                   "Choose a file to calculate its checksum, then compare it with the value supplied by the source."))
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var cardBackground: some ShapeStyle {
        Color(nsColor: .controlBackgroundColor)
    }

    private func bytesText(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Observes only the window containing this view, so closing another Floe
/// window cannot cancel a running checksum.
private struct MacHashWindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> MacHashWindowCloseView {
        let view = MacHashWindowCloseView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: MacHashWindowCloseView, context: Context) {
        view.onClose = onClose
    }
}

private final class MacHashWindowCloseView: NSView {
    var onClose: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

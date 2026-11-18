import AppKit
import Combine
import SwiftUI
import FloeToolboxUtilities

@MainActor
final class MacTextChecksumModel: ObservableObject {
    typealias Calculator = @Sendable (Data, ToolboxChecksumAlgorithm) async throws -> ToolboxChecksum
    static let maximumInputBytes = 1_048_576

    // String equality is Unicode-canonical, while the checksum hashes exact
    // UTF-8 bytes. Every edit must fence an earlier result or calculation.
    @Published var input = "" { didSet { invalidate() } }
    @Published var algorithm = ToolboxChecksumAlgorithm.sha256 { didSet { if algorithm != oldValue { invalidate() } } }
    @Published var comparison = ""
    @Published private(set) var result: ToolboxChecksum?
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var tooLarge = false

    private let calculator: Calculator
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(calculator: @escaping Calculator = MacTextChecksumModel.checksum) { self.calculator = calculator }

    nonisolated static func checksum(_ data: Data, _ algorithm: ToolboxChecksumAlgorithm) async throws -> ToolboxChecksum {
        try await ToolboxFileChecksum.calculate(algorithm, expectedByteCount: UInt64(data.count),
                                                maximumBytes: UInt64(maximumInputBytes)) { offset, count in
            guard offset < UInt64(data.count) else { return Data() }
            let start = Int(offset)
            let end = min(start + count, data.count)
            return Data(data[start..<end])
        }
    }

    func calculate() {
        guard !busy else { return }
        guard input.utf8.count <= Self.maximumInputBytes else {
            result = nil; failed = false; tooLarge = true
            return
        }
        let bytes = Data(input.utf8), selected = algorithm, calculate = calculator
        let ticket = UUID()
        generation = ticket; result = nil; failed = false; tooLarge = false; busy = true
        operation = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { try await calculate(bytes, selected) }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.result = value; self.busy = false; self.operation = nil
            } catch {
                guard let self, self.generation == ticket else { return }
                self.failed = !(error is CancellationError) && !Task.isCancelled
                self.busy = false; self.operation = nil
            }
        }
    }

    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
    }

    private func invalidate() {
        cancel(); result = nil; failed = false; tooLarge = false
    }
}

struct MacTextChecksumView: View {
    @ObservedObject var model: MacTextChecksumModel
    @Environment(\.locale) private var locale
    @State private var copied = false

    private func t(_ zh: String, _ en: String) -> String { MacToolboxText.t(zh, en, locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("校验文本", "Verify text"), systemImage: "text.alignleft")
                .font(.title2.weight(.semibold))
            Text(t("按 UTF-8 计算文本摘要。空格和换行也会影响结果。", "Calculate a UTF-8 checksum. Spaces and line breaks affect the result."))
                .foregroundStyle(.secondary)
            HStack {
                Picker(t("算法", "Algorithm"), selection: $model.algorithm) {
                    ForEach(ToolboxChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.rawValue.uppercased()).tag(algorithm)
                    }
                }
                .frame(width: 210)
                Button(t("计算", "Calculate")) { model.calculate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy)
                    .accessibilityIdentifier("mac.toolbox.hash.text.calculate")
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            TextEditor(text: $model.input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .accessibilityLabel(t("待校验文本", "Text to verify"))
                .accessibilityIdentifier("mac.toolbox.hash.text.input")
                .border(Color.secondary.opacity(0.25))
            Text(t("最多 1 MiB UTF-8 文本。", "Up to 1 MiB of UTF-8 text."))
                .font(.caption).foregroundStyle(.secondary)
            if model.tooLarge {
                Label(t("文本过长，请缩短后重试。", "Text is too long. Shorten it and try again."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if model.failed {
                Label(t("未能计算，请重试。", "Could not calculate. Try again."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if let result = model.result {
                HStack(alignment: .top) {
                    Text(result.hexadecimal).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("mac.toolbox.hash.text.result")
                    Spacer()
                    Button(copied ? t("已复制", "Copied") : t("复制", "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.hexadecimal, forType: .string)
                        copied = true
                    }
                }
                TextField(t("比较校验值（可选）", "Compare checksum (optional)"), text: $model.comparison)
                    .textFieldStyle(.roundedBorder)
                if !model.comparison.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(result.matches(model.comparison) ? t("校验值一致", "Checksums match") : t("校验值不一致", "Checksums do not match"),
                          systemImage: result.matches(model.comparison) ? "checkmark.circle" : "xmark.circle")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.result) { _, _ in copied = false }
        .onDisappear { model.cancel() }
    }
}

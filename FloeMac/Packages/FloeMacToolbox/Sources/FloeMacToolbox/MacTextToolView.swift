import AppKit
import Combine
import SwiftUI
import FloeToolboxUtilities

enum MacTextAction: String, CaseIterable, Hashable, Sendable {
    case formatJSON, compactJSON, sortJSON
    case base64Encode, base64Decode, urlEncode, urlDecode

    func title(_ locale: Locale) -> String {
        switch self {
        case .formatJSON: MacToolboxText.t("格式化 JSON", "Format JSON", locale)
        case .compactJSON: MacToolboxText.t("压缩 JSON", "Compact JSON", locale)
        case .sortJSON: MacToolboxText.t("按键名排序", "Sort JSON keys", locale)
        case .base64Encode: MacToolboxText.t("Base64 编码", "Base64 encode", locale)
        case .base64Decode: MacToolboxText.t("Base64 解码", "Base64 decode", locale)
        case .urlEncode: MacToolboxText.t("URL 编码", "URL encode", locale)
        case .urlDecode: MacToolboxText.t("URL 解码", "URL decode", locale)
        }
    }
}

@MainActor
final class MacTextUtilityModel: ObservableObject {
    @Published var input = "" {
        didSet { if input != oldValue { output = ""; errorDetail = nil; lastAction = nil } }
    }
    @Published private(set) var output = ""
    @Published private(set) var errorDetail: String?
    @Published private(set) var lastAction: MacTextAction?

    var failed: Bool { errorDetail != nil }

    func perform(_ action: MacTextAction) {
        let frozen = input
        output = ""
        errorDetail = nil
        lastAction = action
        do {
            switch action {
            case .formatJSON: output = try ToolboxJSON.format(frozen)
            case .compactJSON: output = try ToolboxJSON.format(frozen, style: .compact)
            case .sortJSON: output = try ToolboxJSON.format(frozen, style: .sorted)
            case .base64Encode: output = try ToolboxTextEncoding.base64Encode(frozen)
            case .base64Decode: output = try ToolboxTextEncoding.base64Decode(frozen)
            case .urlEncode: output = try ToolboxTextEncoding.urlEncode(frozen)
            case .urlDecode: output = try ToolboxTextEncoding.urlDecode(frozen)
            }
        } catch {
            output = ""
            errorDetail = String(reflecting: error)
        }
    }
}

struct MacTextToolView: View {
    enum Mode: Sendable { case json, encoding }

    @Environment(\.locale) private var locale
    @StateObject private var model = MacTextUtilityModel()
    @State private var action: MacTextAction
    @State private var copied = false
    @FocusState private var inputFocused: Bool
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        _action = State(initialValue: mode == .json ? .formatJSON : .base64Encode)
    }

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

    private var actions: [MacTextAction] {
        mode == .json ? [.formatJSON, .compactJSON, .sortJSON]
            : [.base64Encode, .base64Decode, .urlEncode, .urlDecode]
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            HSplitView {
                inputPane
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                resultPane
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.output) { _, _ in copied = false }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Picker(t("转换方式", "Conversion"), selection: $action) {
                ForEach(actions, id: \.self) { action in
                    Text(action.title(locale)).tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)
            .accessibilityIdentifier("mac.toolbox.utility.operation")

            Button {
                inputFocused = false
                model.perform(action)
            } label: {
                Label(model.failed ? t("重试转换", "Retry conversion") : action.title(locale),
                      systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.input.isEmpty)
            .accessibilityIdentifier("mac.toolbox.utility.convert")

            Spacer()
            Text(t("⌘↩ 转换 · ⇧⌘C 复制", "⌘↩ convert · ⇧⌘C copy"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t("输入", "Input"), systemImage: "text.cursor")
                .font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.input)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(t("输入内容", "Input text"))
                    .accessibilityIdentifier("mac.toolbox.utility.input")
                if model.input.isEmpty {
                    Text(mode == .json
                         ? t("粘贴 JSON 内容", "Paste JSON here")
                         : t("输入要编码或解码的文本", "Enter text to encode or decode"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
    }

    @ViewBuilder private var resultPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t("结果", "Result"), systemImage: "text.alignleft")
                .font(.headline)
            if let detail = model.errorDetail {
                VStack(alignment: .leading, spacing: 10) {
                    Label(t("未能转换", "Unable to convert"), systemImage: "exclamationmark.triangle")
                    Text(t("请检查输入格式，修改后重新转换。", "Check the input format, edit it and convert again."))
                        .foregroundStyle(.secondary)
                    DisclosureGroup(t("查看详情", "View details")) {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let lastAction = model.lastAction {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lastAction.title(locale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if model.output.isEmpty {
                        ContentUnavailableView(t("结果为空", "Empty result"),
                                               systemImage: "text.alignleft",
                                               description: Text(t("转换已完成，输出为空。", "Conversion completed with empty output.")))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(model.output)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("mac.toolbox.utility.result")
                        HStack(spacing: 12) {
                            Button(copied ? t("已复制", "Copied") : t("复制结果", "Copy result"),
                                   systemImage: copied ? "checkmark" : "doc.on.doc") {
                                copy(model.output)
                                copied = true
                            }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                            .accessibilityIdentifier("mac.toolbox.utility.copy")
                            ShareLink(item: model.output) {
                                Label(t("分享结果", "Share result"), systemImage: "square.and.arrow.up")
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label(t("等待转换", "Ready to convert"), systemImage: "arrow.left.arrow.right")
                } description: {
                    Text(t("输入内容并选择转换方式，结果会显示在这里。",
                           "Enter text and choose a conversion. The result appears here."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeToolboxCore

/// Embedded in the original tool's Form. Reuse is always an explicit user action.
struct ToolboxHistorySection: View {
    let tool: ToolboxTool
    @ObservedObject var history: ToolboxHistoryStore
    var runsImmediately = false
    var busy = false
    let reuse: (ToolboxHistoryConfiguration) -> Void
    @State private var expanded = false
    @State private var confirmingClear = false
    @Environment(\.locale) private var locale
    private func text(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
    private var records: [ToolboxHistoryEntry] {
        history.records(for: tool).filter {
            tool != .serialAssistant || $0.configuration.serial.connection != .usb || ToolboxConnection.includesUSBSerialDriver
        }
    }
    var body: some View {
        Section {
            if records.isEmpty {
                Text(text("尚无使用记录", "No history yet")).foregroundStyle(.secondary)
            }
            ForEach(Array(records.prefix(expanded ? ToolboxHistoryStore.maximumPerTool : 4))) { entry in
                HStack(spacing: 12) {
                    Button {
                        guard !busy else { return }; reuse(entry.configuration)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if entry.pinned { Image(systemName: "pin.fill").font(.caption) }
                                Text(entry.configuration.label).lineLimit(2)
                            }
                            HStack {
                                Text(outcome(entry))
                                Text(entry.usedAt, format: .dateTime.month().day().hour().minute())
                            }.font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityHint(runsImmediately ? text("使用此参数再次运行", "Run again with these parameters") : text("填入设置，不自动连接", "Fill settings without connecting"))
                        .accessibilityIdentifier("toolbox.history.reuse.\(entry.id.uuidString)")
                    Menu {
                        Button(entry.pinned ? text("取消固定", "Unpin") : text("固定", "Pin"), systemImage: entry.pinned ? "pin.slash" : "pin") { history.togglePin(entry.id) }
                            .disabled(!entry.pinned && records.filter(\.pinned).count >= 8)
                        Button(text("删除", "Delete"), systemImage: "trash", role: .destructive) { history.delete(entry.id) }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel(text("记录操作", "History actions"))
                }
            }
            if records.count > 4 {
                Button(expanded ? text("收起记录", "Show less") : text("显示全部记录", "Show all history")) { expanded.toggle() }
            }
            if !records.isEmpty {
                Button(text("清空此工具的记录", "Clear this tool’s history"), role: .destructive) { confirmingClear = true }
                    .accessibilityIdentifier("toolbox.history.clear")
            }
            if history.persistenceFailed {
                Text(text("历史暂时无法保存，原记录未被覆盖。", "History could not be saved. Existing records were preserved."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(text("历史记录", "History")) }
            footer: {
                Text(runsImmediately ? text("点选后再次运行。", "Tap a record to run it again.")
                     : ([ToolboxTool.http, .webSocket].contains(tool)
                        ? text("仅保留服务器地址，请补全请求地址后连接。认证信息、路径和查询参数不会保存。", "Only the server address is retained. Complete the URL before connecting. Credentials, paths and query parameters are not saved.")
                        : text("仅填入设置，请确认后连接。", "Fills settings only. Confirm before connecting.")))
            }
            .accessibilityIdentifier("toolbox.history.\(tool.rawValue)")
            .confirmationDialog(text("清空此工具的历史记录？", "Clear this tool’s history?"), isPresented: $confirmingClear, titleVisibility: .visible) {
                Button(text("清空记录", "Clear history"), role: .destructive) { history.clear(tool) }
                Button(text("取消", "Cancel"), role: .cancel) { }
            }
    }
    private func outcome(_ entry: ToolboxHistoryEntry) -> String {
        switch entry.outcome {
        case .started: text("已发起", "Started")
        case .ready: tool == .http ? text("已打开", "Opened") : text("已连接", "Connected")
        case .completed: text("已完成", "Completed")
        case .failed: text("未完成", "Failed")
        case .cancelled: text("已停止", "Stopped")
        case .interrupted: text("已中断", "Interrupted")
        }
    }
}
#endif

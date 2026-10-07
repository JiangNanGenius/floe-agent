// FloeApp — SSH terminal surface.
//
// SPDX-License-Identifier: MPL-2.0
//
// A PTY surface bound to a session snapshot. The connection is owned by
// RemoteSessionCenter, so dismissing this view does NOT kill the session.
// Monospaced evidence type for output; an input field for sending; an
// honest disconnected/unknown state when the session is not interactive.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import SwiftTerm
import UIKit

/// The terminal screen for one SSH session.
struct TerminalView: View {
    @StateObject private var viewModel: TerminalViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = false

    init(sessionID: UUID, center: RemoteSessionCenter) {
        _viewModel = StateObject(
            wrappedValue: TerminalViewModel(sessionID: sessionID, center: center)
        )
    }

    var body: some View {
        Group { if expanded { Color.clear } else { content } }
            .fullScreenCover(isPresented: $expanded) { content }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                statusBar
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }.accessibilityLabel(IDELanguageRunText.t("切换全屏", "Toggle full screen"))
            }
            TerminalControls(presentation: viewModel.presentation, interactive: viewModel.isInteractive) { data in Task { await viewModel.send(data) } }
            if let error = viewModel.error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            SSHEmulatorView(
                output: viewModel.outputData,
                byteEnd: viewModel.outputEnd,
                generation: viewModel.sessionID,
                presentation: viewModel.presentation,
                isInteractive: viewModel.isInteractive,
                onSend: { data in
                    Task { await viewModel.send(data) }
                },
                onResize: { columns, rows in
                    Task { await viewModel.resize(columns: columns, rows: rows) }
                }
            )
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("hosts.terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    Task {
                        await viewModel.disconnect()
                        dismiss()
                    }
                } label: {
                    Label("action.disconnect", systemImage: "xmark.circle")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .task { viewModel.refresh() }
        .onReceive(viewModel.center.objectWillChange) { _ in
            viewModel.refresh()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(statusText)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(FloeTheme.chromeMaterial)
    }

    private var statusText: String {
        guard let state = viewModel.snapshot?.record.state else {
            return String(localized: "state.unknown")
        }
        switch state {
        case .connected: return String(localized: "session.connected")
        case .connecting: return String(localized: "session.connecting")
        case .suspended: return String(localized: "session.suspended")
        case .disconnected: return String(localized: "state.disconnected")
        case .unknown: return String(localized: "state.unknown")
        }
    }

    private var statusColor: SwiftUI.Color {
        switch viewModel.snapshot?.record.state {
        case .connected: FloeTheme.success
        case .connecting: FloeTheme.primary
        case .suspended: FloeTheme.pending
        case .disconnected: FloeTheme.destructive
        default: FloeTheme.unknown
        }
    }
}

@MainActor
final class TerminalPresentation: ObservableObject {
    let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
    var renderedEnd: Int?
    var generation: UUID?
    @Published var fontSize: CGFloat = 14 {
        didSet { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
    func clear() { view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H") }
    func consume(_ output: Data, byteEnd: Int, generation: UUID?) {
        let start = byteEnd - output.count
        let newBytes: Data
        if self.generation != generation || (renderedEnd ?? start) < start || (renderedEnd ?? start) > byteEnd {
            view.getTerminal().resetToInitialState()
            newBytes = output
        } else { newBytes = Data(output.dropFirst((renderedEnd ?? start) - start)) }
        renderedEnd = byteEnd; self.generation = generation
        guard !newBytes.isEmpty else { return }
        let atBottom = view.contentOffset.y + view.bounds.height >= view.contentSize.height - 24
        let offset = view.contentOffset
        let bytes = [UInt8](newBytes)
        view.feed(byteArray: bytes[...])
        if !atBottom { view.setContentOffset(offset, animated: false) }
        view.setNeedsDisplay()
    }
}

struct TerminalControls: View {
    @ObservedObject var presentation: TerminalPresentation
    let interactive: Bool
    let send: (Data) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Menu {
                    Button(IDELanguageRunText.t("放大字体", "Larger text")) { presentation.fontSize = min(28, presentation.fontSize + 1) }
                    Button(IDELanguageRunText.t("缩小字体", "Smaller text")) { presentation.fontSize = max(10, presentation.fontSize - 1) }
                    Button(IDELanguageRunText.t("复制输出", "Copy output")) {
                        UIPasteboard.general.string = String(decoding: presentation.view.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\u{0}", with: "")
                    }
                    Button(IDELanguageRunText.t("粘贴", "Paste")) {
                        if let text = UIPasteboard.general.string { send(Data(text.utf8)) }
                    }.disabled(!interactive)
                    Button(IDELanguageRunText.t("清屏", "Clear screen")) { presentation.clear() }
                } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                .accessibilityLabel(IDELanguageRunText.t("终端显示与剪贴板", "Terminal display and clipboard"))
                key("Ctrl-C", "\u{03}"); key("Tab", "\t"); key("Esc", "\u{1b}")
                key("←", "\u{1b}[D"); key("↓", "\u{1b}[B"); key("↑", "\u{1b}[A"); key("→", "\u{1b}[C")
            }.font(.caption.monospaced())
        }
    }
    private func key(_ title: String, _ bytes: String) -> some View {
        Button(title) { send(Data(bytes.utf8)) }.frame(minWidth: 44, minHeight: 44).disabled(!interactive)
    }
}

/// SwiftTerm-backed PTY renderer. It interprets ANSI/VT sequences, owns the
/// software/hardware keyboard surface, and forwards raw bytes and resize
/// events to the long-lived SSH session owned by RemoteSessionCenter.
struct SSHEmulatorView: UIViewRepresentable {
    let output: Data
    var byteEnd: Int? = nil
    var generation: UUID? = nil
    var presentation: TerminalPresentation? = nil
    let isInteractive: Bool
    let onSend: @MainActor (Data) -> Void
    let onResize: @MainActor (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSend: onSend, onResize: onResize)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = presentation?.view ?? context.coordinator.presentation.view
        terminal.terminalDelegate = context.coordinator
        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = .black
        terminal.backgroundColor = .black
        terminal.allowMouseReporting = true
        return terminal
    }

    func updateUIView(_ terminal: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onSend = onSend
        context.coordinator.onResize = onResize
        context.coordinator.isInteractive = isInteractive

        let state = presentation ?? context.coordinator.presentation
        if terminal.font.pointSize != state.fontSize {
            terminal.font = .monospacedSystemFont(ofSize: state.fontSize, weight: .regular)
        }
        terminal.layoutIfNeeded()
        let wasAtBottom = terminal.contentOffset.y + terminal.bounds.height >= terminal.contentSize.height - 24
        let previousOffset = terminal.contentOffset
        let newBytes: Data
        if let byteEnd {
            state.consume(output, byteEnd: byteEnd, generation: generation)
            return
        } else if output.starts(with: context.coordinator.renderedOutput) {
            newBytes = output.dropFirst(context.coordinator.renderedOutput.count)
        } else {
            terminal.getTerminal().resetToInitialState()
            newBytes = output
        }
        if !newBytes.isEmpty {
            let bytes = [UInt8](newBytes)
            terminal.feed(byteArray: bytes[...])
            if !wasAtBottom { terminal.setContentOffset(previousOffset, animated: false) }
            terminal.setNeedsDisplay()
        }
        if byteEnd == nil { context.coordinator.renderedOutput = output }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency SwiftTerm.TerminalViewDelegate {
        let presentation = TerminalPresentation()
        var renderedOutput = Data()
        var isInteractive = false
        var onSend: @MainActor (Data) -> Void
        var onResize: @MainActor (Int, Int) -> Void

        init(
            onSend: @escaping @MainActor (Data) -> Void,
            onResize: @escaping @MainActor (Int, Int) -> Void
        ) {
            self.onSend = onSend
            self.onResize = onResize
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard isInteractive else { return }
            onSend(Data(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            onResize(newCols, newRows)
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
        }

        func requestOpenLink(
            source: SwiftTerm.TerminalView,
            link: String,
            params: [String: String]
        ) {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased()) else {
                return
            }
            UIApplication.shared.open(url)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
#endif

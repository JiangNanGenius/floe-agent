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

    init(sessionID: UUID, center: RemoteSessionCenter) {
        _viewModel = StateObject(
            wrappedValue: TerminalViewModel(sessionID: sessionID, center: center)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            SSHEmulatorView(
                output: viewModel.outputData,
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

/// SwiftTerm-backed PTY renderer. It interprets ANSI/VT sequences, owns the
/// software/hardware keyboard surface, and forwards raw bytes and resize
/// events to the long-lived SSH session owned by RemoteSessionCenter.
private struct SSHEmulatorView: UIViewRepresentable {
    let output: Data
    let isInteractive: Bool
    let onSend: @MainActor (Data) -> Void
    let onResize: @MainActor (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSend: onSend, onResize: onResize)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = SwiftTerm.TerminalView(frame: .zero)
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

        let newBytes: Data
        if output.starts(with: context.coordinator.renderedOutput) {
            newBytes = output.dropFirst(context.coordinator.renderedOutput.count)
        } else {
            terminal.getTerminal().resetToInitialState()
            newBytes = output
        }
        if !newBytes.isEmpty {
            let bytes = [UInt8](newBytes)
            terminal.feed(byteArray: bytes[...])
        }
        context.coordinator.renderedOutput = output
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency SwiftTerm.TerminalViewDelegate {
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

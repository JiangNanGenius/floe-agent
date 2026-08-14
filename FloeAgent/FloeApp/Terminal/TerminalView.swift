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

/// The terminal screen for one SSH session.
struct TerminalView: View {
    @StateObject private var viewModel: TerminalViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    init(sessionID: UUID, center: RemoteSessionCenter) {
        _viewModel = StateObject(
            wrappedValue: TerminalViewModel(sessionID: sessionID, center: center)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            outputScroll
            Divider()
            inputBar
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
        .task { await viewModel.refresh() }
        .onReceive(viewModel.center.objectWillChange) { _ in
            Task { await viewModel.refresh() }
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

    private var outputScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(viewModel.outputText.isEmpty
                     ? String(localized: "terminal.no_output")
                     : viewModel.outputText)
                    .font(FloeTheme.Typography.evidence)
                    .foregroundStyle(viewModel.outputText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .id("output-tail")
            }
            .background(Color.black.opacity(0.92))
            .onChange(of: viewModel.outputText) { _, _ in
                proxy.scrollTo("output-tail", anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(text: $input) {
                Text("terminal.input")
            }
            .textInputAutocapitalization(.never)
            .font(FloeTheme.Typography.evidence)
            .disabled(!viewModel.isInteractive)
            .onSubmit { send() }
            Button {
                send()
            } label: {
                Image(systemName: "return")
                    .foregroundStyle(FloeTheme.primary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isInteractive || input.isEmpty)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("terminal.send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FloeTheme.chromeMaterial)
    }

    private func send() {
        let text = input + "\n"
        input = ""
        Task { await viewModel.send(text) }
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

    private var statusColor: Color {
        switch viewModel.snapshot?.record.state {
        case .connected: FloeTheme.success
        case .connecting: FloeTheme.primary
        case .suspended: FloeTheme.pending
        case .disconnected: FloeTheme.destructive
        default: FloeTheme.unknown
        }
    }
}
#endif

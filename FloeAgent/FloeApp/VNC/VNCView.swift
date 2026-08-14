// FloeApp — VNC screen.
//
// SPDX-License-Identifier: MPL-2.0
//
// Wraps the committed VNCViewer with a status bar (state + FPS), a
// disconnect affordance, and a persistent emergency stop. The session is
// owned by RemoteSessionCenter, so dismissing this view does NOT kill it.
// VNC always runs over the SSH loopback forwarder, never a public listener.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeVNC

/// The VNC screen for one session.
struct VNCView: View {
    @StateObject private var viewModel: VNCViewModel
    @Environment(\.dismiss) private var dismiss

    init(sessionID: UUID, center: RemoteSessionCenter) {
        _viewModel = StateObject(
            wrappedValue: VNCViewModel(sessionID: sessionID, center: center)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            viewerArea
        }
        .background(Color.black)
        .navigationTitle("hosts.vnc")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            // Periodically refresh the FPS readout.
            while !Task.isCancelled {
                viewModel.refreshFPS()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var viewerArea: some View {
        Group {
            if let session = viewModel.session {
                VNCViewer(session: session)
                    .background(.black)
            } else {
                ContentUnavailableView {
                    Label("state.unknown", systemImage: "display.trianglebadge.exclamationmark")
                } description: {
                    Text("vnc.unavailable")
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(statusText)
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Label("\(Int(viewModel.framesPerSecond)) FPS", systemImage: "speedometer")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(FloeTheme.chromeMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    await viewModel.disconnect()
                    dismiss()
                }
            } label: {
                Label("action.disconnect", systemImage: "xmark.circle")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        }
        ToolbarItem(placement: .topBarTrailing) {
            // Persistent emergency stop — visually distinct (red).
            Button(role: .destructive) {
                Task {
                    await viewModel.emergencyStop()
                    dismiss()
                }
            } label: {
                Label("action.emergency_stop", systemImage: "stop.hand.raised")
            }
            .tint(FloeTheme.destructive)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("action.emergency_stop")
        }
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

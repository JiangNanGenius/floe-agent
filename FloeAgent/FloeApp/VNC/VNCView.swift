// FloeApp — VNC screen.
//
// SPDX-License-Identifier: MPL-2.0
//
// Wraps the committed VNCViewer with a status bar (state + FPS), a
// disconnect affordance, and a persistent emergency stop. The session is
// owned by RemoteSessionCenter, so dismissing this view does NOT kill it.
// VNC may connect directly or through the verified SSH loopback forwarder.

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
        if case .failed(let failure) = viewModel.connectionState {
            return failure.message
        }
        guard let state = viewModel.snapshot?.record.state else {
            switch viewModel.connectionState {
            case .connecting: return String(localized: "session.connecting")
            case .connected: return String(localized: "session.connected")
            case .disconnected: return String(localized: "state.disconnected")
            case .failed(let failure): return failure.message
            }
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
        if case .failed = viewModel.connectionState { return FloeTheme.destructive }
        switch viewModel.snapshot?.record.state {
        case .connected: return FloeTheme.success
        case .connecting: return FloeTheme.primary
        case .suspended: return FloeTheme.pending
        case .disconnected: return FloeTheme.destructive
        default: return FloeTheme.unknown
        }
    }
}
#endif

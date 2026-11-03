import SwiftUI
import UIKit
import BridgeCore

enum BridgeProductSurface: String, CaseIterable, Identifiable, Hashable {
    case run
    case setup
    case clients
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: return BridgeProductCopy.run
        case .setup: return BridgeProductCopy.setup
        case .clients: return BridgeProductCopy.clients
        case .diagnostics: return BridgeProductCopy.diagnostics
        case .settings: return BridgeProductCopy.settings
        }
    }

    var symbol: String {
        switch self {
        case .run: return "play.circle"
        case .setup: return "wrench.and.screwdriver"
        case .clients: return "person.2"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }

    static var compactCases: [BridgeProductSurface] {
        [.run, .clients, .diagnostics, .settings]
    }
}

struct BridgeRootView: View {
    @ObservedObject var model: BridgeAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSurface: BridgeProductSurface = .run
    @State private var setupPresented = false
    @State private var didOfferInitialSetup = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactShell
            } else {
                splitShell
            }
        }
        .tint(BridgeProductTheme.accent)
        .overlay {
            BridgeProductApprovalOverlay(model: model)
        }
        .sheet(isPresented: $setupPresented) {
            NavigationStack {
                BridgeProductSetupView(model: model, isSheet: true)
            }
            .overlay {
                BridgeProductApprovalOverlay(model: model)
            }
            .interactiveDismissDisabled(model.pendingApproval != nil)
        }
        .task {
            guard !didOfferInitialSetup else { return }
            didOfferInitialSetup = true
            if model.shouldOfferInitialSetup {
                setupPresented = true
            }
        }
    }

    // MARK: - iPad

    private var sidebarSelection: Binding<BridgeProductSurface?> {
        Binding(
            get: { selectedSurface },
            set: { if let value = $0 { selectedSurface = value } }
        )
    }

    private var splitShell: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    ForEach(BridgeProductSurface.allCases) { surface in
                        Label(surface.title, systemImage: surface.symbol)
                            .tag(surface)
                            .accessibilityIdentifier("bridge.sidebar.\(surface.rawValue)")
                    }
                }
            }
            .navigationTitle(BridgeProductCopy.appTitle)
            .safeAreaInset(edge: .bottom) {
                sidebarStatus
            }
        } detail: {
            NavigationStack {
                detail(for: selectedSurface)
                    .navigationTitle(selectedSurface.title)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Label(model.productRunState.title, systemImage: model.productRunState.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.productRunState.tint)
            if !model.rpcSnapshot.clients.isEmpty {
                Text(BridgeProductCopy.clientCount(model.rpcSnapshot.clients.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - iPhone

    private var compactShell: some View {
        TabView(selection: $selectedSurface) {
            ForEach(BridgeProductSurface.compactCases) { surface in
                NavigationStack {
                    detail(for: surface)
                        .navigationTitle(surface.title)
                }
                .tabItem {
                    Label(surface.title, systemImage: surface.symbol)
                }
                .tag(surface)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(for surface: BridgeProductSurface) -> some View {
        switch surface {
        case .run:
            BridgeProductRunView(model: model) {
                setupPresented = true
            }
        case .setup:
            BridgeProductSetupView(model: model, isSheet: false)
        case .clients:
            BridgeProductClientsView(model: model) {
                setupPresented = true
            }
        case .diagnostics:
            BridgeProductDiagnosticsView(model: model)
        case .settings:
            BridgeProductSettingsView(model: model) {
                setupPresented = true
            }
        }
    }

}

/// Central owner decision. It is attached to the root shell and to the setup
/// sheet so a new pairing request remains visible and protected across tab and
/// navigation changes.
struct BridgeProductApprovalOverlay: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        if let approval = model.pendingApproval {
            ZStack {
                Color.black.opacity(0.36)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                BridgeProductApprovalCard(
                    approval: approval,
                    onApprove: { model.approvePendingPairing() },
                    onDeny: { model.denyPendingPairing() }
                )
                .padding(24)
                .frame(maxWidth: 460)
            }
            .transition(.opacity)
            .zIndex(20)
        }
    }
}

private struct BridgeProductApprovalCard: View {
    let approval: BridgeProductPendingApproval
    let onApprove: () -> Void
    let onDeny: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(BridgeProductCopy.approvalTitle, systemImage: "person.badge.key.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(BridgeProductTheme.accent)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            Text(BridgeProductCopy.approvalDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(approval.clientName.isEmpty
                     ? BridgeProductCopy.approvalUnknownClient
                     : approval.clientName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Label(sourceText, systemImage: sourceSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let fingerprint = approval.fingerprint {
                    LabeledContent(BridgeProductCopy.approvalFingerprint,
                                   value: fingerprint.uppercased())
                        .font(.callout)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = Int(approval.deadline.timeIntervalSince(context.date).rounded(.down))
                    Text(remaining > 0
                         ? BridgeProductCopy.approvalExpiresIn(remaining)
                         : BridgeProductCopy.approvalExpired)
                        .font(.caption)
                        .foregroundStyle(remaining > 0 ? Color.secondary : BridgeProductTheme.warning)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 10) {
                Button(action: onApprove) {
                    Text(BridgeProductCopy.approvalAllow)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(BridgeProductTheme.accent)
                .accessibilityIdentifier("bridge.approval.allow")

                Button(role: .cancel, action: onDeny) {
                    Text(BridgeProductCopy.approvalDeny)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("bridge.approval.deny")
            }
        }
        .padding(22)
        .background(Color(uiColor: .systemBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 12)
        .onAppear { titleFocused = true }
    }

    private var sourceText: String {
        switch approval.source {
        case .thisDevice: return BridgeProductCopy.approvalFromDevice
        case .localNetwork: return BridgeProductCopy.approvalFromLAN
        }
    }

    private var sourceSymbol: String {
        switch approval.source {
        case .thisDevice: return "iphone"
        case .localNetwork: return "network"
        }
    }
}

import SwiftUI
import UIKit
import BridgeCore

struct BridgeProductClientsView: View {
    @ObservedObject var model: BridgeAppModel
    let onOpenSetup: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var revokeRequest: BridgeRevokeRequest?

    private var clients: [BridgeRPCClientRecord] {
        model.rpcSnapshot.clients.sorted { left, right in
            if left.lastActiveAt == right.lastActiveAt {
                return left.clientName.localizedCaseInsensitiveCompare(right.clientName) == .orderedAscending
            }
            return left.lastActiveAt > right.lastActiveAt
        }
    }

    var body: some View {
        List {
            if let banner = model.banner, !banner.isEmpty {
                Section {
                    BridgeProductBanner(text: BridgeProductRedaction.text(banner))
                }
            }

            if let storageError = model.rpcSnapshot.storageError {
                Section {
                    Label(BridgeProductCopy.storageUnavailable, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(BridgeProductTheme.danger)
                    Text(BridgeProductRedaction.text(storageError))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !clients.isEmpty {
                Section(BridgeProductCopy.clients) {
                    ForEach(clients, id: \.clientID) { client in
                        clientRow(client)
                    }
                }
            }

            if model.pendingApproval != nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(BridgeProductCopy.approvalTitle)
                            .font(.callout)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if clients.isEmpty, model.rpcSnapshot.storageError == nil {
                emptyState
            }
        }
        .toolbar {
            if !clients.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            revokeRequest = .all
                        } label: {
                            Label(BridgeProductCopy.revokeAll, systemImage: "person.2.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(BridgeProductCopy.revokeAll)
                }
            }
        }
        .confirmationDialog(
            revokeRequest == .all
                ? BridgeProductCopy.revokeAllTitle
                : BridgeProductCopy.revokeClientTitle,
            isPresented: Binding(
                get: { revokeRequest != nil },
                set: { if !$0 { revokeRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                revokeRequest == .all
                    ? BridgeProductCopy.revokeAll
                    : BridgeProductCopy.revoke,
                role: .destructive
            ) {
                if let request = revokeRequest {
                    switch request {
                    case .all:
                        model.revokeAllClients()
                    case .client(let client):
                        model.revokeClient(clientID: client.clientID)
                    }
                }
                revokeRequest = nil
            }
            Button(BridgeProductCopy.cancel, role: .cancel) {
                revokeRequest = nil
            }
        } message: {
            Text(revokeRequest == .all
                 ? BridgeProductCopy.revokeAllMessage
                 : BridgeProductCopy.revokeClientMessage)
        }
    }

    private func clientRow(_ client: BridgeRPCClientRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName(client))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(BridgeProductCopy.lastActive + ": " + BridgeProductFormat.relative(client.lastActiveAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(sourceText(client), systemImage: sourceSymbol(client))
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { client.sensitiveInputGranted },
                set: { model.setSensitiveInputGrant(clientID: client.clientID, granted: $0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(BridgeProductCopy.sensitiveInput)
                        .font(.callout)
                    Text(BridgeProductCopy.sensitiveInputDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(BridgeProductTheme.accent)
            .accessibilityIdentifier("bridge.clients.sensitive.\(client.clientID)")
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                revokeRequest = .client(client)
            } label: {
                Label(BridgeProductCopy.revoke, systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                revokeRequest = .client(client)
            } label: {
                Label(BridgeProductCopy.revoke, systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(BridgeProductCopy.noClientsTitle, systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text(BridgeProductCopy.noClientsDetail)
        } actions: {
            if let url = model.productRemotePageURL {
                Button {
                    openURL(url)
                } label: {
                    Label(BridgeProductCopy.openRemotePage, systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            } else if model.requiresSetup {
                Button(action: onOpenSetup) {
                    Label(BridgeProductCopy.setUpBridge, systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
            } else if !model.rpcSnapshot.running {
                Button {
                    model.start()
                } label: {
                    Label(BridgeProductCopy.startBridge, systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Text(BridgeProductCopy.localAddressUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func displayName(_ client: BridgeRPCClientRecord) -> String {
        let sanitized = BridgeProductApprovalPolicy.displayName(client.clientName)
        return sanitized.isEmpty ? BridgeProductCopy.approvalUnknownClient : sanitized
    }

    private func sourceText(_ client: BridgeRPCClientRecord) -> String {
        switch client.lastVia {
        case .local: return BridgeProductCopy.clientSourceDevice
        case .lan: return BridgeProductCopy.clientSourceLAN
        default: return BridgeProductCopy.clientSourceUnknown
        }
    }

    private func sourceSymbol(_ client: BridgeRPCClientRecord) -> String {
        switch client.lastVia {
        case .local: return "iphone"
        case .lan: return "network"
        default: return "questionmark.circle"
        }
    }
}


private enum BridgeRevokeRequest: Equatable, Identifiable {
    case client(BridgeRPCClientRecord)
    case all

    var id: String {
        switch self {
        case .client(let client): return client.clientID
        case .all: return "all"
        }
    }
}

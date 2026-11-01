import SwiftUI
import UniformTypeIdentifiers

struct BridgeProductSetupView: View {
    @ObservedObject var model: BridgeAppModel
    let isSheet: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showPairingPicker = false
    @State private var showDDIPicker = false

    var body: some View {
        Form {
            Section {
                Text(BridgeProductCopy.setupIntro)
                    .font(.callout)
            }

            if let banner = model.banner, !banner.isEmpty {
                Section {
                    BridgeProductBanner(text: BridgeProductRedaction.text(banner))
                }
            }

            pairingSection
            vpnSection
            imageSection
            guideSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: BridgeProductTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle(BridgeProductCopy.setup)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button(BridgeProductCopy.done) { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showPairingPicker,
            allowedContentTypes: [.propertyList, .xml, .data]
        ) { result in
            switch result {
            case .success(let url):
                model.importPairing(url)
            case .failure:
                model.banner = BridgeProductCopy.noPairingSelected
            }
        }
        .fileImporter(
            isPresented: $showDDIPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                model.importDDIFolder(url)
            case .failure:
                model.banner = BridgeProductCopy.noImageSelected
            }
        }
    }

    private var pairingSection: some View {
        Section(BridgeProductCopy.setupPairingTitle) {
            Text(BridgeProductCopy.setupPairingDetail)
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent(BridgeProductCopy.status) {
                Label(
                    model.pairingImported
                        ? BridgeProductCopy.setupPairingImported
                        : BridgeProductCopy.setupPairingMissing,
                    systemImage: model.pairingImported ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(model.pairingImported ? BridgeProductTheme.success : .secondary)
            }

            Button {
                showPairingPicker = true
            } label: {
                Label(
                    model.pairingImported
                        ? BridgeProductCopy.replacePairing
                        : BridgeProductCopy.importPairing,
                    systemImage: "doc.badge.plus"
                )
                .frame(minHeight: 44, alignment: .leading)
            }

            if model.pairingImported {
                Button(role: .destructive) {
                    model.removePairing()
                } label: {
                    Label(BridgeProductCopy.removePairing, systemImage: "trash")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private var vpnSection: some View {
        Section(BridgeProductCopy.setupVPNTitle) {
            Text(BridgeProductCopy.setupVPNDetail)
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent(BridgeProductCopy.localNetwork) {
                Label(vpnStatusText, systemImage: vpnStatusSymbol)
                    .foregroundStyle(vpnStatusTint)
            }

            switch model.tunnelPhase {
            case .connected, .connecting, .disconnecting:
                Button {
                    model.stopTunnel()
                } label: {
                    Label(BridgeProductCopy.setupVPNStop, systemImage: "stop.circle")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(model.tunnelPhase == .disconnecting)
            default:
                Button {
                    model.startTunnel()
                } label: {
                    Label(BridgeProductCopy.setupVPNStart, systemImage: "lock.shield")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }

            if model.tunnelPhase == .connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(BridgeProductCopy.setupVPNStarting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.tunnelPhase == .invalid || model.tunnelPhase == .failed {
                Text(BridgeProductCopy.setupVPNNeedsPermission)
                    .font(.caption)
                    .foregroundStyle(BridgeProductTheme.danger)
            }
            if model.tunnelPhase == .failed {
                Text(BridgeProductCopy.setupVPNConflict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if (model.tunnelPhase == .invalid || model.tunnelPhase == .failed),
               let detail = model.tunnelDetail,
               !detail.isEmpty {
                Text(BridgeProductRedaction.text(detail))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var imageSection: some View {
        Section(BridgeProductCopy.setupImageTitle) {
            Text(BridgeProductCopy.setupImageDetail)
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent(BridgeProductCopy.status) {
                Label(imageStatusText, systemImage: imageStatusSymbol)
                    .foregroundStyle(imageStatusTint)
            }

            if model.ddiDownloading {
                ProgressView(value: model.ddiDownloadProgress)
                Text(BridgeProductCopy.downloadingImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    model.cancelDDIDownload()
                } label: {
                    Label(BridgeProductCopy.cancelDownload, systemImage: "xmark.circle")
                        .frame(minHeight: 44, alignment: .leading)
                }
            } else {
                Button {
                    model.downloadDDI()
                } label: {
                    Label(BridgeProductCopy.downloadImage, systemImage: "arrow.down.circle")
                        .frame(minHeight: 44, alignment: .leading)
                }
                Button {
                    showDDIPicker = true
                } label: {
                    Label(BridgeProductCopy.importImage, systemImage: "folder.badge.plus")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }

            if let error = model.ddiError, !error.isEmpty {
                Text(BridgeProductRedaction.text(error))
                    .font(.caption)
                    .foregroundStyle(BridgeProductTheme.danger)
            }
        }
    }

    private var guideSection: some View {
        Section(BridgeProductCopy.setupGuideTitle) {
            Text(BridgeProductCopy.setupGuideHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            NavigationLink {
                BridgeProductGuideView()
            } label: {
                Label(BridgeProductCopy.setupOpenGuide, systemImage: "book")
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var vpnStatusText: String {
        switch model.tunnelPhase {
        case .connected: return BridgeProductCopy.setupVPNConnected
        case .connecting: return BridgeProductCopy.setupVPNStarting
        case .disconnecting: return BridgeProductCopy.stopped
        case .invalid: return BridgeProductCopy.needsAttention
        case .failed: return BridgeProductCopy.needsAttention
        case .disconnected, .unknown: return BridgeProductCopy.setupVPNDisconnected
        }
    }

    private var vpnStatusSymbol: String {
        switch model.tunnelPhase {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .disconnecting: return "hourglass"
        case .invalid, .failed: return "exclamationmark.triangle.fill"
        case .disconnected, .unknown: return "circle"
        }
    }

    private var vpnStatusTint: Color {
        switch model.tunnelPhase {
        case .connected: return BridgeProductTheme.success
        case .connecting, .disconnecting: return BridgeProductTheme.warning
        case .invalid, .failed: return BridgeProductTheme.danger
        case .disconnected, .unknown: return .secondary
        }
    }

    private var imageStatusText: String {
        if model.ddiStatus.mounted { return BridgeProductCopy.setupImageMounted }
        if model.ddiStore.isComplete { return BridgeProductCopy.setupImageReady }
        return BridgeProductCopy.setupImageMissing
    }

    private var imageStatusSymbol: String {
        if model.ddiStatus.mounted { return "checkmark.circle.fill" }
        if model.ddiStore.isComplete { return "checkmark.circle" }
        return "circle"
    }

    private var imageStatusTint: Color {
        if model.ddiStatus.mounted { return BridgeProductTheme.success }
        if model.ddiStore.isComplete { return BridgeProductTheme.accent }
        return .secondary
    }
}

struct BridgeProductGuideView: View {
    var body: some View {
        List {
            Section {
                Text(BridgeProductCopy.guideIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(BridgeProductCopy.setupGuideTitle) {
                guideRow(number: 1, text: BridgeProductCopy.guideStepPairing)
                guideRow(number: 2, text: BridgeProductCopy.guideStepVPN)
                guideRow(number: 3, text: BridgeProductCopy.guideStepImage)
                guideRow(number: 4, text: BridgeProductCopy.guideStepBrowser)
            }

            Section(BridgeProductCopy.guideTroubleshootingTitle) {
                troubleshootingRow(BridgeProductCopy.guideTroubleshootAddress)
                troubleshootingRow(BridgeProductCopy.guideTroubleshootVPN)
                troubleshootingRow(BridgeProductCopy.guideTroubleshootReopen)
                troubleshootingRow(BridgeProductCopy.guideTroubleshootPairing)
                troubleshootingRow(BridgeProductCopy.guideTroubleshootSensitive)
            }
        }
        .navigationTitle(BridgeProductCopy.guideTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(BridgeProductTheme.accent)
                .frame(width: 24, alignment: .leading)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func troubleshootingRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

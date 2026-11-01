import SwiftUI
import UIKit

struct BridgeProductRunView: View {
    @ObservedObject var model: BridgeAppModel
    let onOpenSetup: () -> Void

    var body: some View {
        Form {
            statusSection
            addressSection
            if model.productLANEnabled {
                lanSection
            }
            if model.requiresSetup {
                setupSection
            }
            if model.snapshot.terminalFault {
                recoverySection
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: BridgeProductTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            primaryBar
        }
    }

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                BridgeProductStatusLine(state: model.productRunState)
                Text(model.productRunState.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            if let activity = model.productActivityText {
                if model.snapshot.phase.isActive || model.ddiDownloading {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(activity)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    LabeledContent(BridgeProductCopy.currentStep) {
                        Text(activity)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.ddiDownloading {
                ProgressView(value: model.ddiDownloadProgress)
                Text(BridgeProductCopy.downloadingImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.snapshot.lastError != nil {
                Label(BridgeProductCopy.failureHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(BridgeProductTheme.danger)
            }
            if let banner = model.banner, !banner.isEmpty {
                BridgeProductBanner(text: BridgeProductRedaction.text(banner))
            }
        }
    }

    private var addressSection: some View {
        Section(BridgeProductCopy.localAddress) {
            if let url = model.productPrimaryLocalURL {
                LabeledContent(BridgeProductCopy.localAddress) {
                    Text(url.absoluteString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                if let remote = model.productRemotePageURL {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            copyAddressButton(url)
                            openRemoteButton(remote)
                        }
                        VStack(spacing: 10) {
                            copyAddressButton(url)
                            openRemoteButton(remote)
                        }
                    }
                } else {
                    copyAddressButton(url)
                }
            } else if model.rpcSnapshot.running {
                Text(BridgeProductCopy.localServiceListening)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(BridgeProductCopy.localAddressUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.productNetworkError, !error.isEmpty {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(BridgeProductTheme.danger)
            }
        }
    }

    private func copyAddressButton(_ url: URL) -> some View {
        Button {
            model.copyProductAddress(url)
        } label: {
            Label(BridgeProductCopy.copyAddress, systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func openRemoteButton(_ url: URL) -> some View {
        Link(destination: url) {
            Label(BridgeProductCopy.openRemotePage, systemImage: "safari")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
    }

    private var lanSection: some View {
        Section(BridgeProductCopy.lanAddresses) {
            if model.productLANURLs.isEmpty {
                Text(BridgeProductCopy.lanNotReady)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.productLANURLs, id: \.absoluteString) { url in
                    LabeledContent(BridgeProductCopy.lanAddresses) {
                        Text(url.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Text(BridgeProductCopy.lanSameNetworkOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setupSection: some View {
        Section {
            Label(BridgeProductCopy.setupCalloutTitle, systemImage: "wrench.and.screwdriver")
                .font(.headline)
            Text(BridgeProductCopy.statusNeedsSetupDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: onOpenSetup) {
                Label(BridgeProductCopy.setupCalloutAction, systemImage: "arrow.right.circle")
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var recoverySection: some View {
        Section {
            Label(BridgeProductCopy.statusReopenDetail, systemImage: "arrow.counterclockwise.circle.fill")
                .font(.callout)
                .foregroundStyle(BridgeProductTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryBar: some View {
        VStack(spacing: 0) {
            Divider()
            BridgeProductPrimaryBar(
                action: model.productPrimaryAction,
                canStart: model.productCanStart,
                canStop: model.productCanStop,
                onStart: model.start,
                onStop: model.stop,
                onSetup: onOpenSetup
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: BridgeProductTheme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(.bar)
    }
}

import SwiftUI

struct BridgeProductDiagnosticsView: View {
    @ObservedObject var model: BridgeAppModel
    @State private var showConnectionDetails = false
    @State private var showSafeExport = false
    @State private var showStatusEvents = false

    var body: some View {
        Form {
            Section(BridgeProductCopy.now) {
                LabeledContent(BridgeProductCopy.phase, value: model.snapshot.phase.rawValue)
                LabeledContent(BridgeProductCopy.stage, value: model.snapshot.activity ?? "—")
                LabeledContent(BridgeProductCopy.engine, value: model.engineStateText)
                LabeledContent(BridgeProductCopy.localService,
                               value: model.rpcSnapshot.running
                                   ? (model.rpcSnapshot.loopbackReady ? BridgeProductCopy.running : BridgeProductCopy.preparing)
                                   : BridgeProductCopy.stopped)
                LabeledContent(BridgeProductCopy.localNetwork,
                               value: model.rpcSnapshot.lanReady
                                   ? BridgeProductCopy.running
                                   : (model.rpcSnapshot.lanEnabled ? BridgeProductCopy.preparing : BridgeProductCopy.stopped))
                LabeledContent(BridgeProductCopy.bonjour, value: bonjourText)
                LabeledContent(BridgeProductCopy.storage,
                               value: model.rpcSnapshot.storageError == nil ? BridgeProductCopy.ready : BridgeProductCopy.needsAttention)
            }

            Section(BridgeProductCopy.timing) {
                LabeledContent(BridgeProductCopy.started,
                               value: BridgeProductFormat.timestamp(model.snapshot.startedAt))
                LabeledContent(BridgeProductCopy.ready,
                               value: BridgeProductFormat.timestamp(model.snapshot.readyAt))
                LabeledContent(BridgeProductCopy.stoppedAt,
                               value: BridgeProductFormat.timestamp(model.snapshot.stoppedAt))
                LabeledContent(BridgeProductCopy.updated,
                               value: BridgeProductFormat.timestamp(model.snapshot.updatedAt))
            }

            Section(BridgeProductCopy.lastIssue) {
                if let error = model.snapshot.lastError, !error.isEmpty {
                    Text(BridgeProductRedaction.text(error))
                        .font(.callout)
                        .foregroundStyle(BridgeProductTheme.danger)
                } else if let error = model.productListenerError, !error.isEmpty {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(BridgeProductTheme.danger)
                } else if let error = model.rpcSnapshot.storageError, !error.isEmpty {
                    Text(BridgeProductRedaction.text(error))
                        .font(.callout)
                        .foregroundStyle(BridgeProductTheme.danger)
                } else {
                    Text(BridgeProductCopy.noIssue)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup(BridgeProductCopy.recentStatusEvents,
                                isExpanded: $showStatusEvents) {
                    LabeledContent(BridgeProductCopy.statusLog,
                                   value: model.statusLogHealth.persistence == "persistent"
                                       ? BridgeProductCopy.statusLogStored
                                       : BridgeProductCopy.statusLogMemoryOnly)
                    if recentStatusLines.isEmpty {
                        Text(BridgeProductCopy.noRecentStatusEvents)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(recentStatusLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Text(BridgeProductCopy.statusEventsPrivacy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    model.copySafeDiagnostics()
                } label: {
                    Label(BridgeProductCopy.copySafeDiagnostics, systemImage: "doc.on.doc")
                        .frame(minHeight: 44, alignment: .leading)
                }
                ShareLink(
                    item: model.safeDiagnosticsJSON(),
                    subject: Text(BridgeProductCopy.appTitle),
                    message: Text(BridgeProductCopy.diagnosticsPrivacy)
                ) {
                    Label(BridgeProductCopy.exportSafeDiagnostics, systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44, alignment: .leading)
                }
                Text(BridgeProductCopy.diagnosticsPrivacy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup(showSafeExport ? BridgeProductCopy.hideSafeExport : BridgeProductCopy.showSafeExport, isExpanded: $showSafeExport) {
                    Text(model.safeDiagnosticsJSON())
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                DisclosureGroup(BridgeProductCopy.connectionDetails,
                                isExpanded: $showConnectionDetails) {
                    LabeledContent(BridgeProductCopy.port,
                                   value: model.rpcSnapshot.port.map { String($0) } ?? "—")
                    LabeledContent(BridgeProductCopy.connectedClients,
                                   value: "\(model.rpcSnapshot.clients.count)")
                    LabeledContent(BridgeProductCopy.methods,
                                   value: "\(model.rpcSnapshot.engine.supportedMethods.count)")
                    if !model.rpcSnapshot.capabilities.isEmpty {
                        Text(model.rpcSnapshot.capabilities.sorted().joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(BridgeProductCopy.engine,
                                   value: engineReadinessText)
                    if let storage = model.rpcSnapshot.storageError, !storage.isEmpty {
                        Text(BridgeProductRedaction.text(storage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let network = model.rpcSnapshot.networkError, !network.isEmpty {
                        Text(BridgeProductRedaction.text(network))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: BridgeProductTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var recentStatusLines: [String] {
        Array(model.recentStatusEvents(limit: 24).reversed())
    }

    private var bonjourText: String {
        switch model.rpcSnapshot.bonjourState {
        case "published": return BridgeProductCopy.running
        case "starting": return BridgeProductCopy.preparing
        case "off", "": return BridgeProductCopy.stopped
        default: return BridgeProductCopy.needsAttention
        }
    }

    private var engineReadinessText: String {
        switch model.rpcSnapshot.engine.readiness {
        case .notRegistered: return BridgeProductCopy.stopped
        case .notReady: return BridgeProductCopy.preparing
        case .ready: return BridgeProductCopy.ready
        }
    }
}

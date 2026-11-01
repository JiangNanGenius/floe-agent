import SwiftUI
import BridgeCore

struct BridgeProductSettingsView: View {
    @ObservedObject var model: BridgeAppModel
    let onOpenSetup: () -> Void

    var body: some View {
        Form {
            Section(BridgeProductCopy.run) {
                Toggle(BridgeProductCopy.restoreOnOpen, isOn: $model.autoStart)
                    .tint(BridgeProductTheme.accent)
                Text(BridgeProductCopy.restoreOnOpenDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(BridgeProductCopy.localNetwork) {
                Toggle(BridgeProductCopy.lanAccess,
                       isOn: Binding(
                        get: { model.productLANEnabled },
                        set: { model.setProductLAN($0) }
                       ))
                    .tint(BridgeProductTheme.accent)
                Text(BridgeProductCopy.lanAccessDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(BridgeProductCopy.bonjourDiscovery,
                       isOn: Binding(
                        get: { model.productBonjourEnabled },
                        set: { model.setProductBonjour($0) }
                       ))
                    .tint(BridgeProductTheme.accent)
                    .disabled(!model.productLANEnabled)
                Text(BridgeProductCopy.bonjourDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.productLANEnabled {
                    Text(BridgeProductCopy.bonjourRequiresLAN)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent(BridgeProductCopy.port, value: "8200")
                Text(BridgeProductCopy.portDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = model.productNetworkError, !error.isEmpty {
                    Text(BridgeProductCopy.networkError + ": " + BridgeProductRedaction.text(error))
                        .font(.caption)
                        .foregroundStyle(BridgeProductTheme.danger)
                }
            }

            Section(BridgeProductCopy.language) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(BridgeProductCopy.language)
                    Text(BridgeProductCopy.languageSystem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(BridgeProductCopy.about) {
                LabeledContent(BridgeProductCopy.version,
                               value: "\(BridgeBuild.marketingVersion) (\(BridgeBuild.buildNumber))")
                NavigationLink {
                    BridgeProductNoticesView()
                } label: {
                    Label(BridgeProductCopy.notices, systemImage: "doc.text")
                }
                NavigationLink {
                    BridgeProductGuideView()
                } label: {
                    Label(BridgeProductCopy.help, systemImage: "questionmark.circle")
                }
                Button(action: onOpenSetup) {
                    Label(BridgeProductCopy.openSetup, systemImage: "wrench.and.screwdriver")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: BridgeProductTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }
}

struct BridgeProductNoticesView: View {
    var body: some View {
        List {
            Section {
                Text(BridgeProductCopy.noticesIntro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(BridgeProductCopy.noticeICTRL)
                    .font(.callout)
                Text(BridgeProductCopy.noticeApple)
                    .font(.callout)
                Text(BridgeProductCopy.noticeNoAccount)
                    .font(.callout)
            }
            Section(BridgeProductCopy.version) {
                LabeledContent(BridgeProductCopy.version,
                               value: "\(BridgeBuild.marketingVersion) (\(BridgeBuild.buildNumber))")
                LabeledContent(BridgeProductCopy.appTitle, value: BridgeProductRuntime.productName)
            }
        }
        .navigationTitle(BridgeProductCopy.notices)
        .navigationBarTitleDisplayMode(.inline)
    }
}

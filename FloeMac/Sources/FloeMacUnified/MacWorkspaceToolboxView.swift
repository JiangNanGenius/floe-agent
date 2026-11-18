// SPDX-License-Identifier: MPL-2.0

import FloeMacToolbox
import SwiftUI

struct MacWorkspaceToolboxView: View {
    @Environment(\.locale) private var locale
    let openToolbox: (String) -> Void

    var body: some View {
        List {
            ForEach(MacToolboxCatalog.groups(locale: locale)) { group in
                Section(group.title) {
                    ForEach(group.tools) { tool in
                        if tool.isAvailable {
                            Button {
                                openToolbox(tool.id)
                            } label: {
                                HStack {
                                    Label(tool.title, systemImage: tool.symbol)
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("workspace.toolbox.\(tool.id)")
                        } else {
                            HStack {
                                Label(tool.title, systemImage: tool.symbol)
                                Spacer()
                                Text(MacToolboxText.t("暂不可用", "Unavailable", locale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

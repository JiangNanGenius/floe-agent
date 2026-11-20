// SPDX-License-Identifier: MPL-2.0

import FloeMacToolbox
import SwiftUI

struct MacWorkspaceToolboxView: View {
    let findRequest: UUID?
    let openToolbox: (String) -> Void

    @Environment(\.locale) private var locale
    @FocusState private var searchFocused: Bool
    @State private var search = ""

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = MacToolboxCatalog.groups(locale: locale).map { group in
            let tools = group.tools.filter { tool in
                tool.isAvailable && (query.isEmpty || tool.title.localizedStandardContains(query)
                    || tool.id.localizedStandardContains(query) || group.title.localizedStandardContains(query))
            }
            return (id: group.id, title: group.title, tools: tools)
        }.filter { !$0.tools.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("mac.workspace.findTool", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onExitCommand { search = "" }
                    .accessibilityIdentifier("workspace.toolbox.search")
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView("mac.workspace.noToolsFound", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups, id: \.id) { group in
                            section(group.title, tools: group.tools)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1160, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: findRequest) { _, request in
            if request != nil { searchFocused = true }
        }
    }

    private func section(_ group: String, tools: [MacToolboxCatalog.Tool]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: group)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 280), spacing: 10)], spacing: 8) {
                ForEach(tools) { tool in
                    Button { openToolbox(tool.id) } label: {
                        Label {
                            Text(verbatim: tool.title).lineLimit(2)
                        } icon: {
                            Image(systemName: tool.symbol)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workspace.toolbox.\(tool.id)")
                }
            }
        }
    }
}

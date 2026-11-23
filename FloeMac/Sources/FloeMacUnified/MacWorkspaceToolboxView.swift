// SPDX-License-Identifier: MPL-2.0

import FloeMacToolbox
import SwiftUI

struct MacWorkspaceToolboxView: View {
    let findRequest: UUID?
    let openToolbox: (String) -> Void

    @FocusState private var searchFocused: Bool
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("mac.workspace.findTool", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onExitCommand {
                        search = ""
                        searchFocused = false
                    }
                    .accessibilityIdentifier("workspace.toolbox.search")
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            MacToolboxDirectory(search: $search, openTool: openToolbox)
        }
        .onChange(of: findRequest) { _, request in
            if request != nil { searchFocused = true }
        }
    }

}

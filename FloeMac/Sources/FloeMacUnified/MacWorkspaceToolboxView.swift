// SPDX-License-Identifier: MPL-2.0

import FloeMacToolbox
import FloeToolboxCore
import FloeToolboxUI
import SwiftUI

struct MacWorkspaceToolboxView: View {
    let openToolbox: (String) -> Void

    var body: some View {
        ToolboxHomeView(availability: availability, showsAssistantAvailability: false) { tool in
            openToolbox(tool.rawValue)
        }
    }

    private var availability: [ToolboxTool: ToolboxAvailability] {
        Dictionary(uniqueKeysWithValues: MacToolboxCatalog.availableTools.map { ($0, .available) })
    }
}

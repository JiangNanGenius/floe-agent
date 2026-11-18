// SPDX-License-Identifier: MPL-2.0

import FloeMacInstruments
import FloeMacToolbox
import FloeToolboxCore
import FloeToolboxUI
import SwiftUI

struct MacWorkspaceToolboxView: View {
    @Environment(\.locale) private var locale
    let openToolbox: (String) -> Void

    var body: some View {
        ToolboxHomeView(availability: availability, showsAssistantAvailability: false) { tool in
            openToolbox(tool.rawValue)
        }
    }

    private var availability: [ToolboxTool: ToolboxAvailability] {
        let instruments = MacInstrumentCatalog()
        var result: [ToolboxTool: ToolboxAvailability] = [:]
        for group in MacToolboxCatalog.groups(locale: locale) {
            for entry in group.tools {
                guard let tool = ToolboxTool(rawValue: entry.id) else { continue }
                if entry.isAvailable {
                    result[tool] = .available
                } else if let instrument = MacInstrument.allCases.first(where: { $0.toolboxTool == tool }),
                          case .unsupported(let notice) = instruments.availability(for: instrument) {
                    result[tool] = .unsupported(notice.text(locale))
                } else {
                    result[tool] = .unsupported(MacToolboxText.t("此工具尚未在 Mac 上提供。", "This tool is not yet available on Mac.", locale))
                }
            }
        }
        return result
    }
}

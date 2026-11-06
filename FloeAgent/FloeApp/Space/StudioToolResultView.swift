// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore

/// A returned identifier can navigate to an original; it cannot execute a
/// task or mint the assistant's document-access binding.
struct StudioToolResultView: View {
    let toolName: String
    let summary: String
    private var result: (id: UUID, title: String?)? {
        guard let bytes = summary.data(using: .utf8), bytes.count <= 100 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        let record = object["record"] as? [String: Any]
        guard let raw = (object["projectID"] ?? record?["id"]) as? String,
              raw.count == 36, let id = UUID(uuidString: raw) else { return nil }
        return (id, object["title"] as? String ?? record?["title"] as? String)
    }
    var body: some View {
        if let result {
            HStack {
                Label(result.title ?? IDELanguageRunText.t("作品", "Work"), systemImage: "doc")
                    .lineLimit(1)
                Spacer()
                Link(destination: FloeAppEntryRoute.work(result.id).url) {
                    Label(IDELanguageRunText.t("打开作品", "Open work"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("studio.result.open")
            }
            .font(.subheadline)
        }
    }
    static func title(for name: String) -> String {
        switch name {
        case "studio.create": IDELanguageRunText.t("新建作品", "Create work")
        case "studio.list": IDELanguageRunText.t("查看作品", "List works")
        case "studio.read": IDELanguageRunText.t("读取作品", "Inspect work")
        case "studio.edit": IDELanguageRunText.t("编辑作品", "Edit work")
        case "studio.run": IDELanguageRunText.t("制作与导出", "Produce and export")
        default: name
        }
    }
}
#endif

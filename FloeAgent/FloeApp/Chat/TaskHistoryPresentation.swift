// FloeApp — Portable task-history presentation shared by iPad and Mac.
//
// SPDX-License-Identifier: MPL-2.0
//
// The iPad Runs history row (More tab), the canonical batch management entry
// and the Mac Task Center render the same row anatomy: an owning-task title,
// an optional secondary line (run goal or search snippet) and a date/status
// line, all inside the platform minimum hit area. Keeping that chrome here
// keeps both apps structurally in lockstep; each platform keeps its own
// search fields, menus, actions and state copy. The file is deliberately
// UIKit/AppKit-free so the Mac target can compile it unchanged.

#if canImport(SwiftUI)
import SwiftUI

/// Shared presentation for task-history surfaces. Both apps own the same
/// durable rows; these pieces carry the rendering contract only.
enum TaskHistoryPresentation {

    /// The batch-selection affordance: a filled checkmark when the row is
    /// selected, an empty circle otherwise. The iPad batch management row
    /// and the Mac Task Center selection mode both use this exact control.
    struct SelectionMark: View {
        let isSelected: Bool

        var body: some View {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
    }

    /// The reusable history row: a one-line title (with an optional
    /// platform accessory, e.g. the Mac pin glyph), an optional subtitle and
    /// an injected date/status line, laid out at the shared minimum hit
    /// area. The status line is injected so every surface keeps its existing
    /// state copy and semantic colors exactly; the row supplies the shared
    /// anatomy, the metadata typography and the hit-area floor.
    struct HistoryRow<TitleAccessory: View, StatusLine: View>: View {
        let title: String
        var subtitle: String?
        var subtitleLineLimit: Int
        var subtitleAccessibilityIdentifier: String?
        var titleFont: Font
        var statusFont: Font
        var titleAccessory: TitleAccessory
        var statusLine: StatusLine

        init(
            title: String,
            subtitle: String? = nil,
            subtitleLineLimit: Int = 1,
            subtitleAccessibilityIdentifier: String? = nil,
            titleFont: Font = FloeTheme.Typography.body,
            statusFont: Font = FloeTheme.Typography.metadata,
            @ViewBuilder titleAccessory: () -> TitleAccessory = { EmptyView() },
            @ViewBuilder statusLine: () -> StatusLine
        ) {
            self.title = title
            self.subtitle = subtitle
            self.subtitleLineLimit = subtitleLineLimit
            self.subtitleAccessibilityIdentifier = subtitleAccessibilityIdentifier
            self.titleFont = titleFont
            self.statusFont = statusFont
            self.titleAccessory = titleAccessory()
            self.statusLine = statusLine()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    titleAccessory
                    Text(title)
                        .font(titleFont)
                        .lineLimit(1)
                }
                subtitleView
                statusLine
                    .font(statusFont)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: FloeTheme.minimumTarget)
        }

        @ViewBuilder
        private var subtitleView: some View {
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
                    .accessibilityIdentifierIfPresent(subtitleAccessibilityIdentifier)
            }
        }
    }
}

private extension View {
    /// Applies an accessibility identifier only when one was supplied, so
    /// surfaces without a snippet identifier do not publish an empty one.
    @ViewBuilder
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
#endif

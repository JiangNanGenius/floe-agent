// FloeApp — Collapsible "thinking" block.
//
// SPDX-License-Identifier: MPL-2.0
//
// Reasoning is separated from the answer behind a DisclosureGroup,
// collapsed by default: a one-line preview when folded, full selectable
// text plus a copy action when expanded. Animation honors Reduce Motion
// via FloeTheme.motionAnimation.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// A foldable reasoning ("思考过程") block.
struct ReasoningBlockView: View {
    let text: String
    /// True while reasoning is still streaming (shows a spinner).
    var isStreaming: Bool = false

    @State private var isExpanded = false
    @State private var didCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button {
                        UIPasteboard.general.string = text
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    } label: {
                        Label(
                            didCopy
                                ? LocalizedStringKey("action.copied")
                                : LocalizedStringKey("action.copy"),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(didCopy ? FloeTheme.success : FloeTheme.primary)
                    }
                    .buttonStyle(.plain)
                    .frame(
                        minWidth: FloeTheme.minimumTarget,
                        minHeight: FloeTheme.minimumTarget
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                if isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("reasoning.title")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                if !isExpanded {
                    Text(preview)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .animation(FloeTheme.motionAnimation(reduceMotion: reduceMotion), value: isExpanded)
    }

    /// Last non-empty line as the folded preview.
    private var preview: String {
        text.split(whereSeparator: { $0.isNewline })
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
#endif

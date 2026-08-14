// FloeApp — Fenced code block rendering.
//
// SPDX-License-Identifier: MPL-2.0
//
// Monospaced evidence typography, horizontal scrolling for long lines,
// a language tag when the fence carried an info string, and a copy
// button with an explicit "copied" confirmation. The button never drops
// below the 44pt minimum target.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// One fenced code block: language tag + copy action header over a
/// horizontally scrollable monospaced body.
struct CodeBlockView: View {
    /// Fence info-string language (nil when the fence had none).
    let language: String?
    /// Verbatim code content; never inline-parsed.
    let code: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(FloeTheme.Typography.evidence)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(localized: "codeblock.language") + " " + language
                    )
            }
            Spacer()
            Button {
                UIPasteboard.general.string = code
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
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(
                didCopy
                    ? LocalizedStringKey("action.copied")
                    : LocalizedStringKey("action.copy")
            )
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }
}
#endif

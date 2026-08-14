// FloeApp — Assistant answer rendering.
//
// SPDX-License-Identifier: MPL-2.0
//
// The assistant's answer is the visual subject of the thread: a wide,
// left-aligned reading column on the opaque reading surface, rendered
// through MarkdownRendererView. It deliberately does NOT mirror the
// user bubble's tint/alignment so the two roles never blur.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// One assistant answer: Markdown-rendered, full-width reading column.
struct AssistantMessageView: View {
    /// Markdown source of the answer.
    let text: String
    /// True while the owning run is non-terminal (incremental tail
    /// reparse instead of full-document parse per token).
    var isStreaming: Bool = false

    var body: some View {
        MarkdownRendererView(source: text, isStreaming: isStreaming)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "thread.role.assistant"))
    }
}
#endif

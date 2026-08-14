// FloeApp — Markdown block tree → SwiftUI.
//
// SPDX-License-Identifier: MPL-2.0
//
// Maps [MarkdownBlock] (FloeMarkdown) onto reading-surface SwiftUI:
// headings scale with level, lists indent with nested bullets, quotes
// carry a leading accent bar, code blocks go through CodeBlockView,
// tables render as a lazy Grid. While `isStreaming` is true the source
// is split at the last newline (MarkdownBlockParser.parseStreaming) so
// only the unfinished tail is re-parsed per token; once the run
// terminates the full document is parsed once and cached.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeMarkdown

/// Renders Markdown source as native SwiftUI blocks on the reading
/// surface. All colors and fonts come from FloeTheme tokens.
struct MarkdownRendererView: View {
    /// Markdown source text (agent output subset — see ARCHITECTURE §1.2).
    let source: String
    /// True while the owning run is non-terminal: the trailing partial
    /// block is re-parsed on every update instead of the full document.
    var isStreaming: Bool = false

    var body: some View {
        if isStreaming {
            let parts = MarkdownBlockParser.parseStreaming(source)
            VStack(alignment: .leading, spacing: 10) {
                MarkdownBlockSequenceView(blocks: parts.completed)
                MarkdownBlockSequenceView(blocks: parts.tail)
            }
        } else {
            // Terminal text is parsed once per source change; SwiftUI
            // reuses the view value while `source` is unchanged.
            MarkdownBlockSequenceView(blocks: MarkdownBlockParser.parse(source))
        }
    }
}

/// A vertical stack of rendered blocks. Recursive: quotes and list
/// children re-enter through this view.
struct MarkdownBlockSequenceView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

/// One block of the tree. Kept internal to the render pipeline; public
/// entry point is MarkdownRendererView.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level: level))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            Text(text)
                .font(FloeTheme.Typography.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let ordered, let items):
            MarkdownListView(ordered: ordered, items: items)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FloeTheme.primary.opacity(0.5))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                MarkdownBlockSequenceView(blocks: inner)
            }
            .padding(.leading, 2)
            .accessibilityElement(children: .contain)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)

        case .thematicBreak:
            Divider()
                .padding(.vertical, 2)
        }
    }

    /// Heading levels map onto the typography ramp: h1 ≈ title, h2 ≈
    /// section, deeper levels stay at semibold body so hierarchy reads
    /// without shouting on a phone.
    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: FloeTheme.Typography.title
        case 2: FloeTheme.Typography.section
        case 3: FloeTheme.Typography.body.weight(.semibold)
        default: FloeTheme.Typography.body.weight(.medium)
        }
    }
}

/// Bullet/numbered list with hanging indent and recursive children.
private struct MarkdownListView: View {
    let ordered: Bool
    let items: [MarkdownBlock.ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker(at: position))
                            .font(FloeTheme.Typography.body)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(item.content)
                            .font(FloeTheme.Typography.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !item.children.isEmpty {
                        MarkdownBlockSequenceView(blocks: item.children)
                            .padding(.leading, 22)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func marker(at position: Int) -> String {
        ordered ? "\(position + 1)." : "•"
    }
}

/// GFM table rendered as a lazy grid inside a horizontal scroll view so
/// wide tables never clip on a phone.
private struct MarkdownTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(FloeTheme.Typography.metadata.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }
}
#endif

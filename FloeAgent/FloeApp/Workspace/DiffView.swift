// FloeApp — Unified diff rendering.
//
// SPDX-License-Identifier: MPL-2.0
//
// Renders the unified diff produced by WorkspaceFileService.diff with
// line coloring: additions green (success), removals red (destructive),
// hunk headers accent, context lines secondary. Used by the inspector to
// show agent edits (writeFile/applyPatch before/after).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Renders unified diff text with per-line coloring.
struct DiffView: View {
    /// Unified diff text (`--- / +++ / @@ / + - space` lines).
    let diffText: String

    private enum LineKind {
        case header      // --- / +++
        case hunkHeader  // @@
        case addition    // +
        case removal     // -
        case context     // (space) or anything else
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(FloeTheme.Typography.evidence)
                        .foregroundStyle(color(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(background(for: line.kind))
                        .accessibilityLabel(accessibilityText(for: line))
                }
            }
            .padding(.vertical, 8)
        }
        .background(FloeTheme.readingSurface)
    }

    private struct DiffLine {
        let text: String
        let kind: LineKind
    }

    private var lines: [DiffLine] {
        diffText.components(separatedBy: "\n").compactMap { raw in
            guard !raw.isEmpty else { return nil }
            if raw.hasPrefix("---") || raw.hasPrefix("+++") {
                return DiffLine(text: raw, kind: .header)
            }
            if raw.hasPrefix("@@") {
                return DiffLine(text: raw, kind: .hunkHeader)
            }
            switch raw.first {
            case "+": return DiffLine(text: raw, kind: .addition)
            case "-": return DiffLine(text: raw, kind: .removal)
            default: return DiffLine(text: raw, kind: .context)
            }
        }
    }

    private func color(for kind: LineKind) -> Color {
        switch kind {
        case .header: .secondary
        case .hunkHeader: FloeTheme.primary
        case .addition: FloeTheme.success
        case .removal: FloeTheme.destructive
        case .context: .secondary
        }
    }

    private func background(for kind: LineKind) -> Color {
        switch kind {
        case .addition: FloeTheme.success.opacity(0.12)
        case .removal: FloeTheme.destructive.opacity(0.12)
        case .hunkHeader: FloeTheme.primary.opacity(0.08)
        default: .clear
        }
    }

    private func accessibilityText(for line: DiffLine) -> Text {
        switch line.kind {
        case .addition:
            Text(verbatim: String(localized: "inspector.diff.added") + " " + String(line.text.dropFirst()))
        case .removal:
            Text(verbatim: String(localized: "inspector.diff.removed") + " " + String(line.text.dropFirst()))
        default:
            Text(line.text)
        }
    }
}
#endif

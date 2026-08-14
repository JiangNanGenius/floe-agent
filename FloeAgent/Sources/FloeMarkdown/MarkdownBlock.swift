// FloeMarkdown — Placeholder for T02 (Markdown block tree + parser).
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §1.2. This target ships in T02;
// T01 only declares the module so it compiles.

import Foundation

/// Namespace marker for the FloeMarkdown module. Real block-tree types
/// (`MarkdownBlock`, `MarkdownBlockParser`, `InlineRenderer`) land in T02.
public enum FloeMarkdownModule {
    /// Module version marker; replaced by real API in T02.
    public static let placeholder = "T02"
}

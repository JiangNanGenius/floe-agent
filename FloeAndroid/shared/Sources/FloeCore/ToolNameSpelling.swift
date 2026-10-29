import Foundation

/// The single dotted/underscored tool-name spelling rule. Compat mode,
/// discovery cursors, search queries and the local model fallback all share
/// this; the 1.6.4/1.6.5 naming bugs came from four separate copies drifting.
public enum ToolNameSpelling {
    /// `workspace.readFile` -> `workspace_readFile` when the provider needs
    /// wire-safe names (`^[A-Za-z0-9_-]+$`).
    public static func wire(_ canonical: String, safe: Bool) -> String {
        safe ? canonical.replacingOccurrences(of: ".", with: "_") : canonical
    }

    /// Maps a model-emitted spelling to the unique matching name in
    /// `universe`: exact match, then case-folded match, then a unique
    /// sanitized (dot/underscore, case-folded) match. Returns nil when the
    /// spelling is unknown or ambiguous so callers can deny honestly.
    public static func canonical(_ spelling: String, among universe: [String]) -> String? {
        if universe.contains(spelling) { return spelling }
        if let folded = universe.first(where: { $0.lowercased() == spelling.lowercased() }) {
            return folded
        }
        let target = spelling.replacingOccurrences(of: ".", with: "_").lowercased()
        let matches = Set(universe.filter {
            $0.replacingOccurrences(of: ".", with: "_").lowercased() == target
        })
        return matches.count == 1 ? matches.first : nil
    }
}

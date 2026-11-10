import Foundation

/// Read-only diagnostics for an exact edit that was rejected before writing.
/// Never relaxes matching, repeats an edit, or returns document contents.
enum WorkspaceEditRecoveryHint {
    static func mismatch(
        original: String, oldText: String, newText: String,
        expected: Int, actual: Int
    ) -> String {
        var hints = [
            "Expected \(expected) exact matches; found \(actual). No edit was applied.",
            "Read the current file with workspace.readFile, then retry with an unambiguous exact range and the current revision."
        ]
        if actual == 0, !newText.isEmpty, newText != oldText, original.contains(newText) {
            hints.append("The replacement text already appears in the current file. Verify the intended range; this alone does not prove a previous edit succeeded.")
        }
        // Bounded search for an exact trimmed anchor. Line numbers help the
        // caller request a fresh window without exposing nearby file text.
        if let anchor = oldText.split(separator: "\n", omittingEmptySubsequences: false)
            .lazy.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.count >= 6 && $0.count <= 256 }) {
            var lineNumbers: [Int] = []
            let prefix = original.prefix(256 * 1024)
            for (index, line) in prefix.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(4_096).enumerated() {
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == anchor {
                    lineNumbers.append(index + 1)
                    if lineNumbers.count == 3 { break }
                }
            }
            if !lineNumbers.isEmpty {
                hints.append("An exact trimmed anchor occurs at line(s) \(lineNumbers.map(String.init).joined(separator: ", ")). Read those lines; indentation or surrounding text may differ.")
            }
        }
        return hints.joined(separator: " ")
    }
}

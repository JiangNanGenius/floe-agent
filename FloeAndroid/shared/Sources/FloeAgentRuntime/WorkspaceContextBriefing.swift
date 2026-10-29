import Foundation

/// kimi-code-style workspace grounding for the system envelope: a bounded
/// top-level listing so the model knows the workspace shape without burning
/// a tool call, plus project-supplied instruction files (AGENTS.md/FLOE.md)
/// framed strictly as reference data. All I/O is best-effort and bounded.
public enum WorkspaceContextBriefing {
    /// Recognized project instruction filenames at the workspace root, in
    /// precedence order. The first readable non-empty file wins per name.
    public static let instructionFileNames = ["FLOE.md", "AGENTS.md", "agents.md"]
    /// Beyond this, instruction files cost more than they teach.
    public static let maxInstructionBytes = 32 * 1_024
    public static let maxListingEntries = 30

    /// One-level listing, directories first, bounded. Never throws: an
    /// unreadable or empty workspace is ordinary context, not a failure.
    public static func topLevelListing(rootURL: URL?, maxEntries: Int = maxListingEntries) -> String? {
        guard let rootURL else { return nil }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootURL.path) else { return nil }
        let visible = names.filter { !$0.hasPrefix(".") }.sorted()
        guard !visible.isEmpty else { return "(empty workspace)" }
        var dirs: [String] = []
        var files: [String] = []
        for name in visible {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: rootURL.appendingPathComponent(name).path, isDirectory: &isDir)
            if exists && isDir.boolValue { dirs.append(name + "/") } else { files.append(name) }
        }
        let ordered = dirs + files
        let shown = ordered.prefix(maxEntries)
        var lines = shown.map { "- \($0)" }
        if ordered.count > shown.count {
            lines.append("- … and \(ordered.count - shown.count) more entries")
        }
        return lines.joined(separator: "\n")
    }

    /// Loads the workspace's project instruction files. Content is truncated
    /// at the byte ceiling with an explicit marker; multiple files are
    /// concatenated with provenance headers.
    public static func projectInstructions(rootURL: URL?) -> String? {
        guard let rootURL else { return nil }
        var blocks: [String] = []
        var budget = maxInstructionBytes
        for name in instructionFileNames {
            let url = rootURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let raw = String(data: data, encoding: .utf8) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var block = text
            if block.utf8.count > budget {
                block = String(decoding: block.utf8.prefix(budget), as: UTF8.self) + "\n[truncated at \(maxInstructionBytes) bytes total budget]"
            }
            budget -= block.utf8.count
            blocks.append("<!-- From: \(name) -->\n" + block)
            if budget <= 0 { break }
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
}

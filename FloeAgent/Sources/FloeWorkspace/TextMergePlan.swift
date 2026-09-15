import Foundation

/// Conservative three-way, line-based merge. A bounded diff falls back to a
/// whole-file decision rather than blocking the editor on pathological input.
public struct TextMergePlan: Sendable {
    public enum Choice: String, Sendable, CaseIterable { case mine, current }
    public struct Block: Identifiable, Sendable {
        public let id: Int
        public let base: [String]
        public let mine: [String]
        public let current: [String]
        public let isConflict: Bool
    }
    public let blocks: [Block]
    public var conflicts: [Block] { blocks.filter(\.isConflict) }
    public func resolved(_ choices: [Int: Choice] = [:]) -> String? {
        var lines: [String] = []
        for block in blocks {
            if !block.isConflict { lines += block.mine }
            else {
                guard let choice = choices[block.id] else { return nil }
                lines += choice == .mine ? block.mine : block.current
            }
        }
        return lines.joined(separator: "\n")
    }
    private struct Edit { var start: Int; var end: Int; var replacement: [String]; var mine: Bool }

    public init(base: String?, mine: String, current: String) {
        let a = base?.components(separatedBy: "\n"), b = mine.components(separatedBy: "\n"), c = current.components(separatedBy: "\n")
        func single(_ lines: [String]) -> [Block] { [.init(id: 0, base: a ?? [], mine: lines, current: lines, isConflict: false)] }
        if b == c { blocks = single(b); return }
        if a == b { blocks = single(c); return }
        if a == c { blocks = single(b); return }
        guard let a, let left = Self.diff(a, b, mine: true), let right = Self.diff(a, c, mine: false) else {
            blocks = [.init(id: 0, base: a ?? [], mine: b, current: c, isConflict: true)]; return
        }
        let edits = (left + right).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var groups: [[Edit]] = []
        for edit in edits {
            if let last = groups.last, last.contains(where: { Self.overlaps($0, edit) }) {
                groups[groups.count - 1].append(edit)
            } else { groups.append([edit]) }
        }
        var result: [Block] = [], cursor = 0
        func append(_ base: [String], _ mine: [String], _ current: [String], conflict: Bool = false) {
            result.append(.init(id: result.count, base: base, mine: mine, current: current, isConflict: conflict))
        }
        for group in groups {
            let start = group.map(\.start).min()!, end = group.map(\.end).max()!
            if cursor < start { let unchanged = Array(a[cursor..<start]); append(unchanged, unchanged, unchanged) }
            let original = Array(a[start..<end])
            func apply(_ edits: [Edit]) -> [String] {
                var output = original
                for edit in edits.sorted(by: { $0.start > $1.start }) {
                    output.replaceSubrange((edit.start - start)..<(edit.end - start), with: edit.replacement)
                }
                return output
            }
            let own = group.filter(\.mine), external = group.filter { !$0.mine }
            let mineLines = apply(own), currentLines = apply(external)
            if own.isEmpty { append(original, currentLines, currentLines) }
            else if external.isEmpty || mineLines == currentLines { append(original, mineLines, mineLines) }
            else { append(original, mineLines, currentLines, conflict: true) }
            cursor = end
        }
        if cursor < a.count { let suffix = Array(a[cursor...]); append(suffix, suffix, suffix) }
        blocks = result
    }

    private static func overlaps(_ a: Edit, _ b: Edit) -> Bool {
        if a.start == a.end { return a.start >= b.start && a.start <= b.end }
        if b.start == b.end { return b.start >= a.start && b.start <= a.end }
        return max(a.start, b.start) < min(a.end, b.end)
    }

    private static func diff(_ base: [String], _ changed: [String], mine: Bool) -> [Edit]? {
        var prefix = 0
        while prefix < min(base.count, changed.count), base[prefix] == changed[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(base.count, changed.count) - prefix,
              base[base.count - suffix - 1] == changed[changed.count - suffix - 1] { suffix += 1 }
        let a = Array(base[prefix..<(base.count - suffix)]), b = Array(changed[prefix..<(changed.count - suffix)])
        guard !a.isEmpty || !b.isEmpty else { return [] }
        if a.isEmpty || b.isEmpty { return [.init(start: prefix, end: prefix + a.count, replacement: b, mine: mine)] }
        guard a.count <= 10_000, b.count <= 10_000, (a.count + 1) * (b.count + 1) <= 2_000_000 else { return nil }
        let width = b.count + 1
        var lcs = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i * width + j] = a[i] == b[j] ? lcs[(i + 1) * width + j + 1] + 1 : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        var edits: [Edit] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1; continue }
            let start = i
            var replacement: [String] = []
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] { break }
                if j < b.count, i == a.count || lcs[i * width + j + 1] >= lcs[(i + 1) * width + j] {
                    replacement.append(b[j]); j += 1
                } else { i += 1 }
            }
            edits.append(.init(start: prefix + start, end: prefix + i, replacement: replacement, mine: mine))
        }
        return edits
    }
}

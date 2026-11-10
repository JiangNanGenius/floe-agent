// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Presentation only: never applies a patch, reads a workspace, or infers
/// that a proposed change was committed. A malformed/partial patch has no
/// trustworthy line counts and must keep its original evidence available.
struct NativeFileDiff: Sendable, Equatable {
    enum ParseError: Error { case tooLarge, malformed, unsupported }
    enum Kind: Sendable { case file, hunk, addition, removal, context, noNewline }
    struct Line: Sendable, Identifiable, Equatable {
        let id: Int
        let kind: Kind
        let content: String
        let oldNumber: Int?
        let newNumber: Int?
        var isChange: Bool { kind == .addition || kind == .removal }
    }
    let lines: [Line]
    let paths: [String]
    let added: Int
    let removed: Int
    var changedLineCount: Int { added + removed }
    var showsChangesByDefault: Bool { changedLineCount <= 5 }
    var changedLines: [Line] { lines.filter(\.isChange) }
    var compactLines: [Line] { lines.filter { $0.isChange || (paths.count > 1 && $0.kind == .file) } }

    init(unifiedDiff: String) throws {
        guard unifiedDiff.utf8.count <= 512 * 1024 else { throw ParseError.tooLarge }
        var raw = unifiedDiff.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        guard raw.count <= 40_000 else { throw ParseError.tooLarge }
        var result: [Line] = [], names: [String] = []
        var index = 0, additions = 0, removals = 0, hunks = 0
        var awaitingNewPath: String?, currentPath: String?
        var lastOldEnd = 0, lastNewEnd = 0
        func append(_ kind: Kind, _ text: String, old: Int? = nil, new: Int? = nil) {
            result.append(.init(id: result.count, kind: kind, content: text, oldNumber: old, newNumber: new))
        }
        func path(_ text: String) -> String {
            let value = String(text.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
            return value
        }
        while index < raw.count {
            let line = raw[index]
            if line.hasPrefix("--- ") {
                guard awaitingNewPath == nil else { throw ParseError.malformed }
                awaitingNewPath = path(String(line.dropFirst(4)))
                index += 1; continue
            }
            if line.hasPrefix("+++ ") {
                guard let oldPath = awaitingNewPath else { throw ParseError.malformed }
                let newPath = path(String(line.dropFirst(4)))
                currentPath = newPath == "/dev/null" ? oldPath : newPath
                guard let currentPath, !currentPath.isEmpty else { throw ParseError.malformed }
                names.append(currentPath); append(.file, currentPath)
                awaitingNewPath = nil; lastOldEnd = 0; lastNewEnd = 0
                index += 1; continue
            }
            if line.hasPrefix("@@") {
                guard awaitingNewPath == nil else { throw ParseError.malformed }
                let range = try Self.hunkRange(line)
                guard range.oldStart >= lastOldEnd, range.newStart >= lastNewEnd else { throw ParseError.malformed }
                if currentPath == nil { currentPath = "" }
                append(.hunk, line); hunks += 1; index += 1
                var old = range.oldStart, new = range.newStart
                var seenOld = 0, seenNew = 0
                var hasBody = false
                while index < raw.count, seenOld < range.oldCount || seenNew < range.newCount {
                    let body = raw[index]
                    if body == "\\ No newline at end of file" {
                        guard hasBody else { throw ParseError.malformed }
                        append(.noNewline, body); index += 1; continue
                    }
                    guard let marker = body.first else { throw ParseError.malformed }
                    let content = String(body.dropFirst())
                    switch marker {
                    case " ":
                        guard seenOld < range.oldCount, seenNew < range.newCount else { throw ParseError.malformed }
                        append(.context, content, old: old, new: new)
                        seenOld += 1; seenNew += 1; old += 1; new += 1
                    case "-":
                        guard seenOld < range.oldCount else { throw ParseError.malformed }
                        append(.removal, content, old: old)
                        seenOld += 1; old += 1; removals += 1
                    case "+":
                        guard seenNew < range.newCount else { throw ParseError.malformed }
                        append(.addition, content, new: new)
                        seenNew += 1; new += 1; additions += 1
                    default: throw ParseError.malformed
                    }
                    hasBody = true; index += 1
                }
                guard seenOld == range.oldCount, seenNew == range.newCount else { throw ParseError.malformed }
                if index < raw.count, raw[index] == "\\ No newline at end of file" {
                    guard hasBody else { throw ParseError.malformed }
                    append(.noNewline, raw[index]); index += 1
                }
                lastOldEnd = range.oldStart + range.oldCount
                lastNewEnd = range.newStart + range.newCount
                continue
            }
            if line.hasPrefix("diff --git ") {
                guard awaitingNewPath == nil else { throw ParseError.malformed }
                currentPath = nil; lastOldEnd = 0; lastNewEnd = 0
            } else if line.isEmpty || Self.metadataPrefixes.contains(where: line.hasPrefix) {
                // Git's mode/index metadata does not count as file lines.
            } else { throw ParseError.unsupported }
            index += 1
        }
        guard awaitingNewPath == nil, hunks > 0 else { throw ParseError.malformed }
        self.lines = result; paths = names; added = additions; removed = removals
    }

    private static let metadataPrefixes = ["index ", "new file mode ", "deleted file mode ", "old mode ", "new mode ", "similarity index ", "dissimilarity index ", "rename from ", "rename to ", "copy from ", "copy to "]
    private struct HunkRange { let oldStart: Int; let oldCount: Int; let newStart: Int; let newCount: Int }
    private static func hunkRange(_ header: String) throws -> HunkRange {
        // Bounded header parsing prevents huge numeric input/regex work.
        guard header.utf8.count <= 4096 else { throw ParseError.tooLarge }
        let fields = header.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count >= 4, fields[0] == "@@", fields[3] == "@@" else { throw ParseError.malformed }
        func range(_ field: Substring, prefix: Character) throws -> (Int, Int) {
            guard field.first == prefix else { throw ParseError.malformed }
            let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
                  let start = Int(parts[0]), let count = parts.count == 2 ? Int(parts[1]) : 1,
                  count <= 40_000, count == 0 || start > 0,
                  !start.addingReportingOverflow(count).overflow else { throw ParseError.malformed }
            return (start, count)
        }
        let old = try range(fields[1], prefix: "-"), new = try range(fields[2], prefix: "+")
        guard old.1 > 0 || new.1 > 0 else { throw ParseError.malformed }
        return .init(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }
}

enum NativeFileDiffDisposition: Sendable {
    case applied, proposal, reference
    static let writeTools: Set<String> = ["workspace.createFile", "workspace.writeFile", "workspace.applyPatch", "workspace.appendFile", "workspace.replaceText"]
    static func result(tool: String, status: String, summary: String?, outcomeUnknown: Bool = false) -> Self {
        guard !outcomeUnknown, ["ok", "success", "succeeded", "completed"].contains(status), let summary else { return .reference }
        let marker: String
        switch tool {
        case "workspace.createFile": marker = "created="
        case "workspace.writeFile": marker = "written="
        case "workspace.applyPatch": marker = "patched="
        case "workspace.appendFile", "workspace.replaceText": marker = "edited="
        default: return .reference
        }
        return summary.hasPrefix(marker) && summary.contains(" sha256=") ? .applied : .reference
    }
    static func proposedPatch(tool: String, status: String, input: String?) -> String? {
        guard tool == "workspace.applyPatch", ["pending", "needsUser", "running", "executingTool"].contains(status),
              let input, input.utf8.count <= 600 * 1024, let data = input.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let patch = fields["patch"] as? String, (try? NativeFileDiff(unifiedDiff: patch)) != nil else { return nil }
        return patch
    }
}

enum NativeFileDiffLayout {
    static func maximumHeight(isPad: Bool, viewportHeight: Double?) -> Double {
        let deviceCap = isPad ? 320.0 : 240.0
        guard let viewportHeight, viewportHeight.isFinite, viewportHeight > 0 else { return deviceCap }
        return min(deviceCap, viewportHeight * 0.45)
    }
}

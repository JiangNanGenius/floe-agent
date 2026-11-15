// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

/// Typed build-time diagnostics for standard multi-file ink projects.
///
/// These are produced before any artifact is published. Imported story text is
/// never used to grant permissions, commands, host paths or network access;
/// this type only reports how the bounded source graph could not be prepared.
public enum InkArtifactError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Several root candidates exist and the host did not choose one.
    case ambiguousEntry(candidates: [String])
    /// The explicit entry is not a regular `.ink` file in the project.
    case entryNotFound(String)
    /// A path (entry or INCLUDE) is absolute, control-bearing or escapes the project.
    case unsafeInclude(path: String, includedFrom: String)
    /// An INCLUDE target does not exist in the bounded project tree.
    case missingInclude(file: String, includedFrom: String)
    /// The compiler's own recursive-INCLUDE rule would reject this graph.
    case includeCycle(path: [String])
    /// A selected source or INCLUDE target is a symbolic link.
    case symbolicLink(String)
    /// The source is not a bounded UTF-8 regular file.
    case unreadableSource(String)
    /// More source files than the bounded graph permits.
    case tooManySources(Int)
    /// More source bytes than the bounded graph permits.
    case sourcesTooLarge(Int)
    /// The entry file is empty.
    case emptySource(String)

    public var description: String {
        switch self {
        case .ambiguousEntry(let candidates):
            return "multiple ink entry points; choose one explicitly: " + candidates.joined(separator: ", ")
        case .entryNotFound(let path):
            return "ink entry not found: " + path
        case .unsafeInclude(let path, let from):
            return "unsafe INCLUDE '\(path)' in \(from)"
        case .missingInclude(let file, let from):
            return "missing INCLUDE '\(file)' referenced by \(from)"
        case .includeCycle(let path):
            return "recursive INCLUDE: " + path.joined(separator: " -> ")
        case .symbolicLink(let path):
            return "symbolic link is not a readable ink source: " + path
        case .unreadableSource(let path):
            return "unreadable ink source: " + path
        case .tooManySources(let maximum):
            return "more than \(maximum) ink source files"
        case .sourcesTooLarge(let maximum):
            return "ink sources exceed \(maximum) bytes"
        case .emptySource(let path):
            return "empty ink source: " + path
        }
    }
}

/// A bounded, deterministic ink source graph. `sources` is the exact text
/// embedded into the artifact: every `INCLUDE` path is canonicalised to a
/// project-relative path so the compiler only reads this map (never the host
/// filesystem or a network response). Story text is otherwise byte-preserved.
public struct InkSourceGraph: Sendable, Equatable {
    public let entry: String
    /// Discovery order: entry first, then includes in source order, depth first.
    public let order: [String]
    public let sources: [String: String]
    /// Include edges that were validated, for evidence/diagnostics.
    public let includes: [String: [String]]

    public var entryText: String { sources[entry] ?? "" }

    public static func prepare(projectAt project: URL,
                               entry explicit: String? = nil,
                               maximumFiles: Int = 128,
                               maximumSourceBytes: Int = 1 * 1_024 * 1_024,
                               maximumTotalBytes: Int = 4 * 1_024 * 1_024,
                               maximumDepth: Int = 32) throws -> InkSourceGraph {
        guard maximumFiles > 0, maximumSourceBytes > 0, maximumTotalBytes >= maximumSourceBytes,
              maximumDepth > 0 else { throw NarrativeAdapterError.invalidProject("invalid ink bounds") }
        let tree = try NarrativeBuildTree(root: project)
        let entries = try tree.walk()
        let regular = entries.filter { !$0.directory && $0.regular && !$0.symlink }
        let links = Set(entries.filter(\.symlink).map(\.path))
        let all = regular.map(\.path).filter { $0.lowercased().hasSuffix(".ink") }
        if all.isEmpty {
            if let explicit, !explicit.isEmpty, let path = try? normalise(raw: explicit, from: ""),
               links.contains(path) {
                throw InkArtifactError.symbolicLink(path)
            }
            throw InkArtifactError.entryNotFound(explicit ?? "")
        }
        let sorted = all.sorted(by: utf8Less)
        let selected = try selectEntry(candidates: sorted, explicit: explicit, links: links)
        // Case/Unicode normalisation mirrors the case-insensitive volume while
        // keeping the compiler-visible key equal to the actual file path.
        var folded: [String: String] = [:]
        for path in sorted { folded[fold(path)] = path }
        var sources: [String: String] = [:]
        var order: [String] = []
        var includesByFile: [String: [String]] = [:]
        var stack: [String] = []
        var processed: Set<String> = []
        var total = 0

        func visit(_ path: String) throws {
            if let index = stack.firstIndex(of: path) {
                throw InkArtifactError.includeCycle(path: Array(stack[index...]) + [path])
            }
            if processed.contains(path) { return }
            guard processed.count < maximumFiles else { throw InkArtifactError.tooManySources(maximumFiles) }
            let data = try readSource(tree: tree, path: path, maximum: maximumSourceBytes, links: links)
            total += data.count
            guard total <= maximumTotalBytes else { throw InkArtifactError.sourcesTooLarge(maximumTotalBytes) }
            let (text, rawIncludes) = try canonicalise(data, path: path) { raw in
                try resolve(raw: raw, from: path, folded: folded, links: links)
            }
            processed.insert(path)
            sources[path] = text
            order.append(path)
            includesByFile[path] = rawIncludes
            stack.append(path)
            defer { stack.removeLast() }
            for target in rawIncludes { try visit(target) }
        }

        try visit(selected)
        guard !(sources[selected] ?? "").isEmpty else { throw InkArtifactError.emptySource(selected) }
        return InkSourceGraph(entry: selected, order: order, sources: sources, includes: includesByFile)
    }

    /// All regular `.ink` paths, sorted. Symlinked sources are not candidates.
    public static func candidateEntries(projectAt project: URL) throws -> [String] {
        let tree = try NarrativeBuildTree(root: project)
        return try tree.walk()
            .filter { !$0.directory && $0.regular && !$0.symlink && $0.path.lowercased().hasSuffix(".ink") }
            .map(\.path)
            .sorted(by: utf8Less)
    }

    /// Deterministic default: a root `story.ink`, then a root `main.ink`, then a
    /// single root-level file, then a single file anywhere. Anything else needs
    /// an explicit host choice instead of guessing.
    static func selectEntry(candidates: [String], explicit: String?,
                            links: Set<String> = []) throws -> String {
        if let explicit, !explicit.isEmpty {
            let path = try normalise(raw: explicit, from: "")
            if links.contains(path) { throw InkArtifactError.symbolicLink(path) }
            if let actual = candidates.first(where: { $0 == path })
                ?? candidates.first(where: { fold($0) == fold(path) }) {
                return actual
            }
            throw InkArtifactError.entryNotFound(explicit)
        }
        for preferred in ["story.ink", "main.ink"] {
            if let match = candidates.first(where: { $0 == preferred }) { return match }
        }
        let rootLevel = candidates.filter { !$0.contains("/") }
        if rootLevel.count == 1 { return rootLevel[0] }
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty { throw InkArtifactError.entryNotFound("") }
        throw InkArtifactError.ambiguousEntry(candidates: candidates)
    }

    // MARK: - Bounded source handling

    static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    static func resolve(raw: String, from including: String,
                        folded: [String: String], links: Set<String>) throws -> String {
        let path = try normalise(raw: raw, from: including)
        if links.contains(path) { throw InkArtifactError.symbolicLink(path) }
        if let actual = folded[fold(path)] {
            if links.contains(actual) { throw InkArtifactError.symbolicLink(actual) }
            return actual
        }
        throw InkArtifactError.missingInclude(file: raw, includedFrom: including)
    }

    /// Project-relative normalisation. Backslashes are accepted as separators
    /// for Windows-authored stories, `..` may ascend but never above the project
    /// root, and absolute/drive/control-bearing names are denied.
    static func normalise(raw: String, from including: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 1_024 else {
            throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
        }
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
        }
        var text = raw.replacingOccurrences(of: "\\", with: "/")
        guard !text.hasPrefix("/") else {
            throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
        }
        if text.count >= 2, text[text.index(text.startIndex, offsetBy: 1)] == ":" {
            throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
        }
        var parts = including.isEmpty ? [] : including.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        for component in text.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !parts.isEmpty else {
                    throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
                }
                parts.removeLast()
            default:
                guard !component.contains(":") else {
                    throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
                }
                parts.append(String(component))
            }
        }
        guard !parts.isEmpty else {
            throw InkArtifactError.unsafeInclude(path: raw, includedFrom: including)
        }
        text = parts.joined(separator: "/")
        return text
    }

    static func readSource(tree: NarrativeBuildTree, path: String, maximum: Int,
                           links: Set<String>) throws -> Data {
        if links.contains(path) { throw InkArtifactError.symbolicLink(path) }
        do {
            return try tree.read(path, maximum: maximum)
        } catch let error as NarrativeAdapterError {
            if case .invalidProject(let reason) = error, reason.hasPrefix("symbolic link:") {
                throw InkArtifactError.symbolicLink(path)
            }
            throw InkArtifactError.unreadableSource(path)
        }
    }

    /// Replaces each INCLUDE filename with its canonical project-relative path.
    /// The story text is otherwise preserved byte-for-byte. Comments are masked
    /// exactly like ink's pre-processor before directives are recognised, so a
    /// commented-out INCLUDE is neither resolved nor rewritten.
    static func canonicalise(_ data: Data, path: String,
                             resolve: (String) throws -> String) throws -> (String, [String]) {
        let bytes = [UInt8](data)
        let masked = maskComments(bytes)
        let directives = includeDirectives(in: masked)
        guard !directives.isEmpty else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw InkArtifactError.unreadableSource(path)
            }
            return (text, [])
        }
        var replacements: [(Range<Int>, [UInt8])] = []
        var targets: [String] = []
        for directive in directives {
            guard let raw = String(bytes: bytes[directive.range], encoding: .utf8) else {
                throw InkArtifactError.unreadableSource(path)
            }
            let target = try resolve(raw)
            replacements.append((directive.range, Array(target.utf8)))
            targets.append(target)
        }
        var result = bytes
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        guard let text = String(bytes: result, encoding: .utf8) else {
            throw InkArtifactError.unreadableSource(path)
        }
        return (text, targets)
    }

    struct Directive {
        let range: Range<Int>
    }

    static func maskComments(_ input: [UInt8]) -> [UInt8] {
        var output = input
        var index = 0
        var inBlock = false
        while index < output.count {
            if inBlock {
                if output[index] == 0x2A, index + 1 < output.count, output[index + 1] == 0x2F {
                    output[index] = 0x20; output[index + 1] = 0x20
                    index += 2; inBlock = false
                } else {
                    if output[index] != 0x0A, output[index] != 0x0D { output[index] = 0x20 }
                    index += 1
                }
            } else if output[index] == 0x2F, index + 1 < output.count, output[index + 1] == 0x2F {
                while index < output.count, output[index] != 0x0A {
                    output[index] = 0x20
                    index += 1
                }
            } else if output[index] == 0x2F, index + 1 < output.count, output[index + 1] == 0x2A {
                output[index] = 0x20; output[index + 1] = 0x20
                index += 2; inBlock = true
            } else {
                index += 1
            }
        }
        return output
    }

    static func includeDirectives(in masked: [UInt8]) -> [Directive] {
        let include = Array("INCLUDE".utf8)
        var result: [Directive] = []
        var lineStart = 0
        while lineStart < masked.count {
            var lineEnd = lineStart
            while lineEnd < masked.count, masked[lineEnd] != 0x0A { lineEnd += 1 }
            var cursor = lineStart
            while cursor < lineEnd, masked[cursor] == 0x20 || masked[cursor] == 0x09 { cursor += 1 }
            if cursor + include.count <= lineEnd,
               Array(masked[cursor..<(cursor + include.count)]) == include {
                let next = cursor + include.count
                if next == lineEnd {
                    // Bare `INCLUDE` is a malformed directive, not story text.
                    result.append(Directive(range: next..<next))
                } else if masked[next] == 0x20 || masked[next] == 0x09 {
                    var start = next
                    while start < lineEnd, masked[start] == 0x20 || masked[start] == 0x09 { start += 1 }
                    var end = lineEnd
                    while end > start, masked[end - 1] == 0x20 || masked[end - 1] == 0x09
                        || masked[end - 1] == 0x0D {
                        end -= 1
                    }
                    result.append(Directive(range: start..<end))
                }
            }
            lineStart = lineEnd + 1
        }
        return result
    }
}

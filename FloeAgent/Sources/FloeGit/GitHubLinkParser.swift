// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum GitHubLinkParser {
    public static func parse(_ input: String) throws -> GitHubLink {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 16_384, !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw GitHubLinkError.invalidLink("length or control character")
        }
        var cloneOnly = false
        if raw.hasPrefix("git@github.com:") {
            raw = "https://github.com/" + raw.dropFirst("git@github.com:".count)
            cloneOnly = true
        } else if raw.hasPrefix("ssh://git@github.com/") {
            raw = "https://github.com/" + raw.dropFirst("ssh://git@github.com/".count)
            cloneOnly = true
        }
        // URLComponents otherwise repairs malformed '%' and loses the original error.
        // Encode only non-URI characters before parsing. Foundation otherwise
        // repairs mixed Unicode + %20 input by encoding '%' a second time.
        let uriCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/?#[]@!$&'()*+,;=%-._~")
        guard !raw.contains("\\"), validEscapes(raw),
              let uri = raw.addingPercentEncoding(withAllowedCharacters: uriCharacters),
              let components = URLComponents(string: uri), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["github.com", "www.github.com", "raw.githubusercontent.com"].contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { throw GitHubLinkError.unsupportedLink }
        let encoded = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard encoded.first == "", !encoded.dropFirst().dropLast().contains(""),
              let decoded = decodeSegments(Array(encoded.dropFirst()).map(String.init)) else {
            throw GitHubLinkError.invalidLink("path")
        }
        var parts = decoded
        if parts.last == "" { parts.removeLast() }
        guard parts.count >= 2, validIdentity(parts[0]), validIdentity(parts[1]) else {
            throw GitHubLinkError.invalidLink("repository identity")
        }
        let owner = parts.removeFirst()
        var name = parts.removeFirst()
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard validIdentity(name), !name.isEmpty else { throw GitHubLinkError.invalidLink("repository identity") }
        let identity = GitHubLinkRepositoryID(owner: owner, name: name)
        var kind: GitHubLink.Kind = .repository
        var tail: [String] = []
        var refKind: GitHubLinkRevision.Kind?
        var number: Int?
        var prCommit: String?
        if host == "raw.githubusercontent.com" {
            guard parts.count >= 2 else { throw GitHubLinkError.invalidLink("raw file path") }
            kind = .file; tail = parts
        } else if !parts.isEmpty {
            guard !cloneOnly else { throw GitHubLinkError.unsupportedLink }
            let route = parts.removeFirst()
            switch route {
            case "tree", "blob", "raw":
                kind = route == "tree" ? .tree : .file
                guard !parts.isEmpty else { throw GitHubLinkError.invalidLink("missing revision") }
                tail = parts
            case "commit":
                guard parts.count == 1, isCommitName(parts[0]) else { throw GitHubLinkError.invalidLink("commit") }
                kind = .commit; tail = parts
            case "issues", "pull":
                guard let first = parts.first, let value = Int(first), value > 0,
                      String(value) == first else { throw GitHubLinkError.invalidLink("issue number") }
                number = value; parts.removeFirst(); kind = route == "issues" ? .issue : .pullRequest
                if kind == .issue { guard parts.isEmpty else { throw GitHubLinkError.unsupportedLink } }
                else if !parts.isEmpty {
                    guard ["files", "commits"].contains(parts[0]), parts.count <= 2 else { throw GitHubLinkError.unsupportedLink }
                    if parts.count == 2 {
                        guard isCommitName(parts[1]) else { throw GitHubLinkError.invalidLink("PR commit") }
                        prCommit = parts[1]
                    }
                }
            default: throw GitHubLinkError.unsupportedLink
            }
        }
        if tail.count >= 3, tail[0] == "refs", ["heads", "tags"].contains(tail[1]) {
            refKind = tail[1] == "heads" ? .branch : .tag
            tail.removeFirst(2)
        }
        guard tail.count <= 128 else { throw GitHubLinkError.invalidLink("path depth") }
        let fragment: String?
        if let value = components.percentEncodedFragment, !value.isEmpty {
            guard let value = value.removingPercentEncoding, value.utf8.count <= 1024,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw GitHubLinkError.invalidLink("anchor")
            }
            fragment = value
        } else { fragment = nil }
        let anchor = try fragment.map(parseAnchor)
        // Never retain arbitrary query parameters (including access tokens) in a source or model context.
        let canonicalParts: [String]
        if host == "raw.githubusercontent.com" { canonicalParts = [owner, name, "blob"] + decoded.dropFirst(2) }
        else { canonicalParts = [owner, name] + decoded.dropFirst(2) }
        let url = try webURL(canonicalParts, fragment: fragment)
        return GitHubLink(url: url, repository: identity, kind: kind, revisionAndPath: tail,
                          explicitRefKind: refKind, number: number, anchor: anchor, pullRequestCommit: prCommit)
    }

    static func webURL(_ segments: [String], fragment: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = "github.com"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        components.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        components.fragment = fragment
        guard let url = components.url else { throw GitHubLinkError.invalidLink("canonical URL") }
        return url
    }

    static func isCommitName(_ value: String) -> Bool {
        (7...40).contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func isSHA(_ value: String) -> Bool { value.count == 40 && isCommitName(value) }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }
    }

    private static func validEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, bytes[(index + 1)...(index + 2)].allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { return false }
        }
        return true
    }

    private static func decodeSegments(_ values: [String]) -> [String]? {
        var output: [String] = []
        for value in values {
            guard let decoded = value.removingPercentEncoding,
                  !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || ($0.isEmpty && !decoded.isEmpty) }),
                  !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            output.append(decoded)
        }
        return output
    }

    private static func parseAnchor(_ raw: String) throws -> GitHubLinkAnchor {
        func captures(_ expression: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: expression),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: raw).map { String(raw[$0]) } ?? "" }
        }
        if let values = captures("^L([0-9]+)(?:-L?([0-9]+))?$") {
            guard let start = Int(values[0]), let end = Int(values[1].isEmpty ? values[0] : values[1]), start > 0, end >= start else {
                throw GitHubLinkError.invalidLink("line range")
            }
            return .lines(start: start, end: end)
        }
        for (prefix, kind) in [("issuecomment-", 0), ("discussion_r", 1), ("pullrequestreview-", 2)] where raw.hasPrefix(prefix) {
            guard let value = Int64(raw.dropFirst(prefix.count)), value > 0 else { throw GitHubLinkError.invalidLink("comment anchor") }
            switch kind { case 0: return .issueComment(value); case 1: return .reviewComment(value); default: return .review(value) }
        }
        if let values = captures("^diff-([a-fA-F0-9]{64})(?:([LR])([0-9]+)(?:-([LR]?)([0-9]+))?)?$") {
            let start = values[2].isEmpty ? nil : Int(values[2])
            let end = values[4].isEmpty ? start : Int(values[4])
            guard start == nil || (start! > 0 && end != nil && end! >= start!), values[3].isEmpty || values[3] == values[1] else {
                throw GitHubLinkError.invalidLink("diff range")
            }
            return .diff(digest: values[0].lowercased(), side: values[1].isEmpty ? nil : values[1], start: start, end: end)
        }
        return .other(raw)
    }
}

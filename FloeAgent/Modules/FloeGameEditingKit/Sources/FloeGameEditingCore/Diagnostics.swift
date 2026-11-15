// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameEditDiagnostic: Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable { case info, warning, error }
    public let id: UUID
    public var severity: Severity
    public var message: GameEditCopy
    /// Project file the diagnostic refers to, when applicable.
    public var path: GameRelativePath?
    /// Location inside a JSON document, when applicable.
    public var jsonPath: JSONFieldPath?
    public init(id: UUID = UUID(), severity: Severity, message: GameEditCopy,
                path: GameRelativePath? = nil, jsonPath: JSONFieldPath? = nil) {
        self.id = id; self.severity = severity; self.message = message
        self.path = path; self.jsonPath = jsonPath
    }
}

public struct GameEditIssue: Error, Hashable, Sendable {
    public let diagnostics: [GameEditDiagnostic]
    public var message: String { diagnostics.map { $0.message.en }.joined(separator: "; ") }
    public init(_ diagnostics: [GameEditDiagnostic]) { self.diagnostics = diagnostics }
}

/// One detected reference from a project document to another project file.
public struct AssetReference: Hashable, Sendable {
    public var referencingPath: GameRelativePath
    public var jsonPath: JSONFieldPath?
    /// 1-based line in a plain-text document.
    public var line: Int?
    public var matchedValue: String
}

/// Engine-neutral reference scanning: exact relative-path string matches in
/// JSON documents and line-based matches in text documents. Adapters may add
/// engine-specific scanners later without changing the diagnostics shape.
public enum GameReferenceScanner {
    public static func references(to target: GameRelativePath, inDocumentAt path: GameRelativePath, bytes: Data) -> [AssetReference] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        let candidates = matchCandidates(for: target)
        guard !candidates.isEmpty else { return [] }
        if let root = try? JSONValue.parse(bytes), root.objectValue != nil || root.arrayValue != nil {
            return scanJSON(root, in: path, candidates: candidates)
        }
        return scanText(text, in: path, candidates: candidates)
    }

    static func matchCandidates(for target: GameRelativePath) -> [String] {
        var result = [target.value]
        if let last = target.value.split(separator: "/").last {
            result.append(String(last))
        }
        return Array(Set(result))
    }

    static func scanJSON(_ root: JSONValue, in path: GameRelativePath, candidates: [String]) -> [AssetReference] {
        var references: [AssetReference] = []
        func walk(_ value: JSONValue, _ fieldPath: JSONFieldPath) {
            switch value {
            case .string(let string):
                if candidates.contains(string) {
                    references.append(.init(referencingPath: path, jsonPath: fieldPath, line: nil, matchedValue: string))
                }
            case .array(let values):
                for (index, child) in values.enumerated() {
                    walk(child, fieldPath.appending(.index(index)))
                }
            case .object(let values):
                for (key, child) in values {
                    walk(child, fieldPath.appending(.key(key)))
                }
            default: break
            }
        }
        walk(root, JSONFieldPath([]))
        return references
    }

    static func scanText(_ text: String, in path: GameRelativePath, candidates: [String]) -> [AssetReference] {
        var references: [AssetReference] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let content = String(line)
            if let matched = candidates.first(where: { content.contains($0) }) {
                references.append(.init(referencingPath: path, jsonPath: nil, line: offset + 1, matchedValue: matched))
            }
        }
        return references
    }
}

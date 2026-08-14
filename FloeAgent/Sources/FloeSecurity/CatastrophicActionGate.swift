// FloeSecurity — Catastrophic action gate.
// See docs/DEVELOPMENT_PLAN.md §3.3: an independent gate that runs before
// every approval mode and stops only high-confidence destructive actions.

import Foundation
import FloeCore

/// Independent pre-approval gate. Runs before all three approval policies.
/// A stop requires a second local authentication plus impact confirmation
/// to release. This gate does NOT promise to catch destructive behavior
/// hidden inside scripts — only high-confidence surface patterns.
public struct CatastrophicActionGate: Sendable {

    public struct Pattern: Sendable, Codable, Hashable {
        public var id: String
        public var regex: String
        public var reason: String
    }

    public struct Verdict: Sendable, Hashable {
        public var stopped: Bool
        public var matchedPatternID: String?
        public var reason: String?

        public static let clear = Verdict(stopped: false, matchedPatternID: nil, reason: nil)
    }

    private let compiledPatterns: [(pattern: Pattern, regex: NSRegularExpression)]

    public init(patterns: [Pattern]) throws {
        var compiled: [(Pattern, NSRegularExpression)] = []
        for pattern in patterns {
            let regex = try NSRegularExpression(
                pattern: pattern.regex,
                options: [.caseInsensitive]
            )
            compiled.append((pattern, regex))
        }
        self.compiledPatterns = compiled
    }

    /// Loads the bundled pattern corpus.
    public static func withBundledPatterns(bundle: Bundle? = nil) throws -> CatastrophicActionGate {
        let resolvedBundle = bundle ?? Bundle.module
        guard let url = resolvedBundle.url(forResource: "catastrophic-patterns", withExtension: "json") else {
            throw FloeError.internalError("catastrophic-patterns.json missing from bundle")
        }
        let data = try Data(contentsOf: url)
        struct Corpus: Codable {
            var patterns: [Pattern]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        return try CatastrophicActionGate(patterns: corpus.patterns)
    }

    /// Production fallback when the corpus cannot be loaded. Matching every
    /// command is intentionally restrictive: a packaging failure must never
    /// silently remove the independent destructive-action control.
    public static func failClosed(reason: String) -> CatastrophicActionGate {
        // The constant pattern is known-valid. Keeping the failure local
        // avoids making every production dependency optional.
        try! CatastrophicActionGate(patterns: [Pattern(
            id: "gate-unavailable",
            regex: #"[\s\S]*"#,
            reason: reason
        )])
    }

    /// Evaluates a shell command string. Returns `.stopped` verdict on any
    /// high-confidence destructive match.
    public func evaluate(command: String) -> Verdict {
        let normalized = Self.normalize(command)
        let range = NSRange(normalized.startIndex..., in: normalized)
        for (pattern, regex) in compiledPatterns {
            if regex.firstMatch(in: normalized, range: range) != nil {
                return Verdict(stopped: true, matchedPatternID: pattern.id, reason: pattern.reason)
            }
        }
        return .clear
    }

    /// Normalizes a command for matching: strips quotes and format-control
    /// characters, collapses whitespace, lowercases, removes continuations.
    static func normalize(_ command: String) -> String {
        var result = command
        result = result.replacingOccurrences(of: "\\\n", with: "")
        result = result.unicodeScalars.map { scalar in
            if scalar.properties.generalCategory == .format {
                return ""
            }
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        result = result.replacingOccurrences(of: "\"", with: "")
        result = result.replacingOccurrences(of: "'", with: "")
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

import Foundation

/// Bounded parser for inexpensive approval classifiers. It accepts harmless
/// formatting drift while refusing ambiguous or contradictory decisions.
public struct ApprovalDecisionParser: Sendable {
    public enum Outcome: String, Sendable, Codable, Hashable {
        case allow
        case deny
        case ask
    }

    public struct Parsed: Sendable, Hashable {
        public var outcome: Outcome
        public var reason: String?
        public var route: String

        public init(outcome: Outcome, reason: String? = nil, route: String) {
            self.outcome = outcome
            self.reason = reason
            self.route = route
        }
    }

    public enum ParseError: LocalizedError, Sendable {
        case empty
        case ambiguous
        case missingDecision

        public var errorDescription: String? {
            switch self {
            case .empty: "Approval response was empty"
            case .ambiguous: "Approval response contained contradictory decisions"
            case .missingDecision: "Approval response did not contain a decisive result"
            }
        }
    }

    public init() {}

    public func parse(_ raw: String) throws -> Parsed {
        let normalized = Self.normalized(raw)
        guard !normalized.isEmpty else { throw ParseError.empty }

        if let object = Self.firstJSONObject(in: normalized),
           let parsed = Self.parseJSONObject(object) {
            return parsed
        }

        let candidates = Self.decisionCandidates(in: normalized)
        guard !candidates.isEmpty else { throw ParseError.missingDecision }
        guard Set(candidates).count == 1, let outcome = candidates.first else {
            throw ParseError.ambiguous
        }
        return Parsed(outcome: outcome, route: "decisive-token")
    }

    private static func parseJSONObject(_ object: String) -> Parsed? {
        guard let data = object.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any] else { return nil }

        let decisionKeys = ["decision", "result", "action", "verdict", "approved", "allow"]
        var values: [Outcome] = []
        for key in decisionKeys {
            guard let value = dictionary[key] else { continue }
            if let bool = value as? Bool {
                values.append(bool ? .allow : .deny)
            } else if let parsed = outcome(from: String(describing: value)) {
                values.append(parsed)
            }
        }
        guard !values.isEmpty, Set(values).count == 1, let outcome = values.first else {
            return nil
        }
        let reasonKeys = ["reason", "message", "explanation", "理由", "原因"]
        let reason = reasonKeys.lazy.compactMap { dictionary[$0] as? String }.first
        return Parsed(outcome: outcome, reason: reason, route: "json-object")
    }

    private static func decisionCandidates(in value: String) -> [Outcome] {
        value
            .split(whereSeparator: { $0.isNewline })
            .prefix(8)
            .compactMap { leadingOutcome(in: String($0)) }
    }

    /// Weak classifiers often return a short sentence rather than one token.
    /// Read the declared result at the beginning of each line and ignore risk
    /// words that merely occur later in its explanation (for example
    /// "ALLOW because there is no reason to deny"). Opposite declarations on
    /// separate lines still remain ambiguous and fail closed.
    private static func leadingOutcome(in rawLine: String) -> Outcome? {
        var line = rawLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let labels = [
            "decision", "result", "verdict", "action",
            "decision is", "result is", "verdict is",
            "结论", "决定", "结果", "审核结果", "审批结果", "判断"
        ]
        for label in labels {
            if line.hasPrefix(label) {
                line.removeFirst(label.count)
                line = line.trimmingCharacters(
                    in: .whitespacesAndNewlines.union(
                        CharacterSet(charactersIn: ":：=-—>「」『』")
                    )
                )
                break
            }
        }

        let denyPrefixes = [
            "deny", "denied", "reject", "rejected", "block", "blocked", "no",
            "i deny", "i reject", "this is denied", "cannot approve", "do not approve",
            "拒绝", "禁止", "驳回", "不允许", "阻止", "不能批准", "不予批准", "需要阻止"
        ]
        let askPrefixes = [
            "ask", "review", "human", "escalate", "clarify", "confirm",
            "needs human", "requires human", "request confirmation",
            "询问", "人工", "复核", "确认", "升级", "需要人工", "请求确认"
        ]
        let allowPrefixes = [
            "allow", "allowed", "approve", "approved", "yes", "true", "pass",
            "i allow", "i approve", "this is approved", "do not block", "no need to block",
            "允许", "批准", "通过", "同意", "放行", "可以", "建议批准", "不阻止", "无需阻止"
        ]

        if denyPrefixes.contains(where: { hasDecisionPrefix(line, phrase: $0) }) { return .deny }
        if askPrefixes.contains(where: { hasDecisionPrefix(line, phrase: $0) }) { return .ask }
        if allowPrefixes.contains(where: { hasDecisionPrefix(line, phrase: $0) }) { return .allow }
        return outcome(from: line)
    }

    private static func hasDecisionPrefix(_ line: String, phrase: String) -> Bool {
        guard line.hasPrefix(phrase) else { return false }
        guard line.count > phrase.count else { return true }
        let boundary = line.index(line.startIndex, offsetBy: phrase.count)
        let next = line[boundary]
        // Chinese expressions do not have word boundaries. Their phrase list
        // is ordered with negative forms first so "不能批准" never becomes
        // an allow merely because it also contains "批准".
        if phrase.unicodeScalars.contains(where: { $0.value > 127 }) { return true }
        guard let scalar = next.unicodeScalars.first else { return true }
        return next.isWhitespace
            || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    private static func outcome(from raw: String) -> Outcome? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`.,:;!?[](){}")))
            .lowercased()
        switch value {
        case "allow", "allowed", "approve", "approved", "yes", "true", "pass",
             "允许", "批准", "通过", "同意", "放行", "可以":
            return .allow
        case "deny", "denied", "reject", "rejected", "no", "false", "block",
             "拒绝", "禁止", "驳回", "不允许", "阻止":
            return .deny
        case "ask", "review", "human", "escalate", "clarify", "confirm",
             "询问", "人工", "复核", "确认", "升级":
            return .ask
        default:
            return nil
        }
    }

    private static func firstJSONObject(in value: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false
        for index in value.indices {
            let character = value[index]
            if inString {
                if escaping { escaping = false }
                else if character == "\\" { escaping = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start { return String(value[start...index]) }
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

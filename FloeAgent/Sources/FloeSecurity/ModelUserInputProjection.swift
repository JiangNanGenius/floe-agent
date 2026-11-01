import Foundation
import FloeCore

/// Native-authored source identity. Neither tool output nor a provider may
/// manufacture a source by putting a credential placeholder in arbitrary text.
public struct ModelUserInputSource: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}

/// Per-main-run RAM disclosure/redaction state. Canonical messages remain
/// handle-only; only the selected primary request gets a materialized copy.
/// This is not Codable, a vault, an approval or a shared provider adapter.
public final class ModelUserInputProjection: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var texts: [UUID: (safe: String, live: String)] = [:]
    private var secrets: [String: String] = [:] // reference -> exact value
    private static let maximumBytes = 1_048_576

    public init() {}

    public static func questionSourceID(_ id: String) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(Data(("model-input-question:" + id).utf8)).prefix(32))
        return UUID(uuidString: "\(String(hex[0..<8]))-\(String(hex[8..<12]))-\(String(hex[12..<16]))-\(String(hex[16..<20]))-\(String(hex[20..<32]))")!
    }

    public static func credentialIDs(in text: String) -> [UUID] {
        guard let regex = try? NSRegularExpression(pattern: "⟨credential:([0-9A-Fa-f-]{36})⟩") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            return UUID(uuidString: String(text[range]))
        }
    }

    public func register(id: UUID, safe: String, live: String, captures: [CapturedSecret] = []) throws {
        lock.lock(); defer { lock.unlock() }
        guard open else { throw CancellationError() }
        if safe == live, captures.isEmpty { return }
        var next = secrets
        for capture in captures {
            guard let value = String(data: capture.value, encoding: .utf8) else { continue }
            next[capture.placeholder] = value
        }
        let otherBytes = texts.filter { $0.key != id }.values.reduce(0) { $0 + $1.safe.utf8.count + $1.live.utf8.count }
        guard texts.count < 256 || texts[id] != nil,
              next.count <= 1_024,
              otherBytes + safe.utf8.count + live.utf8.count + next.values.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumBytes else {
            throw FloeError.validationFailed("The model input disclosure is too large for this run")
        }
        texts[id] = (safe, live)
        secrets = next
    }

    public func contains(reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return open && secrets[reference] != nil
    }

    /// Hydration is called only after native ownership/origin checks. No
    /// public tool can use this object to read arbitrary vault records.
    public func register(source: ModelUserInputSource, values: [UUID: String]) throws {
        var live = source.text
        let captures = values.map { id, value in CapturedSecret(id: id, label: "User input", value: Data(value.utf8)) }
        lock.lock()
        let current = secrets
        lock.unlock()
        for (reference, value) in current { live = live.replacingOccurrences(of: reference, with: value) }
        for capture in captures {
            live = live.replacingOccurrences(of: capture.placeholder, with: String(decoding: capture.value, as: UTF8.self))
        }
        try register(id: source.id, safe: source.text, live: live, captures: captures)
    }

    public func liveText(for source: ModelUserInputSource) -> String {
        lock.lock(); defer { lock.unlock() }
        guard open, let value = texts[source.id], value.safe == source.text else { return source.text }
        return value.live
    }

    /// Exact known values also cover secrets the model places in shell text,
    /// error messages or an otherwise non-credential JSON key. This is not a
    /// promise to identify every unlabeled secret in arbitrary conversation.
    public func redacted(_ text: String) -> String {
        lock.lock(); let values = secrets; lock.unlock()
        let ordered = values.sorted {
            if $0.value.utf8.count != $1.value.utf8.count { return $0.value.utf8.count > $1.value.utf8.count }
            return $0.key < $1.key
        }
        // Never rewrite an already-safe handle (short passwords can occur in
        // UUIDs). Short known values match tokens, not arbitrary word pieces.
        let protected = (try? NSRegularExpression(pattern: "⟨credential:[0-9A-Fa-f-]{36}⟩"))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        func redactSegment(_ segment: String) -> String {
            let patterns = ordered.filter { !$0.value.isEmpty }.map { item in
                let literal = NSRegularExpression.escapedPattern(for: item.value)
                return item.value.count < 4 ? "(?<![\\p{L}\\p{N}_])(?:" + literal + ")(?![\\p{L}\\p{N}_])" : "(?:" + literal + ")"
            }
            guard !patterns.isEmpty,
                  let expression = try? NSRegularExpression(pattern: patterns.joined(separator: "|")) else { return segment }
            // Match the original segment once. A second replacement pass must
            // never treat text inside a newly inserted handle as a secret.
            var result = segment
            for match in expression.matches(in: segment, range: NSRange(segment.startIndex..., in: segment)).reversed() {
                guard let originalRange = Range(match.range, in: segment),
                      let replacement = ordered.first(where: { $0.value == String(segment[originalRange]) }),
                      let resultRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(resultRange, with: replacement.key)
            }
            return result
        }
        var output = ""
        var cursor = text.startIndex
        for match in protected {
            guard let range = Range(match.range, in: text) else { continue }
            output += redactSegment(String(text[cursor..<range.lowerBound])) + String(text[range])
            cursor = range.upperBound
        }
        return output + redactSegment(String(text[cursor...]))
    }

    public func redactedJSON(_ data: Data, preservingNativeIdentity: Bool = false) -> Data {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Data(redacted(String(decoding: data, as: UTF8.self)).utf8)
        }
        var changed = false
        func scrub(_ value: Any) -> Any {
            if let text = value as? String {
                let safe = redacted(text)
                changed = changed || safe != text
                return safe
            }
            if let items = value as? [Any] { return items.map(scrub) }
            if let items = value as? [String: Any] {
                let identityKeys: Set<String> = ["id", "callID", "runID", "conversationID", "requestID", "questionID", "reference", "sourceID", "trustedSourceID", "toolName"]
                return items.reduce(into: [String: Any]()) { result, item in
                    result[item.key] = preservingNativeIdentity && identityKeys.contains(item.key) ? item.value : scrub(item.value)
                }
            }
            return value
        }
        let safe = scrub(value)
        guard changed else { return data }
        return (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }

    /// Stop new disclosure immediately; keep redaction until in-flight writers
    /// quiesce. The service's terminal cleanup then releases every raw value.
    public func close() { lock.lock(); open = false; texts.removeAll(); lock.unlock() }
    public func clear() { lock.lock(); open = false; texts.removeAll(); secrets.removeAll(); lock.unlock() }
}

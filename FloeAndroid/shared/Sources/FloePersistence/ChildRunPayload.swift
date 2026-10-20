// FloePersistence — bounded, always-valid delegated-child transcript payloads.
//
// The durable child transcript is evidence, not an unbounded dump. Earlier
// writes bounded the RAW encoded JSON string at 8 KiB, which produced invalid
// JSON whenever a single value (CJK text, escaped quotes, long arguments)
// crossed the cap. This codec instead bounds individual FIELD VALUES by
// re-encoding and measuring the real JSON bytes, so every new row is valid
// JSON and the metadata that pairs a tool call with its result (tool name,
// callID, status, digest) is never clipped away.
//
// Historical rows are NOT migrated or rewritten: the store only normalizes
// new writes, and readers fall back to bounded raw text for a row that is not
// valid JSON. A non-object or corrupt payload handed to the store is wrapped
// in a valid JSON object under `legacyRaw` rather than stored as broken JSON.

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// A payload that cannot be represented inside the entry budget without
/// dropping required pairing metadata. The caller must report an incomplete
/// durable record instead of writing a malformed row.
public enum ChildRunPayloadError: Error, Equatable, Sendable, LocalizedError {
    case metadataExceedsBudget(keys: [String], requiredBytes: Int, limit: Int)
    case unencodableObject

    public var errorDescription: String? {
        switch self {
        case .metadataExceedsBudget(let keys, let requiredBytes, let limit):
            return "Child transcript metadata exceeds \(limit) bytes (\(requiredBytes) required: \(keys.joined(separator: ", ")))"
        case .unencodableObject:
            return "Child transcript payload is not encodable as JSON"
        }
    }
}

public enum ChildRunPayload {
    /// 8 KiB per durable transcript entry, measured on the encoded JSON.
    public static let maximumEntryBytes = 8 * 1024
    /// Bounded raw fallback for a historical/corrupt row.
    public static let maximumRawFallbackBytes = 8 * 1024

    static let legacyRawKey = "legacyRaw"
    static let invalidJSONKey = "invalidJSON"
    static let truncatedKey = "truncated"

    /// Bounds a stored payload. Valid JSON that already fits is returned
    /// byte-for-byte (no needless rewrite). A valid but oversized object is
    /// re-encoded field by field. Invalid JSON never reaches the database: it
    /// is preserved as bounded raw text inside a valid wrapper object.
    public static func boundedPayload(
        _ json: String,
        kind: ChildRunEntryKind,
        limit: Int = maximumEntryBytes
    ) throws -> String {
        let data = Data(json.utf8)
        if let parsed = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) {
            if let object = parsed as? [String: Any] {
                if data.count <= limit { return json }
                return try boundedObject(
                    object, requiredKeys: requiredKeys(for: kind), limit: limit
                )
            }
            return try wrappedRaw(json, limit: limit)
        }
        return try wrappedRaw(json, limit: limit)
    }

    /// Bounds a JSON object so its UTF-8 encoding is at most `limit` bytes.
    /// `requiredKeys` are never clipped (callID pairing, tool name, status,
    /// digest). All other string/string-array values are clipped on character
    /// boundaries with a `truncated: true` marker. If the required metadata
    /// itself cannot fit, this throws instead of writing a half-paired row.
    public static func boundedObject(
        _ object: [String: Any],
        requiredKeys: Set<String> = [],
        limit: Int = maximumEntryBytes
    ) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ChildRunPayloadError.unencodableObject
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           data.count <= limit {
            return String(decoding: data, as: UTF8.self)
        }

        let protectedKeys = requiredKeys.intersection(object.keys)
        let stringKeys = orderedClippableKeys(
            object.keys.filter { key in
                !protectedKeys.contains(key) && key != truncatedKey
                    && object[key] is String
            }
        )
        let arrayKeys = orderedClippableKeys(
            object.keys.filter { key in
                !protectedKeys.contains(key) && key != truncatedKey
                    && stringElements(of: object[key]) != nil
            }
        )

        var working = object
        var originalStrings: [String: String] = [:]
        var originalArrays: [String: [String]] = [:]
        for key in stringKeys {
            originalStrings[key] = working[key] as? String
            working[key] = ""
        }
        for key in arrayKeys {
            originalArrays[key] = stringElements(of: working[key])
            working[key] = [String]()
        }
        // The codec OWNS the marker: reserve the final `truncated: true`
        // spelling before measuring, never the caller's shorter `false`/`0`/
        // empty-string value. Otherwise the final marker could push an entry
        // the base measurement said fit over the budget and fail needlessly.
        working[truncatedKey] = true
        let baseBytes = try encodedSize(working)
        guard baseBytes <= limit else {
            throw ChildRunPayloadError.metadataExceedsBudget(
                keys: protectedKeys.union([truncatedKey]).sorted(),
                requiredBytes: baseBytes,
                limit: limit
            )
        }

        // Content fields are filled in a stable priority order: the human
        // readable payload first, supporting arrays afterwards.
        for key in stringKeys {
            guard let original = originalStrings[key] else { continue }
            working[key] = try fittingPrefix(
                of: original,
                limit: limit,
                set: { working[key] = $0 },
                size: { try encodedSize(working) }
            )
        }
        for key in arrayKeys {
            guard let elements = originalArrays[key] else { continue }
            var kept: [String] = []
            for element in elements.prefix(64) {
                let prefix = try fittingPrefix(
                    of: element,
                    limit: limit,
                    set: { working[key] = kept + [$0] },
                    size: { try encodedSize(working) }
                )
                let complete = prefix == element
                if prefix.isEmpty && !element.isEmpty && !complete {
                    break
                }
                kept.append(prefix)
                if !complete { break }
            }
            working[key] = kept
        }

        working[truncatedKey] = true
        let finalData: Data
        do {
            finalData = try JSONSerialization.data(
                withJSONObject: working, options: [.sortedKeys]
            )
        } catch {
            throw ChildRunPayloadError.unencodableObject
        }
        guard finalData.count <= limit else {
            throw ChildRunPayloadError.metadataExceedsBudget(
                keys: protectedKeys.union([truncatedKey]).sorted(),
                requiredBytes: finalData.count,
                limit: limit
            )
        }
        return String(decoding: finalData, as: UTF8.self)
    }

    /// Tolerant reader used by presentation projections. Returns nil for a
    /// row that is not a JSON object (a historical truncated row is handled
    /// by `rawFallbackText` instead).
    public static func decodedObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              ) else { return nil }
        return parsed as? [String: Any]
    }

    /// Typed-compatible presentation fields. The old reader decoded only
    /// `[String: String]`, so an intact result with Int/Bool/[String] values
    /// decoded to `[:]`. Mixed values are normalized here instead: booleans
    /// stay "true"/"false", numbers keep their textual form and string arrays
    /// are joined one item per line for the existing bounded evidence view.
    public static func decodedStringFields(_ json: String) -> [String: String] {
        guard let object = decodedObject(json) else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in object {
            fields[key] = presentationString(value)
        }
        return fields
    }

    /// Bounded raw text for a historical/corrupt row, preferring the
    /// normalized `legacyRaw` wrapper value when present.
    public static func rawFallbackText(_ json: String) -> String {
        if let object = decodedObject(json),
           let legacy = object[legacyRawKey] as? String {
            return clipRawText(legacy)
        }
        return clipRawText(json)
    }

    /// True when the row must be rendered as bounded raw evidence instead of
    /// a structured entry: either the original JSON is unreadable, or it is
    /// the store's valid `{legacyRaw, invalidJSON:true}` wrapper. Without this
    /// distinction a normalized old row would render as an empty tool card and
    /// hide the preserved text.
    public static func requiresRawFallback(_ json: String) -> Bool {
        guard let object = decodedObject(json) else { return true }
        guard let invalid = object[invalidJSONKey] else { return false }
        return isJSONBool(invalid) && (invalid as? Bool) == true
    }

    // MARK: - Key policy

    /// Pairing/identity fields that must survive the budget. `truncated` is
    /// reserved by the encoder; non-string values are never clipped.
    static func requiredKeys(for kind: ChildRunEntryKind) -> Set<String> {
        switch kind {
        case .message:
            return ["role"]
        case .toolRequest:
            return ["tool", "callID"]
        case .toolResult:
            return ["tool", "callID", "status", "digest"]
        case .result:
            return ["status"]
        case .error:
            return []
        case .state:
            return ["state"]
        }
    }

    // MARK: - Encoding helpers

    private static func wrappedRaw(_ raw: String, limit: Int) throws -> String {
        try boundedObject(
            [
                legacyRawKey: raw,
                invalidJSONKey: true,
                truncatedKey: true,
            ],
            requiredKeys: [invalidJSONKey],
            limit: limit
        )
    }

    private static func orderedClippableKeys(_ keys: [String]) -> [String] {
        keys.sorted { lhs, rhs in
            let left = priority(lhs)
            let right = priority(rhs)
            return left == right ? lhs < rhs : left < right
        }
    }

    private static func priority(_ key: String) -> Int {
        switch key {
        case "findings": 0
        case "text": 1
        case "output": 2
        case "arguments": 3
        case "message": 4
        case "evidence": 5
        case "unfinished": 6
        case legacyRawKey: 7
        default: 8
        }
    }

    private static func stringElements(of value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        var elements: [String] = []
        elements.reserveCapacity(array.count)
        for element in array {
            guard let string = element as? String else { return nil }
            elements.append(string)
        }
        return elements
    }

    /// Largest CHARACTER prefix of `value` whose inclusion keeps the encoded
    /// object within `limit`. Character boundaries keep the stored value valid
    /// Unicode while the measured unit stays the real JSON-escaped byte count.
    private static func fittingPrefix(
        of value: String,
        limit: Int,
        set: (String) -> Void,
        size: () throws -> Int
    ) throws -> String {
        let characters = Array(value)
        var low = 0
        var high = characters.count
        var best = ""
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(characters.prefix(middle))
            set(candidate)
            if try size() <= limit {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        set(best)
        return best
    }

    private static func encodedSize(_ object: [String: Any]) throws -> Int {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ChildRunPayloadError.unencodableObject
        }
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ).count
    }

    private static func clipRawText(
        _ text: String,
        limit: Int = maximumRawFallbackBytes
    ) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        let marker = "\n[truncated: original \(bytes.count) bytes]"
        let keep = max(0, limit - marker.utf8.count)
        return String(decoding: bytes.prefix(keep), as: UTF8.self) + marker
    }

    // MARK: - Presentation conversion

    private static func presentationString(_ value: Any) -> String {
        if let string = value as? String { return string }
        if isJSONBool(value) {
            return (value as? Bool) == true ? "true" : "false"
        }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "" }
        if let array = value as? [Any] {
            return array.map(stringElement).joined(separator: "\n")
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    private static func stringElement(_ value: Any) -> String {
        if let string = value as? String { return string }
        if isJSONBool(value) {
            return (value as? Bool) == true ? "true" : "false"
        }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    private static func isJSONBool(_ value: Any) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
        #else
        return value is Bool
        #endif
    }
}

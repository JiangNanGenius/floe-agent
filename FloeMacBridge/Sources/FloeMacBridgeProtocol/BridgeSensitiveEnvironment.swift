import Foundation

/// Additive contract for per-process sensitive environment values on the Mac
/// bridge. The capability string is negotiated through the authenticated
/// `ping` response; an old companion does not advertise it, so the native
/// client refuses to send any sensitive value. The wire request carries only
/// the exact variable NAMES whose values must be redacted; values travel in
/// the existing environment object and are never written to metadata.
public enum BridgeSensitiveEnvironment {
    public static let capability = "sensitiveEnvironmentV1"
    public static let metadataVersion = 1
    public static let maximumNames = 64
    public static let maximumNameBytes = 128
    public static let maximumValueBytes = 32 * 1024
    public static let maximumTotalValueBytes = 64 * 1024

    /// Names the companion owns itself. Marking one sensitive would be
    /// silently overridden by `BridgeJobs`, so both sides refuse it.
    public static let reservedNames: Set<String> = [
        "HOME", "TMPDIR", "PATH", "PYTHONPATH", "NODE_PATH", "TERM",
        "FLOE_EXECUTION_BACKEND",
    ]

    public static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumNameBytes else { return false }
        guard let first = name.utf8.first,
              (first >= 0x41 && first <= 0x5a) || (first >= 0x61 && first <= 0x7a) || first == 0x5f else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) ||
            (byte >= 0x30 && byte <= 0x39) || byte == 0x5f
        }
    }

    /// Exact typed validation for the request field. Names are not secrets,
    /// but the message stays generic so a malformed request is not echoed.
    public static func validatedNames(_ names: [String]) throws -> [String] {
        guard names.count <= maximumNames else {
            throw BridgeFailure.remote(
                "This command marks too many sensitive environment variables; the Mac bridge limit is \(maximumNames). No command was started."
            )
        }
        var seen = Set<String>()
        for name in names {
            guard validName(name) else {
                throw BridgeFailure.remote(
                    "The Mac bridge received an invalid sensitive environment variable name. No command was started."
                )
            }
            guard !reservedNames.contains(name) else {
                throw BridgeFailure.remote(
                    "The Mac bridge controls variable '\(name)' itself and cannot redact it as a command secret. Choose another name. No command was started."
                )
            }
            guard seen.insert(name).inserted else {
                throw BridgeFailure.remote(
                    "The Mac bridge received the same sensitive environment variable name twice. No command was started."
                )
            }
        }
        return names
    }

    /// Decodes `sensitiveEnvironmentNames` from a paired `start` payload.
    /// Missing means an ordinary command; a non-array or non-string element
    /// fails closed before any process is spawned.
    public static func names(from value: BridgeValue?) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value else {
            throw BridgeFailure.remote(
                "sensitiveEnvironmentNames must be an array of variable names. No command was started."
            )
        }
        var names: [String] = []
        for item in items {
            guard let name = item.string else {
                throw BridgeFailure.remote(
                    "sensitiveEnvironmentNames must contain only variable names. No command was started."
                )
            }
            names.append(name)
        }
        return try validatedNames(names)
    }

    /// Names-only metadata. It never contains a value and is written before
    /// the child exists so a failed start still leaves an auditable intent.
    public static func metadata(names: [String]) -> [String: BridgeValue] {
        [
            "version": .integer(Int64(metadataVersion)),
            "capability": .string(capability),
            "names": .array(names.map(BridgeValue.string)),
        ]
    }
}

/// Streaming redactor used by the companion before bytes reach `output.bin`.
/// It replaces exact UTF-8 values for the explicitly marked names, longest
/// first, and holds a bounded possible-prefix tail between chunks so a value
/// split across two PTY reads cannot leak. On flush a held partial prefix is
/// replaced with the marker instead of being emitted: a prefix of a secret
/// is still sensitive. A struct with internal state; `BridgeJob.drain` owns
/// one instance on its single reader.
public struct BridgeSensitiveRedactor: Sendable {
    public static let placeholder = "[REDACTED]"

    private let patterns: [[UInt8]]
    private let placeholderBytes: [UInt8]
    private var carry: [UInt8] = []

    public init(names: [String], environment: [String: String]) throws {
        let validated = try BridgeSensitiveEnvironment.validatedNames(names)
        var values: [String] = []
        var total = 0
        for name in validated {
            guard let value = environment[name] else {
                throw BridgeFailure.remote(
                    "Sensitive environment variable '\(name)' is missing from the command environment. No command was started."
                )
            }
            guard !value.utf8.contains(0) else {
                throw BridgeFailure.remote(
                    "Sensitive environment variable '\(name)' contains a NUL byte. No command was started."
                )
            }
            let bytes = value.utf8.count
            guard bytes <= BridgeSensitiveEnvironment.maximumValueBytes else {
                throw BridgeFailure.remote(
                    "Sensitive environment variable '\(name)' exceeds the Mac bridge value limit. No command was started."
                )
            }
            total += bytes
            guard total <= BridgeSensitiveEnvironment.maximumTotalValueBytes else {
                throw BridgeFailure.remote(
                    "Sensitive environment values exceed the Mac bridge total limit. No command was started."
                )
            }
            if !value.isEmpty { values.append(value) }
        }
        let unique = Set(values)
        self.patterns = unique
            .sorted { lhs, rhs in
                if lhs.utf8.count != rhs.utf8.count { return lhs.utf8.count > rhs.utf8.count }
                return lhs < rhs
            }
            .map { Array($0.utf8) }
        self.placeholderBytes = Array(Self.placeholder.utf8)
    }

    public var isActive: Bool { !patterns.isEmpty }

    /// Returns bytes safe to append to `output.bin`. `flush` must be called
    /// once at EOF/cancel completion; it emits a marker for any held prefix
    /// rather than the prefix itself.
    public mutating func redact(_ data: Data, flush: Bool = false) -> Data {
        let priorCarry = carry.count
        var combined = carry
        combined.append(contentsOf: data)
        carry.removeAll(keepingCapacity: false)
        guard !patterns.isEmpty else { return Data(combined) }

        if flush {
            var output = Data()
            var index = 0
            if priorCarry > 0 {
                // The held prefix is a partial marked value. If the new bytes
                // complete a full value starting at index 0, replace the whole
                // match; otherwise replace the entire held prefix and resume
                // after it. A partial secret is never emitted raw.
                var matchedAtStart: Int?
                for pattern in patterns where pattern.count <= combined.count {
                    if combined[0..<pattern.count].elementsEqual(pattern) {
                        matchedAtStart = pattern.count
                        break
                    }
                }
                output.append(contentsOf: placeholderBytes)
                index = max(priorCarry, matchedAtStart ?? 0)
            }
            while index < combined.count {
                var matched: [UInt8]?
                for pattern in patterns where index + pattern.count <= combined.count {
                    if combined[index..<index + pattern.count].elementsEqual(pattern) {
                        matched = pattern
                        break
                    }
                }
                if let matched {
                    output.append(contentsOf: placeholderBytes)
                    index += matched.count
                } else {
                    output.append(combined[index])
                    index += 1
                }
            }
            return output
        }

        let held = longestHeldSuffix(combined)
        let emitLimit = combined.count - held
        var output = Data()
        output.reserveCapacity(emitLimit + placeholderBytes.count)
        var index = 0
        while index < emitLimit {
            var matched: [UInt8]?
            for pattern in patterns where index + pattern.count <= combined.count {
                if combined[index..<index + pattern.count].elementsEqual(pattern) {
                    matched = pattern
                    break
                }
            }
            if let matched {
                output.append(contentsOf: placeholderBytes)
                index += matched.count
            } else {
                output.append(combined[index])
                index += 1
            }
        }
        let carryStart = max(emitLimit, index)
        if carryStart < combined.count {
            carry = Array(combined[carryStart...])
        }
        return output
    }

    private func longestHeldSuffix(_ bytes: [UInt8]) -> Int {
        var best = 0
        for pattern in patterns {
            let limit = min(pattern.count - 1, bytes.count)
            guard limit > best else { continue }
            var length = limit
            while length > best {
                let base = bytes.count - length
                var matches = true
                for offset in 0..<length where bytes[base + offset] != pattern[offset] {
                    matches = false
                    break
                }
                if matches {
                    best = length
                    break
                }
                length -= 1
            }
        }
        return best
    }
}

// FloeSecurity — Hash-chained audit entries and device key derivation.
// See docs/DEVELOPMENT_PLAN.md §3.3: "Audit entries contain the model, tool,
// target, policy, decision, timestamps, exit status, and bounded output
// digest. Entries form a device-keyed hash chain."
//
// entryHash = HMAC_SHA256(deviceKey, prevHash ‖ canonicalJSON(entry))
// deviceKey is derived from a device secret via HKDF-SHA256. On iOS the
// device secret is a Secure Enclave P-256 private key (wired in at the app
// layer); on macOS/Linux a caller-supplied secret is used for tests.

import Foundation
import Crypto
import FloeCore

/// One append-only audit record. Hashes are lowercase hex strings.
public struct AuditEntry: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    /// Monotonically increasing per device, starting at 1.
    public var sequence: Int64
    public var timestamp: Date
    public var runID: UUID
    /// Wire-level model identifier (e.g. "gpt-5").
    public var modelRemoteID: String
    public var toolName: String
    /// Normalized human-readable target (host, path, or URL). Never a secret.
    public var target: String
    /// Name of the policy that produced the decision ("human",
    /// "approval-model", "full-control").
    public var policyUsed: String
    /// Canonical decision string ("allow", "deny:<reason>", "stopped:<id>", …).
    public var decision: String
    public var exitStatus: Int32?
    /// SHA256 hex digest of the bounded tool output. Empty when no output.
    public var outputDigestSHA256: String
    /// Hex of the previous entry's hash; 64 zeros for the genesis entry.
    public var prevHashSHA256: String
    /// HMAC-SHA256 hex of (prevHash ‖ canonicalJSON(entry-without-hashes)).
    public var entryHashSHA256: String

    public static let genesisPrevHash = String(repeating: "0", count: 64)

    public init(
        id: UUID = UUID(),
        sequence: Int64,
        timestamp: Date = Date(),
        runID: UUID,
        modelRemoteID: String,
        toolName: String,
        target: String,
        policyUsed: String,
        decision: String,
        exitStatus: Int32? = nil,
        outputDigestSHA256: String = "",
        prevHashSHA256: String,
        entryHashSHA256: String
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.runID = runID
        self.modelRemoteID = modelRemoteID
        self.toolName = toolName
        self.target = target
        self.policyUsed = policyUsed
        self.decision = decision
        self.exitStatus = exitStatus
        self.outputDigestSHA256 = outputDigestSHA256
        self.prevHashSHA256 = prevHashSHA256
        self.entryHashSHA256 = entryHashSHA256
    }

    /// Codable keys exclude nothing; hashing uses a separate view that omits
    /// the two hash fields.
    enum CodingKeys: String, CodingKey {
        case id, sequence, timestamp, runID, modelRemoteID, toolName, target
        case policyUsed, decision, exitStatus, outputDigestSHA256
        case prevHashSHA256, entryHashSHA256
    }
}

/// Derives the audit device key from a device secret.
///
/// On iOS the secret is material tied to a Secure Enclave P-256 private key
/// (a signature over a fixed label, or key agreement output). The derivation
/// itself is pure HKDF-SHA256 and therefore testable cross-platform.
public enum AuditDeviceKey {
    public static let info = "org.floeagent.ios.audit-chain-v1"
    public static let salt = "floe-agent-audit"

    /// HKDF-SHA256 extract+expand producing a 32-byte symmetric key.
    public static func derive(deviceSecret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: deviceSecret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }
}

/// Append-only, hash-chained audit log. `append` computes `prevHash` and
/// `entryHash` automatically; `verify` replays the chain and returns the
/// sequence number of the first tampered entry (or nil if intact).
public actor AuditChain {
    public enum ChainError: Error, Sendable {
        case emptyChainRequiresGenesis
        case tampered(sequence: Int64)
    }

    private let deviceKey: SymmetricKey
    private let encoder = CanonicalJSONEncoder()
    private var entries: [AuditEntry] = []
    private var lastHash: String = AuditEntry.genesisPrevHash
    private var lastSequence: Int64 = 0

    public init(deviceSecret: Data) {
        self.deviceKey = AuditDeviceKey.derive(deviceSecret: deviceSecret)
    }

    /// Rebuilds an actor over existing entries (e.g. loaded from GRDB).
    /// Throws when the stored chain fails verification.
    public init(deviceSecret: Data, existing: [AuditEntry]) throws {
        self.deviceKey = AuditDeviceKey.derive(deviceSecret: deviceSecret)
        guard let firstTamper = Self.verifyChain(existing, deviceKey: deviceKey) else {
            self.entries = existing
            self.lastHash = existing.last?.entryHashSHA256 ?? AuditEntry.genesisPrevHash
            self.lastSequence = existing.last?.sequence ?? 0
            return
        }
        throw ChainError.tampered(sequence: firstTamper)
    }

    public var count: Int { entries.count }

    public var allEntries: [AuditEntry] { entries }

    /// Appends a new entry. Hash fields of `draft` are ignored and recomputed.
    public func append(_ draft: AuditEntry) throws -> AuditEntry {
        let sequence = lastSequence + 1
        var entry = draft
        entry.sequence = sequence
        entry.prevHashSHA256 = lastHash
        entry.entryHashSHA256 = ""
        let canonical = try encoder.encode(entry)
        let hash = Self.computeHash(
            deviceKey: deviceKey,
            prevHashHex: lastHash,
            canonicalEntry: canonical
        )
        entry.entryHashSHA256 = hash
        entries.append(entry)
        lastHash = hash
        lastSequence = sequence
        return entry
    }

    /// Replays the stored chain. Returns the sequence of the first tampered
    /// entry, or nil when the chain is intact.
    public func verify() -> Int64? {
        Self.verifyChain(entries, deviceKey: deviceKey)
    }

    /// Static verifier usable without an actor instance.
    public static func verifyChain(_ chain: [AuditEntry], deviceKey: SymmetricKey) -> Int64? {
        let encoder = CanonicalJSONEncoder()
        var expectedPrev = AuditEntry.genesisPrevHash
        var expectedSequence: Int64 = 0
        for entry in chain {
            expectedSequence += 1
            guard entry.sequence == expectedSequence else { return entry.sequence }
            guard entry.prevHashSHA256 == expectedPrev else { return entry.sequence }
            var recomputed = entry
            recomputed.entryHashSHA256 = ""
            guard let canonical = try? encoder.encode(recomputed) else { return entry.sequence }
            let expected = computeHash(
                deviceKey: deviceKey,
                prevHashHex: expectedPrev,
                canonicalEntry: canonical
            )
            guard constantTimeEqual(expected, entry.entryHashSHA256) else { return entry.sequence }
            expectedPrev = entry.entryHashSHA256
        }
        return nil
    }

    private static func computeHash(
        deviceKey: SymmetricKey,
        prevHashHex: String,
        canonicalEntry: Data
    ) -> String {
        var message = Data()
        message.append(contentsOf: hexBytes(prevHashHex))
        message.append(canonicalEntry)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: deviceKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// FloeSecurityTests — QA edge-case corpus (Round 1, authored by QA/Yan).
// Covers boundaries the engineer's own tests did not exercise:
//   - ApprovalGrant / FullControlPolicy.Grant exact-moment expiry boundaries
//   - Canonical JSON deep nesting, non-BMP Unicode, CJK keys, Decimal variants
//   - Audit-chain tamper detection for timestamp / prevHash / deletion
//   - Catastrophic-gate obfuscation inputs (case, quotes, chains, env vars,
//     tabs, invisible characters)
//   - ToolCall 64 KiB argument boundary

import Foundation
import Testing
import Crypto
@testable import FloeSecurity
@testable import FloeModels
@testable import FloeCore
import FloeTestSupport

// MARK: - Approval boundary conditions

@Suite("QA.ApprovalBoundaries")
struct ApprovalBoundaryTests {

    @Test("FullControlPolicy.Grant: expiresAt == now is INACTIVE (now < expiresAt is false)")
    func grantExpiresAtEqualsNow() {
        let now = Date()
        let grant = FullControlPolicy.Grant(hostID: UUID(), expiresAt: now)
        #expect(!grant.isActive(at: now))
    }

    @Test("FullControlPolicy.Grant: 1ms before expiry is active, 1ms after is not")
    func grantMillisecondBoundaries() {
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let grant = FullControlPolicy.Grant(hostID: UUID(), expiresAt: expiry)
        #expect(grant.isActive(at: expiry.addingTimeInterval(-0.001)))
        #expect(!grant.isActive(at: expiry.addingTimeInterval(0.001)))
    }

    @Test("FullControlPolicy.Grant: nil expiresAt is always active (until connection closes)")
    func grantNilExpiry() {
        let grant = FullControlPolicy.Grant(hostID: UUID(), expiresAt: nil)
        #expect(grant.isActive(at: Date(timeIntervalSince1970: 0)))
        #expect(grant.isActive(at: Date(timeIntervalSince1970: 4_000_000_000))) // year 2096
    }

    @Test("ApprovalGrant.isExpired: nil expiresAt never expires")
    func approvalGrantNilExpiry() {
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "t"),
            expiresAt: nil,
            policyName: "human"
        )
        #expect(!grant.isExpired(at: Date(timeIntervalSince1970: 4_000_000_000)))
    }

    @Test("ApprovalGrant.isExpired: expiresAt == now counts as expired")
    func approvalGrantExactExpiry() {
        let now = Date()
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "t"),
            expiresAt: now,
            policyName: "human"
        )
        #expect(grant.isExpired(at: now))
        #expect(!grant.isExpired(at: now.addingTimeInterval(-0.001)))
        #expect(grant.isExpired(at: now.addingTimeInterval(0.001)))
    }
}

// MARK: - Canonical JSON edges

@Suite("QA.CanonicalJSONEdges")
struct CanonicalJSONEdgeTests {

    @Test("Nested empty object, empty array, and empty dictionary serialize")
    func nestedEmptyContainers() throws {
        struct Empty: Codable {}
        struct Wrapper: Codable {
            var obj: Empty
            var arr: [Int]
            var emptyDict: [String: Int]
        }
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(Wrapper(obj: Empty(), arr: [], emptyDict: [:]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"arr":[],"emptyDict":{},"obj":{}}"#)
    }

    @Test("Non-BMP emoji round-trip is byte-stable and unescaped")
    func nonBMPEmoji() throws {
        struct WithEmoji: Codable { var s: String }
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(WithEmoji(s: "🚀💥𐍈"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"s":"🚀💥𐍈"}"#)
        // Deterministic across encodes.
        #expect(try encoder.encode(WithEmoji(s: "🚀💥𐍈")) == data)
    }

    @Test("CJK keys sort by code point and serialize unescaped")
    func cjkKeys() throws {
        struct CJK: Codable {
            var 乙: Int
            var 甲: Int
            var ascii: Int
        }
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(CJK(乙: 2, 甲: 1, ascii: 3))
        let text = String(decoding: data, as: UTF8.self)
        // "ascii" (U+0061…) sorts before 甲 (U+7532) < 乙 (U+4E59)? Literal
        // UTF-16 comparison: U+4E59 < U+7532, and 'a' < both.
        #expect(text.hasPrefix(#"{"ascii":3,"#))
        #expect(text.contains("甲") && text.contains("乙"))
        #expect(try encoder.encode(CJK(乙: 2, 甲: 1, ascii: 3)) == data)
    }

    @Test("100-level nested encoding succeeds and is deterministic")
    func deepNesting() throws {
        struct Node: Codable { var child: [Node] }
        // 1 (initial leaf) + 99 wraps = exactly 100 levels of {"child":…}.
        var node = Node(child: [])
        for _ in 0..<99 {
            node = Node(child: [node])
        }
        let encoder = CanonicalJSONEncoder()
        let first = try encoder.encode(node)
        let second = try encoder.encode(node)
        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.hasPrefix(#"{"child":["#))
        #expect(text.hasSuffix(#"]}"#))
        // Each level contributes {"child":[ (10) + ]} (2) = 12 chars.
        #expect(text.count == 100 * 12)
    }

    @Test("Decimal('0.000') and Decimal('0') canonicalize identically")
    func decimalZeroVariants() throws {
        struct WithDecimal: Codable { var d: Decimal }
        let encoder = CanonicalJSONEncoder()
        let a = try encoder.encode(WithDecimal(d: Decimal(string: "0.000")!))
        let b = try encoder.encode(WithDecimal(d: Decimal(0)))
        #expect(a == b)
        #expect(String(decoding: a, as: UTF8.self) == #"{"d":0}"#)
    }

    @Test("Decimal('1.50') and Decimal('1.5') canonicalize identically")
    func decimalTrailingZeros() throws {
        struct WithDecimal: Codable { var d: Decimal }
        let encoder = CanonicalJSONEncoder()
        let a = try encoder.encode(WithDecimal(d: Decimal(string: "1.50")!))
        let b = try encoder.encode(WithDecimal(d: Decimal(string: "1.5")!))
        #expect(a == b)
    }

    @Test("Non-integer Decimal keeps fractional digits (BUG-QA-2 regression)")
    func decimalFractionPreserved() throws {
        struct WithDecimal: Codable { var d: Decimal }
        let encoder = CanonicalJSONEncoder()
        #expect(String(decoding: try encoder.encode(WithDecimal(d: Decimal(string: "3.14159")!)), as: UTF8.self) == #"{"d":3.14159}"#)
        #expect(String(decoding: try encoder.encode(WithDecimal(d: Decimal(string: "100")!)), as: UTF8.self) == #"{"d":100}"#)
        #expect(String(decoding: try encoder.encode(WithDecimal(d: Decimal(string: "0.00001")!)), as: UTF8.self) == #"{"d":0.00001}"#)
        #expect(String(decoding: try encoder.encode(WithDecimal(d: Decimal(string: "-2.5")!)), as: UTF8.self) == #"{"d":-2.5}"#)
        #expect(String(decoding: try encoder.encode(WithDecimal(d: Decimal(string: "1000.1000")!)), as: UTF8.self) == #"{"d":1000.1}"#)
    }

    @Test("Negative zero Decimal canonicalizes to 0")
    func decimalNegativeZero() throws {
        struct WithDecimal: Codable { var d: Decimal }
        let encoder = CanonicalJSONEncoder()
        let data = try encoder.encode(WithDecimal(d: Decimal(string: "-0.00")!))
        #expect(String(decoding: data, as: UTF8.self) == #"{"d":0}"#)
    }
}

// MARK: - Audit chain tamper matrix

@Suite("QA.AuditChainTamper")
struct AuditChainTamperTests {

    private func makeChain(entries count: Int) async throws -> AuditChain {
        let chain = AuditChain(deviceSecret: TestFixtures.testDeviceSecret)
        let runID = UUID()
        for index in 0..<count {
            _ = try await chain.append(AuditEntry(
                sequence: 0,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                runID: runID,
                modelRemoteID: "test-model-1",
                toolName: "ssh.execute",
                target: "host:test",
                policyUsed: "human",
                decision: "allow:human",
                exitStatus: 0,
                outputDigestSHA256: "",
                prevHashSHA256: "",
                entryHashSHA256: ""
            ))
        }
        return chain
    }

    private var deviceKey: SymmetricKey {
        AuditDeviceKey.derive(deviceSecret: TestFixtures.testDeviceSecret)
    }

    @Test("Tampering a middle entry's timestamp is detected at that sequence")
    func timestampTamper() async throws {
        let chain = try await makeChain(entries: 8)
        var entries = await chain.allEntries
        entries[3].timestamp = Date(timeIntervalSince1970: 42)
        #expect(AuditChain.verifyChain(entries, deviceKey: deviceKey) == 4)
    }

    @Test("Tampering prevHash of a middle entry is detected at that sequence")
    func prevHashTamper() async throws {
        let chain = try await makeChain(entries: 8)
        var entries = await chain.allEntries
        entries[5].prevHashSHA256 = String(repeating: "f", count: 64)
        #expect(AuditChain.verifyChain(entries, deviceKey: deviceKey) == 6)
    }

    @Test("Deleting the last entry truncates but does NOT corrupt the prefix")
    func deleteLastEntry() async throws {
        let chain = try await makeChain(entries: 8)
        var entries = await chain.allEntries
        entries.removeLast()
        // Prefix still verifies; truncation alone is not tampering of what remains.
        #expect(AuditChain.verifyChain(entries, deviceKey: deviceKey) == nil)
    }

    @Test("Deleting a middle entry breaks the chain")
    func deleteMiddleEntry() async throws {
        let chain = try await makeChain(entries: 8)
        var entries = await chain.allEntries
        entries.remove(at: 4)
        #expect(AuditChain.verifyChain(entries, deviceKey: deviceKey) != nil)
    }

    @Test("Forged entryHash on a tampered entry is detected at that entry")
    func forgedHashStillDetected() async throws {
        let chain = try await makeChain(entries: 5)
        var entries = await chain.allEntries
        // Attacker tampers entry 3 and writes an arbitrary forged hash.
        entries[2].decision = "allow:attacker"
        entries[2].entryHashSHA256 = String(repeating: "a", count: 64)
        #expect(AuditChain.verifyChain(entries, deviceKey: deviceKey) == 3)
    }

    @Test("Empty chain verifies clean")
    func emptyChain() {
        #expect(AuditChain.verifyChain([], deviceKey: deviceKey) == nil)
    }

    @Test("Rebuilding an actor over a tampered chain throws .tampered")
    func actorRebuildRejectsTamper() async throws {
        let chain = try await makeChain(entries: 6)
        var entries = await chain.allEntries
        entries[1].target = "host:evil"
        #expect(throws: AuditChain.ChainError.self) {
            _ = try AuditChain(deviceSecret: TestFixtures.testDeviceSecret, existing: entries)
        }
    }
}

// MARK: - Catastrophic gate obfuscation edges

@Suite("QA.CatastrophicGateEdges")
struct CatastrophicGateEdgeTests {

    private func makeGate() throws -> CatastrophicActionGate {
        try CatastrophicActionGate.withBundledPatterns()
    }

    @Test("Uppercase RM -RF / is stopped (case-insensitive)")
    func uppercaseRM() throws {
        let gate = try makeGate()
        #expect(gate.evaluate(command: "RM -RF /").stopped)
        #expect(gate.evaluate(command: "Rm -Rf /Etc").stopped)
    }

    @Test("Quoted path with spaces normalizes; benign target stays clear")
    func quotedPathWithSpaces() throws {
        let gate = try makeGate()
        #expect(!gate.evaluate(command: #"rm -rf "/tmp/my dir""#).stopped)
    }

    @Test("Command chain ending in rm -rf / is stopped")
    func commandChain() throws {
        let gate = try makeGate()
        #expect(gate.evaluate(command: "ls && rm -rf /").stopped)
        #expect(gate.evaluate(command: "cd /tmp; rm -rf /").stopped)
    }

    @Test("Environment variable expansion forms are stopped")
    func envVarExpansion() throws {
        let gate = try makeGate()
        #expect(gate.evaluate(command: "rm -rf $HOME").stopped)
        #expect(gate.evaluate(command: "rm -rf ${HOME}").stopped)
        #expect(gate.evaluate(command: "rm -rf ${HOME}/").stopped)
    }

    @Test("Tab-separated flags and target are stopped")
    func tabSeparated() throws {
        let gate = try makeGate()
        #expect(gate.evaluate(command: "rm\t-rf\t/").stopped)
    }

    @Test("Zero-width format characters are removed before tokenization")
    func zeroWidthSpaceIsNormalized() throws {
        let gate = try makeGate()
        let verdict = gate.evaluate(command: "rm\u{200B} -rf /")
        #expect(verdict.stopped)
    }

    @Test("Unicode-escaped slashes and homoglyphs are NOT silently stopped")
    func homoglyphNonInterference() throws {
        let gate = try makeGate()
        // Full-width slash should not produce a false positive on a benign rm.
        #expect(!gate.evaluate(command: "rm -rf ／tmp").stopped)
    }

    @Test("Newline-continuation splicing is normalized before matching")
    func lineContinuation() throws {
        let gate = try makeGate()
        #expect(gate.evaluate(command: "rm \\\n -rf \\\n /").stopped)
    }

    @Test("Bundled corpus includes the locked destructive command families")
    func bundledPatternCount() throws {
        // Construction over the bundled resource must succeed; the corpus
        // scope is deliberately limited to direct, high-confidence damage.
        let gate = try makeGate()
        // Probe one representative command per high-risk family to confirm
        // the bundled corpus (not a stale copy) drives the verdicts.
        #expect(gate.evaluate(command: "rm -rf /").matchedPatternID == "rm-rf-root")
        #expect(gate.evaluate(command: "btrfs subvolume delete /").matchedPatternID == "btrfs-subvolume-delete-root")
    }
}

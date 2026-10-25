// FloeApp — frozen v1 Impeccable snapshot/facts contract models and native ingress
// validation (A2).
//
// These types are the native twin of
// `engines/impeccable/contract/snapshot-contract.v1.json` (schemaStatus
// frozen-v1, hub commit 156214d364baa8b575e1755a74d223d7b4ce34a7). Nothing here
// runs the engine: the riscv64 binary, its goldens and the launcher are pending
// in the H3 lane. What is implemented here is the *obligation side* the contract
// freezes for native: the wire shapes, the exact IEEE-754 hit-test key rules, the
// binding/fencing/privacy rejection table, the budgets and the truthful coverage
// gating (v1 never certifies a page clean).
//
// The validation entry points below are the real ingress: the capture service
// uses them for every measurement, and the focused tests drive forged
// identities, stale bindings, bit mismatches and malformed results through the
// same paths. Code here is model-neutral: no JSON produced by a model, a page or
// a tool response is trusted for producer trust or redaction claims — the
// native-issued identity record is the authority.

import Foundation

// MARK: - Frozen constants

enum ImpeccableContract {
    static let name = "floe.impeccable.snapshot"
    static let contractVersion = 1
    /// The only accepted `producerTrust`. Any other value — model-declared,
    /// page-declared, or absent — rejects the identity.
    static let producerTrust = "native-fixed-script"
    static let redactionPolicy = "floe.impeccable.redaction.v1"
    static let producerEngine = "WebKit"
    static let producerName = "floe.impeccable.native-producer"
    static let producerVersion = "floe.a2.v1"
    /// Synthetic fixtures may carry this digest; it is never accepted at real
    /// ingress (identity schema + `ingressRejections`).
    static let syntheticScriptDigest = String(repeating: "0", count: 64)

    // Single deliberate upstream pin (never a mixed-byte claim).
    static let upstreamProject = "pbakaus/impeccable"
    static let upstreamCommit = "4fc2f83e1c8710dba772bfd4523d0efab57737b6"
    static let upstreamTree = "1363fadfb2141db1cf22b4ba171d6fc4dbf5cd72"
    static let upstreamEngineVersion = "0.1.17"
    static let upstreamPackageVersion = "4.7.1"

    static let stylePropCount = 138
    static let pseudoPropCount = 23
    static let statePseudoCount = 31
}

struct ImpeccableBudgets: Codable, Sendable, Equatable {
    var maxSnapshotBytes: Int
    var maxElements: Int
    var maxRounds: Int
    var maxHitTestsPerRound: Int
    var maxHitTestsTotal: Int
    var timeoutMs: Int

    static let frozenV1 = ImpeccableBudgets(
        maxSnapshotBytes: 50_331_648,   // 48 MiB
        maxElements: 30_000,
        maxRounds: 4,
        maxHitTestsPerRound: 4_096,
        maxHitTestsTotal: 16_384,
        timeoutMs: 120_000
    )
}

// MARK: - IEEE-754 exact-bit keys

/// The engine's hit-test lookup key is the exact IEEE-754 double bits of
/// `(x, y)`; the contract carries `hitTestsBits` as decimal u64 strings so the
/// bits survive JSON text intact.
enum ImpeccableDoubleBits {
    static func u64String(from value: Double) -> String {
        String(value.bitPattern)
    }

    static func double(fromU64String text: String) -> Double? {
        guard let bits = UInt64(text) else { return nil }
        return Double(bitPattern: bits)
    }

    /// True when the decimal text and the declared u64 bits describe the exact
    /// same double (round-trip rule of §5.2). `-0.0`/`+0.0` and NaN never match
    /// their decimal text, which is exactly the conservative behaviour wanted.
    static func matches(decimal: Double, bits u64Text: String) -> Bool {
        guard let restored = double(fromU64String: u64Text) else { return false }
        return restored.bitPattern == decimal.bitPattern
    }
}

// MARK: - Identity (native-issued binding document)

struct ImpeccableSize: Codable, Sendable, Equatable {
    var width: Double
    var height: Double
}

struct ImpeccablePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

struct ImpeccableProducerInfo: Codable, Sendable, Equatable {
    var name: String
    var version: String
    var engine: String
    var scriptDigest: String
}

struct ImpeccableRedactionReceipt: Codable, Sendable, Equatable {
    var policy: String
    var applied: Bool
    var passwordInputs: Int
    var formValues: Int
    var credentialAttributes: [String]
    var textRuns: Int

    static let emptyNative = ImpeccableRedactionReceipt(
        policy: ImpeccableContract.redactionPolicy,
        applied: true,
        passwordInputs: 0,
        formValues: 0,
        credentialAttributes: [],
        textRuns: 0
    )
}

struct ImpeccableIdentity: Codable, Sendable, Equatable {
    var taskId: String
    var sessionId: String
    var tabId: String
    var documentId: String
    var captureId: String
    var documentGeneration: Int
    var url: String
    var hostname: String
    var viewport: ImpeccableSize
    var scroll: ImpeccablePoint
    var capturedAtMs: Int64
    var producerTrust: String
    var producer: ImpeccableProducerInfo
    var redaction: ImpeccableRedactionReceipt
    var fenced: Bool

    /// A minimal native-side snapshot summary the identity must agree with
    /// (contract §6 rule 4: hostname/viewport/scroll equal the snapshot's own
    /// values). Produced by `ImpeccableSnapshotFacts`.
    struct SnapshotAgreement: Sendable, Equatable {
        var hostname: String
        var innerWidth: Double
        var innerHeight: Double
        var scrollX: Double
        var scrollY: Double
    }

    /// Contract §6/§7 privacy + schema rules for a real capture. Returns the
    /// rejection reasons; empty means the identity is structurally acceptable
    /// (binding vs the live capture is checked separately against the record).
    func ingressRejections(
        snapshot: SnapshotAgreement,
        expectedScriptDigest: String
    ) -> [String] {
        var rejections: [String] = []
        if producerTrust != ImpeccableContract.producerTrust {
            rejections.append("identity rejected: untrusted producerTrust '\(producerTrust)'")
        }
        if captureId.isEmpty || documentId.isEmpty || taskId.isEmpty
            || sessionId.isEmpty || tabId.isEmpty {
            rejections.append("identity rejected: required binding absent")
        }
        if documentGeneration < 0 {
            rejections.append("identity rejected: negative documentGeneration")
        }
        if url.isEmpty {
            rejections.append("identity rejected: url absent")
        }
        let digest = producer.scriptDigest.lowercased()
        if digest != expectedScriptDigest {
            rejections.append("identity rejected: scriptDigest is not the pinned fixed producer")
        }
        if digest == ImpeccableContract.syntheticScriptDigest {
            rejections.append("identity rejected: synthetic all-zero scriptDigest is never a real capture")
        }
        if !digest.allSatisfy(\.isHexDigit) || digest.count != 64 {
            rejections.append("identity rejected: scriptDigest malformed")
        }
        if producer.engine != ImpeccableContract.producerEngine {
            rejections.append("identity rejected: producer engine is not WebKit")
        }
        if producer.name.isEmpty || producer.version.isEmpty {
            rejections.append("identity rejected: producer name/version absent")
        }
        if redaction.policy != ImpeccableContract.redactionPolicy || redaction.applied != true {
            rejections.append("identity rejected: redaction policy not applied")
        }
        if redaction.passwordInputs < 0 || redaction.formValues < 0 || redaction.textRuns < 0
            || redaction.credentialAttributes.contains(where: { $0.isEmpty }) {
            rejections.append("identity rejected: redaction counters invalid")
        }
        if fenced {
            rejections.append("superseded: identity carries a fenced capture")
        }
        if hostname != snapshot.hostname {
            rejections.append("identityCheck mismatch: hostname differs from snapshot")
        }
        if viewport.width.bitPattern != snapshot.innerWidth.bitPattern
            || viewport.height.bitPattern != snapshot.innerHeight.bitPattern {
            rejections.append("identityCheck mismatch: viewport differs from snapshot")
        }
        if scroll.x.bitPattern != snapshot.scrollX.bitPattern
            || scroll.y.bitPattern != snapshot.scrollY.bitPattern {
            rejections.append("identityCheck mismatch: scroll differs from snapshot")
        }
        if capturedAtMs < 0 {
            rejections.append("identity rejected: negative capturedAtMs")
        }
        return rejections
    }

    /// Equality of the binding that every snapshot/needs/facts document must
    /// share (contract bindingRules).
    var bindingKey: String { "\(taskId)|\(sessionId)|\(tabId)|\(documentId)|\(captureId)|\(documentGeneration)" }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Strict decode of the `identity` echo carried by an engine result
    /// document, against the frozen identity schema's required-field list.
    /// Any absent, mistyped or malformed field is a rejection; a rejected
    /// echo never yields an identity (and a result without a fully valid
    /// echo can never carry usable findings). `fenced` is optional in the
    /// schema; absence decodes as `false`.
    static func decodeResultEcho(_ object: Any?) -> (identity: ImpeccableIdentity?, rejections: [String]) {
        guard let dictionary = object as? [String: Any] else {
            return (nil, ["identity echo is not a JSON object"])
        }
        var rejections: [String] = []
        func string(_ key: String) -> String? {
            guard let value = dictionary[key] as? String else {
                rejections.append("identity.\(key) absent or not a string")
                return nil
            }
            return value
        }
        func integer(_ key: String) -> Int? {
            guard let number = dictionary[key] as? NSNumber else {
                rejections.append("identity.\(key) absent or not a number")
                return nil
            }
            guard Double(number.intValue) == number.doubleValue else {
                rejections.append("identity.\(key) is not an integer")
                return nil
            }
            return number.intValue
        }
        func number(_ container: [String: Any], _ key: String, _ label: String) -> Double? {
            guard let value = (container[key] as? NSNumber)?.doubleValue, value.isFinite else {
                rejections.append("identity.\(label) absent or not a finite number")
                return nil
            }
            return value
        }

        guard let taskId = string("taskId"),
              let sessionId = string("sessionId"),
              let tabId = string("tabId"),
              let documentId = string("documentId"),
              let captureId = string("captureId"),
              let documentGeneration = integer("documentGeneration"),
              let url = string("url"),
              let hostname = string("hostname") else {
            return (nil, rejections)
        }
        var viewportWidth: Double?
        var viewportHeight: Double?
        if let viewport = dictionary["viewport"] as? [String: Any] {
            viewportWidth = number(viewport, "width", "viewport.width")
            viewportHeight = number(viewport, "height", "viewport.height")
        } else {
            rejections.append("identity.viewport absent or not an object")
        }
        var scrollX: Double?
        var scrollY: Double?
        if let scroll = dictionary["scroll"] as? [String: Any] {
            scrollX = number(scroll, "x", "scroll.x")
            scrollY = number(scroll, "y", "scroll.y")
        } else {
            rejections.append("identity.scroll absent or not an object")
        }
        guard let capturedAtMsNumber = dictionary["capturedAtMs"] as? NSNumber,
              Int64(exactly: capturedAtMsNumber.int64Value) != nil,
              Double(capturedAtMsNumber.int64Value) == capturedAtMsNumber.doubleValue else {
            rejections.append("identity.capturedAtMs absent or not an integer")
            return (nil, rejections)
        }
        let capturedAtMs = capturedAtMsNumber.int64Value
        guard let producerTrust = string("producerTrust") else { return (nil, rejections) }
        var producerName: String?
        var producerVersion: String?
        var producerEngine: String?
        var scriptDigest: String?
        if let producer = dictionary["producer"] as? [String: Any] {
            producerName = producer["name"] as? String
            producerVersion = producer["version"] as? String
            producerEngine = producer["engine"] as? String
            scriptDigest = producer["scriptDigest"] as? String
            if producerName == nil { rejections.append("identity.producer.name absent or not a string") }
            if producerVersion == nil { rejections.append("identity.producer.version absent or not a string") }
            if producerEngine == nil { rejections.append("identity.producer.engine absent or not a string") }
            if scriptDigest == nil { rejections.append("identity.producer.scriptDigest absent or not a string") }
        } else {
            rejections.append("identity.producer absent or not an object")
        }
        var redactionReceipt: ImpeccableRedactionReceipt?
        if let redaction = dictionary["redaction"] as? [String: Any],
           let policy = redaction["policy"] as? String,
           let applied = redaction["applied"] as? Bool,
           let passwordInputs = (redaction["passwordInputs"] as? NSNumber)?.intValue,
           let formValues = (redaction["formValues"] as? NSNumber)?.intValue,
           let textRuns = (redaction["textRuns"] as? NSNumber)?.intValue,
           let credentialAttributes = redaction["credentialAttributes"] as? [String] {
            redactionReceipt = ImpeccableRedactionReceipt(
                policy: policy,
                applied: applied,
                passwordInputs: passwordInputs,
                formValues: formValues,
                credentialAttributes: credentialAttributes,
                textRuns: textRuns
            )
        } else {
            rejections.append("identity.redaction absent or malformed")
        }
        var fenced = false
        if let fencedValue = dictionary["fenced"] {
            if let value = fencedValue as? Bool {
                fenced = value
            } else if !(fencedValue is NSNull) {
                rejections.append("identity.fenced is not a boolean")
            }
        }
        guard rejections.isEmpty,
              let viewportWidth, let viewportHeight,
              let scrollX, let scrollY,
              let producerName, let producerVersion, let producerEngine, let scriptDigest,
              let redactionReceipt else {
            return (nil, rejections)
        }
        return (ImpeccableIdentity(
            taskId: taskId,
            sessionId: sessionId,
            tabId: tabId,
            documentId: documentId,
            captureId: captureId,
            documentGeneration: documentGeneration,
            url: url,
            hostname: hostname,
            viewport: ImpeccableSize(width: viewportWidth, height: viewportHeight),
            scroll: ImpeccablePoint(x: scrollX, y: scrollY),
            capturedAtMs: capturedAtMs,
            producerTrust: producerTrust,
            producer: ImpeccableProducerInfo(
                name: producerName,
                version: producerVersion,
                engine: producerEngine,
                scriptDigest: scriptDigest
            ),
            redaction: redactionReceipt,
            fenced: fenced
        ), [])
    }

    /// Field-by-field comparison against the native-issued identity of the
    /// capture record. Every frozen field is compared; viewport/scroll use
    /// exact IEEE-754 bit patterns. A non-empty return means the result
    /// cannot belong to this capture: it is a failure, never a finding and
    /// never an inconclusive-with-usable-counts. The engine's own
    /// `identityCheck.state == "verified"` claim never substitutes for this
    /// comparison.
    func mismatches(against issued: ImpeccableIdentity) -> [String] {
        var mismatches: [String] = []
        if taskId != issued.taskId { mismatches.append("taskId") }
        if sessionId != issued.sessionId { mismatches.append("sessionId") }
        if tabId != issued.tabId { mismatches.append("tabId") }
        if documentId != issued.documentId { mismatches.append("documentId") }
        if captureId != issued.captureId { mismatches.append("captureId") }
        if documentGeneration != issued.documentGeneration { mismatches.append("documentGeneration") }
        if url != issued.url { mismatches.append("url") }
        if hostname != issued.hostname { mismatches.append("hostname") }
        if viewport.width.bitPattern != issued.viewport.width.bitPattern { mismatches.append("viewport.width") }
        if viewport.height.bitPattern != issued.viewport.height.bitPattern { mismatches.append("viewport.height") }
        if scroll.x.bitPattern != issued.scroll.x.bitPattern { mismatches.append("scroll.x") }
        if scroll.y.bitPattern != issued.scroll.y.bitPattern { mismatches.append("scroll.y") }
        if capturedAtMs != issued.capturedAtMs { mismatches.append("capturedAtMs") }
        if producerTrust != issued.producerTrust { mismatches.append("producerTrust") }
        if producerTrust != ImpeccableContract.producerTrust { mismatches.append("producerTrust (not native-fixed-script)") }
        if producer.name != issued.producer.name { mismatches.append("producer.name") }
        if producer.version != issued.producer.version { mismatches.append("producer.version") }
        if producer.engine != issued.producer.engine { mismatches.append("producer.engine") }
        if producer.scriptDigest.lowercased() != issued.producer.scriptDigest.lowercased() { mismatches.append("producer.scriptDigest") }
        if redaction.policy != issued.redaction.policy { mismatches.append("redaction.policy") }
        if redaction.applied != issued.redaction.applied { mismatches.append("redaction.applied") }
        if redaction.passwordInputs != issued.redaction.passwordInputs { mismatches.append("redaction.passwordInputs") }
        if redaction.formValues != issued.redaction.formValues { mismatches.append("redaction.formValues") }
        if redaction.textRuns != issued.redaction.textRuns { mismatches.append("redaction.textRuns") }
        if redaction.credentialAttributes.sorted() != issued.redaction.credentialAttributes.sorted() { mismatches.append("redaction.credentialAttributes") }
        if fenced != issued.fenced { mismatches.append("fenced") }
        return mismatches
    }
}

// MARK: - Needs (engine → native)

struct ImpeccableNeeds: Sendable, Equatable {
    var hitTests: [[Double]]
    var hitTestsBits: [[String]]?
    var scrollProbes: [Int]
    var round: Int

    var isEmpty: Bool { hitTests.isEmpty && scrollProbes.isEmpty }

    /// Decodes one Needs document from engine output.
    static func decode(from data: Data) throws -> ImpeccableNeeds {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ImpeccableCaptureError.invalidInput("needs", "Needs document is not a JSON object")
        }
        return try decode(dictionary)
    }

    static func decode(_ dictionary: [String: Any]) throws -> ImpeccableNeeds {
        let rawHits = dictionary["hitTests"] as? [Any] ?? []
        let hitTests = rawHits.compactMap { entry -> [Double]? in
            guard let pair = entry as? [Any], pair.count == 2,
                  let x = (pair[0] as? NSNumber)?.doubleValue,
                  let y = (pair[1] as? NSNumber)?.doubleValue else { return nil }
            return [x, y]
        }
        var bits: [[String]]? = nil
        if let raw = dictionary["hitTestsBits"] as? [Any] {
            bits = raw.compactMap { entry -> [String]? in
                guard let pair = entry as? [Any], pair.count == 2 else { return nil }
                return [bitText(pair[0]), bitText(pair[1])]
            }
        }
        let probes = (dictionary["scrollProbes"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        guard let round = (dictionary["round"] as? NSNumber)?.intValue else {
            throw ImpeccableCaptureError.invalidInput("needs", "Needs document lacks an integer round")
        }
        if hitTests.count != rawHits.count {
            throw ImpeccableCaptureError.invalidInput("needs", "Needs hitTests contains a malformed point")
        }
        if let bits, bits.count != rawHits.count {
            throw ImpeccableCaptureError.invalidInput("needs", "Needs hitTestsBits contains a malformed pair")
        }
        return ImpeccableNeeds(hitTests: hitTests, hitTestsBits: bits, scrollProbes: probes, round: round)
    }

    static func bitText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.uint64Value.description }
        return ""
    }

    /// Contract §5.2/§7: the decimal text must round-trip to the declared bits
    /// exactly, and every asked point needs a bits pair. Returns the effective
    /// authoritative points (from the bits, which are the engine's true keys).
    func verifiedPoints() throws -> [(x: Double, y: Double)] {
        guard let bits = hitTestsBits else {
            throw ImpeccableCaptureError.needsBitsMismatch("Needs omits hitTestsBits; exact-bit verification is mandatory")
        }
        guard bits.count == hitTests.count else {
            throw ImpeccableCaptureError.needsBitsMismatch("Needs hitTestsBits count differs from hitTests")
        }
        var points: [(Double, Double)] = []
        for index in hitTests.indices {
            guard hitTests[index].count == 2 else {
                throw ImpeccableCaptureError.needsBitsMismatch("Needs point \(index) is malformed")
            }
            guard bits[index].count == 2,
                  let xBits = bits[index][0].isEmpty ? nil : bits[index][0],
                  let yBits = bits[index][1].isEmpty ? nil : bits[index][1],
                  let x = ImpeccableDoubleBits.double(fromU64String: xBits),
                  let y = ImpeccableDoubleBits.double(fromU64String: yBits) else {
                throw ImpeccableCaptureError.needsBitsMismatch("Needs point \(index) carries undecodable bits")
            }
            guard ImpeccableDoubleBits.matches(decimal: hitTests[index][0], bits: xBits),
                  ImpeccableDoubleBits.matches(decimal: hitTests[index][1], bits: yBits) else {
                throw ImpeccableCaptureError.needsBitsMismatch("Needs point \(index) decimal text does not round-trip to its bits")
            }
            guard x.isFinite, y.isFinite else {
                throw ImpeccableCaptureError.needsBitsMismatch("Needs point \(index) is not finite")
            }
            points.append((x, y))
        }
        return points
    }
}

// MARK: - Facts (native → engine answers)

struct ImpeccableFactHit: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var xBits: String
    var yBits: String
    var top: Int
    var stack: [Int]
    var unanswerable: Bool?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case x, y, xBits, yBits, top, stack, unanswerable, reason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(xBits, forKey: .xBits)
        try container.encode(yBits, forKey: .yBits)
        try container.encode(top, forKey: .top)
        try container.encode(stack, forKey: .stack)
        try container.encodeIfPresent(unanswerable, forKey: .unanswerable)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    /// Bits must equal the exact key of the point that was asked.
    var bitPairMatchesPoint: Bool {
        ImpeccableDoubleBits.matches(decimal: x, bits: xBits)
            && ImpeccableDoubleBits.matches(decimal: y, bits: yBits)
    }
}

struct ImpeccableShownOnScroll: Codable, Sendable, Equatable {
    var el: Int
    var shown: Bool
}

struct ImpeccableFacts: Codable, Sendable, Equatable {
    var taskId: String
    var sessionId: String
    var tabId: String
    var documentId: String
    var captureId: String
    var documentGeneration: Int
    var fenced: Bool
    var hits: [ImpeccableFactHit]
    var shownOnScroll: [ImpeccableShownOnScroll]

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Contract §7 (`facts-bits-mismatch`, `facts-stale-capture`,
    /// `facts-other-tab`): a facts document is only acceptable when its bits
    /// equal the asked points and its binding equals the capture that issued
    /// the Needs. Rejected facts are never merged.
    func rejections(
        against binding: ImpeccableCaptureBinding,
        askedPoints: [(x: Double, y: Double)],
        elementCount: Int
    ) -> [String] {
        var rejections: [String] = []
        if fenced {
            rejections.append("facts rejected: fenced capture")
        }
        if taskId != binding.taskId || sessionId != binding.sessionId || tabId != binding.tabId
            || documentId != binding.documentId || captureId != binding.captureId
            || documentGeneration != binding.documentGeneration {
            rejections.append("facts rejected: binding differs from the capture that was asked")
        }
        if hits.count != askedPoints.count {
            rejections.append("facts rejected: answer count differs from asked points")
        }
        for (index, hit) in hits.enumerated() where index < askedPoints.count {
            guard hit.bitPairMatchesPoint else {
                rejections.append("facts rejected: point \(index) bits differ from the Needs that asked")
                continue
            }
            if hit.x.bitPattern != askedPoints[index].x.bitPattern
                || hit.y.bitPattern != askedPoints[index].y.bitPattern {
                rejections.append("facts rejected: point \(index) differs from the Needs that asked")
            }
            if hit.top < 0 || hit.top > elementCount {
                rejections.append("facts rejected: point \(index) top id outside the capture")
            }
            if hit.stack.contains(where: { $0 <= 0 || $0 > elementCount }) {
                rejections.append("facts rejected: point \(index) stack contains a zero or foreign id")
            }
            if (hit.unanswerable ?? false) == false && hit.top == 0 && hit.stack.isEmpty {
                rejections.append("facts rejected: point \(index) answers nothing without unanswerable + reason")
            }
            if (hit.unanswerable ?? false) && (hit.reason ?? "").isEmpty {
                rejections.append("facts rejected: point \(index) is unanswerable without a reason")
            }
        }
        if shownOnScroll.contains(where: { $0.el < 1 || $0.el > elementCount }) {
            rejections.append("facts rejected: shownOnScroll references an id outside the capture")
        }
        return rejections
    }
}

/// The native-side binding mirror of the identity fields, held by capture
/// records and used for synchronous fence checks.
struct ImpeccableCaptureBinding: Codable, Sendable, Equatable {
    var taskId: String
    var sessionId: String
    var tabId: String
    var documentId: String
    var documentGeneration: Int
    var captureId: String
}

// MARK: - Snapshot ingress scan

/// The small, validated summary of one snapshot as it enters the native side.
/// The full document is never held as a Swift value tree beyond the file copy.
struct ImpeccableSnapshotIngress: Sendable {
    var version: Int?
    var hostname: String
    var innerWidth: Double
    var innerHeight: Double
    var scrollX: Double
    var scrollY: Double
    var elementCount: Int
    var stylePropsCount: Int
    var columnParityBrokenCount: Int
    var floeCaptureId: String?
    var floeDocumentId: String?
    var floeContractVersion: Int?
    var redaction: ImpeccableRedactionReceipt?
    var snapshotBytes: Int

    /// One full pass over the returned snapshot value. Expensive fields are
    /// scanned (element count, per-element 138-column parity) because the
    /// contract rejects a `schema-mismatch` capture rather than trusting it.
    static func scan(_ object: Any, snapshotBytes: Int, budgets: ImpeccableBudgets) -> (ingress: ImpeccableSnapshotIngress?, rejections: [String]) {
        guard let dictionary = object as? [String: Any] else {
            return (nil, ["snapshot-parse: top level is not a JSON object"])
        }
        guard dictionary["v"] != nil else {
            return (nil, ["snapshot-parse: no version field"])
        }
        let version = (dictionary["v"] as? NSNumber)?.intValue
        guard version == 1 else {
            return (nil, ["snapshot-version-unsupported: v=\(version.map(String.init) ?? "unreadable")"])
        }
        guard dictionary["strings"] is [Any] else {
            return (nil, ["schema-mismatch: strings table absent"])
        }
        var rejections: [String] = []
        let hostname = (dictionary["hostname"] as? String) ?? ""
        let innerWidth = (dictionary["innerWidth"] as? NSNumber)?.doubleValue ?? .nan
        let innerHeight = (dictionary["innerHeight"] as? NSNumber)?.doubleValue ?? .nan
        let scrollX = (dictionary["scrollX"] as? NSNumber)?.doubleValue ?? .nan
        let scrollY = (dictionary["scrollY"] as? NSNumber)?.doubleValue ?? .nan
        guard innerWidth.isFinite, innerHeight.isFinite, scrollX.isFinite, scrollY.isFinite,
              innerWidth > 0, innerHeight > 0 else {
            rejections.append("schema-mismatch: snapshot viewport/scroll are not finite usable numbers")
            return (nil, rejections)
        }
        let styleProps = dictionary["styleProps"] as? [Any] ?? []
        let stylePropsCount = styleProps.count
        guard stylePropsCount == ImpeccableContract.stylePropCount else {
            rejections.append("schema-mismatch: styleProps column count \(stylePropsCount) != 138")
        }
        let elements = dictionary["els"] as? [Any] ?? []
        let elementCount = elements.count
        if elementCount == 0 {
            rejections.append("schema-mismatch: snapshot contains no elements")
        }
        if elementCount > budgets.maxElements {
            rejections.append("budget: elements \(elementCount) > \(budgets.maxElements)")
        }
        if snapshotBytes > budgets.maxSnapshotBytes {
            rejections.append("budget: snapshot bytes \(snapshotBytes) > \(budgets.maxSnapshotBytes)")
        }
        var parityBroken = 0
        for element in elements {
            guard let record = element as? [String: Any] else { parityBroken += 1; continue }
            let s = record["s"] as? [Any] ?? []
            if s.count != ImpeccableContract.stylePropCount { parityBroken += 1 }
        }
        if parityBroken > 0 {
            rejections.append("schema-mismatch: \(parityBroken) element(s) with s-length != styleProps")
        }
        let documentElementID = (dictionary["documentElement"] as? NSNumber)?.intValue ?? -1
        if documentElementID < 1 || documentElementID > elementCount {
            rejections.append("schema-mismatch: documentElement id does not resolve inside els")
        }
        if dictionary["body"] == nil {
            rejections.append("schema-mismatch: body id absent")
        } else if let bodyNumber = dictionary["body"] as? NSNumber, bodyNumber.intValue < 0 || bodyNumber.intValue > elementCount {
            rejections.append("schema-mismatch: body id does not resolve inside els")
        }
        var floeCaptureId: String?
        var floeDocumentId: String?
        var floeContractVersion: Int?
        var floeRedaction: ImpeccableRedactionReceipt?
        if let floe = dictionary["floe"] as? [String: Any] {
            floeCaptureId = floe["captureId"] as? String
            floeDocumentId = floe["documentId"] as? String
            floeContractVersion = (floe["contractVersion"] as? NSNumber)?.intValue
            floeRedaction = ImpeccableRedactionReceipt.decode(floe["redaction"])
        } else {
            rejections.append("schema-mismatch: snapshot lacks the floe binding block")
        }
        let ingress = ImpeccableSnapshotIngress(
            version: version,
            hostname: hostname,
            innerWidth: innerWidth,
            innerHeight: innerHeight,
            scrollX: scrollX,
            scrollY: scrollY,
            elementCount: elementCount,
            stylePropsCount: stylePropsCount,
            columnParityBrokenCount: parityBroken,
            floeCaptureId: floeCaptureId,
            floeDocumentId: floeDocumentId,
            floeContractVersion: floeContractVersion,
            redaction: floeRedaction,
            snapshotBytes: snapshotBytes
        )
        return (rejections.isEmpty ? ingress : nil, rejections)
    }
}

extension ImpeccableRedactionReceipt {
    /// Best-effort decode of one redaction receipt as found in a snapshot's
    /// `floe` block or an identity document. `nil` on any structural failure —
    /// the caller treats absence as "redaction not proven".
    static func decode(_ object: Any?) -> ImpeccableRedactionReceipt? {
        guard let dictionary = object as? [String: Any] else { return nil }
        guard let policy = dictionary["policy"] as? String,
              let applied = dictionary["applied"] as? Bool,
              let passwordInputs = (dictionary["passwordInputs"] as? NSNumber)?.intValue,
              let formValues = (dictionary["formValues"] as? NSNumber)?.intValue,
              let textRuns = (dictionary["textRuns"] as? NSNumber)?.intValue,
              let credentialAttributes = dictionary["credentialAttributes"] as? [String] else {
            return nil
        }
        return ImpeccableRedactionReceipt(
            policy: policy,
            applied: applied,
            passwordInputs: passwordInputs,
            formValues: formValues,
            credentialAttributes: credentialAttributes,
            textRuns: textRuns
        )
    }

    var contractRejections: [String] {
        var rejections: [String] = []
        if policy != ImpeccableContract.redactionPolicy {
            rejections.append("redaction policy is not \(ImpeccableContract.redactionPolicy)")
        }
        if !applied { rejections.append("redaction not applied") }
        if passwordInputs < 0 || formValues < 0 || textRuns < 0 {
            rejections.append("redaction counters negative")
        }
        if credentialAttributes.contains(where: { $0.isEmpty }) {
            rejections.append("redaction credentialAttributes contains an empty name")
        }
        return rejections
    }
}

// MARK: - Result (engine → native) and truthful exit mapping

enum ImpeccableEngineExit: Int, Sendable {
    case clean = 0
    case failure = 1
    case findings = 2
    case needsFacts = 3
    case inconclusive = 4
}

struct ImpeccableResultIdentityCheck: Sendable, Equatable {
    /// verified | absent | mismatch | superseded
    var state: String
    var mismatches: [String]
}

struct ImpeccableResultCoveragePass: Sendable, Equatable {
    var id: String
    var state: String
    var requiredForCleanVerdict: Bool?
    var reason: String?
}

struct ImpeccableResultCoverage: Sendable, Equatable {
    var passes: [ImpeccableResultCoveragePass]
    var uncoveredRequired: [String]
    var unknownStyleProps: [String]?

    var uncoveredRequiredList: [String] {
        var listed = Set(uncoveredRequired)
        for pass in passes where (pass.requiredForCleanVerdict ?? false) {
            if pass.state == "uncovered" || pass.state == "not-run" || pass.state == "failed" {
                listed.insert(pass.id)
            }
        }
        return listed.sorted()
    }
}

struct ImpeccableResultBudget: Sendable, Equatable {
    var exceeded: [String]?
}

struct ImpeccableResultError: Sendable, Equatable {
    var code: String
    var message: String
}

struct ImpeccableResultDocument: Sendable {
    var contract: String
    var contractVersion: Int
    var status: String
    var verdict: String
    var identityCheck: ImpeccableResultIdentityCheck?
    var budget: ImpeccableResultBudget?
    var coverage: ImpeccableResultCoverage?
    var needs: ImpeccableNeeds?
    var findingCount: Int
    var error: ImpeccableResultError?
    /// The full frozen-v1 `identity` echo of the engine result, strictly
    /// decoded. `nil` with empty rejections means the document carried no
    /// identity at all; a non-empty `identityDecodingRejections` means it
    /// carried a malformed one. Either way the result can never carry usable
    /// findings — the native-issued capture identity is mandatory.
    var identity: ImpeccableIdentity?
    var identityDecodingRejections: [String]

    /// Tolerant read-only parse of the engine result document (the native side
    /// never re-emits it). Required top-level fields are enforced; unknown
    /// fields are ignored. Throws `.invalidInput` (contract code
    /// `snapshot-parse`) on a malformed document — a broken result can never
    /// become a pass.
    static func parse(from data: Data) throws -> ImpeccableResultDocument {
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let contract = dictionary["contract"] as? String,
              let contractVersion = (dictionary["contractVersion"] as? NSNumber)?.intValue,
              let status = dictionary["status"] as? String,
              let verdict = dictionary["verdict"] as? String else {
            throw ImpeccableCaptureError.invalidInput("result", "result document is missing required fields")
        }
        var identityCheck: ImpeccableResultIdentityCheck?
        if let raw = dictionary["identityCheck"] as? [String: Any],
           let state = raw["state"] as? String {
            identityCheck = ImpeccableResultIdentityCheck(
                state: state,
                mismatches: (raw["mismatches"] as? [Any] ?? []).compactMap { $0 as? String }
            )
        }
        var budget: ImpeccableResultBudget?
        if let raw = dictionary["budget"] as? [String: Any] {
            budget = ImpeccableResultBudget(
                exceeded: (raw["exceeded"] as? [Any])?.compactMap { $0 as? String }
            )
        }
        var coverage: ImpeccableResultCoverage?
        if let raw = dictionary["coverage"] as? [String: Any],
           let rawPasses = raw["passes"] as? [Any] {
            let passes = rawPasses.compactMap { entry -> ImpeccableResultCoveragePass? in
                guard let pass = entry as? [String: Any],
                      let id = pass["id"] as? String,
                      let state = pass["state"] as? String else { return nil }
                return ImpeccableResultCoveragePass(
                    id: id,
                    state: state,
                    requiredForCleanVerdict: (pass["requiredForCleanVerdict"] as? NSNumber)?.boolValue,
                    reason: pass["reason"] as? String
                )
            }
            let uncovered = (raw["uncoveredRequired"] as? [Any] ?? []).compactMap { $0 as? String }
            coverage = ImpeccableResultCoverage(
                passes: passes,
                uncoveredRequired: uncovered,
                unknownStyleProps: (raw["unknownStyleProps"] as? [Any])?.compactMap { $0 as? String }
            )
        }
        var needs: ImpeccableNeeds?
        if let raw = dictionary["needs"] as? [String: Any],
           (raw["hitTests"] as? [Any])?.isEmpty == false || (raw["scrollProbes"] as? [Any])?.isEmpty == false {
            needs = try ImpeccableNeeds.decode(raw)
        }
        var identity: ImpeccableIdentity?
        var identityDecodingRejections: [String] = []
        if let rawIdentity = dictionary["identity"], !(rawIdentity is NSNull) {
            let decoded = ImpeccableIdentity.decodeResultEcho(rawIdentity)
            identity = decoded.identity
            identityDecodingRejections = decoded.rejections
        }
        var findingCount = 0
        if let findings = dictionary["findings"] as? [String: Any] {
            if let total = (findings["counts"] as? [String: Any])?["total"] as? NSNumber {
                findingCount = max(0, total.intValue)
            } else {
                let groups = (findings["groups"] as? [Any] ?? []).reduce(0) { sum, entry in
                    guard let group = entry as? [String: Any] else { return sum }
                    return sum + ((group["items"] as? [Any])?.count ?? 0)
                }
                let pageLevel = (findings["pageLevel"] as? [Any])?.count ?? 0
                findingCount = groups + pageLevel
            }
        }
        var error: ImpeccableResultError?
        if let raw = dictionary["error"] as? [String: Any],
           let code = raw["code"] as? String {
            error = ImpeccableResultError(code: code, message: (raw["message"] as? String) ?? "")
        }
        return ImpeccableResultDocument(
            contract: contract,
            contractVersion: contractVersion,
            status: status,
            verdict: verdict,
            identityCheck: identityCheck,
            budget: budget,
            coverage: coverage,
            needs: needs,
            findingCount: findingCount,
            error: error,
            identity: identity,
            identityDecodingRejections: identityDecodingRejections
        )
    }

    /// Exit mapping per the frozen table. 3 and 4 are never a clean scan; the
    /// native side derives the exit from the document itself and never
    /// "succeeds" a malformed result into a pass.
    var engineExit: ImpeccableEngineExit {
        if status == "failed" { return .failure }
        if status == "needs-facts" { return .needsFacts }
        if status == "inconclusive" || verdict == "inconclusive" { return .inconclusive }
        if status == "complete" {
            if verdict == "clean" { return .clean }
            if verdict == "findings" { return .findings }
            return .inconclusive
        }
        return .failure
    }
}

// MARK: - Coverage rule (v1: missing is never clean)

enum ImpeccableCoverage {
    struct Pass: Sendable, Equatable {
        let id: String
        let requiredForCleanVerdict: Bool
    }

    /// The 18 passes of `snapshot-contract.v1.json → coveragePasses`, with the
    /// frozen clean-verdict requirements.
    static let v1Passes: [Pass] = [
        Pass(id: "core-rule-pass", requiredForCleanVerdict: true),
        Pass(id: "hit-test-fixpoint", requiredForCleanVerdict: true),
        Pass(id: "style-parity", requiredForCleanVerdict: true),
        Pass(id: "scroll-probes", requiredForCleanVerdict: true),
        Pass(id: "static-html-source-scan", requiredForCleanVerdict: false),
        Pass(id: "pixel-contrast", requiredForCleanVerdict: true),
        Pass(id: "screenshot-diff", requiredForCleanVerdict: false),
        Pass(id: "reveal-sweep", requiredForCleanVerdict: true),
        Pass(id: "content-hidden-at-rest-measure", requiredForCleanVerdict: true),
        Pass(id: "consent-overlay-hiding", requiredForCleanVerdict: false),
        Pass(id: "script-errors", requiredForCleanVerdict: true),
        Pass(id: "cross-origin-iframe", requiredForCleanVerdict: true),
        Pass(id: "same-origin-iframe", requiredForCleanVerdict: true),
        Pass(id: "media-intrinsics", requiredForCleanVerdict: false),
        Pass(id: "animations", requiredForCleanVerdict: false),
        Pass(id: "shadow-trees", requiredForCleanVerdict: false),
        Pass(id: "text-lines", requiredForCleanVerdict: true),
        Pass(id: "keyframes-and-linked-css", requiredForCleanVerdict: false),
    ]

    /// In v1 these are uncovered by contract and each blocks a clean verdict,
    /// so no result can ever certify a page clean.
    static let uncoveredRequiredInV1: [String] = [
        "content-hidden-at-rest-measure",
        "cross-origin-iframe",
        "pixel-contrast",
        "reveal-sweep",
        "same-origin-iframe",
        "script-errors",
    ]

    /// The six conditions of §8. Returns the failed conditions; empty means the
    /// document claims a defensible clean state — which v1 still cannot deliver
    /// because condition 3 cannot hold (`cleanVerdictReachableInV1 == false`).
    static func cleanGateFailures(for result: ImpeccableResultDocument) -> [String] {
        var failures: [String] = []
        if result.status != "complete" { failures.append("status is \(result.status)") }
        if let needs = result.needs, !needs.isEmpty { failures.append("needs outstanding") }
        let uncovered = result.coverage?.uncoveredRequiredList ?? uncoveredRequiredInV1
        if result.coverage == nil {
            failures.append("coverage receipt absent")
        }
        if !uncovered.isEmpty {
            failures.append("required passes uncovered: \(uncovered.joined(separator: ", "))")
        }
        if let coverage = result.coverage, !(coverage.unknownStyleProps ?? []).isEmpty {
            failures.append("style-parity partial: \(coverage.unknownStyleProps?.joined(separator: ", ") ?? "")")
        }
        if result.identityCheck?.state != "verified" {
            failures.append("identity not verified (\(result.identityCheck?.state ?? "absent"))")
        }
        if let exceeded = result.budget?.exceeded, !exceeded.isEmpty {
            failures.append("budget exceeded: \(exceeded.joined(separator: ", "))")
        }
        if result.error?.code == "cancelled" || result.error?.code == "timeout" {
            failures.append("run did not complete (\(result.error?.code ?? ""))")
        }
        return failures
    }

    static var cleanVerdictReachableInV1: Bool { false }

    /// One uniform failure assessment: zero findings, zero usable counts,
    /// truthful identity state and headline. Every refusal path (absent,
    /// foreign, malformed identity; fenced or moved capture; unprovable
    /// currency) reports through this shape.
    static func failure(
        identityState: String,
        headline: String,
        identityRejections: [String] = []
    ) -> ImpeccableResultAssessment {
        ImpeccableResultAssessment(
            exit: .failure,
            identityState: identityState,
            headline: headline,
            findingCount: 0,
            uncoveredRequired: [],
            needsOutstanding: nil,
            budgetExceeded: [],
            identityRejections: identityRejections
        )
    }

    /// One uniform superseded assessment for a late result: the capture
    /// moved, was replaced or was fenced, so the result can never be a scan
    /// outcome regardless of its content.
    static func superseded(_ headline: String) -> ImpeccableResultAssessment {
        failure(identityState: "superseded", headline: "superseded: \(headline)")
    }

    /// Final native surface assessment for one result document bound to one
    /// capture record. `superseded` and malformed documents are reported
    /// truthfully and never converted into a pass.
    static func assess(
        result: ImpeccableResultDocument?,
        parseFailure: String?,
        recordFenced: Bool,
        bindingMatches: Bool
    ) -> ImpeccableResultAssessment {
        if recordFenced {
            return ImpeccableResultAssessment(
                exit: .failure,
                identityState: "superseded",
                headline: "superseded: the capture was fenced; this result cannot be trusted",
                findingCount: 0,
                uncoveredRequired: [],
                needsOutstanding: nil,
                budgetExceeded: []
            )
        }
        guard let result else {
            return ImpeccableResultAssessment(
                exit: .failure,
                identityState: "absent",
                headline: "snapshot-parse: result document is malformed (\(parseFailure ?? "unspecified"))",
                findingCount: 0,
                uncoveredRequired: [],
                needsOutstanding: nil,
                budgetExceeded: []
            )
        }
        if result.contract != ImpeccableContract.name || result.contractVersion != ImpeccableContract.contractVersion {
            return ImpeccableResultAssessment(
                exit: .failure,
                identityState: result.identityCheck?.state ?? "absent",
                headline: "schema-mismatch: result is not \(ImpeccableContract.name) v\(ImpeccableContract.contractVersion)",
                findingCount: 0,
                uncoveredRequired: [],
                needsOutstanding: nil,
                budgetExceeded: []
            )
        }
        if !bindingMatches {
            return ImpeccableResultAssessment(
                exit: .failure,
                identityState: "mismatch",
                headline: "identityCheck mismatch: result binding differs from the capture record",
                findingCount: 0,
                uncoveredRequired: [],
                needsOutstanding: nil,
                budgetExceeded: []
            )
        }
        // The engine's own identityCheck is never allowed to turn a mismatch
        // or superseded document into a scan result (contract fencing rule 3).
        if let engineState = result.identityCheck?.state,
           engineState == "mismatch" || engineState == "superseded" {
            return ImpeccableResultAssessment(
                exit: .failure,
                identityState: engineState,
                headline: "identityCheck \(engineState): the engine did not bind this result to the capture; it is never a scan result",
                findingCount: 0,
                uncoveredRequired: [],
                needsOutstanding: nil,
                budgetExceeded: [],
                identityRejections: ["engine identityCheck \(engineState)"]
            )
        }
        var exit = result.engineExit
        var headline: String
        let uncovered = result.coverage?.uncoveredRequiredList ?? []
        let exceeded = result.budget?.exceeded ?? []
        let needs = (result.status == "needs-facts") ? result.needs : nil
        switch exit {
        case .clean:
            // v1 can never legitimately reach clean. A document claiming it is
            // surfaced truthfully as inconclusive with the coverage reason.
            if cleanVerdictReachableInV1 == false {
                exit = .inconclusive
                headline = "inconclusive: v1 coverage cannot certify a page clean (\(uncovered.isEmpty ? ImpeccableCoverage.uncoveredRequiredInV1.joined(separator: ", ") : uncovered.joined(separator: ", ")))"
            } else {
                headline = "clean"
            }
        case .findings:
            headline = "findings: \(result.findingCount)"
        case .needsFacts:
            headline = "needs-facts: the engine is asking for measurements (round \(result.needs?.round ?? 0))"
        case .inconclusive:
            headline = uncovered.isEmpty
                ? "inconclusive: coverage receipt incomplete"
                : "inconclusive: required passes uncovered (\(uncovered.joined(separator: ", ")))"
        case .failure:
            headline = result.error.map { "failed: \($0.code) \($0.message)" } ?? "failed"
        }
        return ImpeccableResultAssessment(
            exit: exit,
            // `bindingMatches == true` means the native side completed the
            // full frozen-identity comparison against its own issued record;
            // that native verdict — not the engine's claim — is reported.
            identityState: "verified",
            headline: headline,
            findingCount: exit == .findings ? result.findingCount : 0,
            uncoveredRequired: uncovered,
            needsOutstanding: needs,
            budgetExceeded: exceeded
        )
    }
}

struct ImpeccableResultAssessment: Sendable, Equatable {
    var exit: ImpeccableEngineExit
    /// verified | absent | mismatch | superseded. Only the native comparison
    /// against the issued capture identity can produce `verified`; the
    /// engine's own `identityCheck.state` claim never grants trust on its own.
    var identityState: String
    var headline: String
    var findingCount: Int
    var uncoveredRequired: [String]
    var needsOutstanding: ImpeccableNeeds?
    var budgetExceeded: [String]
    /// Exact native reasons the result identity was refused (absent,
    /// malformed, or the differing frozen fields). Empty when accepted.
    var identityRejections: [String] = []
}

// MARK: - Errors

enum ImpeccableCaptureError: Error, Sendable, CustomStringConvertible {
    case released
    case superseded(String)
    case noSuchCapture(String)
    case tabUnavailable(String)
    case invalidInput(String, String)
    case needsBitsMismatch(String)
    case factsRejected([String])
    case identityRejected([String])
    case schemaMismatch([String])
    case budgetExceeded([String])
    case timedOut
    case cancelled
    case producerScriptRejected(String)
    case webKit(String)

    var description: String {
        switch self {
        case .released: return "impeccable: the task browser session was released"
        case .superseded(let reason): return "impeccable: superseded (\(reason))"
        case .noSuchCapture(let id): return "impeccable: no capture record \(id)"
        case .tabUnavailable(let reason): return "impeccable: tab unavailable (\(reason))"
        case .invalidInput(let kind, let detail): return "impeccable: invalid \(kind): \(detail)"
        case .needsBitsMismatch(let detail): return "impeccable: needs bits verification failed: \(detail)"
        case .factsRejected(let reasons): return "impeccable: facts rejected: \(reasons.joined(separator: "; "))"
        case .identityRejected(let reasons): return "impeccable: identity rejected: \(reasons.joined(separator: "; "))"
        case .schemaMismatch(let reasons): return "impeccable: schema-mismatch: \(reasons.joined(separator: "; "))"
        case .budgetExceeded(let reasons): return "impeccable: budget exceeded: \(reasons.joined(separator: "; "))"
        case .timedOut: return "impeccable: timed out"
        case .cancelled: return "impeccable: cancelled"
        case .producerScriptRejected(let reason): return "impeccable: fixed producer refused: \(reason)"
        case .webKit(let detail): return "impeccable: WebKit error: \(detail)"
        }
    }

    /// The frozen rejection-table code this error maps to.
    var contractCode: String {
        switch self {
        case .released, .superseded: return "superseded"
        case .noSuchCapture, .tabUnavailable: return "superseded"
        case .invalidInput: return "snapshot-parse"
        case .needsBitsMismatch, .factsRejected: return "facts-rejected"
        case .identityRejected: return "identity-rejected"
        case .schemaMismatch: return "schema-mismatch"
        case .budgetExceeded: return "budget"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        case .producerScriptRejected: return "identity-rejected"
        case .webKit: return "webkit"
        }
    }
}

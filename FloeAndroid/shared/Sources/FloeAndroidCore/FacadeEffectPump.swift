// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — bounded operation-effect pump (`floe.effect-cursor/3`).
//
// Semantics (BRIDGE_V3_MAIN_DECISIONS.effectPoll + service-map "pump"):
// * A receipt is minted ONLY at queue acceptance and is exactly
//   `correlationID + operationReceiptID`; it claims no domain identity.
// * Outcomes for CONFIG/LAUNCH/BOOTSTRAP operations arrive here BEFORE any
//   run exists. This channel has no run/environment/job roles and never
//   impersonates the run-bound `event.poll` channel.
// * Receipt existence is bound to the CURRENT App instance: each owner
//   generation constructs a NEW pump, so an old receipt returns typed
//   `effectReceiptNotFound` after a restart and the caller reconciles against
//   the durable store instead of blind-retrying. No second durable business
//   DB is created to persist UI receipt tokens.
// * Bounded replay by sequence, per-stream caps with `resyncRequired` (never
//   silent truncation), LRU expiry of fully-read terminal streams, and no
//   fabricated effects for unknown receipts.
//
// All state is guarded by one NSLock; every method is synchronous and safe to
// call from a JNI/binder thread. No actor, SQLite or network is ever awaited
// here. This source is NOT compiled/executed by the authoring package.
import Foundation
import Crypto
import FloeCore

// MARK: - Typed result carrier (final Kotlin consumer schema, 2026-10-19)

/// Exact Foundation projection of an accepted JSON tree for the wire. Only
/// OBJECT documents are legal carriers (`value`, `page` are JsonObjects in
/// the final Kotlin consumer); booleans are stamped as NSNumber(boolean) so JSON
/// `true` never serializes as `1`.
enum RuntimeEffectDocumentProjection {
    /// A legal carrier is an OBJECT document whose scalars can actually be
    /// encoded by Foundation. Nonfinite numbers/decimals are rejected here
    /// (Foundation's JSONSerializer raises for them), so the item settles as
    /// an honest typed refusal instead of crashing at frame encode time.
    static func isValidObject(_ value: DesignJSONValue) -> Bool {
        guard case .object = value else { return false }
        return isEncodable(value)
    }

    private static func isEncodable(_ value: DesignJSONValue) -> Bool {
        switch value {
        case .null, .bool, .integer, .unsigned, .string:
            return true
        case .number(let number):
            return number.isFinite
        case .decimal(let number):
            return !number.isNaN
        case .array(let items):
            return items.allSatisfy(isEncodable)
        case .object(let pairs):
            return pairs.values.allSatisfy(isEncodable)
        }
    }

    static func foundationObject(_ value: DesignJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .integer(let number): return NSNumber(value: number)
        case .unsigned(let number): return NSNumber(value: number)
        case .decimal(let number): return NSDecimalNumber(decimal: number)
        case .number(let double): return NSNumber(value: double)
        case .string(let text): return text
        case .array(let items): return items.map(foundationObject)
        case .object(let pairs):
            var object: [String: Any] = [:]
            object.reserveCapacity(pairs.count)
            for (key, item) in pairs { object[key] = foundationObject(item) }
            return object
        }
    }
}

// MARK: - Receipt identity

/// Opaque host operation receipt: `op:v1:` + 32 lowercase hex. Logical 38
/// UTF-8 bytes, C capacity 39 — same style as the frozen gateway ingress
/// token (`int:v1:` + 32hex, logical 39/C40) but a distinct never-persisted
/// runtime namespace. ASCII, no control characters, satisfies the V3 effect
/// cursor receipt rule (non-blank, <=256, no ISO control).
public enum RuntimeOperationReceipt {
    public static let prefix = "op:v1:"
    public static let hexLength = 32
    public static let logicalBytes = 38
    public static let capacity = 39

    public static func isValid(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == logicalBytes, value.hasPrefix(prefix) else { return false }
        let hex = value[value.index(value.startIndex, offsetBy: prefix.count)...]
        guard hex.count == hexLength else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

// MARK: - Effect items

/// One bounded operation effect. `kind` is a closed vocabulary; `code` and
/// `detail` carry typed identifiers only — never paths, envelope bytes,
/// secrets or raw failure text.
public struct RuntimeEffectItem: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case accepted       // bootstrap/config operation committed successfully
        case rejected       // admission refused with typed code, no domain effect
        case failed         // attempted, real failure, typed code
        case cancelled      // proven pre-dispatch cancel (queue-only removal)
        case replaced       // owner generation retired the operation
        case closed         // mailbox shutdown settled the operation
        case resyncRequired // bounded replay lost head; walk from 0
        // VISIBLE NON-TERMINAL stages. RB1 never emits `prepared`/`started`
        // itself: those belong to later domain packages and are emitted ONLY
        // after the ORIGINAL atomic prepare/commit minted REAL identities.
        // Declaring the closed kind now keeps the wire vocabulary stable
        // without fabricating any identity here.
        case prepared
        case started

        public var isTerminal: Bool {
            switch self {
            case .accepted, .rejected, .failed, .cancelled, .replaced, .closed:
                return true
            case .prepared, .started, .resyncRequired:
                return false
            }
        }
    }

    public let sequence: Int
    public let kind: Kind
    public let code: RuntimeFacadeCode?
    public let detail: [String: String]?
    /// OPTIONAL typed page document (a JSON OBJECT) as defined by the final
    /// RB1 Kotlin consumer (`RuntimeHostCommandClient.HostEffectFrame.page`).
    /// Absent for identity-only effects, so older consumers keep the exact
    /// frozen item shape (backward-compatible optional field).
    public let page: DesignJSONValue?
    /// Declared canonical encoded size of `page` (kotlinx
    /// `JsonObject.toString()` UTF-8 bytes). Emitted ONLY with `page`.
    public let pageBytes: Int?
    /// OPTIONAL typed completed value/result document (a JSON OBJECT). The
    /// consumer prefers it over `page` for accepted terminals.
    public let value: DesignJSONValue?
    /// Declared canonical encoded size of `value`.
    public let valueBytes: Int?

    /// TRUE frame cost of this item: the LARGER of the actual wire
    /// (`JSONSerialization`, which escapes `/` as `\/`) and the canonical
    /// Kotlin-equivalent encoding. Budget selection and retention use this —
    /// the consumer re-encodes canonically and enforces its own 48 KiB page /
    /// 64 KiB frame limits, so neither encoding may undercount. `Int.max`
    /// marks a document that is not a JSON object or not serializable.
    public let encodedBytes: Int

    public init(sequence: Int, kind: Kind, code: RuntimeFacadeCode?,
                detail: [String: String]?,
                page: DesignJSONValue? = nil,
                value: DesignJSONValue? = nil) {
        self.sequence = sequence
        self.kind = kind
        self.code = code
        self.detail = detail
        self.page = page
        self.value = value
        var pageCanonical: Int? = nil
        if let page {
            guard RuntimeEffectDocumentProjection.isValidObject(page),
                  let bytes = FacadeFrameBudget.canonicalSerializedBytes(
                    RuntimeEffectDocumentProjection.foundationObject(page)) else {
                // Illegal carrier document: retain identity only and mark the
                // item un-appendable (append refuses it typed, never stores a
                // partial/oversized item).
                self.pageBytes = nil
                self.valueBytes = nil
                self.encodedBytes = Int.max
                return
            }
            pageCanonical = bytes
        }
        var valueCanonical: Int? = nil
        if let value {
            guard RuntimeEffectDocumentProjection.isValidObject(value),
                  let bytes = FacadeFrameBudget.canonicalSerializedBytes(
                    RuntimeEffectDocumentProjection.foundationObject(value)) else {
                self.pageBytes = nil
                self.valueBytes = nil
                self.encodedBytes = Int.max
                return
            }
            valueCanonical = bytes
        }
        self.pageBytes = pageCanonical
        self.valueBytes = valueCanonical
        let object = Self.jsonObject(sequence: sequence, kind: kind, code: code,
                                     detail: detail, page: page, pageBytes: pageCanonical,
                                     value: value, valueBytes: valueCanonical)
        let wire = FacadeFrameBudget.serializedBytes(object)
        let canonical = FacadeFrameBudget.canonicalSerializedBytes(object) ?? Int.max
        self.encodedBytes = max(wire, canonical)
    }

    public var jsonObject: [String: Any] {
        Self.jsonObject(sequence: sequence, kind: kind, code: code,
                        detail: detail, page: page, pageBytes: pageBytes,
                        value: value, valueBytes: valueBytes)
    }

    private static func jsonObject(sequence: Int, kind: Kind,
                                   code: RuntimeFacadeCode?,
                                   detail: [String: String]?,
                                   page: DesignJSONValue?, pageBytes: Int?,
                                   value: DesignJSONValue?, valueBytes: Int?) -> [String: Any] {
        var object: [String: Any] = ["sequence": sequence, "kind": kind.rawValue]
        if let code { object["code"] = code.rawValue }
        if let detail, !detail.isEmpty {
            object["detail"] = detail.keys.sorted().map { key in
                ["key": key, "value": detail[key] ?? ""]
            }
        }
        // Final consumer schema: optional typed OBJECT carriers with their
        // canonical declared sizes; never a stringified page in `detail`.
        if let page, let pageBytes {
            object["page"] = RuntimeEffectDocumentProjection.foundationObject(page)
            object["pageBytes"] = pageBytes
        }
        if let value, let valueBytes {
            object["value"] = RuntimeEffectDocumentProjection.foundationObject(value)
            object["valueBytes"] = valueBytes
        }
        return object
    }

    /// Terminal kinds end the stream for replay accounting.
    public var isTerminal: Bool { kind.isTerminal }
}

// MARK: - Pump

public final class FacadeEffectPump: @unchecked Sendable {

    public enum Limits {
        /// Per-stream retained effects (ring drops the OLDEST non-terminal
        /// head with an explicit resyncRequired marker, never silently).
        public static let maximumEffectsPerReceipt = 64
        /// Process-local receipts across the current App instance.
        public static let maximumLiveReceipts = 256
        /// Retired-but-recognisable window so a late poll answers
        /// `effectReceiptExpired` rather than pretending the receipt never
        /// existed.
        public static let maximumExpiredMarks = 512

        // MARK: Actual encoded-byte budgets (carrier integration, Main decision)
        // The producer ring trimmed against the raw-text estimate
        // `maximumEffectsPerReceipt * 256` = 16 KiB per receipt, which would
        // silently drop a normal 32-48 KiB typed result. The bounds below
        // replace that with ACTUAL escape-aware serialized sizes. Initial
        // tradeoff (documented for Main review): a receipt stream retains at
        // most 128 KiB of encoded effects and the whole pump at most 4 MiB.
        // An unread terminal result is NEVER trimmed away (correctness
        // first), so the pump may briefly exceed the soft 4 MiB bound while
        // saturated with unread terminals; the hard ceiling is bounded
        // receipts (256) x per-receipt bound (128 KiB + one retained
        // terminal ≤ ~48 KiB) ≈ 45 MiB process-local in the pathological
        // all-terminals-unread window, and new receipts are then refused
        // with the typed `receiptSaturated` path instead of growing further.

        /// Hard bound on one effect item's ACTUAL encoded size. Derived from
        /// the complete wire: 48 KiB page budget minus the worst-case
        /// handler wrapper, the outer exchange stamp and one separator —
        /// never an arbitrary 16 KiB cap and never a raw-text guess.
        public static let maximumItemEncodedBytes = 47_616   // 49_152 - 1_536
        /// Per-receipt retained encoded bytes (non-terminal heads ring-drop
        /// with explicit resync; the single terminal is always retained).
        public static let maximumReceiptEncodedBytes = 131_072   // 128 KiB
        /// Process-local encoded bytes retained across ALL receipt streams of
        /// this generation's pump (soft; see tradeoff above).
        public static let maximumPumpEncodedBytes = 4_194_304    // 4 MiB
        /// Sequence-digit headroom so a page selected under the append-time
        /// available-body bound always remains selectable at poll time even
        /// as cursor digits grow.
        static let sequenceDigitHeadroom = 8
    }

    public enum PollResult: Sendable {
        case notFound
        case expired
        case page(effects: [RuntimeEffectItem], nextSequence: Int,
                  hasMore: Bool, resyncRequired: Bool)
    }

    /// Typed outcome of one append (carrier integration). The Bool wrapper
    /// stays for identity-only settlement callers.
    public enum EffectAppendRefusal: Sendable, Equatable {
        case unknownOrExpiredReceipt
        case alreadyTerminal
        /// The item (including its typed payload) cannot be encoded inside
        /// the ACTUAL available effect body for this stream. Nothing was
        /// stored: the caller re-stages through `FacadeContentReader`
        /// handles or durable pages — never a silent truncate.
        case payloadTooLarge(encodedBytes: Int, availableBytes: Int)
    }

    public enum EffectAppendOutcome: Sendable, Equatable {
        case appended(sequence: Int)
        case refused(EffectAppendRefusal)

        public var isAppended: Bool { if case .appended = self { return true }; return false }
    }

    private struct Stream {
        let correlationID: String
        var effects: [RuntimeEffectItem] = []
        /// The sequence that will be assigned to the NEXT append. Starts at 1.
        var nextSequence: Int = 1
        /// True when the ring dropped a head the consumer has not read.
        var resyncRequired: Bool = false
        var terminal: Bool = false
        var readThrough: Int = 0
        var bytesRetained: Int = 0
    }

    private let lock = NSLock()
    private var streams: [String: Stream] = [:]
    private var order: [String] = []              // registration order (LRU)
    private var expiredMarks: [String] = []       // typed expiry ring
    private var mintCounter: UInt64 = 0
    private var pumpBytesRetained = 0
    private let salt: Data

    /// Bump on every owner generation; a new pump instance means old receipts
    /// are process-death-equivalent for this App instance.
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
        var random = Data(count: 16)
        for index in random.indices { random[index] = UInt8.random(in: 0...255) }
        self.salt = random
    }

    // MARK: Mint

    /// Allocate a receipt for a just-queued operation. Returns nil when the
    /// bounded registry is saturated and nothing terminal can be evicted.
    @discardableResult
    public func register(correlationID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if streams[correlationID] != nil {
            // Receipts are per operation; a live duplicate correlation is a
            // dedupe decision made by the mailbox BEFORE registration.
            return nil
        }
        var candidate: String?
        for _ in 0..<8 {
            mintCounter &+= 1
            let input = salt + Data("gen:\(generation);mint:\(mintCounter);cor:\(correlationID)".utf8)
            let hex = SHA256.hash(data: input).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
            let receipt = RuntimeOperationReceipt.prefix + hex
            if streams[receipt] == nil { candidate = receipt; break }
        }
        guard let receipt = candidate else { return nil }
        guard evictIfNeededLocked() else { return nil }
        streams[receipt] = Stream(correlationID: correlationID)
        order.append(receipt)
        return receipt
    }

    public func correlationID(for receipt: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return streams[receipt]?.correlationID
    }

    /// RB1-M3: the shutdown path must be able to tell whether an existing
    /// control receipt already carries its single terminal effect (typed
    /// failure retained-ownership) before deciding to retry.
    public func isTerminal(receipt: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams[receipt]?.terminal ?? false
    }

    // MARK: Settle

    /// Append one identity-only effect. Returns false when the receipt is
    /// unknown/expired (never fabricates a stream on late completion) or the
    /// stream is already terminal (exact-once terminal discipline).
    @discardableResult
    public func append(receipt: String, kind: RuntimeEffectItem.Kind,
                       code: RuntimeFacadeCode? = nil,
                       detail: [String: String]? = nil) -> Bool {
        append(receipt: receipt, kind: kind, code: code, detail: detail,
               page: nil, value: nil).isAppended
    }

    /// Append one effect, optionally with its typed OBJECT result carriers
    /// (`page` and/or `value` per the final Kotlin consumer schema).
    ///
    /// Carrier integration (Main decision 2026-10-19): the item's ACTUAL
    /// frame cost (max of wire-escaped and canonical Kotlin-equivalent
    /// encoded size) is measured before any state changes. An item that
    /// cannot fit the complete effect frame available for THIS stream (page
    /// budget minus the exact wrapper, the outer exchange stamp and
    /// separators, with digit headroom) is refused typed
    /// `payloadTooLarge` WITHOUT mutation — the caller re-stages through
    /// `FacadeContentReader` handles or durable pages and settles a small
    /// typed terminal instead. No silent truncation, no partial item, no
    /// raw-text estimates.
    @discardableResult
    public func append(receipt: String, kind: RuntimeEffectItem.Kind,
                       code: RuntimeFacadeCode? = nil,
                       detail: [String: String]? = nil,
                       page: DesignJSONValue?,
                       value: DesignJSONValue?) -> EffectAppendOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var stream = streams[receipt] else {
            return .refused(.unknownOrExpiredReceipt)
        }
        guard !stream.terminal else { return .refused(.alreadyTerminal) }
        let item = RuntimeEffectItem(sequence: stream.nextSequence, kind: kind,
                                     code: code, detail: detail,
                                     page: page, value: value)
        if item.encodedBytes > Limits.maximumItemEncodedBytes
            || item.encodedBytes > availableBodyBytesLocked(correlationID: stream.correlationID,
                                                            receipt: receipt,
                                                            upcomingSequence: stream.nextSequence) {
            return .refused(.payloadTooLarge(
                encodedBytes: item.encodedBytes,
                availableBytes: min(Limits.maximumItemEncodedBytes,
                                    availableBodyBytesLocked(
                                        correlationID: stream.correlationID,
                                        receipt: receipt,
                                        upcomingSequence: stream.nextSequence))))
        }
        if kind.isTerminal { stream.terminal = true }
        stream.effects.append(item)
        stream.nextSequence += 1
        stream.bytesRetained += item.encodedBytes
        pumpBytesRetained += item.encodedBytes
        trimStreamLocked(&stream)
        streams[receipt] = stream
        return .appended(sequence: item.sequence)
    }

    /// Exact available effect-body budget for one stream: the 48 KiB page
    /// budget minus the ACTUAL serialized handler frame wrapper for this
    /// correlation/receipt pair (with sequence-digit headroom), minus the
    /// outer exchange stamp margin. Shared with the poll selection so an
    /// item accepted at append time is ALWAYS selectable later.
    private func availableBodyBytesLocked(correlationID: String, receipt: String,
                                          upcomingSequence: Int) -> Int {
        // Reserve for the WORST-CASE poll-time wrapper, not just this job's
        // correlation: the effect.poll request carries an INDEPENDENT
        // correlationID (frozen V3 bound 256 bytes) and a longer wrapper
        // shrinks the body budget. An item accepted here must remain
        // selectable for every legal poll request, so a frame can never end
        // up with `hasMore=true` and a zero-progress empty page.
        let worstCaseCorrelation = String(repeating: "c", count: 256)
        let digits = max(1, upcomingSequence).description.count
            + Limits.maximumEffectsPerReceipt.description.count
            + Limits.sequenceDigitHeadroom
        return FacadeFrameBudget.effectBodyBudgetBytes(
            correlationID: worstCaseCorrelation, receipt: receipt,
            sequenceDigits: digits)
    }

    /// Public composer view of the same derivation: the ACTUAL encoded bytes
    /// a domain processor may plan for when composing a typed result page
    /// for this live receipt (Main: "expose it for domain composers"; derived
    /// from the complete wire overhead, never a fixed 16 KiB guess).
    public func availableEffectBodyBytes(receipt: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let stream = streams[receipt] else { return nil }
        return availableBodyBytesLocked(correlationID: stream.correlationID,
                                        receipt: receipt,
                                        upcomingSequence: stream.nextSequence)
    }

    /// Ring bound (carrier integration): drop the OLDEST NON-TERMINAL head
    /// with an explicit resyncRequired marker until the count and the ACTUAL
    /// encoded per-receipt bound both hold. The single terminal result is
    /// never trimmed — correctness first (documented soft overshoot).
    private func trimStreamLocked(_ stream: inout Stream) {
        while stream.effects.count > Limits.maximumEffectsPerReceipt
                || stream.bytesRetained > Limits.maximumReceiptEncodedBytes {
            guard let index = stream.effects.firstIndex(where: { !$0.isTerminal })
            else { break }   // only the retained terminal remains: keep it
            let head = stream.effects.remove(at: index)
            stream.bytesRetained -= head.encodedBytes
            pumpBytesRetained -= head.encodedBytes
            if head.sequence > stream.readThrough {
                stream.resyncRequired = true
            }
        }
    }

    // MARK: Poll (peek + acknowledge; carrier integration R-ACK)

    /// Back-compatible entry: PEEK within an unbounded body budget. It does
    /// NOT advance the read cursor any more — delivery is acknowledged only
    /// through `acknowledge(receipt:throughSequence:)` after the frame has
    /// actually been encoded and returned (Main carrier decision: "failed
    /// serialization cannot mark read").
    public func poll(receipt: String, afterSequence: Int) -> PollResult {
        peekPage(receipt: receipt, afterSequence: afterSequence,
                 bodyBudgetBytes: Int.max)
    }

    /// Bounded replay from `afterSequence` within a UTF-8 body budget
    /// (escape-aware actual serialized sizes, selection stops BEFORE the
    /// budget, never mid-item). A dropped head surfaces as a leading
    /// `resyncRequired` effect while the resync flag is set; the flag clears
    /// only on acknowledgement of a page that carried it.
    public func peekPage(receipt: String, afterSequence: Int,
                         bodyBudgetBytes: Int) -> PollResult {
        lock.lock()
        defer { lock.unlock() }
        guard let stream = streams[receipt] else {
            return expiredMarks.contains(receipt) ? .expired : .notFound
        }
        return peekLocked(stream, afterSequence: afterSequence,
                          bodyBudgetBytes: bodyBudgetBytes)
    }

    private func peekLocked(_ stream: Stream, afterSequence: Int,
                            bodyBudgetBytes: Int) -> PollResult {
        var page: [RuntimeEffectItem] = []
        var used = 0
        var resync = false
        if stream.resyncRequired,
           let earliest = stream.effects.first,
           earliest.sequence > afterSequence + 1 {
            resync = true
            let marker = RuntimeEffectItem(sequence: earliest.sequence - 1,
                                           kind: .resyncRequired,
                                           code: .resyncRequired, detail: nil)
            // The marker is always first; its bytes count against the body.
            used = marker.encodedBytes
            page.append(marker)
        }
        var nextSequence = max(afterSequence, stream.readThrough)
        var truncated = false
        for item in stream.effects where item.sequence > afterSequence {
            if item.kind == .resyncRequired { continue }
            let charge = item.encodedBytes + (page.isEmpty ? 0 : 1)
            if used + charge > bodyBudgetBytes {
                truncated = true
                break
            }
            page.append(item)
            used += charge
            nextSequence = item.sequence
        }
        let hasMore = truncated || nextSequence < stream.nextSequence - 1
        return .page(effects: page, nextSequence: nextSequence,
                     hasMore: hasMore, resyncRequired: resync)
    }

    /// Delivery acknowledgement. The ONLY path that advances `readThrough`
    /// (and thereby marks data read, releases the resync marker and permits
    /// fully-read terminal LRU eviction). A failed frame serialization never
    /// calls this, so nothing unread is ever marked read or evicted silently.
    @discardableResult
    public func acknowledge(receipt: String, throughSequence: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var stream = streams[receipt] else { return false }
        if throughSequence > stream.readThrough {
            stream.readThrough = throughSequence
        }
        if stream.resyncRequired,
           let earliest = stream.effects.first,
           stream.readThrough >= earliest.sequence - 1 {
            // The page carrying the marker was delivered: exactly-once.
            stream.resyncRequired = false
        }
        streams[receipt] = stream
        return true
    }

    // MARK: Expiry / eviction

    /// Retire the whole pump (FAILED-generation teardown / test reset).
    /// EVERY receipt — terminal or not — becomes typed-expired for a bounded
    /// diagnostic window: an old receipt can never silently read as "never
    /// existed" right after its instance went away. Production stop does NOT
    /// call this; a NEW generation instead builds a NEW pump, and old
    /// receipts honestly resolve to typed notFound there.
    public func retire() {
        lock.lock()
        defer { lock.unlock() }
        for receipt in order {
            addExpiredMarkLocked(receipt)
        }
        streams.removeAll()
        order.removeAll()
        pumpBytesRetained = 0
    }

    private func addExpiredMarkLocked(_ receipt: String) {
        expiredMarks.append(receipt)
        while expiredMarks.count > Limits.maximumExpiredMarks {
            expiredMarks.removeFirst()
        }
    }

    private func evictIfNeededLocked() -> Bool {
        // Pump-wide encoded-byte pressure: release fully-read terminal
        // streams first (LRU). Unread terminals are retained (correctness
        // first); a soft overshoot of the bound is documented in `Limits`
        // instead of silently dropping a result nobody read.
        while pumpBytesRetained > Limits.maximumPumpEncodedBytes {
            guard let index = order.firstIndex(where: {
                guard let stream = streams[$0], stream.terminal else { return false }
                return stream.readThrough >= stream.nextSequence - 1
            }) else { break }
            let receipt = order.remove(at: index)
            if let stream = streams.removeValue(forKey: receipt) {
                pumpBytesRetained -= stream.bytesRetained
            }
        }
        while order.count >= Limits.maximumLiveReceipts {
            // Evict the oldest TERMINAL stream; never a live one.
            guard let index = order.firstIndex(where: { streams[$0]?.terminal == true })
            else { return false } // all live: caller sees typed saturation
            let receipt = order.remove(at: index)
            if let stream = streams.removeValue(forKey: receipt) {
                pumpBytesRetained -= stream.bytesRetained
                if stream.readThrough < stream.nextSequence - 1 {
                    // Terminal but UNREAD to the end: typed-expired, so a late
                    // poll is honest rather than a silent notFound.
                    addExpiredMarkLocked(receipt)
                }
            }
            // Fully-read terminal streams are forgotten (notFound is true).
        }
        return true
    }

    // MARK: Retired-generation export (RB1-R1)

    /// Export ONLY terminal streams for a process-level retired-receipt route.
    /// This copies typed items; it never exposes the live stream dictionary,
    /// never resurrects a stream and never retains a database/generation.
    public func exportTerminalStreams() -> [RuntimeRetiredEffectStream] {
        lock.lock()
        defer { lock.unlock() }
        var exported: [RuntimeRetiredEffectStream] = []
        for receipt in order {
            guard let stream = streams[receipt], stream.terminal else { continue }
            exported.append(RuntimeRetiredEffectStream(
                receipt: receipt,
                correlationID: stream.correlationID,
                effects: stream.effects,
                nextSequence: stream.nextSequence))
        }
        return exported
    }

    // MARK: Stats (diagnostics; typed counters only)

    public func statsSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let live = streams.values.count
        let terminalCount = streams.values.filter { $0.terminal }.count
        return [
            "generation": generation,
            "receiptsLive": live,
            "receiptsTerminal": terminalCount,
            "expiredMarks": expiredMarks.count,
            // Typed counters only (no content): actual retained encoded bytes.
            "encodedBytesRetained": pumpBytesRetained,
        ]
    }
}

// MARK: - Retired-generation receipt routing (RB1-R1)

/// One immutable terminal stream copied out of a generation's pump after the
/// real `DatabaseManager.close()` completed. Only typed effect items are
/// retained — no owner, mailbox, database, content reader or generation.
public struct RuntimeRetiredEffectStream: Sendable, Equatable {
    public let receipt: String
    public let correlationID: String
    public let effects: [RuntimeEffectItem]
    public let nextSequence: Int

    public init(receipt: String, correlationID: String,
                effects: [RuntimeEffectItem], nextSequence: Int) {
        self.receipt = receipt
        self.correlationID = correlationID
        self.effects = effects
        self.nextSequence = nextSequence
    }
}

/// Process-lifetime, bounded, read-only routing for terminals of CLOSED or
/// FAILED generations. Accessibility is the real v3 `effect.poll` handler;
/// this type has no command submission and no mutation through the wire.
///
/// Honesty rules:
/// * only streams that already reached their single terminal are copied;
/// * unknown receipts answer `effectReceiptNotFound`; receipts evicted from
///   the bounded window answer `effectReceiptExpired` (never a fake success);
/// * a stale receipt is resolved HERE, never appended to or mixed with a new
///   generation's pump;
/// * process death drops the whole registry (same as the parent design).
public final class RuntimeRetiredEffectRegistry: @unchecked Sendable {
    public static let shared = RuntimeRetiredEffectRegistry()

    public enum Limits {
        /// At most two retired generations (the latest stop plus the previous
        /// one) so a cross-generation poll is bounded and old generations are
        /// evicted honestly.
        public static let maximumGenerations = 2
        /// Bounded terminal receipts across retained generations.
        public static let maximumStreams = 128
        /// Recognisable-but-evicted receipts (typed expired, not silent).
        public static let maximumExpiredMarks = 512
        /// Carrier integration: retired streams obey the same ACTUAL
        /// encoded-byte discipline as the live pump — the retained terminal
        /// snapshot never multiplies out into an unbounded ring. Evicting
        /// over bound answers typed `effectReceiptExpired`, never silent.
        public static let maximumRetainedEncodedBytes = 4_194_304   // 4 MiB
    }

    /// Sum of actual encoded item bytes retained for one stream.
    static func streamEncodedBytes(_ stream: RuntimeRetiredEffectStream) -> Int {
        stream.effects.reduce(0) { $0 + $1.encodedBytes }
    }

    private let lock = NSLock()
    private var generations: [UInt64: [String: RuntimeRetiredEffectStream]] = [:]
    private var order: [UInt64] = []
    private var expiredMarks: [String] = []
    /// The just-retired generation's pump stays addressable until its single
    /// anchor terminal settles (a tiny window after `generation=nil`). This
    /// closes the otherwise-observable "known receipt briefly notFound" gap.
    /// Bounded to two pumps; never retains a database/mailbox/owner.
    private var pendingPumps: [UInt64: FacadeEffectPump] = [:]
    private var pendingOrder: [UInt64] = []

    public init() {}

    /// Stage the closing generation's pump BEFORE releasing the lifecycle
    /// generation. It is removed when the anchor terminal observation
    /// completes and its terminal snapshot is retained.
    public func stagePending(generation: UInt64, effects: FacadeEffectPump) {
        lock.lock()
        pendingPumps[generation] = effects
        pendingOrder.removeAll { $0 == generation }
        pendingOrder.append(generation)
        while pendingOrder.count > Limits.maximumGenerations {
            let evicted = pendingOrder.removeFirst()
            if let pump = pendingPumps.removeValue(forKey: evicted) {
                // Preserve whatever terminal facts exist before dropping the
                // bounded staging entry; never claim a fake success.
                mergeLocked(generation: evicted,
                            streams: pump.exportTerminalStreams())
            }
        }
        lock.unlock()
    }

    /// Poll the just-closing pumps (live terminal settlement window). Nil
    /// means no staged pump knows this receipt; callers then consult the
    /// immutable retired snapshot / typed notFound.
    public func pollPending(receipt: String, afterSequence: Int)
        -> FacadeEffectPump.PollResult? {
        pollPending(receipt: receipt, afterSequence: afterSequence,
                    bodyBudgetBytes: Int.max)
    }

    /// Budget-bounded pending peek. Delivery acknowledgement is done by the
    /// binder handler via `acknowledgePending` ONLY after the complete frame
    /// was actually encoded and returned.
    public func pollPending(receipt: String, afterSequence: Int,
                            bodyBudgetBytes: Int)
        -> FacadeEffectPump.PollResult? {
        lock.lock()
        let pumps = pendingOrder.compactMap { generation -> (UInt64, FacadeEffectPump)? in
            guard let pump = pendingPumps[generation] else { return nil }
            return (generation, pump)
        }
        lock.unlock()
        for (_, pump) in pumps.reversed() {
            let result = pump.peekPage(receipt: receipt,
                                       afterSequence: afterSequence,
                                       bodyBudgetBytes: bodyBudgetBytes)
            if case .notFound = result { continue }
            return result
        }
        return nil
    }

    /// Delivery acknowledgement for the live-pending route. The binder
    /// handler calls this ONLY after the frame was actually encoded and
    /// returned, so a failed serialization never marks a staged generation's
    /// unread effects as read.
    @discardableResult
    public func acknowledgePending(receipt: String, throughSequence: Int) -> Bool {
        lock.lock()
        let pumps = pendingOrder.compactMap { pendingPumps[$0] }
        lock.unlock()
        for pump in pumps.reversed() where pump.acknowledge(receipt: receipt,
                                                            throughSequence: throughSequence) {
            return true
        }
        return false
    }

    /// Final anchor observed: the snapshot is already retained, so the
    /// pump reference is no longer needed.
    public func completePending(generation: UInt64) {
        lock.lock()
        pendingPumps.removeValue(forKey: generation)
        pendingOrder.removeAll { $0 == generation }
        lock.unlock()
    }

    /// Replace the retained terminal set for one generation. Called after the
    /// real database close (and again when the anchor terminal settles, so a
    /// late control terminal is included exactly once).
    public func retire(generation: UInt64,
                       streams: [RuntimeRetiredEffectStream]) {
        lock.lock()
        mergeLocked(generation: generation, streams: streams)
        lock.unlock()
    }

    private func mergeLocked(generation: UInt64,
                             streams: [RuntimeRetiredEffectStream]) {
        var incoming: [String: RuntimeRetiredEffectStream] = [:]
        for stream in streams where !stream.effects.isEmpty {
            // Keep only terminal-carrying streams; the exporter already
            // filtered, and this is defense in depth.
            guard stream.effects.contains(where: { $0.isTerminal }) else { continue }
            incoming[stream.receipt] = stream
        }
        let previous = generations[generation] ?? [:]
        for receipt in previous.keys where incoming[receipt] == nil {
            addExpiredMarkLocked(receipt)
        }
        generations[generation] = incoming
        order.removeAll { $0 == generation }
        order.append(generation)
        while order.count > Limits.maximumGenerations {
            let evictedGeneration = order.removeFirst()
            if let evicted = generations.removeValue(forKey: evictedGeneration) {
                for receipt in evicted.keys { addExpiredMarkLocked(receipt) }
            }
        }
        var total = generations.values.reduce(0) { $0 + $1.count }
        while total > Limits.maximumStreams, let oldest = order.first {
            guard var retained = generations[oldest] else {
                order.removeFirst()
                total = generations.values.reduce(0) { $0 + $1.count }
                continue
            }
            guard let receipt = retained.keys.sorted().first else {
                generations.removeValue(forKey: oldest)
                order.removeFirst()
                total = generations.values.reduce(0) { $0 + $1.count }
                continue
            }
            retained.removeValue(forKey: receipt)
            generations[oldest] = retained
            addExpiredMarkLocked(receipt)
            total -= 1
        }
        // Actual encoded-byte bound (carrier integration): the retained
        // terminal snapshot obeys the same byte discipline as the live pump.
        // Over-bound streams answer typed `effectReceiptExpired` later.
        var retainedBytes = generations.values.reduce(0) { partial, perGeneration in
            partial + perGeneration.values.reduce(0) {
                $0 + Self.streamEncodedBytes($1)
            }
        }
        while retainedBytes > Limits.maximumRetainedEncodedBytes,
              let oldest = order.first {
            guard var retained = generations[oldest] else {
                order.removeFirst()
                continue
            }
            guard let receipt = retained.keys.sorted().first else {
                generations.removeValue(forKey: oldest)
                order.removeAll { $0 == oldest }
                continue
            }
            if let stream = retained.removeValue(forKey: receipt) {
                retainedBytes -= Self.streamEncodedBytes(stream)
            }
            generations[oldest] = retained.isEmpty ? nil : retained
            if retained.isEmpty { order.removeAll { $0 == oldest } }
            addExpiredMarkLocked(receipt)
        }
    }

    /// Synchronous read-only poll used by the v3 `effect.poll` handler.
    /// `afterSequence` is the caller cursor; sequence numbers are preserved
    /// exactly as the owning pump emitted them.
    public func poll(receipt: String, afterSequence: Int)
        -> FacadeEffectPump.PollResult {
        poll(receipt: receipt, afterSequence: afterSequence,
             bodyBudgetBytes: Int.max)
    }

    /// Budget-bounded read-only poll over the immutable terminal snapshot.
    /// Selection stops BEFORE the ACTUAL encoded body budget (same escape-
    /// aware accounting as the live pump) and `hasMore` stays true for the
    /// remainder, so a retired near-48 KiB typed result page can never
    /// overflow the frame or be silently split away from its cursor.
    public func poll(receipt: String, afterSequence: Int, bodyBudgetBytes: Int)
        -> FacadeEffectPump.PollResult {
        lock.lock()
        defer { lock.unlock() }
        var found: RuntimeRetiredEffectStream?
        for generation in order.reversed() {
            if let stream = generations[generation]?[receipt] {
                found = stream
                break
            }
        }
        guard let stream = found else {
            return expiredMarks.contains(receipt) ? .expired : .notFound
        }
        var page: [RuntimeEffectItem] = []
        var used = 0
        var truncated = false
        for item in stream.effects where item.sequence > afterSequence {
            let charge = item.encodedBytes + (page.isEmpty ? 0 : 1)
            if used + charge > bodyBudgetBytes {
                truncated = true
                break
            }
            page.append(item)
            used += charge
        }
        let nextSequence = page.last?.sequence ?? afterSequence
        let hasMore = truncated || stream.effects.contains { $0.sequence > nextSequence }
        return .page(effects: page, nextSequence: nextSequence,
                     hasMore: hasMore, resyncRequired: false)
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations.isEmpty && pendingPumps.isEmpty
    }

    public var retainedGenerationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return generations.count
    }

    public func removeAllForTesting() {
        lock.lock()
        generations.removeAll()
        order.removeAll()
        expiredMarks.removeAll()
        pendingPumps.removeAll()
        pendingOrder.removeAll()
        lock.unlock()
    }

    private func addExpiredMarkLocked(_ receipt: String) {
        expiredMarks.append(receipt)
        while expiredMarks.count > Limits.maximumExpiredMarks {
            expiredMarks.removeFirst()
        }
    }
}

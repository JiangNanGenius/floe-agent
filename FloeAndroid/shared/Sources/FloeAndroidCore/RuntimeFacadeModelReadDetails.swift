// SPDX-License-Identifier: MPL-2.0
//
// G02 — full-row detail reads for the EXISTING `config.models.list`
// command (job-7d4d4e41017f4391; the source-proven transport gap
// MAIN_MODEL_SINGLE_ROW_READ_BUDGET_GAP_20261021.json).
// (private source candidate; NOT compiled, NOT executed here).
//
// The problem: a legal saved row is bounded at 61_440 canonical bytes
// (ProviderModelSetLimits.maximumModelRowBytes / the single config.model.
// save payload bound), but a page ITEM budget is 49_152
// (ConfigPageBudget.maximumPageItemsBytes), so one dense row can never fit
// a fresh page and the composer's typed `itemDoesNotFitPage` refusal makes
// the saved model un-reopenable. This package adds an EXPLICITLY OPTED-IN
// closed payload member on the SAME command/scope that streams that one
// original row in bounded, deterministic chunks, WITHOUT:
//  * reducing the accepted row bound, raising any payload/page/frame
//    budget, or replacing the original DB/schema 46,
//  * a second config authority, store or retained read registry,
//  * any change to LEGACY calls (a payload without `modelRead` composes
//    the byte-identical legacy page, including the unchanged
//    `itemDoesNotFitPage` refusal — an old client NEVER sees a success
//    with a silently skipped row),
//  * a new command tuple, scope or public secret seam.
//
// Wire grammar (closed, additive; RuntimeFacadeConfigBinding re-checks):
//   initial opt-in:   {"modelRead":{}}                        (+ providerID
//                     / cursor with their EXISTING meaning — the GLOBAL
//                     envelope cursor is NOT reinterpreted)
//   continuation:     {"modelRead":{"id":"<model uuid>",
//                                    "digest":"<64 lowercase hex>",
//                                    "offset":"<decimal byte offset>"}}
//                     on the SAME provider filter and the SAME row-index
//                     payload cursor.
// Response: a page document whose single row is an explicit chunk marker
//   {"modelChunk":{"id":…,"digest":…,"offset":…,"next":…|null,
//                  "total":…,"text":…}}
// with TRUTHFUL logical nextCursor/hasMore: while the row is not fully
// reconstructed the numeric row cursor stays at the row's own index (it
// advances to the NEXT logical row only in the final chunk's page). The
// offset/next/total members are strict decimal strings (the existing
// pageCursor grammar style — no numeric coercion).
//
// Consistency model (stateless, no registry): every chunk — initial or
// continuation — RE-READS the ORIGINAL current store rows through the
// unchanged `store.models(providerID:)` binding and canonically serializes
// the SAME row object the legacy page would have carried
// (ConfigModelSnapshot.jsonObject + the ACTUAL native CAS `revision`
// member). The opaque read digest is SHA-256 over those EXACT bytes
// (including the revision member). A continuation must match identity +
// provider + row index + digest + an offset on the deterministic greedy
// chunk chain, or it refuses typed (`staleRevision`) with NO chunk and NO
// mixed-snapshot bytes. The digest protects same-read CONSISTENCY, not
// permission: command admission, Root/store ownership and the original
// schema stay the only authorities. Secrets never enter this row path
// (the original row JSON is secret-free by the save-boundary rule).

import Foundation
import Crypto

// MARK: - Limits (DERIVED from the proven original bounds; nothing here
// raises a payload/page/frame budget)

enum ConfigModelReadLimits {
    /// The accepted row ceiling 61_440 canonical row bytes
    /// (ProviderModelSetLimits.maximumModelRowBytes / config.model.save)
    /// plus the bounded native `revision` member
    /// (`{"resourceID":"model.<57>","version":"<64 hex>"}` ≤ ~140 bytes)
    /// and canonical re-serialization headroom. A FIXED raw read-carrier
    /// bound; a row exceeding it is internal corruption: typed refusal,
    /// never a silently weakened bound or a partial row.
    static let maximumRawRowBytes = 65_536
    /// Max RAW UTF-8 bytes carried by one chunk `text` (Main invariant 3).
    static let maximumChunkRawBytes = 32_768
    /// A marker is ONE page item, so the EXISTING
    /// `ConfigPageBudget.maximumPageItemsBytes` measurement applies
    /// including the composer's 2-byte `"[...]"` enclosure. The chunker
    /// measures the ACTUAL canonical serialized marker (escaping and
    /// metadata included) against this — no budget changes.
    static let maximumMarkerItemBytes = ConfigPageBudget.maximumPageItemsBytes - 2
    /// Closed marker key. `ModelProfile` has no such field, so an original
    /// row NEVER carries it; App-side row decoders that did not process
    /// the marker refuse the page instead of silently skipping a row.
    static let markerKey = "modelChunk"
    /// offset/next/total are strict decimal strings (existing pageCursor
    /// grammar). 65_536 needs 5 digits; 6 admits every representable
    /// value while still refusing overflow strings early.
    static let maximumDecimalDigits = 6
    /// The opaque read digest: SHA-256 hex lowercase.
    static let digestHexLength = 64

    static func isDecimalString(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumDecimalDigits,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              !(value.count > 1 && value.hasPrefix("0")) else {
            return false
        }
        return true
    }
}

// MARK: - Closed request grammar

/// The two opt-in forms of the additive `modelRead` payload member.
/// Public only so the facade's public `listModels` can carry it; the
/// grammar itself is re-checked at the actual binding boundary.
public enum ConfigModelReadRequest: Sendable, Equatable {
    case begin
    case continuation(modelID: UUID, digest: String, offset: Int)
}

enum ConfigModelReadPayload {
    /// Parses the closed OPTIONAL `modelRead` member of the models-list
    /// payload. Absent ⇒ nil (byte-identical legacy page semantics).
    /// Malformed/unknown/coerced shapes refuse typed and are NEVER
    /// silently downgraded to a legacy page, so a truncated read can not
    /// masquerade as a complete one.
    static func parse(_ raw: Any?) throws -> ConfigModelReadRequest? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any] else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadShape")
        }
        guard !object.isEmpty else { return .begin }
        try ConfigJSON.closed(object,
                              allowed: ["id", "digest", "offset"],
                              required: ["id", "digest", "offset"],
                              context: "modelRead")
        guard let rawID = object["id"] as? String,
              let modelID = UUID(uuidString: rawID) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadID")
        }
        guard let digest = object["digest"] as? String,
              digest.count == ConfigModelReadLimits.digestHexLength,
              digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadDigest")
        }
        guard let offsetString = object["offset"] as? String,
              ConfigModelReadLimits.isDecimalString(offsetString),
              let offset = Int(offsetString) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadOffset")
        }
        return .continuation(modelID: modelID, digest: digest, offset: offset)
    }
}

// MARK: - Row detail carrier + deterministic chunk engine

/// One canonical read carrier: the EXACT bytes the legacy page would have
/// carried for the row (original ModelProfile JSON + the actual native
/// revision member), plus the opaque digest over those bytes.
struct ConfigModelRowDetail: Sendable {
    let canonicalBytes: Data
    let readDigest: String
}

enum ConfigModelRowReader {
    struct Chunk: Sendable {
        let offset: Int
        /// The exact next byte offset, or nil at EOF (final chunk).
        let next: Int?
        let total: Int
        let text: String

        func marker(rowID: String, digest: String) -> [String: Any] {
            ConfigModelRowReader.marker(rowID: rowID, digest: digest,
                                        offset: offset, next: next,
                                        total: total, text: text)
        }
    }

    /// Canonicalizes the ORIGINAL listModels row object into exact UTF-8
    /// carrier bytes and digests them. No re-encoding, no field dropping,
    /// no key reordering beyond the canonical sorted-keys rule the page
    /// composer already applies: full pricing precision, useSurfaces,
    /// nil-vs-zero capabilities, reasoning, unknown fields and the native
    /// CAS revision all survive byte-exactly.
    static func detail(of object: [String: Any]) throws -> ConfigModelRowDetail {
        guard let bytes = ConfigJSON.canonicalData(object) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadEncode")
        }
        guard bytes.count <= ConfigModelReadLimits.maximumRawRowBytes else {
            throw ConfigDomainError(code: .payloadTooLarge,
                                    reason: "modelReadCarrier\(bytes.count)")
        }
        return ConfigModelRowDetail(canonicalBytes: bytes,
                                    readDigest: ConfigJSON.sha256Hex(bytes))
    }

    /// `index` is a valid scalar boundary when it is EOF or the lead byte
    /// of a scalar (never a 0b10xxxxxx continuation byte). Truncation at a
    /// boundary is what keeps every chunk prefix valid UTF-8 without any
    /// injected U+FFFD.
    static func isScalarBoundary(_ bytes: [UInt8], _ index: Int) -> Bool {
        guard index < bytes.count else { return true }
        return (bytes[index] & 0xC0) != 0x80
    }

    static func marker(rowID: String, digest: String, offset: Int,
                       next: Int?, total: Int, text: String) -> [String: Any] {
        var chunk: [String: Any] = [
            "id": rowID,
            "digest": digest,
            "offset": String(offset),
            "total": String(total),
            "text": text,
        ]
        if let next {
            chunk["next"] = String(next)
        } else {
            chunk["next"] = NSNull()
        }
        return [ConfigModelReadLimits.markerKey: chunk]
    }

    /// Deterministic greedy chunk from `offset`: the LARGEST scalar-safe
    /// slice whose ACTUAL canonical serialized marker (escaping and
    /// metadata included) fits the existing page item budget and the raw
    /// chunk bound. Pure in (carrier bytes, rowID, digest, offset), so a
    /// stateless continuation can re-derive and validate the whole chain
    /// without any retained registry.
    static func chunk(_ detail: ConfigModelRowDetail,
                      rowID: String,
                      at offset: Int) throws -> Chunk {
        let bytes = [UInt8](detail.canonicalBytes)
        let total = bytes.count
        guard offset >= 0, offset < total else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadOffsetRange")
        }
        guard isScalarBoundary(bytes, offset) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadOffsetBoundary")
        }
        // Candidate raw end: chunk bound, snapped back to a scalar boundary.
        var end = min(total, offset + ConfigModelReadLimits.maximumChunkRawBytes)
        while end < total, !isScalarBoundary(bytes, end) { end -= 1 }
        // Escape-prefix table over [offset, end) for exact O(1) serialized
        // size candidates while shrinking (the carrier never contains raw
        // control bytes, but the table counts them defensively).
        var prefix = [Int](repeating: 0, count: max(1, end - offset + 1))
        for index in offset..<end {
            let byte = bytes[index]
            let add: Int
            if byte == 0x22 || byte == 0x5C { add = 1 }
            else if byte < 0x20 { add = 5 }
            else { add = 0 }
            prefix[index - offset + 1] = prefix[index - offset] + add
        }
        while end > offset {
            let rawLength = end - offset
            let escaped = prefix[rawLength]
            let probe = marker(rowID: rowID, digest: detail.readDigest,
                               offset: offset, next: end < total ? end : nil,
                               total: total, text: "")
            guard let probeData = ConfigJSON.canonicalData(probe) else {
                throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadProbeEncode")
            }
            let projected = probeData.count - 2 + rawLength + escaped  // -2: the empty ""
            if projected <= ConfigModelReadLimits.maximumMarkerItemBytes { break }
            // Shrink: escapes only ADD, so removing (projected - budget)
            // raw bytes is the tightest first guess; re-loop verifies.
            var candidate = end - (projected - ConfigModelReadLimits.maximumMarkerItemBytes)
            if candidate <= offset { candidate = offset + 1 }
            if candidate < end {
                end = candidate
                while end > offset, !isScalarBoundary(bytes, end) { end -= 1 }
                // The prefix table above covered the ORIGINAL end; rebuild
                // for the shrunken window (rare, still bounded by chunk
                // size).
                prefix = [Int](repeating: 0, count: max(1, end - offset + 1))
                for index in offset..<end {
                    let byte = bytes[index]
                    let add: Int
                    if byte == 0x22 || byte == 0x5C { add = 1 }
                    else if byte < 0x20 { add = 5 }
                    else { add = 0 }
                    prefix[index - offset + 1] = prefix[index - offset] + add
                }
                continue
            }
            // Progress guard: shrinking is monotonically decreasing, so
            // this branch means an unsatisfiable overhead — refuse typed.
            throw ConfigDomainError(code: .payloadTooLarge, reason: "modelReadNoProgress")
        }
        guard end > offset else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "modelReadNoProgress")
        }
        guard let text = String(bytes: Array(bytes[offset..<end]), encoding: .utf8) else {
            // Only a split scalar could reach here; the boundary snaps
            // forbid it. Fail closed rather than inject U+FFFD.
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadScalarInvariant")
        }
        let built = marker(rowID: rowID, digest: detail.readDigest,
                           offset: offset, next: end < total ? end : nil,
                           total: total, text: text)
        // Authoritative measurement on the ACTUAL serialized marker
        // (escaping and metadata included) — never trust the projection.
        guard let builtData = ConfigJSON.canonicalData(built) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadMarkerEncode")
        }
        guard builtData.count <= ConfigModelReadLimits.maximumMarkerItemBytes else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "modelReadMarkerBudget")
        }
        // Scalar-safety invariant: the decoded text re-encodes to EXACTLY
        // the sliced bytes (no normalization, no U+FFFD injection).
        guard (end - offset) == text.utf8.count else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelReadSizeInvariant")
        }
        return Chunk(offset: offset, next: end < total ? end : nil,
                     total: total, text: text)
    }

    /// Validates that `offset` lies on the deterministic greedy chain of
    /// `detail` (0 is the chain head). Gaps, replays, mid-scalar splits and
    /// out-of-order requests fail typed with NO chunk emitted.
    static func validateChainOffset(_ detail: ConfigModelRowDetail,
                                    rowID: String,
                                    offset: Int) throws {
        guard offset >= 0, offset <= ConfigModelReadLimits.maximumRawRowBytes else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadOffsetRange")
        }
        if offset == 0 { return }
        try walk(detail, rowID: rowID, target: offset)
    }

    private static func walk(_ detail: ConfigModelRowDetail,
                             rowID: String,
                             target: Int) throws {
        let bytes = [UInt8](detail.canonicalBytes)
        var offset = 0
        var hops = 0
        while offset < bytes.count {
            let step = try chunk(detail, rowID: rowID, at: offset)
            guard let next = step.next else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadOffsetOutOfOrder")
            }
            if next == target { return }
            guard next > offset,
                  ConfigModelRowReader.isScalarBoundary(bytes, next) else {
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "modelReadChainInvariant")
            }
            offset = next
            hops += 1
            if hops > 8 {
                // 64 KiB carrier / ≥24 KiB minimum scalar-safe chunk can
                // never legitimately need more; a longer walk is protocol
                // corruption, not a legal read.
                throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadChainBound")
            }
        }
        throw ConfigDomainError(code: .invalidEnvelope, reason: "modelReadOffsetOutOfOrder")
    }
}

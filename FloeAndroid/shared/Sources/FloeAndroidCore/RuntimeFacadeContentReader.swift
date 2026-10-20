// SPDX-License-Identifier: MPL-2.0
//
// P3 — Shared applicationConfiguration/content.read dispatcher (private
// source candidate; UNCOMPILED). Job job-676ec714cb334606.
//
// Authority: contract commandTable entry 22 (content.read, third matrix
// entry, label personalization) + its precedent note: the existing v3
// handler key `v3.command.applicationConfiguration.content.read` is
// SHARED between the conversations and personalization configurationScope
// entries; P3 must register/extend that existing key for BOTH labels and
// dispatch on the envelope's ACTUAL configurationScope, rejecting any
// other label BEFORE any read. The conversationLifecycle/content.read
// entry remains a SEPARATE handler key. This file COMPOSES with the other
// RB3 content reader; it never overwrites it and never becomes a generic
// bypass: handles exist only for legitimately minted producer snapshots
// (personalization.get / personalization.revision.read over real stored
// document rows; conversation handles belong to the RB3 authority).
//
// Chunk rules honored here (P3/P0 checks):
// * 32 KiB source chunk preserved (SettingsDomainV1.maximumChunkBytes);
// * the producer caps each chunk so the COMPLETE encoded response fits the
//   actual 48 KiB page budget — maxBytes is an upper bound, not a promise;
// * UTF-8 scalar-boundary safe (backward scan), byte-exact reassembly;
// * no arbitrary smaller cap, no silent truncation;
// * process-lifetime handles only: notFound{handleExpired|handleUnknown}.
//
// The byte-holder is the REAL RB1 bounded reader behind the typed port
// (PersonalizationContentStoring — HANDOFF §dependency lists the exact
// FacadeContentReader stage/read/release API it must wrap). This file owns
// NO content storage of its own.

import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime

/// RB3 conversation-scope delegate. The conversation/history lane
/// (job-6cfc13d84cf84d56) exposes its own authority; the trusted binder
/// wraps it in this port. The adapter never parses conversation payloads
/// itself: the conversations entry keeps its frozen field grammar.
public protocol ConversationContentReadDelegate: Sendable {
    /// Reads one conversations-scoped content chunk and returns the RB3
    /// lane's REAL reply as a typed JSON OBJECT document (its reply carries
    /// the binding's row identity + staged-bytes digest; the personalization
    /// branch never sees or re-shapes it). The binder converts the authority's
    /// `wireObject` with `DesignJSONValue.from(foundation:)` — the same
    /// projection the RB1 consumer uses — so no `Any` crosses an isolation
    /// boundary and no page is stringified into detail.
    func readConversationsScopedContent(payload: SettingsDomainV1.JSONValue) async throws
        -> DesignJSONValue
}

/// Dispatcher failures for the shared content.read key. Reuses the accepted
/// wire codes only.
public enum ContentReadDispatchError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    case notFound(String)
    case unsupportedOperation(String)
    case persistenceUnavailable(String?)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope: return "invalidEnvelope"
        case .notFound: return "notFound"
        case .unsupportedOperation: return "unsupportedOperation"
        case .persistenceUnavailable: return "persistenceUnavailable"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason), .notFound(let reason),
             .unsupportedOperation(let reason):
            return reason
        case .persistenceUnavailable(let reason):
            return reason
        }
    }
}

/// RuntimeFacadeContentReader — the composition point registered under the
/// SHARED `v3.command.applicationConfiguration.content.read` handler key.
/// Dispatch order (commandTable entry 22): scope routing happens BEFORE
/// any payload parsing or read, because the two configurationScope
/// grammars differ (conversations: `offset`; personalization:
/// `offsetBytes` per the P0 validator): unknown labels are rejected before
/// any read.
public actor RuntimeFacadeContentReader {
    public static let personalizationScope = "personalization"
    public static let conversationsScope = "conversations"

    private let contentStore: FacadePersonalizationContentStore
    private let conversations: (any ConversationContentReadDelegate)?

    public init(contentStore: FacadePersonalizationContentStore,
                conversations: (any ConversationContentReadDelegate)?) {
        self.contentStore = contentStore
        self.conversations = conversations
    }

    public enum Outcome: Sendable {
        /// Personalization-scope chunk: the P0 frozen ContentChunk DTO.
        case personalizationChunk(SettingsDomainV1.ContentChunk)
        /// Conversations-scope: the RB3 lane's own reply as a typed JSON
        /// object document.
        case conversationsWireObject(DesignJSONValue)
    }

    public func read(configurationScope: String?,
                     payload: SettingsDomainV1.JSONValue) async throws -> Outcome {
        switch configurationScope {
        case Self.personalizationScope:
            return .personalizationChunk(try await readPersonalization(payload: payload))
        case Self.conversationsScope:
            guard let conversations else {
                // Fail closed typed until the RB3 authority is bound — the
                // shared key NEVER fakes the other lane's reader.
                throw ContentReadDispatchError
                    .unsupportedOperation("conversationsReaderNotBound")
            }
            return .conversationsWireObject(
                try await conversations.readConversationsScopedContent(payload: payload))
        default:
            // Rejected BEFORE any read (commandTable entry 22).
            throw ContentReadDispatchError.invalidEnvelope("configurationScopeMismatch")
        }
    }

    // MARK: - Personalization branch

    private struct PersonalizationReadRequest: Sendable {
        let handle: String
        let offsetBytes: Int
        let maxBytes: Int
    }

    /// Mirrors the P0 validateContentRead grammar defensively (the binder
    /// has already run it): handle ≤256 non-control; offsetBytes ≥0;
    /// maxBytes 1..32768; ranges → invalidChunkRange; unknown keys →
    /// unknownContentField.
    private static func parseRequest(_ payload: SettingsDomainV1.JSONValue) throws
        -> PersonalizationReadRequest
    {
        guard case .object(let root) = payload else {
            throw ContentReadDispatchError.invalidEnvelope("invalidPayload")
        }
        for key in root.keys where !["handle", "offsetBytes", "maxBytes"].contains(key) {
            throw ContentReadDispatchError.invalidEnvelope("unknownContentField")
        }
        guard let handleValue = root["handle"], case .string(let handle) = handleValue,
              !handle.isEmpty, handle.count <= SettingsDomainV1.maximumHandleCharacters,
              handle.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ContentReadDispatchError.invalidEnvelope("invalidPayloadField:handle")
        }
        guard let offsetValue = root["offsetBytes"], let maxBytesValue = root["maxBytes"] else {
            throw ContentReadDispatchError.invalidEnvelope("invalidChunkRange")
        }
        guard case .integer(let rawOffset) = offsetValue,
              case .integer(let rawMax) = maxBytesValue,
              rawOffset >= 0, rawMax >= 1,
              rawMax <= Int64(SettingsDomainV1.maximumChunkBytes),
              rawOffset <= Int64.max - rawMax else {
            throw ContentReadDispatchError.invalidEnvelope("invalidChunkRange")
        }
        return PersonalizationReadRequest(handle: handle,
                                          offsetBytes: Int(rawOffset),
                                          maxBytes: Int(rawMax))
    }

    private func readPersonalization(payload: SettingsDomainV1.JSONValue) async throws
        -> SettingsDomainV1.ContentChunk
    {
        let request = try Self.parseRequest(payload)
        let binding: PersonalizationContentBinding
        switch await contentStore.lookup(handle: request.handle) {
        case .found(let stored): binding = stored
        case .expired: throw ContentReadDispatchError.notFound("handleExpired")
        case .unknown: throw ContentReadDispatchError.notFound("handleUnknown")
        }
        // Byte-exact slice from the REAL bounded reader (scalar-aligned by
        // the port contract). A handle bound in this index whose bytes the
        // port no longer knows = generation restart: honest expiry.
        let total = binding.totalBytes
        let offset = request.offsetBytes
        guard offset >= 0, offset <= total else {
            throw ContentReadDispatchError.invalidEnvelope("invalidChunkRange")
        }
        if offset == total {
            return SettingsDomainV1.ContentChunk(chunk: "", nextOffset: nil,
                                                 totalBytes: total, done: true)
        }
        guard case .slice(let sliceData, let portNextOffset, let portComplete) =
            await contentStore.read(handle: request.handle, offset: offset,
                                    maxBytes: request.maxBytes) else {
            throw ContentReadDispatchError.notFound("handleExpired")
        }
        var bytes = Array(sliceData)
        var end = portNextOffset
        var complete = portComplete
        // Escape-aware page cap: shrink WHOLE scalars from the end until
        // the complete encoded chunk response fits the actual page budget
        // (maxBytes is an upper bound; the 48 KiB budget wins — the P0
        // ContentBudget helper measures with the same JSON encoder the wire
        // uses; a scalar is never split; nothing is silently truncated).
        while true {
            // VALIDATING decode: a misaligned slice must fail typed rather
            // than be replaced with U+FFFD, which would change the returned
            // text's byte count and desynchronize nextOffset from the
            // producer's byte offsets.
            guard let text = String(bytes: bytes[0..<max(bytes.count, 0)],
                                    encoding: .utf8) else {
                throw ContentReadDispatchError.invalidEnvelope("invalidChunkRange")
            }
            let chunk = SettingsDomainV1.ContentChunk(
                chunk: text,
                nextOffset: end < total ? end : nil,
                totalBytes: total,
                done: end >= total && complete)
            if SettingsDomainV1.ContentBudget.fitsPageBudget(chunk) {
                return chunk
            }
            // Back up over ONE whole UTF-8 scalar (same backward-scan rule
            // the P0 chunk helper applies).
            guard !bytes.isEmpty else {
                throw ContentReadDispatchError.invalidEnvelope("invalidChunkRange")
            }
            var cut = bytes.count - 1
            while cut > 0, (bytes[cut] & 0xC0) == 0x80 {
                cut -= 1
            }
            // `cut` is now the lead byte index of the final scalar; the
            // shortened slice is bytes[0..<cut]. cut == 0 means the slice
            // holds a single scalar that cannot fit even alone.
            guard cut > 0 else {
                throw ContentReadDispatchError.invalidEnvelope("invalidChunkRange")
            }
            bytes = Array(bytes[0..<cut])
            end = offset + bytes.count
            complete = false
        }
    }

}


// SPDX-License-Identifier: MPL-2.0
//
// Typed domain -> RB1 result-carrier composition (memory/personalization/
// defaults/usage integration, 2026-10-20).
//
// The accepted RB1 typed carrier (`RuntimeCommandResult.value/page` +
// `RuntimeEffectItem.value/page`) carries a JSON OBJECT document, measured
// against the COMPLETE encoded frame. Domain adapters return their P0 Codable
// DTOs; this adapter is the ONE composition point that turns a completed DTO
// into that document. It exists so:
//   * no domain code serializes a page into `detail` strings, and
//   * no domain needs a second/duplicate handler registration or a private
//     carrier type, and
//   * the module keeps a single closed projection (Foundation -> the same
//     `DesignJSONValue.from(foundation:)` used by the RB1 consumer), so a
//     boolean can never degrade to 1 and null/`null` stays exact.
//
// This file adds NO command, label, schema, count or permission: it is a pure
// value encoder. A non-OBJECT document (e.g. a top-level array) is refused
// typed rather than being smuggled into a string.
import Foundation
import FloeCore

public enum FacadeDomainCarrier {
    public enum CarrierError: Error, Sendable, Equatable {
        /// The encoded document is not a JSON object; the RB1 carrier only
        /// accepts OBJECT documents (`value`/`page` are JsonObjects in the
        /// final Kotlin consumer).
        case notAnObjectDocument
        /// The DTO could not be encoded by JSONEncoder at all.
        case encodingFailed
        /// JSONSerialization could not re-read the encoder output (or the
        /// projection did not round-trip to an object).
        case notJSONCompatible
    }

    /// Encodes one completed domain DTO into the RB1 typed value document.
    /// The result is exactly what the binder attaches to
    /// `RuntimeCommandResult.value` (or `.page` for a completed read) — the
    /// effect pump then measures and carries it atomically.
    public static func encode<T: Encodable>(_ value: T) throws -> DesignJSONValue {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw CarrierError.encodingFailed
        }
        let foundation: Any
        do {
            foundation = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CarrierError.notJSONCompatible
        }
        guard foundation is [String: Any] else {
            throw CarrierError.notAnObjectDocument
        }
        let document = DesignJSONValue.from(foundation: foundation)
        guard case .object = document else {
            throw CarrierError.notJSONCompatible
        }
        return document
    }

    /// Terminal ACCEPTED result whose completed value is the typed document.
    /// Identifier-only detail may still accompany it; page content never
    /// becomes a detail string.
    public static func accepted<T: Encodable>(_ value: T,
                                              detail: [String: String]? = nil) throws
        -> RuntimeCommandResult
    {
        RuntimeCommandResult(kind: .accepted, detail: detail,
                             value: try encode(value))
    }
}

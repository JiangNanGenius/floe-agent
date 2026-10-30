// The schema is a writer gate understood by existing format-1 readers.
// Additive association fields alone cannot protect their meaning from old apps.
import Foundation

nonisolated enum CADDocumentFormatError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat(Int)
    case insufficientFormat(provided: Int, required: Int)
    case downgrade(provided: Int, stored: Int)
    case opaqueAssociations
    case malformedAssociation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version): return "This build cannot write CAD format \(version)."
        case let .insufficientFormat(provided, required): return "CAD format \(provided) cannot store this document; format \(required) is required."
        case let .downgrade(provided, stored): return "CAD format cannot decrease from \(stored) to \(provided)."
        case .opaqueAssociations: return CADDocumentFormat.opaqueReadOnlyMessage
        case .malformedAssociation(let record): return "The \(record) association payload is malformed."
        }
    }
}

nonisolated enum CADDocumentFormat {
    static let supportedVersion = 2
    static let legacyVersion = 1
    static let associativeVersion = 2
    static var opaqueReadOnlyMessage: String {
        FloeCADStrings.text("cad.document.readOnlyAssociation", "This document uses newer features. Update the app to edit it.")
    }

    nonisolated struct Assessment: Sendable {
        var requiredVersion = legacyVersion
        var opaquePlanes: Set<UUID> = []
        var opaqueSketches: Set<UUID> = []
        var isOpaqueReadOnly: Bool { !opaquePlanes.isEmpty || !opaqueSketches.isEmpty }
    }

    static func requiredFormat(document: DesignDocument) -> Int {
        document.planes.contains(where: { $0.definition != nil })
            || document.sketches.contains(where: { $0.support != nil }) ? associativeVersion : legacyVersion
    }

    /// Existing save diffs preserve unreadable legacy rows, but a new
    /// association must never be silently skipped by a try?-encode fallback.
    static func validateLiveAssociations(_ document: DesignDocument) throws {
        let encoder = JSONEncoder()
        for plane in document.planes {
            guard let definition = plane.definition else { continue }
            guard definition.semanticVersion == OffsetPlaneDefinition.supportedVersion else {
                throw CADDocumentFormatError.opaqueAssociations
            }
            _ = try encoder.encode(plane)
        }
        for sketch in document.sketches where sketch.support != nil { _ = try encoder.encode(sketch) }
    }

    /// Inspect real inline bytes, not a caller's flag. Unsupported semantics
    /// are a view-only document; malformed known associations are corruption.
    /// Legacy undecodable rows with no identifiable association keep the
    /// existing unreadable-row preservation contract.
    static func assess(planes: [CADBlobRecord], sketches: [CADBlobRecord]) throws -> Assessment {
        var result = Assessment()
        for row in planes {
            guard let object = try? JSONSerialization.jsonObject(with: row.data) as? [String: Any],
                  let definition = object["definition"], !(definition is NSNull) else { continue }
            result.requiredVersion = associativeVersion
            do {
                _ = try JSONDecoder().decode(ConstructionPlane.self, from: row.data)
            } catch let error as AssociativeGeometryError where error.requiresOpaqueReadOnlyDocument {
                // Prove the cached display portion itself is readable. Never
                // classify a broken id/plane as a supported future definition.
                _ = try cachedPlane(from: row.data)
                result.opaquePlanes.insert(row.blobID)
            } catch {
                throw CADDocumentFormatError.malformedAssociation("construction-plane")
            }
        }
        let knownSupportCases: Set<String> = ["sketch", "construction", "ground", "explicit"]
        for row in sketches {
            guard let object = try? JSONSerialization.jsonObject(with: row.data) as? [String: Any],
                  let support = object["support"], !(support is NSNull) else { continue }
            result.requiredVersion = associativeVersion
            do {
                _ = try JSONDecoder().decode(Sketch.self, from: row.data)
            } catch {
                guard let support = support as? [String: Any],
                      let source = support["source"] as? [String: Any], source.count == 1,
                      let unknown = source.keys.first, !knownSupportCases.contains(unknown),
                      source[unknown] is [String: Any] else {
                    throw CADDocumentFormatError.malformedAssociation("sketch-support")
                }
                _ = try cachedSketch(from: row.data)
                result.opaqueSketches.insert(row.blobID)
            }
        }
        return result
    }

    static func assess(_ record: CADDocumentRecord) throws -> Assessment {
        try assess(planes: record.planes, sketches: record.sketches)
    }

    static func validateWrite(_ payload: CADWritePayload, storedSchema: Int? = nil) throws {
        guard (legacyVersion...supportedVersion).contains(payload.schemaVersion) else {
            throw CADDocumentFormatError.unsupportedFormat(payload.schemaVersion)
        }
        let assessment = try assess(payload.document)
        guard !assessment.isOpaqueReadOnly else { throw CADDocumentFormatError.opaqueAssociations }
        guard payload.schemaVersion >= assessment.requiredVersion else {
            throw CADDocumentFormatError.insufficientFormat(provided: payload.schemaVersion, required: assessment.requiredVersion)
        }
        if let storedSchema {
            guard storedSchema <= supportedVersion else { throw CADDocumentFormatError.unsupportedFormat(storedSchema) }
            guard payload.schemaVersion >= storedSchema else {
                throw CADDocumentFormatError.downgrade(provided: payload.schemaVersion, stored: storedSchema)
            }
        }
    }

    /// These stripped copies are DISPLAY caches only. The original persisted
    /// rows stay byte-for-byte intact, the entire session is read-only, and no
    /// evaluator may consume them as an absolute editable replacement.
    static func cachedPlane(from data: Data) throws -> ConstructionPlane {
        try cachedValue(ConstructionPlane.self, data: data, removing: "definition")
    }
    static func cachedSketch(from data: Data) throws -> Sketch {
        try cachedValue(Sketch.self, data: data, removing: "support")
    }
    private static func cachedValue<T: Decodable>(_ type: T.Type, data: Data, removing key: String) throws -> T {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CADDocumentFormatError.malformedAssociation(key)
        }
        object.removeValue(forKey: key)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}

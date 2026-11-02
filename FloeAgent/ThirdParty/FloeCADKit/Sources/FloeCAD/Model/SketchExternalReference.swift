//
//  SketchExternalReference.swift
//  FloeCAD
//
//  M05 (associative external sketch projection) — package A: the persistent
//  value model and the pure projection adapter.
//
//  A `SketchExternalReference` links ONE sketch entity (v1: a `.line`) to ONE
//  source edge of a feature-produced body, frozen to the exact geometry
//  version (writer) the edge was minted from. During replay the resolver
//  re-projects the source edge onto the sketch's (possibly associatively
//  resolved) plane, so a source dimension edit moves the projected entity
//  through the same transactional rebuild as every other derived coordinate.
//
//  Deliberate boundaries, matching the M07 contract style:
//    * Only straight kernel edges are supported. Curved edges are skipped at
//      creation with an honest count; they are never tessellated and passed
//      off as exact curves.
//    * Resolution is identity-only: the stored `EdgeName` (the crease's
//      adjacent-face name pair + occurrence) must hit exactly one kernel edge
//      on the frozen source version. There is NO signature/nearest-edge
//      fallback that could silently re-bind a projection to a lookalike edge.
//    * `Sketch.externalReferences` is optional and omitted when empty, so a
//      legacy sketch keeps its exact stored shape. A PRESENT reference with an
//      unknown semantic version throws from `init(from:)`; the document
//      format's row assessment turns that into an opaque read-only document,
//      never a silent drop back to plain geometry.
//    * Detaching removes the reference and keeps the current entity geometry
//      as ordinary independent sketch geometry (one undoable command).
//
//  This file contains NO feature-graph replay, named-edge lookup or document
//  mutation; those belong to the resolver/service packages.
//

import Foundation
import simd

// MARK: - Errors

/// Value-level reasons an external sketch reference cannot be decoded or
/// resolved. `unsupportedVersion` is a DECODE failure (the document format
/// maps it to an opaque read-only document); the remaining cases are
/// resolution failures reported as broken references, never as a silent
/// fallback to the cached entity geometry.
nonisolated enum SketchExternalReferenceError: Error, LocalizedError, Codable, Equatable, Sendable {
    /// A reference payload has a semantic version this build cannot read.
    case unsupportedVersion(Int)
    /// The frozen source body carries no analytic B-rep to project from.
    case sourceNotExact(GeometryVersionRef)
    /// The stored crease name no longer exists on the frozen source version.
    case missingNamedEdge(GeometryVersionRef)
    /// The named edge's curve is not a straight line in this build.
    case sourceCurveUnsupported(GeometryVersionRef)
    /// The source edge projects to a degenerate (normal-parallel) segment.
    case degenerateProjection(GeometryVersionRef)
    /// The reference's own `source.body.bodyID` and frozen `sourceVersion`
    /// name different bodies — the value is internally inconsistent.
    case sourceBodyMismatch(source: BodyID, version: BodyID)
    /// A numeric input was NaN or infinite.
    case nonFiniteValue(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported external sketch reference version \(version)."
        case let .sourceNotExact(version):
            return "The frozen source body \(version.bodyID.raw.uuidString) has no analytic geometry to project from."
        case let .missingNamedEdge(version):
            return "The source edge no longer exists on body \(version.bodyID.raw.uuidString)."
        case let .sourceCurveUnsupported(version):
            return "The source edge on body \(version.bodyID.raw.uuidString) is no longer a straight edge."
        case let .degenerateProjection(version):
            return "The source edge on body \(version.bodyID.raw.uuidString) projects to a point on this sketch plane."
        case let .sourceBodyMismatch(source, version):
            return "The external reference names source body \(source.raw.uuidString) "
                + "but freezes geometry for body \(version.raw.uuidString)."
        case let .nonFiniteValue(label):
            return "\(label) is not finite."
        }
    }

    /// True only for a PRESENT reference written to a newer/other semantic
    /// contract. The load boundary catches this case, keeps the original
    /// sketch blob bytes, and opens the document opaque and read-only; it is
    /// not a broken-reference case that may keep plain geometry.
    var requiresOpaqueReadOnlyDocument: Bool {
        switch self {
        case .unsupportedVersion: return true
        default: return false
        }
    }
}

// MARK: - Reference

/// One associative external projection: sketch entity ↔ source body edge.
///
/// `entity` is the id of the driven `.line` sketch entity (the entity keeps
/// its id across re-projections, so constraints/dimensions attached to it
/// survive source edits). `sourceVersion` freezes WHICH evaluation of the
/// body the edge identity was minted from; `source` carries the stable crease
/// identity (`faceNames` is always present for v1 references — only named
/// creases are projectable — and resolution is name-only).
nonisolated struct SketchExternalReference: Codable, Equatable, Sendable {
    /// Semantic version of this reference's shape/meaning, not a body or
    /// document format version.
    static var supportedVersion: Int { 1 }

    /// Frozen with the value: a re-source or version upgrade constructs a new
    /// reference rather than mutating this one in place.
    let version: Int
    /// The sketch entity this reference drives.
    let entity: UUID
    /// Frozen source geometry version (body + writer).
    let sourceVersion: GeometryVersionRef
    /// Stable source edge identity (signature is diagnostic only; resolution
    /// binds by `faceNames`, never by geometric resemblance).
    let source: EdgeRef

    init(
        version: Int = SketchExternalReference.supportedVersion,
        entity: UUID,
        sourceVersion: GeometryVersionRef,
        source: EdgeRef
    ) {
        self.version = version
        self.entity = entity
        self.sourceVersion = sourceVersion
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case version, entity, sourceVersion, source
    }

    /// Decode the semantic version FIRST, so a future payload is reported as
    /// an unsupported version even when its other fields no longer match this
    /// build's shape. A present but unreadable reference never decodes to a
    /// value a caller could mistake for plain geometry.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw SketchExternalReferenceError.unsupportedVersion(version)
        }
        self.version = version
        entity = try container.decode(UUID.self, forKey: .entity)
        sourceVersion = try container.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        source = try container.decode(EdgeRef.self, forKey: .source)
    }

    /// A known-version reference can still be internally inconsistent. Those
    /// are resolution failures reported as broken references, not decode
    /// failures.
    func validate() throws {
        guard version == Self.supportedVersion else {
            throw SketchExternalReferenceError.unsupportedVersion(version)
        }
        guard source.body.bodyID == sourceVersion.bodyID else {
            throw SketchExternalReferenceError.sourceBodyMismatch(
                source: source.body.bodyID, version: sourceVersion.bodyID)
        }
        guard source.faceNames != nil else {
            throw SketchExternalReferenceError.missingNamedEdge(sourceVersion)
        }
    }
}

// MARK: - Pure projection adapter

/// The one geometric question this package answers: where does the source
/// edge's straight segment land on the sketch plane, in plane-local
/// coordinates? Callers supply the CURRENT source segment (world space) from
/// the frozen geometry version; the cached sketch entity is never an input.
nonisolated enum ExternalSketchProjection {

    private static let lengthEpsilon = 1e-5

    /// Project one straight world-space segment onto `plane` along its
    /// normal. Nil when the segment is parallel to the plane normal (it
    /// projects to a point) — a degenerate projection is refused, never
    /// emitted as a zero-length line.
    static func project(
        worldA: SIMD3<Double>,
        worldB: SIMD3<Double>,
        onto plane: SketchPlane
    ) -> (SIMD2<Double>, SIMD2<Double>)? {
        let a = plane.toLocal(worldA)
        let b = plane.toLocal(worldB)
        guard simd_length(b - a) > lengthEpsilon else { return nil }
        return (a, b)
    }
}

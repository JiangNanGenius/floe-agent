// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

/// Canonical JSON export with a SHA-256 source identity.
///
/// The source hash covers the COMPLETE request — mesh, material with provenance,
/// every load and boundary condition, tolerance and budget — so two runs over
/// byte-identical requests share one identity. Root's outer archive hash wraps
/// this payload; this inner hash binds the engineering inputs themselves.
/// Wall-clock timing is excluded everywhere (never encoded, never hashed).
public enum EngineeringExport {
    public static let formatVersion = 1
    public static let generator = "FloeEngineeringCore R5 (predevelopment 2026-11-05)"

    /// Deterministic JSON encoder: sorted keys, no fragment leakage.
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// SHA-256 hex digest of the canonical encoding of any Codable value.
    public static func canonicalHash<T: Encodable>(of value: T) throws -> String {
        let data = try canonicalEncoder().encode(value)
        return sha256Hex(data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A persisted engineering session: request + results + provenance + the
    /// explicit unsupported-domain ledger. Codable both ways.
    public struct SessionRecord: Codable, Sendable {
        public var formatVersion: Int
        public var generator: String
        public var study: EngineeringStudy
        public var structuralResult: StructuralResult?
        public var thermalResult: ThermalResult?
        public var manufacturability: ManufacturabilityReport?
        /// SHA-256 over the canonical encoding of `study` (all inputs).
        public var studySourceHash: String
        /// SHA-256 over this record's identity-bearing fields
        /// (study + results, excluding this digest itself and timing).
        public var recordHash: String
        public var unsupportedDomains: [String]
        public var materialProvenance: [String]
        public var solverProvenance: String

        public init(study: EngineeringStudy,
                    structuralResult: StructuralResult? = nil,
                    thermalResult: ThermalResult? = nil,
                    manufacturability: ManufacturabilityReport? = nil) throws {
            self.formatVersion = EngineeringExport.formatVersion
            self.generator = EngineeringExport.generator
            self.study = study
            self.structuralResult = structuralResult
            self.thermalResult = thermalResult
            self.manufacturability = manufacturability
            self.studySourceHash = try EngineeringExport.canonicalHash(of: study)
            self.unsupportedDomains = EngineeringUnsupported.ledger.map { $0.rawValue }
            self.materialProvenance = [study.material.provenance]
            self.solverProvenance = SolverProvenance.summary
            // Initialize the digest field before copying so the value copy below
            // is fully initialized at all times.
            self.recordHash = ""
            let copy = self
            self.recordHash = try EngineeringExport.canonicalHash(of: copy)
        }
    }

    /// Encodes a session record to canonical JSON bytes (sorted keys).
    public static func encode(_ record: SessionRecord) throws -> Data {
        try canonicalEncoder().encode(record)
    }

    /// Decodes a session record previously written by `encode`.
    public static func decode(_ data: Data) throws -> SessionRecord {
        try JSONDecoder().decode(SessionRecord.self, from: data)
    }
}

/// Solver provenance, recorded in every export.
public enum SolverProvenance {
    public static let method = "4-node linear tetrahedron (constant strain/stress), isotropic linear elasticity; steady isotropic heat conduction; symmetric sparse assembly; preconditioned conjugate gradient with diagonal (Jacobi) preconditioner; convergence judged on residual norm"

    public static let references = [
        "Hughes, T.J.R., The Finite Element Method: Linear Static and Dynamic Finite Element Analysis, Dover 2000 (ch. 3 linear elasticity, ch. 4 heat conduction)",
        "Bathe, K.-J., Finite Element Procedures, 2nd ed., 2014 (tetrahedral elements; conjugate gradient with preconditioning)",
        "Zienkiewicz, Taylor, Zhu, The Finite Element Method, 7th ed., 2013 (patch test, ch. 9)",
        "Kienzle, O. & Victor, H., 'Spezifische Schnittkräfte bei der Metallbearbeitung', Werkstattstechnik 47 (1957) (cutting force estimate form)",
    ]

    public static let summary = method + ". References: " + references.joined(separator: "; ") + ". Predevelopment implementation; not a certified engineering solver."
}

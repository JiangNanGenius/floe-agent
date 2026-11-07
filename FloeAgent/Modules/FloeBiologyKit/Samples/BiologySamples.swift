// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

/// Small, offline inputs for the independent workbench. Synthetic fixtures are
/// explicitly labelled and are never presented as biological observations.
public enum BiologySampleID: String, CaseIterable, Identifiable, Sendable {
    case ubiquitinPDB = "1ubq.pdb"
    case ubiquitinMMCIF = "1ubq.cif"
    case sequenceComparison = "synthetic-dna.fasta"
    case expressionCounts = "synthetic-counts.csv"
    case microscopy = "synthetic-microscopy.json"
    case microscopyPGM = "synthetic-microscopy.pgm"
    case reactionNetwork = "synthetic-network.json"

    public var id: String { rawValue }
}

public struct BiologySampleProvenance: Codable, Sendable, Equatable {
    public let file: String
    public let title: String
    public let sha256: String
    public let bytes: Int
    public let origin: String
    public let license: String
}

public enum BiologySampleError: Error, LocalizedError {
    case missingResource(String), invalidManifest, integrityFailure(String)
    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "Sample resource is unavailable: \(name)"
        case .invalidManifest: "The sample provenance manifest is invalid."
        case .integrityFailure(let name): "Sample integrity verification failed: \(name)"
        }
    }
}

public enum BiologySamples {
    private struct Manifest: Decodable {
        let schema: String
        let entries: [BiologySampleProvenance]
    }

    public static func provenance(for sample: BiologySampleID) throws -> BiologySampleProvenance {
        guard let url = Bundle.module.url(forResource: "sample-index", withExtension: "json") else {
            throw BiologySampleError.missingResource("sample-index.json")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536 else {
            throw BiologySampleError.invalidManifest
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schema == "floe.biology.samples.v1",
              manifest.entries.count == BiologySampleID.allCases.count,
              Set(manifest.entries.map(\.file)).count == manifest.entries.count,
              Set(manifest.entries.map(\.file)) == Set(BiologySampleID.allCases.map(\.rawValue)),
              let entry = manifest.entries.first(where: { $0.file == sample.rawValue }),
              entry.bytes > 0, entry.bytes <= 2_097_152,
              entry.sha256.count == 64 else { throw BiologySampleError.invalidManifest }
        return entry
    }

    public static func data(for sample: BiologySampleID) throws -> Data {
        let entry = try provenance(for: sample)
        guard let url = Bundle.module.url(forResource: sample.rawValue, withExtension: nil) else {
            throw BiologySampleError.missingResource(sample.rawValue)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == entry.bytes else {
            throw BiologySampleError.integrityFailure(sample.rawValue)
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else { throw BiologySampleError.integrityFailure(sample.rawValue) }
        return data
    }
}

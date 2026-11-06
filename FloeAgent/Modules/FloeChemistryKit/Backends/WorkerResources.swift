import Foundation
import CryptoKit

public struct BundledChemistryWorkerManifest: Codable, Sendable {
    public let protocolVersion: Int
    public let files: [String: String]
}

/// Immutable trusted resources only. Installation and execution belong to the resolved host environment.
public enum BundledChemistryWorkerFiles {
    private static let names: Set<String> = [
        "chemistry_worker.py", "science_worker.py", "quantum_worker.py",
        "requirements-rdkit.txt", "requirements-science.txt"
    ]
    public static func load() throws -> [String: Data] {
        guard let url = Bundle.module.url(forResource: "WorkerManifest", withExtension: "json") else { throw ResourceError.missing }
        let data = try Data(contentsOf: url)
        guard data.count <= 16384 else { throw ResourceError.invalid }
        let manifest = try JSONDecoder().decode(BundledChemistryWorkerManifest.self, from: data)
        guard manifest.protocolVersion == 1, Set(manifest.files.keys) == names else { throw ResourceError.invalid }
        var files = ["WorkerManifest.json": data]
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else { throw ResourceError.missing }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 1024 * 1024,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.files[name] else {
                throw ResourceError.invalid
            }
            files[name] = bytes
        }
        return files
    }
    private enum ResourceError: Error, LocalizedError {
        case missing, invalid
        var errorDescription: String? {
            switch self {
            case .missing: "Bundled chemistry worker resources are missing."
            case .invalid: "Bundled chemistry worker resources failed verification."
            }
        }
    }
}

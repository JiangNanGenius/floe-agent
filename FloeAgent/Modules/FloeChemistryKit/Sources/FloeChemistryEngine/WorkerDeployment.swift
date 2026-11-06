import Foundation
import FloeChemistryWorkerResources

public enum ChemistryWorkerDeployment {
    public static let protocolVersion = 1
    /// The host stages these exact bytes through its existing environment/jobs lifecycle.
    /// No developer interpreter paths, credentials, package installs or process launches are embedded.
    public static func files() throws -> [String: Data] { try BundledChemistryWorkerFiles.load() }
    public static func digests() throws -> [String: String] {
        guard let manifest = try files()["WorkerManifest.json"] else { return [:] }
        return try JSONDecoder().decode(BundledChemistryWorkerManifest.self, from: manifest).files
    }
}

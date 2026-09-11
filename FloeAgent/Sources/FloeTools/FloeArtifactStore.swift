import Foundation
import FloeCore

/// App-owned artifact namespaces under `<Application Support>/FloeAgent`.
/// Five resolvers previously maintained their own allow-lists, size caps and
/// digest rules; this is the single registry so a namespace added here is
/// readable everywhere.
public enum ArtifactNamespace: String, CaseIterable, Sendable {
    case attachments = "Attachments"
    case generatedImages = "GeneratedImages"
    case browser = "BrowserArtifacts"
    case vnc = "VNCArtifacts"
    case presentation = "PresentationArtifacts"
    case change = "ChangeArtifacts"
    case jobDownloads = "JobDownloads"
}

/// Resolves and verifies app-storage artifact references produced by tools
/// (`GeneratedImages/<uuid>.png`, `BrowserArtifacts/...`). Tool results and
/// cards hand these paths to the model and UI, so every reader must apply the
/// same containment, secret and digest policy.
public enum FloeArtifactStore {
    public static func root() throws -> URL {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw FloeError.storageCorrupted("Application Support directory is unavailable")
        }
        return support.appendingPathComponent("FloeAgent", isDirectory: true)
    }

    /// Resolves an app-storage artifact path. `root` is injectable for tests.
    public static func resolve(
        _ relativePath: String,
        allowed: Set<ArtifactNamespace>,
        maxBytes: Int,
        expectedSHA256: String? = nil,
        root: URL? = nil
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw FloeError.validationFailed("Artifact path must be app-storage relative")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2, components.allSatisfy({ $0 != ".." && $0 != "." }),
              let namespace = ArtifactNamespace(rawValue: components[0]),
              allowed.contains(namespace) else {
            throw FloeError.validationFailed("Artifact path is outside the allowed namespaces")
        }
        let base = try root ?? Self.root()
        let resolved = components.reduce(base) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL.resolvingSymlinksInPath()
        let allowedRoot = base.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path == allowedRoot || resolved.path.hasPrefix(allowedRoot + "/") else {
            throw FloeError.validationFailed("Artifact path escapes the artifact store")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FloeError.notFound("Artifact file does not exist: \(relativePath)")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        guard let size = attributes?[.size] as? Int, size <= maxBytes else {
            throw FloeError.validationFailed("Artifact exceeds the \(maxBytes)-byte limit")
        }
        if let expectedSHA256 {
            let actual = try Digest.sha256Hex(ofFileAt: resolved)
            guard actual == expectedSHA256.lowercased() else {
                throw FloeError.validationFailed("Artifact digest changed since it was produced; regenerate it")
            }
        }
        return resolved
    }

    /// Resolves, verifies and loads an artifact in one step.
    public static func verifiedData(
        _ relativePath: String,
        allowed: Set<ArtifactNamespace>,
        maxBytes: Int,
        expectedSHA256: String? = nil,
        root: URL? = nil
    ) throws -> Data {
        let url = try resolve(
            relativePath,
            allowed: allowed,
            maxBytes: maxBytes,
            expectedSHA256: expectedSHA256,
            root: root
        )
        return try Data(floeContentsOf: url, options: [.mappedIfSafe])
    }
}

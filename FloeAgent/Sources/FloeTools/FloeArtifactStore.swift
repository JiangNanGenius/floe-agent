import Foundation
import FloeCore
import FloeModels

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
    /// Design-revision payloads, stored content-addressed under the existing
    /// artifact authority (never a parallel material library).
    case designRevisions = "DesignRevisions"
    /// Stable per-run user-output snapshots (`RunOutputs/<runID>/<outputID>/
    /// <basename>`). Owned by `RunOutputSnapshotStore`; bytes are frozen at
    /// publication and validated again at retrieval. This namespace is the
    /// only path a `RunOutputFile` receipt may ever reference.
    case runOutputs = "RunOutputs"
}

/// Resolves and verifies app-storage artifact references produced by tools
/// (`GeneratedImages/<uuid>.png`, `BrowserArtifacts/...`). Tool results and
/// cards hand these paths to the model and UI, so every reader must apply the
/// same containment, secret and digest policy.
public enum FloeArtifactStore {
    /// Freeze a successful tool's unified diff in the existing run-owned
    /// change namespace. The host may supply its own private artifact root.
    public static func storeChangeDiff(_ diff: String, runID: UUID, root: URL? = nil) throws -> ToolArtifactReference? {
        let bytes = Data(diff.utf8)
        guard !bytes.isEmpty, bytes.count <= 512 * 1024 else { return nil }
        let base = try (root ?? Self.root()).standardizedFileURL.resolvingSymlinksInPath()
        let folder = "\(ArtifactNamespace.change.rawValue)/\(runID.uuidString)"
        let directory = base.appendingPathComponent(folder, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw FloeError.validationFailed("Change artifact directory is unavailable")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let hash = FloeDigest.sha256Hex(bytes)
        let relative = "\(folder)/\(hash).diff"
        let url = base.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try resolve(relative, allowed: [.change], maxBytes: bytes.count, expectedSHA256: hash, root: base)
        } else {
            try bytes.write(to: url, options: [.atomic])
        }
        return ToolArtifactReference(id: UUID(), relativePath: relative, mimeType: "text/x-diff", byteCount: bytes.count, sha256: hash)
    }

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
            let actual = try FloeDigest.sha256Hex(ofFileAt: resolved)
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

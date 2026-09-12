// FloeApp — Signed skill-hub catalog access for media models.
// Downloads catalog.json + catalog.sig, verifies the Ed25519 signature with
// the app's pinned trust root, and exposes the verified model list to
// `media.models` and `media.capabilities`.

import Foundation
import Crypto
import FloeCore
import FloeMedia
import FloeSkills

actor MediaModelCatalogService {
    static let shared = MediaModelCatalogService()

    private var cached: ModelArtifactCatalog?
    private var lastRefresh: Date?
    private var catalogURL: URL?
    private var boundStore: ModelArtifactStore?

    func configure(catalogURL: URL?) {
        self.catalogURL = catalogURL
    }

    func bind(store: ModelArtifactStore) {
        boundStore = store
    }

    /// Returns the last verified catalog, refreshing at most once per hour.
    func catalog(forceRefresh: Bool = false) async -> ModelArtifactCatalog? {
        if !forceRefresh, let cached, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 3600 {
            return cached
        }
        guard let catalogURL else { return cached }
        do {
            let catalogData = try await fetch(catalogURL)
            let signatureData = try await fetch(catalogURL.appendingPathExtension("sig"))
            guard try verify(catalogData: catalogData, signatureData: signatureData) else {
                FloeLogger(category: .tools).error("modelCatalogSignatureInvalid")
                return cached
            }
            let parsed = try parse(catalogData: catalogData)
            cached = parsed
            lastRefresh = Date()
            return parsed
        } catch {
            FloeLogger(category: .tools).error("modelCatalogRefreshFailed error=\(error.localizedDescription)")
            return cached
        }
    }

    func report() async -> (installed: [MediaCapabilities.Model], available: [MediaCapabilities.Model]) {
        let catalog = await catalog()
        let installedIDs: Set<String>
        if let boundStore {
            installedIDs = Set(await boundStore.installed().map(\.id))
        } else {
            installedIDs = []
        }
        let installed = (catalog?.models ?? []).filter { installedIDs.contains($0.id) }.map {
            MediaCapabilities.Model(id: $0.id, capability: $0.capability, installed: true, kind: $0.kind, license: $0.license)
        }
        let available = (catalog?.models ?? []).filter { !installedIDs.contains($0.id) }.map {
            MediaCapabilities.Model(id: $0.id, capability: $0.capability, installed: false, kind: $0.kind, license: $0.license)
        }
        return (installed, available)
    }

    private func parse(catalogData: Data) throws -> ModelArtifactCatalog {
        struct Envelope: Decodable {
            var schemaVersion: Int?
            var models: [ModelArtifact]?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: catalogData)
        return ModelArtifactCatalog(
            models: envelope.models ?? [],
            catalogSHA256: FloeDigest.sha256Hex(catalogData)
        )
    }

    private func verify(catalogData: Data, signatureData: Data) throws -> Bool {
        struct SignatureEnvelope: Decodable {
            var keyID: String
            var signature: String
        }
        let envelope = try JSONDecoder().decode(SignatureEnvelope.self, from: signatureData)
        guard let keyData = OfficialSkillHub.trustedKeys[envelope.keyID],
              let signatureBytes = Data(base64Encoded: envelope.signature),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureBytes, for: catalogData)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let service = HTTPRequestService()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-hub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await service.download(url: url, timeout: 120, maxBytes: 8 * 1024 * 1024, to: temporary)
        return try Data(floeContentsOf: temporary)
    }
}

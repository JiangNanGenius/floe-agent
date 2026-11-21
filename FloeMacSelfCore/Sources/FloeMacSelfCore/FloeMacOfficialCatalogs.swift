// SPDX-License-Identifier: MPL-2.0

import FloeProviders
import FloeSkills
import Foundation

/// Fetches only the two declarative catalog packages used by Settings. The
/// shared engine verifies the signed feed and atomically activates the payload.
public actor FloeMacOfficialCatalogs {
    public enum Catalog: Sendable {
        case models, webSearch

        var packageID: String {
            switch self {
            case .models: "floe.providers.compatibility"
            case .webSearch: "floe.search.providers"
            }
        }

        var fileName: String {
            switch self {
            case .models: "ProviderCatalog.json"
            case .webSearch: "SearchProviderCatalog.json"
            }
        }

        // These are the built-in content versions used by the iPad app.
        var bundledVersion: String {
            switch self {
            case .models: "1.1.5"
            case .webSearch: "1.3.0"
            }
        }
    }

    public enum Failure: Error {
        case badResponse, invalidFeed, missingCatalog, blockedUpdate
    }

    private let root: URL
    private let appVersion: String
    private let session = ASRTransportSecurity.makeHTTPSession()
    private var store: ContentUpdateStore?

    public init(root: URL, appVersion: String) {
        self.root = root
        self.appVersion = appVersion
    }

    private func contentStore() throws -> ContentUpdateStore {
        if let store { return store }
        let store = try ContentUpdateStore(root: root)
        self.store = store
        return store
    }

    public func active(_ catalog: Catalog) async throws -> Data? {
        let store = try contentStore()
        guard let installed = await store.currentState().entries[catalog.packageID],
              try SignedContentVersion(installed.entry.version) >= SignedContentVersion(catalog.bundledVersion)
        else { return nil }
        return try await store.file(id: catalog.packageID, relativePath: catalog.fileName)
    }

    public func refresh(_ catalog: Catalog, validate: @escaping @Sendable (Data) throws -> Void) async throws -> Data? {
        let store = try contentStore()
        let owner = OfficialContentHub.owner
        let repository = OfficialContentHub.repository
        let identity = URL(string: "https://api.github.com/repos")!
            .appendingPathComponent(owner).appendingPathComponent(repository).appendingPathComponent("git/ref/heads/main")
        struct Ref: Decodable {
            struct Object: Decodable { var sha: String }
            var object: Object
        }
        let revision = try JSONDecoder().decode(Ref.self, from: await bytes(identity, limit: 16 * 1024)).object.sha
        guard revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw Failure.invalidFeed }
        let publication = URL(string: "https://raw.githubusercontent.com")!
            .appendingPathComponent(owner).appendingPathComponent(repository).appendingPathComponent(revision)
        async let index = bytes(publication.appendingPathComponent(OfficialContentHub.indexPath),
                                limit: SignedContentFeedVerifier.maximumFeedBytes)
        async let signature = bytes(publication.appendingPathComponent(OfficialContentHub.signaturePath), limit: 4096)
        let feed = try await store.verifyFeed(index: index, signature: signature, trustedKeys: OfficialSkillHub.trustedKeys)
        guard let entry = feed.entries.first(where: { $0.id == catalog.packageID }), entry.kind == .providers,
              !entry.containsScripts, entry.dependencies.isEmpty, entry.requiredCapabilities.isEmpty else {
            throw Failure.missingCatalog
        }
        guard try SignedContentVersion(entry.version) >= SignedContentVersion(catalog.bundledVersion) else {
            return try await active(catalog)
        }
        guard let decision = try await store.plan(feed: feed, appVersion: appVersion).items[catalog.packageID]?.decision else {
            throw Failure.missingCatalog
        }
        switch decision {
        case .upToDate: return try await active(catalog)
        case .blocked: throw Failure.blockedUpdate
        case .update: break
        }
        let archive = try await bytes(publication.appendingPathComponent(entry.path), limit: entry.size)
        try Task.checkCancellation()
        try await store.commit([.init(entry: entry, zip: archive)], appVersion: appVersion, allowedCapabilities: []) { _, files in
            guard let data = files[catalog.fileName] else { throw Failure.missingCatalog }
            try validate(data)
        }
        return try await active(catalog)
    }

    private func bytes(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Floe-Agent", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await BoundedHTTP.data(for: request, session: session, maxBytes: limit)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let effective = response.url, ASRTransportSecurity.sameOrigin(effective, url) else { throw Failure.badResponse }
        return data
    }
}

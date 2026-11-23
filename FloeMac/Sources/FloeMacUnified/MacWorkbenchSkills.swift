// SPDX-License-Identifier: MPL-2.0
//
// Task-scoped Skills for the Floe Mac workbench.
//
// This file provides the public service, facades and tool hooks for the
// macOS-original signed skill catalog on the native Mac app:
//
// - Catalog: the EXISTING signed `MacOriginalSkillCatalog` verifier
//   (FloeSkills) over a pinned floe-skill-hub publication, with a local
//   snapshot so installed items stay manageable offline. Refreshing the
//   snapshot is an explicit user action on the public anonymous routes.
// - Store: the EXISTING shared model (`PersistedSkill`) through a narrow
//   facade the coordinator satisfies with the runtime DB-owner adapter. This
//   file never instantiates a second/conflicting store.
// - Task context: an installed+enabled skill becomes readable in a task via
//   the EXISTING `skill.list` / `skill.search` / `skill.read` / `skill.manage`
//   tools (wired in `MacWorkbenchExtensionTools`) plus a runtime scope value
//   the coordinator feeds into the run configuration (`activeSkillIDs` and
//   the run's skill instructions), mirroring the iPad `RuntimeSelection`.
// - Authority: adds go through the existing approval chain
//   (`skill.install source="hub"` → `SkillHubInstalling` with the real
//   runtime-issued `ToolContext`); the UI path performs the identical
//   verified commit for an explicit user tap. No model output is trusted,
//   no capability is granted beyond the declared (empty) ceiling, and the
//   official publication ledger enforces immutable released versions.
//
// English and Simplified Chinese stay aligned; copy lives in the views.

import Foundation
import Combine
import Crypto
import FloeCore
import FloePersistence
import FloeProviders
import FloeSkills
import FloeTools

// MARK: - Verified signed catalog snapshot

/// One verified catalog snapshot: the signed feed itself plus the transport
/// identities that carried it. All fields are produced by
/// `MacOriginalSkillCatalog.verified` and the snapshot commit resolution —
/// never by model output.
public struct MacWorkbenchSignedCatalog: Sendable {
    public let feed: MacOriginalSkillCatalog
    public let publicationCommit: String
    public let catalogDigest: String
    public let signatureKeyID: String?

    public init(feed: MacOriginalSkillCatalog, publicationCommit: String, catalogDigest: String, signatureKeyID: String?) {
        self.feed = feed
        self.publicationCommit = publicationCommit
        self.catalogDigest = catalogDigest
        self.signatureKeyID = signatureKeyID
    }
}

// MARK: - Store facade (coordinator-satisfied)

/// The narrow persistence seam the workbench needs from the runtime DB-owner
/// adapter. `SQLiteSkillStore` (FloePersistence) already implements every
/// requirement; `MacWorkbenchSkillStoreAdapter` adapts it without a second
/// store instance, and the coordinator may substitute its own adapter.
public protocol MacWorkbenchSkillStore: Sendable {
    func all() async throws -> [PersistedSkill]
    func skill(id: String) async throws -> PersistedSkill?
    func save(_ skill: PersistedSkill, grantCapabilities: [String],
              officialPublication: OfficialSkillPublicationRecord?) async throws
    func setEnabled(_ enabled: Bool, id: String, expectedDigest: String?) async throws
    func remove(id: String, expectedDigest: String?) async throws
    func wasExplicitlyRemoved(id: String) async throws -> Bool
}

/// Adapter over the EXISTING shared `SQLiteSkillStore`. This composes the
/// runtime-owned store; it never opens its own database or schema.
public struct MacWorkbenchSkillStoreAdapter: MacWorkbenchSkillStore {
    private let store: SQLiteSkillStore
    public init(_ store: SQLiteSkillStore) { self.store = store }

    public func all() async throws -> [PersistedSkill] { try await store.all() }
    public func skill(id: String) async throws -> PersistedSkill? { try await store.skill(id: id) }
    public func save(_ skill: PersistedSkill, grantCapabilities: [String],
                     officialPublication: OfficialSkillPublicationRecord?) async throws {
        try await store.save(skill, grantCapabilities: grantCapabilities,
                             officialPublication: officialPublication)
    }
    public func setEnabled(_ enabled: Bool, id: String, expectedDigest: String?) async throws {
        try await store.setEnabled(enabled, id: id, expectedDigest: expectedDigest)
    }
    public func remove(id: String, expectedDigest: String?) async throws {
        try await store.remove(id: id, expectedDigest: expectedDigest)
    }
    public func wasExplicitlyRemoved(id: String) async throws -> Bool {
        try await store.wasExplicitlyRemoved(id: id)
    }
}

// MARK: - Catalog source

/// Bounded anonymous byte fetch for the signed catalog channel. The default
/// implementation uses an ephemeral session, enforces byte limits and
/// requires the response origin to equal the request origin (no redirect
/// trust expansion), mirroring `FloeMacOfficialCatalogs`.
public protocol MacWorkbenchCatalogFetching: Sendable {
    func bytes(at url: URL, limit: Int) async throws -> Data
}

public enum MacWorkbenchCatalogFetchError: Error, Equatable, Sendable, LocalizedError {
    case badResponse
    public var errorDescription: String? { "The catalog download failed or was redirected." }
}

public struct MacWorkbenchAnonymousCatalogFetcher: MacWorkbenchCatalogFetching {
    private let session: URLSession
    public init(session: URLSession = ASRTransportSecurity.makeHTTPSession()) {
        self.session = session
    }

    public func bytes(at url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Floe-Agent", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await BoundedHTTP.data(for: request, session: session, maxBytes: limit)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let effective = response.url, ASRTransportSecurity.sameOrigin(effective, url) else {
            throw MacWorkbenchCatalogFetchError.badResponse
        }
        return data
    }
}

/// Loads and refreshes the verified macOS-original catalog. `load` reads the
/// retained local snapshot (never the network); `refresh` is the explicit
/// user-triggered fetch of the pinned publication over the public anonymous
/// routes, verified by `MacOriginalSkillCatalog.verified` before acceptance.
public protocol MacWorkbenchCatalogSource: Sendable {
    func loadCatalog() async throws -> MacWorkbenchSignedCatalog
    func refreshCatalog() async throws -> MacWorkbenchSignedCatalog
}

public enum MacWorkbenchCatalogError: Error, Equatable, Sendable, LocalizedError {
    case noSnapshot
    case invalidSnapshot
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .noSnapshot: "The signed skill catalog has not been downloaded yet. Use Refresh."
        case .invalidSnapshot: "The retained catalog snapshot failed verification and was not used."
        case .unavailable: "The signed skill catalog could not be reached. Installed skills remain available."
        }
    }
}

/// Snapshot-plus-refresh source for the macOS-original channel, mirroring the
/// iPad `MacOriginalSkillsCenter` refresh boundary without any Bridge
/// dependency: resolve `main` at the floe-skill-hub publication repository,
/// fetch `macos/catalog.json` + signature at the pinned commit through the
/// fixed anonymous mirror routes, verify, and retain the snapshot locally so
/// later launches (and offline use) still see the last verified feed.
public actor MacWorkbenchCatalogSnapshotSource: MacWorkbenchCatalogSource {
    private let snapshotURL: URL
    private let fetcher: any MacWorkbenchCatalogFetching

    public init(snapshotURL: URL, fetcher: any MacWorkbenchCatalogFetching = MacWorkbenchAnonymousCatalogFetcher()) {
        self.snapshotURL = snapshotURL
        self.fetcher = fetcher
    }

    private struct Snapshot: Codable {
        var commit: String
        var bytes: Data
        var signature: Data
    }

    public func loadCatalog() async throws -> MacWorkbenchSignedCatalog {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw MacWorkbenchCatalogError.noSnapshot
        }
        return try verified(snapshot)
    }

    public func refreshCatalog() async throws -> MacWorkbenchSignedCatalog {
        struct Ref: Decodable { struct Object: Decodable { var sha: String }; var object: Object }
        let referenceURL = URL(string: "https://api.github.com/repos")!
            .appendingPathComponent(CuratedSkillHub.owner)
            .appendingPathComponent(CuratedSkillHub.repository)
            .appendingPathComponent("git/ref/heads/main")
        let refBytes = try await fetcher.bytes(at: referenceURL, limit: 16 * 1024)
        let commit = try JSONDecoder().decode(Ref.self, from: refBytes).object.sha
        guard commit.utf8.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SignedContentFailure.feed
        }
        let publication = URL(string: "https://raw.githubusercontent.com")!
            .appendingPathComponent(CuratedSkillHub.owner)
            .appendingPathComponent(CuratedSkillHub.repository)
            .appendingPathComponent(commit)
        let catalogURL = publication.appendingPathComponent(MacOriginalSkillCatalog.catalogPath)
        let signatureURL = publication.appendingPathComponent(MacOriginalSkillCatalog.signaturePath)
        async let catalog = SkillHubMirrorTransport.load(catalogURL) { url in
            try await self.fetcher.bytes(at: url, limit: MacOriginalSkillCatalog.maximumBytes)
        }
        async let signature = SkillHubMirrorTransport.load(signatureURL) { url in
            try await self.fetcher.bytes(at: url, limit: 4096)
        }
        let snapshot = try await Snapshot(commit: commit, bytes: catalog, signature: signature)
        let verified = try verified(snapshot)
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(snapshot) {
            try? encoded.write(to: snapshotURL, options: .atomic)
        }
        return verified
    }

    /// Fail-closed verification: signature envelope, feed schema, entry
    /// shapes and per-entry manifest digests are all enforced by the
    /// EXISTING verifier before any entry is published.
    private func verified(_ snapshot: Snapshot) throws -> MacWorkbenchSignedCatalog {
        let feed = try MacOriginalSkillCatalog.verified(bytes: snapshot.bytes, signature: snapshot.signature)
        let keyID = try? JSONDecoder().decode(SignedContentEnvelope.self, from: snapshot.signature).keyID
        return MacWorkbenchSignedCatalog(
            feed: feed,
            publicationCommit: snapshot.commit,
            catalogDigest: FloeDigest.sha256Hex(snapshot.bytes),
            signatureKeyID: keyID
        )
    }
}

// MARK: - Runtime scope (task tool context)

/// The per-run skills projection the coordinator binds into the run
/// configuration: `skillIDs` becomes `ToolContext.activeSkillIDs` and
/// `instructions` joins the run's skill instructions — the same seam the
/// iPad `SkillsCenter.RuntimeSelection` feeds. Nothing here executes;
/// it is metadata the scoped runtime already understands.
public struct MacWorkbenchSkillScope: Sendable, Equatable {
    public var skillIDs: Set<String>
    public var instructions: String?

    public init(skillIDs: Set<String>, instructions: String?) {
        self.skillIDs = skillIDs
        self.instructions = instructions
    }

    public static let none = MacWorkbenchSkillScope(skillIDs: [], instructions: nil)
}

// MARK: - Service

/// Workbench service for the signed macOS-original skill catalog.
///
/// Responsibilities: publish the verified catalog (inspect), fetch verified
/// detail (select), commit installs (add), enable/disable/remove, and expose
/// the run scope plus a `SkillManaging` adapter for the existing skill
/// tools. All durable writes go through the store facade; all byte fetches
/// are verified against the signed catalog before use.
@MainActor
public final class MacWorkbenchSkillsService: ObservableObject {
    public enum CatalogState: Sendable, Equatable {
        case empty
        case loaded(publicationCommit: String, entryCount: Int)
        case unavailable(message: String)
    }

    @Published public private(set) var entries: [SkillHubCatalogEntry] = []
    @Published public private(set) var installed: [PersistedSkill] = []
    @Published public private(set) var catalogState: CatalogState = .empty
    @Published public private(set) var refreshingCatalog = false
    @Published public private(set) var jobs: [String: (stage: String, completed: Int, total: Int)] = [:]
    @Published public private(set) var errorMessage: String?

    private let catalogSource: any MacWorkbenchCatalogSource
    private let store: any MacWorkbenchSkillStore
    private let fetcher: any MacWorkbenchCatalogFetching
    private let installationRoot: URL
    private let appVersion: String
    private let admitWork: HostAgentWorkspace.AdmitWork
    private var catalog: MacWorkbenchSignedCatalog?

    init(catalogSource: any MacWorkbenchCatalogSource,
                store: any MacWorkbenchSkillStore,
                fetcher: any MacWorkbenchCatalogFetching = MacWorkbenchAnonymousCatalogFetcher(),
                installationRoot: URL,
                appVersion: String,
                admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.catalogSource = catalogSource
        self.store = store
        self.fetcher = fetcher
        self.installationRoot = installationRoot
        self.appVersion = appVersion
        self.admitWork = admitWork
    }

    /// Default application-support locations for the snapshot and the
    /// installed original files.
    public static func defaultSnapshotURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeMacWorkbench", isDirectory: true)
            .appendingPathComponent("macos-original-catalog-snapshot.json")
    }

    public static func defaultInstallationRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeMacWorkbench", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
    }

    // MARK: Catalog (inspect)

    /// Load the retained verified snapshot. Never touches the network.
    public func restore() async {
        do {
            let loaded = try await catalogSource.loadCatalog()
            accept(loaded)
            errorMessage = nil
        } catch MacWorkbenchCatalogError.noSnapshot {
            catalogState = .empty
        } catch {
            catalogState = .unavailable(message: MacWorkbenchCatalogError.invalidSnapshot.localizedDescription)
        }
        await reloadInstalled()
    }

    /// Explicit user-triggered refresh over the public anonymous routes.
    public func refreshCatalog() async {
        guard !refreshingCatalog else { return }
        refreshingCatalog = true
        defer { refreshingCatalog = false }
        do {
            let loaded = try await catalogSource.refreshCatalog()
            accept(loaded)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            if catalog == nil {
                catalogState = .unavailable(message: MacWorkbenchCatalogError.unavailable.localizedDescription)
            }
            errorMessage = MacWorkbenchCatalogError.unavailable.localizedDescription
        }
        await reloadInstalled()
    }

    private func accept(_ loaded: MacWorkbenchSignedCatalog) {
        catalog = loaded
        entries = (try? loaded.feed.entries.map { try entryRow($0, in: loaded) }) ?? []
        catalogState = .loaded(publicationCommit: loaded.publicationCommit, entryCount: entries.count)
    }

    private func entryRow(_ entry: MacOriginalSkillCatalog.Entry,
                          in loaded: MacWorkbenchSignedCatalog) throws -> SkillHubCatalogEntry {
        let provenance = try SkillHubProvenance(
            hubRepository: CuratedSkillHub.hubRepository,
            publisher: entry.repository,
            channel: .macosOriginal,
            feedStatus: .production,
            signatureKeyID: loaded.signatureKeyID,
            sourceCommit: entry.commit,
            publicationCommit: loaded.publicationCommit,
            catalogDigest: loaded.catalogDigest,
            contentDigest: entry.digest,
            packageSHA256: nil,
            reviewDigest: nil
        )
        return try SkillHubCatalogEntry(
            id: entry.id,
            version: entry.version,
            kind: .optional,
            name: SkillHubLocalizedText.name(en: entry.name.en, zhHans: entry.name.zhHans),
            description: SkillHubLocalizedText.description(en: entry.description.en, zhHans: entry.description.zhHans),
            category: entry.category.rawValue,
            tags: ["macos", "upstream-original"],
            containsScripts: entry.files.contains { $0.path.hasPrefix("scripts/") },
            installOffer: .upstreamOriginal,
            reviewed: true,
            qualified: false,
            published: true,
            minimumAppVersion: entry.minimumAppVersion,
            provenance: provenance
        )
    }

    /// Review-only detail: the exact SKILL.md bytes from the pinned source
    /// commit, every byte hash-verified against the signed catalog.
    public func detail(id: String) async throws -> SkillHubCatalogDetail? {
        guard let loaded = catalog else { throw MacWorkbenchCatalogError.noSnapshot }
        guard let entry = loaded.feed.entries.first(where: { $0.id == id }) else { return nil }
        guard let row = entries.first(where: { $0.id == id }) else { return nil }
        guard let instructionsFile = entry.files.first(where: { $0.path == "SKILL.md" }) else { return nil }
        let bytes = try await fetchOriginalFile(entry, file: instructionsFile)
        return try SkillHubCatalogDetail(
            entry: row,
            instructions: String(decoding: bytes, as: UTF8.self),
            bundledFiles: entry.files.map(\.path),
            fileCount: entry.files.count,
            totalBytes: Int(entry.files.reduce(0) { $0 + $1.bytes }),
            reviewedCapabilities: [],
            reviewedTools: []
        )
    }

    private func fetchOriginalFile(_ entry: MacOriginalSkillCatalog.Entry,
                                   file: MacOriginalSkillCatalog.File) async throws -> Data {
        let parts = entry.repository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw SignedContentFailure.feed }
        let url = URL(string: "https://raw.githubusercontent.com")!
            .appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1])
            .appendingPathComponent(entry.commit)
            .appendingPathComponent(MacOriginalSkillCatalog.sourcePath(entry, file: file))
        let bytes = try await SkillHubMirrorTransport.load(url) { url in
            try await self.fetcher.bytes(at: url, limit: Int(MacOriginalSkillCatalog.maximumPackageBytes))
        }
        guard Int64(bytes.count) == file.bytes, FloeDigest.sha256Hex(bytes) == file.sha256 else {
            throw SignedContentFailure.feed
        }
        return bytes
    }

    // MARK: Installed state

    public func reloadInstalled() async {
        installed = (try? await store.all()) ?? []
    }

    public func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    public func installedRow(_ id: String) -> PersistedSkill? {
        installed.first { $0.id == id }
    }

    // MARK: Add (verified install)

    /// Commit one catalog entry into the shared store. Every byte is fetched
    /// at the entry's pinned source commit and verified against the signed
    /// catalog; files land in a scratch directory and are promoted only
    /// after verification, with the existing rollback discipline (a failed
    /// store commit restores the previous installation). The official
    /// publication ledger records the immutable id+version+digest identity
    /// in the SAME transaction as the row.
    @discardableResult
    public func install(id: String) async throws -> SkillHubInstallReceipt {
        guard let loaded = catalog else { throw SkillHubInstallError.notConfigured }
        guard let entry = loaded.feed.entries.first(where: { $0.id == id }) else {
            throw SkillHubInstallError.notConfigured
        }
        guard MacOriginalSkillCatalog.compatible(entry, appVersion: appVersion) else {
            throw FloeError.invalidConfiguration("This skill requires a newer Floe version")
        }
        guard jobs[id] == nil else { throw SkillStoreConflict.changedOrMissing }
        let release = try admitWork()
        jobs[id] = (MacWorkbenchSkillsText.downloading, 0, entry.files.count)
        defer {
            jobs.removeValue(forKey: id)
            release()
        }
        let existed = try await store.skill(id: id) != nil
        if let current = try await store.skill(id: id) {
            if current.version == entry.version, current.rewrittenDigest != entry.digest {
                throw SignedContentFailure.immutableVersion
            }
            if current.version != entry.version,
               let old = try? SignedContentVersion(current.version),
               try SignedContentVersion(entry.version) <= old {
                throw FloeError.invalidConfiguration("This update is not newer than the installed skill.")
            }
        }

        let staging = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "skills")
        let scratch = staging.url
        defer { staging.lease.release() }
        do {
            var fileRecords: [[String: Any]] = []
            for (index, file) in entry.files.enumerated() {
                try Task.checkCancellation()
                jobs[id] = (MacWorkbenchSkillsText.downloading, index, entry.files.count)
                let bytes = try await fetchOriginalFile(entry, file: file)
                let local = scratch.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try bytes.write(to: local, options: .atomic)
                fileRecords.append([
                    "path": file.path,
                    "sha256": file.sha256,
                    "bytes": file.bytes,
                    "mode": file.mode,
                ])
            }
            let packageSHA256 = Self.contentDigest(root: scratch, files: entry.files)
            let reviewDigest = try Self.reviewManifestDigest(fileRecords)
            try Task.checkCancellation()
            jobs[id] = (MacWorkbenchSkillsText.installing, entry.files.count, entry.files.count)

            let destination = installationRoot.appendingPathComponent(entry.id, isDirectory: true)
            let backup = installationRoot.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: installationRoot, withIntermediateDirectories: true)
            var didBackup = false
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
                didBackup = true
            }
            var didInstall = false
            do {
                try FileManager.default.moveItem(at: scratch, to: destination)
                didInstall = true
                let skill = try Self.persistedSkill(
                    entry: entry,
                    publicationCommit: loaded.publicationCommit,
                    packageSHA256: packageSHA256,
                    reviewDigest: reviewDigest,
                    installedPath: destination.path
                )
                try await store.save(skill, grantCapabilities: [], officialPublication: OfficialSkillPublicationRecord(
                    skillID: entry.id,
                    version: entry.version,
                    contentDigest: entry.digest,
                    publicationCommit: loaded.publicationCommit
                ))
            } catch {
                if didInstall, FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                if didBackup, FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.moveItem(at: backup, to: destination)
                }
                throw error
            }
            if didBackup { try? FileManager.default.removeItem(at: backup) }
            await reloadInstalled()
            guard let committed = try await store.skill(id: id),
                  committed.rewrittenDigest == entry.digest else {
                throw SkillUpgradeError.localConflict
            }
            return try SkillHubInstallReceipt(
                status: existed ? .replaced : .installed,
                skillID: entry.id,
                version: entry.version,
                contentDigest: entry.digest,
                packageSHA256: packageSHA256,
                catalogDigest: loaded.catalogDigest,
                reviewDigest: reviewDigest,
                sourceCommit: entry.commit,
                publicationCommit: loaded.publicationCommit,
                containsScripts: entry.files.contains { $0.path.hasPrefix("scripts/") },
                fileCount: entry.files.count,
                totalBytes: Int(entry.files.reduce(0) { $0 + $1.bytes }),
                reviewedCapabilities: [],
                reviewedTools: []
            )
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    // MARK: Enable / disable / remove

    public func setEnabled(_ enabled: Bool, id: String) async throws {
        guard jobs[id] == nil, let row = try await store.skill(id: id) else { throw SkillStoreConflict.changedOrMissing }
        try await store.setEnabled(enabled, id: id, expectedDigest: row.rewrittenDigest)
        await reloadInstalled()
    }

    public func remove(id: String) async throws {
        guard jobs[id] == nil, let row = try await store.skill(id: id) else { throw SkillStoreConflict.changedOrMissing }
        let packageURL = installationRoot.appendingPathComponent(id, isDirectory: true)
        let recovery = installationRoot.deletingLastPathComponent()
            .appendingPathComponent("RemovedSkills", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let backup = recovery.appendingPathComponent("\(id)-\(UUID().uuidString)", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: packageURL.path)
        if exists { try FileManager.default.moveItem(at: packageURL, to: backup) }
        do {
            try await store.remove(id: id, expectedDigest: row.rewrittenDigest)
        } catch {
            if exists { try? FileManager.default.moveItem(at: backup, to: packageURL) }
            throw error
        }
        await reloadInstalled()
    }

    // MARK: Task scope

    /// The enabled installed skills for the current task context. The
    /// coordinator binds this into the run configuration
    /// (`Configuration.activeSkillIDs` and the run's skill instructions).
    public func runtimeScope() async -> MacWorkbenchSkillScope {
        guard let rows = try? await store.all() else { return .none }
        let enabled = rows.filter { $0.status == "enabled" }
        guard !enabled.isEmpty else { return .none }
        var blocks: [String] = []
        for row in enabled {
            let description = (try? SkillPackageValidator().parseSkillMarkdown(Data(row.skillMarkdown.utf8)))?.description
                ?? entries.first(where: { $0.id == row.id })?.description.en
                ?? row.name
            blocks.append("- \(row.id): \(description) [version=\(row.version), digest=\(row.rewrittenDigest)]")
        }
        return MacWorkbenchSkillScope(skillIDs: Set(enabled.map(\.id)), instructions: blocks.joined(separator: "\n\n"))
    }

    /// The `SkillManaging` adapter for the existing skill tools. The same
    /// instance backs the UI and the task path, so a change made either way
    /// is the change the other side sees.
    public func makeManager() -> MacWorkbenchSkillManager {
        MacWorkbenchSkillManager(store: store)
    }

    /// The catalog provider adapter for `skill.search` / `skill.read`.
    public func makeCatalogProvider() -> MacWorkbenchCatalogProvider {
        MacWorkbenchCatalogProvider(service: self)
    }

    // MARK: Receipt helpers

    /// Deterministic digest over the unpacked staged bytes: for every file,
    /// path length (big-endian) + path bytes + content length (big-endian) +
    /// content bytes, in signed-catalog path order. This is the "package
    /// bytes" identity for this channel: no archive exists upstream.
    static func contentDigest(root: URL, files: [MacOriginalSkillCatalog.File]) -> String {
        var hasher = SHA256()
        for file in files {
            let path = Data(file.path.utf8)
            var length = UInt64(path.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: path)
            let bytes = (try? Data(contentsOf: root.appendingPathComponent(file.path))) ?? Data()
            var size = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of the canonical install review record: the JSON array of the
    /// exact per-file {path, sha256, bytes, mode} records verified during
    /// this install, sorted keys, no slashes escaped.
    static func reviewManifestDigest(_ records: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .withoutEscapingSlashes])
        return FloeDigest.sha256Hex(data)
    }

    private static func persistedSkill(entry: MacOriginalSkillCatalog.Entry,
                                       publicationCommit: String,
                                       packageSHA256: String,
                                       reviewDigest: String,
                                       installedPath: String) throws -> PersistedSkill {
        let manifest = SkillManifest(
            id: entry.id,
            version: entry.version,
            capabilities: [],
            tools: [],
            platforms: [SkillPlatform.macOS.rawValue],
            scriptRuntime: .none
        )
        let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        let compatibility: [String: Any] = [
            "status": "compatible",
            "channel": "macos-original",
        ]
        let compatibilityJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: compatibility, options: [.sortedKeys]), as: UTF8.self)
        let tracking: [String: Any] = [
            "channel": "macos-original",
            "repository": entry.repository,
            "commit": entry.commit,
            "installedPath": installedPath,
            "fileCount": entry.files.count,
            "totalBytes": entry.files.reduce(0) { $0 + $1.bytes },
            "packageSHA256": packageSHA256,
            "reviewDigest": reviewDigest,
            "publicationCommit": publicationCommit,
        ]
        let trackingJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: tracking, options: [.sortedKeys]), as: UTF8.self)
        guard let markdownFile = entry.files.first(where: { $0.path == "SKILL.md" }) else {
            throw SignedContentFailure.feed
        }
        // The caller has already staged and verified the bytes; re-read the
        // staged copy rather than re-fetching.
        let stagedRoot = URL(fileURLWithPath: installedPath, isDirectory: true)
        let markdown = String(decoding: try Data(contentsOf: stagedRoot.appendingPathComponent(markdownFile.path)), as: UTF8.self)
        return PersistedSkill(
            id: entry.id,
            name: entry.name.en,
            version: entry.version,
            status: "enabled",
            skillMarkdown: markdown,
            manifestJSON: manifestJSON,
            declaredCapabilitiesJSON: "[]",
            effectiveCapabilitiesJSON: "[]",
            sourceURL: "https://github.com/\(entry.repository)",
            sourceDigest: entry.commit,
            rewrittenDigest: entry.digest,
            rewriteModelID: "macos-original-\(publicationCommit)",
            compatibilityReportJSON: compatibilityJSON,
            sourceTrackingJSON: trackingJSON
        )
    }
}

// MARK: - Text

enum MacWorkbenchSkillsText {
    static var isChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
    static var downloading: String { t("正在下载", "Downloading") }
    static var installing: String { t("正在安装", "Installing") }
}

// MARK: - SkillManaging adapter

/// The existing-tools manager over the shared store. List/search metadata
/// never carries instruction bodies; exact reads carry the pinned Markdown;
/// `manage` applies enable/disable/remove against the current row digest.
public struct MacWorkbenchSkillManager: SkillManaging {
    private let store: any MacWorkbenchSkillStore

    public init(store: any MacWorkbenchSkillStore) {
        self.store = store
    }

    public func read(id: String?) async throws -> [ManagedSkill] {
        let rows = try await store.all().filter { id == nil || $0.id == id }
        if let id, rows.isEmpty { throw SkillStoreConflict.changedOrMissing }
        return rows.map(Self.row)
    }

    public func read(id: String?, runID: UUID) async throws -> [ManagedSkill] {
        try await read(id: id)
    }

    public func read(id: String, runID: UUID, resourceContext: SkillResourceContext) async throws -> [ManagedSkill] {
        // Resource staging into a guest workspace is a Linux-guest concept;
        // this channel keeps the exact previous shape (no resources field).
        try await read(id: id)
    }

    public func manage(_ request: SkillManageTool.Arguments) async throws -> String {
        guard let row = try await store.skill(id: request.id),
              row.rewrittenDigest == request.expectedDigest else {
            throw SkillStoreConflict.changedOrMissing
        }
        switch request.action {
        case .setEnabled:
            guard let enabled = request.enabled else {
                throw FloeError.validationFailed("setEnabled requires enabled")
            }
            try await store.setEnabled(enabled, id: row.id, expectedDigest: request.expectedDigest)
            return "status=applied id=\(row.id) action=setEnabled enabled=\(enabled); use skill.read for the current digest"
        case .remove:
            try await store.remove(id: row.id, expectedDigest: request.expectedDigest)
            return "status=removed id=\(row.id); the catalog entry remains available for reinstall"
        case .update:
            throw FloeError.validationFailed("Signed catalog skills keep their reviewed instructions; disable or remove instead")
        case .checkUpdates, .updatePackage, .rollback, .prepareDependencies:
            throw FloeError.validationFailed("This operation is unavailable for macOS-original channel skills")
        }
    }

    static func row(_ skill: PersistedSkill) -> ManagedSkill {
        let description = (try? SkillPackageValidator().parseSkillMarkdown(Data(skill.skillMarkdown.utf8)))?.description
        return ManagedSkill(
            id: skill.id,
            name: skill.name,
            version: skill.version,
            enabled: skill.status == "enabled",
            digest: skill.rewrittenDigest,
            markdown: skill.skillMarkdown,
            description: description
        )
    }
}

// MARK: - Catalog provider adapter

/// `SkillHubCatalogProviding` over the workbench service: review-only
/// discovery/detail, never an install side effect.
public struct MacWorkbenchCatalogProvider: SkillHubCatalogProviding {
    private let service: MacWorkbenchSkillsService

    public init(service: MacWorkbenchSkillsService) {
        self.service = service
    }

    public func verifiedCatalogEntries() async throws -> [SkillHubCatalogEntry] {
        let entries = await service.entries
        guard !entries.isEmpty else { throw SkillHubCatalogError.unavailable("The signed catalog is not loaded yet") }
        return entries
    }

    public func verifiedCatalogDetail(id: String) async throws -> SkillHubCatalogDetail? {
        do {
            return try await service.detail(id: id)
        } catch MacWorkbenchCatalogError.noSnapshot {
            throw SkillHubCatalogError.unavailable("The signed catalog is not loaded yet")
        }
    }
}

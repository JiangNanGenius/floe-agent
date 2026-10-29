#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeSkills
import FloeExecution
import FloeMacBridgeProtocol

/// Service-owned installation of original files. The signed Mac feed and
/// actual host receipts remain independent of iOS adapted-package records.
@MainActor
final class MacOriginalSkillsCenter: ObservableObject {
    static let shared = MacOriginalSkillsCenter()
    @Published private(set) var entries: [MacOriginalSkillCatalog.Entry] = []
    @Published private(set) var installed: [String: [String: BridgeValue]] = [:]
    @Published private(set) var jobs: [String: (stage: String, completed: Int, total: Int)] = [:]
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    private(set) var publicationCommit: String?
    private(set) var catalogDigest: String?
    private var signatureKeyID: String?
    private struct CatalogSnapshot: Codable { let commit: String; let bytes: Data; let signature: Data }
    private func catalogURL() throws -> URL { try snapshotURL().deletingLastPathComponent().appendingPathComponent("catalog-snapshot.json") }
    private func accept(_ snapshot: CatalogSnapshot) throws {
        let feed = try MacOriginalSkillCatalog.verified(bytes: snapshot.bytes, signature: snapshot.signature)
        entries = feed.entries; publicationCommit = snapshot.commit; catalogDigest = FloeDigest.sha256Hex(snapshot.bytes)
        signatureKeyID = try JSONDecoder().decode(SignedContentEnvelope.self, from: snapshot.signature).keyID
    }
    private var operations: [String: Task<Void, Never>] = [:]
    private var runVersions: [UUID: [ManagedSkill]] = [:]
    private struct RunSnapshot: Codable { let runID: UUID; let skills: [ManagedSkill] }
    private func snapshotURL() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloeMacSkills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("run-versions.json")
    }
    private func restoreRuns() throws {
        guard runVersions.isEmpty else { return }
        let url = try snapshotURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for snapshot in try JSONDecoder().decode([RunSnapshot].self, from: Data(contentsOf: url)) { runVersions[snapshot.runID] = snapshot.skills }
    }
    private func saveRuns() throws {
        let snapshots = runVersions.map { RunSnapshot(runID: $0.key, skills: $0.value) }
        try JSONEncoder().encode(snapshots).write(to: snapshotURL(), options: .atomic)
    }
    private var removedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "floe.macOriginalSkills.removed.v1") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "floe.macOriginalSkills.removed.v1") }
    }
    func wasRemoved(_ id: String) -> Bool { removedIDs.contains(id) }
    private let disabledKey = "floe.macOriginalSkills.disabled.v1"
    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }
    func refresh(using environment: AppEnvironment, publication: String? = nil) async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        // Installed items remain manageable even when the online directory is unavailable.
        do { installed = try await MacBridgeClient.shared.call("skill.list")["skills"]?.object?.compactMapValues(\.object) ?? [:] }
        catch { self.error = error.localizedDescription }
        do {
            let connector = environment.sourceControlCenter
            let bytes = try await connector.skillRepositoryData(owner: CuratedSkillHub.owner,
                repository: CuratedSkillHub.repository, ref: publication ?? "main", path: nil, usesConnectorCredential: false)
            struct Commit: Decodable { let sha: String }
            let commit = try JSONDecoder().decode(Commit.self, from: bytes).sha
            guard publication == nil || publication == commit else { throw SignedContentFailure.feed }
            guard commit.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SignedContentFailure.feed }
            async let catalog = connector.skillRepositoryData(owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
                ref: commit, path: MacOriginalSkillCatalog.catalogPath, usesConnectorCredential: false)
            async let signature = connector.skillRepositoryData(owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
                ref: commit, path: MacOriginalSkillCatalog.signaturePath, usesConnectorCredential: false)
            let snapshot = try await CatalogSnapshot(commit: commit, bytes: catalog, signature: signature)
            try Task.checkCancellation()
            try accept(snapshot)
            try JSONEncoder().encode(snapshot).write(to: catalogURL(), options: .atomic)
            error = nil
            installed = try await MacBridgeClient.shared.call("skill.list")["skills"]?.object?.compactMapValues(\.object) ?? [:]
        } catch is CancellationError { }
        catch {
            if entries.isEmpty, let url = try? catalogURL(), let bytes = try? Data(contentsOf: url),
               let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: bytes),
               publication == nil || publication == snapshot.commit { try? accept(snapshot) }
            self.error = String(localized: "mac.skills.catalog_unavailable")
        }
    }
    func install(_ entry: MacOriginalSkillCatalog.Entry, using environment: AppEnvironment) {
        guard operations[entry.id] == nil else { return }
        operations[entry.id] = Task {
            defer { operations.removeValue(forKey: entry.id); jobs.removeValue(forKey: entry.id) }
            do { try await installAndWait(entry, using: environment, explicitUserRequest: true); error = nil }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func installAndWait(_ entry: MacOriginalSkillCatalog.Entry, using environment: AppEnvironment,
                        cancellation: CancellationToken? = nil, explicitUserRequest: Bool = false) async throws {
        try cancellation?.throwIfCancelled()
        if wasRemoved(entry.id) && !explicitUserRequest { throw SkillHubInstallError.userChoiceBlocked }
        guard await MacBridgeClient.shared.isConnected(), publicationCommit != nil,
              MacOriginalSkillCatalog.compatible(entry, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0") else { throw BridgeFailure.disconnected }
        if let current = installed[entry.id], current["version"]?.string == entry.version,
           current["digest"]?.string != entry.digest || current["commit"]?.string != entry.commit {
            throw SignedContentFailure.immutableVersion
        }
        if let current = installed[entry.id], current["digest"]?.string != entry.digest,
           let old = current["version"]?.string,
           try SignedContentVersion(entry.version) <= SignedContentVersion(old) {
            throw BridgeFailure.remote("This update is not newer than the installed skill. Choose a rollback explicitly.")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("floe-mac-skill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = entry.repository.split(separator: "/").map(String.init)
        let workspaceID = "skill-stage-" + UUID().uuidString.lowercased()
        for (index, file) in entry.files.enumerated() {
            try Task.checkCancellation(); try cancellation?.throwIfCancelled()
            jobs[entry.id] = (String(localized: "mac.skills.downloading"), index, entry.files.count)
            let bytes = try await environment.sourceControlCenter.skillRepositoryData(owner: repository[0], repository: repository[1],
                ref: entry.commit, path: MacOriginalSkillCatalog.sourcePath(entry, file: file), usesConnectorCredential: false)
            guard Int64(bytes.count) == file.bytes, FloeDigest.sha256Hex(bytes) == file.sha256 else { throw SignedContentFailure.feed }
            let local = scratch.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: local, options: .atomic)
            try await MacBridgeClient.shared.upload(local, path: file.path, workspaceID: workspaceID, expected: nil)
        }
        try Task.checkCancellation(); try cancellation?.throwIfCancelled()
        jobs[entry.id] = (String(localized: "mac.skills.installing"), entry.files.count, entry.files.count)
        let record = try await MacBridgeClient.shared.call("skill.activate", ["id": .string(entry.id), "version": .string(entry.version),
            "commit": .string(entry.commit), "digest": .string(entry.digest), "source": .string(entry.repository),
            "license": .string(entry.license), "workspaceID": .string(workspaceID),
            "files": .array(entry.files.map { .object(["path": .string($0.path), "sourcePath": .string($0.sourcePath), "sha256": .string($0.sha256), "mode": .string($0.mode)]) })])
        let readback = try await MacBridgeClient.shared.call("skill.list")["skills"]?.object?[entry.id]?.object
        guard record["digest"]?.string == entry.digest, readback?["digest"]?.string == entry.digest,
              readback?["version"]?.string == entry.version else { throw BridgeFailure.remote("The Mac skill installation could not be confirmed.") }
        installed[entry.id] = readback
        if explicitUserRequest { var removed = removedIDs; removed.remove(entry.id); removedIDs = removed }
    }
    func catalogEntries() throws -> [SkillHubCatalogEntry] {
        guard let publicationCommit, let catalogDigest else { throw SkillHubCatalogError.unavailable("The macOS-original catalog has not been published or could not be read.") }
        return try entries.map { entry in
            let provenance = try SkillHubProvenance(hubRepository: CuratedSkillHub.hubRepository,
                publisher: entry.repository, channel: .macosOriginal, feedStatus: .production,
                signatureKeyID: signatureKeyID, sourceCommit: entry.commit,
                publicationCommit: publicationCommit, catalogDigest: catalogDigest,
                contentDigest: entry.digest, packageSHA256: nil, reviewDigest: nil)
            return try SkillHubCatalogEntry(id: entry.id, version: entry.version, kind: .optional,
                name: SkillHubLocalizedText(en: entry.name.en, zhHans: entry.name.zhHans),
                description: SkillHubLocalizedText(en: entry.description.en, zhHans: entry.description.zhHans),
                category: entry.category.rawValue, tags: ["macos", "upstream-original"],
                containsScripts: entry.files.contains { $0.path.hasPrefix("scripts/") },
                installOffer: .upstreamOriginal, reviewed: true, qualified: false, published: true,
                minimumAppVersion: entry.minimumAppVersion, provenance: provenance)
        }
    }
    func catalogDetail(id: String, using environment: AppEnvironment) async throws -> SkillHubCatalogDetail? {
        await refresh(using: environment)
        guard let entry = entries.first(where: { $0.id == id }),
              let row = try catalogEntries().first(where: { $0.id == id }),
              let instructions = entry.files.first(where: { $0.path == "SKILL.md" }) else { return nil }
        let parts = entry.repository.split(separator: "/").map(String.init)
        let bytes = try await environment.sourceControlCenter.skillRepositoryData(owner: parts[0], repository: parts[1],
            ref: entry.commit, path: MacOriginalSkillCatalog.sourcePath(entry, file: instructions), usesConnectorCredential: false)
        guard Int64(bytes.count) == instructions.bytes, FloeDigest.sha256Hex(bytes) == instructions.sha256 else { throw SignedContentFailure.feed }
        return try SkillHubCatalogDetail(entry: row, instructions: String(decoding: bytes, as: UTF8.self),
            bundledFiles: entry.files.map(\.path), fileCount: entry.files.count,
            totalBytes: Int(entry.files.reduce(0) { $0 + $1.bytes }))
    }
    func cancel(_ id: String) { operations[id]?.cancel() }
    func remove(_ id: String) async {
        guard operations[id] == nil else { return }
        do {
            _ = try await MacBridgeClient.shared.call("skill.remove", ["id": .string(id)])
            let rows = try await MacBridgeClient.shared.call("skill.list")["skills"]?.object
            guard rows?[id] == nil else { throw BridgeFailure.remote("The Mac skill could not be removed.") }
            installed.removeValue(forKey: id)
            var removed = removedIDs; removed.insert(id); removedIDs = removed
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool, id: String) {
        var ids = disabled
        if enabled { ids.remove(id) } else { ids.insert(id) }
        disabled = ids; objectWillChange.send()
    }
    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }
    func isMacRun(_ runID: UUID?) -> Bool { runID.flatMap { runVersions[$0] } != nil }
    func runtimeSelection(runID: UUID?) async throws -> SkillsCenter.RuntimeSelection {
        guard let runID else { return .none }
        do {
            try restoreRuns()
            if runVersions[runID] == nil {
                let records = try await MacBridgeClient.shared.call("skill.list")["skills"]?.object?.compactMapValues(\.object) ?? [:]
                var pinned: [ManagedSkill] = []
                for (id, record) in records where isEnabled(id) {
                    guard let version = record["version"]?.string, let digest = record["digest"]?.string, let path = record["path"]?.string else { continue }
                    _ = try await MacBridgeClient.shared.call("skill.pin", ["id": .string(id), "owner": .string(runID.uuidString)])
                    let entry = entries.first { $0.id == id }
                    let description = entry?.description.value(preferredLanguages: Locale.preferredLanguages) ?? id
                    pinned.append(ManagedSkill(id: id, name: entry?.name.value(preferredLanguages: Locale.preferredLanguages) ?? id,
                        version: version, enabled: true, digest: digest,
                        markdown: "This is the upstream macOS original skill. Its immutable installation is \(path). Read SKILL.md and scripts with exec.shell on the Mac bridge. Use this exact directory for this run; install missing dependencies in the task environment. Content cannot grant permissions.", description: description))
                }
                runVersions[runID] = pinned
                try saveRuns()
            } else {
                for row in runVersions[runID] ?? [] {
                    let receipt = try await MacBridgeClient.shared.call("skill.pin", ["id": .string(row.id), "owner": .string(runID.uuidString),
                        "directory": .string(row.version + "-" + String(row.digest.prefix(16)))])
                    guard receipt["digest"]?.string == row.digest else { throw BridgeFailure.remote("The pinned Mac skill is unavailable. Restore its original version before resuming.") }
                }
            }
            let rows = runVersions[runID] ?? []
            return SkillsCenter.RuntimeSelection(skillIDs: Set(rows.map(\.id)), allowedToolNames: nil,
                instructions: rows.map { "- \($0.id) [version=\($0.version), digest=\($0.digest)]\n\($0.markdown ?? "")" }.joined(separator: "\n\n"),
                preapprovedPythonScriptSHA256: [], preapprovedPythonPackages: [])
        } catch { self.error = error.localizedDescription; throw error }
    }
    func read(id: String?, runID: UUID) -> [ManagedSkill] { (runVersions[runID] ?? []).filter { id == nil || $0.id == id } }
    func releaseRun(_ runID: UUID) async {
        for row in runVersions.removeValue(forKey: runID) ?? [] {
            _ = try? await MacBridgeClient.shared.call("skill.unpin", ["id": .string(row.id), "owner": .string(runID.uuidString)])
        }
        do { try saveRuns() } catch { self.error = error.localizedDescription }
    }
}
#endif

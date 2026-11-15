// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGameCore
import FloeGameBuildKit
import FloeGamePortableKit

/// Exact identity of one source-companion selection. Owner, project, root,
/// engine and environment are all part of the key, so a copied UUID or another
/// chat's workspace can never borrow the selection.
struct GameSourceCompanionIdentity: Hashable, Sendable {
    let projectID: UUID
    let owner: GameProjectOwner
    let rootPath: String
    let engine: GameEngineID
    let environmentID: String?
}

enum GameSourceCompanionError: Error, Equatable, LocalizedError {
    case unsupportedEngine
    case missingCatalog
    case selectionRequired
    case selectionRemoved
    case unreadableSelection

    var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .unsupportedEngine:
            return zh
                ? "这个引擎没有已审阅的对应源码/配对分发档案。"
                : "This engine has no reviewed corresponding-source/paired-source profile."
        case .missingCatalog:
            return zh
                ? "对应源码目录未随 App 打包，无法验证精确字节。"
                : "The source-accompaniment catalog is not bundled, so exact bytes cannot be verified."
        case .selectionRequired:
            return zh
                ? "请先选择该引擎的精确对应源码包，再导出完整分发包。"
                : "Choose the exact corresponding-source bundle for this engine before a full distribution export."
        case .selectionRemoved:
            return zh
                ? "对应源码选择已失效，请重新选择。"
                : "The source-companion selection is no longer active. Choose it again."
        case .unreadableSelection:
            return zh
                ? "无法读取所选源码包，请确认文件仍在且可访问。"
                : "The selected source bundle cannot be read. Confirm it is still present and accessible."
        }
    }
}

/// Something a view can show without holding a lease or a private path. The
/// display name is the user's selected folder/file name, never a depot path.
struct GameSourceCompanionSnapshot: Sendable, Equatable {
    let packID: String
    let profileID: String?
    let bundleID: String
    let sha256: String
    let bytes: Int
    let layout: GamePortableSourceOfferLayout
    let displayName: String
    let importedAt: Date
    /// UI hint only: the materializer markers are present. Export still hashes
    /// every declared file; markers are never authority.
    let isCompleteSourceOffer: Bool
}

struct GameSourceCompanionExport: Sendable {
    let directory: URL
    let receipt: GamePortableSourceOfferReceipt
}

/// One service-owned selection and its security-scoped access. Views never own
/// the scope: they install a selection here and the service keeps it alive
/// until the session closes or the user replaces/removes it. An in-flight
/// build keeps its own use count, so removing/replacing the selection cannot
/// release the scope under running IO.
final class GameSourceCompanionSelection: @unchecked Sendable {
    let identity: GameSourceCompanionIdentity
    let packID: String
    let profileID: String?
    let pairedSourceID: String
    let bundleID: String
    let bundleURL: URL
    let sha256: String
    let bytes: Int
    let layout: GamePortableSourceOfferLayout
    let displayName: String
    let importedAt: Date
    let isCompleteSourceOffer: Bool
    let rootURL: URL
    let isDirectoryRoot: Bool

    private let didAccess: Bool
    private let lock = NSLock()
    private var users = 0
    private var retired = false
    private var scopeReleased = false

    init(identity: GameSourceCompanionIdentity,
         pack: GamePortableSourcePackAccompaniment,
         resolution: GamePortableSourceOfferResolution,
         rootURL: URL,
         didAccess: Bool) throws {
        guard let pairedSourceID = pack.pairedSourceID,
              let bundle = pack.sourceBundle,
              bundle.id == resolution.bundleID,
              bundle.sha256 == resolution.sha256,
              bundle.bytes == resolution.bytes else {
            throw GameSourceCompanionError.unsupportedEngine
        }
        self.identity = identity
        self.packID = pack.packID
        self.profileID = pack.profileID
        self.pairedSourceID = pairedSourceID
        self.bundleID = resolution.bundleID
        self.bundleURL = resolution.bundleURL
        self.sha256 = resolution.sha256
        self.bytes = resolution.bytes
        self.layout = resolution.layout
        self.importedAt = Date()
        self.rootURL = rootURL
        self.isDirectoryRoot = resolution.layout != .directBundleFile
        let rootName = rootURL.lastPathComponent
        self.displayName = (resolution.layout == .directBundleFile || rootName.isEmpty)
            ? resolution.bundleID : rootName
        let directory = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.isCompleteSourceOffer = resolution.layout != .directBundleFile
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("bundle-manifest.json").path)
            && FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("PAIRED-SOURCE.json").path)
        self.didAccess = didAccess
    }

    var snapshot: GameSourceCompanionSnapshot {
        .init(packID: packID, profileID: profileID, bundleID: bundleID,
              sha256: sha256, bytes: bytes, layout: layout, displayName: displayName,
              importedAt: importedAt, isCompleteSourceOffer: isCompleteSourceOffer)
    }

    /// Roots for the shared PortableKit materializer. When the user selected a
    /// materialized source-offer directory all declared groups live under that
    /// one root; a flat Python producer only has the exact bundle, so the
    /// materializer truthfully reports the missing groups instead of pretending
    /// a complete offer exists.
    var companionRoots: GamePortableSourceOfferRoots {
        guard isDirectoryRoot else {
            return .init(sourceBundle: bundleURL.deletingLastPathComponent())
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let exact = root.appendingPathComponent("sources/exact", isDirectory: true)
        let bundleRoot = FileManager.default.fileExists(atPath: exact.path) ? exact : root
        return .init(licenses: root, helperSources: root, relink: root,
                     sourcePackages: root, sourceFiles: root, sourceBundle: bundleRoot)
    }

    func beginUse() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, !scopeReleased else {
            throw GameSourceCompanionError.selectionRemoved
        }
        users += 1
    }

    func endUse() {
        lock.lock()
        users = max(0, users - 1)
        releaseIfUnusedLocked()
        lock.unlock()
    }

    func retire() {
        lock.lock()
        retired = true
        releaseIfUnusedLocked()
        lock.unlock()
    }

    var isReadable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !scopeReleased
    }

    var scopeIsReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return scopeReleased
    }

    private func releaseIfUnusedLocked() {
        guard retired, users == 0, !scopeReleased else { return }
        scopeReleased = true
        if didAccess {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        if didAccess, !scopeReleased {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }
}

/// The BuildKit paired-source provider captures one selection for the whole
/// build. `resolve` re-hashes the actual file every time, so replacing the file
/// after selection fails the build instead of silently packaging new bytes.
final class GameSourceCompanionPairedProvider: GameDistributionPairedSourceProvider,
                                              @unchecked Sendable {
    private let selection: GameSourceCompanionSelection

    init(selection: GameSourceCompanionSelection) throws {
        try selection.beginUse()
        self.selection = selection
    }

    deinit {
        selection.endUse()
    }

    func resolve(_ artifactID: String) async throws -> GameDistributionPairedSourceResolution? {
        guard artifactID == selection.pairedSourceID else { return nil }
        guard selection.isReadable else {
            throw GameSourceCompanionError.selectionRemoved
        }
        let resolution = try GamePortableSourceOfferResolver.verifyBundleFile(
            selection.bundleURL, packID: selection.packID,
            bundleID: selection.bundleID, sha256: selection.sha256,
            bytes: selection.bytes)
        return .init(url: resolution.bundleURL, sha256: resolution.sha256,
                     bytes: resolution.bytes)
    }
}

/// Per-owner source-companion storage. There is no global "current player" or
/// first-conversation lookup; every read uses the full identity key.
@MainActor
final class GameSourceCompanionStore {
    private struct Entry {
        let selection: GameSourceCompanionSelection
        let snapshot: GameSourceCompanionSnapshot
    }

    private var entries: [GameSourceCompanionIdentity: Entry] = [:]

    var count: Int { entries.count }

    func snapshot(for identity: GameSourceCompanionIdentity) -> GameSourceCompanionSnapshot? {
        entries[identity]?.snapshot
    }

    func selection(for identity: GameSourceCompanionIdentity) -> GameSourceCompanionSelection? {
        entries[identity]?.selection
    }

    @discardableResult
    func install(_ selection: GameSourceCompanionSelection) -> GameSourceCompanionSnapshot {
        if let previous = entries.removeValue(forKey: selection.identity) {
            previous.selection.retire()
        }
        entries[selection.identity] = Entry(selection: selection, snapshot: selection.snapshot)
        return selection.snapshot
    }

    func remove(_ identity: GameSourceCompanionIdentity) {
        entries.removeValue(forKey: identity)?.selection.retire()
    }

    func provider(for identity: GameSourceCompanionIdentity)
        -> (any GameDistributionPairedSourceProvider)? {
        guard let selection = entries[identity]?.selection else { return nil }
        return try? GameSourceCompanionPairedProvider(selection: selection)
    }

    /// Fences owner/project/root/engine/environment changes. Entries for the
    /// same owner but a different root, engine or environment are retired; an
    /// in-flight build keeps its own reference until it finishes.
    func retireStale(projectID: UUID, owner: GameProjectOwner, rootPath: String,
                     keepingEngine: GameEngineID, environmentID: String?) {
        var stale: [GameSourceCompanionIdentity] = []
        for identity in entries.keys where identity.projectID == projectID
            && identity.owner == owner
            && (identity.rootPath != rootPath
                || identity.engine != keepingEngine
                || identity.environmentID != environmentID) {
            stale.append(identity)
        }
        for identity in stale {
            entries.removeValue(forKey: identity)?.selection.retire()
        }
    }

    func retireAll(projectID: UUID, owner: GameProjectOwner) {
        var stale: [GameSourceCompanionIdentity] = []
        for identity in entries.keys where identity.projectID == projectID
            && identity.owner == owner {
            stale.append(identity)
        }
        for identity in stale {
            entries.removeValue(forKey: identity)?.selection.retire()
        }
    }
}
#endif

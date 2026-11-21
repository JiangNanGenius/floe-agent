// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import CryptoKit
import FloeCore
import FloeTools
import FloeWorkspace
import FloeGameCore
import FloeGameRuntime
import FloeGameRunKit
import FloeGamePortableKit
import FloeGameBuildKit
import FloeGameStarterKit

// MARK: - Product manifest

/// One file in a reviewed runtime resource. Paths are relative to the resource
/// root; the digest and byte count are verified before any engine can use the
/// resource. The optional URL is only used by an explicit user-triggered
/// acquisition; bundled resources never need it.
struct GameRuntimeResourceFileRecord: Codable, Sendable, Equatable {
    let path: String
    let sha256: String
    let bytes: Int
    let url: URL?

    private enum CodingKeys: String, CodingKey { case path, sha256, bytes, url }
}

struct GameRuntimeRemoteArchive: Codable, Sendable, Equatable {
    /// Nil for a reviewed pack archive that has not been published yet. A nil
    /// URL is never treated as ready or silently substituted.
    let url: URL?
    /// Nil until the producer has generated the exact archive and its digest
    /// has been recorded. A missing digest never becomes a download.
    let sha256: String?
    enum Assembly: String, Codable, Sendable { case rpgMakerMVCoreScript }
    let assembly: Assembly?
    let format: String
    let markers: [String]
    let markerContents: [String: String]

    private enum CodingKeys: String, CodingKey {
        case url, sha256, assembly, format, markers, markerContents
    }
}

/// Small, App-bundled notice bundle materialized after an official archive is
/// downloaded. Every file is re-hashed; a missing or changed notice is a hard
/// failure, not a silent omission.
struct GameRuntimeAttribution: Codable, Sendable, Equatable {
    let bundledDirectory: String
    let files: [GameRuntimeResourceFileRecord]
}

struct GameRuntimePackManifest: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case reviewedPackArchive
        case remoteFiles
        case remoteArchive
        case enginePackStore
        case hostRuntime
        case userProvided
        case ciProvided
    }

    let id: String
    /// ``primary`` participates in engine readiness. ``supplementary`` is
    /// acquirable but never gates the engine by itself.
    let role: String
    let engines: [String]
    let displayName: String
    let version: String
    let license: String
    let kind: Kind
    let bundledDirectory: String?
    let sourceDirectory: String?
    let portableManifest: String?
    let portableManifestSource: String?
    let sourceCommit: String?
    /// Logical id in ``source-accompaniment.json``. Nil means this pack has no
    /// reviewed source/notice companion record.
    let sourceAccompanimentID: String?
    /// Existing FloeGameBuildKit distribution profile used by an explicit
    /// export. Nil never invents a profile.
    let distributionProfileID: String?
    let attribution: GameRuntimeAttribution?
    let files: [GameRuntimeResourceFileRecord]
    let licenseFiles: [String]
    let markers: [String]
    let archive: GameRuntimeRemoteArchive?
    let requirement: String?
    let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case id, role, engines, displayName, version, license, kind
        case bundledDirectory, sourceDirectory, portableManifest, portableManifestSource
        case sourceCommit, sourceAccompanimentID, distributionProfileID, attribution
        case files, licenseFiles, markers, archive, requirement, notes
    }

    var engineIDs: [GameEngineID] {
        engines.compactMap(GameEngineID.init(rawValue:))
    }
}

struct GameRuntimeResourceManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generatedFrom: String
    let packs: [GameRuntimePackManifest]
}

// MARK: - Readiness

enum GameRuntimeInstallState: Sendable, Equatable {
    /// The state has not been evaluated yet. It is never presented as ready.
    case unknown
    case ready(version: String, root: URL?)
    case downloadable(bytes: Int?)
    case installing(phase: String)
    case missing(String)
    case failed(String)
    case userAction(String)
}

struct GameRuntimeEngineReadiness: Sendable, Equatable {
    let engine: GameEngineID
    let packID: String
    let displayName: String
    let version: String
    let state: GameRuntimeInstallState

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var canDownload: Bool {
        if case .downloadable = state { return true }
        return false
    }

    var canRetry: Bool {
        if case .failed = state { return true }
        return false
    }

    var root: URL? {
        if case .ready(_, let root) = state { return root }
        return nil
    }

    var statusText: String {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch state {
        case .unknown:
            return zh ? "尚未检查运行资源。" : "The runtime resource has not been checked yet."
        case .ready(let version, _):
            return zh ? "已就绪 \(version)" : "Ready \(version)"
        case .downloadable(let bytes):
            if let bytes {
                return zh ? "可下载（\(bytes) 字节）" : "Available to download (\(bytes) bytes)"
            }
            return zh ? "可下载" : "Available to download"
        case .installing(let phase):
            return phase
        case .missing(let detail), .failed(let detail):
            return detail
        case .userAction(let detail):
            return detail
        }
    }
}

/// Truthful product status for the exact source/notice accompaniment. It is
/// independent from runtime readiness: a verified runtime can exist while its
/// public source offer is still unpublished.
enum GameRuntimeSourceAccompanimentStatus: Sendable, Equatable {
    case unavailable(String)
    case unpublished(String)
    case localVerified(String)
    case published(String)

    var isDistributionReady: Bool {
        if case .published = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .unavailable(let detail), .unpublished(let detail),
             .localVerified(let detail), .published(let detail):
            return detail
        }
    }
}

enum GameRuntimeResourceError: Error, LocalizedError, Equatable {
    case manifestUnavailable
    case unsupportedEngine(GameEngineID)
    case resourceNotBundled(packID: String, expectedPath: String)
    case configurationRequired(String)
    case downloadFailed(String)
    case digestMismatch(String)
    case corruptInstallation(String)
    case extractionFailed(String)
    case destinationExists(String)
    case missingDeclaredFile(String)

    var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .manifestUnavailable:
            return zh ? "运行资源清单不可用，无法验证引擎资源。"
                : "The runtime resource manifest is unavailable, so engine resources cannot be verified."
        case .unsupportedEngine(let engine):
            return zh ? "没有为 \(engine.rawValue) 配置运行资源。"
                : "No runtime resource is configured for \(engine.rawValue)."
        case .resourceNotBundled(let packID, let expectedPath):
            return zh
                ? "\(packID) 未随 App 一起复制到 \(expectedPath)。请执行资源复制步骤后重试。"
                : "\(packID) was not copied into the App at \(expectedPath). Run the reviewed resource-copy step and retry."
        case .configurationRequired(let detail):
            return detail
        case .downloadFailed(let detail):
            return zh ? "运行资源下载失败：\(detail)" : "Runtime resource download failed: \(detail)"
        case .digestMismatch(let detail):
            return zh ? "运行资源校验失败：\(detail)" : "Runtime resource verification failed: \(detail)"
        case .corruptInstallation(let detail):
            return zh ? "已安装的运行资源损坏：\(detail)"
                : "The installed runtime resource is corrupt: \(detail)"
        case .extractionFailed(let detail):
            return zh ? "运行资源解压失败：\(detail)" : "Runtime resource extraction failed: \(detail)"
        case .destinationExists(let path):
            return zh ? "运行资源目标已存在：\(path)" : "The runtime resource destination already exists: \(path)"
        case .missingDeclaredFile(let path):
            return zh ? "运行资源清单缺少文件：\(path)" : "A declared runtime resource file is missing: \(path)"
        }
    }
}

// MARK: - Registry

/// App-owned readiness and acquisition for reviewed engine resources. It is
/// the single place that answers:
///
///  * which starter/runtime pack an engine needs;
///  * whether the exact bytes are present and verified;
///  * how to acquire a reviewed downloadable pack on user action;
///  * which real resource roots the execution bridge should receive.
///
/// Bundled resources are copied by the Main integration step from the reviewed
/// fixture tree. They are never guessed from a path's presence: every declared
/// file is size- and SHA-256-verified before readiness becomes `.ready`.
@MainActor @Observable
final class GameRuntimeResourceRegistry {
    private static let renpySDKID = "renpy-8.5.3-sdk"
    private static let renpyWebSupportID = "renpy-8.5.3-web"

    private let manifest: GameRuntimeResourceManifest?
    private let bundledRoot: URL?
    private let installationRoot: URL
    private let enginePackRoot: URL?
    private let packStore: GameEnginePackStore?
    private let installer = GameReviewedResourceInstaller()
    private let sourceCatalog: GamePortableSourceAccompanimentCatalog?

    private var verifiedRoots: [String: URL] = [:]
    private var packRoots: [String: URL] = [:]
    private var attributionRoots: [String: URL] = [:]
    private var installing: [String: Task<Void, any Error>] = [:]

    private(set) var states: [String: GameRuntimeInstallState] = [:]
    private(set) var progress: [String: Double] = [:]

    init(manifest: GameRuntimeResourceManifest? = nil,
         bundledRoot: URL? = nil,
         installationRoot: URL? = nil,
         enginePackRoot: URL? = nil,
         packStore: GameEnginePackStore?) {
        self.manifest = manifest ?? Self.loadManifest()
        self.sourceCatalog = Self.loadSourceCatalog()
        self.bundledRoot = (bundledRoot ?? Bundle.main.url(forResource: "GameRuntime", withExtension: nil))?
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = installationRoot ?? Self.defaultInstallationRoot()
        self.installationRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.enginePackRoot = enginePackRoot?.standardizedFileURL.resolvingSymlinksInPath()
        self.packStore = packStore
        try? FileManager.default.createDirectory(at: self.installationRoot,
                                                 withIntermediateDirectories: true)
    }

    /// Evaluates every primary pack without downloading. File hashing runs off
    /// the main actor; a corrupt or absent pack remains an explicit state.
    func refresh(force: Bool = false) async {
        guard let manifest else { return }
        if force {
            verifiedRoots.removeAll()
            packRoots.removeAll()
        }
        for pack in manifest.packs where pack.role == "primary" {
            guard installing[pack.id] == nil else { continue }
            states[pack.id] = await evaluate(pack)
        }
    }

    func readiness(for engine: GameEngineID) -> GameRuntimeEngineReadiness? {
        guard let pack = primaryPack(for: engine) else { return nil }
        return .init(engine: engine, packID: pack.id, displayName: pack.displayName,
                     version: pack.version,
                     state: states[pack.id] ?? .unknown)
    }

    /// User-triggered acquisition. It coalesces concurrent requests for the
    /// same pack, reports phase/byte progress, and never replaces an existing
    /// verified installation. Failures keep the previous verified state.
    @discardableResult
    func prepare(for engine: GameEngineID) async throws -> GameRuntimeEngineReadiness {
        guard let pack = primaryPack(for: engine) else {
            throw GameRuntimeResourceError.unsupportedEngine(engine)
        }
        if case .ready? = states[pack.id] {
            return readiness(for: engine)!
        }
        if let existing = installing[pack.id] {
            try await existing.value
            if let value = readiness(for: engine), value.isReady { return value }
        }
        // A failed remote installation may have left an unverified partial
        // directory. Remove only that owned, non-ready installation so a user
        // retry can start clean; a verified installation is never touched.
        if case .failed? = states[pack.id] {
            switch pack.kind {
            case .remoteArchive where pack.id == Self.renpySDKID:
                // A failed companion download must not discard a valid SDK.
                break
            case .reviewedPackArchive, .remoteArchive, .remoteFiles:
                try? FileManager.default.removeItem(
                    at: installationRoot.appendingPathComponent(pack.id, isDirectory: true))
            case .enginePackStore:
                if let enginePackRoot {
                    try? FileManager.default.removeItem(
                        at: enginePackRoot.appendingPathComponent(pack.id, isDirectory: true))
                }
            default:
                break
            }
            verifiedRoots.removeValue(forKey: pack.id)
        }
        let task = Task { try await self.install(pack) }
        installing[pack.id] = task
        states[pack.id] = .installing(phase: FloeL10n.l("app.game_runtime_resource_registry.preparing_runtime_resource"))
        do {
            try await task.value
            installing[pack.id] = nil
            progress[pack.id] = nil
            if let value = readiness(for: engine) { return value }
            throw GameRuntimeResourceError.corruptInstallation(pack.id)
        } catch is CancellationError {
            installing[pack.id] = nil
            progress[pack.id] = nil
            if case .installing? = states[pack.id] {
                states[pack.id] = .downloadable(bytes: nil)
            }
            throw CancellationError()
        } catch {
            installing[pack.id] = nil
            progress[pack.id] = nil
            states[pack.id] = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Cancels an in-flight user-triggered acquisition. The installer removes
    /// its staging tree; the signed pack store cancels its own preparation.
    func cancelPreparation(for engine: GameEngineID) async {
        guard let pack = primaryPack(for: engine) else { return }
        installing[pack.id]?.cancel()
        installing[pack.id] = nil
        progress[pack.id] = nil
        if case .installing? = states[pack.id] {
            states[pack.id] = .downloadable(bytes: nil)
        }
        if pack.kind == .enginePackStore,
           let packStore, let engineID = pack.engineIDs.first {
            await packStore.cancelPreparation(engineID)
        }
    }

    /// A first-run check without a network request. Used before creating a
    /// starter so a missing pack is reported before an empty project is made.
    func requireReady(_ engine: GameEngineID) throws -> URL? {
        guard let value = readiness(for: engine) else {
            throw GameRuntimeResourceError.unsupportedEngine(engine)
        }
        switch value.state {
        case .ready(_, let root):
            return root
        case .downloadable:
            throw GameRuntimeResourceError.configurationRequired(
                FloeL10n.l("app.game_runtime_resource_registry.is_not_installed_download_it", value.displayName))
        case .installing(let phase):
            throw GameRuntimeResourceError.configurationRequired(phase)
        case .missing(let detail), .failed(let detail), .userAction(let detail):
            throw GameRuntimeResourceError.configurationRequired(detail)
        case .unknown:
            throw GameRuntimeResourceError.configurationRequired(
                FloeL10n.l("app.game_runtime_resource_registry.runtime_resources_are_still_being"))
        }
    }

    // MARK: Source accompaniment

    /// The existing BuildKit distribution profile for this engine, if the pack
    /// declared one. It is an explicit export choice, never auto-trusted.
    func distributionProfileID(for engine: GameEngineID) -> String? {
        primaryPack(for: engine)?.distributionProfileID
    }

    func sourceAccompanimentStatus(for engine: GameEngineID) -> GameRuntimeSourceAccompanimentStatus {
        guard let pack = primaryPack(for: engine),
              let id = pack.sourceAccompanimentID else {
            return .unavailable(FloeL10n.l("app.game_runtime_resource_registry.no_reviewed_corresponding_source_notice"))
        }
        guard let catalog = sourceCatalog, let item = catalog.packs[id] else {
            return .unavailable(FloeL10n.l("app.game_runtime_resource_registry.the_source_accompaniment_catalog_is"))
        }
        if item.publication.state == "published" {
            return .published(item.publication.detail)
        }
        if item.publication.state == "bundled-source-present"
            || item.publication.state == "mit-source-included"
            || item.publication.state == "mit-runtime-only"
            || item.publication.state == "apache-runtime-only" {
            return .localVerified(item.publication.detail)
        }
        return .unpublished(item.publication.detail)
    }

    /// Directory containing the materialized notice bundle, when one was
    /// copied for an installed official archive. It is not a source depot.
    func attributionRoot(for engine: GameEngineID) -> URL? {
        guard let pack = primaryPack(for: engine) else { return nil }
        return attributionRoots[pack.id]
    }

    /// The decoded exact-source record for this engine, if the bundled catalog
    /// and the installed primary pack both declare one.
    func sourceAccompanimentPack(for engine: GameEngineID) -> GamePortableSourcePackAccompaniment? {
        guard let pack = primaryPack(for: engine),
              let id = pack.sourceAccompanimentID else { return nil }
        return sourceCatalog?.packs[id]
    }

    func sourceAccompanimentCatalog() -> GamePortableSourceAccompanimentCatalog? {
        sourceCatalog
    }

    /// True only when the current pack declares both an exact bundle and a
    /// paired-source id for its existing BuildKit distribution profile. Other
    /// engines keep their ordinary export path without any companion prompt.
    func requiresPairedSource(for engine: GameEngineID) -> Bool {
        guard distributionProfileID(for: engine) != nil,
              let item = sourceAccompanimentPack(for: engine) else { return false }
        return item.pairedSourceID != nil && item.sourceBundle != nil
    }

    /// Resolves the existing GameBuildKit paired-source id from a user-imported
    /// exact source offer. Both real producer layouts are accepted through the
    /// shared descriptor-relative resolver: `<root>/sources/exact/<id>` and the
    /// flat `<root>/<id>` (or the bundle file itself). No manifest claim is
    /// authority; the catalog's size/SHA-256 must match the actual bytes. An
    /// absent/mismatched file returns nil so distribution fails closed.
    func pairedSourceProvider(for engine: GameEngineID,
                              sourceOfferRoot: URL) -> (any GameDistributionPairedSourceProvider)? {
        guard let item = sourceAccompanimentPack(for: engine),
              let pairedID = item.pairedSourceID,
              let resolution = try? GamePortableSourceOfferResolver.resolve(
                pack: item, root: sourceOfferRoot) else { return nil }
        return GameRuntimePairedSourceProvider(resolutions: [
            pairedID: .init(url: resolution.bundleURL, sha256: resolution.sha256,
                            bytes: resolution.bytes)
        ])
    }

    /// Explicit user-rebuilt component seam. The caller must supply a complete
    /// rebuilt resource tree and metadata that names the mutable runtime files;
    /// the validator checks every immutable byte (including licenses) against
    /// the installed base. It does not install, persist or auto-trust the tree.
    func validateUserRuntimeReplacement(for engine: GameEngineID, root: URL,
                                        metadata: Data) throws -> GamePortablePreparedResources {
        guard let base = portableResources()[engine] else {
            throw GameRuntimeResourceError.configurationRequired(FloeL10n.l("app.game_runtime_resource_registry.install_and_verify_the_base"))
        }
        let value = try GamePortableRuntimeReplacementMetadata(from: metadata)
        return try GamePortableUserRuntimeReplacement.validate(
            base: base, replacementRoot: root, metadata: value)
    }

    /// Materializes an exact export companion from caller-supplied local roots
    /// using the shared PortableKit writer. It deliberately cannot conjure a
    /// source depot from the App bundle: missing roots fail closed.
    func exportSourceOffer(for engine: GameEngineID,
                           roots: GamePortableSourceOfferRoots,
                           to destination: URL,
                           mode: GamePortableSourceOfferMode) throws -> GamePortableSourceOfferReceipt {
        guard let pack = primaryPack(for: engine),
              let id = pack.sourceAccompanimentID else {
            throw GameRuntimeResourceError.unsupportedEngine(engine)
        }
        guard let catalog = sourceCatalog else {
            throw GameRuntimeResourceError.configurationRequired(FloeL10n.l("app.game_runtime_resource_registry.the_source_accompaniment_catalog_is_2"))
        }
        return try GamePortableSourceOfferMaterializer.materialize(
            catalog: catalog, packID: id, roots: roots, to: destination, mode: mode)
    }

    // MARK: Execution resource composition

    func starterResources() -> GameStarterResources {
        var resources = GameStarterResources()
        if let root = verifiedRoots["phaser-3.90.0"] { resources.phaser = root }
        for (engine, packID) in [
            (GameEngineID.kaplay, "kaplay-3001.0.0"),
            (.babylon, "babylon-9.35.0"),
            (.playcanvas, "playcanvas-2.24.0"),
        ] {
            if let root = verifiedRoots[packID] { resources.enginePacks[engine] = root }
        }
        return resources
    }

    func portableResources() -> [GameEngineID: GamePortablePreparedResources] {
        var values: [GameEngineID: GamePortablePreparedResources] = [:]
        for (engine, packID) in [
            (GameEngineID.love, "lovejs-11.4.1"),
            (.rpgMakerMV, "rpg-maker-mv-corescript-1.3b"),
        ] {
            guard let pack = manifest?.packs.first(where: { $0.id == packID }),
                  let root = verifiedRoots[packID],
                  let packRoot = packRoots[packID],
                  let manifestPath = pack.portableManifest else { continue }
            let manifestURL = packRoot.appendingPathComponent(manifestPath)
            if let value = try? GamePortablePreparedResources(rootURL: root,
                                                              manifestURL: manifestURL) {
                values[engine] = value
            }
        }
        return values
    }

    var narrativeRoot: URL? { verifiedRoots["narrative-runtime"] }
    var renpySDKRoot: URL? { verifiedRoots[Self.renpySDKID] }

    /// Tool IDs that are genuinely present from reviewed resources. CI-provided
    /// tools are added by `GameBuildToolReadiness` only when a real repository
    /// and credential are configured; developer subscriptions are never probed.
    func providedToolIDs() -> Set<String> {
        var values: Set<String> = []
        if renpySDKRoot != nil { values.insert("renpy-sdk") }
        return values
    }

    func runtimePackProvider() -> (any GameRunRuntimePackProviding)? {
        guard let packStore else { return nil }
        return GameEngineResourcePackProvider(store: packStore)
    }

    func executionResources() -> GameExecutionResources {
        .init(portableResources: portableResources(),
              renpySDK: renpySDKRoot,
              narrativeResources: narrativeRoot,
              runtimePacks: runtimePackProvider(),
              gdevelopSDKRoot: nil,
              gdevelopExportScript: nil,
              providedTools: providedToolIDs())
    }

    // MARK: Evaluation/installation

    private func primaryPack(for engine: GameEngineID) -> GameRuntimePackManifest? {
        manifest?.packs.first { $0.role == "primary" && $0.engines.contains(engine.rawValue) }
    }

    private func evaluate(_ pack: GameRuntimePackManifest) async -> GameRuntimeInstallState {
        if let root = verifiedRoots[pack.id] {
            return .ready(version: pack.version, root: root)
        }
        switch pack.kind {
        case .enginePackStore:
            guard let packStore, let engine = pack.engineIDs.first else {
                return .missing(FloeL10n.l("app.game_runtime_resource_registry.the_signed_engine_pack_store"))
            }
            if let prepared = try? await packStore.prepared(engine) {
                verifiedRoots[pack.id] = prepared.directory
                return .ready(version: pack.version, root: prepared.directory)
            }
            if let root = enginePackRoot?.appendingPathComponent(pack.id),
               FileManager.default.fileExists(atPath: root.path) {
                return .failed(FloeL10n.l("app.game_runtime_resource_registry.the_installed_engine_pack_failed"))
            }
            return .downloadable(bytes: nil)
        case .reviewedPackArchive:
            // Use reviewed resources shipped with the app where available.
            // The same pinned file receipts apply to bundled and installed packs.
            if let root = bundledContentRoot(for: pack) {
                do {
                    try await verify(pack: pack, root: root, requireFiles: true)
                    verifiedRoots[pack.id] = root
                    packRoots[pack.id] = bundledRoot
                    return .ready(version: pack.version, root: root)
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            if let root = installedContentRoot(for: pack) {
                do {
                    try await verify(pack: pack, root: root, requireFiles: true)
                    verifiedRoots[pack.id] = root
                    packRoots[pack.id] = installationRoot.appendingPathComponent(pack.id, isDirectory: true)
                    return .ready(version: pack.version, root: root)
                } catch {
                    return .failed(FloeL10n.l("app.game_runtime_resource_registry.the_installed_resource_failed_verification", error.localizedDescription))
                }
            }
            if resolvedArchiveURL(pack) != nil, hasPinnedArchiveSHA(pack) {
                return .downloadable(bytes: nil)
            }
            return .userAction(pack.requirement ?? (FloeL10n.l("app.game_runtime_resource_registry.this_version_does_not_offer")))
        case .remoteFiles, .remoteArchive:
            guard resolvedArchiveURL(pack) != nil, hasPinnedArchiveSHA(pack) else {
                return .userAction(pack.requirement ?? (FloeL10n.l("app.game_runtime_resource_registry.this_runtime_resource_has_no")))
            }
            let root = installationRoot.appendingPathComponent(pack.id, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else {
                return .downloadable(bytes: nil)
            }
            do {
                try await verify(pack: pack, root: root, requireFiles: pack.kind == .remoteFiles)
                try await ensureAttribution(pack, contentRoot: root, copy: false)
                if pack.id == Self.renpySDKID {
                    let web = try renpyWebSupportPack()
                    guard resolvedArchiveURL(web) != nil, hasPinnedArchiveSHA(web) else {
                        return .userAction(web.requirement ?? web.displayName)
                    }
                    let webRoot = root.appendingPathComponent("web", isDirectory: true)
                    guard FileManager.default.fileExists(atPath: webRoot.path) else {
                        return .downloadable(bytes: nil)
                    }
                    try await verify(pack: web, root: webRoot, requireFiles: true)
                    try await ensureAttribution(web, contentRoot: webRoot, copy: false)
                }
                verifiedRoots[pack.id] = root
                return .ready(version: pack.version, root: root)
            } catch {
                return .failed(FloeL10n.l("app.game_runtime_resource_registry.the_installed_resource_failed_verification", error.localizedDescription))
            }
        case .hostRuntime:
            return .ready(version: pack.version, root: nil)
        case .userProvided, .ciProvided:
            return .userAction(pack.requirement ?? (FloeL10n.l("app.game_runtime_resource_registry.configure_the_engine_tool_or")))
        }
    }

    private func install(_ pack: GameRuntimePackManifest) async throws {
        switch pack.kind {
        case .enginePackStore:
            guard let packStore, let engine = pack.engineIDs.first else {
                throw GameRuntimeResourceError.configurationRequired(
                    FloeL10n.l("app.game_runtime_resource_registry.the_signed_engine_pack_store"))
            }
            let prepared: GameEngineResourcePack
            do {
                prepared = try await packStore.prepare(engine)
            } catch {
                throw GameRuntimeResourceError.downloadFailed(error.localizedDescription)
            }
            verifiedRoots[pack.id] = prepared.directory
            states[pack.id] = .ready(version: pack.version, root: prepared.directory)
        case .remoteFiles:
            guard let url = resolvedArchiveURL(pack),
                  let sha = pack.archive?.sha256, !sha.isEmpty else {
                throw GameRuntimeResourceError.configurationRequired(
                    pack.requirement ?? "This resource has no published archive URL or pinned SHA-256.")
            }
            let destination = installationRoot.appendingPathComponent(pack.id, isDirectory: true)
            let root = try await installer.installFiles(pack, destination: destination) { [weak self, id = pack.id] value in
                Task { @MainActor in self?.progress[id] = value }
            }
            try await verify(pack: pack, root: root, requireFiles: true)
            verifiedRoots[pack.id] = root
            packRoots[pack.id] = destination
            states[pack.id] = .ready(version: pack.version, root: root)
        case .remoteArchive:
            guard let url = resolvedArchiveURL(pack),
                  let sha = pack.archive?.sha256, !sha.isEmpty else {
                throw GameRuntimeResourceError.configurationRequired(
                    pack.requirement ?? "This runtime resource has no published archive URL or pinned SHA-256.")
            }
            let destination = installationRoot.appendingPathComponent(pack.id, isDirectory: true)
            let isRenPy = pack.id == Self.renpySDKID
            let root: URL
            if isRenPy, FileManager.default.fileExists(atPath: destination.path),
               (try? await verify(pack: pack, root: destination, requireFiles: false)) != nil {
                root = destination
            } else {
                if isRenPy, FileManager.default.fileExists(atPath: destination.path) {
                    try Task.checkCancellation()
                    try FileManager.default.removeItem(at: destination)
                }
                root = try await installer.installArchive(pack, archiveURL: url,
                    expectedSHA256: sha, destination: destination,
                    contentSubdirectory: nil) { [weak self, id = pack.id] value in
                    Task { @MainActor in self?.progress[id] = isRenPy ? value * 0.70 : value }
                }
            }
            try await verify(pack: pack, root: root, requireFiles: false)
            try await ensureAttribution(pack, contentRoot: root, copy: true)
            if isRenPy { try await prepareRenPyWebSupport(in: root) }
            try Task.checkCancellation()
            verifiedRoots[pack.id] = root
            packRoots[pack.id] = destination
            states[pack.id] = .ready(version: pack.version, root: root)
        case .reviewedPackArchive:
            if let root = bundledContentRoot(for: pack) {
                try await verify(pack: pack, root: root, requireFiles: true)
                verifiedRoots[pack.id] = root
                packRoots[pack.id] = bundledRoot
                states[pack.id] = .ready(version: pack.version, root: root)
                return
            }
            guard let url = resolvedArchiveURL(pack),
                  let sha = pack.archive?.sha256, !sha.isEmpty else {
                throw GameRuntimeResourceError.configurationRequired(
                    pack.requirement ?? (FloeL10n.l("app.game_runtime_resource_registry.this_version_does_not_offer")))
            }
            let destination = installationRoot.appendingPathComponent(pack.id, isDirectory: true)
            let root = try await installer.installArchive(pack, archiveURL: url,
                expectedSHA256: sha, destination: destination,
                contentSubdirectory: pack.bundledDirectory) { [weak self, id = pack.id] value in
                Task { @MainActor in self?.progress[id] = value }
            }
            try await verify(pack: pack, root: root, requireFiles: true)
            verifiedRoots[pack.id] = root
            packRoots[pack.id] = destination
            states[pack.id] = .ready(version: pack.version, root: root)
        case .hostRuntime:
            states[pack.id] = .ready(version: pack.version, root: nil)
        case .userProvided, .ciProvided:
            throw GameRuntimeResourceError.configurationRequired(pack.requirement ?? pack.displayName)
        }
    }

    private func renpyWebSupportPack() throws -> GameRuntimePackManifest {
        guard let pack = manifest?.packs.first(where: {
            $0.id == Self.renpyWebSupportID && $0.role == "supplementary" && $0.kind == .remoteArchive
        }) else { throw GameRuntimeResourceError.manifestUnavailable }
        return pack
    }

    /// The official launcher expects the matching Web support under SDK/web.
    /// Keep the SDK when an upgrade only needs to fetch that companion.
    private func prepareRenPyWebSupport(in sdk: URL) async throws {
        let pack = try renpyWebSupportPack()
        guard let url = resolvedArchiveURL(pack), let sha = pack.archive?.sha256,
              hasPinnedArchiveSHA(pack) else {
            throw GameRuntimeResourceError.configurationRequired(pack.requirement ?? pack.displayName)
        }
        let files = FileManager.default
        let destination = sdk.appendingPathComponent("web", isDirectory: true)
        if files.fileExists(atPath: destination.path) {
            do {
                try await verify(pack: pack, root: destination, requireFiles: true)
                try await ensureAttribution(pack, contentRoot: destination, copy: false)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Preserve the installed tree until its replacement is verified.
            }
        }
        let staged = installationRoot.appendingPathComponent(".renpy-web-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? files.removeItem(at: staged)
            if attributionRoots[pack.id] == staged.appendingPathComponent("FloeAttribution", isDirectory: true) {
                attributionRoots.removeValue(forKey: pack.id)
            }
        }
        let prepared = try await installer.installArchive(pack, archiveURL: url, expectedSHA256: sha,
            destination: staged, contentSubdirectory: nil) { [weak self] value in
            Task { @MainActor in self?.progress[Self.renpySDKID] = 0.70 + value * 0.30 }
        }
        try await verify(pack: pack, root: prepared, requireFiles: true)
        try await ensureAttribution(pack, contentRoot: prepared, copy: true)
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: prepared,
                                        backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: prepared, to: destination)
        }
        attributionRoots[pack.id] = destination.appendingPathComponent("FloeAttribution", isDirectory: true)
    }

    private func bundledContentRoot(for pack: GameRuntimePackManifest) -> URL? {
        guard let bundledRoot else { return nil }
        let root = pack.bundledDirectory.map {
            bundledRoot.appendingPathComponent($0, isDirectory: true)
        } ?? bundledRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func installedContentRoot(for pack: GameRuntimePackManifest) -> URL? {
        let packRoot = installationRoot.appendingPathComponent(pack.id, isDirectory: true)
        let root = pack.bundledDirectory.map {
            packRoot.appendingPathComponent($0, isDirectory: true)
        } ?? packRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func resolvedArchiveURL(_ pack: GameRuntimePackManifest) -> URL? {
        if let url = pack.archive?.url { return url }
        guard let base = GameRuntimeResourceDistribution.baseURL else { return nil }
        return base.appendingPathComponent("\(pack.id)-\(pack.version).tar.xz")
    }

    private func hasPinnedArchiveSHA(_ pack: GameRuntimePackManifest) -> Bool {
        guard let value = pack.archive?.sha256 else { return false }
        return value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// Verifies and materializes the small App-bundled notice bundle for an
    /// official archive. The source archive bytes stay the official download;
    /// this only supplies the applicable notices and explicit attribution.
    private func ensureAttribution(_ pack: GameRuntimePackManifest,
                                   contentRoot: URL, copy: Bool) async throws {
        guard let attribution = pack.attribution else { return }
        guard let sourceRoot = Self.bundledAttributionRoot(attribution) else {
            throw GameRuntimeResourceError.configurationRequired(FloeL10n.l("app.game_runtime_resource_registry.the_runtime_declares_a_bundled"))
        }
        let targetRoot = contentRoot.appendingPathComponent("FloeAttribution", isDirectory: true)
        if copy {
            try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        }
        for file in attribution.files {
            guard Self.safeRelativePath(file.path) else {
                throw GameRuntimeResourceError.corruptInstallation("unsafe attribution path \(file.path)")
            }
            let source = sourceRoot.appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: source, options: [.mappedIfSafe]),
                  data.count == file.bytes,
                  let sourceDigest = try? GameRuntimeDigest.sha256(source),
                  sourceDigest == file.sha256 else {
                throw GameRuntimeResourceError.digestMismatch("attribution \(file.path)")
            }
            let target = targetRoot.appendingPathComponent(file.path)
            if copy {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    guard let existing = try? Data(contentsOf: target, options: [.mappedIfSafe]),
                          existing.count == file.bytes,
                          let existingDigest = try? GameRuntimeDigest.sha256(target),
                          existingDigest == file.sha256 else {
                        throw GameRuntimeResourceError.digestMismatch("existing attribution \(file.path)")
                    }
                } else {
                    try data.write(to: target, options: [.atomic])
                    guard let copiedDigest = try? GameRuntimeDigest.sha256(target),
                          copiedDigest == file.sha256 else {
                        throw GameRuntimeResourceError.digestMismatch("copied attribution \(file.path)")
                    }
                }
            } else {
                guard FileManager.default.fileExists(atPath: target.path),
                      let existing = try? Data(contentsOf: target, options: [.mappedIfSafe]),
                      existing.count == file.bytes,
                      let existingDigest = try? GameRuntimeDigest.sha256(target),
                      existingDigest == file.sha256 else {
                    throw GameRuntimeResourceError.missingDeclaredFile("FloeAttribution/\(file.path)")
                }
            }
        }
        attributionRoots[pack.id] = targetRoot
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func bundledAttributionRoot(_ attribution: GameRuntimeAttribution,
                                               bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let relative = attribution.bundledDirectory
            .replacingOccurrences(of: "Attribution/", with: "")
        let candidates = [
            resources.appendingPathComponent("GameRuntime/Attribution/", isDirectory: true)
                .appendingPathComponent(relative, isDirectory: true),
            resources.appendingPathComponent("GameRuntime/", isDirectory: true)
                .appendingPathComponent(attribution.bundledDirectory, isDirectory: true),
            resources.appendingPathComponent(attribution.bundledDirectory, isDirectory: true),
        ]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    private func verify(pack: GameRuntimePackManifest, root: URL,
                        requireFiles: Bool) async throws {
        let input = GameRuntimeVerificationInput(
            root: root,
            files: requireFiles ? pack.files : [],
            markers: pack.markers,
            markerContents: pack.archive?.markerContents ?? [:])
        try await Task.detached(priority: .utility) {
            try GameRuntimeResourceVerifier.verify(input)
        }.value
    }

    // MARK: Bundle locations

    private static func loadManifest(from bundle: Bundle = .main) -> GameRuntimeResourceManifest? {
        let candidates = [
            bundle.url(forResource: "registry", withExtension: "json",
                       subdirectory: "GameRuntime"),
            bundle.url(forResource: "manifest", withExtension: "json",
                       subdirectory: "GameRuntimeResources"),
            bundle.url(forResource: "registry", withExtension: "json"),
        ].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode(GameRuntimeResourceManifest.self, from: data),
                  value.schemaVersion == 1 else { continue }
            return value
        }
        return nil
    }

    private static func loadSourceCatalog(from bundle: Bundle = .main) -> GamePortableSourceAccompanimentCatalog? {
        let candidates = [
            bundle.url(forResource: "source-accompaniment", withExtension: "json",
                       subdirectory: "GameRuntime"),
            bundle.url(forResource: "source-accompaniment", withExtension: "json"),
        ].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let value = try? GamePortableSourceAccompanimentCatalog(from: data) else { continue }
            return value
        }
        return nil
    }

    private static func defaultInstallationRoot() -> URL {
        // Installed engine packs are durable user resources. If the artifact
        // store cannot resolve, keep using the App's persistent Application
        // Support container instead of a temporary directory, which would
        // silently discard a verified installation on the next launch.
        let base = (try? FloeArtifactStore.root())
            ?? URL.applicationSupportDirectory.appendingPathComponent("FloeAgent", isDirectory: true)
        return base.appendingPathComponent("GameRuntimeResources", isDirectory: true)
    }
}

// MARK: - Verification

struct GameRuntimeVerificationInput: Sendable {
    let root: URL
    let files: [GameRuntimeResourceFileRecord]
    let markers: [String]
    let markerContents: [String: String]
}

enum GameRuntimeResourceVerifier {
    static func verify(_ input: GameRuntimeVerificationInput) throws {
        let root = input.root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GameRuntimeResourceError.corruptInstallation("resource root is not a directory")
        }
        for file in input.files {
            let target = try confinedPath(file.path, root: root)
            guard let values = try? target.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true else {
                throw GameRuntimeResourceError.missingDeclaredFile(file.path)
            }
            guard values.fileSize == file.bytes else {
                throw GameRuntimeResourceError.digestMismatch("\(file.path) size")
            }
            guard try GameRuntimeDigest.sha256(target) == file.sha256 else {
                throw GameRuntimeResourceError.digestMismatch(file.path)
            }
        }
        for marker in input.markers {
            let target = try confinedPath(marker, root: root)
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw GameRuntimeResourceError.missingDeclaredFile(marker)
            }
        }
        for (path, expected) in input.markerContents {
            let target = try confinedPath(path, root: root)
            guard let data = try? Data(contentsOf: target, options: [.mappedIfSafe]),
                  let text = String(data: data, encoding: .utf8) else {
                throw GameRuntimeResourceError.missingDeclaredFile(path)
            }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
                throw GameRuntimeResourceError.digestMismatch(path)
            }
        }
    }

    private static func confinedPath(_ relative: String, root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GameRuntimeResourceError.corruptInstallation("unsafe resource path \(relative)")
        }
        let target = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw GameRuntimeResourceError.corruptInstallation("resource path escapes its root")
        }
        return target
    }
}

enum GameRuntimeDigest {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Installer

/// Downloads only an explicitly requested reviewed archive/file, verifies its
/// byte identity, and moves a fully verified tree into place. A failed or
/// cancelled install removes its staging directory and leaves any previous
/// verified installation untouched.
actor GameReviewedResourceInstaller {
    private static let maximumDownloadBytes = 4 * 1024 * 1024 * 1024
    private static let extractionLimits = ArchiveLimits(
        maxEntries: 200_000,
        maxTotalBytes: 4 * 1024 * 1024 * 1024,
        maxListedEntries: 500)

    func installFiles(_ pack: GameRuntimePackManifest, destination: URL,
                      progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard !pack.files.isEmpty else {
            throw GameRuntimeResourceError.corruptInstallation("no files in \(pack.id)")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw GameRuntimeResourceError.destinationExists(destination.path)
        }
        let stage = parent.appendingPathComponent(".prepare-\(pack.id)-\(UUID().uuidString)",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        for (index, file) in pack.files.enumerated() {
            try Task.checkCancellation()
            guard let url = file.url else {
                throw GameRuntimeResourceError.missingDeclaredFile(file.path)
            }
            let downloaded = try await download(url, maximumBytes: Self.maximumDownloadBytes)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            let size = Self.fileSize(downloaded)
            guard size == file.bytes else {
                throw GameRuntimeResourceError.digestMismatch("\(file.path) size")
            }
            guard try GameRuntimeDigest.sha256(downloaded) == file.sha256 else {
                throw GameRuntimeResourceError.digestMismatch(file.path)
            }
            let target = stage.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: downloaded, to: target)
            progress(Double(index + 1) / Double(pack.files.count) * 0.9)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
        progress(1)
        return destination
    }

    func installArchive(_ pack: GameRuntimePackManifest, archiveURL: URL,
                        expectedSHA256: String, destination: URL,
                        contentSubdirectory: String?,
                        progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard let archive = pack.archive else {
            throw GameRuntimeResourceError.extractionFailed("no archive metadata for \(pack.id)")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw GameRuntimeResourceError.destinationExists(destination.path)
        }
        progress(0.02)
        let downloaded = try await download(archiveURL, maximumBytes: Self.maximumDownloadBytes)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        progress(0.45)
        guard try GameRuntimeDigest.sha256(downloaded) == expectedSHA256 else {
            throw GameRuntimeResourceError.digestMismatch(pack.id)
        }
        progress(0.55)
        let stage = parent.appendingPathComponent(".prepare-\(pack.id)-\(UUID().uuidString)",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let extracted = stage.appendingPathComponent("extracted", isDirectory: true)
        try await extract(format: Self.archiveEngineFormat(archive.format),
                          source: downloaded, destination: extracted)
        progress(0.9)
        if archive.assembly == .rpgMakerMVCoreScript {
            guard let contentSubdirectory, let manifestPath = pack.portableManifest,
                  let bundleRoot = Bundle.main.resourceURL?.appendingPathComponent("GameRuntime") else {
                throw GameRuntimeResourceError.corruptInstallation(pack.id)
            }
            let source = try findRoot(in: extracted, markers: archive.markers,
                                      markerContents: archive.markerContents)
            let prepared = stage.appendingPathComponent("prepared", isDirectory: true)
            let content = prepared.appendingPathComponent(contentSubdirectory, isDirectory: true)
            let notices = bundleRoot.appendingPathComponent("Attribution/rpg-maker-mv")
            try Self.assembleMV(pack, source: source, notices: notices, destination: content)
            let manifest = prepared.appendingPathComponent(manifestPath)
            try FileManager.default.copyItem(at: bundleRoot.appendingPathComponent(manifestPath), to: manifest)
            _ = try GamePortablePreparedResources(rootURL: content, manifestURL: manifest)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: prepared, to: destination)
            progress(1)
            return destination.appendingPathComponent(contentSubdirectory, isDirectory: true)
        }
        if let contentSubdirectory {
            guard FileManager.default.fileExists(
                atPath: extracted.appendingPathComponent("PACK-MANIFEST.json").path) else {
                throw GameRuntimeResourceError.extractionFailed(
                    "reviewed pack archive has no PACK-MANIFEST.json")
            }
            let content = extracted.appendingPathComponent(contentSubdirectory, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: content.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw GameRuntimeResourceError.extractionFailed(
                    "reviewed pack archive has no \(contentSubdirectory)")
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: extracted, to: destination)
            progress(1)
            return destination.appendingPathComponent(contentSubdirectory, isDirectory: true)
        }
        let root = try findRoot(in: extracted, markers: archive.markers,
                                markerContents: archive.markerContents)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: root, to: destination)
        progress(1)
        return destination
    }

    /// Reproduce the reviewed CoreScript producer using the pinned upstream
    /// source. Only the verified runtime files and bundled notices are installed.
    static func assembleMV(_ pack: GameRuntimePackManifest, source: URL,
                           notices: URL, destination: URL) throws {
        let files = FileManager.default
        for record in pack.files {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(record.path)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if record.path.hasPrefix("js/rpg_") {
                let name = target.deletingPathExtension().lastPathComponent
                let list = source.appendingPathComponent("\(name).json")
                let modules = try JSONDecoder().decode([String].self, from: Data(contentsOf: list))
                var combined = Data()
                for (index, module) in modules.enumerated() {
                    let path = try GameRelativePath(module)
                    guard path.value.hasPrefix("js/\(name)/"), path.value.hasSuffix(".js") else {
                        throw GameRuntimeResourceError.corruptInstallation(record.path)
                    }
                    if index != 0 { combined.append(10) }
                    combined.append(try Data(contentsOf: source.appendingPathComponent(path.value)))
                    guard combined.count <= record.bytes else {
                        throw GameRuntimeResourceError.digestMismatch(record.path)
                    }
                }
                try combined.write(to: target)
            } else {
                try files.copyItem(at: (record.path.hasPrefix("js/libs/") ? source : notices)
                    .appendingPathComponent(record.path), to: target)
            }
        }
        try GameRuntimeResourceVerifier.verify(.init(root: destination, files: pack.files,
            markers: pack.markers, markerContents: [:]))
    }

    // MARK: Download/extract

    private func download(_ url: URL, maximumBytes: Int) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw GameRuntimeResourceError.downloadFailed("HTTPS is required")
        }
        let result: (URL, URLResponse)
        do {
            result = try await URLSession.shared.download(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameRuntimeResourceError.downloadFailed(error.localizedDescription)
        }
        let temporary = result.0
        let response = result.1
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GameRuntimeResourceError.downloadFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = Self.fileSize(temporary)
        guard size > 0, size <= maximumBytes else {
            throw GameRuntimeResourceError.downloadFailed("download size \(size) exceeds the limit")
        }
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-game-runtime-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temporary, to: local)
        return local
    }

    private static func archiveEngineFormat(_ value: String) -> String {
        switch value.lowercased() {
        case "tar.xz", "xz": return "txz"
        case "tar.gz", "gzip": return "tgz"
        case "tar.bz2", "bzip2": return "tbz2"
        default: return value.lowercased()
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.intValue
    }

    private func extract(format: String, source: URL, destination: URL) async throws {
        let cancellation = CancellationToken()
        let limits = Self.extractionLimits
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    _ = try ArchiveEngine.extract(format: format, source: source,
                                                  destination: destination,
                                                  limits: limits, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveEngineError {
            if case .limitExceeded(let detail) = error {
                throw GameRuntimeResourceError.extractionFailed(detail)
            }
            throw GameRuntimeResourceError.extractionFailed(error.localizedDescription)
        } catch {
            throw GameRuntimeResourceError.extractionFailed(error.localizedDescription)
        }
    }

    private func findRoot(in extracted: URL, markers: [String],
                          markerContents: [String: String]) throws -> URL {
        let fileManager = FileManager.default
        func matches(_ url: URL) -> Bool {
            markers.allSatisfy { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
                && markerContents.allSatisfy { path, expected in
                    guard let data = try? Data(contentsOf: url.appendingPathComponent(path)),
                          let text = String(data: data, encoding: .utf8) else { return false }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines) == expected
                }
        }
        if matches(extracted) { return extracted }
        let children = (try? fileManager.contentsOfDirectory(
            at: extracted, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            if matches(child) { return child }
        }
        throw GameRuntimeResourceError.extractionFailed(
            "archive does not contain the declared resource root")
    }
}

/// A snapshot of the concrete resources the execution bridge can receive. It
/// contains no credential, task identity or engine binary of its own.
/// Product distribution location for reviewed pack archives. The URL is read
/// from the signed App's Info.plist; the source tree contains no invented
/// endpoint. When it is absent, the registry reports the pack as unpublished
/// instead of pretending the 77 MB qualification fallback is a download.
enum GameRuntimeResourceDistribution {
    static let baseURLKey = "FloeGameRuntimePackBaseURL"

    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: baseURLKey) as? String,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }
}

/// Host-owned paired-source resolution over an already verified local source
/// offer. It never fetches, invents a URL or widens permissions.
struct GameRuntimePairedSourceProvider: GameDistributionPairedSourceProvider {
    let resolutions: [String: GameDistributionPairedSourceResolution]

    func resolve(_ artifactID: String) async throws -> GameDistributionPairedSourceResolution? {
        resolutions[artifactID]
    }
}

struct GameExecutionResources: Sendable {
    let portableResources: [GameEngineID: GamePortablePreparedResources]
    let renpySDK: URL?
    let narrativeResources: URL?
    let runtimePacks: (any GameRunRuntimePackProviding)?
    let gdevelopSDKRoot: URL?
    let gdevelopExportScript: URL?
    let providedTools: Set<String>
}
#endif

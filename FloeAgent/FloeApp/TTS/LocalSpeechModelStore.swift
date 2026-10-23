// FloeApp — Verified optional speech models, sharing the speech transfer owner.
#if canImport(UIKit)
import Foundation
import CryptoKit
import Darwin
import FloeCore

struct LocalSpeechCatalog: Codable, Sendable {
    let schemaVersion: Int
    let models: [LocalSpeechModel]
}

struct LocalSpeechModel: Codable, Sendable, Identifiable, Hashable {
    struct Voice: Codable, Sendable, Identifiable, Hashable {
        /// A qualified reference voice asset. Only published voices carry one;
        /// the catalog default timbre has no reference and stays built-in.
        struct Reference: Codable, Sendable, Hashable {
            enum Source: String, Codable, Sendable { case bundled, downloaded }
            let source: Source
            let path: String
            let sha256: String
            let byteCount: Int64
            let frames: Int
            let codesPerFrame: Int
            let codebookSize: Int
        }
        let id: String
        let name: String
        let languages: [String]
        var reference: Reference? = nil
    }
    struct Asset: Codable, Sendable, Hashable {
        let path: String
        let url: URL
        let sha256: String
        let byteCount: Int64
    }
    let id: String
    let title: String
    let engine: String
    let repository: String
    let revision: String
    let license: String
    let languages: [String]
    let voices: [Voice]
    let files: [Asset]
    let tokenizerRelativePath: String?
    let minimumMemoryBytes: UInt64?
    /// Catalog default voice for first-install and selection migration. Replaces
    /// the previously hardcoded provider-specific voice id.
    var defaultVoiceID: String? = nil
    /// "hidden" keeps a legacy descriptor loadable for old installs until the
    /// migration finishes, while the pack is never listed or installable.
    var visibility: String? = nil
    var isHidden: Bool { visibility == "hidden" }
    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

/// Validated MOSS-TTS-Nano reference-code envelope (see private SCHEMA.md).
/// Parsing fails closed: size, hash, header invariants, row width and the
/// 0..<1024 code range are all enforced before any audio is produced.
enum LocalSpeechVoiceReference {
    struct Payload: Decodable {
        let schemaVersion: Int
        let engine: String
        let codesPerFrame: Int
        let codebookSize: Int
        let frames: Int
        let codes: [[Int32]]
    }
    enum LoadError: Error, Equatable { case missing, corrupt }

    static func load(reference: LocalSpeechModel.Voice.Reference, modelDirectory: URL,
                     bundle: Bundle = .main) throws -> [[Int32]] {
        guard safeRelativePath(reference.path) else { throw LoadError.corrupt }
        let file: URL
        switch reference.source {
        case .downloaded:
            file = modelDirectory.appendingPathComponent(reference.path)
        case .bundled:
            let components = reference.path.split(separator: "/").map(String.init)
            guard components.count == 2, components[0] == "references",
                  let url = bundle.url(forResource: components[1], withExtension: nil,
                                       subdirectory: "LocalSpeech/" + components[0])
            else { throw LoadError.corrupt }
            file = url
        }
        guard let bytes = try? Data(contentsOf: file) else { throw LoadError.missing }
        guard Int64(bytes.count) == reference.byteCount else { throw LoadError.corrupt }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reference.sha256.lowercased() else {
            throw LoadError.corrupt
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: bytes) else { throw LoadError.corrupt }
        guard payload.schemaVersion == 1, payload.engine == "mossTTSNano",
              payload.codesPerFrame == 16, payload.codebookSize == 1024,
              payload.frames == reference.frames,
              payload.codesPerFrame == reference.codesPerFrame,
              payload.codebookSize == reference.codebookSize,
              payload.frames == payload.codes.count,
              payload.frames >= 1, payload.frames <= 1024,
              payload.codes.allSatisfy({ $0.count == 16 && $0.allSatisfy({ (0..<1024).contains($0) }) })
        else { throw LoadError.corrupt }
        return payload.codes
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && value.hasPrefix("references/")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

protocol LocalSpeechDownloading: Sendable {
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
    /// Retire an in-flight or resumable transfer for a URL before its cached
    /// bytes are deleted. Canceling the owning background task first prevents a
    /// process-restarted transfer from recreating the file after cleanup.
    /// Production routes to the shared transfer owner's durable retirement
    /// fence; the default no-op serves download-only conformers and fixtures.
    func retire(_ url: URL) async
}
extension LocalSpeechDownloading { func retire(_ url: URL) async { } }

private struct SharedSpeechDownloader: LocalSpeechDownloading {
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await WhisperDownloadCoordinator.shared.download(url, progress: progress)
    }
    /// Shared transfer owner's durable retirement fence: persists the URL key,
    /// resumes waiters, cancels the matching background task and removes its
    /// `.download`/`.resume` blobs, so a restored or late delegate callback
    /// cannot recreate legacy bytes after cleanup.
    func retire(_ url: URL) async {
        await WhisperDownloadCoordinator.shared.cancelAndRemovePendingTransfer(for: url)
    }
}

extension Notification.Name {
    static let localSpeechInstallationCompleted = Notification.Name("floe.localSpeech.installationCompleted")
}

/// Smoothed real-network throughput estimator. The baseline window is HELD
/// until at least `window` seconds of elapsed time accumulate, so frequent
/// (e.g. 10 Hz) callbacks — where consecutive deltas are sub-`window` — still
/// produce a speed instead of never reaching the sample gate. Only cumulative
/// byte growth advances the reported value; cached or committed bytes never
/// feed it, and a rolled window resets the smoothing anchor.
struct SpeedEstimator: Sendable {
    static let minimumWindow: TimeInterval = 0.5
    private var baseline: (time: TimeInterval, bytes: Int64)?
    private var ema: Double = 0
    private var lastObservedBytes: Int64?
    private var lastGrowthAt: TimeInterval?
    mutating func reset() { baseline = nil; ema = 0; lastObservedBytes = nil; lastGrowthAt = nil }
    func currentRate(now: TimeInterval) -> Double {
        guard let lastGrowthAt, (0...2).contains(now - lastGrowthAt) else { return 0 }
        return ema
    }
    /// Feeds one cumulative sample; returns the smoothed bytes/second once a
    /// full window has elapsed, otherwise nil (baseline held, not advanced).
    mutating func sample(now: TimeInterval, bytes: Int64) -> Double? {
        if let previous = lastObservedBytes, bytes > previous { lastGrowthAt = now }
        lastObservedBytes = bytes
        guard let start = baseline else { baseline = (now, bytes); return nil }
        let dt = now - start.time
        guard dt >= Self.minimumWindow else { return nil }
        // A full window with no movement is a genuine 0, folded into the EMA.
        let instant = Double(max(0, bytes - start.bytes)) / dt
        ema = ema <= 0 ? instant : ema * 0.6 + instant * 0.4
        baseline = (now, bytes)
        return ema
    }
}

actor LocalSpeechModelStore {
    static let shared = LocalSpeechModelStore()
    struct Installation: Sendable, Equatable {
        enum Phase: String, Sendable, Equatable {
            case queued, downloading, verifying, committing
        }
        var modelID: String?
        var completed: Int64 = 0
        var total: Int64 = 0
        var phase: Phase = .queued
        var running = false
        var failureKey: String?
        /// Smoothed bytes/second measured from real network callbacks only.
        /// Zero for cache-served bytes and outside the downloading phase,
        /// so a reused transfer never shows an inflated speed.
        var bytesPerSecond: Int64 = 0
        var downloadPercent: Double { total > 0 ? Double(min(max(completed, 0), total)) * 100 / Double(total) : 0 }
    }
    /// Durable legacy-pack transition. Stages survive process death; every
    /// transition is written before the next action runs.
    struct MigrationRecord: Codable, Sendable, Equatable {
        enum Stage: String, Codable, Sendable, Equatable {
            case pendingInstall
            case awaitingLoadValidation
            case awaitingLegacyRelease
            case cleanupPending
            case complete
        }
        struct LegacyPack: Codable, Sendable, Equatable {
            let id: String
            let revision: String
            let assetURLs: [String]
        }
        var stage: Stage
        let newModelID: String
        let newRevision: String
        let selectionRevision: Int
        let legacy: [LegacyPack]
    }
    struct Lease: Sendable { let id: UUID; let model: LocalSpeechModel; let directory: URL }
    enum Failure: Error, Equatable { case unavailable, corrupt, busy, space, memory, thermal }
    private var installation = Installation()
    private var installTask: Task<Void, Never>?
    private var generation = UUID()
    private var leases: [UUID: String] = [:]
    private var verified = Set<String>()
    private let defaults: UserDefaults
    private let providedCatalog: LocalSpeechCatalog?
    private let storageRoot: URL?
    private let transfersRoot: URL?
    private let downloader: any LocalSpeechDownloading
    private let remover: (URL) throws -> Void
    // Smoothed network speed estimate, fenced per asset download window so a
    // late callback from a previous asset can never contaminate the new one.
    private var estimator = SpeedEstimator()
    private var speedWindow: Int = 0
    /// Packs currently being retired. Set synchronously before cleanup's first
    /// suspension point so an actor-reentrant acquire can never mount a lease
    /// under a directory that is about to be deleted.
    private var retiring: Set<String> = []
    private var cleanupRunning = false
    private var cleanupFailureKey: String?

    init(catalog: LocalSpeechCatalog? = nil, root: URL? = nil, defaults: UserDefaults = .standard,
         downloader: (any LocalSpeechDownloading)? = nil, transfersRoot: URL? = nil,
         remover: ((URL) throws -> Void)? = nil) {
        providedCatalog = catalog
        storageRoot = root
        self.transfersRoot = transfersRoot
        self.defaults = defaults
        self.downloader = downloader ?? SharedSpeechDownloader()
        self.remover = remover ?? { try FileManager.default.removeItem(at: $0) }
    }
    private static let pendingKey = "voice.local.pendingInstallation"
    private static let migrationKey = "voice.local.migration.v1"

    func state() -> Installation {
        var snapshot = installation
        if snapshot.running && snapshot.phase == .downloading {
            snapshot.bytesPerSecond = Int64(estimator.currentRate(now: Date().timeIntervalSinceReferenceDate).rounded())
        } else {
            snapshot.bytesPerSecond = 0
        }
        return snapshot
    }
    func catalog() throws -> [LocalSpeechModel] {
        let catalog: LocalSpeechCatalog
        if let providedCatalog { catalog = providedCatalog }
        else {
            guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "LocalSpeech") else { throw Failure.unavailable }
            catalog = try JSONDecoder().decode(LocalSpeechCatalog.self, from: Data(contentsOf: url))
        }
        guard catalog.schemaVersion == 1, !catalog.models.isEmpty,
              Set(catalog.models.map(\.id)).count == catalog.models.count else { throw Failure.corrupt }
        for model in catalog.models {
            guard safeComponent(model.id), model.revision.count == 40, model.revision.allSatisfy(\.isHexDigit),
                  !model.files.isEmpty, Set(model.files.map(\.path)).count == model.files.count,
                  ["qwen3TTS", "mossTTSNano"].contains(model.engine),
                  !model.voices.isEmpty, !model.languages.isEmpty,
                  model.visibility == nil || ["visible", "hidden"].contains(model.visibility!),
                  model.defaultVoiceID.map { id in model.voices.contains { $0.id == id } } ?? true,
                  Set(model.voices.map(\.id)).count == model.voices.count,
                  model.tokenizerRelativePath.map(safePath) ?? true else { throw Failure.corrupt }
            for asset in model.files {
                guard safePath(asset.path), asset.url.scheme == "https", asset.url.host == "huggingface.co",
                      pinnedURL(asset.url),
                      asset.byteCount > 0, asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw Failure.corrupt }
            }
            for voice in model.voices {
                guard let reference = voice.reference else { continue }
                guard reference.source == .bundled || reference.source == .downloaded,
                      safePath(reference.path), reference.path.hasPrefix("references/"),
                      reference.byteCount > 0, reference.sha256.count == 64, reference.sha256.allSatisfy(\.isHexDigit),
                      reference.frames >= 1, reference.frames <= 1024,
                      reference.codesPerFrame == 16, reference.codebookSize == 1024 else { throw Failure.corrupt }
                if reference.source == .downloaded {
                    // Downloaded references must travel through the same byte-
                    // verified asset pipeline as the model weights.
                    guard model.files.contains(where: { $0.path == reference.path && $0.sha256 == reference.sha256 && $0.byteCount == reference.byteCount })
                    else { throw Failure.corrupt }
                }
            }
        }
        return catalog.models
    }
    /// Packs offered for download and shown in voice surfaces. Hidden legacy
    /// descriptors never appear here.
    func visibleCatalog() throws -> [LocalSpeechModel] { try catalog().filter { !$0.isHidden } }

    func isInstalled(_ model: LocalSpeechModel) -> Bool {
        guard let directory = try? directory(model),
              let marker = try? Data(contentsOf: directory.appendingPathComponent("installed.json")),
              let installed = try? JSONDecoder().decode(LocalSpeechModel.self, from: marker),
              installed.id == model.id, installed.engine == model.engine,
              installed.revision == model.revision, installed.files == model.files,
              installed.tokenizerRelativePath == model.tokenizerRelativePath else { return false }
        return model.files.allSatisfy { asset in
            guard let values = try? directory.appendingPathComponent(asset.path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == asset.byteCount
        }
    }

    func beginInstallation(_ model: LocalSpeechModel, selectionRevision: Int = 0) {
        guard installTask == nil else { return }
        guard !model.isHidden else {
            installation = Installation(modelID: model.id, total: model.byteCount, failureKey: "voice.local.error.legacy")
            return
        }
        let owner = UUID()
        generation = owner
        if migrationRecord == nil {
            let legacy = legacyInstalledDescriptors(excluding: model.id)
            if !legacy.isEmpty {
                migrationRecord = MigrationRecord(stage: .pendingInstall, newModelID: model.id, newRevision: model.revision,
                                                  selectionRevision: selectionRevision, legacy: legacy)
            }
        }
        defaults.set(model.id, forKey: Self.pendingKey)
        estimator.reset()
        installation = Installation(modelID: model.id, total: model.byteCount, phase: .queued, running: true)
        installTask = Task {
            do { try await install(model, owner: owner) }
            catch is CancellationError { }
            catch { if generation == owner { installation.failureKey = (error as? Failure) == .space ? "voice.local.error.space" : "voice.local.error.install" } }
            guard generation == owner else { return }
            if var record = migrationRecord, record.stage == .pendingInstall, record.newModelID == model.id,
               installation.completed >= model.byteCount, isInstalled(model) {
                record.stage = .awaitingLoadValidation
                migrationRecord = record
            }
            installation.running = false
            installation.bytesPerSecond = 0
            installTask = nil
            defaults.removeObject(forKey: Self.pendingKey)
        }
    }

    /// Launch reconciliation. Resumes only the current visible pack; a pending
    /// legacy (hidden) installation is dropped and its stored transfer resume
    /// blobs are deleted so an old pending transfer can never resume.
    /// Lease-blocked legacy cleanup is retried here too.
    func restoreInstallation() {
        if migrationRecord?.stage == .cleanupPending { Task { await self.retryLegacyCleanup() } }
        guard let id = defaults.string(forKey: Self.pendingKey), let model = try? catalog().first(where: { $0.id == id }) else {
            defaults.removeObject(forKey: Self.pendingKey)
            return
        }
        guard !model.isHidden else {
            defaults.removeObject(forKey: Self.pendingKey)
            // Disable the old pending transfer: fence + cancel + remove its
            // exact blobs through the shared transfer owner, then sweep any
            // remaining resume artifact under the injected root.
            Task {
                for asset in model.files { await self.downloader.retire(asset.url) }
                self.deleteTransferResumeArtifacts(for: model)
            }
            return
        }
        if migrationRecord == nil {
            let legacy = legacyInstalledDescriptors(excluding: model.id)
            if !legacy.isEmpty {
                migrationRecord = MigrationRecord(stage: .pendingInstall, newModelID: model.id, newRevision: model.revision,
                                                  selectionRevision: defaults.integer(forKey: "voice.output.selectionRevision"), legacy: legacy)
            }
        }
        beginInstallation(model, selectionRevision: migrationRecord?.selectionRevision ?? 0)
    }
    func cancelInstallation() {
        defaults.removeObject(forKey: Self.pendingKey)
        if migrationRecord?.stage == .pendingInstall { migrationRecord = nil }
        installTask?.cancel()
    }

    func acquire(_ id: String) throws -> Lease {
        guard let model = try catalog().first(where: { $0.id == id }), isInstalled(model),
              installation.modelID != id || !installation.running else { throw Failure.unavailable }
        // A pack under active retirement must never gain a fresh lease while
        // cleanup crosses its await points.
        guard !retiring.contains(id) else { throw Failure.busy }
        guard leases.isEmpty else { throw Failure.busy }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw Failure.thermal }
        let required = model.minimumMemoryBytes ?? max(768 * 1024 * 1024, UInt64(model.byteCount) * 2)
        let available = UInt64(os_proc_available_memory())
        let reserved = UInt64(max(0, ResidentMemoryReservations.totalBytes()))
        let headroom = available > reserved ? available - reserved : 0
        guard headroom > required + 256 * 1024 * 1024 else { throw Failure.memory }
        let directory = try directory(model)
        if !verified.contains(model.id + model.revision) {
            for asset in model.files { try verify(directory.appendingPathComponent(asset.path), asset) }
            verified.insert(model.id + model.revision)
        }
        let lease = Lease(id: UUID(), model: model, directory: directory)
        leases[lease.id] = model.id
        ResidentMemoryReservations.set(id: "tts.\(lease.id.uuidString)", bytes: Int64(required))
        return lease
    }
    func release(_ id: UUID) {
        leases.removeValue(forKey: id)
        ResidentMemoryReservations.clear(id: "tts.\(id.uuidString)")
        if migrationRecord?.stage == .cleanupPending { Task { await self.retryLegacyCleanup() } }
    }
    func remove(_ model: LocalSpeechModel) throws {
        guard !leases.values.contains(model.id), installation.modelID != model.id || !installation.running else { throw Failure.busy }
        let directory = try directory(model)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        let staging = try root().appendingPathComponent(".tts-\(model.id)-\(model.revision)", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        verified.remove(model.id + model.revision)
    }

    // MARK: - Durable legacy migration

    var migrationRecord: MigrationRecord? {
        get {
            guard let data = defaults.data(forKey: Self.migrationKey),
                  let record = try? JSONDecoder().decode(MigrationRecord.self, from: data),
                  record.stage != .complete else { return nil }
            return record
        }
        nonmutating set {
            if let newValue {
                if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.migrationKey) }
            } else {
                defaults.removeObject(forKey: Self.migrationKey)
            }
        }
    }

    /// Selection-side legacy descriptors that are actually installed right now.
    private func legacyInstalledDescriptors(excluding newModelID: String) -> [MigrationRecord.LegacyPack] {
        (try? catalog().filter { $0.isHidden && $0.id != newModelID }.compactMap { model -> MigrationRecord.LegacyPack? in
            guard isInstalled(model) else { return nil }
            return MigrationRecord.LegacyPack(id: model.id, revision: model.revision, assetURLs: model.files.map(\.url.absoluteString))
        }) ?? []
    }

    /// Called by the settings service after the new pack bytes verified and the
    /// engine load-validation hook passed. `legacyStillSelected` keeps the old
    /// pack when the user's current selection still uses it.
    func migrationLoadValidated(legacyStillSelected: Bool) async {
        guard var record = migrationRecord, record.stage == .awaitingLoadValidation else { return }
        record.stage = legacyStillSelected ? .awaitingLegacyRelease : .cleanupPending
        migrationRecord = record
        if !legacyStillSelected { await self.retryLegacyCleanup() }
    }
    func migrationLegacyReleased() async {
        guard var record = migrationRecord, record.stage == .awaitingLegacyRelease else { return }
        record.stage = .cleanupPending
        migrationRecord = record
        await self.retryLegacyCleanup()
    }
    /// Cancels matching transfers, then removes ONLY the exact legacy pack
    /// directory/staging and the exact keyed transfer blobs for its own asset
    /// URLs. ASR/Whisper models and any other transfer keys are never touched.
    /// Removal is verified: any surviving path keeps the durable stage at
    /// `cleanupPending` (retryable on release/launch/idle) with an actionable
    /// key — a partial cleanup is never reported as finished.
    func retryLegacyCleanup() async {
        guard var record = migrationRecord, record.stage == .cleanupPending else { return }
        guard !cleanupRunning else { return }
        cleanupRunning = true
        defer { cleanupRunning = false }
        // Refuse to start while the old pack is in use; deferred, not failed.
        let busyLease = leases.values.contains(where: { id in record.legacy.contains { $0.id == id } })
        let busyInstall = record.legacy.contains { installation.modelID == $0.id && installation.running }
        guard !busyLease, !busyInstall else { return }
        guard let storageRoot = try? root() else {
            cleanupFailureKey = "voice.local.error.remove"
            return
        }
        // Fence acquisition of every pack in this migration for the whole
        // async duration, then restore availability if removal fails and the
        // pack is still present and usable.
        let ids = Set(record.legacy.map(\.id))
        retiring.formUnion(ids)
        defer { retiring.subtract(ids) }
        // Cancel matching background transfers before deleting anything, so a
        // restored or late delegate callback cannot recreate the bytes.
        for pack in record.legacy {
            for urlString in pack.assetURLs {
                guard let url = URL(string: urlString) else { continue }
                await downloader.retire(url)
            }
        }
        var complete = true
        for pack in record.legacy {
            // Reentrancy recheck after the last await, immediately before the
            // synchronous deletion pass.
            if leases.values.contains(pack.id) { complete = false; continue }
            var targets = [
                storageRoot.appendingPathComponent("tts-\(pack.id)-\(pack.revision)", isDirectory: true),
                storageRoot.appendingPathComponent(".tts-\(pack.id)-\(pack.revision)", isDirectory: true),
            ]
            for urlString in pack.assetURLs {
                guard let url = URL(string: urlString) else { continue }
                targets.append(contentsOf: Self.transferArtifacts(for: url, transfersRoot: transfersRoot))
            }
            for target in targets where FileManager.default.fileExists(atPath: target.path) {
                do { try remover(target) }
                catch { complete = false }
                // Absence is the contract, not the absence of a thrown error.
                if FileManager.default.fileExists(atPath: target.path) { complete = false }
            }
            verified.remove(pack.id + pack.revision)
        }
        guard complete else {
            cleanupFailureKey = "voice.local.error.remove"
            return
        }
        cleanupFailureKey = nil
        record.stage = .complete
        migrationRecord = record
    }
    func migrationStatus() -> (record: MigrationRecord?, cleanupFailureKey: String?) {
        (migrationRecord, cleanupFailureKey)
    }
    /// The exact known transfer artifacts for one catalog asset URL. Scoped to
    /// these keys only; ASR/Whisper model files and other transfers are never
    /// touched.
    static func transferArtifacts(for url: URL, transfersRoot: URL? = nil) -> [URL] {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let base: URL?
        if let transfersRoot {
            base = transfersRoot
        } else {
            base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
                .appendingPathComponent("FloeAgent/SpeechTransfers", isDirectory: true)
        }
        guard let base else { return [] }
        return [base.appendingPathComponent(key + ".download"), base.appendingPathComponent(key + ".resume")]
    }
    private func deleteTransferResumeArtifacts(for model: LocalSpeechModel) {
        for asset in model.files {
            for artifact in Self.transferArtifacts(for: asset.url, transfersRoot: transfersRoot) where artifact.pathExtension == "resume" {
                try? FileManager.default.removeItem(at: artifact)
            }
        }
    }

    private func root() throws -> URL {
        let directory: URL
        if let storageRoot { directory = storageRoot }
        else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("FloeAgent/SpeechModels", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func directory(_ model: LocalSpeechModel) throws -> URL {
        try root().appendingPathComponent("tts-\(model.id)-\(model.revision)", isDirectory: true)
    }
    private func install(_ model: LocalSpeechModel, owner: UUID) async throws {
        guard try catalog().contains(model), !leases.values.contains(model.id) else { throw Failure.busy }
        // Crash window between the final commit and the stage transition:
        // the pack is already installed, so finish without re-downloading.
        if isInstalled(model) {
            verified.insert(model.id + model.revision)
            guard generation == owner else { return }
            commitProgress(owner, bytes: model.byteCount)
            NotificationCenter.default.post(name: .localSpeechInstallationCompleted, object: nil)
            return
        }
        let root = try root(), destination = try directory(model)
        let staging = root.appendingPathComponent(".tts-\(model.id)-\(model.revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var stagingForValues = staging
        try stagingForValues.setResourceValues(values)
        let remaining = model.files.filter { (try? verify(staging.appendingPathComponent($0.path), $0)) == nil }
        let needed = remaining.reduce(Int64(64 * 1024 * 1024)) { $0 + $1.byteCount } + (remaining.map(\.byteCount).max() ?? 0)
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= needed else { throw Failure.space }
        var completed: Int64 = 0
        for asset in model.files {
            try Task.checkCancellation()
            guard generation == owner else { throw CancellationError() }
            let target = staging.appendingPathComponent(asset.path)
            if (try? verify(target, asset)) != nil {
                completed += asset.byteCount
                commitProgress(owner, bytes: completed)
                continue
            }
            let before = completed
            // New asset ⇒ new measurement window (drops the previous asset's
            // smoothing anchor and fences any still-in-flight callback).
            speedWindow += 1
            let window = speedWindow
            estimator.reset()
            installation.phase = .downloading
            let temporary = try await downloader.download(asset.url) { bytes in
                Task { await self.networkProgress(owner, window: window, base: before, bytes: bytes, assetBytes: asset.byteCount) }
            }
            try Task.checkCancellation()
            installation.phase = .verifying
            do { try verify(temporary, asset) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // The shared transfer owner reuses a completed download.
                // Reject and remove corrupt transport bytes so Retry fetches
                // them again instead of looping on the same bad cache.
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += asset.byteCount
            commitProgress(owner, bytes: completed)
        }
        try Task.checkCancellation()
        installation.phase = .committing
        try JSONEncoder().encode(model).write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            // A valid installed version is preserved on failed replacement.
            let backup = root.appendingPathComponent(".tts-backup-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: destination, to: backup)
            do { try FileManager.default.moveItem(at: staging, to: destination); try? FileManager.default.removeItem(at: backup) }
            catch { try? FileManager.default.moveItem(at: backup, to: destination); throw error }
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        verified.insert(model.id + model.revision)
        NotificationCenter.default.post(name: .localSpeechInstallationCompleted, object: nil)
    }
    /// Snapshot completion update from a byte-commit boundary. Never feeds the
    /// speed estimator: cache-served or verified-skip bytes are not network.
    private func commitProgress(_ owner: UUID, bytes: Int64) {
        guard generation == owner else { return }
        installation.completed = min(installation.total, max(installation.completed, bytes))
    }
    /// Real network throughput only: feeds the held-window estimator with the
    /// per-download-task cumulative callback. A callback whose asset window is
    /// no longer current (late Task from a prior asset) is dropped so it can
    /// never advance or contaminate the new baseline. completed uses max().
    private func networkProgress(_ owner: UUID, window: Int, base: Int64, bytes: Int64, assetBytes: Int64) {
        guard generation == owner, window == speedWindow, installation.phase == .downloading else { return }
        let capped = min(bytes, assetBytes)
        installation.completed = min(installation.total, max(installation.completed, base + capped))
        if let speed = estimator.sample(now: Date().timeIntervalSinceReferenceDate, bytes: bytes) {
            installation.bytesPerSecond = Int64(speed.rounded())
        }
    }
    private func pinnedURL(_ url: URL) -> Bool {
        // A speech tokenizer may live in a different pinned repository/revision
        // from its talker. Each complete URL and digest is bound by the catalog.
        let components = url.pathComponents
        guard let marker = components.firstIndex(of: "resolve"), marker + 2 < components.count else { return false }
        let revision = components[marker + 1]
        return revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }

    private func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && value.utf8.count <= 80
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
    private func safePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private func verify(_ url: URL, _ asset: LocalSpeechModel.Asset) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.byteCount else { throw Failure.corrupt }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256.lowercased() else { throw Failure.corrupt }
    }
}

#endif

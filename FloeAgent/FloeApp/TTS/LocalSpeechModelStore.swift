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
        let id: String
        let name: String
        let languages: [String]
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
    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

protocol LocalSpeechDownloading: Sendable {
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

private struct SharedSpeechDownloader: LocalSpeechDownloading {
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await WhisperDownloadCoordinator.shared.download(url, progress: progress)
    }
}

extension Notification.Name {
    static let localSpeechInstallationCompleted = Notification.Name("floe.localSpeech.installationCompleted")
}

actor LocalSpeechModelStore {
    static let shared = LocalSpeechModelStore()
    struct Installation: Sendable {
        var modelID: String?
        var completed: Int64 = 0
        var total: Int64 = 0
        var running = false
        var failureKey: String?
    }
    struct Lease: Sendable { let id: UUID; let model: LocalSpeechModel; let directory: URL }
    enum Failure: Error, Equatable { case unavailable, corrupt, busy, space, memory }
    private var installation = Installation()
    private var installTask: Task<Void, Never>?
    private var generation = UUID()
    private var leases: [UUID: String] = [:]
    private var verified = Set<String>()
    private let defaults: UserDefaults
    private let providedCatalog: LocalSpeechCatalog?
    private let storageRoot: URL?
    private let downloader: any LocalSpeechDownloading

    init(catalog: LocalSpeechCatalog? = nil, root: URL? = nil, defaults: UserDefaults = .standard,
         downloader: (any LocalSpeechDownloading)? = nil) {
        providedCatalog = catalog
        storageRoot = root
        self.defaults = defaults
        self.downloader = downloader ?? SharedSpeechDownloader()
    }
    private static let pendingKey = "voice.local.pendingInstallation"

    func state() -> Installation { installation }
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
                  model.tokenizerRelativePath.map(safePath) ?? true else { throw Failure.corrupt }
            for asset in model.files {
                guard safePath(asset.path), asset.url.scheme == "https", asset.url.host == "huggingface.co",
                      pinnedURL(asset.url),
                      asset.byteCount > 0, asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw Failure.corrupt }
            }
        }
        return catalog.models
    }

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

    func beginInstallation(_ model: LocalSpeechModel) {
        guard installTask == nil else { return }
        let owner = UUID()
        generation = owner
        defaults.set(model.id, forKey: Self.pendingKey)
        installation = Installation(modelID: model.id, total: model.byteCount, running: true)
        installTask = Task {
            do { try await install(model, owner: owner) }
            catch is CancellationError { }
            catch { if generation == owner { installation.failureKey = (error as? Failure) == .space ? "voice.local.error.space" : "voice.local.error.install" } }
            guard generation == owner else { return }
            installation.running = false
            installTask = nil
            defaults.removeObject(forKey: Self.pendingKey)
        }
    }

    func restoreInstallation() {
        guard let id = defaults.string(forKey: Self.pendingKey), let model = try? catalog().first(where: { $0.id == id }) else { return }
        beginInstallation(model)
    }
    func cancelInstallation() { defaults.removeObject(forKey: Self.pendingKey); installTask?.cancel() }

    func acquire(_ id: String) throws -> Lease {
        guard let model = try catalog().first(where: { $0.id == id }), isInstalled(model),
              installation.modelID != id || !installation.running else { throw Failure.unavailable }
        guard leases.isEmpty else { throw Failure.busy }
        let required = model.minimumMemoryBytes ?? max(768 * 1024 * 1024, UInt64(model.byteCount) * 2)
        let available = UInt64(os_proc_available_memory())
        let reserved = UInt64(max(0, ResidentMemoryReservations.totalBytes()))
        let headroom = available > reserved ? available - reserved : 0
        guard headroom > required + 256 * 1024 * 1024,
              ProcessInfo.processInfo.thermalState != .critical else { throw Failure.memory }
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
    func release(_ id: UUID) { leases.removeValue(forKey: id); ResidentMemoryReservations.clear(id: "tts.\(id.uuidString)") }
    func remove(_ model: LocalSpeechModel) throws {
        guard !leases.values.contains(model.id), installation.modelID != model.id || !installation.running else { throw Failure.busy }
        let directory = try directory(model)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        let staging = try root().appendingPathComponent(".tts-\(model.id)-\(model.revision)", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        verified.remove(model.id + model.revision)
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
            if (try? verify(target, asset)) != nil { completed += asset.byteCount; continue }
            let before = completed
            let temporary = try await downloader.download(asset.url) { bytes in
                Task { await self.progress(owner, bytes: before + min(bytes, asset.byteCount)) }
            }
            try Task.checkCancellation()
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
            progress(owner, bytes: completed)
        }
        try Task.checkCancellation()
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
    private func progress(_ owner: UUID, bytes: Int64) {
        guard generation == owner else { return }
        installation.completed = min(installation.total, max(installation.completed, bytes))
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

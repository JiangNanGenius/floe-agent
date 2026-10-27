import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(iOS)
/// Bridges URLSession background relaunch callbacks back to UIKit without
/// making the catalog target depend on the application target. The facade
/// is a thin, thread-safe entry into the per-identifier settlement
/// primitive: the stored system completion runs exactly once on main AFTER
/// every settle event this wake registered has drained (component
/// verification, the durable staging commit, the manifest write and the
/// directory swap) — never while that work is still underway. `AppDelegate`
/// keeps calling `register(identifier:completion:)` unchanged. The lookup
/// is lock-protected with no actor hop, so the launch hook and the download
/// delegate resolve the SAME instance from any thread in any order, and
/// registration order can neither lose a completion nor fire one twice.
/// The optional `bootstrap:` argument lets the launch hook attach bounded
/// wake-readiness work (finite due scans, never inference or a whole-agent
/// wait) BEFORE the handler is stored; two-argument `register` call sites
/// are unchanged.
public final class LocalModelBackgroundEvents: @unchecked Sendable {
    public static let shared = LocalModelBackgroundEvents()

    private init() {}

    /// Stores the system completion for this identifier's wake.
    /// `bootstrap` is the caller-provided BOUNDED wake readiness work
    /// (finite metadata/due scans only — never a whole-agent wait,
    /// inference or user wait). When present, its lease is registered as
    /// pending BEFORE the handler is stored: a late handler on an already
    /// drained+finished wake would otherwise fire immediately past the
    /// still-running readiness work. Callers that pass no bootstrap keep
    /// the previous two-argument behavior unchanged.
    public func register(
        identifier: String,
        completion: @escaping () -> Void,
        bootstrap: (@Sendable () async -> Void)? = nil
    ) {
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)
        if let bootstrap {
            settlement.trackBootstrap(bootstrap)
        }
        settlement.registerSystemCompletionHandler(completion)
    }
}
#endif

/// Service-owned settlement lookup: one `FloeCore.BackgroundDownloadEventSettlement`
/// per background session identifier (`org.floeagent.local-model.<model>.<component>`).
/// Creation is lock-protected so the launch-hook facade and the delegate
/// callbacks always share the same instance. Identifiers stay fully
/// separated — a wake belongs to exactly one session — and per-model /
/// per-component state survives across wakes with no cross-identifier
/// hold or release.
enum LocalModelDownloadSettlements {
    nonisolated(unsafe) private static var settlements: [String: BackgroundDownloadEventSettlement] = [:]
    private static let lock = NSLock()

    static func settlement(for identifier: String) -> BackgroundDownloadEventSettlement {
        lock.withLock {
            if let existing = settlements[identifier] { return existing }
            let created = BackgroundDownloadEventSettlement(name: "local-model.\(identifier)")
            settlements[identifier] = created
            return created
        }
    }
}

/// Exactly-once pairing helper shared by the two model-download owners.
/// A settle event begun synchronously inside a delegate callback is counted
/// here against the settlement it belongs to; the owning download/install
/// operation checkpoints completed components before the next network wait
/// and drains exactly once at its tail — AFTER durable bytes/state have been committed (or after failure cleanup restored the
/// previous state) — so no background-session wake can be released
/// mid-commit. Draining is idempotent; a defensive late `began` after the
/// drain self-pairs (begin + immediate end) and can never strand a future
/// wake for that identifier.
public final class ModelDownloadSettlementLedger: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var counts: [ObjectIdentifier: (settlement: BackgroundDownloadEventSettlement, count: Int)] = [:]
    private var drained = false

    /// Registers one owned async follow-up begun by a delegate callback.
    /// Call synchronously inside the callback that schedules the work.
    public func began(_ settlement: BackgroundDownloadEventSettlement) {
        settlement.beginEvent()
        lock.lock()
        guard !drained else {
            lock.unlock()
            settlement.endEvent()
            return
        }
        let key = ObjectIdentifier(settlement)
        let entry = counts[key] ?? (settlement, 0)
        counts[key] = (entry.settlement, entry.count + 1)
        lock.unlock()
    }

    /// A verified component has been moved into durable staging. Release
    /// only events already settled, before waiting on the NEXT network
    /// component. The final component stays held through the package commit.
    public func checkpoint() {
        lock.lock()
        let snapshot = Array(counts.values)
        counts.removeAll()
        lock.unlock()
        for entry in snapshot {
            for _ in 0..<entry.count { entry.settlement.endEvent() }
        }
    }

    /// Ends every registered event of this operation exactly once.
    public func drain() {
        lock.lock()
        guard !drained else { lock.unlock(); return }
        drained = true
        let snapshot = Array(counts.values)
        counts.removeAll()
        lock.unlock()
        for entry in snapshot {
            for _ in 0..<entry.count { entry.settlement.endEvent() }
        }
    }
}

public struct LocalModelDownloadProgress: Sendable, Equatable {
    public var modelID: String
    public var component: String
    public var bytesReceived: Int64
    public var bytesExpected: Int64?
    public var fractionCompleted: Double
    public var bytesPerSecond: Double?
    public var estimatedRemainingSeconds: Double?

    public init(
        modelID: String,
        component: String,
        bytesReceived: Int64,
        bytesExpected: Int64?,
        fractionCompleted: Double,
        bytesPerSecond: Double? = nil,
        estimatedRemainingSeconds: Double? = nil
    ) {
        self.modelID = modelID
        self.component = component
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.bytesPerSecond = bytesPerSecond
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
    }
}

public enum LocalModelRuntimeFormat: String, Codable, Hashable, Sendable {
    case mlx
    case gguf
}

public struct LocalModelArtifact: Codable, Hashable, Sendable {
    public var path: String
    public var byteCount: Int64

    public init(_ path: String, byteCount: Int64) {
        self.path = path
        self.byteCount = byteCount
    }
}

public struct LocalModelCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var profileID: UUID
    public var displayName: String
    public var repository: String
    /// Immutable Hugging Face commit. Curated downloads must never follow a
    /// mutable branch because a model update must pass Floe's release checks.
    public var revision: String
    public var runtimeFormat: LocalModelRuntimeFormat
    public var artifacts: [LocalModelArtifact]
    public var parameterBillions: Double
    public var approximateDownloadBytes: Int64
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var supportsToolCalling: Bool
    public var license: String

    public func artifactURL(_ artifact: LocalModelArtifact) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(artifact.path)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url!
    }

    public var ggufModelFile: String? {
        guard runtimeFormat == .gguf else { return nil }
        return artifacts.first(where: { $0.path.lowercased().hasSuffix(".gguf") })?.path
    }

    public var ggufProjectorFile: String? {
        guard runtimeFormat == .gguf else { return nil }
        return artifacts.dropFirst().first(where: { $0.path.lowercased().hasSuffix(".gguf") })?.path
    }
}

public enum CuratedLocalModelCatalog {
    /// Weights are never bundled with Floe. The public catalog is MLX-only.
    /// GGUF remains an internal compatibility runtime, but is intentionally
    /// absent from the selectable/downloadable catalog in this release.
    public static let entries: [LocalModelCatalogEntry] = [
        .init(
            id: "qwen3.5-4b-mlx4", profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000001")!, displayName: "Qwen3.5 4B MLX 4-bit",
            repository: "mlx-community/Qwen3.5-4B-MLX-4bit",
            revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
            runtimeFormat: .mlx,
            artifacts: [
                .init("chat_template.jinja", byteCount: 7_756),
                .init("config.json", byteCount: 3_366),
                .init("model.safetensors", byteCount: 3_034_300_695),
                .init("model.safetensors.index.json", byteCount: 101_944),
                .init("preprocessor_config.json", byteCount: 390),
                .init("processor_config.json", byteCount: 1_300),
                .init("tokenizer.json", byteCount: 19_989_343),
                .init("tokenizer_config.json", byteCount: 1_139),
                .init("video_preprocessor_config.json", byteCount: 385),
                .init("vocab.json", byteCount: 6_722_759)
            ],
            parameterBillions: 4,
            approximateDownloadBytes: 3_061_129_077, supportsVision: false,
            supportsReasoning: true, supportsToolCalling: true, license: "Apache-2.0"
        ),
        .init(
            id: "qwen3.8-4b-heretic-mlx4",
            profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000006")!,
            displayName: "Qwen3.8 4B Distill Heretic MLX 4-bit",
            repository: "yachen4ever/Qwen3.8-4B-Distill-Heretic-Abliterated-MLX-4bit",
            revision: "f47bef776bcd49b552219c14c4da949c8b49e336",
            runtimeFormat: .mlx,
            artifacts: [
                .init("chat_template.jinja", byteCount: 7_756),
                .init("config.json", byteCount: 3_857),
                .init("generation_config.json", byteCount: 174),
                .init("model.safetensors", byteCount: 3_034_299_183),
                .init("model.safetensors.index.json", byteCount: 101_944),
                .init("preprocessor_config.json", byteCount: 390),
                .init("processor_config.json", byteCount: 989),
                .init("tokenizer.json", byteCount: 19_989_492),
                .init("tokenizer_config.json", byteCount: 1_269)
            ],
            parameterBillions: 4,
            approximateDownloadBytes: 3_054_405_054,
            supportsVision: false,
            supportsReasoning: true,
            supportsToolCalling: true,
            license: "Apache-2.0"
        ),
    ]

    /// Entries removed from the selectable catalog remain known long enough
    /// for an existing installation to be discovered and deleted. They are
    /// never offered for download, model discovery, or task routing.
    ///
    /// Gemma 4 E4B moved here in the next repair slice: its 5.15 GB safetensors
    /// snapshot is the largest default entry and cannot be admitted on an
    /// M4-class iPad allowance (~4.7-4.9 GiB) once Floe's own footprint and a
    /// running TinyEMU Linux guest are accounted for, so offering it as a
    /// default/recommended download was a guaranteed failed start. Keeping the
    /// entry (and its profile id) means an existing user download is still
    /// discovered and can be deleted explicitly — nothing is removed silently.
    public static let retiredEntries: [LocalModelCatalogEntry] = [
        .init(
            id: "gemma4-e4b-mlx4",
            profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000005")!,
            displayName: "Gemma 4 E4B Instruction-Tuned MLX 4-bit",
            repository: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            runtimeFormat: .mlx,
            artifacts: [
                .init("chat_template.jinja", byteCount: 17_336),
                .init("config.json", byteCount: 6_628),
                .init("generation_config.json", byteCount: 208),
                .init("model.safetensors", byteCount: 5_146_800_534),
                .init("model.safetensors.index.json", byteCount: 240_961),
                .init("processor_config.json", byteCount: 1_316),
                .init("tokenizer.json", byteCount: 32_169_626),
                .init("tokenizer_config.json", byteCount: 2_740)
            ],
            parameterBillions: 4.5,
            approximateDownloadBytes: 5_179_239_349,
            supportsVision: false,
            supportsReasoning: true,
            supportsToolCalling: true,
            license: "Gemma"
        ),
        .init(
            id: "qwen3.5-9b-q4km", profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000002")!, displayName: "Qwen3.5 9B Q4_K_M",
            repository: "unsloth/Qwen3.5-9B-GGUF", revision: "main", runtimeFormat: .gguf,
            artifacts: [.init("Qwen3.5-9B-Q4_K_M.gguf", byteCount: 5_700_000_000), .init("mmproj-BF16.gguf", byteCount: 600_000_000)], parameterBillions: 9,
            approximateDownloadBytes: 6_300_000_000, supportsVision: true,
            supportsReasoning: true, supportsToolCalling: true, license: "Apache-2.0"
        ),
        .init(
            id: "ministral3-3b-q4km", profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000003")!, displayName: "Ministral 3 3B Q4_K_M",
            repository: "mistralai/Ministral-3-3B-Instruct-2512-GGUF", revision: "main", runtimeFormat: .gguf,
            artifacts: [.init("Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", byteCount: 2_200_000_000), .init("Ministral-3-3B-Instruct-2512-BF16-mmproj.gguf", byteCount: 600_000_000)],
            parameterBillions: 3.4, approximateDownloadBytes: 2_800_000_000,
            supportsVision: true, supportsReasoning: false, supportsToolCalling: true,
            license: "Apache-2.0"
        )
    ]

    public static let knownEntries = entries + retiredEntries
}

public actor LocalModelStore {
    public enum StoreError: LocalizedError {
        case invalidGGUF
        case invalidMLXSnapshot(String)
        case unexpectedArtifact(String)
        case insufficientDiskSpace(required: Int64, available: Int64)
        public var errorDescription: String? {
            switch self {
            case .invalidGGUF: FloeL10n.l("localmodels.local_model_catalog.the_downloaded_model_files_cannot_be")
            case .invalidMLXSnapshot: FloeL10n.l("localmodels.local_model_catalog.the_downloaded_model_files_are_incomplete")
            case .unexpectedArtifact: FloeL10n.l("localmodels.local_model_catalog.the_download_failed_the_security_check")
            case .insufficientDiskSpace(let required, let available):FloeL10n.l("localmodels.local_model_catalog.the_device_is_low_on_space", ByteCountFormatter.string(fromByteCount: required, countStyle: .file), ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
            }
        }
    }

    public let root: URL
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var activeOperations: [String: ComponentDownloadDelegate] = [:]
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeAgent/LocalModels", isDirectory: true)
    }

    public func installedModelURL(id: String) -> URL? {
        guard let entry = CuratedLocalModelCatalog.knownEntries.first(where: { $0.id == id }) else { return nil }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        switch entry.runtimeFormat {
        case .mlx:
            guard Self.hasValidManifest(in: directory, entry: entry),
                  (try? Self.validateMLXSnapshot(directory, entry: entry)) != nil else { return nil }
            return directory
        case .gguf:
            guard let model = entry.ggufModelFile else { return nil }
            let url = directory.appendingPathComponent(model)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    public func installedProjectorURL(id: String) -> URL? {
        guard let entry = CuratedLocalModelCatalog.knownEntries.first(where: { $0.id == id }),
              let projector = entry.ggufProjectorFile
        else { return nil }
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(projector)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Resident preflight uses the actual downloaded weight files rather than
    /// the catalog estimate. Tokenizer and configuration files are negligible
    /// beside the safetensors and are intentionally excluded.
    public func installedWeightBytes(id: String) -> UInt64? {
        guard let entry = CuratedLocalModelCatalog.knownEntries.first(where: { $0.id == id }),
              let url = installedModelURL(id: id) else { return nil }
        switch entry.runtimeFormat {
        case .gguf:
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            return UInt64(max(0, size))
        case .mlx:
            return entry.artifacts.reduce(into: UInt64(0)) { total, artifact in
                guard artifact.path.lowercased().hasSuffix(".safetensors") else { return }
                let values = try? url.appendingPathComponent(artifact.path)
                    .resourceValues(forKeys: [.fileSizeKey])
                total += UInt64(max(0, values?.fileSize ?? 0))
            }
        }
    }

    public func isInstalled(id: String) -> Bool {
        guard let entry = CuratedLocalModelCatalog.knownEntries.first(where: { $0.id == id }),
              installedModelURL(id: id) != nil else { return false }
        return entry.runtimeFormat == .mlx || entry.ggufProjectorFile == nil || installedProjectorURL(id: id) != nil
    }

    public func resumableModelIDs() -> Set<String> {
        let directory = root.appendingPathComponent(".downloads", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(children.compactMap { child in
            guard CuratedLocalModelCatalog.entries.contains(where: { $0.id == child.lastPathComponent }) else {
                return nil
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? []
            return files.contains(where: { $0.hasSuffix(".resume") }) ? child.lastPathComponent : nil
        })
    }

    public func download(
        _ entry: LocalModelCatalogEntry,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let traceID = UUID().uuidString
        let startedAt = Date()
        // Settle events begun inside the component delegate callbacks drain
        // at this operation's tail: on success only after snapshot
        // validation, the manifest write and the staging→directory swap
        // have committed durable state; on failure/cancellation only after
        // staging cleanup and backup restoration. No background-session
        // wake for this entry's identifiers may release its system
        // completion before that point.
        let ledger = ModelDownloadSettlementLedger()
        defer { ledger.drain() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let required = max(entry.approximateDownloadBytes * 2, 1_000_000_000)
        guard available >= required else {
            FloeLogger(category: .providers).warning(
                "localModelDownloadRejected trace=\(traceID) model=\(entry.id) reason=insufficientDisk requiredBytes=\(required) availableBytes=\(available)"
            )
            throw StoreError.insufficientDiskSpace(required: required, available: available)
        }
        FloeLogger(category: .providers).info(
            "localModelDownloadStarted trace=\(traceID) model=\(entry.id) format=\(entry.runtimeFormat.rawValue) revision=\(entry.revision) files=\(entry.artifacts.count) expectedBytes=\(entry.approximateDownloadBytes) availableBytes=\(available)"
        )

        let directory = root.appendingPathComponent(entry.id, isDirectory: true)
        let staging = root.appendingPathComponent(".\(entry.id)-\(UUID().uuidString).staging", isDirectory: true)
        let backup = root.appendingPathComponent(".\(entry.id)-\(UUID().uuidString).backup", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let totalBytes = max(entry.artifacts.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }, 1)
            var completedBytes: Int64 = 0
            for (index, artifact) in entry.artifacts.enumerated() {
                try Self.validateArtifactPath(artifact.path, format: entry.runtimeFormat)
                let stagedFile = staging.appendingPathComponent(artifact.path)
                let weight = Double(max(artifact.byteCount, 0)) / Double(totalBytes)
                let base = Double(completedBytes) / Double(totalBytes)
                try await downloadArtifact(
                    from: entry.artifactURL(artifact),
                    to: stagedFile,
                    expectedBytes: artifact.byteCount,
                    format: entry.runtimeFormat,
                    traceID: traceID,
                    modelID: entry.id,
                    component: "file-\(index)",
                    displayComponent: artifact.path,
                    overallBase: base,
                    overallWeight: weight,
                    ledger: ledger,
                    progress: progress
                )
                completedBytes += max(artifact.byteCount, 0)
                if index < entry.artifacts.count - 1 { ledger.checkpoint() }
            }
            switch entry.runtimeFormat {
            case .mlx:
                try Self.validateMLXSnapshot(staging, entry: entry)
                try Self.writeManifest(to: staging, entry: entry)
            case .gguf:
                break
            }

            let hadPrevious = FileManager.default.fileExists(atPath: directory.path)
            if hadPrevious { try FileManager.default.moveItem(at: directory, to: backup) }
            do {
                try FileManager.default.moveItem(at: staging, to: directory)
                if hadPrevious { try? FileManager.default.removeItem(at: backup) }
            } catch {
                if hadPrevious, !FileManager.default.fileExists(atPath: directory.path) {
                    try? FileManager.default.moveItem(at: backup, to: directory)
                }
                throw error
            }
            FloeLogger(category: .providers).info(
                "localModelInstallFinished trace=\(traceID) model=\(entry.id) replacedExisting=\(hadPrevious) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            switch entry.runtimeFormat {
            case .mlx: return directory
            case .gguf:
                guard let model = entry.ggufModelFile else { throw StoreError.invalidGGUF }
                return directory.appendingPathComponent(model)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if FileManager.default.fileExists(atPath: backup.path),
               !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.moveItem(at: backup, to: directory)
            }
            let nsError = error as NSError
            FloeLogger(category: .providers).warning(
                "localModelInstallFailed trace=\(traceID) model=\(entry.id) domain=\(nsError.domain) code=\(nsError.code) restoredPrevious=\(FileManager.default.fileExists(atPath: directory.path)) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
    }

    /// Cancels the active transfer while asking URLSession to preserve opaque
    /// resume data. A later call to `download` automatically resumes it.
    public func pauseDownload(id: String) {
        guard let task = activeTasks[id] else { return }
        let resumeURL = resumeDataURL(modelID: id, component: task.taskDescription ?? "weights")
        task.cancel { data in
            guard let data else { return }
            try? FileManager.default.createDirectory(
                at: resumeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: resumeURL, options: .atomic)
        }
        activeTasks[id] = nil
    }

    public func cancelDownload(id: String) {
        activeOperations[id]?.discardResumeData()
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        activeOperations[id] = nil
        let directory = root.appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    public func remove(id: String) throws {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func validateGGUF(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x47, 0x47, 0x55, 0x46]) else { throw StoreError.invalidGGUF }
    }

    static func validateSafetensors(_ url: URL) throws {
        if let problem = LocalModelSnapshotIntegrity.safetensorsProblem(url) {
            throw StoreError.invalidMLXSnapshot(problem.summary)
        }
    }

    static func validateMLXSnapshot(_ directory: URL, entry: LocalModelCatalogEntry) throws {
        guard entry.runtimeFormat == .mlx else { return }
        for artifact in entry.artifacts {
            try validateArtifactPath(artifact.path, format: .mlx)
            let file = directory.appendingPathComponent(artifact.path)
            guard FileManager.default.fileExists(atPath: file.path),
                  ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
                throw StoreError.invalidMLXSnapshot("missing \(artifact.path)")
            }
            if artifact.path.lowercased().hasSuffix(".safetensors") {
                try validateSafetensors(file)
            }
        }
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let modelType = object["model_type"] as? String,
              ["qwen3_5", "qwen3_5_moe", "gemma4", "gemma4_unified"].contains(modelType) else {
            throw StoreError.invalidMLXSnapshot("unsupported model_type")
        }
    }

    private struct InstalledManifest: Codable {
        let modelID: String
        let repository: String
        let revision: String
        let format: LocalModelRuntimeFormat
        let artifacts: [LocalModelArtifact]
    }

    /// Floe's install manifest. Only a directory that carries it was written
    /// by `LocalModelStore`; a directory without one is not assumed to be a
    /// complete install (unit-test seams, a hand-copied folder) and integrity
    /// auditing stays out of that path.
    public static let installManifestName = ".floe-model.json"

    /// True when `directory` carries Floe's install manifest.
    public static func hasInstallManifest(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(installManifestName).path
        )
    }

    private static func writeManifest(to directory: URL, entry: LocalModelCatalogEntry) throws {
        let manifest = InstalledManifest(
            modelID: entry.id,
            repository: entry.repository,
            revision: entry.revision,
            format: entry.runtimeFormat,
            artifacts: entry.artifacts
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(".floe-model.json"),
            options: .atomic
        )
    }

    private static func hasValidManifest(in directory: URL, entry: LocalModelCatalogEntry) -> Bool {
        let url = directory.appendingPathComponent(".floe-model.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(InstalledManifest.self, from: data) else { return false }
        return manifest.modelID == entry.id
            && manifest.repository == entry.repository
            && manifest.revision == entry.revision
            && manifest.format == entry.runtimeFormat
            && manifest.artifacts == entry.artifacts
    }

    private static func validateArtifactPath(
        _ path: String,
        format: LocalModelRuntimeFormat
    ) throws {
        let normalized = NSString(string: path).standardizingPath
        guard !path.isEmpty, !path.hasPrefix("/"), normalized == path,
              !normalized.hasPrefix("../"), normalized != ".." else {
            throw StoreError.unexpectedArtifact(path)
        }
        let allowedMLXNames: Set<String> = [
            "chat_template.jinja", "config.json", "generation_config.json",
            "preprocessor_config.json", "processor_config.json",
            "video_preprocessor_config.json", "tokenizer.json",
            "tokenizer_config.json", "vocab.json", "merges.txt",
            "special_tokens_map.json", "model.safetensors.index.json"
        ]
        switch format {
        case .mlx:
            guard allowedMLXNames.contains(path) || path.lowercased().hasSuffix(".safetensors") else {
                throw StoreError.unexpectedArtifact(path)
            }
        case .gguf:
            guard path.lowercased().hasSuffix(".gguf") else {
                throw StoreError.unexpectedArtifact(path)
            }
        }
    }

    private func downloadArtifact(
        from source: URL,
        to destination: URL,
        expectedBytes: Int64,
        format: LocalModelRuntimeFormat,
        traceID: String,
        modelID: String,
        component: String,
        displayComponent: String,
        overallBase: Double,
        overallWeight: Double,
        ledger: ModelDownloadSettlementLedger,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) async throws {
        let startedAt = Date()
        FloeLogger(category: .providers).debug(
            "localModelComponentDownloadStarted trace=\(traceID) model=\(modelID) component=\(displayComponent) expectedBytes=\(expectedBytes) host=\(source.host ?? "none")"
        )
        let resumeURL = resumeDataURL(modelID: modelID, component: component)
        let resumeData = try? Data(contentsOf: resumeURL)
        let sessionIdentifier = "org.floeagent.local-model.\(modelID).\(component)"
        let settlement = LocalModelDownloadSettlements.settlement(for: sessionIdentifier)
        let operation = ComponentDownloadDelegate(
            destination: destination,
            resumeDataURL: resumeURL,
            modelID: modelID,
            component: displayComponent,
            overallBase: overallBase,
            overallWeight: overallWeight,
            settlement: settlement,
            ledger: ledger,
            progress: progress
        )
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
        let restored = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }.first
        let task = restored
            ?? resumeData.map(session.downloadTask(withResumeData:))
            ?? session.downloadTask(with: source)
        task.taskDescription = component
        activeTasks[modelID] = task
        activeOperations[modelID] = operation
        do {
            let response = try await operation.start(task: task)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        } catch {
            activeTasks[modelID] = nil
            activeOperations[modelID] = nil
            session.finishTasksAndInvalidate()
            throw error
        }
        activeTasks[modelID] = nil
        activeOperations[modelID] = nil
        session.finishTasksAndInvalidate()
        try? FileManager.default.removeItem(at: resumeURL)
        let actualBytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard expectedBytes <= 0 || actualBytes == expectedBytes else {
            throw StoreError.invalidMLXSnapshot(
                "size mismatch for \(displayComponent): expected \(expectedBytes), got \(actualBytes)"
            )
        }
        if format == .gguf { try Self.validateGGUF(destination) }
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        FloeLogger(category: .providers).info(
            "localModelComponentDownloadFinished trace=\(traceID) model=\(modelID) component=\(displayComponent) bytes=\(bytes) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
    }

    private func resumeDataURL(modelID: String, component: String) -> URL {
        root.appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
            .appendingPathComponent("\(component).resume")
    }
}

final class ComponentDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeDataURL: URL
    private let modelID: String
    private let component: String
    private let overallBase: Double
    private let overallWeight: Double
    private let progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    /// Per-session-identifier settlement shared with the launch-hook facade.
    private let settlement: BackgroundDownloadEventSettlement
    /// Counts the settle event begun by this callback so the owning
    /// `LocalModelStore.download` operation ends it exactly once at its
    /// durable-commit tail.
    private let ledger: ModelDownloadSettlementLedger
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var response: URLResponse?
    private var movedFile = false
    private var permitsResumePersistence = true
    /// True once this transfer's FIRST terminal delegate callback has run.
    /// Gates BOTH the settle-event registration and the resume handoff to
    /// exactly once per transfer, independent of whether `start` has
    /// attached yet — the event contract is callback-bound, not
    /// continuation-bound (see `finish`).
    private var settled = false
    private var terminalCallbackClaimed = false
    /// Terminal result stored when the callback arrived BEFORE `start`
    /// attached (background-session restore replay: URLSession can deliver
    /// replayed callbacks the moment the session is created, and
    /// `session.allTasks` awaits before `start` runs). The awaiting
    /// operation consumes it in `start`, so its verification/commit work
    /// and the ledger tail drain still run; the resume is never lost.
    private var storedResult: Result<URLResponse, Error>?
    private let startedAt = Date()

    init(
        destination: URL,
        resumeDataURL: URL,
        modelID: String,
        component: String,
        overallBase: Double,
        overallWeight: Double,
        settlement: BackgroundDownloadEventSettlement,
        ledger: ModelDownloadSettlementLedger,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) {
        self.destination = destination
        self.resumeDataURL = resumeDataURL
        self.modelID = modelID
        self.component = component
        self.overallBase = overallBase
        self.overallWeight = overallWeight
        self.settlement = settlement
        self.ledger = ledger
        self.progress = progress
    }

    func start(task: URLSessionDownloadTask) async throws -> URLResponse {
        enum Binding {
            case attached
            case awaitingReplay
            case replayed(Result<URLResponse, Error>)
            case consumed
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
            let binding: Binding = lock.withLock {
                if settled {
                    // The terminal callback already ran (restore-replay
                    // order). Hand back its stored result instead of
                    // installing a continuation that nothing can resume.
                    if let stored = storedResult {
                        storedResult = nil
                        return .replayed(stored)
                    }
                    return .consumed
                }
                guard self.continuation == nil else { return .consumed }
                self.continuation = continuation
                return terminalCallbackClaimed ? .awaitingReplay : .attached
            }
            switch binding {
            case .attached:
                task.resume()
            case .awaitingReplay:
                // The callback is registering its ledger event. It will
                // resume this continuation only after that registration.
                task.cancel()
                break
            case .replayed(let result):
                // The task is terminal (its callbacks were replayed by
                // URLSession when the restored session was created); its
                // settle event was registered inside that callback. Do not
                // resume it. allTasks can already have dropped the terminal
                // task, leaving the caller's replacement task suspended;
                // cancel that unused task (a no-op if already completed).
                task.cancel()
                continuation.resume(with: result)
            case .consumed:
                // Defensive: a second attach for one transfer. Never strand
                // the caller's continuation.
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }

    func discardResumeData() {
        lock.withLock { permitsResumePersistence = false }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let componentFraction = expected.map { min(1, Double(totalBytesWritten) / Double($0)) } ?? 0
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.1)
        let speed = Double(totalBytesWritten) / elapsed
        let remaining = expected.map { max(0, Double($0 - totalBytesWritten) / max(speed, 1)) }
        progress?(LocalModelDownloadProgress(
            modelID: modelID,
            component: component,
            bytesReceived: totalBytesWritten,
            bytesExpected: expected,
            fractionCompleted: overallBase + componentFraction * overallWeight,
            bytesPerSecond: speed,
            estimatedRemainingSeconds: remaining
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock {
                response = downloadTask.response
                movedFile = true
            }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            let mayPersist = lock.withLock { permitsResumePersistence }
            if mayPersist,
               let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? FileManager.default.createDirectory(
                    at: resumeDataURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: resumeDataURL, options: .atomic)
            }
            finish(.failure(error))
            return
        }
        let result: Result<URLResponse, Error> = lock.withLock {
            guard movedFile, let response else { return .failure(URLError(.cannotCreateFile)) }
            return .success(response)
        }
        finish(result)
    }

    private func finish(_ result: Result<URLResponse, Error>) {
        let firstTerminal = lock.withLock {
            guard !terminalCallbackClaimed else { return false }
            terminalCallbackClaimed = true
            return true
        }
        guard firstTerminal else { return }
        // Publish a replayable result only AFTER the event is registered.
        // A concurrent start must not consume it and drain the operation
        // while finish is still between its lock and ledger.began.
        ledger.began(settlement)
        let waiting: CheckedContinuation<URLResponse, Error>? = lock.withLock {
            settled = true
            let waiting = self.continuation
            self.continuation = nil
            if waiting == nil {
                // Restore-replay order: no operation has attached through
                // `start` yet. Store the terminal result so the owning
                // operation still awaits this transfer, runs its
                // validation/commit and drains the event registered below.
                storedResult = result
            }
            return waiting
        }
        // This terminal callback schedules the component's owned async
        // settle follow-up in the awaiting download task (HTTP status/size/
        // format validation now, and the durable staging commit at the
        // operation tail). The event MUST be registered synchronously here,
        // inside the delegate callback — BEFORE any continuation handoff and
        // regardless of whether `start` has attached: `urlSessionDidFinishEvents`
        // for this wake can arrive the moment the callback returns, and the
        // system completion must then wait for the settle to drain instead
        // of letting the process be suspended or killed mid-commit. The
        // matching `endEvent` runs exactly once when the owning `download`
        // operation drains its ledger — on every success, error and
        // cancellation path.
        waiting?.resume(with: result)
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        // System side complete ONLY. The stored launch completion fires
        // exactly once on main after every settle event this wake
        // registered has drained — the previous path hopped through a
        // `Task { @MainActor }` and released OS completion while the
        // verification/install/state-commit work was still running.
        LocalModelDownloadSettlements.settlement(for: identifier).sessionDidFinishEvents()
    }
    #endif
}

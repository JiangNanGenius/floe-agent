import Foundation
import FloeCore

public struct LocalModelCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var profileID: UUID
    public var displayName: String
    public var repository: String
    public var modelFile: String
    public var visionProjectorFile: String?
    public var parameterBillions: Double
    public var approximateDownloadBytes: Int64
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var supportsToolCalling: Bool
    public var license: String

    public var modelURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/main/\(modelFile)?download=true")!
    }
    public var visionProjectorURL: URL? {
        visionProjectorFile.flatMap { URL(string: "https://huggingface.co/\(repository)/resolve/main/\($0)?download=true") }
    }
}

public enum CuratedLocalModelCatalog {
    /// Weights are never bundled with Floe. These Apache-2.0 entries are
    /// downloaded explicitly by the user and verified as GGUF before use.
    public static let entries: [LocalModelCatalogEntry] = [
        .init(
            id: "qwen3.5-4b-q4km", profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000001")!, displayName: "Qwen3.5 4B Q4_K_M",
            repository: "unsloth/Qwen3.5-4B-GGUF", modelFile: "Qwen3.5-4B-Q4_K_M.gguf",
            visionProjectorFile: "mmproj-BF16.gguf", parameterBillions: 4,
            approximateDownloadBytes: 3_200_000_000, supportsVision: true,
            supportsReasoning: true, supportsToolCalling: true, license: "Apache-2.0"
        ),
        .init(
            id: "qwen3.5-9b-q4km", profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000002")!, displayName: "Qwen3.5 9B Q4_K_M",
            repository: "unsloth/Qwen3.5-9B-GGUF", modelFile: "Qwen3.5-9B-Q4_K_M.gguf",
            visionProjectorFile: "mmproj-BF16.gguf", parameterBillions: 9,
            approximateDownloadBytes: 6_300_000_000, supportsVision: true,
            supportsReasoning: true, supportsToolCalling: true, license: "Apache-2.0"
        ),
        .init(
            id: "ministral3-3b-q4km", profileID: UUID(uuidString: "A1480001-0000-4000-8000-000000000003")!, displayName: "Ministral 3 3B Q4_K_M",
            repository: "mistralai/Ministral-3-3B-Instruct-2512-GGUF",
            modelFile: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
            visionProjectorFile: "Ministral-3-3B-Instruct-2512-BF16-mmproj.gguf",
            parameterBillions: 3.4, approximateDownloadBytes: 2_800_000_000,
            supportsVision: true, supportsReasoning: false, supportsToolCalling: true,
            license: "Apache-2.0"
        )
    ]
}

public actor LocalModelStore {
    public enum StoreError: LocalizedError {
        case invalidGGUF
        case insufficientDiskSpace(required: Int64, available: Int64)
        public var errorDescription: String? {
            switch self {
            case .invalidGGUF: "The downloaded file is not a valid GGUF model."
            case .insufficientDiskSpace(let required, let available):
                "Not enough free space (required \(required), available \(available))."
            }
        }
    }

    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeAgent/LocalModels", isDirectory: true)
    }

    public func installedModelURL(id: String) -> URL? {
        guard let entry = CuratedLocalModelCatalog.entries.first(where: { $0.id == id }) else { return nil }
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(entry.modelFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func installedProjectorURL(id: String) -> URL? {
        guard let entry = CuratedLocalModelCatalog.entries.first(where: { $0.id == id }),
              let projector = entry.visionProjectorFile
        else { return nil }
        let url = root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(projector)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isInstalled(id: String) -> Bool {
        guard let entry = CuratedLocalModelCatalog.entries.first(where: { $0.id == id }),
              installedModelURL(id: id) != nil else { return false }
        return entry.visionProjectorFile == nil || installedProjectorURL(id: id) != nil
    }

    public func download(_ entry: LocalModelCatalogEntry) async throws -> URL {
        let traceID = UUID().uuidString
        let startedAt = Date()
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
            "localModelDownloadStarted trace=\(traceID) model=\(entry.id) expectedBytes=\(entry.approximateDownloadBytes) availableBytes=\(available) visionProjector=\(entry.visionProjectorFile != nil)"
        )

        let directory = root.appendingPathComponent(entry.id, isDirectory: true)
        let staging = root.appendingPathComponent(".\(entry.id)-\(UUID().uuidString).staging", isDirectory: true)
        let backup = root.appendingPathComponent(".\(entry.id)-\(UUID().uuidString).backup", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let stagedModel = staging.appendingPathComponent(entry.modelFile)
            try await Self.downloadGGUF(
                from: entry.modelURL, to: stagedModel,
                traceID: traceID, modelID: entry.id, component: "weights"
            )
            if let projectorURL = entry.visionProjectorURL, let projectorName = entry.visionProjectorFile {
                try await Self.downloadGGUF(
                    from: projectorURL,
                    to: staging.appendingPathComponent(projectorName),
                    traceID: traceID, modelID: entry.id, component: "projector"
                )
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
            return directory.appendingPathComponent(entry.modelFile)
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

    public func remove(id: String) throws {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func validateGGUF(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x47, 0x47, 0x55, 0x46]) else { throw StoreError.invalidGGUF }
    }

    private static func downloadGGUF(
        from source: URL,
        to destination: URL,
        traceID: String,
        modelID: String,
        component: String
    ) async throws {
        let startedAt = Date()
        FloeLogger(category: .providers).debug(
            "localModelComponentDownloadStarted trace=\(traceID) model=\(modelID) component=\(component) host=\(source.host ?? "none")"
        )
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try validateGGUF(temporary)
        let bytes = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try FileManager.default.moveItem(at: temporary, to: destination)
        FloeLogger(category: .providers).info(
            "localModelComponentDownloadFinished trace=\(traceID) model=\(modelID) component=\(component) bytes=\(bytes) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
    }
}

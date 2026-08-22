import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(iOS)
/// Bridges URLSession background relaunch callbacks back to UIKit without
/// making the catalog target depend on the application target.
@MainActor
public final class LocalModelBackgroundEvents {
    public static let shared = LocalModelBackgroundEvents()
    private var completions: [String: () -> Void] = [:]
    private var sessionsThatAlreadyFinished: Set<String> = []

    private init() {}

    public func register(identifier: String, completion: @escaping () -> Void) {
        if sessionsThatAlreadyFinished.remove(identifier) != nil {
            completion()
        } else {
            completions[identifier] = completion
        }
    }

    fileprivate func finish(identifier: String) {
        if let completion = completions.removeValue(forKey: identifier) {
            completion()
        } else {
            sessionsThatAlreadyFinished.insert(identifier)
        }
    }
}
#endif

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
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var activeOperations: [String: ComponentDownloadDelegate] = [:]
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
            try await downloadGGUF(
                from: entry.modelURL, to: stagedModel,
                traceID: traceID, modelID: entry.id, component: "weights",
                overallBase: 0, overallWeight: entry.visionProjectorFile == nil ? 1 : 0.85,
                progress: progress
            )
            if let projectorURL = entry.visionProjectorURL, let projectorName = entry.visionProjectorFile {
                try await downloadGGUF(
                    from: projectorURL,
                    to: staging.appendingPathComponent(projectorName),
                    traceID: traceID, modelID: entry.id, component: "projector",
                    overallBase: 0.85, overallWeight: 0.15,
                    progress: progress
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

    private func downloadGGUF(
        from source: URL,
        to destination: URL,
        traceID: String,
        modelID: String,
        component: String,
        overallBase: Double,
        overallWeight: Double,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) async throws {
        let startedAt = Date()
        FloeLogger(category: .providers).debug(
            "localModelComponentDownloadStarted trace=\(traceID) model=\(modelID) component=\(component) host=\(source.host ?? "none")"
        )
        let resumeURL = resumeDataURL(modelID: modelID, component: component)
        let resumeData = try? Data(contentsOf: resumeURL)
        let operation = ComponentDownloadDelegate(
            destination: destination,
            resumeDataURL: resumeURL,
            modelID: modelID,
            component: component,
            overallBase: overallBase,
            overallWeight: overallWeight,
            progress: progress
        )
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "org.floeagent.local-model.\(modelID).\(component)"
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
        try Self.validateGGUF(destination)
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        FloeLogger(category: .providers).info(
            "localModelComponentDownloadFinished trace=\(traceID) model=\(modelID) component=\(component) bytes=\(bytes) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
    }

    private func resumeDataURL(modelID: String, component: String) -> URL {
        root.appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
            .appendingPathComponent("\(component).resume")
    }
}

private final class ComponentDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeDataURL: URL
    private let modelID: String
    private let component: String
    private let overallBase: Double
    private let overallWeight: Double
    private let progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var response: URLResponse?
    private var movedFile = false
    private var permitsResumePersistence = true
    private let startedAt = Date()

    init(
        destination: URL,
        resumeDataURL: URL,
        modelID: String,
        component: String,
        overallBase: Double,
        overallWeight: Double,
        progress: (@Sendable (LocalModelDownloadProgress) -> Void)?
    ) {
        self.destination = destination
        self.resumeDataURL = resumeDataURL
        self.modelID = modelID
        self.component = component
        self.overallBase = overallBase
        self.overallWeight = overallWeight
        self.progress = progress
    }

    func start(task: URLSessionDownloadTask) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            task.resume()
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
        let continuation: CheckedContinuation<URLResponse, Error>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            LocalModelBackgroundEvents.shared.finish(identifier: identifier)
        }
    }
    #endif
}

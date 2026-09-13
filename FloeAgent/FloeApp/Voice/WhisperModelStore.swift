// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit

actor WhisperModelStore {
    static let shared = WhisperModelStore()
    struct Manifest: Decodable, Sendable {
        struct Asset: Decodable, Sendable { let path: String; let url: URL; let sha256: String; let byteCount: Int64 }
        let schemaVersion: Int
        let id: String
        let title: String
        let sourceRevision: String
        let files: [Asset]
    }
    enum Failure: Error, LocalizedError {
        case unavailable, corrupt, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "Whisper 模型尚未安装。"
            case .corrupt: "Whisper 资源不完整或校验失败，请重新下载。"
            case .busy: "语音识别正在使用模型，请结束后再操作。"
            }
        }
    }
    struct InstallationState: Sendable {
        var running = false
        var completed: Int64 = 0
        var total: Int64 = 0
        var error: String?
    }
    private var installation = InstallationState()
    private var installationID = UUID()
    private var installationTask: Task<Void, Never>?
    func installationState() -> InstallationState { installation }
    func beginInstallation() {
        guard installationTask == nil else { return }
        UserDefaults.standard.set(true, forKey: "whisper.installation.requested")
        installation = InstallationState(running: true)
        let id = UUID()
        installationID = id
        installationTask = Task {
            do {
                try await install { done, total in
                    Task { await self.updateProgress(done, total: total, id: id) }
                }
                UserDefaults.standard.set(false, forKey: "whisper.installation.requested")
            } catch is CancellationError {
            } catch { installation.error = error.localizedDescription }
            installation.running = false
            installationTask = nil
        }
    }
    func restoreInstallation() {
        if UserDefaults.standard.bool(forKey: "whisper.installation.requested") { beginInstallation() }
    }
    func cancelInstallation() {
        UserDefaults.standard.set(false, forKey: "whisper.installation.requested")
        installationTask?.cancel()
    }
    private func updateProgress(_ done: Int64, total: Int64, id: UUID) {
        guard installationID == id, installation.running else { return }
        installation.completed = max(installation.completed, done); installation.total = total
    }
    private var leases = Set<UUID>()
    private var installing = false
    private func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/SpeechModels", isDirectory: true)
    }
    func manifest() throws -> Manifest {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Whisper") else { throw Failure.unavailable }
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.id == "whisper-small-multilingual", !value.files.isEmpty,
              Set(value.files.map(\.path)).count == value.files.count,
              value.files.allSatisfy({ asset in
                  !asset.path.hasPrefix("/") && !asset.path.contains("\\") && !asset.path.split(separator: "/").contains("..") &&
                  asset.url.scheme == "https" && asset.url.host == "huggingface.co" && asset.byteCount > 0 &&
                  asset.sha256.count == 64 && asset.sha256.allSatisfy(\.isHexDigit)
              }) else { throw Failure.corrupt }
        return value
    }
    private func location(_ manifest: Manifest) throws -> URL {
        try root().appendingPathComponent(manifest.id + "-" + manifest.sourceRevision, isDirectory: true)
    }
    func isInstalled() -> Bool {
        guard let value = try? manifest(), let folder = try? location(value) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("installed.json").path)
    }
    func acquire() throws -> (UUID, URL) {
        guard !installing, leases.isEmpty, isInstalled() else { throw Failure.unavailable }
        let value = try manifest(), folder = try location(value)
        for asset in value.files { try verify(folder.appendingPathComponent(asset.path), asset: asset) }
        let lease = UUID(); leases.insert(lease)
        return (lease, folder)
    }
    func release(_ lease: UUID) { leases.remove(lease) }
    func remove() throws {
        guard leases.isEmpty, !installing else { throw Failure.busy }
        let folder = try location(manifest())
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func install(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !installing, leases.isEmpty else { throw Failure.busy }
        installing = true; defer { installing = false }
        let manifest = try manifest(), base = try root(), destination = try location(manifest)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let staging = base.appendingPathComponent(".download-\(manifest.id)-\(manifest.sourceRevision)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
        if let free = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < total * 2 { throw CocoaError(.fileWriteOutOfSpace) }
        var completed: Int64 = 0
        for asset in manifest.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(asset.path)
            if (try? verify(target, asset: asset)) != nil {
                completed += asset.byteCount; progress(completed, total)
                continue
            }
            try? FileManager.default.removeItem(at: target)
            let completedBeforeAsset = completed
            let temporary = try await WhisperDownloadCoordinator.shared.download(asset.url) { bytes in
                progress(completedBeforeAsset + min(bytes, asset.byteCount), total)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try verify(temporary, asset: asset)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += asset.byteCount; progress(completed, total)
        }
        try Task.checkCancellation()
        try Data(manifest.sourceRevision.utf8).write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
    private func verify(_ url: URL, asset: Manifest.Asset) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.byteCount else { throw Failure.corrupt }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw Failure.corrupt }
    }
}
/// Background transfer ownership is independent of SwiftUI and the installer
/// continuation. Finished files and resume data survive process recreation.
final class WhisperDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = WhisperDownloadCoordinator()
    static let identifier = "org.floeagent.whisper-downloads"
    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<URL, Error>
        let progress: @Sendable (Int64) -> Void
        var cancelled = false
    }
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var backgroundCompletion: (() -> Void)?
    private var session: URLSession!
    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }
    private func file(_ key: String, suffix: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeAgent/SpeechTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(key + suffix)
    }
    func registerBackgroundCompletion(_ completion: @escaping () -> Void) {
        lock.withLock { backgroundCompletion = completion }
    }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = try file(key, suffix: ".download")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[key] = Pending(id: id, continuation: continuation, progress: progress) }
                if Task.isCancelled {
                    lock.withLock { pending.removeValue(forKey: key) }?.continuation.resume(throwing: CancellationError())
                    return
                }
                session.getAllTasks { [self] tasks in
                    lock.withLock {
                        guard let waiter = pending[key], waiter.id == id, !waiter.cancelled else { return }
                        // A completion may have arrived between the disk check
                        // and listener registration on process restoration.
                        if FileManager.default.fileExists(atPath: destination.path) {
                            pending.removeValue(forKey: key)?.continuation.resume(returning: destination)
                            return
                        }
                        if let task = tasks.first(where: { $0.taskDescription == key }) { task.resume(); return }
                        let resumeURL = try? file(key, suffix: ".resume")
                        let task: URLSessionDownloadTask
                        if let resumeURL, let data = try? Data(contentsOf: resumeURL) {
                            task = session.downloadTask(withResumeData: data)
                            try? FileManager.default.removeItem(at: resumeURL)
                        } else { task = session.downloadTask(with: url) }
                        task.taskDescription = key
                        task.resume()
                    }
                }
            }
        } onCancel: {
            // Keep the installer occupied until the old transfer has stopped.
            // Otherwise a quick retry can attach to a task being cancelled by
            // this asynchronous callback and lose its continuation.
            self.lock.withLock { if self.pending[key]?.id == id { self.pending[key]?.cancelled = true } }
            self.session.getAllTasks { tasks in
                guard self.lock.withLock({ self.pending[key]?.id == id }) else { return }
                let matches = tasks.compactMap { $0 as? URLSessionDownloadTask }.filter { $0.taskDescription == key }
                if matches.isEmpty {
                    self.lock.withLock { self.pending.removeValue(forKey: key) }?.continuation.resume(throwing: CancellationError())
                }
                for task in matches {
                    task.cancel { data in
                        if let data, let target = try? self.file(key, suffix: ".resume") { try? data.write(to: target, options: .atomic) }
                    }
                }
            }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        lock.withLock { pending[key]?.progress }?(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw WhisperModelStore.Failure.corrupt }
            let target = try file(key, suffix: ".download")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            if let resume = try? file(key, suffix: ".resume") { try? FileManager.default.removeItem(at: resume) }
            lock.withLock { pending.removeValue(forKey: key) }?.continuation.resume(returning: target)
        } catch { lock.withLock { pending.removeValue(forKey: key) }?.continuation.resume(throwing: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error else { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let target = try? file(key, suffix: ".resume") { try? data.write(to: target, options: .atomic) }
        if let waiter = lock.withLock({ pending.removeValue(forKey: key) }) {
            waiter.continuation.resume(throwing: waiter.cancelled ? CancellationError() : error)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { let value = backgroundCompletion; backgroundCompletion = nil; return value }
        DispatchQueue.main.async { completion?() }
    }
}
#endif

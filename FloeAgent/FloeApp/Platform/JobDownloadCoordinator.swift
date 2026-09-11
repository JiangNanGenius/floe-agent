// FloeApp — Background URLSession owner for jobs.submit download work.
//
// Downloads keep running while the app is suspended and relaunch the process
// on completion. Transient network failures transparently resume from the
// system-provided resume data; the job only fails after the retry budget is
// exhausted. Results land in the task workspace when it is still reachable,
// otherwise in an app-owned fallback directory with an honest note.

#if canImport(UIKit)
import Foundation
import Crypto
import FloeCore
import FloeExecution
import FloePersistence
import FloeTools
import FloeWorkspace

/// Holds the system completion handler for the background session until all
/// pending delegate events are drained.
final class JobDownloadBackgroundEvents: @unchecked Sendable {
    static let shared = JobDownloadBackgroundEvents()
    private let lock = NSLock()
    private var completionHandler: (() -> Void)?

    func register(_ handler: @escaping () -> Void) {
        lock.lock()
        completionHandler = handler
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        handler?()
    }
}

final class JobDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "org.floeagent.job-downloads"
    /// Job downloads may far exceed the interactive 64 MB tool cap.
    static let defaultMaxBytes = 2 * 1_024 * 1_024 * 1_024
    static let maxAutoResumeAttempts = 5

    private let database: DatabaseManager
    private let onTerminal: @Sendable (BackgroundJob) async -> Void
    /// jobID -> in-flight bookkeeping. The database record stays authoritative
    /// across process relaunches; these maps only accelerate progress writes.
    private var progressState: [UUID: (received: Int64, expected: Int64, lastWrite: Date)] = [:]
    private var resumeAttempts: [UUID: Int] = [:]
    private let stateLock = NSLock()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(database: DatabaseManager, onTerminal: @escaping @Sendable (BackgroundJob) async -> Void) {
        self.database = database
        self.onTerminal = onTerminal
        super.init()
        _ = session
    }

    // MARK: - Ownership handoff from BackgroundJobService

    /// Returns true when the background session accepted the job. A false
    /// return (or a throw) makes the service run the job in-process instead.
    func take(job: BackgroundJob, context: BackgroundJobDownloadContext) async throws -> Bool {
        let args = try JSONDecoder().decode(URLDownloadTool.Arguments.self, from: job.payloadJSON)
        // LAN targets and missing workspaces stay on the in-process path,
        // which applies the interactive policies verbatim.
        guard args.localNetwork != true, context.workspaceRootURL != nil else { return false }
        guard let url = URL(string: args.url),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.host != nil, !url.isLocalOrPrivateNetwork else { return false }

        let store = BackgroundJobStore(database: database)
        let tasks = await session.allTasks
        if tasks.contains(where: { $0.taskDescription == job.id.uuidString }) {
            return true
        }
        _ = try await store.transition(id: job.id, to: .running)
        let task = session.downloadTask(with: url)
        task.taskDescription = job.id.uuidString
        task.priority = URLSessionTask.highPriority
        task.resume()
        return true
    }

    func cancel(jobID: UUID) async {
        let tasks = await session.allTasks
        for task in tasks where task.taskDescription == jobID.uuidString {
            task.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let raw = downloadTask.taskDescription, let jobID = UUID(uuidString: raw) else { return }
        stateLock.lock()
        var state = progressState[jobID] ?? (0, 0, .distantPast)
        state.received = totalBytesWritten
        state.expected = totalBytesExpectedToWrite
        let shouldWrite = Date().timeIntervalSince(state.lastWrite) > 0.5
        if shouldWrite { state.lastWrite = Date() }
        progressState[jobID] = state
        stateLock.unlock()
        guard shouldWrite else { return }
        let progress: [String: Any] = [
            "receivedBytes": totalBytesWritten,
            "expectedBytes": totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: progress) else { return }
        Task {
            let store = BackgroundJobStore(database: database)
            guard let job = try? await store.job(id: jobID), job.state == .running else { return }
            var updated = job
            updated.progressJSON = data
            updated.updatedAt = Date()
            _ = try? await store.save(updated)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let raw = downloadTask.taskDescription, let jobID = UUID(uuidString: raw) else { return }
        // The temporary file is removed when this callback returns, so stage
        // it into app-owned storage synchronously and finish asynchronously.
        let stagingDirectory: URL
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            stagingDirectory = support.appendingPathComponent("FloeAgent/JobDownloads/\(jobID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            Task { await self.fail(jobID: jobID, message: error.localizedDescription) }
            return
        }
        let staging = stagingDirectory.appendingPathComponent("payload.bin")
        do {
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { await self.fail(jobID: jobID, message: error.localizedDescription) }
            return
        }
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let contentType = downloadTask.response?.mimeType ?? "application/octet-stream"
        Task { await self.settle(jobID: jobID, staging: staging, statusCode: statusCode, contentType: contentType) }
    }

    private func settle(jobID: UUID, staging: URL, statusCode: Int, contentType: String) async {
        let store = BackgroundJobStore(database: database)
        do {
            guard let job = try await store.job(id: jobID), job.state == .running else { return }
            let args = try JSONDecoder().decode(URLDownloadTool.Arguments.self, from: job.payloadJSON)
            let cap = args.maxBytes ?? Self.defaultMaxBytes
            let byteCount = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard byteCount <= cap else {
                try? FileManager.default.removeItem(at: staging)
                _ = try? await store.transition(id: jobID, to: .failed) {
                    $0.lastError = "Download exceeded the \(cap)-byte job cap"
                }
                await self.notifyTerminal(jobID: jobID)
                return
            }

            guard (200..<300).contains(statusCode) else {
                try? FileManager.default.removeItem(at: staging)
                _ = try? await store.transition(id: jobID, to: .failed) {
                    $0.lastError = "Download failed with HTTP \(statusCode)"
                }
                await self.notifyTerminal(jobID: jobID)
                return
            }

            var destination: URL?
            var workspaceRelative: String?
            var fallbackNote: String?
            if let rootPath = job.workspaceRootPath {
                var isDirectory: ObjCBool = false
                let rootReachable = FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                if rootReachable,
                   let guarder = try? WorkspacePathGuard(rootURL: URL(fileURLWithPath: rootPath)),
                   let resolved = try? guarder.resolve(args.destination) {
                    // A reachable workspace is authoritative: a conflict or any
                    // write failure is reported to the model instead of
                    // silently relocating the file to app storage. Overwrite
                    // only happens with explicit consent carried in the job.
                    do {
                        _ = try AtomicFileCommitter.commit(
                            stagedFile: staging,
                            to: resolved,
                            policy: FileCommitPolicy(
                                conflict: args.overwrite == true
                                    ? .replaceAtomically(consent: true)
                                    : .failIfExists,
                                maxBytes: cap
                            )
                        )
                        destination = resolved
                        workspaceRelative = args.destination
                    } catch {
                        try? FileManager.default.removeItem(at: staging)
                        _ = try? await store.transition(id: jobID, to: .failed) {
                            $0.lastError = error.localizedDescription
                                + " Ask the user, then resubmit with overwrite=true to replace it."
                        }
                        await self.notifyTerminal(jobID: jobID)
                        return
                    }
                }
            }
            if destination == nil {
                let fallback = stagingDirectoryURL(jobID).appendingPathComponent(
                    URL(fileURLWithPath: args.destination).lastPathComponent
                )
                if FileManager.default.fileExists(atPath: fallback.path) {
                    try FileManager.default.removeItem(at: fallback)
                }
                try FileManager.default.moveItem(at: staging, to: fallback)
                destination = fallback
                fallbackNote = fallbackNote ?? "The task workspace was unreachable after relaunch; the file is in app-owned storage; copy it into a workspace to share it."
            }
            guard let destination else { return }

            let digest = Self.fileSHA256(destination)
            var summaryText = "status=ok path=\(workspaceRelative ?? destination.path) statusCode=\(statusCode) contentType=\(contentType) bytes=\(byteCount) sha256=\(digest)"
            if let fallbackNote { summaryText += "\nnote=\(fallbackNote)" }
            let finalSummary = summaryText
            let finalPath = workspaceRelative ?? destination.path
            _ = try? await store.transition(id: jobID, to: .completed) {
                $0.resultSummary = finalSummary
                $0.resultDigest = digest
                $0.resultPath = finalPath
            }
            await self.notifyTerminal(jobID: jobID)
        } catch {
            await fail(jobID: jobID, message: error.localizedDescription)
        }
    }

    private func stagingDirectoryURL(_ jobID: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("FloeAgent/JobDownloads/\(jobID.uuidString)", isDirectory: true)
    }

    private func fail(jobID: UUID, message: String) async {
        let store = BackgroundJobStore(database: database)
        _ = try? await store.transition(id: jobID, to: .failed) { $0.lastError = message }
        await self.notifyTerminal(jobID: jobID)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let raw = task.taskDescription, let jobID = UUID(uuidString: raw) else { return }
        guard let error = error as? NSError else { return }
        // jobs.cancel cancels the task after the record is already cancelled.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }

        stateLock.lock()
        let attempts = (resumeAttempts[jobID] ?? 0) + 1
        resumeAttempts[jobID] = attempts
        stateLock.unlock()
        let resumeData = error.userInfo["NSURLSessionDownloadTaskResumeDataKey"] as? Data
        if let resumeData, attempts <= Self.maxAutoResumeAttempts {
            // Transparent resume: the job stays running; the model never sees
            // the transient network interruption.
            Task {
                let store = BackgroundJobStore(database: self.database)
                guard (try? await store.job(id: jobID))?.state == .running else { return }
                try? await Task.sleep(nanoseconds: UInt64(min(30, attempts * 5)) * 1_000_000_000)
                let resumed = self.session.downloadTask(withResumeData: resumeData)
                resumed.taskDescription = jobID.uuidString
                resumed.priority = URLSessionTask.highPriority
                resumed.resume()
            }
            return
        }
        Task {
            let store = BackgroundJobStore(database: database)
            _ = try? await store.transition(id: jobID, to: .failed) {
                $0.lastError = error.localizedDescription
                $0.retryCount += attempts
            }
            await self.notifyTerminal(jobID: jobID)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        JobDownloadBackgroundEvents.shared.finish()
    }

    // MARK: - Helpers

    /// Synchronous lock wrapper so async callers never touch NSLock directly.
    private func clearBookkeeping(for jobID: UUID) {
        stateLock.lock()
        progressState[jobID] = nil
        resumeAttempts[jobID] = nil
        stateLock.unlock()
    }

    private func notifyTerminal(jobID: UUID) async {
        clearBookkeeping(for: jobID)
        let store = BackgroundJobStore(database: database)
        if let job = try? await store.job(id: jobID) {
            await onTerminal(job)
        }
    }

    private static func fileSHA256(_ url: URL) -> String {
        guard let stream = InputStream(url: url) else { return "" }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read)) }
            else { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif

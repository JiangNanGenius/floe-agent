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

/// Holds the system completion handler for the background session until the
/// system finish event HAS arrived AND every async settle/drain the
/// coordinator registered has completed. The completion is then called
/// exactly once on the main thread (see `BackgroundDownloadEventSettlement`).
/// The launch hook in `FloeAgentApp` keeps calling the one-argument
/// `register` unchanged; the two-argument form additionally tracks the
/// bounded wake bootstrap ATOMICALLY before the handler is stored, so a
/// finish that already arrived can never release the wake before the
/// bootstrap is accounted. The coordinator drives event accounting through
/// `settlement`.
final class JobDownloadBackgroundEvents: @unchecked Sendable {
    static let shared = JobDownloadBackgroundEvents()
    let settlement = BackgroundDownloadEventSettlement(name: "job-downloads")

    func register(_ handler: @escaping () -> Void) {
        settlement.registerSystemCompletionHandler(handler)
    }

    func register(
        _ handler: @escaping () -> Void,
        bootstrap: @escaping @Sendable () async -> Void
    ) {
        settlement.registerSystemCompletionHandler(handler, bootstrap: bootstrap)
    }
}

final class JobDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "org.floeagent.job-downloads"
    /// Job downloads may far exceed the interactive 64 MB tool cap.
    static let defaultMaxBytes = 2 * 1_024 * 1_024 * 1_024
    static let maxAutoResumeAttempts = 5

    private let database: DatabaseManager
    private let onTerminal: @Sendable (BackgroundJob) async -> Void
    private let reattacher: WorkspaceRootReattacher?
    /// jobID -> in-flight bookkeeping. The database record stays authoritative
    /// across process relaunches; these maps only accelerate progress writes.
    private var progressState: [UUID: (received: Int64, expected: Int64, lastWrite: Date)] = [:]
    private var resumeAttempts: [UUID: Int] = [:]
    /// Ownership generation per job. `cancel` bumps it (and cancels the owned
    /// delayed-retry task) so a sleeping retry can never resume work for a
    /// job the user already cancelled, and a settle task rechecks it after
    /// every await. The monotonic counter is coordinator-local; the durable
    /// job row stays the state authority.
    private var jobGenerations: [UUID: UInt64] = [:]
    private var pendingRetryTasks: [UUID: Task<Void, Never>] = [:]
    private let stateLock = NSLock()

    /// The service-owned drain for this background session's async settle
    /// work. Every follow-up Task registers synchronously inside the
    /// delegate callback and settles on completion, so the system
    /// completion handler runs exactly once, on the main thread, after the
    /// whole wake's work has drained.
    private var settlement: BackgroundDownloadEventSettlement {
        JobDownloadBackgroundEvents.shared.settlement
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(
        database: DatabaseManager,
        reattacher: WorkspaceRootReattacher? = nil,
        onTerminal: @escaping @Sendable (BackgroundJob) async -> Void
    ) {
        self.database = database
        self.reattacher = reattacher
        self.onTerminal = onTerminal
        super.init()
        _ = session
    }

    // MARK: - Ownership handoff from BackgroundJobService

    /// Whether a background URLSession task still exists for this job.
    /// Launch reconciliation must not interrupt a job whose task is alive.
    nonisolated func hasLiveTask(jobID: UUID) async -> Bool {
        let session = await MainActor.run { self.session }
        let tasks = await session.allTasks
        return tasks.contains { $0.taskDescription == jobID.uuidString }
    }

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
        bumpGeneration(job.id)
        let task = session.downloadTask(with: url)
        task.taskDescription = job.id.uuidString
        task.priority = URLSessionTask.highPriority
        task.resume()
        return true
    }

    func cancel(jobID: UUID) async {
        // Take ownership of the cancel first: bumping the generation and
        // cancelling the coordinator-owned delayed retry makes every sleeping
        // retry path fail its re-check, so a cancelled job can never get a
        // late `.resume()` (the historical bug re-checked the job BEFORE the
        // sleep but not after). Any in-flight settle rechecks the same facts
        // and cleans the owned staging itself.
        bumpGeneration(jobID)
        let retry: Task<Void, Never>? = stateLock.withLock {
            pendingRetryTasks.removeValue(forKey: jobID)
        }
        retry?.cancel()
        let tasks = await session.allTasks
        for task in tasks where task.taskDescription == jobID.uuidString {
            task.cancel()
        }
    }

    private func bumpGeneration(_ jobID: UUID) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = (jobGenerations[jobID] ?? 0) &+ 1
        jobGenerations[jobID] = next
        return next
    }

    private func currentGeneration(_ jobID: UUID) -> UInt64 {
        stateLock.withLock { jobGenerations[jobID] ?? 0 }
    }

    /// The delayed-retry re-check contract: resume only while the job is
    /// still the durable running owner, the ownership generation is
    /// unchanged, and nobody cancelled the owned retry task.
    nonisolated static func shouldResumeAfterRetryDelay(
        jobState: BackgroundJobState?,
        generationAtScheduling: UInt64,
        generationNow: UInt64,
        retryTaskCancelled: Bool
    ) -> Bool {
        jobState == .running
            && generationAtScheduling == generationNow
            && !retryTaskCancelled
    }

    /// One durable-settle ownership rule, applied at EVERY await boundary of
    /// a settle (entry, and again immediately before the completion write):
    /// the task may transition the durable row only while its generation
    /// still owns the job AND the row is actually running. A cancelled or
    /// superseded settle instead removes its owned staging (the historical
    /// bug: cancelled settles returned here leaving the full payload behind)
    /// and never announces anything.
    nonisolated static func ownsDurableSettle(
        generationMatches: Bool,
        jobState: BackgroundJobState?
    ) -> Bool {
        generationMatches && jobState == .running
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
        // Register the async follow-up SYNCHRONOUSLY inside this delegate
        // callback: `urlSessionDidFinishEvents` for this wake can arrive the
        // moment the callback returns, and the system completion must then
        // wait for the settle to drain instead of killing the process under
        // it. The temporary file is removed when this callback returns, so
        // stage it into app-owned storage synchronously and finish
        // asynchronously.
        settlement.beginEvent()
        let generation = currentGeneration(jobID)
        let stagingDirectory: URL
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            stagingDirectory = support.appendingPathComponent("FloeAgent/JobDownloads/\(jobID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            Task {
                await self.fail(jobID: jobID, message: error.localizedDescription)
                self.settlement.endEvent()
            }
            return
        }
        let staging = stagingDirectory.appendingPathComponent("payload.bin")
        do {
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task {
                await self.fail(jobID: jobID, message: error.localizedDescription)
                self.settlement.endEvent()
            }
            return
        }
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let contentType = downloadTask.response?.mimeType ?? "application/octet-stream"
        Task {
            await self.settle(
                jobID: jobID, staging: staging, stagingDirectory: stagingDirectory,
                generationAtStart: generation, statusCode: statusCode, contentType: contentType
            )
            self.settlement.endEvent()
        }
    }

    private func settle(
        jobID: UUID,
        staging: URL,
        stagingDirectory: URL,
        generationAtStart: UInt64,
        statusCode: Int,
        contentType: String
    ) async {
        let store = BackgroundJobStore(database: database)
        do {
            // Ownership is decided by ONE rule at every await boundary: the
            // generation this settle started under must still own the row
            // AND the row must actually be running. A cancelled or
            // superseded job must not settle into a terminal state, and its
            // staged payload is coordinator-owned garbage: remove the
            // staging directory (the historical bug left it behind forever
            // on exactly this path).
            let storedJob = try await store.job(id: jobID)
            guard Self.ownsDurableSettle(
                generationMatches: generationAtStart == currentGeneration(jobID),
                jobState: storedJob?.state
            ) else {
                removeOwnedStaging(stagingDirectory)
                clearBookkeeping(for: jobID)
                return
            }
            guard let job = storedJob, job.state == .running else {
                removeOwnedStaging(stagingDirectory)
                clearBookkeeping(for: jobID)
                return
            }
            let args = try JSONDecoder().decode(URLDownloadTool.Arguments.self, from: job.payloadJSON)
            let cap = args.maxBytes ?? Self.defaultMaxBytes
            let byteCount = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard byteCount <= cap else {
                removeOwnedStaging(stagingDirectory)
                _ = try? await store.transition(id: jobID, to: .failed) {
                    $0.lastError = "Download exceeded the \(cap)-byte job cap"
                }
                await self.notifyTerminal(jobID: jobID)
                return
            }

            guard (200..<300).contains(statusCode) else {
                removeOwnedStaging(stagingDirectory)
                _ = try? await store.transition(id: jobID, to: .failed) {
                    $0.lastError = "Download failed with HTTP \(statusCode)"
                }
                await self.notifyTerminal(jobID: jobID)
                return
            }

            var destination: URL?
            var workspaceRelative: String?
            var fallbackNote: String?
            var leaseRelease: (@Sendable () -> Void)?
            var rootURL: URL?
            if let reattacher {
                let lease = await reattacher.acquireRoot(conversationID: job.conversationID)
                rootURL = lease?.url
                leaseRelease = lease?.release
            }
            if rootURL == nil, let rootPath = job.workspaceRootPath {
                rootURL = URL(fileURLWithPath: rootPath)
            }
            defer { leaseRelease?() }
            if let rootURL {
                let rootPath = rootURL.path
                var isDirectory: ObjCBool = false
                let rootReachable = FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                if rootReachable,
                   let guarder = try? WorkspacePathGuard(rootURL: rootURL),
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
                        removeOwnedStaging(stagingDirectory)
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

            let digest = (try? FloeDigest.sha256Hex(ofFileAt: destination)) ?? ""
            var summaryText = "status=ok path=\(workspaceRelative ?? destination.path) statusCode=\(statusCode) contentType=\(contentType) bytes=\(byteCount) sha256=\(digest)"
            if let fallbackNote { summaryText += "\nnote=\(fallbackNote)" }
            let finalSummary = summaryText
            let finalPath = workspaceRelative ?? destination.path
            // Final ownership re-check with the SAME rule as entry: a
            // cancel that landed while the file was being committed must not
            // announce a completed job. The committed artifact stays (it is
            // user-visible work or the app-owned fallback, not staging);
            // only a workspace-committed job's leftover staging directory is
            // cleaned — a fallback artifact physically lives inside it.
            let stillOwns = Self.ownsDurableSettle(
                generationMatches: generationAtStart == currentGeneration(jobID),
                jobState: (try? await store.job(id: jobID))?.state
            )
            guard stillOwns else {
                if workspaceRelative != nil { removeOwnedStaging(stagingDirectory) }
                clearBookkeeping(for: jobID)
                return
            }
            // A durable DB failure is NOT readiness: the throw must not be
            // swallowed into a completed notification. The committed file is
            // preserved and the job honestly stays non-terminal until a
            // later pass/reconciliation settles it.
            do {
                _ = try await store.transition(id: jobID, to: .completed) {
                    $0.resultSummary = finalSummary
                    $0.resultDigest = digest
                    $0.resultPath = finalPath
                }
            } catch {
                FloeLogger(category: .persistence).warning(
                    "jobDownloadCompleteTransitionFailed job=\(jobID.uuidString) (DB failure is not readiness; artifact preserved)"
                )
                return
            }
            if workspaceRelative != nil { removeOwnedStaging(stagingDirectory) }
            await self.notifyTerminal(jobID: jobID)
        } catch {
            // Reached only BEFORE any destination was committed: the staging
            // directory is pure owned garbage here, safe to remove.
            removeOwnedStaging(stagingDirectory)
            await fail(jobID: jobID, message: error.localizedDescription)
        }
    }

    private func stagingDirectoryURL(_ jobID: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("FloeAgent/JobDownloads/\(jobID.uuidString)", isDirectory: true)
    }

    /// Removes the coordinator-OWNED staging directory. The staged payload is
    // only garbage once the job settled; leaving it behind (the historical
    // leak: cancelled settles and cap/HTTP failures removed only the file,
    // never the directory) accumulates full download copies forever.
    private func removeOwnedStaging(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
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

        // Register this wake's follow-up work synchronously, before the
        // system can report finish events.
        settlement.beginEvent()
        stateLock.lock()
        let attempts = (resumeAttempts[jobID] ?? 0) + 1
        resumeAttempts[jobID] = attempts
        stateLock.unlock()
        let resumeData = error.userInfo["NSURLSessionDownloadTaskResumeDataKey"] as? Data
        if let resumeData, attempts <= Self.maxAutoResumeAttempts {
            // Transparent resume: the job stays running; the model never sees
            // the transient network interruption. The event stays registered
            // for the whole delay so the system completion cannot fire while
            // the retry decision is still pending.
            let generationAtScheduling = currentGeneration(jobID)
            let retry: Task<Void, Never> = Task {
                let store = BackgroundJobStore(database: self.database)
                guard (try? await store.job(id: jobID))?.state == .running else {
                    self.settlement.endEvent()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(min(30, attempts * 5)) * 1_000_000_000)
                // The fix for the historical bug: the job and the ownership
                // generation are re-checked AFTER the sleep and immediately
                // before `.resume()`, and `cancel` cancelled this owned task
                // anyway, so a cancelled or superseded job can never be
                // silently re-started by a stale timer.
                let stateAfterSleep: BackgroundJobState?
                if Task.isCancelled {
                    stateAfterSleep = nil
                } else {
                    stateAfterSleep = (try? await store.job(id: jobID))?.state
                }
                guard Self.shouldResumeAfterRetryDelay(
                    jobState: stateAfterSleep,
                    generationAtScheduling: generationAtScheduling,
                    generationNow: self.currentGeneration(jobID),
                    retryTaskCancelled: Task.isCancelled
                ) else {
                    self.clearBookkeeping(for: jobID)
                    self.settlement.endEvent()
                    return
                }
                let resumed = self.session.downloadTask(withResumeData: resumeData)
                resumed.taskDescription = jobID.uuidString
                resumed.priority = URLSessionTask.highPriority
                resumed.resume()
                // The resumed task produces its own delegate events on the
                // next callback; this registered event is settled.
                self.settlement.endEvent()
            }
            stateLock.lock()
            pendingRetryTasks[jobID] = retry
            stateLock.unlock()
            // The task clears its own entry when it ends.
            Task { await retry.value; self.clearRetryEntry(jobID: jobID, task: retry) }
            return
        }
        Task {
            defer { self.settlement.endEvent() }
            let store = BackgroundJobStore(database: database)
            _ = try? await store.transition(id: jobID, to: .failed) {
                $0.lastError = error.localizedDescription
                $0.retryCount += attempts
            }
            await self.notifyTerminal(jobID: jobID)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Mark the system side complete ONLY. The stored completion fires
        // after every registered settle/retry event has also drained — this
        // was the finish-before-settle bug.
        settlement.sessionDidFinishEvents()
    }

    // MARK: - Helpers

    private func clearRetryEntry(jobID: UUID, task: Task<Void, Never>) {
        stateLock.lock()
        // Remove only this ending task's own entry: a newer retry (or a
        // cancel that already removed it) must not be overwritten.
        if pendingRetryTasks[jobID] == task {
            pendingRetryTasks[jobID] = nil
        }
        stateLock.unlock()
    }

    /// Synchronous lock wrapper so async callers never touch NSLock directly.
    private func clearBookkeeping(for jobID: UUID) {
        stateLock.lock()
        progressState[jobID] = nil
        resumeAttempts[jobID] = nil
        jobGenerations[jobID] = nil
        stateLock.unlock()
    }

    private func notifyTerminal(jobID: UUID) async {
        clearBookkeeping(for: jobID)
        let store = BackgroundJobStore(database: database)
        if let job = try? await store.job(id: jobID) {
            await onTerminal(job)
        }
    }
}
#endif

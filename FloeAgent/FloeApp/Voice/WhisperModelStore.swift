// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit

import FloeCore
import FloeLocalModelCatalog
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
            case .unavailable: FloeL10n.l("voice.whisper_model_store.the_whisper_model_is_not_installed")
            case .corrupt: FloeL10n.l("voice.whisper_model_store.the_whisper_resources_are_incomplete_or")
            case .busy: FloeL10n.l("voice.whisper_model_store.speech_recognition_is_using_the_model")
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
    /// Warm-residency handshake. The recognition runtime registers a releaser
    /// that unmounts an IDLE warm model and returns its file lease before the
    /// files are replaced or removed. Without it a warm lease would keep the
    /// model permanently `busy`; a live recognition session still reports
    /// busy exactly as before.
    private var releaseResident: (@Sendable () async -> Bool)?
    func setResidentReleaser(_ releaser: @escaping @Sendable () async -> Bool) {
        releaseResident = releaser
    }
    private func retireResident() async -> Bool {
        guard let releaseResident else { return true }
        return await releaseResident()
    }
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
    /// Identity of the installed model ("<manifest id>-<revision>"), `nil`
    /// when nothing is installed. Cheap: bundled manifest + install marker,
    /// no byte verification (the acquire path owns that).
    func installedIdentity() -> String? {
        guard let value = try? manifest(), let folder = try? location(value),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("installed.json").path) else { return nil }
        return folder.lastPathComponent
    }
    func isInstalled() -> Bool { installedIdentity() != nil }
    /// Acquires an exclusive directory lease. `resident` must be `true` ONLY
    /// from the recognition runtime's own cold mount: the resident never
    /// retires itself (that would wait on the load calling this method —
    /// a Store↔Runtime self-wait). External callers keep the pack-management
    /// behavior and retire an idle warm model first.
    func acquire(resident: Bool = false) async throws -> (UUID, URL) {
        guard !installing else { throw Failure.unavailable }
        switch SpeechModelLeaseArbitration.decision(for: resident ? .resident : .external,
                                                   heldLeases: leases.count) {
        case .proceed:
            break
        case .unavailable:
            // A lease is already held (file/caption transcription or another
            // exclusive user): fail fast, never call the retirement hook.
            throw Failure.unavailable
        case .retireResident:
            // Another owner needs the model directory exclusively. Retire the
            // IDLE warm recognition model first — it reloads on the next
            // dictation. A live recognition session answers `false` and keeps
            // today's single-user busy behavior for this caller.
            guard await retireResident() else { throw Failure.unavailable }
        }
        // Revalidate after the retirement await: an install/remove may have
        // started in the meantime.
        guard !installing, leases.isEmpty, isInstalled() else { throw Failure.unavailable }
        let value = try manifest(), folder = try location(value)
        for asset in value.files { try verify(folder.appendingPathComponent(asset.path), asset: asset) }
        let lease = UUID(); leases.insert(lease)
        return (lease, folder)
    }
    func release(_ lease: UUID) { leases.remove(lease) }
    func remove() async throws {
        guard !installing else { throw Failure.busy }
        // Maintenance gate: while the resident is retired and the files are
        // deleted/verified, a new acquisition must fail fast instead of
        // racing the deletion (the residency window closes before these file
        // operations finish).
        installing = true; defer { installing = false }
        // Retire an idle warm model first: residency must never keep deletion
        // permanently busy. A live session still answers `false` → busy.
        guard await retireResident() else { throw Failure.busy }
        guard leases.isEmpty else { throw Failure.busy }
        let folder = try location(manifest())
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func install(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !installing else { throw Failure.busy }
        installing = true; defer { installing = false }
        // Replacement happens in place: the mounted model and its file lease
        // must be gone before staging swaps the directory.
        guard await retireResident() else { throw Failure.busy }
        guard leases.isEmpty else { throw Failure.busy }
        // Owned settle work for this whole installation: every delegate-
        // callback resume of a waiter this install registers begins its
        // event in this ledger. Verified components checkpoint after their
        // durable staging move, before the next network wait. The final
        // component remains held through installed.json and the directory
        // swap; errors drain only after the operation unwinds. Each store
        // owns its own ledger even though speech shares one URLSession.
        let ledger = ModelDownloadSettlementLedger()
        defer { ledger.drain() }
        let manifest = try manifest(), base = try root(), destination = try location(manifest)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let staging = base.appendingPathComponent(".download-\(manifest.id)-\(manifest.sourceRevision)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
        if let free = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < total * 2 { throw CocoaError(.fileWriteOutOfSpace) }
        var completed: Int64 = 0
        for (index, asset) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(asset.path)
            if (try? verify(target, asset: asset)) != nil {
                completed += asset.byteCount; progress(completed, total)
                continue
            }
            try? FileManager.default.removeItem(at: target)
            let completedBeforeAsset = completed
            let temporary = try await WhisperDownloadCoordinator.shared.download(asset.url, ledger: ledger) { bytes in
                progress(completedBeforeAsset + min(bytes, asset.byteCount), total)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try verify(temporary, asset: asset)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += asset.byteCount; progress(completed, total)
            if index < manifest.files.count - 1 { ledger.checkpoint() }
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
        /// The calling installation operation's ledger (`nil` = caller does
        /// not track the wake). Every acquired resume pairs a synchronous
        /// `began` here with that operation's single tail drain, so the
        /// background-session wake cannot release while the installer
        /// verifies/commits the transferred bytes.
        let ledger: ModelDownloadSettlementLedger?
        var cancelled = false
    }
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private static let retiredTransfersKey = "speech.transfers.retired.v1"
    private var retiredTransfers = Set<String>()
    /// Service-owned drain for this background session. The stored system
    /// completion fires exactly once on main after the tracked launch
    /// bootstrap AND every registered settle event of the wake have drained —
    /// the previous path released OS completion while the installation's
    /// verification/state-commit work was still underway.
    let settlement = FloeCore.BackgroundDownloadEventSettlement(name: "whisper-model")
    private var session: URLSession!
    private override init() {
        super.init()
        retiredTransfers = Set(UserDefaults.standard.stringArray(forKey: Self.retiredTransfersKey) ?? [])
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
    /// Stores the system completion for this background session's wake.
    /// Every bootstrap is registered as pending BEFORE the handler is
    /// stored: `registerSystemCompletionHandler` can fire an already
    /// drained + finished wake immediately, and the bounded readiness work
    /// is exactly what such a wake must drain first. Whisper's own
    /// requested-install owner restoration is always tracked; the optional
    /// `bootstrap:` closure adds the caller's bounded wake-readiness scan
    /// as a second parallel tracked lease (each begins synchronously and
    /// ends exactly once). Neither may wait on the whole agent, inference,
    /// model loading or a user wait. One-argument call sites are unchanged.
    func registerBackgroundCompletion(
        _ completion: @escaping () -> Void,
        bootstrap: (@Sendable () async -> Void)? = nil
    ) {
        settlement.trackBootstrap {
            // Restore only an explicitly requested download. Starting the
            // owner is bounded; verification/commit callbacks hold their own
            // settle leases. Never await all future network components here.
            await WhisperModelStore.shared.restoreInstallation()
        }
        if let bootstrap {
            settlement.trackBootstrap(bootstrap)
        }
        settlement.registerSystemCompletionHandler(completion)
    }

    /// Persist the fence before cancelling the background transfer: delegate
    /// callbacks can arrive after cancellation, including after process restore.
    /// Only this URL's transfer is retired; ASR and other pack downloads survive.
    func cancelAndRemovePendingTransfer(for url: URL) async {
        let key = Self.transferKey(url)
        let waiter = lock.withLock {
            retiredTransfers.insert(key)
            UserDefaults.standard.set(retiredTransfers.sorted(), forKey: Self.retiredTransfersKey)
            return pending.removeValue(forKey: key)
        }
        if let waiter {
            // The installer unwinds asynchronously from this resume; register
            // the settle event synchronously so the wake waits for that
            // durable cleanup like any other acquired waiter.
            waiter.ledger?.began(settlement)
            waiter.continuation.resume(throwing: CancellationError())
        }
        let tasks = await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in continuation.resume(returning: tasks) }
        }
        for task in tasks where task.taskDescription == key || task.originalRequest?.url == url {
            if let download = task as? URLSessionDownloadTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    download.cancel { _ in continuation.resume() }
                }
            } else { task.cancel() }
        }
        // The model store verifies removal and keeps cleanup pending on error.
        // Late callbacks cannot recreate either file because of the fence above.
        for suffix in [".download", ".resume"] {
            if let artifact = try? file(key, suffix: suffix) { try? FileManager.default.removeItem(at: artifact) }
        }
    }

    private static func transferKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `ledger` is owned by the CALLING installation operation: installers
    /// that pass one have their waiter resumes accounted as settle events
    /// drained at that operation's durable-commit tail. Callers that pass
    /// `nil` (e.g. other pack stores riding the same session) keep exactly
    /// the previous behavior and can never strand or extend another
    /// operation's wake.
    func download(_ url: URL, ledger: ModelDownloadSettlementLedger? = nil, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let key = Self.transferKey(url)
        guard !lock.withLock({ retiredTransfers.contains(key) }) else { throw CancellationError() }
        let destination = try file(key, suffix: ".download")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let registered = lock.withLock {
                    guard !retiredTransfers.contains(key) else { return false }
                    pending[key] = Pending(id: id, continuation: continuation, progress: progress, ledger: ledger)
                    return true
                }
                guard registered else { continuation.resume(throwing: CancellationError()); return }
                if Task.isCancelled {
                    if let waiter = lock.withLock({ pending.removeValue(forKey: key) }) {
                        waiter.ledger?.began(settlement)
                        waiter.continuation.resume(throwing: CancellationError())
                    }
                    return
                }
                session.getAllTasks { [self] tasks in
                    lock.withLock {
                        guard !retiredTransfers.contains(key), let waiter = pending[key], waiter.id == id, !waiter.cancelled else { return }
                        // A completion may have arrived between the disk check
                        // and listener registration on process restoration.
                        if FileManager.default.fileExists(atPath: destination.path) {
                            if let waiter = pending.removeValue(forKey: key) {
                                // The restored finished file still has to be
                                // verified/moved by the awaiting installer;
                                // register the settle synchronously here.
                                waiter.ledger?.began(settlement)
                                waiter.continuation.resume(returning: destination)
                            }
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
                    if let waiter = self.lock.withLock({ self.pending.removeValue(forKey: key) }) {
                        waiter.ledger?.began(self.settlement)
                        waiter.continuation.resume(throwing: CancellationError())
                    }
                }
                for task in matches {
                    task.cancel { data in
                        self.lock.withLock {
                            guard !self.retiredTransfers.contains(key) else { return }
                            if let data, let target = try? self.file(key, suffix: ".resume") { try? data.write(to: target, options: .atomic) }
                        }
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
            let (waiter, target) = try lock.withLock {
                guard !retiredTransfers.contains(key) else { throw CancellationError() }
                guard let response = downloadTask.response as? HTTPURLResponse, (response.statusCode == 200 || response.statusCode == 206) else { throw WhisperModelStore.Failure.corrupt }
                let target = try file(key, suffix: ".download")
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: location, to: target)
                if let resume = try? file(key, suffix: ".resume") { try? FileManager.default.removeItem(at: resume) }
                return (pending.removeValue(forKey: key), target)
            }
            if let waiter {
                // The durable staged bytes moved inside the lock above; the
                // awaiting installer now verifies and commits them. Register
                // the settle synchronously inside this callback — the finish
                // event can arrive the moment the callback returns — and let
                // the operation tail end it exactly once.
                waiter.ledger?.began(settlement)
                waiter.continuation.resume(returning: target)
            }
        } catch {
            if let failed = lock.withLock({ pending.removeValue(forKey: key) }) {
                failed.ledger?.began(settlement)
                failed.continuation.resume(throwing: error)
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error else { return }
        let waiter = lock.withLock {
            if !retiredTransfers.contains(key),
               let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let target = try? file(key, suffix: ".resume") { try? data.write(to: target, options: .atomic) }
            return pending.removeValue(forKey: key)
        }
        if let waiter {
            // Failed/cancelled transfers settle the same way: the awaiting
            // installer unwinds asynchronously and its own error/cancel
            // cleanup is covered by this event, ended once at the tail.
            waiter.ledger?.began(settlement)
            waiter.continuation.resume(throwing: waiter.cancelled ? CancellationError() : error)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // System side done only. The stored completion fires after the
        // tracked launch bootstrap AND every registered settle event of
        // this wake have drained — finish-before-settle was the historical
        // premature-OS-completion bug.
        settlement.sessionDidFinishEvents()
    }
}
#endif

import Foundation
import os

// MARK: - Out-of-process transfer
//
// An in-process `URLSession` stops when the process does. On a platform that
// suspends an application the moment it leaves the screen, a multi-hundred
// megabyte model transfer therefore freezes wherever it stood: the sockets go
// down, the retry ladder's timers do not run, and nothing moves again until the
// process is frontmost. A background session hands the transfer to the system
// instead, which keeps it running while the process is suspended and relaunches
// the process to deliver the result.
//
// It is opt-in, and stays that way, because it is not free. A background
// session accepts only download tasks, so a range arrives as a file rather than
// as bytes in memory; the system decides when the work runs; and the process
// that receives a completion may be a fresh launch that never asked for the
// download. Callers that are never suspended — a command-line tool, a desktop
// process — gain nothing from any of that and keep the in-process path.

/// Opt in to system-scheduled transfers that survive process suspension.
public struct BackgroundTransferConfiguration: Sendable {
    /// Identifies the session across launches.
    ///
    /// Reusing one identifier is what lets a new process adopt transfers an
    /// earlier one started. Two live sessions may not share it.
    public var sessionIdentifier: String

    /// App-group container holding the session's own bookkeeping, required
    /// when a transfer has to be visible to an extension as well.
    public var sharedContainerIdentifier: String?

    /// Let the system choose when to transfer, waiting for conditions it
    /// prefers. Off by default: a model download blocks the feature that
    /// needs it, so "later, when charging" is the wrong answer. The system
    /// makes a session discretionary regardless when it is created while the
    /// application is already in the background.
    public var isDiscretionary: Bool

    public var allowsCellularAccess: Bool

    /// Total time the system allows one transfer before failing it.
    ///
    /// This stands in for the in-process stall guard, which cannot work here:
    /// that clock keeps running while the process is suspended, so a transfer
    /// the system was performing correctly the whole time would look stalled
    /// the moment the process came back. The system owns the transfer, so the
    /// system owns its deadline. Generous by default, because a large bundle
    /// on a slow link legitimately takes hours and cancelling one that is
    /// progressing throws away everything it has not yet committed.
    public var resourceTimeout: TimeInterval

    public init(
        sessionIdentifier: String,
        sharedContainerIdentifier: String? = nil,
        isDiscretionary: Bool = false,
        allowsCellularAccess: Bool = true,
        resourceTimeout: TimeInterval = 24 * 60 * 60
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.sharedContainerIdentifier = sharedContainerIdentifier
        self.isDiscretionary = isDiscretionary
        self.allowsCellularAccess = allowsCellularAccess
        self.resourceTimeout = resourceTimeout
    }
}

/// What one background task is fetching, carried in its `taskDescription`.
///
/// The description is the only state that survives process death alongside the
/// task itself, so it has to say everything needed to file the bytes: a
/// relaunched process is handed tasks it has no memory of starting.
struct BackgroundTransferItem: Codable, Sendable, Equatable {
    /// `modelId/path`, for diagnostics only.
    let label: String
    /// Staging file for a chunk, final path for a whole file.
    let destination: String
    /// Chunk bookkeeping. Absent for a whole-file transfer.
    let sidecar: String?
    let expectedSize: Int64
    let chunkCount: Int
    /// Absent for a whole-file transfer.
    let chunkIndex: Int?
    let rangeStart: Int64?
    let rangeEnd: Int64?

    /// Bytes this task is expected to deliver.
    var length: Int64 {
        guard let rangeStart, let rangeEnd else { return expectedSize }
        return rangeEnd - rangeStart + 1
    }

    /// Transfers are grouped by what they are assembling, so a completion can
    /// find the writer and the waiting caller without a task identifier —
    /// which is not stable across launches.
    var groupKey: String { destination }

    /// Position inside its group. A whole file is a group of one.
    var slot: Int { chunkIndex ?? 0 }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(from description: String?) -> BackgroundTransferItem? {
        guard let description, let data = description.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BackgroundTransferItem.self, from: data)
    }
}

/// Decides who owns the system transfer when one in-process waiter ends.
///
/// Cancelling an async caller must only detach that caller. The background
/// session is deliberately longer-lived than any one task, and a replacement
/// caller (or a relaunched process) can adopt its download. A transport failure
/// is different: its sibling requests belong to the same failed assembly and
/// must be torn down before the retry ladder starts another pass.
enum BackgroundTransferEndSource {
    case callerCancellation
    case transportFailure

    var cancelsSystemTransfer: Bool {
        self == .transportFailure
    }
}

enum BackgroundTransferAdoption {
    static func remainingSlots(
        requested: Set<Int>,
        completed: Set<Int>
    ) -> Set<Int> {
        requested.subtracting(completed)
    }
}

enum BackgroundTransferWaiterOwnership {
    static func mayFinish(current: UUID, requested: UUID?) -> Bool {
        requested == nil || current == requested
    }
}

/// Runs transfers on a background `URLSession` and files the results.
///
/// One coordinator per session identifier, kept for the life of the process:
/// the session must not be recreated while it exists, and its delegate has to
/// be there whenever the system decides to deliver something.
final class BackgroundTransferCoordinator: NSObject, @unchecked Sendable {

    private struct Group {
        let label: String
        var outstanding: Set<Int>
        var waiterID: UUID
        var continuation: CheckedContinuation<Void, Error>?
        var finished = false
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: BackgroundTransferCoordinator] = [:]

    static func coordinator(
        for configuration: BackgroundTransferConfiguration
    ) -> BackgroundTransferCoordinator {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[configuration.sessionIdentifier] {
            return existing
        }
        let created = BackgroundTransferCoordinator(configuration: configuration)
        registry[configuration.sessionIdentifier] = created
        return created
    }

    /// The coordinator owning `identifier`, if this process has built one.
    static func existingCoordinator(for identifier: String) -> BackgroundTransferCoordinator? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[identifier]
    }

    private let configuration: BackgroundTransferConfiguration
    private let lock = NSLock()
    private var groups: [String: Group] = [:]
    private var writers: [String: ChunkedFileWriter] = [:]
    private var progress: [String: RangedDownloadProgress] = [:]
    private var sessionFinishedHandlers: [@Sendable () -> Void] = []

    /// Built in `init` rather than lazily, and assigned exactly once before
    /// the coordinator is published: two sessions may not share one
    /// identifier, and a `lazy var` reached from two threads builds two.
    private var session: URLSession!

    private init(configuration: BackgroundTransferConfiguration) {
        self.configuration = configuration
        super.init()
        let sessionConfiguration = URLSessionConfiguration.background(
            withIdentifier: configuration.sessionIdentifier)
        sessionConfiguration.sharedContainerIdentifier = configuration.sharedContainerIdentifier
        sessionConfiguration.isDiscretionary = configuration.isDiscretionary
        sessionConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.httpMaximumConnectionsPerHost = max(
            HuggingFaceDownloader.downloadRangeConcurrency, 1)
        sessionConfiguration.sessionSendsLaunchEvents = true
        session = URLSession(
            configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
    }

    /// Hand back the completion handler the system supplies when it relaunches
    /// the process to deliver finished transfers.
    func addSessionFinishedHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        sessionFinishedHandlers.append(handler)
        lock.unlock()
    }

    // MARK: - Transfers

    /// Fetch `chunks` of one file, resuming whatever a previous process left
    /// running or already wrote.
    func download(
        chunks: [DownloadChunk],
        from url: URL,
        label: String,
        writer: ChunkedFileWriter,
        staging: URL,
        sidecar: URL,
        expectedSize: Int64,
        chunkCount: Int,
        progress: RangedDownloadProgress
    ) async throws {
        guard !chunks.isEmpty else { return }
        let key = staging.path
        let inFlight = await slotsInFlight(forGroup: key)
        register(writer: writer, progress: progress, forGroup: key)

        // A task adopted from an earlier process can finish between the
        // `allTasks` snapshot above and installing this process's writer. Its
        // delegate stores that range beside the staging file because there was
        // no writer yet. Reconcile once more after registration so the new
        // waiter cannot count an already-landed range forever.
        BackgroundTransferCoordinator.spliceHeldChunks(
            staging: staging, chunks: chunks, writer: writer)
        let completed = writer.completedChunkIndices()

        let toStart = chunks.filter {
            !inFlight.contains($0.index) && !completed.contains($0.index)
        }
        let items = toStart.map { chunk in
            BackgroundTransferItem(
                label: label,
                destination: staging.path,
                sidecar: sidecar.path,
                expectedSize: expectedSize,
                chunkCount: chunkCount,
                chunkIndex: chunk.index,
                rangeStart: chunk.start,
                rangeEnd: chunk.end)
        }

        try await run(
            group: key,
            label: label,
            outstanding: Set(chunks.map(\.index)),
            starting: items,
            from: url,
            completedSlots: { writer.completedChunkIndices() })
    }

    /// Fetch one whole file, small enough not to be worth ranging.
    func download(
        wholeFile file: RepoFile,
        from url: URL,
        label: String,
        to destination: URL
    ) async throws {
        let key = destination.path
        let inFlight = await slotsInFlight(forGroup: key)
        let items: [BackgroundTransferItem] = inFlight.contains(0)
            ? []
            : [BackgroundTransferItem(
                label: label,
                destination: destination.path,
                sidecar: nil,
                expectedSize: file.size,
                chunkCount: 1,
                chunkIndex: nil,
                rangeStart: nil,
                rangeEnd: nil)]

        try await run(
            group: key,
            label: label,
            outstanding: [0],
            starting: items,
            from: url,
            completedSlots: {
                HuggingFaceDownloader.localFileSize(destination) == file.size
                    ? [0]
                    : []
            })
    }

    private func register(
        writer: ChunkedFileWriter,
        progress: RangedDownloadProgress,
        forGroup key: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        writers[key] = writer
        self.progress[key] = progress
    }

    private func run(
        group key: String,
        label: String,
        outstanding: Set<Int>,
        starting items: [BackgroundTransferItem],
        from url: URL,
        completedSlots: () -> Set<Int>
    ) async throws {
        let describedItems = items.compactMap { item in
            item.encoded().map { (item, $0) }
        }
        guard describedItems.count == items.count else {
            throw DownloadError.failedToDownload("\(label): could not describe a background transfer")
        }
        let waiterID = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation can arrive before the continuation exists, and
                // the handler below would then have nothing to resume.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                lock.lock()
                // A delegate can land an adopted task before this waiter is
                // registered. Read the disk-backed completion state while
                // holding the same lock used by `complete`: either the range
                // is already excluded here, or the delegate observes the new
                // group and removes it afterward.
                let remaining = BackgroundTransferAdoption.remainingSlots(
                    requested: outstanding,
                    completed: completedSlots()
                )
                guard !remaining.isEmpty else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if var existing = groups[key] {
                    // Another caller in this process is already waiting on the
                    // same file. Two waiters need two continuations; the older
                    // one loses rather than being left unresumed.
                    existing.continuation?.resume(throwing: CancellationError())
                    existing.continuation = continuation
                    existing.outstanding = remaining
                    existing.waiterID = waiterID
                    existing.finished = false
                    groups[key] = existing
                } else {
                    groups[key] = Group(
                        label: label,
                        outstanding: remaining,
                        waiterID: waiterID,
                        continuation: continuation)
                }
                lock.unlock()
                for (item, description) in describedItems where remaining.contains(item.slot) {
                    var request = HuggingFaceDownloader.makeHubRequest(url: url)
                    if let start = item.rangeStart, let end = item.rangeEnd {
                        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    }
                    let task = session.downloadTask(with: request)
                    task.taskDescription = description
                    task.countOfBytesClientExpectsToSend = 0
                    task.countOfBytesClientExpectsToReceive = item.length
                    task.resume()
                }
            }
        } onCancel: {
            finish(group: key, ownedBy: waiterID, with: CancellationError())
        }
    }

    private func slotsInFlight(forGroup key: String) async -> Set<Int> {
        let tasks = await session.allTasks
        var slots: Set<Int> = []
        for task in tasks {
            guard task.state == .running || task.state == .suspended,
                  let item = BackgroundTransferItem.decoded(from: task.taskDescription),
                  item.groupKey == key
            else { continue }
            slots.insert(item.slot)
        }
        return slots
    }

    private func cancelTasks(inGroup key: String) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard let item = BackgroundTransferItem.decoded(from: task.taskDescription),
                      item.groupKey == key
                else { continue }
                task.cancel()
            }
        }
    }

    private func end(
        group key: String,
        with error: Error,
        source: BackgroundTransferEndSource
    ) {
        finish(group: key, with: error)
        if source.cancelsSystemTransfer {
            cancelTasks(inGroup: key)
        }
    }

    private func finish(
        group key: String,
        ownedBy waiterID: UUID? = nil,
        with error: Error?
    ) {
        lock.lock()
        guard let group = groups[key],
              !group.finished,
              BackgroundTransferWaiterOwnership.mayFinish(
                  current: group.waiterID,
                  requested: waiterID
              ) else {
            lock.unlock()
            return
        }
        let continuation = group.continuation
        groups.removeValue(forKey: key)
        writers.removeValue(forKey: key)
        progress.removeValue(forKey: key)
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    /// Records a landed slot and answers whether the group is complete.
    private func complete(slot: Int, inGroup key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var group = groups[key], !group.finished else { return false }
        group.outstanding.remove(slot)
        groups[key] = group
        return group.outstanding.isEmpty
    }
}

// MARK: - Delegate

extension BackgroundTransferCoordinator: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let item = BackgroundTransferItem.decoded(from: downloadTask.taskDescription) else {
            AudioLog.download.error("background transfer finished without a description")
            return
        }
        do {
            try accept(location: location, for: item, response: downloadTask.response)
        } catch {
            AudioLog.download.error(
                "\(item.label, privacy: .public): background transfer rejected: \(error.localizedDescription, privacy: .public)")
            end(group: item.groupKey, with: error, source: .transportFailure)
            return
        }
        reportLanded(item)
        if complete(slot: item.slot, inGroup: item.groupKey) {
            finish(group: item.groupKey, with: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let item = BackgroundTransferItem.decoded(from: downloadTask.taskDescription),
              item.chunkIndex != nil
        else { return }
        lock.lock()
        let state = progress[item.groupKey]
        lock.unlock()
        guard let state else { return }
        Task {
            await state.updateInFlightBytes(
                totalBytesWritten,
                forSlot: item.slot,
                expectedBytes: item.length
            )
        }
    }

    /// Replace the range's provisional live-byte count with its validated,
    /// durable length. The progress actor ignores any delayed delegate update
    /// for this slot after it lands.
    private func reportLanded(_ item: BackgroundTransferItem) {
        guard item.chunkIndex != nil else { return }
        lock.lock()
        let state = progress[item.groupKey]
        lock.unlock()
        guard let state else { return }
        let length = item.length
        Task { await state.addCompletedBytes(length, forSlot: item.slot) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let item = BackgroundTransferItem.decoded(from: task.taskDescription)
        else { return }
        // Usually cancellation is this coordinator tearing a failed group
        // down, after that group's real error was already delivered. A retry
        // can adopt one of those tasks before URLSession publishes its final
        // state, though. Finish that newer waiter instead of letting it wait
        // forever for a completion the cancelled task can never deliver.
        if (error as NSError).code == NSURLErrorCancelled {
            finish(group: item.groupKey, with: error)
            return
        }
        AudioLog.download.error(
            "\(item.label, privacy: .public): background transfer failed: \(error.localizedDescription, privacy: .public)")
        end(group: item.groupKey, with: error, source: .transportFailure)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handlers = sessionFinishedHandlers
        sessionFinishedHandlers.removeAll(keepingCapacity: false)
        lock.unlock()
        // The system expects to be answered on the main thread; the delegate
        // queue is not it.
        DispatchQueue.main.async { for handler in handlers { handler() } }
    }

    /// File the delivered bytes before returning: the system removes `location`
    /// as soon as this call ends.
    private func accept(
        location: URL,
        for item: BackgroundTransferItem,
        response: URLResponse?
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.failedToDownload("\(item.label): missing HTTP response")
        }
        let expectedStatus = item.chunkIndex == nil ? 200 : 206
        guard http.statusCode == expectedStatus else {
            throw DownloadError.failedToDownload(
                "\(item.label): expected HTTP \(expectedStatus), got \(http.statusCode)")
        }
        let delivered = HuggingFaceDownloader.localFileSize(location)
        guard delivered == item.length else {
            throw DownloadError.failedToDownload(
                "\(item.label): got \(delivered) bytes, expected \(item.length)")
        }

        guard let chunkIndex = item.chunkIndex, let start = item.rangeStart else {
            let destination = URL(fileURLWithPath: item.destination)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            return
        }

        lock.lock()
        let writer = writers[item.groupKey]
        lock.unlock()

        // A relaunched process is handed completions for transfers it never
        // started and has no writer for. Opening one here would race the
        // caller that is about to open its own, so the bytes are held beside
        // the staging file and spliced by whoever asks for this file next.
        guard let writer else {
            try holdForLaterSplice(location: location, item: item, chunkIndex: chunkIndex)

            // The adopter may have installed its writer after the lookup
            // above but before this range reached the held path. Recheck once
            // the bytes are durable. If the writer exists now, splice this
            // range immediately; otherwise the adopter's post-registration
            // sweep will find it. Either ordering closes the handoff gap.
            lock.lock()
            let adoptedWriter = writers[item.groupKey]
            lock.unlock()
            if let adoptedWriter {
                let chunk = DownloadChunk(
                    index: chunkIndex,
                    start: start,
                    end: start + item.length - 1
                )
                _ = BackgroundTransferCoordinator.spliceHeldChunk(
                    staging: URL(fileURLWithPath: item.destination),
                    chunk: chunk,
                    writer: adoptedWriter
                )
            }
            return
        }
        try writer.write(Data(contentsOf: location), at: start, chunkIndex: chunkIndex)
    }

    private func holdForLaterSplice(
        location: URL,
        item: BackgroundTransferItem,
        chunkIndex: Int
    ) throws {
        let held = BackgroundTransferCoordinator.heldChunkURL(
            staging: URL(fileURLWithPath: item.destination), chunkIndex: chunkIndex)
        try? FileManager.default.removeItem(at: held)
        try FileManager.default.moveItem(at: location, to: held)
    }

    /// Where a chunk waits when it lands in a process that is not assembling
    /// its file yet.
    static func heldChunkURL(staging: URL, chunkIndex: Int) -> URL {
        staging.appendingPathExtension("held-\(chunkIndex)")
    }

    /// Throw away ranges held for a staging file that no longer describes
    /// them — a reset staging file, or one already assembled and moved.
    static func discardHeldChunks(staging: URL, chunks: [DownloadChunk]) {
        for chunk in chunks {
            try? FileManager.default.removeItem(
                at: heldChunkURL(staging: staging, chunkIndex: chunk.index))
        }
    }

    /// Splice anything a previous launch left beside the staging file.
    ///
    /// Held chunks are as good as written — they were validated when they
    /// arrived — so this runs before deciding what still has to be fetched.
    static func spliceHeldChunks(
        staging: URL,
        chunks: [DownloadChunk],
        writer: ChunkedFileWriter
    ) {
        for chunk in chunks {
            _ = spliceHeldChunk(staging: staging, chunk: chunk, writer: writer)
        }
    }

    /// Splice one range that became durable while ownership moved from the
    /// system session to an in-process writer.
    @discardableResult
    static func spliceHeldChunk(
        staging: URL,
        chunk: DownloadChunk,
        writer: ChunkedFileWriter
    ) -> Bool {
        let fileManager = FileManager.default
        let held = heldChunkURL(staging: staging, chunkIndex: chunk.index)
        guard fileManager.fileExists(atPath: held.path),
              HuggingFaceDownloader.localFileSize(held) == chunk.length,
              let data = try? Data(contentsOf: held)
        else { return false }
        do {
            try writer.write(data, at: chunk.start, chunkIndex: chunk.index)
            try? fileManager.removeItem(at: held)
            return true
        } catch {
            AudioLog.download.error(
                "could not splice held chunk \(chunk.index): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

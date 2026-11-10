// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation
import CryptoKit
import Synchronization

/// Durable owned record for one remote Music.AI stem job. It carries provider
/// identity and ownership fences only; it is data, never authority. The App
/// revalidates document fences and provider authority around every use, and
/// only a receipt's own persisted remote ID may ever be polled, downloaded or
/// deleted.
public struct AudioStemCloudReceipt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// The remote create may not have reached the provider.
        case submitting
        /// The provider returned a job ID and it is durably recorded here.
        case created
        /// Waiting on the exact owned ID.
        case polling
        /// The owned job reached SUCCEEDED with two verified result URLs.
        case succeeded
        /// Both result files are downloaded, decoded, fitted and hashed.
        case downloaded
        /// The App's atomic document commit for these outputs succeeded.
        case committed
        /// The owned remote job was DELETEd by this service. No in-flight
        /// provider computation or billing is revoked by that claim.
        case released
        /// Terminal provider/local failure with no recoverable owned result.
        case failed
        /// Waiting stopped locally; the remote job may still exist and remain
        /// recoverable through its owned ID. Never re-created.
        case detached
    }
    public var remoteJobID: String
    public var workflow: String
    public var projectID: UUID
    public var clipID: UUID
    /// SHA-256 of the ORIGINAL source file the user authorized (not uploaded).
    public var sourceSHA256: String
    /// SHA-256 of the frozen excerpt actually uploaded to the provider.
    public var excerptSHA256: String
    /// The explicitly selected source interval the stems must cover.
    public var sourceSeconds: Double
    public var state: State
    public var createdAt: Date
    public var updatedAt: Date
    public var lastError: String?
    public init(remoteJobID: String, workflow: String, projectID: UUID, clipID: UUID,
        sourceSHA256: String, excerptSHA256: String, sourceSeconds: Double, state: State,
        createdAt: Date = Date(), updatedAt: Date = Date(), lastError: String? = nil) {
        self.remoteJobID = remoteJobID; self.workflow = workflow; self.projectID = projectID; self.clipID = clipID
        self.sourceSHA256 = sourceSHA256; self.excerptSHA256 = excerptSHA256; self.sourceSeconds = sourceSeconds
        self.state = state; self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastError = lastError
    }
    public var isTerminal: Bool {
        switch state { case .committed, .released, .failed: return true; default: return false }
    }
    public func validated() throws {
        guard !remoteJobID.isEmpty, remoteJobID.utf8.count <= 128,
              remoteJobID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }),
              !workflow.isEmpty, workflow.utf8.count <= 256,
              Self.isHash(sourceSHA256), Self.isHash(excerptSHA256),
              sourceSeconds.isFinite, sourceSeconds > 0, sourceSeconds <= 6 * 3600,
              lastError.map({ $0.utf8.count <= 2_048 }) ?? true else {
            throw AudioPCMProcessingError.invalidInput("stem cloud receipt is not a valid owned record")
        }
    }
    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

/// The existing App job storage supplies this seam. It persists receipts
/// atomically and answers ownership queries; it never schedules work, so no
/// parallel task registry is introduced. Polling stays owned by the caller's
/// existing session/service worker.
public protocol AudioStemCloudReceiptStore: Sendable {
    /// Awaited BEFORE any post-response cancellation check. Persistence
    /// failure must abort the operation honestly, never silently drop an
    /// owned remote ID.
    func save(_ receipt: AudioStemCloudReceipt) async throws
    /// The newest non-terminal receipt for this exact project+clip fence.
    func owned(projectID: UUID, clipID: UUID) async throws -> AudioStemCloudReceipt?
    /// Any non-terminal receipts for the project, for honest recovery UI.
    func outstanding(projectID: UUID) async throws -> [AudioStemCloudReceipt]
    /// The exact persisted record for one remote ID (any state).
    func load(remoteJobID: String) async throws -> AudioStemCloudReceipt?
}

/// Downloads one verified provider result to a bounded local file. The App
/// implements this with the existing reviewed HTTPRequestService download,
/// keeping its public-network and redirect revalidation intact.
public protocol AudioStemCloudDownloading: Sendable {
    func download(_ url: URL, to destination: URL, maxBytes: Int, work: AudioPCMWork) async throws
}

public struct AudioStemCloudStage: Sendable, Equatable {
    public enum Kind: String, Sendable { case preparing, uploading, creating, waiting, downloading, verifying, finished }
    public var kind: Kind
    public var waitedSeconds: Int?
    public init(_ kind: Kind, waitedSeconds: Int? = nil) { self.kind = kind; self.waitedSeconds = waitedSeconds }
}

public struct AudioStemCloudFile: Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let bytes: Int
    public let frames: Int
    public let sampleRate: Double
    public let channels: Int
    /// The decoded provider output differed from the requested source
    /// interval and was trimmed (or aligned with silence) to EXACT frames.
    /// Records the applied signed delta in seconds; 0 when untouched.
    public let alignmentSeconds: Double
}

public struct AudioStemCloudOutput: Sendable, Equatable {
    public let vocals: AudioStemCloudFile
    public let accompaniment: AudioStemCloudFile
    public let receipt: AudioStemCloudReceipt
    public let limitations: [String]
}

public struct AudioStemCloudRequest: Sendable {
    /// The frozen, explicitly selected source interval already exported by
    /// the App's existing excerpt writer. Its bytes are what the provider
    /// receives; the original source file is never uploaded.
    public let excerptURL: URL
    public let excerptSHA256: String
    public let excerptContentType: String
    public let jobName: String
    public let projectID: UUID
    public let clipID: UUID
    public let sourceSHA256: String
    public let sourceSeconds: Double
    public init(excerptURL: URL, excerptSHA256: String, excerptContentType: String, jobName: String,
        projectID: UUID, clipID: UUID, sourceSHA256: String, sourceSeconds: Double) throws {
        guard excerptURL.isFileURL, Self.isHash(excerptSHA256), Self.isHash(sourceSHA256),
              ["audio/wav", "audio/x-wav", "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/ogg"].contains(excerptContentType),
              !jobName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, jobName.utf8.count <= 512,
              sourceSeconds.isFinite, sourceSeconds > 0, sourceSeconds <= 6 * 3600 else {
            throw AudioPCMProcessingError.invalidInput("stem cloud request needs a bounded frozen source selection")
        }
        self.excerptURL = excerptURL; self.excerptSHA256 = excerptSHA256; self.excerptContentType = excerptContentType
        self.jobName = jobName; self.projectID = projectID; self.clipID = clipID
        self.sourceSHA256 = sourceSHA256; self.sourceSeconds = sourceSeconds
    }
    fileprivate struct Fence: Sendable {
        let projectID: UUID
        let clipID: UUID
        let sourceSHA256: String
        let excerptSHA256: String
        let sourceSeconds: Double
        let jobName: String
        init(projectID: UUID, clipID: UUID, sourceSHA256: String, excerptSHA256: String, sourceSeconds: Double, jobName: String) {
            self.projectID = projectID; self.clipID = clipID; self.sourceSHA256 = sourceSHA256
            self.excerptSHA256 = excerptSHA256; self.sourceSeconds = sourceSeconds; self.jobName = jobName
        }
        init(_ request: AudioStemCloudRequest) {
            projectID = request.projectID; clipID = request.clipID; sourceSHA256 = request.sourceSHA256
            excerptSHA256 = request.excerptSHA256; sourceSeconds = request.sourceSeconds; jobName = request.jobName
        }
    }
    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

public enum AudioStemCloudError: Error, Sendable, Equatable {
    case persistence(String)
    case noOwnedJob
    case staleSource
    case providerFailure(String)
    case timedOut(String)
    case unsafeResult(String)
    case resultMismatch(String)
}

/// The complete owned cloud lifecycle over the existing MusicAIStemAPI
/// contract: upload → create (the remote ID is durably awaited BEFORE any
/// post-response cancellation check) → poll the exact owned ID → verified
/// bounded downloads → decoded stems aligned to the selected source interval.
/// Timeouts keep ownership (the receipt stays recoverable) and NEVER create a
/// second paid job. Files are decoded/checked before the caller's single
/// atomic document commit (MediaAudioDerivation.commitStems).
public struct AudioStemCloudWorkflow: Sendable {
    public struct Limits: Sendable {
        public var maximumExcerptBytes: Int
        public var maximumResultBytes: Int
        public var pollInitialSeconds: Int
        public var pollMaximumSeconds: Int
        public var deadlineSeconds: Int
        /// A decoded provider stem may be at most this much shorter than the
        /// requested interval (aligned with silence) or longer (trimmed).
        public var maximumAlignmentSeconds: Double
        public var maximumTotalBytes: Int
        public init(maximumExcerptBytes: Int = 128 * 1_024 * 1_024, maximumResultBytes: Int = 256 * 1_024 * 1_024,
            pollInitialSeconds: Int = 2, pollMaximumSeconds: Int = 15, deadlineSeconds: Int = 1_500,
            maximumAlignmentSeconds: Double = 0.25, maximumTotalBytes: Int = 512 * 1_024 * 1_024) {
            self.maximumExcerptBytes = maximumExcerptBytes; self.maximumResultBytes = maximumResultBytes
            self.pollInitialSeconds = pollInitialSeconds; self.pollMaximumSeconds = pollMaximumSeconds
            self.deadlineSeconds = deadlineSeconds; self.maximumAlignmentSeconds = maximumAlignmentSeconds
            self.maximumTotalBytes = maximumTotalBytes
        }
        fileprivate func validated() throws {
            guard maximumExcerptBytes > 0, maximumExcerptBytes <= 128 * 1_024 * 1_024,
                  maximumResultBytes >= 1_024 * 1_024, maximumResultBytes <= 512 * 1_024 * 1_024,
                  pollInitialSeconds >= 1, pollMaximumSeconds >= pollInitialSeconds, pollMaximumSeconds <= 120,
                  deadlineSeconds >= pollMaximumSeconds, deadlineSeconds <= 3_600,
                  maximumAlignmentSeconds.isFinite, maximumAlignmentSeconds >= 0.01, maximumAlignmentSeconds <= 1,
                  maximumTotalBytes >= maximumResultBytes * 2 else {
                throw AudioPCMProcessingError.invalidInput("stem cloud limits are invalid")
            }
        }
    }
    public static let localFilenameVocals = "vocals.wav"
    public static let localFilenameAccompaniment = "accompaniment.wav"
    private let api: MusicAIStemAPI
    private let store: any AudioStemCloudReceiptStore
    private let downloader: any AudioStemCloudDownloading
    private let limits: Limits
    private let now: @Sendable () -> Date
    /// Re-checked before EVERY provider request and download. The App passes
    /// its existing provider authority gate here; model data can never mint
    /// it and a stale original/task stops the next network step.
    private let authority: @Sendable () async throws -> Void
    public init(api: MusicAIStemAPI, store: any AudioStemCloudReceiptStore, downloader: any AudioStemCloudDownloading,
        limits: Limits = .init(), now: @escaping @Sendable () -> Date = Date.init,
        authority: @escaping @Sendable () async throws -> Void = {}) throws {
        try limits.validated()
        self.api = api; self.store = store; self.downloader = downloader; self.limits = limits; self.now = now; self.authority = authority
    }
    /// Starts one new separation. Callers hold the existing provider authority
    /// and a fenced document instruction across this call and must re-check
    /// both before the atomic commit.
    public func start(_ request: AudioStemCloudRequest, destinationDirectory: URL,
        work: AudioPCMWork = .init(), status: @escaping @MainActor @Sendable (AudioStemCloudStage) -> Void = { _ in }) async throws -> AudioStemCloudOutput {
        try work.check()
        let values = try request.excerptURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= limits.maximumExcerptBytes,
              try Self.sha256(request.excerptURL, work: work) == request.excerptSHA256 else {
            throw AudioStemCloudError.resultMismatch("the frozen excerpt is missing, oversized or changed before upload")
        }
        let receipt = AudioStemCloudReceipt(remoteJobID: "", workflow: api.configuration.workflow, projectID: request.projectID,
            clipID: request.clipID, sourceSHA256: request.sourceSHA256, excerptSHA256: request.excerptSHA256,
            sourceSeconds: request.sourceSeconds, state: .submitting, createdAt: now(), updatedAt: now())
        let receiptBox = Mutex(receipt)
        await status(.init(.preparing))
        do {
            try await authority()
            let upload = try await api.prepareUpload(work: work)
            try work.check()
            await status(.init(.uploading))
            try await authority()
            try await api.uploadFile(request.excerptURL, upload: upload, contentType: request.excerptContentType, work: work)
            try work.check()
            await status(.init(.creating))
            let persisted = Mutex(false)
            let job: MusicAIStemJob
            do {
                try await authority()
                job = try await api.createJob(name: request.jobName, inputURL: upload.downloadURL,
                    metadata: ["project": request.projectID.uuidString, "clip": request.clipID.uuidString], work: work,
                    recordCreated: { [store] created in
                        // Awaited BEFORE the post-response cancellation check.
                        var filled = receiptBox.withLock { $0 }
                        filled.remoteJobID = created.id; filled.workflow = created.workflow; filled.updatedAt = Date()
                        filled.state = .created
                        try await store.save(filled)
                        receiptBox.withLock { $0 = filled }
                        persisted.withLock { $0 = true }
                    })
            } catch {
                if !persisted.withLock({ $0 }) {
                    var failed = receiptBox.withLock { $0 }
                    failed.state = .failed; failed.updatedAt = Date()
                    failed.lastError = String(String(describing: error).prefix(240))
                    try? await store.save(failed)
                }
                throw error
            }
            try work.check()
            return try await continueOwned(job: job, receipt: receiptBox.withLock { $0 }, fence: .init(request),
                destinationDirectory: destinationDirectory, resuming: false, work: work, status: status)
        } catch {
            let latest = receiptBox.withLock { $0 }
            if error is CancellationError || (error as? AudioPCMProcessingError) == .cancelled,
               !latest.remoteJobID.isEmpty, latest.state != .committed {
                // Losing the local wait must never lose the owned ID.
                var detached = latest; detached.state = .detached; detached.updatedAt = now()
                detached.lastError = "stopped before the owned job finished waiting; recover with its owned ID"
                try? await store.save(detached)
            }
            throw error
        }
    }
    /// Resume/poll the EXACT owned remote ID. Never creates a new job.
    public func resume(projectID: UUID, clipID: UUID, destinationDirectory: URL,
        work: AudioPCMWork = .init(), status: @escaping @MainActor @Sendable (AudioStemCloudStage) -> Void = { _ in }) async throws -> AudioStemCloudOutput {
        guard let receipt = try await store.owned(projectID: projectID, clipID: clipID), !receipt.remoteJobID.isEmpty else {
            throw AudioStemCloudError.noOwnedJob
        }
        let job = try Self.ownedJob(remoteID: receipt.remoteJobID, workflow: receipt.workflow)
        guard job.workflow == api.configuration.workflow else { throw AudioStemCloudError.noOwnedJob }
        let fence = AudioStemCloudRequest.Fence(projectID: projectID, clipID: clipID, sourceSHA256: receipt.sourceSHA256,
            excerptSHA256: receipt.excerptSHA256, sourceSeconds: receipt.sourceSeconds,
            jobName: "Floe stems \(clipID.uuidString.prefix(8))")
        return try await continueOwned(job: job, receipt: receipt, fence: fence,
            destinationDirectory: destinationDirectory, resuming: true, work: work, status: status)
    }
    /// Stop waiting locally on an owned job without pretending to cancel the
    /// provider. The owned receipt remains for honest recovery.
    public func detach(projectID: UUID, clipID: UUID, reason: String) async throws {
        guard let receipt = try await store.owned(projectID: projectID, clipID: clipID) else { throw AudioStemCloudError.noOwnedJob }
        var detached = receipt; detached.state = .detached; detached.updatedAt = now()
        detached.lastError = String(reason.prefix(240))
        try await store.save(detached)
    }
    /// DELETE only the owned remote record for this project+clip fence, after
    /// the App stopped its local work or verified downloads. A completed job
    /// can still be released; no claim is made about revoking billed
    /// computation. Original/user assets are untouched.
    public func releaseOwned(projectID: UUID, clipID: UUID, work: AudioPCMWork = .init()) async throws -> AudioStemCloudReceipt {
        guard let receipt = try await store.owned(projectID: projectID, clipID: clipID), !receipt.remoteJobID.isEmpty else {
            throw AudioStemCloudError.noOwnedJob
        }
        let job = try Self.ownedJob(remoteID: receipt.remoteJobID, workflow: receipt.workflow)
        var released = receipt; released.updatedAt = now()
        do {
            try await authority()
            try await api.delete(job, work: work)
            released.state = .released; released.lastError = nil
        } catch {
            released.state = .detached
            released.lastError = "owned delete unconfirmed: \(String(describing: error).prefix(200))"
        }
        try await store.save(released)
        return released
    }
    /// Mark the committed outcome AFTER the App's atomic document commit. The
    /// record may already be `.released` (remote deleted after verification).
    public func markCommitted(remoteJobID: String, projectID: UUID, clipID: UUID) async throws {
        guard let receipt = try await store.load(remoteJobID: remoteJobID), receipt.projectID == projectID, receipt.clipID == clipID,
              receipt.state != .failed else { throw AudioStemCloudError.noOwnedJob }
        if receipt.state == .committed { return }
        var committed = receipt; committed.state = .committed; committed.updatedAt = now(); committed.lastError = nil
        try await store.save(committed)
    }
    private func continueOwned(job: MusicAIStemJob, receipt initial: AudioStemCloudReceipt, fence: AudioStemCloudRequest.Fence,
        destinationDirectory: URL, resuming: Bool, work: AudioPCMWork, status: @escaping @MainActor @Sendable (AudioStemCloudStage) -> Void) async throws -> AudioStemCloudOutput {
        var receipt = initial
        do {
            let snapshot = try await pollUntilSucceeded(job: job, receipt: &receipt, work: work, status: status)
            guard let vocalsURL = snapshot.vocalsURL, let accompanimentURL = snapshot.accompanimentURL,
                  MusicAIStemAPI.safeHTTPS(vocalsURL), MusicAIStemAPI.safeHTTPS(accompanimentURL), vocalsURL != accompanimentURL else {
                throw AudioStemCloudError.unsafeResult("the owned job did not expose two distinct verified HTTPS results")
            }
            try work.check()
            await status(.init(.downloading))
            let destination = destinationDirectory.standardizedFileURL.resolvingSymlinksInPath()
            var total = 0
            let vocals = try await receive(vocalsURL, to: destination.appendingPathComponent(Self.localFilenameVocals),
                sourceSeconds: fence.sourceSeconds, work: work, totalBytes: &total)
            let accompaniment = try await receive(accompanimentURL, to: destination.appendingPathComponent(Self.localFilenameAccompaniment),
                sourceSeconds: fence.sourceSeconds, work: work, totalBytes: &total)
            var downloaded = receipt; downloaded.state = .downloaded; downloaded.updatedAt = now(); downloaded.lastError = nil
            try await store.save(downloaded)
            var limitations = ["Cloud stems are the configured Music.AI service's output; isolation quality is provider output, not locally verified separation."]
            if vocals.alignmentSeconds != 0 || accompaniment.alignmentSeconds != 0 {
                limitations.append(String(format: "Provider output was aligned to the selected %.3f s interval (vocals %+0.3f s, accompaniment %+0.3f s).",
                    fence.sourceSeconds, vocals.alignmentSeconds, accompaniment.alignmentSeconds))
            }
            await status(.init(.finished))
            return .init(vocals: vocals, accompaniment: accompaniment, receipt: downloaded, limitations: limitations)
        } catch {
            if !receipt.isTerminal, !receipt.remoteJobID.isEmpty {
                var updated = receipt; updated.updatedAt = now()
                switch error {
                case _ where error is CancellationError || (error as? AudioPCMProcessingError) == .cancelled:
                    updated.state = .detached
                    updated.lastError = "stopped while waiting; the owned remote job remains recoverable"
                case _ where (error as? AudioStemCloudError).map { if case .timedOut = $0 { return true }; return false } ?? false:
                    // The remote job may still complete and remain pollable.
                    updated.state = .detached
                    updated.lastError = String(String(describing: error).prefix(240))
                case _ where (error as? AudioStemCloudError).map { switch $0 { case .unsafeResult, .resultMismatch: return true; default: return false } } ?? false:
                    updated.state = .failed
                    updated.lastError = String(String(describing: error).prefix(240))
                default:
                    // Transient poll/download failure on an owned job stays
                    // recoverable; a fresh start must still never re-create
                    // this job while the receipt is non-terminal.
                    updated.state = resuming ? .polling : .detached
                    updated.lastError = String(String(describing: error).prefix(240))
                }
                try? await store.save(updated)
            }
            throw error
        }
    }
    private func pollUntilSucceeded(job: MusicAIStemJob, receipt: inout AudioStemCloudReceipt,
        work: AudioPCMWork, status: @escaping @MainActor @Sendable (AudioStemCloudStage) -> Void) async throws -> MusicAIStemJobSnapshot {
        let started = now()
        var delay = limits.pollInitialSeconds
        var waited = 0
        while true {
            try work.check()
            try await authority()
            let snapshot = try await api.status(job, work: work)
            switch snapshot.state {
            case .succeeded:
                var polling = receipt; polling.state = .succeeded; polling.updatedAt = now(); polling.lastError = nil
                try await store.save(polling); receipt = polling
                return snapshot
            case .failed:
                let message = snapshot.failure.map { "\($0.code): \($0.message)" } ?? "the provider reported a failure"
                var failed = receipt; failed.state = .failed; failed.updatedAt = now(); failed.lastError = String(message.prefix(240))
                try await store.save(failed); receipt = failed
                throw AudioStemCloudError.providerFailure(String(message.prefix(240)))
            case .queued, .started:
                var polling = receipt
                polling.state = .polling; polling.updatedAt = now(); polling.lastError = nil
                if polling.remoteJobID.isEmpty { polling.remoteJobID = job.id; polling.workflow = job.workflow }
                try await store.save(polling); receipt = polling
                if now().timeIntervalSince(started) + TimeInterval(delay) > TimeInterval(limits.deadlineSeconds) {
                    throw AudioStemCloudError.timedOut("waiting for the owned cloud job exceeded \(limits.deadlineSeconds) s; recover with its owned ID instead of creating another job")
                }
                await status(.init(.waiting, waitedSeconds: waited))
                try await Self.sleep(seconds: delay, work: work)
                waited += delay
                delay = min(delay * 2, limits.pollMaximumSeconds)
            }
        }
    }
    private func receive(_ url: URL, to destination: URL, sourceSeconds: Double, work: AudioPCMWork, totalBytes: inout Int) async throws -> AudioStemCloudFile {
        guard MusicAIStemAPI.safeHTTPS(url) else { throw AudioStemCloudError.unsafeResult("provider result URL is not bounded HTTPS") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        let remaining = limits.maximumTotalBytes - totalBytes
        guard remaining >= limits.maximumResultBytes else { throw AudioPCMProcessingError.limitExceeded("both stems exceed the transfer budget") }
        let cap = min(limits.maximumResultBytes, remaining)
        try await authority()
        try await downloader.download(url, to: destination, maxBytes: cap, work: work)
        try work.check()
        let downloadHash = try Self.sha256(destination, work: work)
        guard let decoded = try Self.decode(destination, work: work, maximumFrames: Int(TimeInterval(limits.maximumResultBytes) / 4)) else {
            throw AudioStemCloudError.resultMismatch("the provider result is not a decodable audio stem")
        }
        try decoded.validate(maximumBytes: limits.maximumResultBytes)
        let wanted = Int((sourceSeconds * decoded.sampleRate).rounded())
        guard wanted > 0 else { throw AudioStemCloudError.resultMismatch("the requested source interval is empty") }
        let maximumShift = max(1, Int(limits.maximumAlignmentSeconds * decoded.sampleRate))
        let pcm: AudioPCM
        var alignment = 0.0
        if decoded.frameCount != wanted {
            guard decoded.frameCount > wanted || wanted - decoded.frameCount <= maximumShift else {
                throw AudioStemCloudError.resultMismatch("provider output is shorter than the selected source interval")
            }
            pcm = try Self.reslice(decoded, frames: wanted)
            alignment = Double(wanted - decoded.frameCount) / decoded.sampleRate
        } else { pcm = decoded }
        try FileManager.default.removeItem(at: destination)
        try Self.write(pcm, to: destination, work: work)
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int($0) } ?? 0
        guard bytes > 0, bytes <= cap else { throw AudioPCMProcessingError.limitExceeded("a fitted stem exceeds its transfer bound") }
        totalBytes += bytes
        guard let written = try Self.decode(destination, work: work, maximumFrames: nil),
              written.frameCount == pcm.frameCount, written.sampleRate == pcm.sampleRate,
              written.channels.count == pcm.channels.count else {
            throw AudioStemCloudError.resultMismatch("the fitted stem does not read back with its measured identity")
        }
        _ = downloadHash // The raw provider bytes are replaced by the verified fit below.
        return .init(url: destination, sha256: try Self.sha256(destination, work: work), bytes: bytes,
            frames: pcm.frameCount, sampleRate: pcm.sampleRate, channels: pcm.channels.count, alignmentSeconds: alignment)
    }
    private static func ownedJob(remoteID: String, workflow: String) throws -> MusicAIStemJob {
        // MusicAIStemJob keeps its initializer fileprivate on purpose; the
        // Codable round-trip is the only contract-preserving way to rebuild an
        // already-persisted owned receipt. A decoded receipt is data, not
        // permission: callers revalidate ownership before every use.
        let json = try JSONSerialization.data(withJSONObject: ["id": remoteID, "workflow": workflow])
        do { return try JSONDecoder().decode(MusicAIStemJob.self, from: json) }
        catch { throw AudioStemCloudError.noOwnedJob }
    }
    private static func sleep(seconds: Int, work: AudioPCMWork) async throws {
        var remaining = seconds
        while remaining > 0 {
            try Task.checkCancellation()
            if work.isCancelled() { throw AudioPCMProcessingError.cancelled }
            let slice = min(remaining, 1)
            do { try await Task.sleep(nanoseconds: UInt64(slice) * 1_000_000_000) }
            catch { throw CancellationError() }
            remaining -= slice
        }
    }
    private static func decode(_ url: URL, work: AudioPCMWork, maximumFrames: Int?) throws -> AudioPCM? {
        try work.check()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        guard rate.isFinite, (8_000...192_000).contains(rate), (1...2).contains(channels), file.length > 0,
              let frames = Int(exactly: file.length), frames > 0,
              maximumFrames.map({ frames <= $0 }) ?? true else { return nil }
        var samples = [[Float]](repeating: [], count: channels)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else { return nil }
        file.framePosition = 0
        while Int(file.framePosition) < frames {
            try work.check()
            let wanted = min(8_192, frames - Int(file.framePosition))
            try file.read(into: input, frameCount: AVAudioFrameCount(wanted))
            guard input.frameLength > 0 else { return nil }
            guard let data = input.floatChannelData else { return nil }
            for channel in 0..<channels { samples[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(input.frameLength))) }
        }
        guard samples.allSatisfy({ $0.count == frames }) else { return nil }
        return try AudioPCM(sampleRate: rate, channels: samples)
    }
    private static func reslice(_ pcm: AudioPCM, frames: Int) throws -> AudioPCM {
        var channels = pcm.channels
        for index in channels.indices {
            if channels[index].count > frames { channels[index] = Array(channels[index][0..<frames]) }
            else if channels[index].count < frames { channels[index].append(contentsOf: [Float](repeating: 0, count: frames - channels[index].count)) }
        }
        return try AudioPCM(sampleRate: pcm.sampleRate, channels: channels)
    }
    private static func write(_ pcm: AudioPCM, to url: URL, work: AudioPCMWork) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.sampleRate,
            channels: AVAudioChannelCount(pcm.channels.count), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw AudioPCMProcessingError.transformUnavailable
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for start in stride(from: 0, to: pcm.frameCount, by: 8_192) {
            try work.check()
            let count = min(8_192, pcm.frameCount - start)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in pcm.channels.indices {
                pcm.channels[channel].withUnsafeBufferPointer { source in
                    buffer.floatChannelData![channel].update(from: source.baseAddress! + start, count: count)
                }
            }
            try file.write(from: buffer)
        }
    }
    private static func sha256(_ url: URL, work: AudioPCMWork) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try work.check()
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

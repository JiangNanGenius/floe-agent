// Service-owned image transfer scratch. This never owns installed images,
// environment disks, Runtime recovery, resident state, or arbitrary paths.
import Foundation
import Darwin
import FloeCore

public struct LinuxGuestUpgradeResidueReport: Codable, Sendable, Equatable {
    public var deletedJobs = 0
    public var deletedEntries = 0
    /// Sum of allocation observed immediately before successful unlinks.
    /// Not guaranteed physical reclaim on APFS/COW.
    public var summedDeletedAllocatedBytes: Int64 = 0
    public var volumeAvailableDeltaBytes: Int64?
    public var skippedBusy = 0
    public var retainedUnknownOwnership = 0
    public var retainedLocalRecovery = 0
    public var retainedCurrentResume = 0
    public var retainedLegacyEntries = 0
    public var unmeasuredLegacyDirectories = 0
    public var legacyKnownFileAllocatedBytes: Int64 = 0
    public var failedJobs = 0
    public var budgetReached = false
    public var wasCancelled = false
    public var isUpgradePass = false
    public var completedAt = Date()
}

struct LinuxImageStageRecord: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case catalogDownload, catalogImport, localImport }
    enum State: String, Codable, Sendable { case active, retryable, promoting, discardable }
    var schema = 1
    var producer = "FloeExecution.LinuxImageTransfer/1"
    var operationID: String
    var directoryName: String
    var session: String
    var producerBuild: String
    var kind: Kind
    var state: State
    var imageID: String?
    var archiveSHA512: String?
    var namespaceIdentity: LinuxImageStageIdentity
    var directoryIdentity: LinuxImageStageIdentity
    var lockIdentity: LinuxImageStageIdentity
    var payloadIdentity: LinuxImageStageIdentity
    var publicationImageID: String?
    var publicationIdentity: LinuxImageStageIdentity?
    var publicationLeaf: String?
}

/// Opaque handle retained until downloader/extractor/importer has actually
/// returned. Closing this is not inferred from task cancellation or a TTL.
final class LinuxImageOwnedStage: @unchecked Sendable {
    let url: URL
    let payloadURL: URL
    let directoryName: String
    let operationID: String
    private let center: StorageCleanupLeaseCenter
    private let lock = NSLock()
    private var lockFD: Int32?

    init(url: URL, name: String, id: String, fd: Int32, center: StorageCleanupLeaseCenter) {
        self.url = url
        self.payloadURL = url.appendingPathComponent("payload", isDirectory: true)
        self.directoryName = name
        self.operationID = id
        self.lockFD = fd
        self.center = center
    }

    func closeNativeOwner() -> Bool {
        lock.withLock {
            guard let fd = lockFD else { return false }
            lockFD = nil
            _ = Darwin.close(fd)
            return true
        }
    }

    deinit {
        if closeNativeOwner() {
            let center = center
            let path = url.path
            Task { await center.release(path: path) }
        }
    }
}

actor LinuxGuestImageStagingOwner {
    static let processSession = UUID().uuidString
    static var currentBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let number = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version)/\(number)"
    }
    struct Limits: Sendable {
        var maxJobs = 16
        var maxNamespaceEntries = 256
        var maxEntriesPerJob = 512
        var maxAllocatedBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
        var maxSeconds: TimeInterval = 3
    }
    private struct Checkpoint: Codable {
        var producer = "FloeExecution.LinuxImageTransferCleanup/1"
        var build: String
        var report: LinuxGuestUpgradeResidueReport
    }
    private let root: URL
    private let imagesURL: URL
    private let center: StorageCleanupLeaseCenter
    private let session: String
    private let build: String
    private let limits: Limits
    private(set) var latestReport: LinuxGuestUpgradeResidueReport?

    init(root: URL, center: StorageCleanupLeaseCenter = .shared,
         session: String = LinuxGuestImageStagingOwner.processSession,
         build: String = LinuxGuestImageStagingOwner.currentBuild, limits: Limits = Limits()) {
        self.root = root
        self.imagesURL = root.appendingPathComponent("LinuxGuest/images", isDirectory: true)
        self.center = center
        self.session = session
        self.build = build
        self.limits = limits
    }

    func beginImport(catalog: LinuxGuestTrustedImage? = nil) async throws -> LinuxImageOwnedStage {
        try await begin(kind: catalog == nil ? .localImport : .catalogImport, catalog: catalog)
    }

    func beginDownload(catalog: LinuxGuestTrustedImage) async throws -> LinuxImageOwnedStage {
        try await begin(kind: .catalogDownload, catalog: catalog)
    }

    private func begin(kind: LinuxImageStageRecord.Kind, catalog: LinuxGuestTrustedImage?) async throws -> LinuxImageOwnedStage {
        if let catalog {
            guard let pinned = LinuxGuestImageDistributionCatalog.entry(id: catalog.id),
                  pinned.archiveSHA512.lowercased() == catalog.archiveSHA512.lowercased() else {
                throw LinuxImageStageError.unsafe
            }
        }
        guard let images = try LinuxImageStageIO.images(root: root, create: true),
              let namespace = try LinuxImageStageIO.directory(LinuxImageStageIO.namespace, in: images, create: true) else {
            throw LinuxImageStageError.unsafe
        }
        defer { _ = Darwin.close(images); _ = Darwin.close(namespace) }
        var reused: LinuxImageStageRecord?
        if kind == .catalogDownload, let catalog {
            // Same owned job => same parent for the existing verified-piece
            // resume implementation. Unknown/legacy jobs are never adopted.
            for name in try LinuxImageStageIO.names(in: namespace, limit: limits.maxNamespaceEntries, allowPartial: true) {
                guard UUID(uuidString: name) != nil,
                      let fd = try? LinuxImageStageIO.directory(name, in: namespace, create: false) else { continue }
                defer { _ = Darwin.close(fd) }
                guard let record = try? LinuxImageStageIO.readRecord(in: fd),
                      valid(record, name: name, directory: fd, namespace: namespace),
                      record.kind == .catalogDownload, record.state != .discardable,
                      record.imageID == catalog.id,
                      record.archiveSHA512 == catalog.archiveSHA512.lowercased() else { continue }
                reused = record
                break
            }
        }
        let name = reused?.directoryName ?? UUID().uuidString
        let url = imagesURL.appendingPathComponent(LinuxImageStageIO.namespace, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard await center.acquire(path: url.path) else { throw LinuxImageStageError.busy }
        var ownedFD: Int32?
        do {
            if reused == nil {
                guard name.withCString({ mkdirat(namespace, $0, mode_t(0o700)) }) == 0 else {
                    throw LinuxImageStageError.io(errno)
                }
            }
            guard let directory = try LinuxImageStageIO.directory(name, in: namespace, create: false) else {
                throw LinuxImageStageError.unsafe
            }
            defer { _ = Darwin.close(directory) }
            let lockFD = try LinuxImageStageIO.lock(in: directory, create: reused == nil)
            ownedFD = lockFD
            guard let observed = try LinuxImageStageIO.observe(name, in: namespace),
                  observed.sameInode(as: try LinuxImageStageIO.identity(fd: directory)) else {
                throw LinuxImageStageError.unsafe
            }
            let record: LinuxImageStageRecord
            if let previous = reused {
                var existing = try LinuxImageStageIO.readRecord(in: directory)
                guard existing.operationID == previous.operationID, existing.state != .discardable,
                      valid(existing, name: name, directory: directory, namespace: namespace),
                      try LinuxImageStageIO.identity(fd: lockFD).sameInode(as: existing.lockIdentity) else {
                    throw LinuxImageStageError.unsafe
                }
                existing.state = .active
                existing.session = session
                existing.producerBuild = build
                record = existing
            } else {
                guard let payload = try LinuxImageStageIO.directory("payload", in: directory, create: true) else {
                    throw LinuxImageStageError.unsafe
                }
                defer { _ = Darwin.close(payload) }
                record = .init(operationID: UUID().uuidString, directoryName: name, session: session,
                               producerBuild: build, kind: kind, state: .active,
                               imageID: catalog?.id, archiveSHA512: catalog?.archiveSHA512.lowercased(),
                               namespaceIdentity: try LinuxImageStageIO.identity(fd: namespace),
                               directoryIdentity: try LinuxImageStageIO.identity(fd: directory),
                               lockIdentity: try LinuxImageStageIO.identity(fd: lockFD),
                               payloadIdentity: try LinuxImageStageIO.identity(fd: payload))
            }
            // No payload bytes are exposed to a writer until this record and
            // both directory entries are durable. A crash before here leaves
            // at most unowned empty metadata, never an unowned GB payload.
            try LinuxImageStageIO.writeRecord(record, in: directory)
            guard fsync(directory) == 0, fsync(namespace) == 0, fsync(images) == 0 else {
                throw LinuxImageStageError.io(errno)
            }
            ownedFD = nil
            return LinuxImageOwnedStage(url: url, name: name, id: record.operationID, fd: lockFD, center: center)
        } catch {
            if let ownedFD { _ = Darwin.close(ownedFD) }
            await center.release(path: url.path)
            throw error
        }
    }

    private func valid(_ record: LinuxImageStageRecord, name: String, directory: Int32, namespace: Int32) -> Bool {
        guard record.schema == 1, record.producer == "FloeExecution.LinuxImageTransfer/1",
              UUID(uuidString: record.operationID) != nil, UUID(uuidString: record.session) != nil,
              record.directoryName == name, UUID(uuidString: name) != nil,
              !record.producerBuild.isEmpty, record.producerBuild.utf8.count <= 128,
              let actual = try? LinuxImageStageIO.identity(fd: directory),
              let parent = try? LinuxImageStageIO.identity(fd: namespace),
              actual.sameInode(as: record.directoryIdentity), parent.sameInode(as: record.namespaceIdentity),
              let lock = try? LinuxImageStageIO.observe(LinuxImageStageIO.lockName, in: directory),
              lock.sameInode(as: record.lockIdentity) else { return false }
        if record.kind != .localImport {
            guard let id = record.imageID, !id.isEmpty, id.utf8.count <= 160,
                  let digest = record.archiveSHA512, digest.count == 128,
                  digest.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        // payload may already have moved out only after a journaled promotion.
        if let payload = try? LinuxImageStageIO.observe("payload", in: directory) {
            return payload.sameInode(as: record.payloadIdentity)
        }
        return record.state == .promoting || record.state == .discardable
    }

    func markPromotion(_ stage: LinuxImageOwnedStage, candidate: URL, imageID: String) throws {
        try LinuxImageStageIO.validate(imageID)
        guard !imageID.hasPrefix("."),
              candidate == stage.payloadURL || candidate.deletingLastPathComponent() == stage.payloadURL else {
            throw LinuxImageStageError.unsafe
        }
        let directory = stage.url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directory >= 0 else { throw LinuxImageStageError.io(errno) }
        defer { _ = Darwin.close(directory) }
        var record = try LinuxImageStageIO.readRecord(in: directory)
        guard record.operationID == stage.operationID, record.session == session else { throw LinuxImageStageError.unsafe }
        let candidateFD = candidate.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard candidateFD >= 0 else { throw LinuxImageStageError.io(errno) }
        defer { _ = Darwin.close(candidateFD) }
        record.state = .promoting
        record.publicationImageID = imageID
        record.publicationIdentity = try LinuxImageStageIO.identity(fd: candidateFD)
        record.publicationLeaf = candidate == stage.payloadURL ? "payload" : candidate.lastPathComponent
        try LinuxImageStageIO.writeRecord(record, in: directory)
    }

    func finish(_ stage: LinuxImageOwnedStage, retryable: Bool = false) async {
        var persistenceFailed = false
        do {
            let directory = stage.url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard directory >= 0 else { throw LinuxImageStageError.io(errno) }
            defer { _ = Darwin.close(directory) }
            var record = try LinuxImageStageIO.readRecord(in: directory)
            guard record.operationID == stage.operationID, record.session == session else { throw LinuxImageStageError.unsafe }
            if record.kind == .catalogDownload,
               let payload = try LinuxImageStageIO.directory("payload", in: directory, create: false) {
                defer { _ = Darwin.close(payload) }
                guard try LinuxImageStageIO.identity(fd: payload).sameInode(as: record.payloadIdentity) else {
                    throw LinuxImageStageError.unsafe
                }
                // All awaited fetch/import workers have returned. Preserve
                // verified-piece resume, but retain the old producer contract:
                // the whole/partial archive is transient, not a resume cache.
                if let archive = try LinuxImageStageIO.observe("archive.zip", in: payload) {
                    guard archive.isRegular, archive.links == 1, archive.uid == UInt32(geteuid()) else {
                        throw LinuxImageStageError.unsafe
                    }
                    guard "archive.zip".withCString({ unlinkat(payload, $0, 0) }) == 0,
                          fsync(payload) == 0 else { throw LinuxImageStageError.io(errno) }
                }
            }
            var mayDiscard = record.kind != .localImport
            if !mayDiscard, record.state == .promoting,
               let id = record.publicationImageID, !id.hasPrefix("."),
               let published = record.publicationIdentity,
               let images = try LinuxImageStageIO.images(root: root, create: false) {
                defer { _ = Darwin.close(images) }
                if let actual = try LinuxImageStageIO.observe(id, in: images) {
                    mayDiscard = actual.sameInode(as: published)
                }
            }
            if mayDiscard {
                record.state = retryable && record.kind == .catalogDownload ? .retryable : .discardable
                try LinuxImageStageIO.writeRecord(record, in: directory)
            }
            // A local import with no proven published duplicate may contain
            // the only remaining user image. Owner completion/age alone does
            // not grant deletion; retain its durable recovery record.
        } catch {
            // Keep the old durable lifecycle record, never manufacture a
            // disposable state after an ownership/persistence failure.
            persistenceFailed = true
        }
        if stage.closeNativeOwner() { await center.release(path: stage.url.path) }
        if !retryable {
            var result = await cleanup(build: build)
            if persistenceFailed { result.failedJobs += 1 }
            latestReport = result
        } else if persistenceFailed {
            var result = latestReport ?? LinuxGuestUpgradeResidueReport()
            result.failedJobs += 1
            latestReport = result
        }
    }

    func cleanup(build: String, isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) async -> LinuxGuestUpgradeResidueReport {
        var report = LinuxGuestUpgradeResidueReport()
        guard !build.isEmpty, build.utf8.count <= 128 else { report.failedJobs = 1; return report }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maxSeconds
        let stop = { isCancelled() || Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
        do {
            guard let images = try LinuxImageStageIO.images(root: root, create: false) else { return report }
            defer { _ = Darwin.close(images) }
            let before = LinuxImageStageIO.availableBytes(fd: images)
            // Historical names are diagnostic only. No old .download/.import/
            // .trash, installed component, environment, resident or recovery is deleted.
            do {
                let legacyNames = try LinuxImageStageIO.names(in: images, limit: limits.maxNamespaceEntries, allowPartial: true)
                if legacyNames.count >= limits.maxNamespaceEntries { report.budgetReached = true }
                for name in legacyNames {
                    if stop() { break }
                    guard [".download-", ".import-", ".trash-", ".shards-"].contains(where: { name.hasPrefix($0) }) else { continue }
                    report.retainedLegacyEntries += 1
                    if let entry = try LinuxImageStageIO.observe(name, in: images) {
                        if entry.isDirectory { report.unmeasuredLegacyDirectories += 1 }
                        else if entry.isRegular { report.legacyKnownFileAllocatedBytes += entry.allocatedBytes }
                    }
                }
            } catch { report.budgetReached = true }
            guard let namespace = try LinuxImageStageIO.directory(LinuxImageStageIO.namespace, in: images, create: false) else {
                report.wasCancelled = isCancelled() || Task.isCancelled
                latestReport = report
                return report
            }
            defer { _ = Darwin.close(namespace) }
            let names = try LinuxImageStageIO.names(in: namespace, limit: limits.maxNamespaceEntries, allowPartial: true)
            if names.count >= limits.maxNamespaceEntries { report.budgetReached = true }
            for name in names {
                if stop() { break }
                guard UUID(uuidString: name) != nil else {
                    if name != "last-cleanup.json" { report.retainedUnknownOwnership += 1 }
                    continue
                }
                guard report.deletedJobs < limits.maxJobs else { report.budgetReached = true; break }
                let url = imagesURL.appendingPathComponent(LinuxImageStageIO.namespace).appendingPathComponent(name)
                guard let claim = await center.claimForDeletion(path: url.path) else { report.skippedBusy += 1; continue }
                do {
                    try cleanJob(name, namespace: namespace, images: images, build: build, stop: stop, report: &report)
                } catch is CancellationError {
                    report.wasCancelled = isCancelled() || Task.isCancelled
                    report.budgetReached = !report.wasCancelled
                } catch LinuxImageStageError.busy {
                    report.skippedBusy += 1
                } catch LinuxImageStageError.limit {
                    report.budgetReached = true
                } catch LinuxImageStageError.unsafe {
                    report.retainedUnknownOwnership += 1
                } catch {
                    report.failedJobs += 1
                }
                await center.releaseClaim(claim.id)
            }
            if let before, let after = LinuxImageStageIO.availableBytes(fd: images) {
                report.volumeAvailableDeltaBytes = after - before
            }
            report.wasCancelled = report.wasCancelled || isCancelled() || Task.isCancelled
            report.budgetReached = report.budgetReached || (ProcessInfo.processInfo.systemUptime >= deadline && !report.wasCancelled)
            report.completedAt = Date()
            if !report.wasCancelled {
                try writeCheckpoint(build: build, report: report, namespace: namespace)
            }
        } catch is CancellationError {
            report.wasCancelled = true
        } catch LinuxImageStageError.limit {
            report.budgetReached = true
        } catch {
            report.failedJobs += 1
        }
        latestReport = report
        return report
    }

    private func cleanJob(_ name: String, namespace: Int32, images: Int32, build: String,
                          stop: () -> Bool, report: inout LinuxGuestUpgradeResidueReport) throws {
        guard let directory = try LinuxImageStageIO.directory(name, in: namespace, create: false) else { throw LinuxImageStageError.unsafe }
        defer { _ = Darwin.close(directory) }
        let admitted: LinuxImageStageRecord
        do { admitted = try LinuxImageStageIO.readRecord(in: directory) }
        catch { throw LinuxImageStageError.unsafe }
        guard valid(admitted, name: name, directory: directory, namespace: namespace) else { throw LinuxImageStageError.unsafe }
        let native = try LinuxImageStageIO.lock(in: directory, create: false)
        defer { _ = Darwin.close(native) }
        let record = try LinuxImageStageIO.readRecord(in: directory)
        guard record.operationID == admitted.operationID,
              valid(record, name: name, directory: directory, namespace: namespace),
              try LinuxImageStageIO.identity(fd: native).sameInode(as: record.lockIdentity) else {
            throw LinuxImageStageError.unsafe
        }
        report.isUpgradePass = report.isUpgradePass || record.producerBuild != build
        guard let current = try LinuxImageStageIO.observe(name, in: namespace),
              current.sameInode(as: record.directoryIdentity) else { throw LinuxImageStageError.unsafe }
        var discard = record.state == .discardable
        if !discard, record.kind != .localImport, record.session != session {
            if record.kind == .catalogImport || record.producerBuild != build { discard = true }
            else { report.retainedCurrentResume += 1; return }
        }
        if !discard, record.kind == .localImport, record.state == .promoting,
           let id = record.publicationImageID, !id.hasPrefix("."),
           let published = record.publicationIdentity,
           let actual = try LinuxImageStageIO.observe(id, in: images), actual.sameInode(as: published) {
            // The exact already-verified candidate was renamed OUT of this
            // private job. Cleanup can only remove its leftover private wrapper.
            discard = true
        }
        guard discard else { report.retainedLocalRecovery += 1; return }
        var disposable = record
        disposable.state = .discardable
        try LinuxImageStageIO.writeRecord(disposable, in: directory)
        let nodes = try LinuxImageStageIO.snapshot(in: directory, limit: limits.maxEntriesPerJob, cancelled: stop)
        var allocated: Int64 = 0
        for node in nodes {
            let (sum, overflow) = allocated.addingReportingOverflow(node.identity.allocatedBytes)
            guard !overflow else { throw LinuxImageStageError.limit }
            allocated = sum
        }
        guard allocated <= limits.maxAllocatedBytes - report.summedDeletedAllocatedBytes else { throw LinuxImageStageError.limit }
        try LinuxImageStageIO.remove(nodes: nodes, from: directory, cancelled: stop, report: &report)
        guard let final = try LinuxImageStageIO.observe(name, in: namespace), final.sameInode(as: record.directoryIdentity) else {
            throw LinuxImageStageError.unsafe
        }
        guard name.withCString({ unlinkat(namespace, $0, AT_REMOVEDIR) }) == 0,
              fsync(namespace) == 0 else { throw LinuxImageStageError.io(errno) }
        report.deletedJobs += 1
    }

    private func writeCheckpoint(build: String, report: LinuxGuestUpgradeResidueReport, namespace: Int32) throws {
        // Diagnostic checkpoint only; eligibility is always reconstructed from
        // per-job producer records + live leases + native lock + inode checks.
        let bytes = try JSONEncoder().encode(Checkpoint(build: build, report: report))
        let name = "last-cleanup.json"
        let temporary = ".cleanup-\(UUID().uuidString).tmp"
        let fd = temporary.withCString { openat(namespace, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw LinuxImageStageError.io(errno) }
        defer { _ = Darwin.close(fd) }
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard count == bytes.count, fsync(fd) == 0 else { throw LinuxImageStageError.io(errno) }
        let result = temporary.withCString { old in name.withCString { renameat(namespace, old, namespace, $0) } }
        guard result == 0, fsync(namespace) == 0 else { throw LinuxImageStageError.io(errno) }
    }
}

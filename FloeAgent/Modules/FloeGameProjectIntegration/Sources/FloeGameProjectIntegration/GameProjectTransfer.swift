// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameAuthoring

/// Resolved by the App's existing access, workspace and environment services.
/// Never decoded from a game, a saved link, or a model response.
public struct GameProjectTransferEndpoint: Sendable {
    public let context: GameProjectContext
    public let repository: FileGameProjectRepository
    public let contexts: any GameAuthoringContextHost

    public init(context: GameProjectContext, repository: FileGameProjectRepository,
                contexts: any GameAuthoringContextHost) {
        self.context = context; self.repository = repository; self.contexts = contexts
    }
}

public enum GameProjectTransferMode: Sendable {
    /// The host has already created an independent empty destination project.
    case importIntoEmptyProject
    /// The caller has explicitly chosen to update this captured destination.
    /// Its expected revision is still checked, and its previous bytes survive.
    case updateExistingCopy
}

public struct GameProjectTransferPreview: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceProjectID: UUID
    public let destinationProjectID: UUID
    public let sourceRevision: String
    public let destinationRevision: String
    public let engineHint: GameEngineID?
    public let fileCount: Int
    public let byteCount: Int
    public let addedPaths: [GameRelativePath]
    public let modifiedPaths: [GameRelativePath]
    public let removedPaths: [GameRelativePath]
}

public struct GameProjectTransferReceipt: Sendable {
    public let id: UUID
    public let sourceProjectID: UUID
    public let sourceRevision: String
    public let destinationPreviousRevision: String
    public let project: GameStoredProject
    /// Metadata for fresh recognition/choice in the destination, never a runtime
    /// readiness claim or permission copied from the source project.
    public let engineHint: GameEngineID?
    /// A completed commit remains completed if its presentation was closed.
    /// The host reopens this exact project before any further action.
    public let requiresReopen: Bool
    /// Cleanup failure cannot relabel a committed copy as a failed import.
    public let cleanupPending: Bool
}

public enum GameProjectTransferError: Error, Equatable, Sendable {
    case sameProject, overlappingRoots, engineChangeRequiresNewProject
    case invalidStagingDirectory, tooManyPendingTransfers, unknownTransfer, committing
}

/// Explicit copies between independent chat/Space repositories. This does not
/// synchronize either project, move its assistant, copy save games, or touch Git.
/// All engines use the same exact-byte repository import/export operations.
public actor GameProjectTransferService {
    private struct Pending: Sendable {
        let preview: GameProjectTransferPreview
        let source: GameProjectTransferEndpoint
        let destination: GameProjectTransferEndpoint
        let mode: GameProjectTransferMode
        let jobDirectory: URL
        let sourceTree: URL
        let sourceSnapshot: GameStoredProject
        let destinationLimits: GameRepositoryLimits
    }
    private let stagingDirectory: URL
    private let removeOwnedDirectory: @Sendable (URL) throws -> Void
    private var pending: [UUID: Pending] = [:]
    private var committing: Set<UUID> = []
    private var receipts: [UUID: GameProjectTransferReceipt] = [:]
    private var receiptOrder: [UUID] = []
    private var cleanupJobs: [UUID: URL] = [:]

    public init(stagingDirectory: URL,
                removeOwnedDirectory: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard stagingDirectory.isFileURL else { throw GameProjectTransferError.invalidStagingDirectory }
        let canonical = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameProjectTransferError.invalidStagingDirectory
        }
        self.stagingDirectory = canonical
        self.removeOwnedDirectory = removeOwnedDirectory
    }

    public func prepare(from source: GameProjectTransferEndpoint,
                        to destination: GameProjectTransferEndpoint,
                        mode: GameProjectTransferMode) async throws -> GameProjectTransferPreview {
        guard source.context.projectID != destination.context.projectID else {
            throw GameProjectTransferError.sameProject
        }
        let roots = [source.context.rootURL, destination.context.rootURL]
        guard !Self.overlap(roots[0], roots[1]),
              roots.allSatisfy({ !Self.overlap($0, stagingDirectory) }) else {
            throw GameProjectTransferError.overlappingRoots
        }
        // Count before suspension so an actor reentry cannot admit unbounded jobs.
        guard pending.count + preparing + cleanupJobs.count < 8 else { throw GameProjectTransferError.tooManyPendingTransfers }
        preparing += 1
        defer { preparing -= 1 }
        try await validate(source); try await validate(destination)
        let original = try await source.repository.open(source.context.projectID, owner: source.context.owner)
        let target = try await destination.repository.open(destination.context.projectID, owner: destination.context.owner)
        try Self.require(original, context: source.context)
        try Self.require(target, context: destination.context)
        switch mode {
        case .importIntoEmptyProject:
            guard target.files.isEmpty, target.directories.isEmpty else { throw GameProjectError.importDestinationNotEmpty }
        case .updateExistingCopy:
            // Engine conversion is a separately created project. Do not silently
            // turn a user's independently edited destination into another engine.
            if let targetEngine = target.engine, let sourceEngine = original.engine,
               targetEngine != sourceEngine { throw GameProjectTransferError.engineChangeRequiresNewProject }
        }
        let id = UUID()
        let job = stagingDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let tree = job.appendingPathComponent("Source", isDirectory: true)
        do {
            _ = try await source.repository.export(original.projectID, owner: original.owner,
                expectedRevision: original.revision, to: tree)
            try await validate(source); try await validate(destination)
            let before = Dictionary(uniqueKeysWithValues: target.files.map { ($0.path, $0) })
            let after = Dictionary(uniqueKeysWithValues: original.files.map { ($0.path, $0) })
            let sorted: (GameRelativePath, GameRelativePath) -> Bool = { $0.value < $1.value }
            let preview = GameProjectTransferPreview(id: id, sourceProjectID: original.projectID,
                destinationProjectID: target.projectID, sourceRevision: original.revision,
                destinationRevision: target.revision, engineHint: original.engine, fileCount: original.files.count,
                byteCount: original.files.reduce(0) { $0 + $1.bytes },
                addedPaths: after.keys.filter { before[$0] == nil }.sorted(by: sorted),
                modifiedPaths: after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted(by: sorted),
                removedPaths: before.keys.filter { after[$0] == nil }.sorted(by: sorted))
            let destinationLimits = await destination.repository.limits
            try await validate(source); try await validate(destination)
            pending[id] = .init(preview: preview, source: source, destination: destination,
                mode: mode, jobDirectory: job, sourceTree: tree, sourceSnapshot: original,
                destinationLimits: destinationLimits)
            return preview
        } catch {
            // This directory was exclusively created by this request, never a
            // caller-provided game or destination. Failed preparations publish nothing.
            do { try removeOwnedDirectory(job) }
            catch { cleanupJobs[id] = job }
            throw error
        }
    }

    private var preparing = 0

    public func commit(_ id: UUID) async throws -> GameProjectTransferReceipt {
        if let completed = receipts[id] { return completed }
        guard !committing.contains(id) else { throw GameProjectTransferError.committing }
        guard let transfer = pending[id] else { throw GameProjectTransferError.unknownTransfer }
        committing.insert(id)
        defer { committing.remove(id) }
        try await validate(transfer.source); try await validate(transfer.destination)
        let current = try await transfer.source.repository.open(transfer.source.context.projectID,
                                                                 owner: transfer.source.context.owner)
        try Self.require(current, context: transfer.source.context)
        // The private job is outside both IDE roots. No imported path or model
        // receives it. Verify its inventory and bytes before the repository's
        // own bounded double-read import validation.
        try Self.verifyStagedTree(transfer)
        try Task.checkCancellation()
        let replace: Bool
        switch transfer.mode { case .importIntoEmptyProject: replace = false; case .updateExistingCopy: replace = true }
        let saved = try await transfer.destination.repository.importContents(from: transfer.sourceTree,
            into: transfer.destination.context.projectID, owner: transfer.destination.context.owner,
            expectedRevision: transfer.preview.destinationRevision, replaceExisting: replace)
        // No cancellable operation may turn this completed transaction into an
        // apparent failure. Persisted destination history is the source of truth.
        var reopen = false
        do {
            _ = try await transfer.destination.contexts.contextAfterCommit(saved, previous: transfer.destination.context)
        } catch { reopen = true }
        let cleaned: Bool
        do { try removeOwnedDirectory(transfer.jobDirectory); cleaned = true }
        catch { cleaned = false; cleanupJobs[id] = transfer.jobDirectory }
        let receipt = GameProjectTransferReceipt(id: id, sourceProjectID: transfer.preview.sourceProjectID,
            sourceRevision: transfer.preview.sourceRevision,
            destinationPreviousRevision: transfer.preview.destinationRevision, project: saved,
            engineHint: transfer.preview.engineHint,
            requiresReopen: reopen, cleanupPending: !cleaned)
        pending[id] = nil
        receipts[id] = receipt; receiptOrder.append(id)
        while receiptOrder.count > 128,
              let index = receiptOrder.firstIndex(where: { cleanupJobs[$0] == nil }) {
            receipts[receiptOrder.remove(at: index)] = nil
        }
        return receipt
    }

    public func discard(_ id: UUID) throws {
        guard !committing.contains(id) else { throw GameProjectTransferError.committing }
        guard let transfer = pending[id] else { return }
        // Keep the pending record when removal fails so cleanup can be retried.
        try removeOwnedDirectory(transfer.jobDirectory)
        pending[id] = nil
    }

    public func receipt(for id: UUID) -> GameProjectTransferReceipt? { receipts[id] }

    public func pendingCleanupIDs() -> [UUID] { Array(cleanupJobs.keys).sorted { $0.uuidString < $1.uuidString } }

    /// A nil receipt means a failed preparation was removed; it never committed.
    public func retryCleanup(_ id: UUID) throws -> GameProjectTransferReceipt? {
        guard let directory = cleanupJobs[id] else {
            guard let receipt = receipts[id] else { throw GameProjectTransferError.unknownTransfer }
            return receipt
        }
        try removeOwnedDirectory(directory)
        cleanupJobs[id] = nil
        guard let receipt = receipts[id] else { return nil }
        let updated = GameProjectTransferReceipt(id: receipt.id, sourceProjectID: receipt.sourceProjectID,
            sourceRevision: receipt.sourceRevision, destinationPreviousRevision: receipt.destinationPreviousRevision,
            project: receipt.project, engineHint: receipt.engineHint, requiresReopen: receipt.requiresReopen,
            cleanupPending: false)
        receipts[id] = updated
        return updated
    }

    private func validate(_ endpoint: GameProjectTransferEndpoint) async throws {
        try Task.checkCancellation()
        try endpoint.context.validate(current: await endpoint.contexts.currentContext(for: endpoint.context))
    }
    private static func require(_ project: GameStoredProject, context: GameProjectContext) throws {
        guard project.projectID == context.projectID, project.owner == context.owner else { throw GameProjectError.ownershipMismatch }
        guard project.revision == context.savedRevision else {
            throw GameProjectError.conflict(expected: context.savedRevision, actual: project.revision)
        }
    }
    private static func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = lhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = rhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }
    private static func verifyStagedTree(_ pending: Pending) throws {
        let limits = pending.destinationLimits
        let reader = try GameProjectReader(rootURL: pending.sourceTree, maximumFileBytes: limits.maximumFileBytes)
        let entries = try reader.tree(maximumEntries: limits.maximumEntries)
        let files = pending.sourceSnapshot.files
        guard Set(entries.filter(\.directory).map(\.path)) == Set(pending.sourceSnapshot.directories),
              Set(entries.filter { !$0.directory }.map(\.path)) == Set(files.map(\.path)) else {
            throw GameProjectError.corruptStorage
        }
        for file in files {
            try Task.checkCancellation()
            guard let bytes = try reader.read(file.path), bytes.count == file.bytes,
                  GameDigest.sha256(bytes) == file.sha256,
                  try reader.isExecutable(file.path) == file.executable else { throw GameProjectError.corruptStorage }
        }
    }
}

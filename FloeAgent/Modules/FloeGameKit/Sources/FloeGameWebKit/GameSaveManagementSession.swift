// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeGameCore

/// The narrow player surface used by save management. The real conformance
/// calls the existing bounded player operations; tests inject a typed fake to
/// exercise readiness, run-fence and failure paths without claiming a real
/// engine was exercised.
@MainActor
public protocol GameSavePlayerPort: AnyObject {
    var saveIdentity: GameWebStorageIdentity { get }
    var saveSourceRevision: String { get }
    var saveSupportsState: Bool { get }
    var saveIsReady: Bool { get }
    /// The actual player increments this for every start/stop generation.
    /// Save management must never accept bytes captured by an older run.
    var saveRunGeneration: Int { get }
    func saveSnapshotState() async throws -> Data
    func saveRestoreState(_ data: Data) async throws
    func saveCapturePNG() async throws -> Data
}

extension GameWebPlayer: GameSavePlayerPort {
    public var saveIdentity: GameWebStorageIdentity { storageIdentity }
    public var saveSourceRevision: String { package.prepared.source.savedRevision }
    public var saveSupportsState: Bool { supportsState }
    public var saveIsReady: Bool { loaded && gameReady }
    public var saveRunGeneration: Int { runGeneration }
    public func saveSnapshotState() async throws -> Data { try await snapshotState() }
    public func saveRestoreState(_ data: Data) async throws { try await restoreState(data) }
    public func saveCapturePNG() async throws -> Data { try await capturePNG() }
}

public enum GameSaveNativeReadiness: Equatable, Sendable {
    case notRunning
    case unsupported
    case ready
}

public enum GameSaveManagementError: Error, Equatable, Sendable {
    case invalidated
    case cancelled
    case busy
    case stateUnavailable
    case staleRun
    case captureFailed(String)
    case restoreFailed(String)
    case repository(GameSaveSlotError)
    case backupTooLarge(Int)
    case backupReadFailed(String)
    case invalidFileURL
    case unexpected(String)
}

extension GameSaveManagementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidated:
            return "The game run ended; this save management session is closed."
        case .cancelled:
            return "The save operation was cancelled."
        case .busy:
            return "Another save operation is still running."
        case .stateUnavailable:
            return "The running game does not expose a native state snapshot."
        case .staleRun:
            return "The game run changed before the snapshot completed."
        case .captureFailed(let detail):
            return "The game could not capture its state: \(detail)"
        case .restoreFailed(let detail):
            return "The game could not restore that snapshot: \(detail)"
        case .repository(let error):
            return error.errorDescription
        case .backupTooLarge(let bytes):
            return "The backup file is too large (\(bytes) bytes)."
        case .backupReadFailed(let detail):
            return "The backup file could not be read: \(detail)"
        case .invalidFileURL:
            return "The selected backup is not a file."
        case .unexpected(let detail):
            return "The save operation failed: \(detail)"
        }
    }
}

public enum GameSaveAutomaticResult: Equatable, Sendable {
    case saved(GameSaveSlotDescriptor)
    case unchanged(GameSaveSlotDescriptor)
    case disabled
    case notRunning
    case unsupported
    case busy
    case invalidated
    case failed(GameSaveManagementError)
}

public enum GameSaveManagementOutcome: Equatable, Sendable {
    case created(String)
    case overwrote(String)
    case loaded(String)
    case renamed(String)
    case deleted(String)
    case recovered(String)
    case imported(String)
    case importedLegacy(String)
    case legacyAlreadyImported(String)
}

/// Service-owned save management for one actual player run. It owns no new
/// interpreter, file browser or source save. Capture and restore are only
/// attempted while the player reports a ready native snapshot/restore surface;
/// every await is fenced against invalidation and a changed run.
@MainActor
public final class GameSaveManagementSession: ObservableObject {
    public let identity: GameWebStorageIdentity
    public let repository: FileGameSaveSlotRepository
    public let port: any GameSavePlayerPort

    @Published public private(set) var activeSlots: [GameSaveSlotDescriptor] = []
    @Published public private(set) var deletedSlots: [GameSaveSlotDescriptor] = []
    @Published public private(set) var readiness: GameSaveNativeReadiness
    @Published public private(set) var runGenerationIsCurrent = true
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: GameSaveManagementError?
    @Published public private(set) var lastOutcome: GameSaveManagementOutcome?
    @Published public var autosaveEnabled: Bool

    private let baselineIdentity: GameWebStorageIdentity
    private let baselineSourceRevision: String
    private var runGeneration: Int
    private var hasObservedReadyRun: Bool
    private var epoch = 0
    private var invalidated = false
    private var operationInFlight = false
    private var operationTask: Task<Void, Never>?

    public var sourceRevision: String { port.saveSourceRevision }
    public var supportsNativeState: Bool { readiness == .ready && runGenerationIsCurrent }

    public convenience init(player: GameWebPlayer,
                            directory: URL,
                            autosaveEnabled: Bool = true) throws {
        let saveRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRoot = player.package.prepared.source.rootURL
        guard !(saveRoot.path + "/").hasPrefix(sourceRoot.path + "/") else {
            throw GameSaveManagementError.repository(.invalidConfiguration)
        }
        let repository = try FileGameSaveSlotRepository(directory: directory,
                                                        identity: player.storageIdentity)
        try self.init(port: player, repository: repository, autosaveEnabled: autosaveEnabled)
    }

    public convenience init(port: any GameSavePlayerPort,
                            directory: URL,
                            autosaveEnabled: Bool = true) throws {
        let repository = try FileGameSaveSlotRepository(directory: directory,
                                                        identity: port.saveIdentity)
        try self.init(port: port, repository: repository, autosaveEnabled: autosaveEnabled)
    }

    public init(port: any GameSavePlayerPort,
                repository: FileGameSaveSlotRepository,
                autosaveEnabled: Bool = true) throws {
        guard port.saveIdentity == repository.identity else {
            throw GameSaveManagementError.repository(.scopeMismatch)
        }
        self.identity = repository.identity
        self.repository = repository
        self.port = port
        self.autosaveEnabled = autosaveEnabled
        baselineIdentity = repository.identity
        baselineSourceRevision = port.saveSourceRevision
        runGeneration = port.saveRunGeneration
        let initialReadiness = Self.readiness(for: port)
        hasObservedReadyRun = initialReadiness == .ready
        readiness = initialReadiness
    }

    public func isCompatible(_ descriptor: GameSaveSlotDescriptor) -> Bool {
        descriptor.sourceRevision == port.saveSourceRevision
    }

    // MARK: Readiness and listing

    public func refreshReadiness() {
        guard !invalidated else {
            readiness = .notRunning
            runGenerationIsCurrent = false
            return
        }
        let current = Self.readiness(for: port)
        synchronizeReadyRun()
        if hasObservedReadyRun {
            runGenerationIsCurrent = port.saveRunGeneration == runGeneration
        } else {
            runGenerationIsCurrent = true
        }
        readiness = current
    }

    public func refresh() async throws {
        guard !invalidated else { throw GameSaveManagementError.invalidated }
        do {
            let snapshot = try await repository.list(includeDeleted: true)
            guard !invalidated else { throw GameSaveManagementError.invalidated }
            apply(snapshot)
            lastError = nil
        } catch {
            throw fail(error)
        }
    }

    public func dismissNotice() {
        lastError = nil
        lastOutcome = nil
    }

    // MARK: Manual save/overwrite

    public func saveNew(title: String) async throws -> GameSaveSlotDescriptor {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            let captured = try await capture(includeThumbnail: true, epoch: epoch)
            try ensureCurrent(epoch)
            let slot = try await repository.create(state: captured.state,
                                                   title: title, kind: .manual,
                                                   sourceRevision: port.saveSourceRevision,
                                                   thumbnail: captured.thumbnail)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .created(slot.title)
            lastError = nil
            return slot
        } catch {
            throw fail(error)
        }
    }

    public func overwrite(_ id: UUID,
                          expectedRevision: UInt64? = nil) async throws -> GameSaveSlotDescriptor {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            let revision: UInt64
            if let expectedRevision { revision = expectedRevision }
            else { revision = try cachedRevision(for: id) }
            let captured = try await capture(includeThumbnail: true, epoch: epoch)
            try ensureCurrent(epoch)
            let slot = try await repository.update(id, state: captured.state,
                                                   thumbnail: captured.thumbnail,
                                                   sourceRevision: port.saveSourceRevision,
                                                   expectedRevision: revision)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .overwrote(slot.title)
            lastError = nil
            return slot
        } catch {
            let mapped = map(error)
            if case .repository(.staleRevision) = mapped {
                await reloadAfterFailure()
            }
            throw fail(mapped)
        }
    }

    // MARK: Load with safety checkpoint

    /// Captures a fresh autosave before restoring. The game's own built-in
    /// storage is never closed or cleared. A capture or safety-checkpoint
    /// failure aborts before restore, leaving current progress untouched.
    public func load(_ id: UUID,
                     checkpointTitle: String? = nil) async throws -> GameSaveSlotDescriptor {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            guard Self.readiness(for: port) == .ready else {
                throw GameSaveManagementError.stateUnavailable
            }
            let target = try await repository.load(id)
            try ensureCurrent(epoch)
            let captured = try await capture(includeThumbnail: false, epoch: epoch)
            try ensureCurrent(epoch)
            let title = Self.clippedTitle(checkpointTitle ?? "Before: \(target.descriptor.title)")
            _ = try await repository.saveAutomatic(state: captured.state, title: title,
                                                    sourceRevision: port.saveSourceRevision,
                                                    preserving: target.descriptor.kind == .autosave
                                                        ? target.descriptor.id : nil)
            try ensureCurrent(epoch)
            do {
                try await port.saveRestoreState(target.state)
            } catch {
                try ensureCurrent(epoch)
                if let playerError = error as? GameWebPlayerError {
                    switch playerError {
                    case .staleRun: throw GameSaveManagementError.staleRun
                    case .notReady: throw GameSaveManagementError.staleRun
                    default: break
                    }
                }
                guard Self.readiness(for: port) == .ready else {
                    throw GameSaveManagementError.staleRun
                }
                throw GameSaveManagementError.restoreFailed(String(describing: error))
            }
            try ensureCurrent(epoch)
            guard Self.readiness(for: port) == .ready else {
                throw GameSaveManagementError.staleRun
            }
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .loaded(target.descriptor.title)
            lastError = nil
            return target.descriptor
        } catch {
            throw fail(error)
        }
    }

    // MARK: Metadata operations

    public func rename(_ id: UUID,
                       to title: String,
                       expectedRevision: UInt64? = nil) async throws -> GameSaveSlotDescriptor {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            let revision: UInt64
            if let expectedRevision { revision = expectedRevision }
            else { revision = try cachedRevision(for: id) }
            let slot = try await repository.rename(id, to: title, expectedRevision: revision)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .renamed(slot.title)
            lastError = nil
            return slot
        } catch {
            let mapped = map(error)
            if case .repository(.staleRevision) = mapped { await reloadAfterFailure() }
            throw fail(mapped)
        }
    }

    public func delete(_ id: UUID,
                       expectedRevision: UInt64? = nil) async throws -> GameSaveSlotDescriptor {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            let revision: UInt64
            if let expectedRevision { revision = expectedRevision }
            else { revision = try cachedRevision(for: id) }
            let slot = try await repository.delete(id, expectedRevision: revision)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .deleted(slot.title)
            lastError = nil
            return slot
        } catch {
            let mapped = map(error)
            if case .repository(.staleRevision) = mapped { await reloadAfterFailure() }
            throw fail(mapped)
        }
    }

    public func recover(_ id: UUID,
                        expectedRevision: UInt64? = nil) async throws -> GameSaveSlotDescriptor {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            let revision: UInt64
            if let expectedRevision { revision = expectedRevision }
            else { revision = try cachedRevision(for: id) }
            let slot = try await repository.recover(id, expectedRevision: revision)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .recovered(slot.title)
            lastError = nil
            return slot
        } catch {
            let mapped = map(error)
            if case .repository(.staleRevision) = mapped { await reloadAfterFailure() }
            throw fail(mapped)
        }
    }

    public func thumbnail(for id: UUID) async throws -> Data? {
        do {
            guard !invalidated else { throw GameSaveManagementError.invalidated }
            return try await repository.thumbnail(id)
        } catch {
            throw fail(error)
        }
    }

    // MARK: Backup

    public func exportBackup(_ id: UUID) async throws -> GameSaveBackupPackage {
        try beginTracked()
        defer { endOperation() }
        do {
            let package = try await repository.exportBackup(id)
            lastError = nil
            return package
        } catch {
            throw fail(error)
        }
    }

    public func inspectBackup(at url: URL) async throws -> GameSaveBackupSummary {
        do {
            let data = try readBackupFile(url)
            let summary = try await repository.inspectBackup(data)
            lastError = nil
            return summary
        } catch {
            throw fail(error)
        }
    }

    public func importBackup(_ data: Data, title: String? = nil) async throws -> GameSaveImportResult {
        try beginTracked()
        defer { endOperation() }
        return try await performImport(data, title: title)
    }

    public func importBackup(from url: URL, title: String? = nil) async throws -> GameSaveImportResult {
        try beginTracked()
        defer { endOperation() }
        do {
            let data = try readBackupFile(url)
            return try await performImport(data, title: title)
        } catch {
            throw fail(error)
        }
    }

    public func importLegacy(title: String? = nil) async throws -> GameSaveLegacyImportResult {
        try beginTracked()
        defer { endOperation() }
        do {
            let epoch = try currentEpoch()
            let result = try await repository.importLegacySave(title: title)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = result.alreadyImported
                ? .legacyAlreadyImported(result.slot.title)
                : .importedLegacy(result.slot.title)
            lastError = nil
            return result
        } catch {
            throw fail(error)
        }
    }

    // MARK: Automatic save (host calls before stop, then invalidates)

    /// Never throws and never blocks a caller waiting for an unbounded engine
    /// promise. The existing player bounds the capture; unsupported and failed
    /// states are explicit so Stop can proceed without clearing game storage.
    public func saveAutomaticIfSupported(title: String? = nil) async -> GameSaveAutomaticResult {
        guard !invalidated else { return .invalidated }
        guard autosaveEnabled else { return .disabled }
        synchronizeReadyRun()
        switch Self.readiness(for: port) {
        case .notRunning: return .notRunning
        case .unsupported: return .unsupported
        case .ready: break
        }
        guard hasObservedReadyRun, port.saveRunGeneration == runGeneration else {
            runGenerationIsCurrent = false
            return .failed(.staleRun)
        }
        guard !operationInFlight else { return .busy }
        operationInFlight = true
        isBusy = true
        defer {
            operationInFlight = false
            isBusy = false
        }
        let epoch = self.epoch
        do {
            guard Self.readiness(for: port) == .ready else {
                return .failed(.staleRun)
            }
            let state: Data
            do { state = try await port.saveSnapshotState() }
            catch is CancellationError { throw CancellationError() }
            catch { throw Self.mapCaptureError(error) }
            try ensureCurrent(epoch)
            guard Self.readiness(for: port) == .ready else {
                return .failed(.staleRun)
            }
            if let latest = activeSlots.filter({ $0.kind == .autosave })
                .max(by: { $0.updatedAt < $1.updatedAt }),
               latest.stateDigest == GameDigest.sha256(state),
               latest.sourceRevision == port.saveSourceRevision {
                lastError = nil
                return .unchanged(latest)
            }
            let slot = try await repository.saveAutomatic(
                state: state, title: Self.clippedTitle(title ?? "Autosave"),
                sourceRevision: port.saveSourceRevision)
            if !invalidated, epoch == self.epoch,
               let snapshot = try? await repository.list(includeDeleted: true),
               !invalidated {
                apply(snapshot)
                refreshReadiness()
            }
            lastError = nil
            return .saved(slot)
        } catch is CancellationError {
            return invalidated ? .invalidated : .failed(.cancelled)
        } catch let error as GameSaveManagementError {
            if error == .invalidated { return .invalidated }
            lastError = error
            return .failed(error)
        } catch {
            let mapped = map(error)
            lastError = mapped
            return .failed(mapped)
        }
    }

    // MARK: UI-owned task entry points

    public func startRefresh() {
        launch { _ = try? await self.refresh() }
    }

    public func startCreate(title: String) {
        launch { _ = try? await self.saveNew(title: title) }
    }

    public func startOverwrite(_ id: UUID, expectedRevision: UInt64? = nil) {
        launch { _ = try? await self.overwrite(id, expectedRevision: expectedRevision) }
    }

    public func startLoad(_ id: UUID, checkpointTitle: String? = nil) {
        launch { _ = try? await self.load(id, checkpointTitle: checkpointTitle) }
    }

    public func startRename(_ id: UUID, to title: String) {
        launch { _ = try? await self.rename(id, to: title) }
    }

    public func startDelete(_ id: UUID) {
        launch { _ = try? await self.delete(id) }
    }

    public func startRecover(_ id: UUID) {
        launch { _ = try? await self.recover(id) }
    }

    public func startImport(data: Data, title: String? = nil) {
        launch { _ = try? await self.importBackup(data, title: title) }
    }

    public func startImportLegacy(title: String? = nil) {
        launch { _ = try? await self.importLegacy(title: title) }
    }

    /// Fences every late capture/restore result. The host calls this after the
    /// actual player has stopped; it never stops or clears the player itself.
    public func invalidate() {
        invalidated = true
        epoch += 1
        operationTask?.cancel()
        operationTask = nil
        operationInFlight = false
        isBusy = false
    }

    // MARK: Internals

    private struct Captured {
        let state: Data
        let thumbnail: Data?
    }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        guard !invalidated, operationTask == nil, !operationInFlight else { return }
        operationTask = Task { @MainActor [weak self] in
            await body()
            self?.operationTask = nil
        }
    }

    private func performImport(_ data: Data, title: String?) async throws -> GameSaveImportResult {
        do {
            let epoch = try currentEpoch()
            let result = try await repository.importBackup(data, title: title)
            try await reloadBestEffort(epoch: epoch)
            lastOutcome = .imported(result.slot.title)
            lastError = nil
            return result
        } catch {
            throw fail(error)
        }
    }

    private func capture(includeThumbnail: Bool, epoch: Int) async throws -> Captured {
        synchronizeReadyRun()
        guard Self.readiness(for: port) == .ready, hasObservedReadyRun else {
            throw GameSaveManagementError.stateUnavailable
        }
        guard port.saveRunGeneration == runGeneration else {
            runGenerationIsCurrent = false
            throw GameSaveManagementError.staleRun
        }
        let state: Data
        do {
            state = try await port.saveSnapshotState()
        } catch {
            try ensureCurrent(epoch)
            guard Self.readiness(for: port) == .ready else {
                throw GameSaveManagementError.staleRun
            }
            throw Self.mapCaptureError(error)
        }
        try ensureCurrent(epoch)
        guard Self.readiness(for: port) == .ready else {
            throw GameSaveManagementError.staleRun
        }
        guard state.count <= repository.maximumStateBytes else {
            throw GameSaveManagementError.repository(.stateTooLarge(state.count))
        }
        var thumbnail: Data?
        if includeThumbnail {
            do {
                let png = try await port.saveCapturePNG()
                try ensureCurrent(epoch)
                guard Self.readiness(for: port) == .ready else {
                    throw GameSaveManagementError.staleRun
                }
                thumbnail = Self.makeThumbnail(png,
                    maximumBytes: repository.limits.maximumThumbnailBytes)
            } catch is CancellationError {
                throw invalidated ? GameSaveManagementError.invalidated
                                   : GameSaveManagementError.cancelled
            } catch let error as GameSaveManagementError {
                throw error
            } catch {
                try ensureCurrent(epoch)
                guard Self.readiness(for: port) == .ready else {
                    throw GameSaveManagementError.staleRun
                }
                if let playerError = error as? GameWebPlayerError,
                   case .staleRun = playerError {
                    throw GameSaveManagementError.staleRun
                }
                // A preview is optional; the validated state snapshot remains.
                thumbnail = nil
            }
        }
        return Captured(state: state, thumbnail: thumbnail)
    }

    private func reload(epoch: Int) async throws {
        let snapshot = try await repository.list(includeDeleted: true)
        try ensureCurrent(epoch)
        apply(snapshot)
        refreshReadiness()
    }

    /// A committed mutation stays committed even if the follow-up catalog
    /// refresh fails. Only cancellation/invalidation is fenced here; the next
    /// refresh repairs a stale list.
    private func reloadBestEffort(epoch: Int) async throws {
        do {
            try await reload(epoch: epoch)
        } catch {
            let mapped = map(error)
            if mapped == .invalidated || mapped == .cancelled {
                throw mapped
            }
        }
    }

    private func reloadAfterFailure() async {
        guard !invalidated else { return }
        if let snapshot = try? await repository.list(includeDeleted: true), !invalidated {
            apply(snapshot)
            refreshReadiness()
        }
    }

    private func apply(_ snapshot: GameSaveSlotCatalogSnapshot) {
        activeSlots = snapshot.slots.filter { !$0.isDeleted }
        deletedSlots = snapshot.slots.filter(\.isDeleted)
    }

    private func cachedRevision(for id: UUID) throws -> UInt64 {
        if let slot = activeSlots.first(where: { $0.id == id }) { return slot.revision }
        if let slot = deletedSlots.first(where: { $0.id == id }) { return slot.revision }
        throw GameSaveManagementError.repository(.slotNotFound(id))
    }

    private func beginTracked() throws {
        do { try beginOperation() }
        catch { throw fail(error) }
    }

    private func beginOperation() throws {
        guard !invalidated else { throw GameSaveManagementError.invalidated }
        guard !operationInFlight else { throw GameSaveManagementError.busy }
        try Task.checkCancellation()
        synchronizeReadyRun()
        guard port.saveIdentity == baselineIdentity,
              port.saveSourceRevision == baselineSourceRevision else {
            throw GameSaveManagementError.staleRun
        }
        guard !hasObservedReadyRun || port.saveRunGeneration == runGeneration else {
            runGenerationIsCurrent = false
            throw GameSaveManagementError.staleRun
        }
        operationInFlight = true
        isBusy = true
        lastError = nil
        lastOutcome = nil
    }

    private func endOperation() {
        operationInFlight = false
        isBusy = false
    }

    private func currentEpoch() throws -> Int {
        guard !invalidated else { throw GameSaveManagementError.invalidated }
        try Task.checkCancellation()
        return epoch
    }

    private func ensureCurrent(_ epoch: Int) throws {
        guard !invalidated, epoch == self.epoch else {
            throw GameSaveManagementError.invalidated
        }
        if Task.isCancelled { throw GameSaveManagementError.cancelled }
        synchronizeReadyRun()
        guard port.saveIdentity == baselineIdentity,
              port.saveSourceRevision == baselineSourceRevision else {
            throw GameSaveManagementError.staleRun
        }
        guard hasObservedReadyRun,
              port.saveRunGeneration == runGeneration else {
            runGenerationIsCurrent = false
            throw GameSaveManagementError.staleRun
        }
    }

    /// A session created before the game started adopts the first ready run.
    /// Once a run has been observed, a later generation can never be accepted
    /// by this session even when source and identity are byte-identical.
    private func synchronizeReadyRun() {
        guard !hasObservedReadyRun, Self.readiness(for: port) == .ready else { return }
        runGeneration = port.saveRunGeneration
        hasObservedReadyRun = true
        runGenerationIsCurrent = true
    }

    private func fail(_ error: any Error) -> GameSaveManagementError {
        let mapped = map(error)
        lastError = mapped
        return mapped
    }

    private func map(_ error: any Error) -> GameSaveManagementError {
        if let error = error as? GameSaveManagementError { return error }
        if let error = error as? GameSaveSlotError { return .repository(error) }
        if error is CancellationError {
            return invalidated ? .invalidated : .cancelled
        }
        return .unexpected(String(describing: error))
    }

    private static func mapCaptureError(_ error: any Error) -> GameSaveManagementError {
        if error is CancellationError { return .cancelled }
        if let playerError = error as? GameWebPlayerError {
            switch playerError {
            case .staleRun: return .staleRun
            case .notReady: return .stateUnavailable
            default: break
            }
        }
        return .captureFailed(String(describing: error))
    }

    private static func readiness(for port: any GameSavePlayerPort) -> GameSaveNativeReadiness {
        if !port.saveIsReady { return .notRunning }
        if !port.saveSupportsState { return .unsupported }
        return .ready
    }

    private static func clippedTitle(_ text: String, maximumBytes: Int = 120) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maximumBytes { break }
            result.append(character)
            bytes += size
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Save" : trimmed
    }

    private static func makeThumbnail(_ png: Data, maximumBytes: Int) -> Data? {
        guard !png.isEmpty, png.count <= 32 * 1_024 * 1_024 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(png as CFData, sourceOptions) else {
            return nil
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 640,
                       kCGImageSourceShouldCacheImmediately: false] as [CFString: Any]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                options as CFDictionary) else { return nil }
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output,
                UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    private func readBackupFile(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw GameSaveManagementError.invalidFileURL }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if let isRegular = values?.isRegularFile, !isRegular {
            throw GameSaveManagementError.backupReadFailed("not a regular file")
        }
        if let size = values?.fileSize, size > repository.maximumBackupBytes {
            throw GameSaveManagementError.backupTooLarge(size)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw GameSaveManagementError.backupReadFailed("open")
        }
        defer { try? handle.close() }
        var data = Data()
        while true {
            let remaining = repository.maximumBackupBytes + 1 - data.count
            guard remaining > 0 else {
                throw GameSaveManagementError.backupTooLarge(data.count)
            }
            let chunk: Data?
            do { chunk = try handle.read(upToCount: min(65_536, remaining)) }
            catch { throw GameSaveManagementError.backupReadFailed("read") }
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
            if data.count > repository.maximumBackupBytes {
                throw GameSaveManagementError.backupTooLarge(data.count)
            }
        }
        guard !data.isEmpty else {
            throw GameSaveManagementError.backupReadFailed("empty")
        }
        return data
    }
}

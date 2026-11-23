// SPDX-License-Identifier: MPL-2.0

import Combine
import CryptoKit
import FloeDeviceLink
import Foundation

public struct DeviceHistoryIdentityStorage: Sendable {
    let load: @Sendable () throws -> Data?
    let save: @Sendable (Data) throws -> Void

    public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void) {
        self.load = load
        self.save = save
    }
}

/// Both endpoints are supplied together by a store that commits each page
/// and its checkpoint in the same transaction.
public struct DeviceHistoryPageDestination: Sendable {
    let cursor: @MainActor @Sendable (String, UUID) async throws -> String?
    let commit: @MainActor @Sendable (String, UUID, Data, String?) async throws -> Int

    public init(cursor: @escaping @MainActor @Sendable (String, UUID) async throws -> String?,
                commit: @escaping @MainActor @Sendable (String, UUID, Data, String?) async throws -> Int) {
        self.cursor = cursor
        self.commit = commit
    }
}

public struct DeviceHistoryPeer: Codable, Identifiable, Sendable, Equatable {
    public var id: String { address.endpointID }
    public var name: String
    let address: FloeDeviceLinkAddress
    public var sharedConversations: Set<UUID>
    var workspaceScopes: [UUID: String]? = nil
    /// Per-conversation workspace convergence consent. Absent or `1` keeps
    /// the original copy-only semantics; `2` was explicitly (re)granted
    /// after delete/rename propagation existed and opts into convergence.
    var workspaceSyncVersions: [UUID: Int]? = nil
    var attachmentConsents: Set<UUID>? = nil

    public func sharesWorkspace(for conversationID: UUID) -> Bool {
        sharedConversations.contains(conversationID) && workspaceScopes?[conversationID] != nil
    }

    public func convergesWorkspace(for conversationID: UUID) -> Bool {
        sharesWorkspace(for: conversationID) && workspaceSyncVersions?[conversationID] == 2
    }

    public func sharesAttachments(for conversationID: UUID) -> Bool {
        sharesWorkspace(for: conversationID) && attachmentConsents?.contains(conversationID) == true
    }
}

public struct DeviceHistoryPairingTicket: Codable, Sendable, Identifiable {
    public var id: String { address.endpointID }
    public var fingerprint: String { address.endpointID }
    private let version: Int
    let address: FloeDeviceLinkAddress
    private static let prefix = "floe-device:"

    init(address: FloeDeviceLinkAddress) {
        version = 1
        self.address = address
    }

    public init(code: String) throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count <= 8_192, code.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(code.dropFirst(Self.prefix.count))) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard version == 1 else { throw DeviceHistorySyncError.unsupportedVersion }
        guard !id.isEmpty, id.utf8.count <= 128,
              (try? FloeDeviceLink.canonicalEndpointID(id)) == id,
              address.directAddresses.count <= 16,
              address.directAddresses.allSatisfy({ $0.utf8.count <= 256 }),
              (address.relayURL?.utf8.count ?? 0) <= 512 else {
            throw DeviceHistorySyncError.invalidResponse
        }
    }

    func code() throws -> String {
        let data = try JSONEncoder().encode(self)
        return Self.prefix + data.base64EncodedString()
    }
}

/// App settings and explicit user actions. Both platforms use the same
/// device pairing and per-conversation sharing rules.
@MainActor
public final class DeviceHistorySyncCenter: ObservableObject {
    private struct Settings: Codable {
        var enabled = false
        var usesPublicRelay = false
        var customRelayURL: URL?
        var peers: [DeviceHistoryPeer] = []
        var listeningPort: UInt16?
    }

    public enum Status: Equatable {
        case idle, ready, unableToStart, transferFailed, conflict, incompatibleVersion
        case noLongerShared, tooLarge, workspaceBusy, workspaceUnavailable
        case interrupted(Int), cancelled(Int), received(Int)
    }

    public enum WorkspaceResult: Equatable {
        case received(DeviceWorkspaceReceiveProgress)
        case interrupted(DeviceWorkspaceReceiveProgress?, Status)
        case cancelled(DeviceWorkspaceReceiveProgress?)
    }

    public struct ReceiveProgress: Equatable {
        public let peerID: String
        public fileprivate(set) var committedPages = 0
        public fileprivate(set) var addedMessages = 0
        /// Original user attachments whose bytes were verified, stored, and
        /// bound to their message parts during this receive.
        public fileprivate(set) var restoredAttachments = 0
        /// Attachments that stayed unrestored (peer lacks them, transport
        /// failed, or verification failed). No usable link is presented for
        /// these; a later receive retries them.
        public fileprivate(set) var failedAttachments = 0
    }

    @Published private var settings = Settings()
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var busy = false
    @Published public private(set) var pairingCode: String?
    @Published public private(set) var fingerprint: String?
    @Published public private(set) var receiveProgress: ReceiveProgress?
    @Published public private(set) var attachmentResult: ReceiveProgress?
    @Published public private(set) var workspaceProgress: DeviceWorkspaceReceiveProgress?
    @Published public private(set) var workspaceResult: WorkspaceResult?
    public private(set) var workspacePeerID: String?

    public var enabled: Bool { settings.enabled }
    public var usesPublicRelay: Bool { settings.usesPublicRelay }
    public var customRelayURL: URL? { settings.customRelayURL }
    public var peers: [DeviceHistoryPeer] { settings.peers }
    public var supportsWorkspaceSync: Bool { workspaceHost != nil }
    public var supportsWorkspaceChanges: Bool { workspaceHost?.canPropagateWorkspaceChanges == true }
    /// A host that can export user-picked files outside the workspace uses
    /// a separate grant. An old copy-only workspace grant reads as off.
    public let requiresAttachmentConsent: Bool

    private let settingsURL: URL
    private let identityStorage: DeviceHistoryIdentityStorage
    private let source: DeviceHistorySource
    private let localTasks: @MainActor () async throws -> [DeviceHistoryOffer]
    private let importHistory: @MainActor (UUID, Data) async throws -> Int
    private let pagedHistory: DeviceHistoryPageDestination?
    private let workspaceHost: DeviceWorkspaceSyncHost?
    private let attachmentRestore: DeviceAttachmentRestore?
    private let didImport: @MainActor (UUID) async -> Void
    private var service: DeviceHistorySync?
    private var receiveTask: Task<Void, Never>?
    private var loadFailed = false
    private var running = false
    private var activationPending = false
    private var revision = 0
    private var lastWorkspaceUpdate: ContinuousClock.Instant?
    private var currentWorkspaceProgress: DeviceWorkspaceReceiveProgress?

    public init(settingsURL: URL, identityStorage: DeviceHistoryIdentityStorage, source: DeviceHistorySource,
                localTasks: @escaping @MainActor () async throws -> [DeviceHistoryOffer],
                importHistory: @escaping @MainActor (UUID, Data) async throws -> Int,
                pagedHistory: DeviceHistoryPageDestination? = nil,
                workspaceHost: DeviceWorkspaceSyncHost? = nil,
                attachmentRestore: DeviceAttachmentRestore? = nil,
                requiresAttachmentConsent: Bool = false,
                didImport: @escaping @MainActor (UUID) async -> Void = { _ in }) {
        self.settingsURL = settingsURL
        self.identityStorage = identityStorage
        self.source = source
        self.localTasks = localTasks
        self.importHistory = importHistory
        self.pagedHistory = pagedHistory
        self.workspaceHost = workspaceHost
        self.attachmentRestore = attachmentRestore
        self.requiresAttachmentConsent = requiresAttachmentConsent
        self.didImport = didImport
        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(Settings.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A fresh installation starts disabled.
        } catch {
            loadFailed = true
            status = .unableToStart
        }
    }

    public func activate() async {
        running = true
        guard settings.enabled, service == nil, !loadFailed else { return }
        if busy {
            activationPending = true
            return
        }
        busy = true
        defer { finishWork() }
        do { try await restart() }
        catch { status = .unableToStart }
    }

    public func pause() async {
        running = false
        activationPending = false
        revision += 1
        receiveTask?.cancel()
        workspaceResult = nil
        let previous = service
        service = nil
        pairingCode = nil
        fingerprint = nil
        status = .idle
        await previous?.stop()
    }

    public func setEnabled(_ enabled: Bool) async {
        var next = settings
        next.enabled = enabled
        await update(next)
    }

    public func setPublicRelay(_ enabled: Bool) async {
        var next = settings
        next.usesPublicRelay = enabled
        if enabled { next.customRelayURL = nil }
        await update(next)
    }

    public func setCustomRelay(_ text: String) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = settings
        if text.isEmpty {
            next.customRelayURL = nil
        } else {
            guard let url = URL(string: text), url.scheme == "https", url.host() != nil,
                  url.user() == nil, url.password() == nil, url.query() == nil, url.fragment() == nil else {
                throw DeviceHistorySyncError.invalidResponse
            }
            next.customRelayURL = url
            next.usesPublicRelay = false
        }
        await update(next)
    }

    public func refreshPairingCode() async {
        guard let service else { return }
        var address = await service.localAddress
        for _ in 0..<10 where address.directAddresses.isEmpty && address.relayURL == nil {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            guard service === self.service else { return }
            address = await service.localAddress
        }
        guard service === self.service else { return }
        fingerprint = address.endpointID
        pairingCode = address.directAddresses.isEmpty && address.relayURL == nil ? nil :
            try? DeviceHistoryPairingTicket(address: address).code()
    }

    public func pair(_ ticket: DeviceHistoryPairingTicket, named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, ticket.id != fingerprint else {
            status = .unableToStart
            return
        }
        var next = settings
        let previous = next.peers.first { $0.id == ticket.id }
        next.peers.removeAll { $0.id == ticket.id }
        next.peers.append(DeviceHistoryPeer(name: String(name.prefix(100)), address: ticket.address,
                                            sharedConversations: previous?.sharedConversations ?? [],
                                            workspaceScopes: previous?.workspaceScopes,
                                            workspaceSyncVersions: previous?.workspaceSyncVersions,
                                            attachmentConsents: previous?.attachmentConsents))
        await update(next, rebind: false)
    }

    public func remove(_ peerID: String) async {
        var next = settings
        next.peers.removeAll { $0.id == peerID }
        await update(next, rebind: false)
    }

    public func share(_ taskID: UUID, with peerID: String, enabled: Bool) async {
        guard !busy, let index = settings.peers.firstIndex(where: { $0.id == peerID }) else { return }
        busy = true
        defer { finishWork() }
        var next = settings
        if enabled {
            guard next.peers[index].sharedConversations.count < DeviceHistorySync.maximumSharedTasks else {
                status = .transferFailed
                return
            }
            next.peers[index].sharedConversations.insert(taskID)
        } else {
            next.peers[index].sharedConversations.remove(taskID)
            next.peers[index].workspaceScopes?.removeValue(forKey: taskID)
            next.peers[index].workspaceSyncVersions?.removeValue(forKey: taskID)
            next.peers[index].attachmentConsents?.remove(taskID)
        }
        do {
            try save(next)
            try await service?.replaceShares(shares, workspaces: workspaceShares, versions: workspaceVersions,
                                             attachments: attachmentShares)
        } catch {
            status = .transferFailed
        }
    }

    public func shareWorkspace(_ taskID: UUID, with peerID: String, enabled: Bool,
                               propagateChanges: Bool = false) async {
        guard !busy, let workspaceHost,
              let index = settings.peers.firstIndex(where: { $0.id == peerID }),
              settings.peers[index].sharedConversations.contains(taskID) else { return }
        busy = true
        defer { finishWork() }
        let revision = revision
        var next = settings
        do {
            var scopes = next.peers[index].workspaceScopes ?? [:]
            var versions = next.peers[index].workspaceSyncVersions ?? [:]
            if enabled {
                let scope = try await workspaceHost.shareScope(for: taskID)
                if scopes[taskID] != scope { next.peers[index].attachmentConsents?.remove(taskID) }
                scopes[taskID] = scope
                versions[taskID] = propagateChanges && supportsWorkspaceChanges ? DeviceWorkspaceConvergence.v2.rawValue : nil
            } else {
                scopes.removeValue(forKey: taskID)
                versions.removeValue(forKey: taskID)
                next.peers[index].attachmentConsents?.remove(taskID)
            }
            guard revision == self.revision else { return }
            next.peers[index].workspaceScopes = scopes
            next.peers[index].workspaceSyncVersions = versions
            try save(next)
            try await service?.replaceShares(shares, workspaces: workspaceShares, versions: workspaceVersions,
                                             attachments: attachmentShares)
            status = .ready
        } catch {
            status = Self.failureStatus(error)
        }
    }

    public func shareAttachments(_ taskID: UUID, with peerID: String, enabled: Bool) async {
        guard requiresAttachmentConsent, !busy,
              let index = settings.peers.firstIndex(where: { $0.id == peerID }),
              settings.peers[index].sharesWorkspace(for: taskID) else { return }
        var next = settings
        var consents = next.peers[index].attachmentConsents ?? []
        if enabled { consents.insert(taskID) }
        else { consents.remove(taskID) }
        next.peers[index].attachmentConsents = consents
        await update(next, rebind: false)
    }

    public func localConversations() async -> [DeviceHistoryOffer] {
        (try? await localTasks()) ?? []
    }

    public func staleWorkspaceShares(for peerID: String) async -> Set<UUID> {
        guard let workspaceHost, let scopes = peers.first(where: { $0.id == peerID })?.workspaceScopes else { return [] }
        var stale: Set<UUID> = []
        for (id, expected) in scopes {
            if (try? await workspaceHost.shareScope(for: id)) != expected { stale.insert(id) }
        }
        return stale
    }

    public func remoteConversations(from peerID: String) async -> [DeviceHistoryOffer]? {
        guard !busy, let service, let peer = peers.first(where: { $0.id == peerID }) else { return nil }
        busy = true
        defer { finishWork() }
        let revision = revision
        do {
            let result = try await service.offers(from: peer.address)
            guard revision == self.revision else { return nil }
            status = .ready
            return result
        } catch {
            if revision == self.revision { status = Self.failureStatus(error) }
            return nil
        }
    }

    public func receive(_ taskID: UUID, from peerID: String, includeWorkspace: Bool = false) async {
        guard !busy, let service, let peer = peers.first(where: { $0.id == peerID }) else { return }
        busy = true
        receiveProgress = ReceiveProgress(peerID: peerID)
        workspaceResult = nil
        workspaceProgress = nil
        currentWorkspaceProgress = nil
        lastWorkspaceUpdate = nil
        workspacePeerID = includeWorkspace ? peerID : nil
        let revision = revision
        let task = Task { [weak self] in
            guard let self else { return }
            await self.receiveSelection(taskID, from: peer, service: service, revision: revision, includeWorkspace: includeWorkspace)
        }
        receiveTask = task
        await task.value
    }

    public func cancelReceive() {
        receiveTask?.cancel()
    }

    private func receiveSelection(_ taskID: UUID, from peer: DeviceHistoryPeer,
                                  service: DeviceHistorySync, revision: Int, includeWorkspace: Bool) async {
        attachmentResult = nil
        defer {
            receiveTask = nil
            receiveProgress = nil
            finishWork()
        }
        do {
            try await service.withReceiveSession(to: peer.address) { [weak self] session in
                guard let self else { throw CancellationError() }
                await self.pullHistory(taskID, from: peer.id, session: session, revision: revision, includeWorkspace: includeWorkspace)
            }
        } catch is CancellationError {
            if revision == self.revision { status = .cancelled(0) }
        } catch {
            if revision == self.revision { status = Self.failureStatus(error) }
        }
    }

    private func pullHistory(_ taskID: UUID, from peerID: String, session: DeviceHistorySync.ReceiveSession,
                             revision: Int, includeWorkspace: Bool) async {
        var outcome: Status
        var capabilities: DeviceHistorySync.PeerCapabilities?
        var importsAttachments = false
        do {
            if pagedHistory != nil || includeWorkspace { capabilities = try await session.capabilities() }
            importsAttachments = includeWorkspace && attachmentRestore != nil && capabilities?.attachmentTransfer == true
                && capabilities?.offers.contains(where: { $0.id == taskID && $0.attachmentTransfer == true }) == true
            let version = importsAttachments ? 2 : 1
            // A prior text-only cursor must not skip old attachment-bearing
            // messages when the user first opts into files.
            let cursorPeer = importsAttachments ? peerID + ":attachments-v2" : peerID
            if let pagedHistory {
                let cursor = try await pagedHistory.cursor(cursorPeer, taskID)
                try await session.transferHistory(taskID, after: cursor, version: version, capabilities: capabilities) { [weak self] delivery in
                    guard let self else { throw CancellationError() }
                    try await self.commit(delivery, conversationID: taskID, peerID: peerID,
                                          revision: revision, cursorPeer: cursorPeer)
                }
            } else {
                let data = try await session.history(taskID, version: version)
                try await commit(.archive(data), conversationID: taskID, peerID: peerID, revision: revision)
            }
            outcome = .received(receiveProgress?.addedMessages ?? 0)
        } catch is CancellationError {
            outcome = .cancelled(receiveProgress?.addedMessages ?? 0)
        } catch {
            outcome = Self.failureStatus(error)
            if outcome == .transferFailed, let progress = receiveProgress, progress.committedPages > 0 {
                outcome = .interrupted(progress.addedMessages)
            }
        }
        if let progress = receiveProgress, progress.committedPages > 0 {
            // Deliver the already committed rows even if the wire task was cancelled.
            await Task { await didImport(taskID) }.value
        }
        if revision == self.revision {
            status = outcome
            if case .received = outcome, includeWorkspace {
                if let attachmentRestore, importsAttachments {
                    await pullAttachments(taskID, session: session, restore: attachmentRestore,
                                          capabilities: capabilities, revision: revision)
                    if let progress = receiveProgress, progress.restoredAttachments > 0 || progress.failedAttachments > 0 {
                        attachmentResult = progress
                        if progress.restoredAttachments > 0 { await Task { await didImport(taskID) }.value }
                    }
                }
                receiveProgress = nil
                if let workspaceHost {
                    let offer = capabilities?.offers.first(where: { $0.id == taskID })
                    let convergence: DeviceWorkspaceConvergence = offer?.workspaceSyncVersion == 2
                        ? workspaceConvergence(for: peerID, conversationID: taskID) : .v1
                    await pullWorkspace(taskID, session: session, host: workspaceHost,
                                        convergence: convergence, revision: revision)
                }
            }
        }
    }

    /// Pulls the original user attachment bytes declared by the imported v2
    /// history. Runs only when the peer advertised the capability and the
    /// workspace share is active; per-item failures are counted and retried
    /// on a later receive, never surfaced as half-links.
    private func pullAttachments(_ taskID: UUID, session: DeviceHistorySync.ReceiveSession,
                                 restore: DeviceAttachmentRestore,
                                 capabilities: DeviceHistorySync.PeerCapabilities?, revision: Int) async {
        guard revision == self.revision,
              capabilities?.attachmentTransfer == true,
              capabilities?.offers.contains(where: { $0.id == taskID && $0.workspaceFiles == true }) == true else { return }
        let items: [DeviceAttachmentRestore.Item]
        do {
            items = try await restore.pending(taskID)
        } catch {
            return
        }
        let valid = items.filter {
            $0.byteCount >= 0 && $0.byteCount <= DeviceAttachmentRestoreLimit.maximumItemBytes
                && DeviceWorkspaceDigest.isValid($0.digest)
        }
        var budget = DeviceAttachmentRestoreLimit.maximumTotalBytes
        var restored = 0
        var failed = 0
        defer {
            if var progress = receiveProgress, restored > 0 || failed > 0 {
                progress.restoredAttachments += restored
                progress.failedAttachments += failed
                receiveProgress = progress
            }
        }
        for item in valid.prefix(DeviceAttachmentRestoreLimit.maximumItems) {
            guard revision == self.revision, !Task.isCancelled else { return }
            guard Int64(item.byteCount) <= budget else { break }
            do {
                var data = Data()
                data.reserveCapacity(min(item.byteCount, 8 * 1_024 * 1_024))
                var offset = 0
                while offset < item.byteCount {
                    try Task.checkCancellation()
                    let count = min(DeviceWorkspaceManifest.chunkSize, item.byteCount - offset)
                    let bytes = try await session.attachmentChunk(taskID: taskID, attachmentID: item.attachmentID,
                                                                  offset: offset, count: count)
                    data.append(bytes)
                    offset += bytes.count
                    guard offset <= item.byteCount else { throw DeviceHistorySyncError.invalidResponse }
                }
                guard data.count == item.byteCount,
                      DeviceWorkspaceDigest.hex(SHA256.hash(data: data)) == item.digest else {
                    throw DeviceHistorySyncError.invalidResponse
                }
                try Task.checkCancellation()
                guard revision == self.revision else { throw CancellationError() }
                budget -= Int64(item.byteCount)
                if try await restore.restore(taskID, item, data) {
                    restored += 1
                } else {
                    failed += 1
                }
            } catch is CancellationError {
                return
            } catch DeviceHistorySyncError.notShared, DeviceHistorySyncError.disconnected {
                // Authorization vanished mid-phase: stop pulling; the
                // workspace phase reports the revocation honestly.
                return
            } catch {
                failed += 1
            }
        }
    }

    private func pullWorkspace(_ taskID: UUID, session: DeviceHistorySync.ReceiveSession,
                               host: DeviceWorkspaceSyncHost,
                               convergence: DeviceWorkspaceConvergence, revision: Int) async {
        let result: WorkspaceResult
        do {
            try Task.checkCancellation()
            try await session.transferWorkspace(taskID, convergence: convergence) { [weak self] value in
                await self?.updateWorkspaceProgress(value, revision: revision)
            }
            guard let report = currentWorkspaceProgress else { throw DeviceHistorySyncError.invalidResponse }
            result = .received(report)
        } catch is CancellationError {
            result = .cancelled(currentWorkspaceProgress)
        } catch {
            result = .interrupted(currentWorkspaceProgress, Self.failureStatus(error))
        }
        if currentWorkspaceProgress != nil {
            await Task { await host.didImport(taskID) }.value
        }
        if revision == self.revision { workspaceResult = result }
        workspaceProgress = nil
        currentWorkspaceProgress = nil
    }

    private func updateWorkspaceProgress(_ progress: DeviceWorkspaceReceiveProgress, revision: Int) {
        guard self.revision == revision else { return }
        currentWorkspaceProgress = progress
        let now = ContinuousClock.now
        if progress.processed == progress.total || lastWorkspaceUpdate.map({ $0.duration(to: now) >= .milliseconds(100) }) != false {
            workspaceProgress = progress
            lastWorkspaceUpdate = now
        }
    }

    private func commit(_ delivery: DeviceHistoryDelivery, conversationID: UUID,
                        peerID: String, revision: Int, cursorPeer: String? = nil) async throws {
        try Task.checkCancellation()
        guard self.revision == revision, enabled, peers.contains(where: { $0.id == peerID }) else {
            throw CancellationError()
        }
        let added: Int
        switch delivery {
        case .archive(let data):
            added = try await importHistory(conversationID, data)
        case .page(let data, let nextCursor):
            guard let pagedHistory else { throw DeviceHistorySyncError.unsupportedVersion }
            added = try await pagedHistory.commit(cursorPeer ?? peerID, conversationID, data, nextCursor)
        }
        if var progress = receiveProgress {
            progress.addedMessages += added
            progress.committedPages += 1
            receiveProgress = progress
        }
    }

    private static func failureStatus(_ error: any Error) -> Status {
        switch error {
        case DeviceHistorySyncError.conflict: .conflict
        case DeviceHistorySyncError.unsupportedVersion: .incompatibleVersion
        case DeviceHistorySyncError.notShared: .noLongerShared
        case DeviceHistorySyncError.tooLarge: .tooLarge
        case DeviceHistorySyncError.busy: .workspaceBusy
        case DeviceHistorySyncError.unavailable: .workspaceUnavailable
        default: .transferFailed
        }
    }

    private var shares: [String: Set<UUID>] {
        Dictionary(settings.peers.map { ($0.id, $0.sharedConversations) }, uniquingKeysWith: { first, _ in first })
    }

    private var workspaceShares: [String: [UUID: String]] {
        Dictionary(settings.peers.compactMap { peer in
            let scopes = peer.workspaceScopes?.filter { peer.sharedConversations.contains($0.key) } ?? [:]
            return scopes.isEmpty ? nil : (peer.id, scopes)
        }, uniquingKeysWith: { first, _ in first })
    }

    private var workspaceVersions: [String: [UUID: Int]] {
        Dictionary(settings.peers.compactMap { peer in
            let versions = peer.workspaceSyncVersions?.filter {
                peer.sharedConversations.contains($0.key) && peer.workspaceScopes?[$0.key] != nil
            } ?? [:]
            return versions.isEmpty ? nil : (peer.id, versions)
        }, uniquingKeysWith: { first, _ in first })
    }

    private var attachmentShares: [String: Set<UUID>]? {
        guard requiresAttachmentConsent else { return nil }
        return Dictionary(settings.peers.map { peer in
            (peer.id, (peer.attachmentConsents ?? []).filter { peer.sharesWorkspace(for: $0) })
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Local convergence consent for a peer conversation: explicit v2
    /// (re)grant on both ends plus the existing workspace share.
    public func workspaceConvergence(for peerID: String, conversationID: UUID) -> DeviceWorkspaceConvergence {
        guard let peer = settings.peers.first(where: { $0.id == peerID }),
              peer.convergesWorkspace(for: conversationID) else { return .v1 }
        return .v2
    }

    private func update(_ next: Settings, rebind: Bool = true) async {
        guard !busy, !loadFailed else { return }
        busy = true
        defer { finishWork() }
        do {
            try save(next)
            if !rebind, let service {
                try await service.replaceShares(shares, workspaces: workspaceShares, versions: workspaceVersions,
                                                attachments: attachmentShares)
                status = .ready
            } else {
                try await restart()
            }
        } catch {
            status = .unableToStart
        }
    }

    private func save(_ value: Settings) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: settingsURL, options: .atomic)
        settings = value
    }

    private func finishWork() {
        busy = false
        if activationPending {
            activationPending = false
            Task { [weak self] in
                guard let self, self.running else { return }
                await self.activate()
            }
        }
    }

    private func restart() async throws {
        revision += 1
        let revision = revision
        let previous = service
        service = nil
        pairingCode = nil
        fingerprint = nil
        await previous?.stop()
        guard running, settings.enabled, revision == self.revision else {
            status = .idle
            return
        }
        let identity: FloeDeviceLinkIdentity
        if let saved = try identityStorage.load() {
            identity = try FloeDeviceLinkIdentity(privateKeyBytes: saved)
        } else {
            identity = .generate()
            try identityStorage.save(identity.privateKeyBytes())
        }
        let relay: FloeDeviceLinkRelay = settings.customRelayURL.map(FloeDeviceLinkRelay.custom)
            ?? (settings.usesPublicRelay ? .publicIroh : .disabled)
        let link = try await FloeDeviceLink.bind(identity: identity, trustedEndpointIDs: Set(peers.map(\.id)),
            relay: relay,
            bindAddress: settings.listeningPort.map { "0.0.0.0:\($0)" })
        guard running, settings.enabled, revision == self.revision else {
            try await link.close()
            return
        }
        if settings.listeningPort == nil, let port = link.listeningPort {
            var next = settings
            next.listeningPort = port
            do { try save(next) }
            catch {
                try? await link.close()
                throw error
            }
        }
        let service = DeviceHistorySync(link: link, shares: shares, source: source, workspaceHost: workspaceHost,
                                        workspaceShares: workspaceShares, versions: workspaceVersions,
                                        attachmentShares: attachmentShares)
        self.service = service
        await service.start()
        guard revision == self.revision else { return }
        status = .ready
        await refreshPairingCode()
    }
}

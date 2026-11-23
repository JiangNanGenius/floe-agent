// SPDX-License-Identifier: MPL-2.0

import Combine
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

    public func sharesWorkspace(for conversationID: UUID) -> Bool {
        sharedConversations.contains(conversationID) && workspaceScopes?[conversationID] != nil
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
    }

    @Published private var settings = Settings()
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var busy = false
    @Published public private(set) var pairingCode: String?
    @Published public private(set) var fingerprint: String?
    @Published public private(set) var receiveProgress: ReceiveProgress?
    @Published public private(set) var workspaceProgress: DeviceWorkspaceReceiveProgress?
    @Published public private(set) var workspaceResult: WorkspaceResult?
    public private(set) var workspacePeerID: String?

    public var enabled: Bool { settings.enabled }
    public var usesPublicRelay: Bool { settings.usesPublicRelay }
    public var customRelayURL: URL? { settings.customRelayURL }
    public var peers: [DeviceHistoryPeer] { settings.peers }
    public var supportsWorkspaceSync: Bool { workspaceHost != nil }

    private let settingsURL: URL
    private let identityStorage: DeviceHistoryIdentityStorage
    private let source: DeviceHistorySource
    private let localTasks: @MainActor () async throws -> [DeviceHistoryOffer]
    private let importHistory: @MainActor (UUID, Data) async throws -> Int
    private let pagedHistory: DeviceHistoryPageDestination?
    private let workspaceHost: DeviceWorkspaceSyncHost?
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
                didImport: @escaping @MainActor (UUID) async -> Void = { _ in }) {
        self.settingsURL = settingsURL
        self.identityStorage = identityStorage
        self.source = source
        self.localTasks = localTasks
        self.importHistory = importHistory
        self.pagedHistory = pagedHistory
        self.workspaceHost = workspaceHost
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
                                            workspaceScopes: previous?.workspaceScopes))
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
        }
        do {
            try save(next)
            try await service?.replaceShares(shares, workspaces: workspaceShares)
        } catch {
            status = .transferFailed
        }
    }

    public func shareWorkspace(_ taskID: UUID, with peerID: String, enabled: Bool) async {
        guard !busy, let workspaceHost,
              let index = settings.peers.firstIndex(where: { $0.id == peerID }),
              settings.peers[index].sharedConversations.contains(taskID) else { return }
        busy = true
        defer { finishWork() }
        let revision = revision
        var next = settings
        do {
            var scopes = next.peers[index].workspaceScopes ?? [:]
            if enabled { scopes[taskID] = try await workspaceHost.shareScope(for: taskID) }
            else { scopes.removeValue(forKey: taskID) }
            guard revision == self.revision else { return }
            next.peers[index].workspaceScopes = scopes
            try save(next)
            try await service?.replaceShares(shares, workspaces: workspaceShares)
            status = .ready
        } catch {
            status = Self.failureStatus(error)
        }
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
            await self.pullHistory(taskID, from: peer, service: service, revision: revision, includeWorkspace: includeWorkspace)
        }
        receiveTask = task
        await task.value
    }

    public func cancelReceive() {
        receiveTask?.cancel()
    }

    private func pullHistory(_ taskID: UUID, from peer: DeviceHistoryPeer,
                             service: DeviceHistorySync, revision: Int, includeWorkspace: Bool) async {
        defer {
            receiveTask = nil
            receiveProgress = nil
            finishWork()
        }
        var outcome: Status
        do {
            if let pagedHistory {
                let cursor = try await pagedHistory.cursor(peer.id, taskID)
                try await service.transferHistory(taskID, from: peer.address, after: cursor) { [weak self] delivery in
                    guard let self else { throw CancellationError() }
                    try await self.commit(delivery, conversationID: taskID, peerID: peer.id, revision: revision)
                }
            } else {
                let data = try await service.history(taskID, from: peer.address)
                try await commit(.archive(data), conversationID: taskID, peerID: peer.id, revision: revision)
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
            if case .received = outcome, includeWorkspace, let workspaceHost {
                receiveProgress = nil
                await pullWorkspace(taskID, from: peer, service: service, host: workspaceHost, revision: revision)
            }
        }
    }

    private func pullWorkspace(_ taskID: UUID, from peer: DeviceHistoryPeer,
                               service: DeviceHistorySync, host: DeviceWorkspaceSyncHost, revision: Int) async {
        let result: WorkspaceResult
        do {
            try await service.transferWorkspace(taskID, from: peer.address) { [weak self] value in
                await self?.updateWorkspaceProgress(value, revision: revision)
            }
            guard let report = currentWorkspaceProgress else { throw DeviceHistorySyncError.invalidResponse }
            result = .received(report)
        } catch is CancellationError {
            result = .cancelled(currentWorkspaceProgress)
        } catch {
            result = .interrupted(currentWorkspaceProgress, Self.failureStatus(error))
        }
        await Task { await host.didImport(taskID) }.value
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
                        peerID: String, revision: Int) async throws {
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
            added = try await pagedHistory.commit(peerID, conversationID, data, nextCursor)
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

    private func update(_ next: Settings, rebind: Bool = true) async {
        guard !busy, !loadFailed else { return }
        busy = true
        defer { finishWork() }
        do {
            try save(next)
            if !rebind, let service {
                try await service.replaceShares(shares, workspaces: workspaceShares)
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
                                        workspaceShares: workspaceShares)
        self.service = service
        await service.start()
        guard revision == self.revision else { return }
        status = .ready
        await refreshPairingCode()
    }
}

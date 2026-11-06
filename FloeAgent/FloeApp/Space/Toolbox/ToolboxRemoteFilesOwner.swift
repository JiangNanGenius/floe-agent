// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeSSH
import FloeWorkspace
import FloeToolboxCore
import FloeToolboxSSH
import FloeToolboxRemoteFiles
import FloeToolboxFileTransports
import FloeToolboxUI

@MainActor final class ToolboxRemoteFilesOwner: ObservableObject {
    let fileAccess = ToolboxFileAccess()
    let lease: SessionLease
    let remoteMachine: MachineReference
    let title: String
    @Published private(set) var localMachine: MachineReference
    @Published private(set) var localDirectory: RemoteFilePath
    @Published private(set) var remoteDirectory: RemoteFilePath
    @Published private(set) var localEntries: [RemoteFileEntry] = []
    @Published private(set) var remoteEntries: [RemoteFileEntry] = []
    @Published private(set) var transfers: [TransferQueueEntry] = []
    @Published private(set) var loadingLocal = false
    @Published private(set) var loadingRemote = false
    @Published private(set) var failure: String?
    @Published private(set) var information: String?
    @Published private(set) var remoteCapabilities: Set<RemoteFileCapability> = []
    @Published private(set) var localRoot: URL
    private(set) var active = true
    private let environment: AppEnvironment
    private weak var terminal: ToolboxTerminalSession?
    private let sshHandle: @MainActor () -> SSHSessionHandle?
    private let remoteWorkingRoot: URL
    private var localSession: RemoteFileSession?
    private var remoteSession: RemoteFileSession?
    private var transferSessions: TransferSessionPair?
    private var queue: RemoteTransferQueue?
    private var monitor: Task<Void, Never>?
    private var localScope: URL?
    private var localScopeGranted = false
    private var localGeneration = UUID()
    private var remoteGeneration = UUID()
    private var completedCount = 0
    var hasActiveTransfers: Bool { transfers.contains { [.queued, .running, .cancelling].contains($0.phase) } }
    private init(environment: AppEnvironment, terminal: ToolboxTerminalSession, ownerID: UUID, localRoot: URL,
                 sshHandle: @escaping @MainActor () -> SSHSessionHandle?) throws {
        self.environment = environment; self.terminal = terminal; self.sshHandle = sshHandle
        lease = .init(ownerID: ownerID, sessionID: terminal.lease.sessionID, generation: terminal.lease.generation)
        localMachine = .temporary(connectionID: ownerID); remoteMachine = terminal.machine; title = terminal.title
        self.localRoot = localRoot; remoteWorkingRoot = terminal.workingRoot
        localDirectory = try .init("/"); remoteDirectory = try .init("/")
    }
    static func open(environment: AppEnvironment, terminal: ToolboxTerminalSession,
                     sshHandle: @escaping @MainActor () -> SSHSessionHandle?) async throws -> ToolboxRemoteFilesOwner {
        let repository = ToolboxTransferRepository(database: environment.database), key: String
        switch terminal.machine {
        case .builtIn(let id): key = "linux:" + id
        case .systemEnvironment(let id), .toolboxMachine(let id): key = "ssh:" + id.uuidString
        case .temporary: key = "temporary:" + terminal.id.uuidString
        }
        let ownerID = try await repository.owner(for: key)
        let root = try PersonalContentLibrary.applicationRoot().deletingLastPathComponent().appendingPathComponent("Toolbox/Files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = try ToolboxRemoteFilesOwner(environment: environment, terminal: terminal, ownerID: ownerID, localRoot: root, sshHandle: sshHandle)
        owner.localSession = try owner.makeLocalSession()
        let queue = RemoteTransferQueue(ownerID: ownerID, repository: repository) { [weak owner] id, request in
            guard let owner else { throw RemoteFileError.staleSession }
            return try await owner.resolve(id, request)
        }
        try await queue.restore(); owner.queue = queue
        owner.monitor = Task { [weak owner] in
            while !Task.isCancelled, let owner, owner.active {
                await owner.refreshQueue()
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
        await owner.refresh(local: true); await owner.refresh(local: false)
        return owner
    }
    private var authorizer: RemoteFileAuthorizer {
        { [weak self] request in
            await MainActor.run {
                guard let self else { return false }
                return self.active && self.terminal?.active == true && request.lease == self.lease
                    && [self.localMachine, self.remoteMachine].contains(request.machine)
            }
        }
    }
    private func makeLocalSession() throws -> RemoteFileSession {
        try RemoteFileSession(lease: lease, machine: localMachine, root: RemoteFilePath("/"),
            backend: ToolboxLocalFileBackend(root: localRoot), authorize: authorizer)
    }
    private func makeRemoteSession() async throws -> RemoteFileSession {
        guard active, terminal?.active == true else { throw RemoteFileError.staleSession }
        if case .builtIn = remoteMachine {
            return try .init(lease: lease, machine: remoteMachine, root: RemoteFilePath("/"),
                backend: ToolboxLocalFileBackend(root: remoteWorkingRoot), authorize: authorizer)
        }
        guard let handle = sshHandle() else { throw RemoteFileError.connectionClosed }
        return try await ToolboxSSHFileBridge.sftp(handle: handle, lease: lease, machine: remoteMachine,
            root: RemoteFilePath("/"), authorize: authorizer)
    }
    private func resolve(_ ownerID: UUID, _ request: RemoteTransferRequest) async throws -> TransferSessionPair {
        guard active, ownerID == lease.ownerID,
              Set([request.sourceMachine, request.destinationMachine]) == Set([localMachine, remoteMachine]) else { throw RemoteFileError.staleSession }
        if let previous = transferSessions { await previous.source.close(); await previous.destination.close() }
        let local = try makeLocalSession(), remote: RemoteFileSession
        do { remote = try await makeRemoteSession() } catch { await local.close(); throw error }
        guard active else { await local.close(); await remote.close(); throw RemoteFileError.staleSession }
        let pair = TransferSessionPair(source: request.sourceMachine == localMachine ? local : remote,
            destination: request.destinationMachine == localMachine ? local : remote)
        transferSessions = pair; return pair
    }
    func refresh(local: Bool) async {
        guard active else { return }
        let token = UUID()
        if local { localGeneration = token; loadingLocal = true } else { remoteGeneration = token; loadingRemote = true }
        defer { if localGeneration == token { loadingLocal = false }; if remoteGeneration == token { loadingRemote = false } }
        do {
            let session: RemoteFileSession
            if local { guard let value = localSession else { throw RemoteFileError.staleSession }; session = value }
            else if let value = remoteSession { session = value }
            else { session = try await makeRemoteSession(); remoteSession = session; remoteCapabilities = session.capabilities }
            let directory = local ? localDirectory : remoteDirectory
            let values = try await session.list(directory, expected: lease)
            guard active, local ? localGeneration == token : remoteGeneration == token else { return }
            if local { localEntries = values } else { remoteEntries = values }; failure = nil
        } catch {
            guard active, local ? localGeneration == token : remoteGeneration == token else { return }
            failure = IDELanguageRunText.t("未能读取文件，请刷新或重新连接。", "Unable to read files. Refresh or reconnect.")
            if !local { await remoteSession?.close(); remoteSession = nil }
        }
    }
    func navigate(_ path: RemoteFilePath, local: Bool) async {
        if local { localDirectory = path } else { remoteDirectory = path }; await refresh(local: local)
    }
    private func refreshQueue() async {
        guard let queue else { return }
        let state = await queue.snapshot(); guard active else { return }; transfers = state.entries
        let completed = state.entries.filter { $0.phase == .completed }.count
        if completed != completedCount { completedCount = completed; await refresh(local: true); await refresh(local: false) }
    }
    func enqueue(_ paths: Set<RemoteFilePath>, uploading: Bool) async {
        guard active, let queue else { return }
        do {
            for path in paths.sorted(by: { $0.value < $1.value }) {
                let entries = uploading ? localEntries : remoteEntries
                guard entries.first(where: { $0.path == path })?.kind == .file else { throw RemoteFileError.unsupported }
                let target = try (uploading ? remoteDirectory : localDirectory).appending(path.name)
                _ = try await queue.enqueue(.init(sourceMachine: uploading ? localMachine : remoteMachine,
                    destinationMachine: uploading ? remoteMachine : localMachine, source: path, destination: target))
            }
            await refreshQueue(); failure = nil
        } catch { failure = IDELanguageRunText.t("未能加入传输队列。当前支持文件传输；请检查目录和权限。", "Unable to queue the transfer. Select files and check the folders and permissions.") }
    }
    func cancel(_ entry: TransferQueueEntry) async {
        do { try await queue?.cancel(entry.id); await refreshQueue() } catch { failure = IDELanguageRunText.t("正在更新传输，请稍后重试。", "The transfer is updating. Try again shortly.") }
    }
    func retry(_ entry: TransferQueueEntry, resume: Bool) async {
        do { try await queue?.retry(entry.id, resume: resume); await refreshQueue() } catch { failure = IDELanguageRunText.t("未能重试，请核对文件和连接。", "Unable to retry. Check the files and connection.") }
    }
    func resolveConflict(_ entry: TransferQueueEntry, replace: Bool) async {
        guard let queue else { return }
        do {
            let destination: RemoteFilePath
            if replace { destination = entry.request.destination }
            else {
                let name = entry.request.destination.name as NSString, suffix = name.pathExtension
                let copy = name.deletingPathExtension + "-" + String(UUID().uuidString.prefix(6)) + (suffix.isEmpty ? "" : "." + suffix)
                destination = try entry.request.destination.parent.appending(copy)
            }
            _ = try await queue.enqueue(.init(sourceMachine: entry.request.sourceMachine, destinationMachine: entry.request.destinationMachine,
                source: entry.request.source, destination: destination, conflict: replace ? .replace : .failIfExists))
            await refreshQueue()
        } catch { failure = IDELanguageRunText.t("未能处理冲突，请刷新后重试。", "Unable to resolve the conflict. Refresh and retry.") }
    }
    func chooseLocalFolder() async {
        guard !hasActiveTransfers else { failure = IDELanguageRunText.t("传输结束后可更改本地文件夹。", "Change the local folder after transfers finish."); return }
        do {
            guard let url = try await fileAccess.choose([.folder]) else { return }
            let granted = url.startAccessingSecurityScopedResource()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard active, values.isDirectory == true, values.isSymbolicLink != true else { if granted { url.stopAccessingSecurityScopedResource() }; throw RemoteFileError.denied }
            await localSession?.close()
            if localScopeGranted, let localScope { localScope.stopAccessingSecurityScopedResource() }
            localRoot = url; localScope = url; localScopeGranted = granted; localMachine = .temporary(connectionID: UUID())
            localDirectory = try .init("/"); localSession = try makeLocalSession(); await refresh(local: true)
        } catch { failure = IDELanguageRunText.t("未能打开所选文件夹。", "Unable to open the selected folder.") }
    }
    func importLocalFile(uploadAfterImport: Bool) async {
        do {
            guard let url = try await fileAccess.choose([.data]) else { return }
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            guard active else { throw RemoteFileError.staleSession }
            let name = url.lastPathComponent, path = try localDirectory.appending(name), root = localRoot
            let access = localScope
            _ = access // The owner retains the explicit folder lease across the detached import.
            try await Task.detached(priority: .utility) {
                let service = WorkspaceFileService(guard: .init(rootURL: root))
                _ = try service.importUserFile(from: url, to: String(path.value.dropFirst()), expectedSHA256: nil)
            }.value
            guard active else { return }; await refresh(local: true)
            if uploadAfterImport { await enqueue([path], uploading: true) }
        } catch { failure = IDELanguageRunText.t("未能导入文件。若存在同名文件，请先重命名。", "Unable to import the file. Rename an existing file with the same name first.") }
    }
    func createFolder(_ name: String, local: Bool) async {
        do {
            let path = try (local ? localDirectory : remoteDirectory).appending(name)
            guard let session = local ? localSession : remoteSession else { throw RemoteFileError.staleSession }
            try await session.createDirectory(path, expected: lease); await refresh(local: local)
        } catch { failure = IDELanguageRunText.t("未能创建文件夹。", "Unable to create the folder.") }
    }
    func rename(_ path: RemoteFilePath, name: String, local: Bool) async {
        do {
            guard let session = local ? localSession : remoteSession else { throw RemoteFileError.staleSession }
            try await session.rename(path, to: path.parent.appending(name), replace: false, expected: lease); await refresh(local: local)
        } catch { failure = IDELanguageRunText.t("未能重命名，请检查同名文件和权限。", "Unable to rename. Check existing names and permissions.") }
    }
    func delete(_ path: RemoteFilePath, local: Bool) async {
        do {
            let entries = local ? localEntries : remoteEntries
            guard let entry = entries.first(where: { $0.path == path }), let session = local ? localSession : remoteSession else { throw RemoteFileError.staleSession }
            try await session.delete(path, directory: entry.kind == .directory, expected: lease); await refresh(local: local)
        } catch { failure = IDELanguageRunText.t("未能删除。请检查权限；文件夹须为空。", "Unable to delete. Check permissions; folders must be empty.") }
    }
    func showInformation(_ path: RemoteFilePath, local: Bool) async {
        do {
            guard let session = local ? localSession : remoteSession else { throw RemoteFileError.staleSession }
            let entry = try await session.metadata(path, expected: lease)
            information = path.value + "\n" + (entry.revision.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? IDELanguageRunText.t("大小未知", "Size unknown")) + "\n" + (entry.revision.modifiedAt?.formatted() ?? IDELanguageRunText.t("修改时间未知", "Modification time unknown"))
        } catch { failure = IDELanguageRunText.t("未能读取文件信息。", "Unable to read file information.") }
    }
    func dismissInformation() { information = nil }
    func followLink(_ path: RemoteFilePath) async {
        do { guard let remoteSession else { return }; remoteDirectory = try await remoteSession.followLink(path, expected: lease); await refresh(local: false) }
        catch { failure = IDELanguageRunText.t("链接目标不可用或超出目录范围。", "The link target is unavailable or outside the folder scope.") }
    }
    func localURL(_ path: RemoteFilePath) -> URL? { try? WorkspacePathGuard(rootURL: localRoot).resolve(String(path.value.dropFirst())) }
    func invalidate() { active = false; localGeneration = UUID(); remoteGeneration = UUID(); monitor?.cancel(); monitor = nil }
    func close() async {
        invalidate(); fileAccess.finish(.success(nil)); await queue?.close()
        await localSession?.close(); await remoteSession?.close()
        if let pair = transferSessions { await pair.source.close(); await pair.destination.close() }
        localSession = nil; remoteSession = nil; transferSessions = nil
        if localScopeGranted, let localScope { localScope.stopAccessingSecurityScopedResource() }; localScopeGranted = false; localScope = nil
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import CryptoKit
import Darwin
import FloeCore
import FloeDeviceSync
import FloeModels
import FloePersistence
import FloeSecurity
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DeviceHistorySyncHost {
    let center: DeviceHistorySyncCenter
    private var foreground = false
    private var activation: Task<Void, Never>?
    private var suspension: Task<Void, Never>?

    convenience init(store: SQLiteConversationStore, workspaceHost: DeviceWorkspaceSyncHost? = nil,
                     didImport: @escaping @MainActor (UUID) async -> Void) {
        let keychain = KeychainStore(service: "org.floeagent.ios.device-history",
                                     synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly)
        let account = "endpoint-identity-v1"
        let identity = DeviceHistoryIdentityStorage(load: {
            do { return try keychain.read(account: account) }
            catch KeychainStoreError.itemNotFound { return nil }
        }, save: { secret in
            try keychain.store(account: account, secret: secret)
        })
        let settingsURL = URL.applicationSupportDirectory
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("device-history-sync.json")
        self.init(store: store, settingsURL: settingsURL, identityStorage: identity,
                  workspaceHost: workspaceHost, didImport: didImport)
    }

    init(store: SQLiteConversationStore, settingsURL: URL, identityStorage: DeviceHistoryIdentityStorage,
         workspaceHost: DeviceWorkspaceSyncHost?, didImport: @escaping @MainActor (UUID) async -> Void) {
        let source = DeviceHistorySource(list: { allowed in
            try await store.conversations().filter { allowed.contains($0.id) }.map(Self.offer)
        }, export: { id, version in
            do {
                if version == 2 { try await Self.indexAttachments(conversationID: id, store: store) }
                return try await store.deviceHistory(conversationID: id, version: version).encoded()
            }
            catch DeviceConversationHistoryError.sizeLimit { throw DeviceHistorySyncError.tooLarge }
        }, exportPage: { id, cursor, through, version in
            do {
                if version == 2, through == nil { try await Self.indexAttachments(conversationID: id, store: store) }
                let page = try await store.deviceHistoryPage(conversationID: id, after: cursor, through: through, version: version)
                return DeviceHistoryPage(archive: page.archive, nextCursor: page.nextCursor,
                                         through: page.through, hasMore: page.hasMore)
            } catch DeviceConversationHistoryError.sizeLimit {
                throw DeviceHistorySyncError.tooLarge
            } catch DeviceConversationHistoryError.cursorExpired {
                throw DeviceHistorySyncError.cursorExpired
            }
        }, attachment: { owner, id, offset, count in
            guard let info = try await store.deviceHistoryUserAttachment(conversationID: owner, id: id),
                  info.storage == .applicationSupport, !info.sha256.isEmpty,
                  offset >= 0, count > 0, offset <= Int64(info.byteCount) - Int64(count) else {
                throw DeviceHistorySyncError.notShared
            }
            return try await Self.fileWork {
                let handle = try Self.openAttachment(info)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                    throw DeviceHistorySyncError.invalidResponse
                }
                return bytes
            }
        })
        let attachments = DeviceAttachmentRestore(pending: { id in
            try await store.deviceHistoryUserAttachments(conversationID: id, storage: .none).compactMap { value in
                guard let messageID = value.messageID, !value.sha256.isEmpty else { return nil }
                return DeviceAttachmentRestore.Item(attachmentID: value.id, messageID: messageID,
                    kind: value.kind == .image ? .image : .file, displayName: value.displayName,
                    byteCount: value.byteCount, digest: value.sha256)
            }
        }, restore: { owner, item, data in
            guard let info = try await store.deviceHistoryUserAttachment(conversationID: owner, id: item.attachmentID),
                  info.messageID == item.messageID, info.storage == .none,
                  info.sha256 == item.digest, info.byteCount == data.count else { return false }
            let name = try await Self.fileWork { try Self.writeAttachment(data, matching: info) }
            try Task.checkCancellation()
            return try await store.restoreDeviceHistoryAttachment(conversationID: owner,
                attachmentID: item.attachmentID, messageID: item.messageID, digest: item.digest, relativePath: name)
        })
        center = DeviceHistorySyncCenter(settingsURL: settingsURL, identityStorage: identityStorage, source: source,
                                         localTasks: { try await store.conversations().map(Self.offer) },
                                         importHistory: { id, data in
            try await Self.importMessages(id, data, store: store)
        }, pagedHistory: DeviceHistoryPageDestination(cursor: { peerID, id in
            try await store.deviceHistoryCursor(from: peerID, conversationID: id)
        }, commit: { peerID, id, data, cursor in
            try await Self.importMessages(id, data, store: store, peerID: peerID, cursor: cursor)
        }), workspaceHost: workspaceHost, attachmentRestore: workspaceHost == nil ? nil : attachments, didImport: didImport)
    }

    private nonisolated static var attachmentRoot: URL {
        URL.applicationSupportDirectory.appending(path: "FloeAgent/Attachments", directoryHint: .isDirectory)
    }

    private nonisolated static func indexAttachments(conversationID: UUID, store: SQLiteConversationStore) async throws {
        let candidates = try await store.deviceHistoryUserAttachments(conversationID: conversationID, storage: .applicationSupport)
        let missing = candidates.filter { $0.sha256.isEmpty }
        guard !missing.isEmpty else { return }
        let digests = try await fileWork {
            try missing.compactMap { info -> (AttachmentRef, String)? in
                try Task.checkCancellation()
                guard let handle = try? openAttachment(info) else { return nil }
                defer { try? handle.close() }
                guard let digest = try? hash(handle, expectedBytes: info.byteCount) else { return nil }
                return (info, digest)
            }
        }
        for (info, digest) in digests {
            try Task.checkCancellation()
            try await store.noteDeviceAttachmentDigest(digest, for: info)
        }
    }

    private nonisolated static func openAttachment(_ info: AttachmentRef) throws -> FileHandle {
        guard let name = info.relativePath, !name.isEmpty, name != ".", name != "..",
              name == URL(fileURLWithPath: name).lastPathComponent,
              (0...DeviceAttachmentRestoreLimit.maximumItemBytes).contains(info.byteCount) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        // Synced user bytes always live in the app-owned attachment store.
        // A peer cannot supply a path or open a bookmark on this device.
        let url = attachmentRoot.appending(path: name)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DeviceHistorySyncError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var infoOnDisk = stat()
        guard fstat(fd, &infoOnDisk) == 0, infoOnDisk.st_mode & S_IFMT == S_IFREG,
              infoOnDisk.st_size == Int64(info.byteCount), infoOnDisk.st_nlink == 1 else {
            try? handle.close()
            throw DeviceHistorySyncError.invalidResponse
        }
        return handle
    }

    private nonisolated static func hash(_ handle: FileHandle, expectedBytes: Int) throws -> String {
        var digest = SHA256()
        var total = 0
        while let bytes = try handle.read(upToCount: 512 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            total += bytes.count
            guard total <= expectedBytes else { throw DeviceHistorySyncError.invalidResponse }
            digest.update(data: bytes)
        }
        guard total == expectedBytes else { throw DeviceHistorySyncError.invalidResponse }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func writeAttachment(_ bytes: Data, matching info: AttachmentRef) throws -> String {
        guard bytes.count == info.byteCount, FloeDigest.sha256Hex(bytes) == info.sha256 else {
            throw DeviceHistorySyncError.invalidResponse
        }
        let ext = UTType(info.uti)?.preferredFilenameExtension ?? "bin"
        let safeExt = !ext.isEmpty && ext.utf8.count <= 12 && ext.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || (65...90).contains($0)
        }
        let name = "sync-\(info.id.uuidString)-\(info.sha256).\(safeExt ? ext : "bin")"
        let fm = FileManager.default
        let root = attachmentRoot
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: name)
        if !fm.fileExists(atPath: target.path) {
            let staged = root.appending(path: ".sync-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try bytes.write(to: staged, options: .atomic)
            try Task.checkCancellation()
            try fm.moveItem(at: staged, to: target)
        }
        var stored = info
        stored.relativePath = name
        let handle = try openAttachment(stored)
        defer { try? handle.close() }
        guard try hash(handle, expectedBytes: info.byteCount) == info.sha256 else {
            throw DeviceHistorySyncError.conflict
        }
        return name
    }

    private nonisolated static func fileWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func importMessages(
        _ id: UUID, _ data: Data, store: SQLiteConversationStore,
        peerID: String? = nil, cursor: String? = nil
    ) async throws -> Int {
        let history = try DeviceConversationHistory(data: data)
        guard history.id == id else { throw DeviceHistorySyncError.invalidResponse }
        do {
            let receipt = try await store.importDeviceHistory(history, sourcePeerID: peerID, nextCursor: cursor)
            return receipt.addedMessages
        } catch DeviceConversationHistoryError.messageConflict {
            throw DeviceHistorySyncError.conflict
        }
    }

    func setForeground(_ foreground: Bool) {
        guard self.foreground != foreground else { return }
        self.foreground = foreground
        let pendingSuspension = suspension
        if foreground {
            activation = Task { [center] in
                await pendingSuspension?.value
                guard !Task.isCancelled else { return }
                await center.activate()
            }
        } else {
            activation?.cancel()
            activation = nil
            suspension = Task { [center] in
                await pendingSuspension?.value
                await center.pause()
            }
        }
    }

    private nonisolated static func offer(_ conversation: ConversationRecord) -> DeviceHistoryOffer {
        DeviceHistoryOffer(id: conversation.id, title: SecretRedactor.redact(conversation.title))
    }
}

extension Notification.Name {
    static let floeDeviceHistoryDidImport = Notification.Name("floe.deviceHistory.didImport")
    static let floeWorkspaceFilesDidSync = Notification.Name("floe.workspace.files.didSync")
}
#endif

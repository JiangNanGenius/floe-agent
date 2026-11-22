// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import FloeCore
import FloeDeviceSync
import FloePersistence
import FloeSecurity
import Foundation

@MainActor
final class DeviceHistorySyncHost {
    let center: DeviceHistorySyncCenter
    private var foreground = false
    private var activation: Task<Void, Never>?
    private var suspension: Task<Void, Never>?

    init(store: SQLiteConversationStore, didImport: @escaping @MainActor (UUID) async -> Void) {
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
        let source = DeviceHistorySource(list: { allowed in
            try await store.conversations().filter { allowed.contains($0.id) }.map(Self.offer)
        }, export: { id in
            try await store.deviceHistory(conversationID: id).encoded()
        })
        center = DeviceHistorySyncCenter(settingsURL: settingsURL, identityStorage: identity, source: source,
                                         localTasks: { try await store.conversations().map(Self.offer) },
                                         importHistory: { id, data in
            let history = try DeviceConversationHistory(data: data)
            guard history.id == id else { throw DeviceHistorySyncError.invalidResponse }
            let receipt: DeviceConversationImport
            do { receipt = try await store.importDeviceHistory(history) }
            catch DeviceConversationHistoryError.messageConflict { throw DeviceHistorySyncError.conflict }
            if receipt.createdConversation || receipt.addedMessages > 0 {
                await didImport(receipt.conversationID)
            }
            return receipt.addedMessages
        })
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
}
#endif

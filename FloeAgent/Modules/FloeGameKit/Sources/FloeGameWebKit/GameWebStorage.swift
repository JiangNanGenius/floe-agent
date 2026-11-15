// SPDX-License-Identifier: MPL-2.0
import Foundation
import WebKit
import FloeGameCore

/// Project-scoped persistent WebKit storage. The store is keyed by the
/// host-resolved `GameWebStorageIdentity`, so unrelated projects (and the App's
/// browser/auth data in the default store) are not visible to a game.
@MainActor
public enum GameWebStorage {
    /// Creates or reopens the persistent store for one trusted identity.
    /// Multiple players for the same project may share it.
    public static func persistentStore(for identity: GameWebStorageIdentity) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: identity.uuid)
    }

    /// Deletes exactly one project scope. The host must stop every player using
    /// the store first; this never clears the App's default website data.
    public static func removeData(for identity: GameWebStorageIdentity) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: identity.uuid)
    }

    /// Convenience for the host's permanent-project-deletion path. It derives
    /// the same stable identity used by `GameWebPlayer`; it is not a source of
    /// authority by itself.
    public static func removeData(for context: GameProjectContext, engine: GameEngineID) async throws {
        try await removeData(for: GameWebStorageIdentity(context: context, engine: engine))
    }
}

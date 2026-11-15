// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGameCore
import FloeGameIDEBridge

/// Built-in project Run uses the IDE's saved buffers and actual caller owner.
/// Preparation may return an ambiguous game so the native chooser can resolve it.
struct GameIDERunExtensionProvider {
    let environment: AppEnvironment

    @MainActor
    func prepare(_ center: WorkspaceCenter, conversationID: UUID?) async throws -> GameWorkspaceSession? {
        try await environment.gameWorkspaces.prepareIDEGameSession(
            for: center, conversationID: conversationID)
    }

    @MainActor
    func resolve(_ center: WorkspaceCenter, conversationID: UUID?) async throws -> IDEProjectRunExtension? {
        try await environment.gameWorkspaces.ideRunExtension(for: center, conversationID: conversationID)
    }
}

private struct GameIDERunExtensionProviderKey: EnvironmentKey {
    static let defaultValue: GameIDERunExtensionProvider? = nil
}

extension EnvironmentValues {
    var gameIDERunExtensionProvider: GameIDERunExtensionProvider? {
        get { self[GameIDERunExtensionProviderKey.self] }
        set { self[GameIDERunExtensionProviderKey.self] = newValue }
    }
}
#endif

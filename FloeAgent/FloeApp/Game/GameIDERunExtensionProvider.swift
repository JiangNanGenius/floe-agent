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

/// Read-only recognition of an IDE's pinned root as a genuine game project.
/// It drives the Run affordance's visibility: an unrelated workspace that
/// merely contains index.html never shows a play button with nothing
/// selected, while a real game workspace keeps Run available for its
/// chooser/run flow even before any file is selected. Recognition only —
/// `prepare`/`resolve` stay the single tap-time path, so this creates no
/// session, owner or run.
enum IDEGameRootRecognition: Sendable, Equatable {
    case recognized
    case notRecognized
    /// The bounded probe could not finish (budget/unreadable root). The
    /// affordance falls back to the runnable-selection rule, so a genuine
    /// game whose probe errors still reaches its run error through a real
    /// selection instead of a dead button.
    case unknown
}

extension GameIDERunExtensionProvider {
    /// Bounded, read-only preflight over the pinned root. Never creates a
    /// game session, owner or run; `prepare`/`resolve` remain the only run
    /// path and re-verify everything on tap.
    @MainActor
    func recognize(_ center: WorkspaceCenter) async -> IDEGameRootRecognition {
        guard let root = center.currentRootURL else { return .unknown }
        do {
            let found = try await Task.detached(priority: .utility) {
                try GameProjectInspector.hasGameCandidate(rootURL: root)
            }.value
            return found ? .recognized : .notRecognized
        } catch {
            return .unknown
        }
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

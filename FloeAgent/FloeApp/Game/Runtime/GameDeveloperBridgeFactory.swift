// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGameCore
import FloeGameIDEBridge
import FloeGameWebKit
import FloeGameDeveloperCore

/// Host-owned development bridge configuration.
///
/// The configuration is created before `GameProjectRunController` creates and
/// starts the Web player (the controller calls
/// `player.enableDeveloperBridge(configuration)` before `player.start`). It is
/// never decoded from project metadata, a model response or an exported game.
///
/// Only WebKit routes receive the bridge. RGSS uses the guest developer
/// overlay and external-build engines have no in-page hook; returning nil for
/// them is honest rather than installing a menu that cannot work.
enum GameDeveloperBridgeFactory {
    static func configuration(for request: GameIDEProjectRunRequest) throws
        -> GameDeveloperBridgeConfiguration? {
        guard let descriptor = try? GameDeveloperEngineCatalog.descriptor(for: request.engine),
              descriptor.hookID != nil else {
            return nil
        }
        switch descriptor.route {
        case .staticWeb, .portableAssembly, .narrativeAssembly, .runtimePack:
            return try GameDeveloperBridgeConfiguration(engine: request.engine)
        case .guestRuntime, .externalBuild:
            return nil
        }
    }
}
#endif

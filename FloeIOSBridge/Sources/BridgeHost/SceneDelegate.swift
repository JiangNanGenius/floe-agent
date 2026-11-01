import SwiftUI
import UIKit
import BridgeCore

/// One hosting controller per process. A scene reconnect only rebuilds the
/// window; it never repeats launch preparation or the one-shot bootstrap.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static var sharedHost: UIHostingController<BridgeRootView>?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let host: UIHostingController<BridgeRootView>
        if let existing = Self.sharedHost {
            host = existing
        } else {
            let created = UIHostingController(rootView: BridgeRootView(model: .shared))
            Self.sharedHost = created
            host = created
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()
        BridgeLivenessMonitor.shared.recordSceneTransition("scene-will-connect", scene: scene)
        BridgeAppModel.shared.activate()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        BridgeLivenessMonitor.shared.recordSceneTransition("scene-did-disconnect", scene: scene)
        BridgeLog.shared.append("scene_disconnected")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        BridgeLivenessMonitor.shared.recordSceneTransition("scene-will-enter-foreground", scene: scene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        BridgeLivenessMonitor.shared.recordSceneTransition("scene-did-become-active", scene: scene)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        BridgeLivenessMonitor.shared.recordSceneTransition("scene-will-resign-active", scene: scene)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        BridgeLivenessMonitor.shared.recordSceneTransition("scene-did-enter-background", scene: scene)
    }
}

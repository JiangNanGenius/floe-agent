import UIKit

/// Drives the canary window with the scene-based life cycle required by SDK 27.
///
/// The process keeps exactly one `CanaryViewController`. Its `viewDidLoad`
/// attaches the shared coordinator once, so scene reconnection only rebuilds the
/// window and never repeats process preparation, the one-shot XCTest bootstrap or
/// the command polling runtime.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private static var sharedViewController: CanaryViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let isNewRoot = Self.sharedViewController == nil
        let viewController: CanaryViewController
        if let existing = Self.sharedViewController {
            viewController = existing
        } else {
            let created = CanaryViewController()
            Self.sharedViewController = created
            viewController = created
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = viewController
        self.window = window
        window.makeKeyAndVisible()

        CanaryFiles.appendLog(
            "scene_connected role=\(session.role.rawValue) " +
            "reused_root=\(!isNewRoot) " +
            "window=\(ObjectIdentifier(window))"
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Keep the canary view controller and coordinator runtime for a reconnect.
        CanaryFiles.appendLog("scene_disconnected")
    }
}

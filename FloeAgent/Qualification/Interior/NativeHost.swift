// SPDX-License-Identifier: MPL-2.0
import UIKit

@main final class InteriorNativeHost: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration=UISceneConfiguration(name:"Interior component",sessionRole:connectingSceneSession.role)
        configuration.delegateClass=InteriorNativeScene.self
        return configuration
    }
}

final class InteriorNativeScene: UIResponder, UIWindowSceneDelegate {
    var window:UIWindow?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else { return }
        let window=UIWindow(windowScene:scene)
        let controller=UIViewController(); controller.view.backgroundColor = .systemBackground
        window.rootViewController=controller; window.makeKeyAndVisible(); self.window=window
    }
}

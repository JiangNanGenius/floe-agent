//
//  CADPresentationServiceRenderHost.swift
//  FloeCADKit
//
//  A service-owned native RealityKit render host for animation frame capture
//  and MP4 export when the user has not opened Present. It reuses the SAME
//  `CADPresentationRenderController`, scene builder, camera, materials and
//  snapshot path as the visible Present; it is a separate host window, not a
//  second renderer and not a software approximation.
//
//  The host window is deliberately NOT made key and sits below the app's
//  window, so a foreground task can render a video without stealing focus.
//  iOS still requires a foreground UIWindowScene for a real ARView render; if
//  none is available (app backgrounded, or no window scene) this host refuses
//  rather than fabricate frames.
//
//  Platform note: the offscreen/window-behind snapshot path must be verified
//  on the Simulator/device batch. If a platform version refuses an occluded
//  ARView snapshot, the App should instead present the task's native Present
//  briefly; this source path reports the real error and never returns an
//  engineering-viewport or placeholder frame as video.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import RealityKit
import UIKit

@MainActor
final class CADPresentationServiceRenderHost {
    let window: UIWindow
    let controller: CADPresentationRenderController
    let handle: CADPresentationHandle
    private let root: UIViewController

    /// Nil when the app has no foreground-active window scene (for example a
    /// background task) or the RealityKit view cannot be created.
    init?(document: FloeCADDocument, width: Int, height: Int) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else {
            return nil
        }
        let size = CGSize(width: max(64, width), height: max(64, height))
        let controller = CADPresentationRenderController()
        let handle = CADPresentationHandle()
        handle.controller = controller
        controller.attach(handle: handle)

        let root = UIViewController()
        root.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        // Behind the app's own window: rendered by UIKit/RealityKit, never
        // key, never focus-stealing, and not visible above the user's UI.
        window.windowLevel = .normal - 1
        window.backgroundColor = .black
        window.rootViewController = root
        window.isUserInteractionEnabled = false
        controller.arView.frame = CGRect(origin: .zero, size: size)
        controller.arView.isUserInteractionEnabled = false
        root.view.addSubview(controller.arView)
        window.isHidden = false
        window.layoutIfNeeded()

        let sceneValue = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(includeExplodedPreview: false),
            documentKey: document.url.standardizedFileURL.path)
        controller.apply(sceneValue)

        self.window = window
        self.controller = controller
        self.handle = handle
        self.root = root
    }

    /// Wait for the actual stage build. No frame is captured before this
    /// returns true; cancellation and a bounded timeout fail cleanly.
    func waitUntilReady(timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if controller.isStageReady { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return controller.isStageReady
    }

    func release() {
        controller.release()
        controller.arView.removeFromSuperview()
        root.view.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
        window.rootViewController = nil
    }
}

#endif

//
//  MacWindowTitle.swift
//  FloeCADKit
//
//  Extracted from OpenShape3D (MIT): on the Mac (Catalyst) the title bar
//  mirrors whatever navigation title was shown last, so a closed sheet's
//  title has to be replaced. No-op on iPhone and iPad.
//

import SwiftUI

enum MacWindowTitle {
    nonisolated(unsafe) private static var wanted: String?

    /// The title the window should show: the gallery's, or the open design's.
    static func want(_ title: String) {
        wanted = title
        apply(title)
    }

    /// A sheet closed: put the wanted title back.
    static func restore() {
        guard let wanted else { return }
        apply(wanted)
    }

    private static func apply(_ title: String) {
        #if targetEnvironment(macCatalyst)
        DispatchQueue.main.async {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.title = title
            }
        }
        #endif
    }
}

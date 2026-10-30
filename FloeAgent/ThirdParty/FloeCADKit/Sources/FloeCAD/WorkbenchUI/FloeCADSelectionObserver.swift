//
//  FloeCADSelectionObserver.swift
//  FloeCADKit
//
//  Host notification for the live workbench selection. The host installs one
//  closure at the presentation site; the editor publishes a fresh
//  `CADSelectionContext` on every real selection/revision change. No second
//  selection store and no polling: the environment box is immutable and the
//  handler runs on the main actor with the live document.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI)
import SwiftUI

/// Immutable, main-actor-confined handler box. `@unchecked Sendable` is safe
/// because the stored closure is only invoked on the main actor and the box
/// itself never mutates.
public final class CADSelectionObserverBox: @unchecked Sendable {
    public let handler: @MainActor (CADSelectionContext) -> Void

    public init(handler: @escaping @MainActor (CADSelectionContext) -> Void) {
        self.handler = handler
    }
}

public struct CADSelectionObserverKey: EnvironmentKey {
    public static let defaultValue: CADSelectionObserverBox? = nil
}

public extension EnvironmentValues {
    /// Host-installed observer for the native CAD workbench selection.
    var cadSelectionObserver: CADSelectionObserverBox? {
        get { self[CADSelectionObserverKey.self] }
        set { self[CADSelectionObserverKey.self] = newValue }
    }
}
#endif

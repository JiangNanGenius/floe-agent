// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// The App supplies the professional pages while the package retains its
/// original document and navigation. The immutable handler is main-actor-only.
public final class CADBuildingProfessionalPresenter: @unchecked Sendable {
    public let handler: @MainActor (FloeCADDocument, CADBuildingProfessionalAction) -> Void
    /// The host may retain its existing file-use service across a child page.
    /// The package owns only the opaque token, never the host's file service.
    public let retainNavigation: @MainActor (FloeCADDocument) -> AnyObject?
    /// Wrap the current destination without adding navigation or document
    /// ownership. Identity preserves the standalone component's behavior.
    public let navigationHost: @MainActor (FloeCADDocument, AnyView) -> AnyView
    public init(retainNavigation: @escaping @MainActor (FloeCADDocument) -> AnyObject? = { _ in nil },
                navigationHost: @escaping @MainActor (FloeCADDocument, AnyView) -> AnyView = { _, page in page },
                handler: @escaping @MainActor (FloeCADDocument, CADBuildingProfessionalAction) -> Void) {
        self.handler = handler
        self.retainNavigation = retainNavigation
        self.navigationHost = navigationHost
    }
}

private struct CADBuildingProfessionalPresenterKey: EnvironmentKey {
    static let defaultValue: CADBuildingProfessionalPresenter? = nil
}

public extension EnvironmentValues {
    var cadBuildingProfessionalPresenter: CADBuildingProfessionalPresenter? {
        get { self[CADBuildingProfessionalPresenterKey.self] }
        set { self[CADBuildingProfessionalPresenterKey.self] = newValue }
    }
}
#endif

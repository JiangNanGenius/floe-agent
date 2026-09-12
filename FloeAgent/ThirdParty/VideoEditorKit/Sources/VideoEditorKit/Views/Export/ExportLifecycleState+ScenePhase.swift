import SwiftUI

extension ExportLifecycleState {

    // MARK: - Initializer

    init(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }

}

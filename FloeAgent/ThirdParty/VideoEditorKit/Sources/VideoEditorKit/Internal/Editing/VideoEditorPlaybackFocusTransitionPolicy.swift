import SwiftUI

enum VideoEditorPlaybackFocusTransitionPolicy {

    // MARK: - Public Properties

    static let animationDuration = 0.24
    static let animationExtraBounce = 0.04

    static var animation: Animation {
        .easeInOut(duration: animationDuration)
    }

    static var stageAnimation: Animation {
        .smooth(
            duration: animationDuration,
            extraBounce: animationExtraBounce
        )
    }

    static var toolsTransition: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

}

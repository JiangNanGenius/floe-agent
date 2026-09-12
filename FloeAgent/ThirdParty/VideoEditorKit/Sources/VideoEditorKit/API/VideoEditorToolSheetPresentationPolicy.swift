import SwiftUI

@available(iOS 16.4, *)
public enum VideoEditorToolSheetPresentationPolicy {

    // MARK: - Public Methods

    public static func initialSheetHeight(for tool: ToolEnum) -> CGFloat {
        switch tool {
        case .audio:
            300
        case .speed:
            320
        case .presets, .adjusts:
            380
        case .transcript:
            520
        case .cut:
            420
        }
    }

    public static func contentInteraction(for tool: ToolEnum) -> PresentationContentInteraction {
        switch tool {
        case .audio, .speed, .presets, .adjusts:
            .resizes
        case .transcript, .cut:
            .scrolls
        }
    }

    public static func requiresExplicitApply(_ tool: ToolEnum) -> Bool {
        switch tool {
        case .transcript:
            true
        case .cut, .speed, .presets, .audio, .adjusts:
            false
        }
    }

}

import SwiftUI

enum VideoEditorToolbarActionPlacement: Equatable {

    // MARK: - Public Properties

    case confirmationAction
    case primaryAction

    var toolbarItemPlacement: ToolbarItemPlacement {
        switch self {
        case .confirmationAction:
            .confirmationAction
        case .primaryAction:
            .primaryAction
        }
    }

}

enum VideoEditorToolbarActionButtonStyle: Equatable {

    // MARK: - Public Properties

    case plainToolbarItem
    case borderedProminent

}

enum VideoEditorToolbarActionLayout {

    // MARK: - Public Properties

    static let exportPlacement: VideoEditorToolbarActionPlacement = .primaryAction
    static let savePlacement: VideoEditorToolbarActionPlacement = .primaryAction
    static let separatorPlacement: VideoEditorToolbarActionPlacement = .primaryAction
    static let exportButtonStyle: VideoEditorToolbarActionButtonStyle = .plainToolbarItem
    static let saveButtonStyle: VideoEditorToolbarActionButtonStyle = .borderedProminent
    static let usesNativeActionSeparator = true
    static let usesSystemSaveButtonStyle = true

}

extension View {

    // MARK: - Public Methods

    @ViewBuilder
    func videoEditorToolbarActionButtonStyle(
        _ style: VideoEditorToolbarActionButtonStyle
    ) -> some View {
        switch style {
        case .plainToolbarItem:
            self
        case .borderedProminent:
            buttonStyle(.borderedProminent)
        }
    }

}

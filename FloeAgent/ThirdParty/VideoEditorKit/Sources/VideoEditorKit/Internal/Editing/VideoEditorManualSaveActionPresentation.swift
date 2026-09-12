enum VideoEditorManualSaveActionPresentation: Equatable {

    // MARK: - Cases

    case hidden
    case disabled
    case enabled
    case loading

    // MARK: - Public Properties

    var systemImageName: String {
        "checkmark"
    }

}

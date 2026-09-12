import Foundation

public enum VideoEditorLocalization {

    // MARK: - Public Methods

    public static func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: .module
        )
    }

}

import Foundation
// Signature/behavior contract for CommunicationViews.swift's shared helper.
// The aggregate Toolbox host compiles the real helper with the entire module.
func workbenchText(_ zh: String, _ en: String, _ locale: Locale) -> String {
    locale.language.languageCode?.identifier == "zh" ? zh : en
}

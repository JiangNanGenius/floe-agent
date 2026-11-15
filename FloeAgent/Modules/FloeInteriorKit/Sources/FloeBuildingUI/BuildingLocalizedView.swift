// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeBuildingSystems

/// Resolve copy from the host's environment. A language override in one
/// project never changes another window through global localization state.
@MainActor
protocol BuildingLocalizedView:View {
    var buildingLocale:Locale {get}
}
extension BuildingLocalizedView {
    func buildingText(_ zh:String,_ en:String)->String {BuildingCopy.text(zh,en,locale:buildingLocale)}
    func buildingError(_ error:Error)->String {BuildingCopy.errorMessage(error,locale:buildingLocale)}
    func buildingIssue(_ issue:SystemPlanIssue)->String {BuildingCopy.issueTitle(issue,locale:buildingLocale)}
}

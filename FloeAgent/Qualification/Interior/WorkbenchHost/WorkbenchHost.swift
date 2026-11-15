// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeBuildingUI

@main
struct InteriorWorkbenchQualificationApp: App {
    private let root: URL
    init() {
        root = URL.applicationSupportDirectory.appendingPathComponent("InteriorWorkbenchQualification", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
    }
    var body: some Scene {
        WindowGroup { BuildingWorkbenchView(projectDirectory: root) }
    }
}

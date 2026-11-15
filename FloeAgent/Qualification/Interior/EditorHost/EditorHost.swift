// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeBuildingEditor

@main
struct InteriorEditorQualificationApp:App {
    private let project:URL
    private let library:URL
    private let launch:BuildingEditorLaunch
    init() {
        let environment=ProcessInfo.processInfo.environment
        let supplied=environment["FLOE_INTERIOR_QUALIFICATION_RUN_ID"].flatMap(UUID.init(uuidString:))
        let name=supplied?.uuidString.lowercased() ?? "manual-project"
        let base=URL.applicationSupportDirectory.appendingPathComponent("InteriorEditorQualification",isDirectory:true)
        project=base.appendingPathComponent(name,isDirectory:true)
        library=base.appendingPathComponent("Library",isDirectory:true)
        launch=FileManager.default.fileExists(atPath:project.path) ? .open:.create(name:"Interior qualification")
    }
    var body:some Scene {
        WindowGroup {
            BuildingEditorProjectHost(projectDirectory:project,assetLibraryDirectory:library,launch:launch)
        }
    }
}

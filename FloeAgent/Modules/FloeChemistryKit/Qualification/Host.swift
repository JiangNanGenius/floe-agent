import SwiftUI
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistryUI
#if os(iOS)
import UIKit
#endif

/// Standalone qualification host. Production integration must inject the existing Floe authorization/model/job services.
@main @MainActor struct ChemistryQualificationApp: App {
    private let service: ChemistryService?
    private let failure: String?
    init() {
        do {
            let root = URL.applicationSupportDirectory.appendingPathComponent("FloeChemistryQualification", isDirectory: true)
            let store = try ChemistryProjectStore(root: root)
            service = try ChemistryService(store: store, authorize: { _ in })
            failure = nil
        } catch { service = nil; failure = error.localizedDescription }
    }
    var body: some Scene {
        WindowGroup {
            if let service {
                ChemistryLibraryView(service: service).frame(minWidth: 320, minHeight: 500)
                    .preferredColorScheme(CommandLine.arguments.contains("--chemistry-qa-dark") ? .dark : nil)
                    .onAppear {
                        #if os(iOS)
                        if CommandLine.arguments.contains("--chemistry-qa-high-contrast") {
                            for scene in UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}) {
                                for window in scene.windows {window.traitOverrides.accessibilityContrast = .high}
                            }
                        }
                        #endif
                    }
            }
            else { ContentUnavailableView("Chemistry", systemImage: "exclamationmark.triangle", description: Text(failure ?? "Unavailable")) }
        }
    }
}

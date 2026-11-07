// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyUI

@main @MainActor struct BiologyQualificationApp:App {
    private let service:BiologyService?
    private let failure:String?
    init() {
        do {
            let root=URL.applicationSupportDirectory.appendingPathComponent("FloeBiologyQualification",isDirectory:true)
            let store=try BiologyProjectStore(root:root)
            service=try BiologyService(store:store,authorize:{_ in
                // This standalone host only owns its own application sandbox.
                // The actual App supplies its existing task/file/environment checks.
            });failure=nil
        }catch{service=nil;failure=error.localizedDescription}
    }
    var body:some Scene {
        WindowGroup {
            if let service {
                BiologyHostRoot(service:service)
                    .preferredColorScheme(CommandLine.arguments.contains("--biology-qa-dark") ? .dark:nil)
            }else{ContentUnavailableView("Biology",systemImage:"exclamationmark.triangle",description:Text(failure ?? "Unavailable"))}
        }
    }
}
@MainActor struct BiologyHostRoot:View {
    let service:BiologyService
    @State private var ready=false
    @State private var error:String?
    var body:some View {
        Group {
            if ready{BiologyLibraryView(service:service)}
            else if let error{ContentUnavailableView("Biology",systemImage:"exclamationmark.triangle",description:Text(error))}
            else{ProgressView()}
        }.task {
            do{try await service.recoverInterruptedNativeRuns();ready=true}
            catch{self.error=error.localizedDescription}
        }
        .onAppear {
            if CommandLine.arguments.contains("--biology-qa-contrast") {
                for scene in UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}) {
                    for window in scene.windows{window.traitOverrides.accessibilityContrast = .high}
                }
            }
        }
    }
}

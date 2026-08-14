#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct SetupGuideLauncherView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ContentUnavailableView {
            Label("more.setup_guide", systemImage: "wand.and.stars")
        } description: {
            Text("setup.launcher.description")
        } actions: {
            Button("setup.launcher.open") { router.presentedSetup = .manual }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("more.setup_guide")
        .background(FloeTheme.readingSurface)
    }
}
#endif

// FloeAgent — NativeMedia qualification host.
//
// The retired single-asset editor and its image-editor branches are gone. This
// host keeps the remaining production video consumer, MediaPlayerView, so the
// shared AVFoundation player can still be built and smoke-checked without the
// full App/Office/MLX graph.
import SwiftUI
import AVFoundation
import FloeMedia

@main struct SmokeApp: App {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MediaPlayerView(url: root.appendingPathComponent("input.mov"))
                    .navigationTitle("Floe media player")
            }
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
        }
    }
}

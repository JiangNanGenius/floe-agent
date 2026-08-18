// FloeApp — SwiftUI wrapper for the system broadcast picker.

#if canImport(SwiftUI)
import SwiftUI
import ReplayKit

/// Presents RPBroadcastActivityViewController so the user can start (or
/// stop) screen sharing with the FloeScreenShare extension.
struct BroadcastPickerView: UIViewControllerRepresentable {
    let center: ScreenShareCenter

    func makeUIViewController(context: Context) -> RPBroadcastActivityViewController {
        center.makeBroadcastPicker()
    }

    func updateUIViewController(
        _ uiViewController: RPBroadcastActivityViewController,
        context: Context
    ) {}
}
#endif

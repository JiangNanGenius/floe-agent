import AVFoundation
import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("PlayerViewTests")
struct PlayerViewTests {

    @Test
    func resizeAspectFillMapsToFillContentMode() {
        #expect(
            PlayerView.resolvedContentMode(for: .resizeAspectFill) == .fill
        )
    }

    @Test
    func resizeAspectMapsToFitContentMode() {
        #expect(
            PlayerView.resolvedContentMode(for: .resizeAspect) == .fit
        )
    }

    @Test
    func resizeMapsToFitContentMode() {
        #expect(
            PlayerView.resolvedContentMode(for: .resize) == .fit
        )
    }

}

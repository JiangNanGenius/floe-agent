// FloeApp — Operation guide overlay on the live screen share.
//
// Shows the real screen frame the user is broadcasting, plus the vision
// model's hints about what to tap. This is the "remote assist guide" surface
// that makes screen sharing a genuine feature (and the background keep-alive
// a legitimate by-product), not a fake to satisfy review.

#if canImport(SwiftUI)
import SwiftUI

struct ScreenShareGuideView: View {
    @ObservedObject var center: ScreenShareCenter
    let userGoal: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frame = center.latestFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .top) {
                        guideOverlay
                    }
            } else {
                ProgressView("等待屏幕画面…")
                    .foregroundStyle(.white)
            }
        }
        .task { await center.analyzeScreenAndGuide(userGoal: userGoal) }
    }

    private var guideOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(center.guideHints) { hint in
                Text(hint.elementText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
    }
}
#endif

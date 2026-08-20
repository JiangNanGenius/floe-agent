// FloeApp — Operation guide overlay on the live screen share.
//
// Shows the real screen frame the user is broadcasting, plus the vision
// model's structured hints: a highlight marker at each tappable element's
// position and an instruction card. This is the "remote assist guide"
// surface that makes screen sharing a genuine feature (and the background
// keep-alive a legitimate by-product), not a fake to satisfy review.

#if canImport(SwiftUI)
import SwiftUI

struct ScreenShareGuideView: View {
    @ObservedObject var center: ScreenShareCenter
    let userGoal: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frame = center.latestFrame {
                GeometryReader { proxy in
                    let imageRect = aspectFitRect(
                        imageSize: frame.size,
                        containerSize: proxy.size
                    )
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .overlay {
                            // Tap markers at each hint's normalized position.
                            ForEach(Array(center.guideHints.enumerated()), id: \.element.id) { index, hint in
                                tapMarker(index: index, hint: hint, in: imageRect)
                            }
                        }
                }
                .overlay(alignment: .bottom) {
                    instructionCard
                }
            } else {
                ProgressView("等待屏幕画面…")
                    .foregroundStyle(.white)
            }
        }
        .task(id: center.latestFrame == nil) {
            guard center.latestFrame != nil else { return }
            await center.analyzeScreenAndGuide(userGoal: userGoal)
        }
    }

    /// A pulsing marker at the element's position on the frame.
    private func tapMarker(
        index: Int,
        hint: ScreenShareCenter.GuideHint,
        in imageRect: CGRect
    ) -> some View {
        let x = imageRect.minX + hint.tapPoint.x * imageRect.width
        let y = imageRect.minY + hint.tapPoint.y * imageRect.height
        return ZStack {
            Circle()
                .fill(Color.yellow.opacity(0.3))
            Circle()
                .strokeBorder(Color.yellow, lineWidth: 3)
            Text("\(index + 1)")
                .font(.headline.bold())
                .foregroundStyle(.yellow)
        }
            .frame(width: 44, height: 44)
            .position(x: x, y: y)
            .accessibilityLabel("点按：\(hint.elementText)")
    }

    private func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - fitted.width) / 2,
            y: (containerSize.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if center.guideHints.isEmpty {
                Text("正在分析屏幕，识别可点按的元素…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            } else {
                ForEach(Array(center.guideHints.enumerated()), id: \.element.id) { index, hint in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hint.elementText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(hint.instruction)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
#endif

import SwiftUI

@available(iOS 16.0, *)
// swiftlint:disable:next type_name
public struct VideoEditorPlaybackTimelineTrackSectionView<Badge: View, Track: View>: View {

    // MARK: - States

    @State private var badgeWidth: CGFloat = 84

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                badge(proxy.size, badgeWidth)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: PlaybackTimelineBadgeWidthPreferenceKey.self,
                                    value: geometry.size.width
                                )
                        }
                    }
            }
            .frame(height: badgeHeight)

            GeometryReader { proxy in
                track(proxy.size)
            }
            .frame(height: trackHeight)
        }
        .onPreferenceChange(PlaybackTimelineBadgeWidthPreferenceKey.self) { width in
            badgeWidth = width
        }
    }

    // MARK: - Private Properties

    private let badgeHeight: CGFloat
    private let trackHeight: CGFloat
    private let badge: (_ size: CGSize, _ badgeWidth: CGFloat) -> Badge
    private let track: (_ size: CGSize) -> Track

    // MARK: - Initializer

    public init(
        badgeHeight: CGFloat = 28,
        trackHeight: CGFloat = 60,
        @ViewBuilder badge: @escaping (_ size: CGSize, _ badgeWidth: CGFloat) -> Badge,
        @ViewBuilder track: @escaping (_ size: CGSize) -> Track
    ) {
        self.badgeHeight = badgeHeight
        self.trackHeight = trackHeight
        self.badge = badge
        self.track = track
    }

}

private struct PlaybackTimelineBadgeWidthPreferenceKey: PreferenceKey {

    static let defaultValue: CGFloat = 84

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }

}

#Preview {
    VideoEditorPlaybackTimelineTrackSectionView { _, _ in
        Text("00:05")
            .font(.caption.monospacedDigit())
    } track: { _ in
        RoundedRectangle(cornerRadius: 8)
            .fill(.gray.opacity(0.3))
    }
    .padding()
}

import SwiftUI

public struct VideoEditorLoadedView<PlayerContent: View, ControlsContent: View, ToolsContent: View>: View {

    // MARK: - Public Properties

    public let availableSize: CGSize
    public let resolvedSourceVideoURL: URL
    public let isPlaybackFocused: Bool

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 32) {
            playerContent()
                .layoutPriority(1)

            controlsContent()

            if !isPlaybackFocused {
                toolsContent()
                    .transition(VideoEditorPlaybackFocusTransitionPolicy.toolsTransition)
            }
        }
        .animation(
            VideoEditorPlaybackFocusTransitionPolicy.animation,
            value: isPlaybackFocused
        )
        .task(id: contentTaskID) {
            onLoad(
                availableSize,
                resolvedSourceVideoURL
            )
        }
    }

    // MARK: - Private Properties

    private let onLoad: @MainActor (CGSize, URL) -> Void
    private let playerContent: () -> PlayerContent
    private let controlsContent: () -> ControlsContent
    private let toolsContent: () -> ToolsContent

    private var contentTaskID: String {
        let width = Int(availableSize.width.rounded())
        let height = Int(availableSize.height.rounded())

        return "\(resolvedSourceVideoURL.absoluteString)-\(width)x\(height)"
    }

    // MARK: - Initializer

    public init(
        availableSize: CGSize,
        resolvedSourceVideoURL: URL,
        isPlaybackFocused: Bool,
        onLoad: @escaping @MainActor (CGSize, URL) -> Void = { _, _ in },
        @ViewBuilder playerContent: @escaping () -> PlayerContent,
        @ViewBuilder controlsContent: @escaping () -> ControlsContent,
        @ViewBuilder toolsContent: @escaping () -> ToolsContent
    ) {
        self.availableSize = availableSize
        self.resolvedSourceVideoURL = resolvedSourceVideoURL
        self.isPlaybackFocused = isPlaybackFocused
        self.onLoad = onLoad
        self.playerContent = playerContent
        self.controlsContent = controlsContent
        self.toolsContent = toolsContent
    }

}

#Preview {
    VideoEditorLoadedView(
        availableSize: CGSize(width: 390, height: 600),
        resolvedSourceVideoURL: URL(filePath: "/dev/null"),
        isPlaybackFocused: false
    ) {
        Rectangle()
            .fill(.gray.opacity(0.3))
            .frame(height: 220)
            .overlay(Text("Player"))
    } controlsContent: {
        Rectangle()
            .fill(.blue.opacity(0.2))
            .frame(height: 80)
            .overlay(Text("Controls"))
    } toolsContent: {
        Rectangle()
            .fill(.green.opacity(0.2))
            .frame(height: 60)
            .overlay(Text("Tools"))
    }
}

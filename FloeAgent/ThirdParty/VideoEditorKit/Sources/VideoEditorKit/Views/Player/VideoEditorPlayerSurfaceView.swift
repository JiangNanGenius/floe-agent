import SwiftUI

@available(iOS 16.0, *)
public struct VideoEditorPlayerSurfaceView<Content: View>: View {

    // MARK: - Public Properties

    public let backgroundColor: Color
    public let scale: CGFloat
    public let animation: Animation

    // MARK: - Body

    public var body: some View {
        ZStack {
            backgroundColor

            content()
                .scaleEffect(scale)
                .animation(
                    animation,
                    value: scale
                )
        }
    }

    // MARK: - Private Properties

    private let content: () -> Content

    // MARK: - Initializer

    public init(
        backgroundColor: Color,
        scale: CGFloat,
        animation: Animation = .default,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.scale = scale
        self.animation = animation
        self.content = content
    }

}

#Preview {
    VideoEditorPlayerSurfaceView(
        backgroundColor: .black,
        scale: 0.85
    ) {
        Rectangle()
            .fill(.blue)
            .frame(width: 320, height: 180)
            .overlay(Text("Video").foregroundStyle(.white))
    }
    .frame(height: 300)
}

import SwiftUI

public struct VideoEditorToolSheetView<Content: View, Footer: View>: View {

    // MARK: - Public Properties

    public let title: String
    public let contentInteraction: PresentationContentInteraction

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                content()
            }
            .safeAreaInset(edge: .bottom) {
                footer()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(VideoEditorStrings.close, action: onClose)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(VideoEditorStrings.reset, action: onReset)
            }
        }
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(contentInteraction)
        .presentationCornerRadius(32)
        .onAppear(perform: onAppear)
    }

    // MARK: - Private Properties

    private let onClose: () -> Void
    private let onReset: () -> Void
    private let onAppear: () -> Void
    private let content: () -> Content
    private let footer: () -> Footer

    // MARK: - Initializer

    public init(
        title: String,
        contentInteraction: PresentationContentInteraction,
        onClose: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onAppear: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.contentInteraction = contentInteraction
        self.onClose = onClose
        self.onReset = onReset
        self.onAppear = onAppear
        self.content = content
        self.footer = footer
    }

}

#Preview {
    NavigationStack {
        VideoEditorToolSheetView(
            title: "Speed",
            contentInteraction: .resizes,
            onClose: {},
            onReset: {}
        ) {
            Text("Tool content goes here")
                .padding()
        } footer: {
            PrimaryActionButton(title: VideoEditorStrings.apply) {}
        }
    }
}

import SwiftUI

extension View {

    // MARK: - Public Methods

    public func videoExportSheet(
        isPresented: Binding<Bool>,
        request: VideoExportSheetRequest,
        configuration: VideoEditorConfiguration = .init(),
        onExported: @escaping (ExportedVideo) -> Void
    ) -> some View {
        modifier(
            VideoExportBooleanSheetModifier(
                isPresented: isPresented,
                request: request,
                configuration: configuration,
                onExported: onExported
            )
        )
    }

    public func videoExportSheet<Item: Identifiable>(
        item: Binding<Item?>,
        configuration: VideoEditorConfiguration = .init(),
        request: @escaping (Item) -> VideoExportSheetRequest,
        onExported: @escaping (ExportedVideo, Item) -> Void
    ) -> some View {
        modifier(
            VideoExportItemSheetModifier(
                item: item,
                configuration: configuration,
                request: request,
                onExported: onExported
            )
        )
    }

}

private struct VideoExportBooleanSheetModifier: ViewModifier {

    // MARK: - Bindings

    @Binding private var isPresented: Bool

    // MARK: - Private Properties

    private let request: VideoExportSheetRequest
    private let configuration: VideoEditorConfiguration
    private let onExported: (ExportedVideo) -> Void

    // MARK: - Initializer

    init(
        isPresented: Binding<Bool>,
        request: VideoExportSheetRequest,
        configuration: VideoEditorConfiguration,
        onExported: @escaping (ExportedVideo) -> Void
    ) {
        _isPresented = isPresented

        self.request = request
        self.configuration = configuration
        self.onExported = onExported
    }

    // MARK: - Public Methods

    func body(content: Content) -> some View {
        content
            .dynamicSheet(
                isPresented: $isPresented,
                initialHeight: 420
            ) {
                VideoExportSheet(
                    request: request,
                    configuration: configuration,
                    onExported: handleExported
                )
            }
    }

    // MARK: - Private Methods

    private func handleExported(_ exportedVideo: ExportedVideo) {
        isPresented = false
        onExported(exportedVideo)
    }

}

private struct VideoExportItemSheetModifier<Item: Identifiable>: ViewModifier {

    // MARK: - Bindings

    @Binding private var item: Item?

    // MARK: - Private Properties

    private let configuration: VideoEditorConfiguration
    private let request: (Item) -> VideoExportSheetRequest
    private let onExported: (ExportedVideo, Item) -> Void

    // MARK: - Initializer

    init(
        item: Binding<Item?>,
        configuration: VideoEditorConfiguration,
        request: @escaping (Item) -> VideoExportSheetRequest,
        onExported: @escaping (ExportedVideo, Item) -> Void
    ) {
        _item = item

        self.configuration = configuration
        self.request = request
        self.onExported = onExported
    }

    // MARK: - Public Methods

    func body(content: Content) -> some View {
        content
            .dynamicSheet(
                item: $item,
                initialHeight: { _ in 420 },
                content: { item in
                    VideoExportSheet(
                        request: request(item),
                        configuration: configuration,
                        onExported: { exportedVideo in
                            handleExported(exportedVideo, item: item)
                        }
                    )
                }
            )
    }

    // MARK: - Private Methods

    private func handleExported(
        _ exportedVideo: ExportedVideo,
        item exportedItem: Item
    ) {
        item = nil
        onExported(exportedVideo, exportedItem)
    }

}

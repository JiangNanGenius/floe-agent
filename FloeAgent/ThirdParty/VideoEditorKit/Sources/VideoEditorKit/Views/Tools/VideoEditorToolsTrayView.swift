import SwiftUI

public struct VideoEditorToolsTrayView<RowContent: View, SheetContent: View>: View {

    // MARK: - Bindings

    @Binding private var selectedTool: ToolEnum?

    // MARK: - States

    @State private var sheetContentHeight: CGFloat = DynamicHeightToolSheetConstants.minimumSheetHeight

    // MARK: - Body

    public var body: some View {
        rowContent()
            .onChange(of: selectedTool?.id) { _, _ in
                if let selectedTool {
                    sheetContentHeight = max(
                        initialSheetHeight(selectedTool),
                        DynamicHeightToolSheetConstants.minimumSheetHeight
                    )
                }
            }
            .sheet(item: $selectedTool) { tool in
                DynamicHeightToolSheetContainer(
                    content: sheetContent(tool),
                    sheetContentHeight: $sheetContentHeight
                )
            }
    }

    // MARK: - Private Properties

    private let initialSheetHeight: (ToolEnum) -> CGFloat
    private let rowContent: () -> RowContent
    private let sheetContent: (ToolEnum) -> SheetContent

    // MARK: - Initializer

    public init(
        selectedTool: Binding<ToolEnum?>,
        initialSheetHeight: @escaping (ToolEnum) -> CGFloat,
        @ViewBuilder rowContent: @escaping () -> RowContent,
        @ViewBuilder sheetContent: @escaping (ToolEnum) -> SheetContent
    ) {
        _selectedTool = selectedTool
        self.initialSheetHeight = initialSheetHeight
        self.rowContent = rowContent
        self.sheetContent = sheetContent
    }

}

private enum DynamicHeightToolSheetConstants {
    static let minimumSheetHeight: CGFloat = 1
    static let navigationChromeHeight: CGFloat = 88
}

private struct DynamicHeightToolSheetContainer<SheetContent: View>: View {

    // MARK: - Bindings

    @Binding private var sheetContentHeight: CGFloat

    // MARK: - Public Properties

    let content: SheetContent

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(sheetHeightReader)
        }
        .presentationDetents([.height(resolvedSheetHeight)])
    }

    // MARK: - Initializer

    init(
        content: SheetContent,
        sheetContentHeight: Binding<CGFloat>
    ) {
        self.content = content
        _sheetContentHeight = sheetContentHeight
    }

    // MARK: - Private Properties

    private var resolvedSheetHeight: CGFloat {
        max(
            sheetContentHeight,
            DynamicHeightToolSheetConstants.minimumSheetHeight
        )
    }

    private var sheetHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .task {
                    updateSheetHeight(proxy.size.height)
                }
                .onChange(of: proxy.size.height) { _, newHeight in
                    updateSheetHeight(newHeight)
                }
        }
    }

    // MARK: - Private Methods

    private func updateSheetHeight(_ newHeight: CGFloat) {
        let measuredHeight = max(
            newHeight.rounded(.up) + DynamicHeightToolSheetConstants.navigationChromeHeight,
            DynamicHeightToolSheetConstants.minimumSheetHeight
        )

        guard abs(sheetContentHeight - measuredHeight) > 1 else { return }
        sheetContentHeight = measuredHeight
    }

}

#Preview {
    @Previewable @State var selectedTool: ToolEnum? = nil
    VideoEditorToolsTrayView(
        selectedTool: $selectedTool,
        initialSheetHeight: { _ in 320 },
        rowContent: {
            HStack {
                ForEach(ToolEnum.all) { tool in
                    Button(tool.title) {
                        selectedTool = tool
                    }
                }
            }
            .padding()
        },
        sheetContent: { tool in
            Text("Sheet for \(tool.title)")
                .padding()
        }
    )
}

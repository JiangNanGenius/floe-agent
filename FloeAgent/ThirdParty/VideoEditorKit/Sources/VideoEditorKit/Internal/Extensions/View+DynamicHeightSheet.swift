//
//  View+DynamicHeightSheet.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 26.03.2026.
//

import SwiftUI

private enum DynamicHeightSheetConstants {
    static let minimumSheetHeight: CGFloat = 1
    static let navigationChromeHeight: CGFloat = 88
}

extension View {

    // MARK: - Public Methods

    func dynamicSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        initialHeight: CGFloat = 1,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        dynamicHeightSheet(
            isPresented: isPresented,
            initialHeight: initialHeight,
            content: content
        )
    }

    func dynamicSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        initialHeight: @escaping (Item) -> CGFloat,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        dynamicHeightSheet(
            item: item,
            initialHeight: initialHeight,
            content: content
        )
    }

    func dynamicHeightSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        initialHeight: CGFloat = 1,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(
            DynamicHeightSheetModifier(
                isPresented: isPresented,
                initialHeight: initialHeight,
                sheetContent: content
            )
        )
    }

    func dynamicHeightSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        initialHeight: @escaping (Item) -> CGFloat,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(
            DynamicHeightItemSheetModifier(
                item: item,
                initialHeight: initialHeight,
                sheetContent: content
            )
        )
    }

}

private struct DynamicHeightSheetContainer<SheetContent: View>: View {

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

    init(content: SheetContent, sheetContentHeight: Binding<CGFloat>) {
        self.content = content
        _sheetContentHeight = sheetContentHeight
    }

    // MARK: - Private Properties

    private var resolvedSheetHeight: CGFloat {
        max(sheetContentHeight, DynamicHeightSheetConstants.minimumSheetHeight)
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
            newHeight.rounded(.up) + DynamicHeightSheetConstants.navigationChromeHeight,
            DynamicHeightSheetConstants.minimumSheetHeight
        )

        guard abs(sheetContentHeight - measuredHeight) > 1 else { return }
        sheetContentHeight = measuredHeight
    }

}

private struct DynamicHeightSheetModifier<SheetContent: View>: ViewModifier {

    // MARK: - States

    @State private var sheetContentHeight: CGFloat

    // MARK: - Private Properties

    @Binding private var isPresented: Bool
    private let initialHeight: CGFloat
    private let sheetContent: () -> SheetContent

    // MARK: - Initializer

    init(
        isPresented: Binding<Bool>,
        initialHeight: CGFloat,
        sheetContent: @escaping () -> SheetContent
    ) {
        _isPresented = isPresented
        _sheetContentHeight = State(
            initialValue: max(initialHeight, DynamicHeightSheetConstants.minimumSheetHeight)
        )

        self.initialHeight = initialHeight
        self.sheetContent = sheetContent
    }

    // MARK: - Public Methods

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, isPresented in
                if isPresented {
                    sheetContentHeight = max(
                        initialHeight,
                        DynamicHeightSheetConstants.minimumSheetHeight
                    )
                }
            }
            .sheet(isPresented: $isPresented) {
                dynamicSheetBody(sheetContent())
            }
    }

    // MARK: - Private Methods

    private func dynamicSheetBody(_ content: SheetContent) -> some View {
        DynamicHeightSheetContainer(
            content: content,
            sheetContentHeight: $sheetContentHeight
        )
    }

}

private struct DynamicHeightItemSheetModifier<Item: Identifiable, SheetContent: View>: ViewModifier {

    // MARK: - States

    @Binding private var item: Item?

    @State private var sheetContentHeight: CGFloat = DynamicHeightSheetConstants.minimumSheetHeight

    // MARK: - Private Properties

    private let initialHeight: (Item) -> CGFloat
    private let sheetContent: (Item) -> SheetContent

    // MARK: - Initializer

    init(
        item: Binding<Item?>,
        initialHeight: @escaping (Item) -> CGFloat,
        sheetContent: @escaping (Item) -> SheetContent
    ) {
        _item = item

        self.initialHeight = initialHeight
        self.sheetContent = sheetContent
    }

    // MARK: - Public Methods

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id) { _, _ in
                if let item {
                    sheetContentHeight = max(
                        initialHeight(item),
                        DynamicHeightSheetConstants.minimumSheetHeight
                    )
                }
            }
            .sheet(item: $item) { item in
                dynamicSheetBody(sheetContent(item))
            }
    }

    // MARK: - Private Methods

    private func dynamicSheetBody(_ content: SheetContent) -> some View {
        DynamicHeightSheetContainer(
            content: content,
            sheetContentHeight: $sheetContentHeight
        )
    }

}

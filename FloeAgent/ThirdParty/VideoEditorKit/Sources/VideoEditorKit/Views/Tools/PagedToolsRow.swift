//
//  PagedToolsRow.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 27.03.2026.
//

import SwiftUI

struct PagedToolsRow: View {

    // MARK: - States

    @State private var currentPageID = 0
    @State private var rowHeight = Layout.defaultRowHeight

    // MARK: - Private Properties

    private let toolAvailability: [ToolAvailability]
    private let presentation: (ToolEnum) -> EditorToolbarItemPresentation
    private let action: (ToolAvailability) -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let metrics = EditorToolbarLayoutResolver.resolvedMetrics(
                    for: proxy.size.width
                )
                let resolvedToolPages = resolvedToolPages(
                    for: metrics
                )

                let shouldCenterRow =
                    toolAvailability.count <= metrics.itemsPerPage
                    && metrics.shouldCenterRowContent(
                        for: resolvedToolPages.first?.map(\.width) ?? [],
                        availableWidth: proxy.size.width
                    )

                ScrollView(.horizontal) {
                    AdaptativeGlassContainer(spacing: metrics.itemSpacing) {
                        LazyHStack(spacing: metrics.pageSpacing) {
                            ForEach(Array(resolvedToolPages.enumerated()), id: \.offset) { index, page in
                                HStack(spacing: metrics.itemSpacing) {
                                    ForEach(page) { item in
                                        ToolButtonView(
                                            item.presentation.title,
                                            image: item.presentation.image,
                                            subtitle: item.presentation.subtitle,
                                            isChange: item.presentation.isApplied,
                                            isBlocked: item.availability.isBlocked,
                                            horizontalPadding: metrics.itemHorizontalPadding
                                        ) {
                                            action(item.availability)
                                        }
                                        .frame(
                                            width: item.width,
                                            height: metrics.itemHeight
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(
                                    minWidth: metrics.pageWidth(
                                        for: page.map(\.width)
                                    ),
                                    alignment: .leading
                                )
                                .background(pageOffsetReader(for: index))
                                .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .frame(
                        minWidth: proxy.size.width,
                        alignment: shouldCenterRow ? .center : .leading
                    )
                }
                .coordinateSpace(name: Layout.scrollCoordinateSpaceName)
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .onPreferenceChange(ToolPageMinXPreferenceKey.self) { pageOffsets in
                    guard
                        let resolvedPageID = PagedToolsRowPageSelectionResolver.selectedPageID(
                            from: pageOffsets
                        ),
                        resolvedPageID != currentPageID
                    else {
                        return
                    }

                    currentPageID = resolvedPageID
                }
                .onAppear {
                    updateRowHeight(for: proxy.size.width)
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    updateRowHeight(for: newWidth)
                }
            }
            .frame(height: rowHeight)

            if shouldShowPagination {
                pagination
            }
        }
    }

    // MARK: - Initializer

    init(
        _ tools: [ToolAvailability],
        presentation: @escaping (ToolEnum) -> EditorToolbarItemPresentation,
        action: @escaping (ToolAvailability) -> Void
    ) {
        self.toolAvailability = tools
        self.presentation = presentation
        self.action = action
    }

    // MARK: - Private Properties

    private var toolPages: [[ToolAvailability]] {
        toolAvailability.chunked(
            into: EditorToolbarLayoutResolver.itemsPerPage
        )
    }

    private var shouldShowPagination: Bool {
        toolPages.count > 1
    }

    private var pagination: some View {
        HStack(spacing: 8) {
            ForEach(Array(toolPages.indices), id: \.self) { index in
                Capsule()
                    .fill(index == currentPageID ? Theme.primary : Theme.secondary.opacity(0.4))
                    .frame(
                        width: index == currentPageID ? Layout.activeIndicatorWidth : Layout.indicatorSize,
                        height: Layout.indicatorSize
                    )
                    .animation(.snappy(duration: 0.18), value: currentPageID)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Private Methods

    private func updateRowHeight(for availableWidth: CGFloat) {
        let resolvedRowHeight = EditorToolbarLayoutResolver.resolvedMetrics(
            for: availableWidth
        ).rowHeight

        guard abs(rowHeight - resolvedRowHeight) > 0.0001 else { return }
        rowHeight = resolvedRowHeight
    }

    private func pageOffsetReader(for pageID: Int) -> some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: ToolPageMinXPreferenceKey.self,
                    value: [
                        pageID: geometry.frame(in: .named(Layout.scrollCoordinateSpaceName)).minX
                    ]
                )
        }
    }

    private func resolvedToolPages(
        for metrics: EditorToolbarLayoutMetrics
    ) -> [[ResolvedToolItem]] {
        toolPages.map { page in
            page.map { availability in
                let itemPresentation = presentation(availability.tool)

                return ResolvedToolItem(
                    availability: availability,
                    presentation: itemPresentation,
                    width: ToolButtonWidthResolver.resolvedWidth(
                        title: itemPresentation.title,
                        subtitle: itemPresentation.subtitle,
                        minimumWidth: metrics.minimumItemWidth,
                        horizontalPadding: metrics.itemHorizontalPadding
                    )
                )
            }
        }
    }

}

extension PagedToolsRow {

    fileprivate struct ResolvedToolItem: Identifiable {

        // MARK: - Public Properties

        let availability: ToolAvailability
        let presentation: EditorToolbarItemPresentation
        let width: CGFloat

        var id: ToolEnum {
            availability.tool
        }

    }

    fileprivate enum Layout {

        // MARK: - Public Properties

        static let defaultRowHeight: CGFloat = 104
        static let indicatorSize: CGFloat = 6
        static let activeIndicatorWidth: CGFloat = 18
        static let scrollCoordinateSpaceName = "PagedToolsRowScrollView"

    }

}

struct PagedToolsRowPageSelectionResolver {

    // MARK: - Public Methods

    static func selectedPageID(
        from pageOffsets: [Int: CGFloat]
    ) -> Int? {
        pageOffsets.min { leftPage, rightPage in
            let leftDistance = abs(leftPage.value)
            let rightDistance = abs(rightPage.value)

            guard abs(leftDistance - rightDistance) > 0.0001 else {
                return leftPage.key < rightPage.key
            }

            return leftDistance < rightDistance
        }?.key
    }

}

private struct ToolPageMinXPreferenceKey: PreferenceKey {

    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(
        value: inout [Int: CGFloat],
        nextValue: () -> [Int: CGFloat]
    ) {
        value.merge(
            nextValue(),
            uniquingKeysWith: { _, next in next }
        )
    }

}

extension Array {

    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }

}

#Preview {
    PagedToolsRow(
        ToolEnum.all.map { ToolAvailability($0) }
    ) { tool in
        .init(
            title: tool.title,
            image: tool.image,
            subtitle: tool == .presets ? "Social 9:16" : nil,
            isApplied: tool == .presets
        )
    } action: { _ in
    }
}

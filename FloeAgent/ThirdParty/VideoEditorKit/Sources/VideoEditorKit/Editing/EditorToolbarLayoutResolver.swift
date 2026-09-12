import CoreGraphics
import Foundation

public struct EditorToolbarLayoutMetrics: Equatable, Sendable {

    // MARK: - Public Properties

    public let itemsPerPage: Int
    public let pageMinimumWidth: CGFloat
    public let minimumItemWidth: CGFloat
    public let itemHeight: CGFloat
    public let itemHorizontalPadding: CGFloat
    public let itemSpacing: CGFloat
    public let pageSpacing: CGFloat
    public let rowHeight: CGFloat

    // MARK: - Initializer

    public init(
        itemsPerPage: Int,
        pageMinimumWidth: CGFloat,
        minimumItemWidth: CGFloat,
        itemHeight: CGFloat,
        itemHorizontalPadding: CGFloat,
        itemSpacing: CGFloat,
        pageSpacing: CGFloat,
        rowHeight: CGFloat
    ) {
        self.itemsPerPage = itemsPerPage
        self.pageMinimumWidth = pageMinimumWidth
        self.minimumItemWidth = minimumItemWidth
        self.itemHeight = itemHeight
        self.itemHorizontalPadding = itemHorizontalPadding
        self.itemSpacing = itemSpacing
        self.pageSpacing = pageSpacing
        self.rowHeight = rowHeight
    }

    // MARK: - Public Methods

    public func pageContentWidth(
        for itemCount: Int
    ) -> CGFloat {
        pageContentWidth(
            for: Array(
                repeating: minimumItemWidth,
                count: itemCount
            )
        )
    }

    public func pageContentWidth(
        for itemWidths: [CGFloat]
    ) -> CGFloat {
        guard itemWidths.isEmpty == false else { return 0 }

        return itemWidths.reduce(0, +)
            + (itemSpacing * CGFloat(max(itemWidths.count - 1, 0)))
    }

    public func pageWidth(
        for itemCount: Int
    ) -> CGFloat {
        pageWidth(
            for: Array(
                repeating: minimumItemWidth,
                count: itemCount
            )
        )
    }

    public func pageWidth(
        for itemWidths: [CGFloat]
    ) -> CGFloat {
        max(
            pageMinimumWidth,
            pageContentWidth(for: itemWidths)
        )
    }

    public func shouldCenterRowContent(
        for itemCount: Int,
        availableWidth: CGFloat
    ) -> Bool {
        shouldCenterRowContent(
            for: Array(
                repeating: minimumItemWidth,
                count: itemCount
            ),
            availableWidth: availableWidth
        )
    }

    public func shouldCenterRowContent(
        for itemWidths: [CGFloat],
        availableWidth: CGFloat
    ) -> Bool {
        guard itemWidths.isEmpty == false else { return false }
        guard itemWidths.count <= itemsPerPage else { return false }

        return pageContentWidth(for: itemWidths) < availableWidth
    }

}

public enum EditorToolbarLayoutResolver {

    // MARK: - Public Properties

    public static let itemsPerPage = Constants.itemsPerPage

    // MARK: - Private Properties

    private enum Constants {
        static let itemsPerPage = 4
        static let itemSpacing: CGFloat = 10
        static let pageSpacing: CGFloat = 10
        static let previewWidth: CGFloat = 28
        static let horizontalInset: CGFloat = 0
        static let itemHeight: CGFloat = 104
        static let itemHorizontalPadding: CGFloat = 12
    }

    // MARK: - Public Methods

    public static func resolvedMetrics(
        for availableWidth: CGFloat
    ) -> EditorToolbarLayoutMetrics {
        let visibleWidth = max(availableWidth - (Constants.horizontalInset * 2), 0)
        let pageMinimumWidth = max(
            visibleWidth - Constants.previewWidth - Constants.pageSpacing,
            0
        )
        let minimumItemWidth = max(
            (pageMinimumWidth
                - (Constants.itemSpacing
                    * CGFloat(Constants.itemsPerPage - 1)))
                / CGFloat(Constants.itemsPerPage),
            0
        )

        return .init(
            itemsPerPage: Constants.itemsPerPage,
            pageMinimumWidth: pageMinimumWidth,
            minimumItemWidth: minimumItemWidth,
            itemHeight: Constants.itemHeight,
            itemHorizontalPadding: Constants.itemHorizontalPadding,
            itemSpacing: Constants.itemSpacing,
            pageSpacing: Constants.pageSpacing,
            rowHeight: Constants.itemHeight
        )
    }

}

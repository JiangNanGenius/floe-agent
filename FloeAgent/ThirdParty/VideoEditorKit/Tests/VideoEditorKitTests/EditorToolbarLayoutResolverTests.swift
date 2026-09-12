import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("EditorToolbarLayoutResolverTests")
struct EditorToolbarLayoutResolverTests {

    // MARK: - Public Methods

    @Test
    func resolvedMetricsKeepFourItemsAcrossCommonViewportWidths() {
        let viewportWidths: [CGFloat] = [320, 375, 393, 430, 768, 1024]

        for viewportWidth in viewportWidths {
            let metrics = EditorToolbarLayoutResolver.resolvedMetrics(
                for: viewportWidth
            )
            let occupiedPageWidth =
                (metrics.minimumItemWidth * CGFloat(metrics.itemsPerPage))
                + (metrics.itemSpacing
                    * CGFloat(metrics.itemsPerPage - 1))

            #expect(metrics.itemsPerPage == 4)
            #expect(metrics.minimumItemWidth > 0)
            #expect(metrics.itemHeight == 104)
            #expect(metrics.itemHorizontalPadding == 12)
            #expect(abs(metrics.rowHeight - metrics.itemHeight) < 0.0001)
            #expect(abs(occupiedPageWidth - metrics.pageMinimumWidth) < 0.0001)
        }
    }

    @Test
    func resolvedMetricsClampToZeroForCollapsedWidths() {
        let metrics = EditorToolbarLayoutResolver.resolvedMetrics(for: 0)

        #expect(metrics.itemsPerPage == 4)
        #expect(metrics.pageMinimumWidth == 0)
        #expect(metrics.minimumItemWidth == 0)
        #expect(metrics.rowHeight == 104)
    }

    @Test
    func metricsCenterRowsThatFitTheVisibleWidth() {
        let metrics = EditorToolbarLayoutResolver.resolvedMetrics(for: 393)

        #expect(
            metrics.shouldCenterRowContent(
                for: 1,
                availableWidth: 393
            )
        )
        #expect(
            metrics.shouldCenterRowContent(
                for: 2,
                availableWidth: 393
            )
        )
        #expect(
            metrics.shouldCenterRowContent(
                for: 3,
                availableWidth: 393
            )
        )
        #expect(
            metrics.shouldCenterRowContent(
                for: 4,
                availableWidth: 393
            )
        )
        #expect(
            metrics.shouldCenterRowContent(
                for: 5,
                availableWidth: 393
            ) == false
        )
    }

    @Test
    func pageWidthKeepsPartialPagesAlignedToThePagingViewport() {
        let metrics = EditorToolbarLayoutResolver.resolvedMetrics(for: 393)

        #expect(
            abs(metrics.pageWidth(for: 1) - metrics.pageMinimumWidth) < 0.0001
        )
        #expect(
            abs(metrics.pageWidth(for: 2) - metrics.pageMinimumWidth) < 0.0001
        )
        #expect(
            abs(metrics.pageWidth(for: 4) - metrics.pageMinimumWidth) < 0.0001
        )
    }

    @Test
    func pageWidthExpandsWhenAnItemNeedsMoreHorizontalSpace() {
        let metrics = EditorToolbarLayoutResolver.resolvedMetrics(for: 393)
        let widenedItemWidths = [
            metrics.minimumItemWidth,
            metrics.minimumItemWidth,
            metrics.minimumItemWidth + 48,
            metrics.minimumItemWidth,
        ]

        #expect(
            metrics.pageWidth(for: widenedItemWidths) > metrics.pageMinimumWidth
        )
    }

    @Test
    func centeringUsesResolvedVariableItemWidths() {
        let metrics = EditorToolbarLayoutResolver.resolvedMetrics(for: 393)
        let widenedItemWidths = [
            metrics.minimumItemWidth + 120,
            metrics.minimumItemWidth,
            metrics.minimumItemWidth,
            metrics.minimumItemWidth,
        ]

        #expect(
            metrics.shouldCenterRowContent(
                for: widenedItemWidths,
                availableWidth: 393
            ) == false
        )
    }

}

import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("PagedToolsRowPageSelectionResolverTests")
struct PagedToolsRowPageSelectionResolverTests {

    // MARK: - Public Methods

    @Test
    func selectedPageIDReturnsNilWhenNoPagesAreVisible() {
        let selectedPageID = PagedToolsRowPageSelectionResolver.selectedPageID(
            from: [:]
        )

        #expect(selectedPageID == nil)
    }

    @Test
    func selectedPageIDUsesThePageClosestToTheLeadingEdge() {
        let selectedPageID = PagedToolsRowPageSelectionResolver.selectedPageID(
            from: [
                0: -210,
                1: 6,
            ]
        )

        #expect(selectedPageID == 1)
    }

    @Test
    func selectedPageIDKeepsTheLowerIndexWhenTwoPagesAreEquallyClose() {
        let selectedPageID = PagedToolsRowPageSelectionResolver.selectedPageID(
            from: [
                0: -12,
                1: 12,
            ]
        )

        #expect(selectedPageID == 0)
    }

}

import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("ToolButtonWidthResolverTests")
struct ToolButtonWidthResolverTests {

    // MARK: - Public Methods

    @Test
    func compactContentKeepsTheBaselineToolbarWidth() {
        let width = ToolButtonWidthResolver.resolvedWidth(
            title: "Cut",
            subtitle: nil,
            minimumWidth: 83.75,
            horizontalPadding: 12
        )

        #expect(abs(width - 83.75) < 0.0001)
    }

    @Test
    func longerAppliedContentExpandsTheToolbarItemWidth() {
        let width = ToolButtonWidthResolver.resolvedWidth(
            title: "Transcript",
            subtitle: "Bottom/Large",
            minimumWidth: 83.75,
            horizontalPadding: 12
        )

        #expect(width > 83.75)
    }

}

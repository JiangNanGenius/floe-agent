import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("RangeSliderMaskedRegionStyleTests")
struct RangeSliderMaskedRegionStyleTests {

    // MARK: - Public Methods

    @Test
    func maskedRegionUsesTheSharedEightPointCornerRadius() {
        #expect(RangeSliderMaskedRegionStyle.cornerRadius == 8)
    }

}

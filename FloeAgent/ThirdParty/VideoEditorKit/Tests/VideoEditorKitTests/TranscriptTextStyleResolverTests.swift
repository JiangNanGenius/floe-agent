import SwiftUI
import Testing

@testable import VideoEditorKit

#if canImport(UIKit)
    import UIKit
    private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
    import AppKit
    private typealias PlatformColor = NSColor
#endif

@Suite("TranscriptTextStyleResolverTests")
struct TranscriptTextStyleResolverTests {

    // MARK: - Public Methods

    @Test
    func attributedStringIncludesStrokeAttributesWhenStyleRequestsStroke() throws {
        let attributedString = TranscriptTextStyleResolver.attributedString(
            text: "Caption",
            style: .init(
                id: UUID(),
                name: "Outlined",
                fontWeight: .heavy,
                hasStroke: true,
                textAlignment: .trailing,
                textColor: .white,
                strokeColor: .black
            ),
            fontSize: 32
        )

        let attributes = attributedString.attributes(
            at: 0,
            effectiveRange: nil
        )

        #expect(attributes[.strokeWidth] as? CGFloat == -4)
        let strokeColorComponents = (attributes[.strokeColor] as? PlatformColor)?.rgbaComponents

        #expect(strokeColorComponents?.red == 0)
        #expect(strokeColorComponents?.green == 0)
        #expect(strokeColorComponents?.blue == 0)
        #expect(strokeColorComponents?.alpha == 1)
        #expect(
            (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment == .right
        )
    }

    @Test
    func attributedStringOmitsStrokeAttributesWhenStyleDoesNotUseStroke() {
        let attributedString = TranscriptTextStyleResolver.attributedString(
            text: "Caption",
            style: .init(
                id: UUID(),
                name: "Plain",
                fontWeight: .semibold
            ),
            fontSize: 32
        )

        let attributes = attributedString.attributes(
            at: 0,
            effectiveRange: nil
        )

        #expect(attributes[.strokeWidth] == nil)
        #expect(attributes[.strokeColor] == nil)
    }

    @Test
    func attributedStringCanRenderFillOnlyTextWithAColorOverride() {
        let attributedString = TranscriptTextStyleResolver.attributedString(
            text: "Caption",
            style: .init(
                id: UUID(),
                name: "Outlined",
                fontWeight: .heavy,
                hasStroke: true,
                textAlignment: .center,
                textColor: .white,
                strokeColor: .black
            ),
            fontSize: 32,
            textColorOverride: .black,
            includesStroke: false
        )

        let attributes = attributedString.attributes(
            at: 0,
            effectiveRange: nil
        )
        let foregroundColorComponents = (attributes[.foregroundColor] as? PlatformColor)?.rgbaComponents

        #expect(attributes[.strokeWidth] == nil)
        #expect(attributes[.strokeColor] == nil)
        #expect(foregroundColorComponents?.red == 0)
        #expect(foregroundColorComponents?.green == 0)
        #expect(foregroundColorComponents?.blue == 0)
        #expect(foregroundColorComponents?.alpha == 1)
    }

    @Test
    func transcriptStyleDecodesLegacyFontFieldsIntoAStableFontWeight() throws {
        let data = try #require(
            """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Legacy",
              "fontFamily": "Avenir Next",
              "isItalic": true,
              "hasStroke": false,
              "textAlignment": "center",
              "textColor": {
                "red": 1,
                "green": 1,
                "blue": 1,
                "alpha": 1
              }
            }
            """.data(using: .utf8)
        )

        let style = try JSONDecoder().decode(TranscriptStyle.self, from: data)

        #expect(style.fontWeight == .heavy)
    }

    @Test
    func resolvedStrokeOffsetsUseADenserCircularOutlineAtFourPixels() {
        let offsets = TranscriptTextStyleResolver.resolvedStrokeOffsets()
        let containsIntermediateCircularSample = offsets.contains { offset in
            abs(offset.width) > 0.1
                && abs(offset.height) > 0.1
                && abs(abs(offset.width) - 2) > 0.1
                && abs(abs(offset.height) - 2) > 0.1
        }

        #expect(TranscriptTextStyleResolver.strokeWidth == 4)
        #expect(TranscriptTextStyleResolver.strokeOffset == 2)
        #expect(TranscriptTextStyleResolver.strokeSampleCount == 16)
        #expect(offsets.count == 16)
        #expect(
            offsets.contains(where: { abs($0.width + 2) < 0.0001 && abs($0.height) < 0.0001 })
        )
        #expect(containsIntermediateCircularSample)
    }

    @Test
    func resolvedStrokeOffsetsScaleLinearlyForLargerExportFontSizes() {
        let offsets = TranscriptTextStyleResolver.resolvedStrokeOffsets(
            for: 80
        )
        let containsNegativeHorizontalOffset = offsets.contains { offset in
            abs(offset.width + 8) < 0.0001 && abs(offset.height) < 0.0001
        }
        let containsIntermediateCircularSample = offsets.contains { offset in
            abs(offset.width) > 0.1
                && abs(offset.height) > 0.1
                && abs(abs(offset.width) - 8) > 0.1
                && abs(abs(offset.height) - 8) > 0.1
        }

        #expect(offsets.count == 16)
        #expect(containsNegativeHorizontalOffset)
        #expect(containsIntermediateCircularSample)
        #expect(TranscriptTextStyleResolver.resolvedTextLayerContentsScale(for: 80) == 8)
    }

}

extension PlatformColor {

    fileprivate var rgbaComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        #if canImport(UIKit)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0

            guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }

            return (red, green, blue, alpha)
        #elseif canImport(AppKit)
            guard let rgbColor = usingColorSpace(.deviceRGB) else { return nil }

            return (
                rgbColor.redComponent,
                rgbColor.greenComponent,
                rgbColor.blueComponent,
                rgbColor.alphaComponent
            )
        #endif
    }

}

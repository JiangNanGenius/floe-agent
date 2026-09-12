import CoreGraphics
import Foundation
import Testing

@testable import VideoEditorKit

@Suite("TranscriptOverlayLayoutResolverTests")
struct TranscriptOverlayLayoutResolverTests {

    // MARK: - Public Methods

    @Test
    func resolveUsesTheFullCanvasWidthForEveryOverlaySize() {
        let smallLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .small,
            text: "Short line"
        )
        let mediumLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Short line"
        )
        let largeLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .large,
            text: "Short line"
        )

        #expect(abs(smallLayout.targetWidth - 1048) < 0.0001)
        #expect(abs(mediumLayout.targetWidth - 1048) < 0.0001)
        #expect(abs(largeLayout.targetWidth - 1048) < 0.0001)
    }

    @Test
    func resolveMovesTheOverlayAcrossTheExpectedVerticalZones() {
        let topLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .top,
            selectedSize: .medium,
            text: "Overlay"
        )
        let centerLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .center,
            selectedSize: .medium,
            text: "Overlay"
        )
        let bottomLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Overlay"
        )

        #expect(topLayout.overlayFrame.midY < centerLayout.overlayFrame.midY)
        #expect(centerLayout.overlayFrame.midY < bottomLayout.overlayFrame.midY)
    }

    @Test
    func resolveDoesNotIncreaseFontSizeWhenTheTextGetsMuchLonger() {
        let shortTextLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Short line"
        )
        let longTextLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "This is a much longer subtitle line that should force the resolver to shrink the font size"
        )

        #expect(longTextLayout.fontSize <= shortTextLayout.fontSize)
    }

    @Test
    func resolveKeepsBottomAlignedOverlaysAnchoredToTheBottomInsetAcrossPresetChanges() {
        let portraitLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Bottom aligned caption"
        )
        let squareLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1080,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Bottom aligned caption"
        )

        #expect(abs((1920 - portraitLayout.overlayFrame.maxY) - 16) < 0.0001)
        #expect(abs((1080 - squareLayout.overlayFrame.maxY) - 16) < 0.0001)
    }

    @Test
    func resolveExpandsTheOverlayHeightToFitAdditionalWrappedLines() {
        let shortTextLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 720,
            videoHeight: 1280,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Short line"
        )
        let multilineLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 720,
            videoHeight: 1280,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text:
                "This transcript segment is intentionally long enough to wrap into multiple lines and needs extra vertical space to stay fully visible inside the preview."
        )

        #expect(multilineLayout.overlayFrame.height > shortTextLayout.overlayFrame.height)
    }

    @Test
    func resolvePreviewLayoutScalesExportAnchoringIntoTheVisiblePreviewCanvas() {
        let previewLayout = TranscriptOverlayLayoutResolver.resolvePreviewLayout(
            exportCanvasSize: CGSize(width: 1080, height: 1920),
            previewCanvasSize: CGSize(width: 270, height: 480),
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Bottom aligned caption"
        )

        #expect(abs((480 - previewLayout.overlayFrame.maxY) - 4) < 0.0001)
        #expect(previewLayout.fontSize > 0)
    }

    @Test
    func resolveMeasuresTheRealTextHeightForCenteredMultilineSegments() {
        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .center,
            selectedSize: .medium,
            text: """
                Edmure, da criacao do universo ao surgimento
                dos elfos e homens, conheca a saga das
                Silmarils
                """
        )

        #expect(abs(layout.overlayFrame.midY - 960) < 0.0001)
        #expect(layout.overlayFrame.height > 0)
    }

    @Test
    func resolveUsesUniformSixteenPointInsetsForBottomOverlaysOnASocialCanvas() {
        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Bottom aligned caption"
        )

        #expect(abs(layout.overlayFrame.minX - 16) < 0.0001)
        #expect(abs((1080 - layout.overlayFrame.maxX) - 16) < 0.0001)
        #expect(abs((1920 - layout.overlayFrame.maxY) - 16) < 0.0001)
    }

    @Test
    func resolveAppliesInternalPaddingToTheTranscriptTextFrame() {
        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Bottom aligned caption"
        )

        #expect(abs(layout.textFrame.minX - 28) < 0.0001)
        #expect(abs((1080 - layout.textFrame.maxX) - 28) < 0.0001)
        #expect(abs(layout.textFrame.minY - (layout.overlayFrame.minY + 16)) < 0.0001)
        #expect(abs(layout.overlayFrame.maxY - layout.textFrame.maxY - 16) < 0.0001)
    }

    @Test
    func resolveMeasuresMultilineHeightUsingThePaddedTextWidth() {
        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text:
                "Edmure, da criacao do universo ao surgimento dos elfos e homens, conheca a saga das Silmarils"
        )

        let measuredTextHeight = TranscriptTextStyleResolver.measuredTextHeight(
            text: "Edmure, da criacao do universo ao surgimento dos elfos e homens, conheca a saga das Silmarils",
            style: TranscriptStyle(
                id: UUID(uuidString: "E5A04D11-329A-4C8E-B266-1E6A60A6F9F9") ?? UUID(),
                name: "Default",
                fontWeight: .bold
            ),
            fontSize: layout.fontSize,
            targetWidth: layout.textFrame.width
        )

        #expect(abs(layout.textFrame.height - measuredTextHeight) < 0.0001)
        #expect(abs(layout.overlayFrame.height - (measuredTextHeight + 32)) < 0.0001)
        #expect(abs((1920 - layout.overlayFrame.maxY) - 16) < 0.0001)
    }

    @Test
    func resolveUsesUniformSixteenPointInsetsForTopOverlaysOnASocialCanvas() {
        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .top,
            selectedSize: .medium,
            text: "Top aligned caption"
        )

        #expect(abs(layout.overlayFrame.minX - 16) < 0.0001)
        #expect(abs((1080 - layout.overlayFrame.maxX) - 16) < 0.0001)
        #expect(abs(layout.overlayFrame.minY - 16) < 0.0001)
    }

    @Test
    func resolveKeepsBottomAnchorAtSixteenPointsForShortAndLongSegments() {
        let shortLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text: "Short caption"
        )
        let longLayout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            text:
                "This is a much longer transcript segment that should still remain anchored to the bottom edge with the same sixteen point margin even when the text expands into multiple visual lines in the social preset canvas."
        )

        #expect(abs((1920 - shortLayout.overlayFrame.maxY) - 16) < 0.0001)
        #expect(abs((1920 - longLayout.overlayFrame.maxY) - 16) < 0.0001)
        #expect(abs(shortLayout.overlayFrame.minX - 16) < 0.0001)
        #expect(abs(longLayout.overlayFrame.minX - 16) < 0.0001)
    }

    @Test
    func resolveSegmentBuildsIndependentWordFramesAcrossMultipleLines() {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 4,
                timelineStartTime: 0,
                timelineEndTime: 4
            ),
            originalText: "one two three four five six seven eight",
            editedText: "one two three four five six seven eight",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0, sourceEndTime: 0.5, timelineStartTime: 0, timelineEndTime: 0.5),
                    originalText: "one", editedText: "one"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.5, sourceEndTime: 1, timelineStartTime: 0.5, timelineEndTime: 1),
                    originalText: "two", editedText: "two"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1, sourceEndTime: 1.5, timelineStartTime: 1, timelineEndTime: 1.5),
                    originalText: "three", editedText: "three"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1.5, sourceEndTime: 2, timelineStartTime: 1.5, timelineEndTime: 2),
                    originalText: "four", editedText: "four"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 2, sourceEndTime: 2.5, timelineStartTime: 2, timelineEndTime: 2.5),
                    originalText: "five", editedText: "five"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 2.5, sourceEndTime: 3, timelineStartTime: 2.5, timelineEndTime: 3),
                    originalText: "six", editedText: "six"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 3, sourceEndTime: 3.5, timelineStartTime: 3, timelineEndTime: 3.5),
                    originalText: "seven", editedText: "seven"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 3.5, sourceEndTime: 4, timelineStartTime: 3.5, timelineEndTime: 4),
                    originalText: "eight", editedText: "eight"),
            ]
        )

        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 320,
            videoHeight: 568,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )

        #expect(layout.wordLayouts.count == 8)
        #expect(Set(layout.wordLayouts.map(\.lineIndex)).count > 1)
        #expect(layout.wordLayouts.map(\.text) == ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        #expect(layout.wordLayouts.allSatisfy { layout.textFrame.contains($0.frame) })
    }

    @Test
    func resolveSegmentCentersEachWrappedLineWhenTheStyleIsCentered() throws {
        let style = TranscriptStyle(
            id: UUID(),
            name: "Centered",
            fontWeight: .bold,
            hasStroke: false,
            textAlignment: .center
        )
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "alpha beta gamma delta epsilon zeta",
            editedText: "alpha beta gamma delta epsilon zeta",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0, sourceEndTime: 0.2, timelineStartTime: 0, timelineEndTime: 0.2),
                    originalText: "alpha", editedText: "alpha"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.2, sourceEndTime: 0.4, timelineStartTime: 0.2, timelineEndTime: 0.4),
                    originalText: "beta", editedText: "beta"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.4, sourceEndTime: 0.6, timelineStartTime: 0.4, timelineEndTime: 0.6),
                    originalText: "gamma", editedText: "gamma"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.6, sourceEndTime: 0.8, timelineStartTime: 0.6, timelineEndTime: 0.8),
                    originalText: "delta", editedText: "delta"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.8, sourceEndTime: 1, timelineStartTime: 0.8, timelineEndTime: 1),
                    originalText: "epsilon", editedText: "epsilon"),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1, sourceEndTime: 1.2, timelineStartTime: 1, timelineEndTime: 1.2),
                    originalText: "zeta", editedText: "zeta"),
            ]
        )

        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 360,
            videoHeight: 640,
            selectedPosition: .center,
            selectedSize: .medium,
            segment: segment,
            style: style
        )
        let lineLayouts = Dictionary(grouping: layout.wordLayouts, by: \.lineIndex)
        let firstLine = try #require(lineLayouts[0])
        let leftInset = (firstLine.map(\.frame.minX).min() ?? 0) - layout.textFrame.minX
        let rightInset = layout.textFrame.maxX - (firstLine.map(\.frame.maxX).max() ?? 0)

        #expect(abs(leftInset - rightInset) < 1.5)
    }

    @Test
    func resolveSegmentReconcilesStandalonePunctuationBeforeBuildingWordLayouts() {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "hello world",
            editedText: "\" Hello , world !",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 0.8,
                        timelineStartTime: 0,
                        timelineEndTime: 0.8
                    ),
                    originalText: "hello",
                    editedText: "hello"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.8,
                        sourceEndTime: 1.6,
                        timelineStartTime: 0.8,
                        timelineEndTime: 1.6
                    ),
                    originalText: "world",
                    editedText: "world"
                ),
            ]
        )

        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 360,
            videoHeight: 640,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )

        #expect(layout.wordLayouts.map(\.text) == ["\"Hello,", "world!"])
    }

    @Test
    func resolveSegmentAddsHorizontalInsetToEachHighlightedWordBlock() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "hello world",
            editedText: "hello world",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 0.8,
                        timelineStartTime: 0,
                        timelineEndTime: 0.8
                    ),
                    originalText: "hello",
                    editedText: "hello"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.8,
                        sourceEndTime: 1.6,
                        timelineStartTime: 0.8,
                        timelineEndTime: 1.6
                    ),
                    originalText: "world",
                    editedText: "world"
                ),
            ]
        )

        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 360,
            videoHeight: 640,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )
        let firstWordLayout = try #require(layout.wordLayouts.first)
        let measuredTextWidth = TranscriptTextStyleResolver.measuredWordWidth(
            text: "hello",
            style: .defaultCaptionStyle,
            fontSize: layout.fontSize
        )

        #expect(
            firstWordLayout.frame.width >= measuredTextWidth + (TranscriptWordHighlightStyle.horizontalInset * 2))
    }

    @Test
    func resolveSegmentUsesTheSharedCompactSpacingBetweenWordBlocks() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "alpha beta",
            editedText: "alpha beta",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "alpha",
                    editedText: "alpha"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1,
                        sourceEndTime: 2,
                        timelineStartTime: 1,
                        timelineEndTime: 2
                    ),
                    originalText: "beta",
                    editedText: "beta"
                ),
            ]
        )

        let layout = TranscriptOverlayLayoutResolver.resolve(
            videoWidth: 480,
            videoHeight: 854,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )
        let firstWord = try #require(layout.wordLayouts.first)
        let secondWord = try #require(layout.wordLayouts.dropFirst().first)
        let gap = secondWord.frame.minX - firstWord.frame.maxX

        #expect(abs(gap - TranscriptWordHighlightStyle.interWordSpacing) < 0.0001)
    }

    @Test
    func resolveRenderPlanUsesWordBlocksWhenTheEditableSegmentRemainsRenderable() {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "alpha beta",
            editedText: "alpha beta",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "alpha",
                    editedText: "alpha"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1,
                        sourceEndTime: 2,
                        timelineStartTime: 1,
                        timelineEndTime: 2
                    ),
                    originalText: "beta",
                    editedText: "beta"
                ),
            ]
        )

        let renderPlan = TranscriptOverlayLayoutResolver.resolveRenderPlan(
            videoWidth: 480,
            videoHeight: 854,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )

        #expect(renderPlan.usesWordBlocks)
        #expect(renderPlan.wordBlocks.map(\.text) == ["alpha", "beta"])
        #expect(renderPlan.wordBlocks.map(\.wordID) == renderPlan.layout.wordLayouts.map(\.wordID))
    }

    @Test
    func resolveRenderPlanKeepsWordBlocksWhenTheSegmentIsHeavilyRewritten() {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "hello world",
            editedText: "greetings brave world",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "hello",
                    editedText: "hello"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1,
                        sourceEndTime: 2,
                        timelineStartTime: 1,
                        timelineEndTime: 2
                    ),
                    originalText: "world",
                    editedText: "world"
                ),
            ]
        )

        let renderPlan = TranscriptOverlayLayoutResolver.resolveRenderPlan(
            videoWidth: 480,
            videoHeight: 854,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )

        #expect(renderPlan.usesWordBlocks)
        #expect(renderPlan.wordBlocks.map(\.text) == ["greetings brave", "world"])
    }

    @Test
    func resolveActiveWordRenderPlansUseTheFullAvailableCaptionWidthForTheVisibleWord() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "hello world",
            editedText: "hello world",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 0.8,
                        timelineStartTime: 0,
                        timelineEndTime: 0.8
                    ),
                    originalText: "hello",
                    editedText: "hello"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0.8,
                        sourceEndTime: 1.6,
                        timelineStartTime: 0.8,
                        timelineEndTime: 1.6
                    ),
                    originalText: "world",
                    editedText: "world"
                ),
            ]
        )

        let renderPlan = try #require(
            TranscriptOverlayLayoutResolver.resolveActiveWordRenderPlans(
                videoWidth: 360,
                videoHeight: 640,
                selectedPosition: .bottom,
                selectedSize: .medium,
                segment: segment
            ).first
        )

        #expect(
            abs(renderPlan.layout.textFrame.minX - renderPlan.layout.overlayFrame.minX - 32) < 0.0001
        )
        #expect(
            abs(renderPlan.layout.overlayFrame.maxX - renderPlan.layout.textFrame.maxX - 32) < 0.0001
        )
        #expect(
            abs(renderPlan.layout.textFrame.minY - renderPlan.layout.overlayFrame.minY - 32) < 0.0001
        )
        #expect(
            abs(renderPlan.layout.overlayFrame.maxY - renderPlan.layout.textFrame.maxY - 32) < 0.0001
        )
        #expect(abs(renderPlan.layout.overlayFrame.midX - 180) < 0.0001)
        #expect(abs(renderPlan.layout.overlayFrame.minX - 16) < 0.0001)
        #expect(abs((360 - renderPlan.layout.overlayFrame.maxX) - 16) < 0.0001)
        #expect(abs(renderPlan.layout.overlayFrame.width - 328) < 0.0001)
        #expect(abs(renderPlan.layout.textFrame.width - 264) < 0.0001)
        #expect(abs((640 - renderPlan.layout.overlayFrame.maxY) - 45) < 0.0001)
    }

    @Test
    func resolveActiveWordLayoutReducesInsetsWhenTheCanvasIsNarrow() {
        let layout = TranscriptOverlayLayoutResolver.resolveActiveWordLayout(
            videoWidth: 120,
            videoHeight: 214,
            selectedPosition: .center,
            selectedSize: .large,
            text: "MMMMMMMMMMMMMMMM",
            style: .defaultCaptionStyle
        )
        let leadingInset = layout.textFrame.minX - layout.overlayFrame.minX
        let trailingInset = layout.overlayFrame.maxX - layout.textFrame.maxX
        let topInset = layout.textFrame.minY - layout.overlayFrame.minY
        let bottomInset = layout.overlayFrame.maxY - layout.textFrame.maxY

        #expect(layout.textFrame.width > 0)
        #expect(layout.textFrame.height > 0)
        #expect(leadingInset < 32)
        #expect(trailingInset < 32)
        #expect(topInset <= 32)
        #expect(bottomInset <= 32)
        #expect(layout.textFrame.maxX <= layout.overlayFrame.maxX)
        #expect(layout.textFrame.maxY <= layout.overlayFrame.maxY)
    }

    @Test
    func resolveActiveWordRenderPlansKeepWordsOnASingleLineWhenThereIsEnoughHorizontalRoom() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 1,
                timelineStartTime: 0,
                timelineEndTime: 1
            ),
            originalText: "Edmure,",
            editedText: "Edmure,",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "Edmure,",
                    editedText: "Edmure,"
                )
            ]
        )

        let renderPlan = try #require(
            TranscriptOverlayLayoutResolver.resolveActiveWordRenderPlans(
                videoWidth: 360,
                videoHeight: 640,
                selectedPosition: .bottom,
                selectedSize: .medium,
                segment: segment
            ).first
        )
        let measuredHeight = TranscriptTextStyleResolver.measuredTextHeight(
            text: renderPlan.text,
            style: .defaultCaptionStyle,
            fontSize: renderPlan.layout.fontSize,
            targetWidth: renderPlan.layout.textFrame.width
        )
        let expectedSingleLineHeight = TranscriptTextStyleResolver.resolvedLineHeight(
            style: .defaultCaptionStyle,
            fontSize: renderPlan.layout.fontSize
        )

        #expect(abs(measuredHeight - expectedSingleLineHeight) < 0.0001)
        #expect(renderPlan.layout.textFrame.width >= 264)
    }

    @Test
    func resolvePreviewActiveWordRenderPlansScaleTheSharedStandaloneWordLayout() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 1,
                timelineStartTime: 0,
                timelineEndTime: 1
            ),
            originalText: "hello",
            editedText: "hello",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "hello",
                    editedText: "hello"
                )
            ]
        )

        let exportPlan = try #require(
            TranscriptOverlayLayoutResolver.resolveActiveWordRenderPlans(
                videoWidth: 1080,
                videoHeight: 1920,
                selectedPosition: .bottom,
                selectedSize: .medium,
                segment: segment
            ).first
        )
        let previewPlan = try #require(
            TranscriptOverlayLayoutResolver.resolvePreviewActiveWordRenderPlans(
                exportCanvasSize: CGSize(width: 1080, height: 1920),
                previewCanvasSize: CGSize(width: 270, height: 480),
                selectedPosition: .bottom,
                selectedSize: .medium,
                segment: segment
            ).first
        )

        #expect(abs(previewPlan.layout.overlayFrame.width - (exportPlan.layout.overlayFrame.width / 4)) < 0.0001)
        #expect(abs(previewPlan.layout.textFrame.minX - (exportPlan.layout.textFrame.minX / 4)) < 0.0001)
        #expect(abs((1920 - exportPlan.layout.overlayFrame.maxY) - 135) < 0.0001)
        #expect(abs((480 - previewPlan.layout.overlayFrame.maxY) - 33.75) < 0.0001)
    }

    @Test
    func resolvePreviewRenderPlanScalesWordBlockFramesWithTheSharedLayout() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "alpha beta",
            editedText: "alpha beta",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "alpha",
                    editedText: "alpha"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1,
                        sourceEndTime: 2,
                        timelineStartTime: 1,
                        timelineEndTime: 2
                    ),
                    originalText: "beta",
                    editedText: "beta"
                ),
            ]
        )

        let exportPlan = TranscriptOverlayLayoutResolver.resolveRenderPlan(
            videoWidth: 1080,
            videoHeight: 1920,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )
        let previewPlan = TranscriptOverlayLayoutResolver.resolvePreviewRenderPlan(
            exportCanvasSize: CGSize(width: 1080, height: 1920),
            previewCanvasSize: CGSize(width: 270, height: 480),
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )
        let exportFirstBlock = try #require(exportPlan.wordBlocks.first)
        let previewFirstBlock = try #require(previewPlan.wordBlocks.first)

        #expect(abs(previewFirstBlock.frame.minX - (exportFirstBlock.frame.minX / 4)) < 0.0001)
        #expect(abs(previewFirstBlock.frame.width - (exportFirstBlock.frame.width / 4)) < 0.0001)
        #expect(abs(previewFirstBlock.textFrame.minX - (exportFirstBlock.textFrame.minX / 4)) < 0.0001)
        #expect(abs(previewFirstBlock.textFrame.width - (exportFirstBlock.textFrame.width / 4)) < 0.0001)
        #expect(previewPlan.usesWordBlocks == exportPlan.usesWordBlocks)
    }

    @Test
    func resolveRenderPlanBuildsWordBlockTextFramesInsideTheirSharedHighlightFrames() throws {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 0,
                sourceEndTime: 2,
                timelineStartTime: 0,
                timelineEndTime: 2
            ),
            originalText: "alpha beta",
            editedText: "alpha beta",
            words: [
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "alpha",
                    editedText: "alpha"
                ),
                .init(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1,
                        sourceEndTime: 2,
                        timelineStartTime: 1,
                        timelineEndTime: 2
                    ),
                    originalText: "beta",
                    editedText: "beta"
                ),
            ]
        )

        let renderPlan = TranscriptOverlayLayoutResolver.resolveRenderPlan(
            videoWidth: 480,
            videoHeight: 854,
            selectedPosition: .bottom,
            selectedSize: .medium,
            segment: segment
        )
        let firstBlock = try #require(renderPlan.wordBlocks.first)

        #expect(firstBlock.frame.contains(firstBlock.textFrame))
        #expect(
            abs(firstBlock.textFrame.minX - firstBlock.frame.minX - TranscriptWordHighlightStyle.horizontalInset)
                < 0.0001)
        #expect(
            abs(firstBlock.frame.maxX - firstBlock.textFrame.maxX - TranscriptWordHighlightStyle.horizontalInset)
                < 0.0001)
    }

}

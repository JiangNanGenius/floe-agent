//
//  TranscriptOverlayLayoutResolver.swift
//  VideoEditorKit
//
//  Created by Codex on 05.04.2026.
//

import CoreGraphics
import Foundation

public enum TranscriptOverlayLayoutResolver {

    private enum Constants {
        static let uniformInset: CGFloat = 16
        static let minimumFontSize: CGFloat = 14
        static let textHorizontalInset: CGFloat = 12
        static let textVerticalInset: CGFloat = 16
        static let activeWordHorizontalInset: CGFloat = 32
        static let activeWordVerticalInset: CGFloat = activeWordHorizontalInset
        static let activeWordOuterVerticalInset: CGFloat = activeWordVerticalInset
    }

    public struct Layout: Equatable {

        // MARK: - Public Properties

        public let overlayFrame: CGRect
        public let textFrame: CGRect
        public let wordLayouts: [WordLayout]
        public let controlsAnchor: CGPoint
        public let targetWidth: CGFloat
        public let fontSize: CGFloat

    }

    public struct WordLayout: Equatable {

        // MARK: - Public Properties

        public let wordID: EditableTranscriptWord.ID
        public let text: String
        public let frame: CGRect
        public let lineIndex: Int

    }

    public struct WordBlock: Equatable {

        // MARK: - Public Properties

        public let wordID: EditableTranscriptWord.ID
        public let text: String
        public let frame: CGRect
        public let textFrame: CGRect
        public let lineIndex: Int
        public let timeRange: ClosedRange<Double>?

    }

    public struct RenderPlan: Equatable {

        // MARK: - Public Properties

        public let layout: Layout
        public let wordBlocks: [WordBlock]
        public let usesWordBlocks: Bool

    }

    public struct ActiveWordRenderPlan: Equatable {

        // MARK: - Public Properties

        public let wordID: EditableTranscriptWord.ID
        public let text: String
        public let layout: Layout
        public let timeRange: ClosedRange<Double>

    }

    private struct PendingWord {

        // MARK: - Public Properties

        let wordID: EditableTranscriptWord.ID
        let text: String
        let width: CGFloat

    }

    private struct PendingLine {

        // MARK: - Public Properties

        let words: [PendingWord]
        let occupiedWidth: CGFloat

    }

    private struct BaseMetrics {

        // MARK: - Public Properties

        let targetWidth: CGFloat
        let textWidth: CGFloat
        let baseFontSize: CGFloat

    }

    // MARK: - Private Properties

    private static let textHeightPadding = Constants.textVerticalInset * 2
    private static let textWidthPadding = Constants.textHorizontalInset * 2
    private static let activeWordTextHeightPadding = Constants.activeWordVerticalInset * 2

    // MARK: - Public Methods

    public static func resolve(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        text: String,
        style: TranscriptStyle? = nil
    ) -> Layout {
        resolveLayout(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            selectedPosition: selectedPosition,
            selectedSize: selectedSize,
            text: text,
            style: style,
            additionalTextMeasurementInset: 0
        )
    }

    public static func resolveRenderPlan(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        segment: EditableTranscriptSegment,
        style: TranscriptStyle? = nil
    ) -> RenderPlan {
        let layout = resolve(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            selectedPosition: selectedPosition,
            selectedSize: selectedSize,
            segment: segment,
            style: style
        )
        let renderableWords = resolvedRenderableWords(
            for: segment
        )
        let wordBlocks = resolvedWordBlocks(
            from: renderableWords,
            layout: layout
        )

        return RenderPlan(
            layout: layout,
            wordBlocks: wordBlocks,
            usesWordBlocks: shouldUseWordBlocks(
                editedText: segment.editedText,
                renderableWords: renderableWords,
                layout: layout
            )
        )
    }

    public static func resolveActiveWordRenderPlans(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        segment: EditableTranscriptSegment,
        style: TranscriptStyle? = nil
    ) -> [ActiveWordRenderPlan] {
        let resolvedStyle = resolvedStyle(for: style)
        let renderableWords = resolvedRenderableWords(
            for: segment
        )

        return renderableWords.compactMap { word in
            let trimmedText = word.editedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedText.isEmpty == false else { return nil }
            guard let timeRange = word.timeMapping.timelineRange else { return nil }
            guard timeRange.upperBound > timeRange.lowerBound else { return nil }

            return ActiveWordRenderPlan(
                wordID: word.id,
                text: trimmedText,
                layout: resolveActiveWordLayout(
                    videoWidth: videoWidth,
                    videoHeight: videoHeight,
                    selectedPosition: selectedPosition,
                    selectedSize: selectedSize,
                    text: trimmedText,
                    style: resolvedStyle
                ),
                timeRange: timeRange
            )
        }
    }

    public static func resolve(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        segment: EditableTranscriptSegment,
        style: TranscriptStyle? = nil
    ) -> Layout {
        guard videoWidth > 0, videoHeight > 0 else {
            return Layout(
                overlayFrame: .zero,
                textFrame: .zero,
                wordLayouts: [],
                controlsAnchor: .zero,
                targetWidth: 0,
                fontSize: 0
            )
        }

        let resolvedStyle = resolvedStyle(for: style)
        let renderableWords = TranscriptWordEditingCoordinator.resolvedWords(
            for: segment
        )
        let metrics = resolveBaseMetrics(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            selectedSize: selectedSize
        )
        let maximumOverlayHeight = max(
            videoHeight - (Constants.activeWordOuterVerticalInset * 2),
            metrics.baseFontSize
        )
        let maximumTextHeight = max(
            maximumOverlayHeight - activeWordTextHeightPadding,
            metrics.baseFontSize
        )
        let fontSize = fittedFontSize(
            startingFrom: metrics.baseFontSize,
            for: renderableWords,
            textWidth: metrics.textWidth,
            maximumTextHeight: maximumTextHeight,
            style: resolvedStyle
        )
        let lineArrangement = resolvedLines(
            for: renderableWords,
            availableWidth: metrics.textWidth,
            fontSize: fontSize,
            style: resolvedStyle
        )
        let measuredTextHeight = measuredWordLayoutHeight(
            lines: lineArrangement,
            fontSize: fontSize,
            style: resolvedStyle
        )
        let layout = layout(
            videoHeight: videoHeight,
            selectedPosition: selectedPosition,
            targetWidth: metrics.targetWidth,
            requestedOverlayHeight: measuredTextHeight + textHeightPadding,
            maximumOverlayHeight: maximumOverlayHeight
        )
        let wordLayouts = resolveWordLayouts(
            lines: lineArrangement,
            in: layout.textFrame,
            fontSize: fontSize,
            style: resolvedStyle
        )

        return Layout(
            overlayFrame: layout.overlayFrame,
            textFrame: layout.textFrame,
            wordLayouts: wordLayouts,
            controlsAnchor: layout.controlsAnchor,
            targetWidth: layout.targetWidth,
            fontSize: fontSize
        )
    }

    // MARK: - Private Methods

    private static func resolveLayout(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        text: String,
        style: TranscriptStyle? = nil,
        additionalTextMeasurementInset: CGFloat
    ) -> Layout {
        guard videoWidth > 0, videoHeight > 0 else {
            return Layout(
                overlayFrame: .zero,
                textFrame: .zero,
                wordLayouts: [],
                controlsAnchor: .zero,
                targetWidth: 0,
                fontSize: 0
            )
        }

        let resolvedStyle = resolvedStyle(for: style)
        let metrics = resolveBaseMetrics(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            selectedSize: selectedSize,
            additionalTextMeasurementInset: additionalTextMeasurementInset
        )
        let maximumOverlayHeight = max(
            videoHeight - (Constants.uniformInset * 2),
            metrics.baseFontSize
        )
        let maximumTextHeight = max(
            maximumOverlayHeight - textHeightPadding,
            metrics.baseFontSize
        )
        let fontSize = fittedFontSize(
            startingFrom: metrics.baseFontSize,
            for: text,
            textWidth: metrics.textWidth,
            maximumTextHeight: maximumTextHeight,
            style: resolvedStyle
        )
        let measuredTextHeight = measuredTextHeight(
            for: text,
            textWidth: metrics.textWidth,
            fontSize: fontSize,
            style: resolvedStyle
        )
        return layout(
            videoHeight: videoHeight,
            selectedPosition: selectedPosition,
            targetWidth: metrics.targetWidth,
            requestedOverlayHeight: measuredTextHeight + textHeightPadding,
            maximumOverlayHeight: maximumOverlayHeight,
            fontSize: fontSize
        )
    }

    public static func resolvePreviewLayout(
        exportCanvasSize: CGSize,
        previewCanvasSize: CGSize,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        text: String,
        style: TranscriptStyle? = nil
    ) -> Layout {
        guard exportCanvasSize.width > 0, exportCanvasSize.height > 0 else {
            return resolve(
                videoWidth: previewCanvasSize.width,
                videoHeight: previewCanvasSize.height,
                selectedPosition: selectedPosition,
                selectedSize: selectedSize,
                text: text,
                style: style
            )
        }

        let exportLayout = resolve(
            videoWidth: exportCanvasSize.width,
            videoHeight: exportCanvasSize.height,
            selectedPosition: selectedPosition,
            selectedSize: selectedSize,
            text: text,
            style: style
        )

        return scaled(
            exportLayout,
            from: exportCanvasSize,
            to: previewCanvasSize
        )
    }

    public static func resolvePreviewRenderPlan(
        exportCanvasSize: CGSize,
        previewCanvasSize: CGSize,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        segment: EditableTranscriptSegment,
        style: TranscriptStyle? = nil
    ) -> RenderPlan {
        guard exportCanvasSize.width > 0, exportCanvasSize.height > 0 else {
            return resolveRenderPlan(
                videoWidth: previewCanvasSize.width,
                videoHeight: previewCanvasSize.height,
                selectedPosition: selectedPosition,
                selectedSize: selectedSize,
                segment: segment,
                style: style
            )
        }

        let exportPlan = resolveRenderPlan(
            videoWidth: exportCanvasSize.width,
            videoHeight: exportCanvasSize.height,
            selectedPosition: selectedPosition,
            selectedSize: selectedSize,
            segment: segment,
            style: style
        )

        return scaled(
            exportPlan,
            from: exportCanvasSize,
            to: previewCanvasSize
        )
    }

    public static func resolvePreviewActiveWordRenderPlans(
        exportCanvasSize: CGSize,
        previewCanvasSize: CGSize,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        segment: EditableTranscriptSegment,
        style: TranscriptStyle? = nil
    ) -> [ActiveWordRenderPlan] {
        guard exportCanvasSize.width > 0, exportCanvasSize.height > 0 else {
            return resolveActiveWordRenderPlans(
                videoWidth: previewCanvasSize.width,
                videoHeight: previewCanvasSize.height,
                selectedPosition: selectedPosition,
                selectedSize: selectedSize,
                segment: segment,
                style: style
            )
        }

        return resolveActiveWordRenderPlans(
            videoWidth: exportCanvasSize.width,
            videoHeight: exportCanvasSize.height,
            selectedPosition: selectedPosition,
            selectedSize: selectedSize,
            segment: segment,
            style: style
        ).map {
            scaled(
                $0,
                from: exportCanvasSize,
                to: previewCanvasSize
            )
        }
    }

    public static func resolvePreviewLayout(
        exportCanvasSize: CGSize,
        previewCanvasSize: CGSize,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        segment: EditableTranscriptSegment,
        style: TranscriptStyle? = nil
    ) -> Layout {
        guard exportCanvasSize.width > 0, exportCanvasSize.height > 0 else {
            return resolve(
                videoWidth: previewCanvasSize.width,
                videoHeight: previewCanvasSize.height,
                selectedPosition: selectedPosition,
                selectedSize: selectedSize,
                segment: segment,
                style: style
            )
        }

        let exportLayout = resolve(
            videoWidth: exportCanvasSize.width,
            videoHeight: exportCanvasSize.height,
            selectedPosition: selectedPosition,
            selectedSize: selectedSize,
            segment: segment,
            style: style
        )

        return scaled(
            exportLayout,
            from: exportCanvasSize,
            to: previewCanvasSize
        )
    }

    private static func scaled(
        _ layout: Layout,
        from exportCanvasSize: CGSize,
        to previewCanvasSize: CGSize
    ) -> Layout {
        guard previewCanvasSize.width > 0, previewCanvasSize.height > 0 else {
            return Layout(
                overlayFrame: .zero,
                textFrame: .zero,
                wordLayouts: [],
                controlsAnchor: .zero,
                targetWidth: 0,
                fontSize: 0
            )
        }

        let widthScale = previewCanvasSize.width / max(exportCanvasSize.width, 1)
        let heightScale = previewCanvasSize.height / max(exportCanvasSize.height, 1)
        let fontScale = min(widthScale, heightScale)
        let overlayFrame = CGRect(
            x: layout.overlayFrame.minX * widthScale,
            y: layout.overlayFrame.minY * heightScale,
            width: layout.overlayFrame.width * widthScale,
            height: layout.overlayFrame.height * heightScale
        )
        let textFrame = CGRect(
            x: layout.textFrame.minX * widthScale,
            y: layout.textFrame.minY * heightScale,
            width: layout.textFrame.width * widthScale,
            height: layout.textFrame.height * heightScale
        )

        return Layout(
            overlayFrame: overlayFrame,
            textFrame: textFrame,
            wordLayouts: layout.wordLayouts.map {
                WordLayout(
                    wordID: $0.wordID,
                    text: $0.text,
                    frame: CGRect(
                        x: $0.frame.minX * widthScale,
                        y: $0.frame.minY * heightScale,
                        width: $0.frame.width * widthScale,
                        height: $0.frame.height * heightScale
                    ),
                    lineIndex: $0.lineIndex
                )
            },
            controlsAnchor: CGPoint(
                x: layout.controlsAnchor.x * widthScale,
                y: layout.controlsAnchor.y * heightScale
            ),
            targetWidth: layout.targetWidth * widthScale,
            fontSize: layout.fontSize * fontScale
        )
    }

    private static func scaled(
        _ renderPlan: RenderPlan,
        from exportCanvasSize: CGSize,
        to previewCanvasSize: CGSize
    ) -> RenderPlan {
        let scaledLayout = scaled(
            renderPlan.layout,
            from: exportCanvasSize,
            to: previewCanvasSize
        )
        let widthScale = previewCanvasSize.width / max(exportCanvasSize.width, 1)
        let heightScale = previewCanvasSize.height / max(exportCanvasSize.height, 1)

        return RenderPlan(
            layout: scaledLayout,
            wordBlocks: renderPlan.wordBlocks.map {
                WordBlock(
                    wordID: $0.wordID,
                    text: $0.text,
                    frame: CGRect(
                        x: $0.frame.minX * widthScale,
                        y: $0.frame.minY * heightScale,
                        width: $0.frame.width * widthScale,
                        height: $0.frame.height * heightScale
                    ),
                    textFrame: CGRect(
                        x: $0.textFrame.minX * widthScale,
                        y: $0.textFrame.minY * heightScale,
                        width: $0.textFrame.width * widthScale,
                        height: $0.textFrame.height * heightScale
                    ),
                    lineIndex: $0.lineIndex,
                    timeRange: $0.timeRange
                )
            },
            usesWordBlocks: renderPlan.usesWordBlocks
        )
    }

    private static func scaled(
        _ renderPlan: ActiveWordRenderPlan,
        from exportCanvasSize: CGSize,
        to previewCanvasSize: CGSize
    ) -> ActiveWordRenderPlan {
        ActiveWordRenderPlan(
            wordID: renderPlan.wordID,
            text: renderPlan.text,
            layout: scaled(
                renderPlan.layout,
                from: exportCanvasSize,
                to: previewCanvasSize
            ),
            timeRange: renderPlan.timeRange
        )
    }

    private static func fittedFontSize(
        startingFrom baseFontSize: CGFloat,
        for text: String,
        textWidth: CGFloat,
        maximumTextHeight: CGFloat,
        style: TranscriptStyle
    ) -> CGFloat {
        var fontSize = baseFontSize
        var estimatedHeight = measuredTextHeight(
            for: text,
            textWidth: textWidth,
            fontSize: fontSize,
            style: style
        )

        guard estimatedHeight > maximumTextHeight else { return fontSize }

        let minimumFontSize = Constants.minimumFontSize

        while estimatedHeight > maximumTextHeight, fontSize > minimumFontSize {
            fontSize = max(fontSize - 1, minimumFontSize)
            estimatedHeight = measuredTextHeight(
                for: text,
                textWidth: textWidth,
                fontSize: fontSize,
                style: style
            )
        }

        return fontSize
    }

    public static func resolveActiveWordLayout(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        selectedSize: TranscriptOverlaySize,
        text: String,
        style: TranscriptStyle
    ) -> Layout {
        guard videoWidth > 0, videoHeight > 0 else {
            return Layout(
                overlayFrame: .zero,
                textFrame: .zero,
                wordLayouts: [],
                controlsAnchor: .zero,
                targetWidth: 0,
                fontSize: 0
            )
        }

        let metrics = resolveBaseMetrics(
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            selectedSize: selectedSize,
            additionalTextMeasurementInset: 0
        )
        let activeWordOuterVerticalInset = resolvedActiveWordOuterVerticalInset(
            for: videoHeight
        )
        let activeWordHorizontalInset = resolvedActiveWordHorizontalInset(
            for: metrics.targetWidth
        )
        let activeWordTextWidth = max(
            metrics.targetWidth - (activeWordHorizontalInset * 2),
            1
        )
        let maximumOverlayHeight = max(
            videoHeight - (activeWordOuterVerticalInset * 2),
            metrics.baseFontSize
        )
        let activeWordVerticalInset = resolvedActiveWordVerticalInset(
            for: maximumOverlayHeight
        )
        let maximumTextHeight = max(
            maximumOverlayHeight - (activeWordVerticalInset * 2),
            metrics.baseFontSize
        )
        let fontSize = fittedSingleLineFontSize(
            startingFrom: metrics.baseFontSize,
            for: text,
            textWidth: activeWordTextWidth,
            maximumTextHeight: maximumTextHeight,
            style: style
        )
        let measuredTextHeight = TranscriptTextStyleResolver.resolvedLineHeight(
            style: style,
            fontSize: fontSize
        )
        let requestedOverlayHeight = measuredTextHeight + (activeWordVerticalInset * 2)
        let overlayHeight = min(requestedOverlayHeight, maximumOverlayHeight)
        let overlayY = resolvedOverlayY(
            videoHeight: videoHeight,
            overlayHeight: overlayHeight,
            selectedPosition: selectedPosition,
            verticalInset: activeWordOuterVerticalInset
        )
        let overlayFrame = CGRect(
            x: Constants.uniformInset,
            y: overlayY,
            width: metrics.targetWidth,
            height: overlayHeight
        )
        let textFrame = overlayFrame.insetBy(
            dx: activeWordHorizontalInset,
            dy: activeWordVerticalInset
        )
        let controlsY = max(overlayFrame.minY - 34, 14)
        let fallbackControlsY = min(overlayFrame.maxY + 34, videoHeight - 14)
        let preferredControlsY = overlayFrame.minY > 52 ? controlsY : fallbackControlsY

        return Layout(
            overlayFrame: overlayFrame,
            textFrame: textFrame,
            wordLayouts: [],
            controlsAnchor: CGPoint(
                x: overlayFrame.midX,
                y: preferredControlsY
            ),
            targetWidth: metrics.targetWidth,
            fontSize: fontSize
        )
    }

    private static func fittedFontSize(
        startingFrom baseFontSize: CGFloat,
        for words: [EditableTranscriptWord],
        textWidth: CGFloat,
        maximumTextHeight: CGFloat,
        style: TranscriptStyle
    ) -> CGFloat {
        var fontSize = baseFontSize
        var estimatedHeight = measuredWordLayoutHeight(
            lines: resolvedLines(
                for: words,
                availableWidth: textWidth,
                fontSize: fontSize,
                style: style
            ),
            fontSize: fontSize,
            style: style
        )

        guard estimatedHeight > maximumTextHeight else { return fontSize }

        let minimumFontSize = Constants.minimumFontSize

        while estimatedHeight > maximumTextHeight, fontSize > minimumFontSize {
            fontSize = max(fontSize - 1, minimumFontSize)
            estimatedHeight = measuredWordLayoutHeight(
                lines: resolvedLines(
                    for: words,
                    availableWidth: textWidth,
                    fontSize: fontSize,
                    style: style
                ),
                fontSize: fontSize,
                style: style
            )
        }

        return fontSize
    }

    private static func fittedSingleLineFontSize(
        startingFrom baseFontSize: CGFloat,
        for text: String,
        textWidth: CGFloat,
        maximumTextHeight: CGFloat,
        style: TranscriptStyle
    ) -> CGFloat {
        var fontSize = baseFontSize
        let minimumFontSize = Constants.minimumFontSize

        while fontSize > minimumFontSize {
            let measuredWidth = TranscriptTextStyleResolver.measuredWordWidth(
                text: text,
                style: style,
                fontSize: fontSize
            )
            let measuredHeight = TranscriptTextStyleResolver.resolvedLineHeight(
                style: style,
                fontSize: fontSize
            )

            if measuredWidth <= textWidth, measuredHeight <= maximumTextHeight {
                return fontSize
            }

            fontSize = max(fontSize - 1, minimumFontSize)
        }

        return fontSize
    }

    private static func measuredTextHeight(
        for text: String,
        textWidth: CGFloat,
        fontSize: CGFloat,
        style: TranscriptStyle
    ) -> CGFloat {
        TranscriptTextStyleResolver.measuredTextHeight(
            text: text,
            style: style,
            fontSize: fontSize,
            targetWidth: textWidth
        )
    }

    private static func resolveWordLayouts(
        for words: [EditableTranscriptWord],
        in textFrame: CGRect,
        fontSize: CGFloat,
        style: TranscriptStyle?
    ) -> [WordLayout] {
        let resolvedStyle = resolvedStyle(for: style)
        let lines = resolvedLines(
            for: words,
            availableWidth: textFrame.width,
            fontSize: fontSize,
            style: resolvedStyle
        )

        return resolveWordLayouts(
            lines: lines,
            in: textFrame,
            fontSize: fontSize,
            style: resolvedStyle
        )
    }

    private static func resolvedWordBlocks(
        from words: [EditableTranscriptWord],
        layout: Layout
    ) -> [WordBlock] {
        let wordsByID = Dictionary(
            uniqueKeysWithValues: words.map { ($0.id, $0) }
        )

        return layout.wordLayouts.compactMap { wordLayout in
            guard let word = wordsByID[wordLayout.wordID] else { return nil }

            return WordBlock(
                wordID: wordLayout.wordID,
                text: wordLayout.text,
                frame: wordLayout.frame,
                textFrame: wordLayout.frame.insetBy(
                    dx: TranscriptWordHighlightStyle.horizontalInset,
                    dy: 0
                ),
                lineIndex: wordLayout.lineIndex,
                timeRange: word.timeMapping.timelineRange
            )
        }
    }

    private static func resolveWordLayouts(
        lines: [PendingLine],
        in textFrame: CGRect,
        fontSize: CGFloat,
        style: TranscriptStyle
    ) -> [WordLayout] {
        let lineHeight = TranscriptTextStyleResolver.resolvedLineHeight(
            style: style,
            fontSize: fontSize
        )
        let interWordSpacing = TranscriptWordHighlightStyle.interWordSpacing

        return lines.enumerated().flatMap { lineIndex, line in
            let alignmentOffset = horizontalOffset(
                for: style.textAlignment,
                availableWidth: textFrame.width,
                occupiedWidth: line.occupiedWidth
            )
            let lineY = textFrame.minY + (CGFloat(lineIndex) * lineHeight)
            var cursorX = textFrame.minX + alignmentOffset

            return line.words.map { word in
                defer {
                    cursorX += word.width + interWordSpacing
                }

                return WordLayout(
                    wordID: word.wordID,
                    text: word.text,
                    frame: CGRect(
                        x: cursorX,
                        y: lineY,
                        width: word.width,
                        height: lineHeight
                    ),
                    lineIndex: lineIndex
                )
            }
        }
    }

    private static func resolvedLines(
        for words: [EditableTranscriptWord],
        availableWidth: CGFloat,
        fontSize: CGFloat,
        style: TranscriptStyle
    ) -> [PendingLine] {
        let interWordSpacing = TranscriptWordHighlightStyle.interWordSpacing

        var lines: [PendingLine] = []
        var currentLineWords: [PendingWord] = []
        var currentLineWidth: CGFloat = 0

        for word in words {
            let trimmedText = word.editedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedText.isEmpty == false else {
                continue
            }

            let measuredWidth = min(
                TranscriptTextStyleResolver.measuredWordWidth(
                    text: trimmedText,
                    style: style,
                    fontSize: fontSize
                ) + (TranscriptWordHighlightStyle.horizontalInset * 2),
                availableWidth
            )
            let pendingWord = PendingWord(
                wordID: word.id,
                text: trimmedText,
                width: measuredWidth
            )
            let candidateWidth =
                currentLineWords.isEmpty
                ? measuredWidth
                : currentLineWidth + interWordSpacing + measuredWidth

            if currentLineWords.isEmpty == false, candidateWidth > availableWidth {
                lines.append(
                    PendingLine(
                        words: currentLineWords,
                        occupiedWidth: currentLineWidth
                    )
                )
                currentLineWords = [pendingWord]
                currentLineWidth = measuredWidth
            } else {
                currentLineWords.append(pendingWord)
                currentLineWidth = candidateWidth
            }
        }

        if currentLineWords.isEmpty == false {
            lines.append(
                PendingLine(
                    words: currentLineWords,
                    occupiedWidth: currentLineWidth
                )
            )
        }

        return lines
    }

    private static func measuredWordLayoutHeight(
        lines: [PendingLine],
        fontSize: CGFloat,
        style: TranscriptStyle
    ) -> CGFloat {
        guard lines.isEmpty == false else { return 0 }

        let lineHeight = TranscriptTextStyleResolver.resolvedLineHeight(
            style: style,
            fontSize: fontSize
        )

        return CGFloat(lines.count) * lineHeight
    }

    private static func resolvedRenderableWords(
        for segment: EditableTranscriptSegment
    ) -> [EditableTranscriptWord] {
        TranscriptWordEditingCoordinator.resolvedWords(
            for: segment
        )
    }

    private static func shouldUseWordBlocks(
        editedText: String,
        renderableWords: [EditableTranscriptWord],
        layout: Layout
    ) -> Bool {
        guard layout.wordLayouts.isEmpty == false else { return false }

        let filteredRenderableTexts =
            renderableWords
            .map(\.editedText)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        if filteredRenderableTexts == layout.wordLayouts.map(\.text) {
            return true
        }

        return normalizedText(editedText)
            == normalizedText(layout.wordLayouts.map(\.text).joined(separator: " "))
    }

    private static func normalizedText(
        _ text: String
    ) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private static func resolveBaseMetrics(
        videoWidth: CGFloat,
        videoHeight: CGFloat,
        selectedSize: TranscriptOverlaySize,
        additionalTextMeasurementInset: CGFloat = 0
    ) -> BaseMetrics {
        let availableWidth = max(videoWidth - (Constants.uniformInset * 2), 0)
        let widthMultiplier: CGFloat
        let baseFontRatio: CGFloat

        switch selectedSize {
        case .small:
            widthMultiplier = 1
            baseFontRatio = 0.038
        case .medium:
            widthMultiplier = 1
            baseFontRatio = 0.05
        case .large:
            widthMultiplier = 1
            baseFontRatio = 0.064
        }

        let targetWidth = availableWidth * widthMultiplier
        let textWidth = max(
            targetWidth - textWidthPadding - additionalTextMeasurementInset,
            1
        )
        let baseFontSize = max(videoHeight * baseFontRatio, Constants.minimumFontSize)

        return BaseMetrics(
            targetWidth: targetWidth,
            textWidth: textWidth,
            baseFontSize: baseFontSize
        )
    }

    private static func layout(
        videoHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        targetWidth: CGFloat,
        requestedOverlayHeight: CGFloat,
        maximumOverlayHeight: CGFloat,
        fontSize: CGFloat = 0
    ) -> Layout {
        let overlayHeight = min(requestedOverlayHeight, maximumOverlayHeight)
        let overlayY = resolvedOverlayY(
            videoHeight: videoHeight,
            overlayHeight: overlayHeight,
            selectedPosition: selectedPosition
        )

        let maximumOverlayY = max(
            videoHeight - overlayHeight - Constants.uniformInset,
            Constants.uniformInset
        )
        let clampedOverlayY = min(max(overlayY, Constants.uniformInset), maximumOverlayY)
        let overlayFrame = CGRect(
            x: Constants.uniformInset,
            y: clampedOverlayY,
            width: targetWidth,
            height: overlayHeight
        )
        let textFrame = overlayFrame.insetBy(
            dx: Constants.textHorizontalInset,
            dy: Constants.textVerticalInset
        )
        let controlsY = max(overlayFrame.minY - 34, 14)
        let fallbackControlsY = min(overlayFrame.maxY + 34, videoHeight - 14)
        let preferredControlsY = overlayFrame.minY > 52 ? controlsY : fallbackControlsY

        return Layout(
            overlayFrame: overlayFrame,
            textFrame: textFrame,
            wordLayouts: [],
            controlsAnchor: CGPoint(
                x: overlayFrame.midX,
                y: preferredControlsY
            ),
            targetWidth: targetWidth,
            fontSize: fontSize
        )
    }

    private static func resolvedOverlayY(
        videoHeight: CGFloat,
        overlayHeight: CGFloat,
        selectedPosition: TranscriptOverlayPosition,
        verticalInset: CGFloat = Constants.uniformInset
    ) -> CGFloat {
        let overlayY: CGFloat

        switch selectedPosition {
        case .top:
            overlayY = verticalInset
        case .center:
            overlayY = (videoHeight - overlayHeight) / 2
        case .bottom:
            overlayY = videoHeight - overlayHeight - verticalInset
        }

        let maximumOverlayY = max(
            videoHeight - overlayHeight - verticalInset,
            verticalInset
        )

        return min(max(overlayY, verticalInset), maximumOverlayY)
    }

    private static func resolvedActiveWordOuterVerticalInset(
        for videoHeight: CGFloat
    ) -> CGFloat {
        max(
            Constants.activeWordOuterVerticalInset,
            ceil(videoHeight * 0.07)
        )
    }

    private static func resolvedActiveWordHorizontalInset(
        for targetWidth: CGFloat
    ) -> CGFloat {
        min(
            Constants.activeWordHorizontalInset,
            max(targetWidth / 4, 0)
        )
    }

    private static func resolvedActiveWordVerticalInset(
        for maximumOverlayHeight: CGFloat
    ) -> CGFloat {
        min(
            Constants.activeWordVerticalInset,
            max(maximumOverlayHeight / 4, 0)
        )
    }

    private static func horizontalOffset(
        for alignment: TranscriptTextAlignment,
        availableWidth: CGFloat,
        occupiedWidth: CGFloat
    ) -> CGFloat {
        switch alignment {
        case .leading:
            0
        case .center:
            max((availableWidth - occupiedWidth) / 2, 0)
        case .trailing:
            max(availableWidth - occupiedWidth, 0)
        }
    }

    private static func resolvedStyle(
        for style: TranscriptStyle?
    ) -> TranscriptStyle {
        style ?? .defaultCaptionStyle
    }

}

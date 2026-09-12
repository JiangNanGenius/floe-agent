//
//  TranscriptOverlayPreview.swift
//  VideoEditorKit
//
//  Created by Codex on 05.04.2026.
//

import SwiftUI

@available(iOS 16.0, *)
@MainActor
public struct TranscriptOverlayPreview: View {

    // MARK: - Public Properties

    let segment: EditableTranscriptSegment
    let activeWordID: EditableTranscriptWord.ID?
    let style: TranscriptStyle?
    let overlayPosition: TranscriptOverlayPosition
    let overlaySize: TranscriptOverlaySize
    let previewCanvasSize: CGSize
    let exportCanvasSize: CGSize

    // MARK: - Body

    public var body: some View {
        let renderPlan = TranscriptOverlayLayoutResolver.resolvePreviewRenderPlan(
            exportCanvasSize: exportCanvasSize,
            previewCanvasSize: previewCanvasSize,
            selectedPosition: overlayPosition,
            selectedSize: overlaySize,
            segment: segment,
            style: resolvedStyle
        )
        let activeWordRenderPlans = TranscriptOverlayLayoutResolver.resolvePreviewActiveWordRenderPlans(
            exportCanvasSize: exportCanvasSize,
            previewCanvasSize: previewCanvasSize,
            selectedPosition: overlayPosition,
            selectedSize: overlaySize,
            segment: segment,
            style: resolvedStyle
        )

        ZStack(alignment: .topLeading) {
            if renderPlan.usesWordBlocks {
                activeWordOverlay(renderPlans: activeWordRenderPlans)
            } else {
                textOverlay(
                    segment.editedText,
                    layout: renderPlan.layout
                )
            }
        }
        .frame(
            width: previewCanvasSize.width,
            height: previewCanvasSize.height,
            alignment: .topLeading
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    // MARK: - Initializer

    public init(
        segment: EditableTranscriptSegment,
        activeWordID: EditableTranscriptWord.ID?,
        style: TranscriptStyle?,
        overlayPosition: TranscriptOverlayPosition,
        overlaySize: TranscriptOverlaySize,
        previewCanvasSize: CGSize,
        exportCanvasSize: CGSize
    ) {
        self.segment = segment
        self.activeWordID = activeWordID
        self.style = style
        self.overlayPosition = overlayPosition
        self.overlaySize = overlaySize
        self.previewCanvasSize = previewCanvasSize
        self.exportCanvasSize = exportCanvasSize
    }

    // MARK: - Private Properties

    private var resolvedStyle: TranscriptStyle {
        style ?? .defaultPreviewStyle
    }

    private var textFrameAlignment: Alignment {
        switch resolvedStyle.textAlignment {
        case .leading:
            .topLeading
        case .center:
            .top
        case .trailing:
            .topTrailing
        }
    }

    private var multilineAlignment: TextAlignment {
        switch resolvedStyle.textAlignment {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }

    // MARK: - Private Methods

    private func textOverlay(
        _ text: String,
        layout: TranscriptOverlayLayoutResolver.Layout,
        allowsWrapping: Bool = true
    ) -> some View {
        let relativeTextFrame = CGRect(
            x: layout.textFrame.minX - layout.overlayFrame.minX,
            y: layout.textFrame.minY - layout.overlayFrame.minY,
            width: layout.textFrame.width,
            height: layout.textFrame.height
        )

        return ZStack(alignment: .topLeading) {
            ZStack(alignment: textFrameAlignment) {
                if resolvedStyle.hasStroke, let strokeColor = resolvedStyle.strokeColor {
                    strokedText(
                        text,
                        color: Color(rgba: strokeColor),
                        fontSize: layout.fontSize,
                        targetWidth: relativeTextFrame.width,
                        allowsWrapping: allowsWrapping
                    )
                }

                overlayText(
                    text,
                    textColor: Color(rgba: resolvedStyle.textColor),
                    fontSize: layout.fontSize,
                    targetWidth: relativeTextFrame.width,
                    allowsWrapping: allowsWrapping
                )
            }
            .frame(
                width: relativeTextFrame.width,
                height: relativeTextFrame.height,
                alignment: textFrameAlignment
            )
            .offset(
                x: relativeTextFrame.minX,
                y: relativeTextFrame.minY
            )
        }
        .frame(
            width: layout.overlayFrame.width,
            height: layout.overlayFrame.height,
            alignment: .topLeading
        )
        .offset(
            x: layout.overlayFrame.minX,
            y: layout.overlayFrame.minY
        )
    }

    @ViewBuilder
    private func activeWordOverlay(
        renderPlans: [TranscriptOverlayLayoutResolver.ActiveWordRenderPlan]
    ) -> some View {
        if let activeWord = activeWord(in: renderPlans) {
            textOverlay(
                activeWord.text,
                layout: activeWord.layout,
                allowsWrapping: false
            )
        }
    }

    private func activeWord(
        in renderPlans: [TranscriptOverlayLayoutResolver.ActiveWordRenderPlan]
    ) -> TranscriptOverlayLayoutResolver.ActiveWordRenderPlan? {
        guard let activeWordID else { return nil }
        return renderPlans.first { $0.wordID == activeWordID }
    }

    @ViewBuilder
    private func overlayText(
        _ text: String,
        textColor: Color,
        fontSize: CGFloat,
        targetWidth: CGFloat,
        allowsWrapping: Bool
    ) -> some View {
        if allowsWrapping {
            Text(text)
                .font(
                    TranscriptTextStyleResolver.resolvedSwiftUIFont(
                        for: resolvedStyle,
                        fontSize: fontSize
                    )
                )
                .foregroundStyle(textColor)
                .multilineTextAlignment(multilineAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    width: targetWidth,
                    alignment: textFrameAlignment
                )
        } else {
            Text(text)
                .font(
                    TranscriptTextStyleResolver.resolvedSwiftUIFont(
                        for: resolvedStyle,
                        fontSize: fontSize
                    )
                )
                .foregroundStyle(textColor)
                .multilineTextAlignment(multilineAlignment)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(
                    width: targetWidth,
                    alignment: textFrameAlignment
                )
        }
    }

    private func strokedText(
        _ text: String,
        color: Color,
        fontSize: CGFloat,
        targetWidth: CGFloat,
        allowsWrapping: Bool
    ) -> some View {
        ZStack {
            ForEach(
                Array(
                    TranscriptTextStyleResolver.resolvedStrokeOffsets(
                        for: fontSize
                    ).enumerated()
                ),
                id: \.offset
            ) { _, offset in
                overlayText(
                    text,
                    textColor: color,
                    fontSize: fontSize,
                    targetWidth: targetWidth,
                    allowsWrapping: allowsWrapping
                )
                .offset(x: offset.width, y: offset.height)
            }
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }

}

extension Color {

    // MARK: - Initializer

    fileprivate init(rgba: RGBAColor) {
        self.init(
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: rgba.alpha
        )
    }

}

extension TranscriptStyle {

    // MARK: - Private Properties

    fileprivate static let defaultPreviewStyle = Self.defaultCaptionStyle

}

#Preview {
    TranscriptOverlayPreview(
        segment: EditableTranscriptSegment(
            id: UUID(),
            timeMapping: TranscriptTimeMapping(
                sourceStartTime: 0,
                sourceEndTime: 3.0
            ),
            originalText: "Hello world",
            editedText: "Hello world"
        ),
        activeWordID: nil,
        style: nil,
        overlayPosition: .bottom,
        overlaySize: .medium,
        previewCanvasSize: CGSize(width: 320, height: 568),
        exportCanvasSize: CGSize(width: 1080, height: 1920)
    )
    .background(.black)
}

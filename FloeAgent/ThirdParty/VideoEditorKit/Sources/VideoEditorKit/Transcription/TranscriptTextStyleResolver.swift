//
//  TranscriptTextStyleResolver.swift
//  VideoEditorKit
//
//  Created by Codex on 07.04.2026.
//

import QuartzCore
import SwiftUI

private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont

public enum TranscriptTextStyleResolver {

    // MARK: - Public Properties

    public static let strokeWidth: CGFloat = 4
    public static let strokeOffset: CGFloat = strokeWidth / 2
    public static let strokeSampleCount = 16

    // MARK: - Private Properties

    private static let referenceStrokeFontSize: CGFloat = 20
    private static let defaultStrokeWidth: CGFloat = -4

    // MARK: - Public Methods

    public static func attributedString(
        text: String,
        style: TranscriptStyle,
        fontSize: CGFloat,
        textColorOverride: RGBAColor? = nil,
        includesStroke: Bool = true,
        isWrapped: Bool = true
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = resolvedTextAlignment(
            for: style.textAlignment
        )
        paragraphStyle.lineBreakMode = isWrapped ? .byWordWrapping : .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(
                style: style,
                fontSize: fontSize
            ),
            .foregroundColor: resolvedPlatformColor(textColorOverride ?? style.textColor),
            .paragraphStyle: paragraphStyle,
        ]

        if includesStroke, style.hasStroke, let strokeColor = style.strokeColor {
            attributes[.strokeColor] = resolvedPlatformColor(strokeColor)
            attributes[.strokeWidth] = defaultStrokeWidth
        }

        return NSAttributedString(
            string: text,
            attributes: attributes
        )
    }

    public static func measuredTextHeight(
        text: String,
        style: TranscriptStyle,
        fontSize: CGFloat,
        targetWidth: CGFloat
    ) -> CGFloat {
        let resolvedFont = resolvedFont(
            style: style,
            fontSize: fontSize
        )
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedText.isEmpty == false else {
            return resolvedLineHeight(for: resolvedFont)
        }

        let attributedText = attributedString(
            text: trimmedText,
            style: style,
            fontSize: fontSize,
            includesStroke: false
        )
        let measurementRect = attributedText.boundingRect(
            with: CGSize(
                width: max(targetWidth, 1),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin],
            context: nil
        )

        return max(
            ceil(measurementRect.height),
            resolvedLineHeight(for: resolvedFont)
        )
    }

    public static func measuredWordWidth(
        text: String,
        style: TranscriptStyle,
        fontSize: CGFloat
    ) -> CGFloat {
        let attributedText = attributedString(
            text: text,
            style: style,
            fontSize: fontSize,
            includesStroke: false
        )
        let measurementRect = attributedText.boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin],
            context: nil
        )

        return ceil(measurementRect.width)
    }

    public static func resolvedLineHeight(
        style: TranscriptStyle,
        fontSize: CGFloat
    ) -> CGFloat {
        resolvedLineHeight(
            for: resolvedFont(
                style: style,
                fontSize: fontSize
            )
        )
    }

    fileprivate static func resolvedFont(
        style: TranscriptStyle,
        fontSize: CGFloat
    ) -> PlatformFont {
        let resolvedFont = PlatformFont.systemFont(
            ofSize: fontSize,
            weight: resolvedPlatformFontWeight(for: style.fontWeight)
        )

        guard let roundedDescriptor = resolvedFont.fontDescriptor.withDesign(.rounded) else {
            return resolvedFont
        }

        return PlatformFont(
            descriptor: roundedDescriptor,
            size: fontSize
        )
    }

    static func resolvedTextAlignment(
        for alignment: TranscriptTextAlignment
    ) -> NSTextAlignment {
        switch alignment {
        case .leading:
            .left
        case .center:
            .center
        case .trailing:
            .right
        }
    }

    public static func resolvedCATextAlignment(
        for alignment: TranscriptTextAlignment
    ) -> CATextLayerAlignmentMode {
        switch alignment {
        case .leading:
            .left
        case .center:
            .center
        case .trailing:
            .right
        }
    }

    fileprivate static func resolvedPlatformColor(
        _ color: RGBAColor
    ) -> PlatformColor {
        PlatformColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }

    static func resolvedSwiftUIFont(
        for style: TranscriptStyle,
        fontSize: CGFloat
    ) -> Font {
        .system(
            size: fontSize,
            weight: resolvedSwiftUIFontWeight(for: style.fontWeight),
            design: .rounded
        )
    }

    public static func resolvedStrokeOffsets() -> [CGSize] {
        resolvedStrokeOffsets(
            for: referenceStrokeFontSize
        )
    }

    public static func resolvedStrokeOffsets(
        for fontSize: CGFloat
    ) -> [CGSize] {
        let scale = max(
            fontSize / referenceStrokeFontSize,
            1
        )
        let radius = strokeOffset * scale

        return (0..<strokeSampleCount).map { index in
            let angle = (CGFloat(index) / CGFloat(strokeSampleCount)) * 2 * .pi
            return CGSize(
                width: cos(angle) * radius,
                height: sin(angle) * radius
            )
        }
    }

    public static func resolvedTextLayerContentsScale(
        for fontSize: CGFloat
    ) -> CGFloat {
        min(
            max(
                ceil(fontSize / referenceStrokeFontSize * 2),
                2
            ),
            8
        )
    }

    // MARK: - Private Methods

    private static func resolvedLineHeight(
        for font: PlatformFont
    ) -> CGFloat {
        ceil(font.lineHeight)
    }

    private static func resolvedPlatformFontWeight(
        for fontWeight: TranscriptFontWeight
    ) -> PlatformFont.Weight {
        switch fontWeight {
        case .regular:
            .regular
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        }
    }

    private static func resolvedSwiftUIFontWeight(
        for fontWeight: TranscriptFontWeight
    ) -> Font.Weight {
        switch fontWeight {
        case .regular:
            .regular
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        }
    }

}

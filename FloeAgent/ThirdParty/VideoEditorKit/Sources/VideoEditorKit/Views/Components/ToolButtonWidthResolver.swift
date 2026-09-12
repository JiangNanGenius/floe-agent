import CoreGraphics
import SwiftUI

struct ToolButtonWidthResolver {

    // MARK: - Public Methods

    static func resolvedWidth(
        title: String,
        subtitle: String?,
        minimumWidth: CGFloat,
        horizontalPadding: CGFloat
    ) -> CGFloat {
        let contentWidth = max(
            Layout.iconMinimumWidth,
            textWidth(
                for: title,
                font: Layout.titleFont
            ),
            textWidth(
                for: subtitle,
                font: Layout.subtitleFont
            )
        )

        return max(
            minimumWidth,
            ceil(contentWidth + (horizontalPadding * 2))
        )
    }

    // MARK: - Private Methods

    private static func textWidth(
        for text: String?,
        font: UIFont
    ) -> CGFloat {
        guard let text, text.isEmpty == false else { return 0 }

        return ceil(
            (text as NSString).size(
                withAttributes: [.font: font]
            ).width
        )
    }

}

extension ToolButtonWidthResolver {

    private enum Layout {

        // MARK: - Public Properties

        static let iconMinimumWidth: CGFloat = 18
        static let titleFont = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .medium
        )
        static let subtitleFont = UIFont.preferredFont(forTextStyle: .caption2)

    }

}

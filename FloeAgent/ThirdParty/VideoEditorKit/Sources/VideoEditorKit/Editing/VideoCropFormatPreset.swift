import CoreGraphics
import Foundation

public enum VideoCropFormatPreset: String, CaseIterable, Identifiable, Sendable {

    // MARK: - Public Properties

    case original
    case vertical9x16
    case square1x1
    case portrait4x5
    case landscape16x9

    public static let editorPresets = Self.allCases

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .original:
            VideoEditorStrings.cropOriginalTitle
        case .vertical9x16:
            VideoEditorStrings.cropSocialTitle
        case .square1x1:
            VideoEditorStrings.cropSquareTitle
        case .portrait4x5:
            VideoEditorStrings.cropPortraitTitle
        case .landscape16x9:
            VideoEditorStrings.cropLandscapeTitle
        }
    }

    public var subtitle: String {
        switch self {
        case .original:
            VideoEditorStrings.cropOriginalSubtitle
        case .vertical9x16:
            VideoEditorStrings.cropSocialSubtitle
        case .square1x1:
            VideoEditorStrings.cropSquareSubtitle
        case .portrait4x5:
            VideoEditorStrings.cropPortraitSubtitle
        case .landscape16x9:
            VideoEditorStrings.cropLandscapeSubtitle
        }
    }

    public var dimensionTitle: String {
        switch self {
        case .original:
            VideoEditorStrings.cropOriginalDimension
        case .vertical9x16:
            "9:16"
        case .square1x1:
            "1:1"
        case .portrait4x5:
            "4:5"
        case .landscape16x9:
            "16:9"
        }
    }

    public var aspectRatio: CGFloat? {
        switch self {
        case .original:
            nil
        case .vertical9x16:
            9.0 / 16.0
        case .square1x1:
            1
        case .portrait4x5:
            4.0 / 5.0
        case .landscape16x9:
            16.0 / 9.0
        }
    }

    public var isSocialVideoPreset: Bool {
        switch self {
        case .vertical9x16:
            true
        case .original, .square1x1, .portrait4x5, .landscape16x9:
            false
        }
    }

    // MARK: - Public Methods

    public func makeFreeformRect(
        for referenceSize: CGSize
    ) -> VideoEditingConfiguration.FreeformRect? {
        guard let aspectRatio else { return nil }
        guard referenceSize.width > 0, referenceSize.height > 0 else { return nil }

        let cropRect = Self.resolvedCropRect(
            aspectRatio: aspectRatio,
            in: referenceSize
        )

        guard cropRect.width > 0, cropRect.height > 0 else { return nil }

        return .init(
            x: cropRect.minX / referenceSize.width,
            y: cropRect.minY / referenceSize.height,
            width: cropRect.width / referenceSize.width,
            height: cropRect.height / referenceSize.height
        )
    }

    public func matches(
        _ freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) -> Bool {
        switch self {
        case .original:
            return freeformRect == nil
        case .vertical9x16,
            .square1x1,
            .portrait4x5,
            .landscape16x9:
            guard let aspectRatio else { return false }
            guard let freeformRect else { return false }
            guard referenceSize.width > 0, referenceSize.height > 0 else { return false }

            let resolvedWidth = freeformRect.width * referenceSize.width
            let resolvedHeight = freeformRect.height * referenceSize.height
            guard resolvedWidth > 0, resolvedHeight > 0 else { return false }

            let resolvedAspectRatio = resolvedWidth / resolvedHeight
            return abs(resolvedAspectRatio - aspectRatio) < 0.001
        }
    }

    public static func resetRect(
        matching freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) -> VideoEditingConfiguration.FreeformRect? {
        guard
            let aspectRatio = resolvedAspectRatio(
                from: freeformRect,
                in: referenceSize
            )
        else { return nil }

        return encodedRect(
            resolvedCropRect(
                aspectRatio: aspectRatio,
                in: referenceSize
            ),
            in: referenceSize
        )
    }

    public static func resizedRect(
        matching freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize,
        magnification: CGFloat
    ) -> VideoEditingConfiguration.FreeformRect? {
        guard magnification.isFinite, magnification > 0 else { return freeformRect }
        guard
            let currentRect = decodedRect(
                from: freeformRect,
                in: referenceSize
            ),
            let aspectRatio = resolvedAspectRatio(
                from: freeformRect,
                in: referenceSize
            )
        else { return freeformRect }

        let maximumRect = resolvedCropRect(
            aspectRatio: aspectRatio,
            in: referenceSize
        )
        guard maximumRect.width > 0, maximumRect.height > 0 else { return freeformRect }

        let minimumWidth = max(maximumRect.width * 0.25, referenceSize.width * 0.18)
        let minimumHeight = max(maximumRect.height * 0.25, referenceSize.height * 0.18)

        var width = currentRect.width / magnification
        var height = width / aspectRatio

        if height < minimumHeight {
            height = minimumHeight
            width = height * aspectRatio
        }

        if width < minimumWidth {
            width = minimumWidth
            height = width / aspectRatio
        }

        if width > maximumRect.width {
            width = maximumRect.width
            height = width / aspectRatio
        }

        if height > maximumRect.height {
            height = maximumRect.height
            width = height * aspectRatio
        }

        let centeredRect = CGRect(
            x: currentRect.midX - width / 2,
            y: currentRect.midY - height / 2,
            width: width,
            height: height
        )

        return encodedRect(
            boundedRect(centeredRect, in: referenceSize),
            in: referenceSize
        )
    }

    // MARK: - Private Methods

    private static func resolvedCropRect(
        aspectRatio: CGFloat,
        in referenceSize: CGSize
    ) -> CGRect {
        guard referenceSize.width > 0, referenceSize.height > 0 else { return .zero }

        let referenceAspectRatio = referenceSize.width / referenceSize.height

        if referenceAspectRatio > aspectRatio {
            let height = referenceSize.height
            let width = height * aspectRatio
            return CGRect(
                x: (referenceSize.width - width) / 2,
                y: 0,
                width: width,
                height: height
            )
        }

        let width = referenceSize.width
        let height = width / aspectRatio
        return CGRect(
            x: 0,
            y: (referenceSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    private static func decodedRect(
        from freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) -> CGRect? {
        guard let freeformRect else { return nil }
        guard referenceSize.width > 0, referenceSize.height > 0 else { return nil }

        return CGRect(
            x: freeformRect.x * referenceSize.width,
            y: freeformRect.y * referenceSize.height,
            width: freeformRect.width * referenceSize.width,
            height: freeformRect.height * referenceSize.height
        )
    }

    private static func encodedRect(
        _ rect: CGRect,
        in referenceSize: CGSize
    ) -> VideoEditingConfiguration.FreeformRect? {
        guard referenceSize.width > 0, referenceSize.height > 0 else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }

        return .init(
            x: rect.minX / referenceSize.width,
            y: rect.minY / referenceSize.height,
            width: rect.width / referenceSize.width,
            height: rect.height / referenceSize.height
        )
    }

    private static func resolvedAspectRatio(
        from freeformRect: VideoEditingConfiguration.FreeformRect?,
        in referenceSize: CGSize
    ) -> CGFloat? {
        guard
            let rect = decodedRect(
                from: freeformRect,
                in: referenceSize
            ),
            rect.width > 0,
            rect.height > 0
        else { return nil }

        return rect.width / rect.height
    }

    private static func boundedRect(
        _ rect: CGRect,
        in referenceSize: CGSize
    ) -> CGRect {
        let bounds = CGRect(origin: .zero, size: referenceSize)
        var boundedRect = rect

        if boundedRect.width > bounds.width {
            boundedRect.size.width = bounds.width
            boundedRect.origin.x = bounds.minX
        }

        if boundedRect.height > bounds.height {
            boundedRect.size.height = bounds.height
            boundedRect.origin.y = bounds.minY
        }

        boundedRect.origin.x = min(
            max(boundedRect.minX, bounds.minX),
            bounds.maxX - boundedRect.width
        )
        boundedRect.origin.y = min(
            max(boundedRect.minY, bounds.minY),
            bounds.maxY - boundedRect.height
        )

        return boundedRect
    }

}

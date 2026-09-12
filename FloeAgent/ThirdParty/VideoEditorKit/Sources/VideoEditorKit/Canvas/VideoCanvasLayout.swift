import CoreGraphics
import Foundation

public struct VideoCanvasLayout: Equatable, Sendable {

    // MARK: - Public Properties

    public let previewCanvasSize: CGSize
    public let exportCanvasSize: CGSize
    public let previewScale: CGFloat
    public let contentBaseSize: CGSize
    public let contentScale: CGFloat
    public let contentCenter: CGPoint
    public let totalRotationRadians: CGFloat
    public let isMirrored: Bool

    // MARK: - Initializer

    public init(
        previewCanvasSize: CGSize,
        exportCanvasSize: CGSize,
        previewScale: CGFloat,
        contentBaseSize: CGSize,
        contentScale: CGFloat,
        contentCenter: CGPoint,
        totalRotationRadians: CGFloat,
        isMirrored: Bool
    ) {
        self.previewCanvasSize = previewCanvasSize
        self.exportCanvasSize = exportCanvasSize
        self.previewScale = previewScale
        self.contentBaseSize = contentBaseSize
        self.contentScale = contentScale
        self.contentCenter = contentCenter
        self.totalRotationRadians = totalRotationRadians
        self.isMirrored = isMirrored
    }

}

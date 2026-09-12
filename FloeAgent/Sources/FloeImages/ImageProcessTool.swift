// FloeImages — image.process agent tool.
//
// Reads a workspace image, applies a bounded Core Image operation (resize or
// rotate), and writes the result back as a new file. The source is never
// mutated. Unsupported operations (mask/composite/watermark/… ) are not
// exposed — the local pipeline surfaces them honestly as unavailable.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

#if canImport(CoreImage)
/// Processes a workspace image with a bounded operation.
public func registerImageTools(
    registry: ToolRunnerRegistry = .shared,
    rootProvider: @escaping @Sendable () -> URL?
) -> (@Sendable () -> URL?) {
    ToolCatalog.register(ImageProcessTool.self, compatibilityOnly: true)
    registry.register(ImageProcessTool(rootProvider: rootProvider), compatibilityOnly: true)
    ToolCatalog.register(QRCodeGenerateTool.self)
    registry.register(QRCodeGenerateTool(rootProvider: rootProvider))
    return rootProvider
}
#endif

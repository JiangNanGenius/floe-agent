// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import PencilKit
import FloeDiagramCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public enum DiagramNativeInk {
    public static func bounds(_ data: Data?) throws -> DiagramRect? {
        guard let data else { return nil }
        #if os(macOS)
        guard Bundle.main.bundleIdentifier != nil else { throw DiagramError.unsupported("PencilKit requires a macOS application bundle identifier. Editable ink remains available in the native archive.") }
        #endif
        let drawing = try PKDrawing(data: data)
        guard !drawing.strokes.isEmpty else { return nil }; let rect = drawing.bounds
        guard rect.minX.isFinite,rect.minY.isFinite,rect.width.isFinite,rect.height.isFinite,rect.width > 0,rect.height > 0,abs(rect.minX) < 100_000_000,abs(rect.minY) < 100_000_000,rect.width < 100_000_000,rect.height < 100_000_000 else { throw DiagramError.invalid("ink bounds") }
        return .init(x: rect.minX,y: rect.minY,width: rect.width,height: rect.height)
    }
    /// PencilKit renders masks, pressure, particle effects and wet-ink groups. Native files retain the editable strokes.
    @MainActor public static func image(_ data: Data, scale requested: Double = 2) throws -> (CGImage, DiagramRect)? {
        guard let bounds = try bounds(data) else { return nil }
        let drawing = try PKDrawing(data: data), scale = min(requested,4096/max(bounds.width,bounds.height),sqrt(8_000_000/(bounds.width*bounds.height)))
        let native = drawing.image(from: bounds.cgRect,scale: max(0.000001,scale))
        #if canImport(UIKit)
        guard let image = native.cgImage else { throw DiagramError.io("PencilKit image") }
        #else
        var rect = CGRect(origin: .zero,size: native.size)
        guard let image = native.cgImage(forProposedRect: &rect,context: nil,hints: nil) else { throw DiagramError.io("PencilKit image") }
        #endif
        return (image,bounds)
    }
}

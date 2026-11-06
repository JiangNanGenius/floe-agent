// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD

/// App-local codec adapters. The native document owns these closures; the
/// offscreen web engine lives for one bounded operation and is always stopped.
@MainActor enum CADDrawingModelBridge {
    static func configure(_ document: FloeCADDocument) {
        document.drawingSketchDecoder = { data, name in
            try await decode(data: data, name: name)
        }
        document.drawingDWGEncoder = { data in
            let engine = CadWebEngineSession()
            do {
                try await engine.start()
                _ = try await engine.open(bytes: data, format: "dxf")
                let result = try await engine.exportAs("dwg", engineeringDrawing: true)
                try Task.checkCancellation()
                await engine.shutdown()
                return result
            } catch { await engine.shutdown(); throw error }
        }
    }
    static func decode(data: Data, name: String,
                       purpose: CADSketchTransferEnvelope.Purpose = .modelSketch,
                       sourceIdentity: String? = nil) async throws -> CADSketchTransferEnvelope {
        let format = (name as NSString).pathExtension.lowercased()
        guard ["dwg", "dxf"].contains(format), !data.isEmpty, data.count <= 10 * 1024 * 1024 else {
            throw CADSketchTransferError.invalid("Choose a DWG or DXF file smaller than 10 MB.")
        }
        let engine = CadWebEngineSession()
        do {
            try await engine.start()
            _ = try await engine.open(bytes: data, format: format)
            let snapshot = try await engine.transferSketch()
            try Task.checkCancellation()
            let envelope = try CADSketchTransferEnvelope(purpose: purpose, sourceName: name,
                sourceSHA256: CADSketchTransferEnvelope.digest(data), sourceIdentity: sourceIdentity,
                sourceBytes: data, snapshot: snapshot)
            await engine.shutdown()
            return envelope
        } catch { await engine.shutdown(); throw error }
    }
}
#endif

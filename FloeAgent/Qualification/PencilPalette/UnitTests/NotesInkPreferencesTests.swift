// SPDX-License-Identifier: MPL-2.0
import XCTest
import PencilKit
@testable import FloePencilPaletteQualification

@MainActor final class NotesInkPreferencesTests: XCTestCase {
    func testLegacyColorsAndWidthsMigrateWithoutRemovingRecoveryKeys() throws {
        let suite = "floe.ink.test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("#123456", forKey: "notes.pen.color")
        defaults.set(5.0, forKey: "notes.pen.width")
        defaults.set("#ABCDEF", forKey: "notes.marker.color")
        let store = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(store.configuration(for: .pen).color, "#123456")
        XCTAssertEqual(store.configuration(for: .pen).width, 5)
        XCTAssertEqual(store.configuration(for: .marker).color, "#ABCDEF")
        store.select(.pencil)
        let reopened = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(reopened.selectedPen, .pencil)
        XCTAssertEqual(reopened.configuration(for: .pen).color, "#123456")
        XCTAssertEqual(defaults.string(forKey: "notes.pen.color"), "#123456")
    }

    func testEachBrushKeepsItsOwnSettingsAcrossReopen() throws {
        let suite = "floe.ink.test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotesInkPreferences(defaults: defaults)
        var saved: [NotesBrushKind: NotesInkPreferences.Configuration] = [:]
        for (index, kind) in NotesBrushKind.allCases.enumerated() {
            store.setColor(String(format: "#%06X", 0x112230 + index), for: kind)
            store.setWidth(kind.widthRange.lowerBound + (kind.widthRange.upperBound - kind.widthRange.lowerBound) * 0.3, for: kind)
            store.setOpacity(0.2 + Double(index) * 0.1, for: kind)
            saved[kind] = store.configuration(for: kind)
        }
        store.select(.reed)
        store.select(.marker)
        let reopened = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(reopened.selectedPen, .reed, "A highlighter must not replace the last writing brush")
        for kind in NotesBrushKind.allCases {
            XCTAssertEqual(reopened.configuration(for: kind), saved[kind])
            let native = reopened.inkingTool(for: kind)
            XCTAssertEqual(native.inkType, kind.inkType)
            XCTAssertEqual(native.width, try XCTUnwrap(saved[kind]).width)
            XCTAssertEqual(native.color.cgColor.alpha, try XCTUnwrap(saved[kind]?.opacity), accuracy: 0.001)
        }
    }

    func testDamagedPreferencesAndInvalidWidthsStayUsable() throws {
        let suite = "floe.ink.test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: NotesInkPreferences.storageKey)
        defaults.set("invalid", forKey: "notes.pen.color")
        defaults.set(-100.0, forKey: "notes.pen.width")
        let store = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(store.configuration(for: .pen).color, "#18181B")
        XCTAssertEqual(store.configuration(for: .pen).width, NotesBrushKind.pen.widthRange.lowerBound)
        let before = store.configuration(for: .pen)
        store.setWidth(.nan, for: .pen)
        store.setOpacity(.infinity, for: .pen)
        store.setColor("not-a-color", for: .pen)
        XCTAssertEqual(store.configuration(for: .pen), before)
        store.setWidth(.greatestFiniteMagnitude, for: .pen)
        XCTAssertEqual(store.inkingTool(for: .pen).width, NotesBrushKind.pen.widthRange.upperBound)
    }

    func testOldSnapshotKeepsBrushSettingsAndDefaultsOpacity() throws {
        let suite = "floe.ink.test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(##"{"selectedPen":"fountainPen","brushes":{"fountainPen":{"color":"#123456","width":4},"marker":{"color":"#FACC15","width":20}}}"##.utf8), forKey: NotesInkPreferences.storageKey)
        let store = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(store.selectedPen, .fountainPen)
        XCTAssertEqual(store.configuration(for: .fountainPen).width, 4)
        XCTAssertEqual(store.configuration(for: .fountainPen).color, "#123456")
        XCTAssertEqual(store.configuration(for: .fountainPen).opacity, 1)
        XCTAssertEqual(store.configuration(for: .marker).opacity, 0.45)
        store.setOpacity(-1, for: .marker)
        XCTAssertEqual(store.inkingTool(for: .marker).color.cgColor.alpha, 0, accuracy: 0.001)
        store.setOpacity(2, for: .marker)
        XCTAssertEqual(store.inkingTool(for: .marker).color.cgColor.alpha, 1)
    }

    func testFiveWidthDotsStayOrderedDistinctAndLegal() throws {
        for kind in NotesBrushKind.allCases {
            let values = NotesInkOptionsPanel.widths(for: kind)
            XCTAssertEqual(values.count, 5, "\(kind)")
            XCTAssertEqual(Set(values.map { Int(($0 * 100).rounded()) }).count, 5,
                           "\(kind) dots must be distinct")
            for (thin, thick) in zip(values, values.dropFirst()) {
                XCTAssertLessThan(thin, thick, "\(kind) dots must grow left to right")
            }
            for value in values {
                XCTAssertTrue(kind.widthRange.contains(value),
                              "\(kind) generated \(value) outside its real width range")
            }
            print("Width dots \(kind.rawValue): default=\(kind.inkType.defaultWidth), range=\(kind.widthRange), values=\(values)")
        }
    }

    func testPreviewUsesWidthColorAndTransparencyWithoutClipping() throws {
        let color = UIColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 0.4)
        XCTAssertEqual(NotesBrushSample.paperWidth, 288)
        XCTAssertTrue((56...64).contains(NotesBrushSample.paperHeight),
                      "the compact preview paper must stay 56-64 points high")
        for kind in NotesBrushKind.allCases {
            let rect = NotesBrushSample.previewRect(for: kind)
            XCTAssertEqual(rect, NotesBrushSample.previewRect(for: kind),
                           "\(kind) viewport must not change with the current width")
            let zoom = NotesBrushSample.previewZoom(for: kind)
            XCTAssertGreaterThanOrEqual(zoom, 1)
            // The native drawing keeps the exact requested width, and the
            // uniformly zoomed preview keeps that same ratio at every setting.
            // The fixed viewport is checked against the zoomed render bounds
            // for the legal minimum, maximum and every five-dot width, which
            // covers texture expansion beyond the nominal nib size.
            var widths: [Double] = [kind.widthRange.lowerBound, kind.widthRange.upperBound]
            widths.append(contentsOf: NotesInkOptionsPanel.widths(for: kind))
            for width in widths {
                let native = NotesBrushSample.drawing(kind: kind, color: color, width: width)
                let nativeStroke = try XCTUnwrap(native.strokes.first)
                let nativeWidest = try XCTUnwrap(nativeStroke.path.max { $0.size.width < $1.size.width })
                XCTAssertEqual(Double(nativeWidest.size.width), width, accuracy: 0.01,
                               "\(kind) native sample must keep the requested width")
                let drawing = NotesBrushSample.previewDrawing(kind: kind, color: color, width: width)
                let stroke = try XCTUnwrap(drawing.strokes.first)
                let widest = try XCTUnwrap(stroke.path.max { $0.size.width < $1.size.width })
                XCTAssertEqual(Double(widest.size.width), width * Double(zoom), accuracy: 0.02,
                               "\(kind) preview must keep one fixed zoom")
                XCTAssertEqual(stroke.ink.color.cgColor.alpha, 0.4, accuracy: 0.01,
                               "\(kind) preview must draw the configured transparency")
                let renderedBounds = drawing.strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
                XCTAssertTrue(rect.insetBy(dx: -1, dy: -1).contains(renderedBounds),
                              "\(kind) preview clipped \(renderedBounds) in \(rect) at width \(width)")
            }
            let thickImage = NotesBrushSample.image(kind: kind, color: color,
                                                    width: kind.widthRange.upperBound)
            let narrowImage = NotesBrushSample.image(kind: kind, color: color,
                                                     width: kind.widthRange.lowerBound)
            let thick = try XCTUnwrap(thickImage.pngData())
            XCTAssertNotEqual(try XCTUnwrap(narrowImage.pngData()), thick,
                              "\(kind) preview must visibly change with width")
            XCTAssertTrue(try containsVisibleInk(thickImage),
                          "\(kind) widest preview must render actual ink")
            XCTAssertTrue(try containsVisibleInk(narrowImage),
                          "\(kind) thinnest preview must render actual ink, not an empty PNG")
            let opaqueImage = NotesBrushSample.image(kind: kind,
                                                     color: color.withAlphaComponent(1),
                                                     width: kind.widthRange.upperBound)
            XCTAssertNotEqual(try XCTUnwrap(opaqueImage.pngData()), thick,
                              "\(kind) preview must visibly change with transparency")
        }
    }

    private func containsVisibleInk(_ image: UIImage) throws -> Bool {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cgImage.width,
                height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    func testAllNativeInkTypesSurviveDrawingSerializationAndRender() throws {
        for kind in NotesBrushKind.allCases {
            let sample = NotesBrushSample.drawing(kind: kind, color: .black)
            let reopened = try PKDrawing(data: sample.dataRepresentation())
            XCTAssertEqual(reopened.strokes.count, 1)
            // A writing mode and the ink stored in a PKStroke are different
            // contracts (e.g. monoline can produce canonical pen ink).
            let originalInk = sample.strokes.first?.ink.inkType
            print("Native brush \(kind.rawValue): stroke=\(String(describing: originalInk)), reopened=\(String(describing: reopened.strokes.first?.ink.inkType))")
            let restoredInk = reopened.strokes.first?.ink.inkType
            if kind == .monoline {
                // SDK 26/27 serialize this native writing mode as pen ink.
                // Accept only that known alias; geometry and pixels must still
                // survive below. The UI case separately checks the active mode.
                XCTAssertTrue(restoredInk == originalInk || restoredInk == .pen)
            } else {
                XCTAssertEqual(restoredInk, originalInk)
            }
            let originalPath = try XCTUnwrap(sample.strokes.first?.path)
            let restoredPath = try XCTUnwrap(reopened.strokes.first?.path)
            XCTAssertEqual(restoredPath.count, originalPath.count)
            for (before, after) in zip(originalPath, restoredPath) {
                XCTAssertEqual(after.location.x, before.location.x, accuracy: 0.001)
                XCTAssertEqual(after.location.y, before.location.y, accuracy: 0.001)
                XCTAssertEqual(after.size.width, before.size.width, accuracy: 0.001)
                XCTAssertEqual(after.size.height, before.size.height, accuracy: 0.001)
                XCTAssertEqual(after.opacity, before.opacity, accuracy: 0.001)
            }
            XCTAssertFalse(reopened.bounds.isEmpty)
            let previewRect = NotesBrushSample.previewRect(for: kind)
            let previewScale = NotesBrushSample.renderScale(for: kind)
            let preview = NotesBrushSample.previewDrawing(kind: kind, from: reopened)
            let originalPreview = NotesBrushSample.previewDrawing(kind: kind, from: sample)
            let image = preview.image(from: previewRect, scale: previewScale)
            let png = try XCTUnwrap(image.pngData())
            let originalImage = originalPreview.image(from: previewRect, scale: previewScale)
            XCTAssertEqual(png, try XCTUnwrap(originalImage.pngData()), "\(kind) must preserve the rendered stroke across save/reopen")
            XCTAssertGreaterThan(png.count, 100)
            XCTAssertTrue(try containsVisibleInk(image),
                          "\(kind) must render actual ink, not an empty PNG")
        }
    }
}

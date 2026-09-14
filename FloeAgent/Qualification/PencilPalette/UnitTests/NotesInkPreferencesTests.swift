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
        XCTAssertEqual(store.inkingTool(for: .marker).color.cgColor.alpha, 0.1, accuracy: 0.001)
        store.setOpacity(2, for: .marker)
        XCTAssertEqual(store.inkingTool(for: .marker).color.cgColor.alpha, 1)
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
            let image = reopened.image(from: CGRect(x: 0, y: 0, width: 110, height: 32), scale: 2)
            let png = try XCTUnwrap(image.pngData())
            let originalImage = sample.image(from: CGRect(x: 0, y: 0, width: 110, height: 32), scale: 2)
            XCTAssertEqual(png, try XCTUnwrap(originalImage.pngData()), "\(kind) must preserve the rendered stroke across save/reopen")
            XCTAssertGreaterThan(png.count, 100)
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cgImage.width,
                    height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 },
                          "\(kind) must render actual ink, not an empty PNG")
        }
    }
}

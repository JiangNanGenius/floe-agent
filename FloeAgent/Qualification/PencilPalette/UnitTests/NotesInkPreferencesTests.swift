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
            saved[kind] = store.configuration(for: kind)
        }
        store.select(.reed)
        store.select(.marker)
        let reopened = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(reopened.selectedPen, .reed, "A highlighter must not replace the last writing brush")
        for kind in NotesBrushKind.allCases {
            XCTAssertEqual(reopened.configuration(for: kind), saved[kind])
            XCTAssertEqual(reopened.inkingTool(for: kind).inkType, kind.inkType)
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
        store.setColor("not-a-color", for: .pen)
        XCTAssertEqual(store.configuration(for: .pen), before)
        store.setWidth(.greatestFiniteMagnitude, for: .pen)
        XCTAssertEqual(store.inkingTool(for: .pen).width, NotesBrushKind.pen.widthRange.upperBound)
    }

    func testAllNativeInkTypesSurviveDrawingSerializationAndRender() throws {
        for kind in NotesBrushKind.allCases {
            let sample = NotesBrushSample.drawing(kind: kind, color: .black)
            let reopened = try PKDrawing(data: sample.dataRepresentation())
            XCTAssertEqual(reopened.strokes.count, 1)
            XCTAssertEqual(reopened.strokes.first?.ink.inkType, kind.inkType)
            XCTAssertFalse(reopened.bounds.isEmpty)
            let image = reopened.image(from: CGRect(x: 0, y: 0, width: 110, height: 32), scale: 2)
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 100)
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

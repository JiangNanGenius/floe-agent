// SPDX-License-Identifier: MPL-2.0
import XCTest
import SwiftUI
import PencilKit
@testable import FloeApp

@MainActor final class NotesBrushPaletteTests: XCTestCase {
    func testEightGlyphsRenderWithDistinctInkAtToolbarSize() throws {
        XCTAssertEqual(NotesBrushKind.allCases.count, 8)
        XCTAssertEqual(Set(NotesBrushKind.ordinaryPens), Set(NotesBrushKind.allCases).subtracting([.marker]))
        for size in [18, 23] {
            var masks: [NotesBrushKind: [UInt8]] = [:]
            for brush in NotesBrushKind.allCases {
                let image = ImageRenderer(content: NotesBrushGlyph(kind: brush).fill(.black)
                    .frame(width: CGFloat(size), height: CGFloat(size)).background(.white))
                image.scale = 1
                let cg = try XCTUnwrap(image.cgImage)
                var pixels = [UInt8](repeating: 255, count: size * size)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue))
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
                }
                let mask = pixels.map { $0 < 160 ? UInt8(1) : UInt8(0) }
                let count = mask.filter { $0 == 1 }.count
                XCTAssertGreaterThan(count, size, brush.rawValue)
                XCTAssertLessThan(count, mask.count / 2, brush.rawValue)
                for (other, existing) in masks {
                    let differing = zip(existing, mask).filter { $0 != $1 }.count
                    XCTAssertGreaterThan(differing, size / 2, "\(brush) and \(other) must look distinct at \(size) pt")
                }
                masks[brush] = mask
            }
        }
    }

    func testPhoneWidthAccommodatesBothBrushPanels() throws {
        let suite = "floe.notes.brushlayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = NotesInkPreferences(defaults: defaults)
        for tool in [NotesBrushKind.fountainPen, .marker] {
            let panel = NotesInkOptionsPanel(selected: tool, preferences: preferences, select: preferences.select, close: {})
                .environment(\.horizontalSizeClass, .compact).environment(\.dynamicTypeSize, .accessibility1)
            let controller = UIHostingController(rootView: panel)
            for width in [CGFloat(280), 320] {
                let fit = controller.sizeThatFits(in: CGSize(width: width, height: 335))
                XCTAssertGreaterThan(fit.width, 200)
                XCTAssertLessThanOrEqual(fit.width, width + 1)
                XCTAssertGreaterThan(fit.height, 100)
                XCTAssertLessThanOrEqual(fit.height, 336)
            }
        }
    }

    func testPenAndHighlighterKeepSeparateSettingsAcrossLegacyReopen() throws {
        let suite = "floe.notes.brushes.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("#345678", forKey: "notes.pen.color")
        defaults.set(5.0, forKey: "notes.pen.width")
        defaults.set("#ABCDEF", forKey: "notes.marker.color")
        defaults.set(14.0, forKey: "notes.marker.width")
        let legacy = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(legacy.configuration(for: .pen).color, "#345678")
        XCTAssertEqual(legacy.configuration(for: .pen).width, 5)
        XCTAssertEqual(legacy.configuration(for: .marker).color, "#ABCDEF")
        XCTAssertEqual(legacy.configuration(for: .marker).width, 14)
        legacy.select(.fountainPen)
        legacy.setColor("#445588", for: .fountainPen)
        legacy.setWidth(4, for: .fountainPen)
        legacy.setOpacity(0.72, for: .fountainPen)
        legacy.setColor("#FFCC22", for: .marker)
        legacy.setWidth(18, for: .marker)
        legacy.setOpacity(0.28, for: .marker)
        legacy.select(.marker)
        let restored = NotesInkPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedPen, .fountainPen)
        XCTAssertEqual(restored.configuration(for: .fountainPen), .init(color: "#445588", width: 4, opacity: 0.72))
        XCTAssertEqual(restored.configuration(for: .marker), .init(color: "#FFCC22", width: 18, opacity: 0.28))
        XCTAssertEqual(restored.inkingTool(for: restored.selectedPen).inkType, .fountainPen)
        XCTAssertEqual(restored.inkingTool(for: .marker).inkType, .marker)
        XCTAssertEqual(defaults.string(forKey: "notes.pen.color"), "#345678")
    }
}

// FloeCoreTests — persisted layout typography + sidebar bounds (Build265).
import Foundation
import Testing
@testable import FloeCore

@Suite("Layout display settings")
struct LayoutDisplayTests {
    @Test("list font sizes are distinct and independent per list kind")
    func fontSizes() {
        #expect(LayoutListFontSize.small.pointSize < LayoutListFontSize.normal.pointSize)
        #expect(LayoutListFontSize.normal.pointSize < LayoutListFontSize.large.pointSize)
        var settings = LayoutSettings()
        settings.setFontSize(.large, for: .files)
        settings.setFontSize(.small, for: .layers)
        #expect(settings.fontSize(for: .files) == .large)
        #expect(settings.fontSize(for: .layers) == .small)
        #expect(settings.fontSize(for: .assets) == .normal)
    }

    @Test("one/two line file names keep the extension and only add the path when asked")
    func fileNameLines() {
        let one = FileNameDisplay.lines(fileName: "drawing.dxf", relativePath: "plans/site/drawing.dxf",
                                        lineCount: 1, showPath: true)
        #expect(one == ["drawing.dxf"])
        let two = FileNameDisplay.lines(fileName: "drawing.dxf", relativePath: "plans/site/drawing.dxf",
                                        lineCount: 2, showPath: true)
        #expect(two.count == 2)
        #expect(two[0] == "drawing.dxf")
        #expect(two[1].contains("drawing.dxf"))
        let withoutPath = FileNameDisplay.lines(fileName: "drawing.dxf", relativePath: "plans/site/drawing.dxf",
                                                lineCount: 2, showPath: false)
        #expect(withoutPath == ["drawing.dxf"])
    }

    @Test("long names are middle-truncated with the extension preserved")
    func middleTruncation() {
        let long = String(repeating: "a", count: 120) + ".png"
        let truncated = FileNameDisplay.middleTruncated(long, limit: 24)
        #expect(truncated.count <= 24)
        #expect(truncated.hasPrefix("aaaaaaaa"))
        #expect(truncated.hasSuffix(".png"), "extension must stay visible")
        #expect(truncated.contains("…"))
        // Short values are untouched.
        #expect(FileNameDisplay.middleTruncated("a.png", limit: 24) == "a.png")
    }

    @Test("same-name conflicts are detected across extensions")
    func sameNameHint() {
        #expect(FileNameDisplay.hasSameNameConflict("plan.dwg", among: ["plan.dxf", "other.dwg"]))
        #expect(!FileNameDisplay.hasSameNameConflict("plan.dwg", among: ["plan.dwg", "other.dxf"]))
        #expect(!FileNameDisplay.hasSameNameConflict("plan.dwg", among: ["site-plan.dxf"]))
    }

    @Test("sidebar width clamps to the declared min/max and line count clamps to 1...2")
    func bounds() {
        let tooSmall = LayoutSettings(sidebarWidth: 10)
        #expect(tooSmall.sidebarWidth == LayoutSettings.sidebarMinimumWidth)
        let tooLarge = LayoutSettings(sidebarWidth: 5000)
        #expect(tooLarge.sidebarWidth == LayoutSettings.sidebarMaximumWidth)
        let zeroLines = LayoutSettings(fileNameLines: 0)
        #expect(zeroLines.fileNameLines == 1)
        let manyLines = LayoutSettings(fileNameLines: 9)
        #expect(manyLines.fileNameLines == FileNameDisplay.maximumLines)
    }
}

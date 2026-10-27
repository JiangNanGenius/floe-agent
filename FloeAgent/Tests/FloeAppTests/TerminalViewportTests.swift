#if canImport(UIKit)
import UIKit
import Testing
@testable import FloeApp

@Suite("Terminal viewport ownership")
@MainActor
struct TerminalViewportTests {
    @Test("A detached viewport cannot resize the rehosted terminal")
    func rehosting() {
        let presentation = TerminalPresentation()
        #expect(presentation.view.font.pointSize == presentation.fontSize)
        let embedded = TerminalViewport(terminal: presentation.view)
        embedded.frame = CGRect(x: 0, y: 0, width: 440, height: 300)
        embedded.layoutIfNeeded()
        let expanded = TerminalViewport(terminal: presentation.view)
        expanded.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        expanded.layoutIfNeeded()
        let expandedFrame = presentation.view.frame
        embedded.frame.size = CGSize(width: 100, height: 100)
        embedded.layoutIfNeeded()
        #expect(presentation.view.superview === expanded)
        #expect(presentation.view.frame == expandedFrame)
        #expect(presentation.view.transform == .identity)
    }
}
#endif

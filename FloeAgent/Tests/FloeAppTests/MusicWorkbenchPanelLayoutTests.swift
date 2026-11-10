#if canImport(UIKit)
import XCTest
import SwiftUI
import UIKit
@testable import FloeApp

@MainActor final class MusicWorkbenchPanelLayoutTests: XCTestCase {
    func testEmptyWideEditorKeepsActualRulerVisibleAboveMixer() throws {
        try check(size: CGSize(width: 1_120, height: 640), inspectorWidth: 260, showsDock: true, expanded: false)
    }
    func testShortEditorReducesDockBeforeHidingRuler() throws {
        try check(size: CGSize(width: 1_120, height: 220), inspectorWidth: 260, showsDock: true, expanded: false)
    }
    func testCompactArrangementUsesAvailableHeightWithoutHiddenMixer() throws {
        try check(size: CGSize(width: 390, height: 500), inspectorWidth: 0, showsDock: false, expanded: false)
    }
    func testExpandedDockUsesTheRemainingEditorHeight() throws {
        try check(size: CGSize(width: 1_120, height: 640), inspectorWidth: 260, showsDock: true, expanded: true)
    }
    private func check(size: CGSize, inspectorWidth: CGFloat, showsDock: Bool, expanded: Bool) throws {
        // The same production split as MusicWorkbenchView, with an actual
        // ruler input and scroll-based dock/inspector. No layout algorithm is
        // reimplemented in this fixture.
        let arrangement = VStack(spacing: 0) {
            Color.clear.frame(height: 44)
            MusicTimelineInput(ruler: true).frame(height: 44)
            Color.clear
            Color.clear.frame(height: 26)
        }
        let host = UIHostingController(rootView:
            MusicWorkbenchPanels(expanded: expanded, showsDock: showsDock, inspectorWidth: inspectorWidth,
                arrangement: arrangement,
                dockBar: Probe(tag: 7101),
                dockContent: ScrollView(.horizontal) { Probe(tag: 7102).frame(width: 900, height: 240) },
                inspector: ScrollView { Probe(tag: 7103).frame(height: 500) })
                .ignoresSafeArea())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: CGPoint(x: -2_000, y: 0), size: size)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let bar = try XCTUnwrap(host.view.viewWithTag(7101))
        let barRect = bar.convert(bar.bounds, to: host.view)
        let surfaces = descendants(host.view).filter {
            $0.gestureRecognizers?.contains(where: { $0.delegate is MusicTimelineInput.Coordinator }) == true
        }
        let note = "root=\(host.view.bounds) bar=\(barRect) surfaces=\(surfaces.map { $0.convert($0.bounds, to: host.view) }) expanded=\(expanded) dock=\(showsDock)"
        let attachment = XCTAttachment(string: note); attachment.name = "Production Music panel layout"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(barRect.height, 44, accuracy: 0.5, note)
        XCTAssertLessThanOrEqual(barRect.maxY, host.view.bounds.height + 0.5, note)
        if expanded {
            XCTAssertTrue(surfaces.isEmpty, note)
            XCTAssertEqual(barRect.minY, 0, accuracy: 0.5, note)
        } else {
            let ruler = try XCTUnwrap(surfaces.first, note)
            let rect = ruler.convert(ruler.bounds, to: host.view)
            XCTAssertEqual(rect.height, 44, accuracy: 0.5, note)
            XCTAssertGreaterThanOrEqual(rect.minY, 0, note)
            XCTAssertLessThanOrEqual(rect.maxY, barRect.minY, note)
            let point = CGPoint(x: min(48, ruler.bounds.midX), y: 22)
            let hit = host.view.hitTest(ruler.convert(point, to: host.view), with: nil)
            XCTAssertTrue(hit === ruler || hit?.isDescendant(of: ruler) == true, note)
        }
        if !showsDock { XCTAssertEqual(barRect.maxY, size.height, accuracy: 0.5, note) }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private struct Probe: UIViewRepresentable {
        let tag: Int
        func makeUIView(context: Context) -> UIView { let view = UIView(); view.tag = tag; return view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
#endif

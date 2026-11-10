#if canImport(UIKit)
import XCTest
import SwiftUI
import UIKit
@testable import FloeApp

@MainActor final class MusicTimelineSurfaceGeometryTests: XCTestCase {
    func testActualRulerSurfaceFillsVisibleRulerAndReceivesHit() throws {
        // Actual production representable, nested in the same two scroll axes.
        // No substitute input UIView or gesture recognizer is used.
        let ruler = ZStack(alignment: .topLeading) {
            Color.clear
            MusicTimelineInput(ruler: true)
        }.frame(width: 760, height: 44)
        let host = UIHostingController(rootView:
            ScrollView(.vertical) {
                ScrollView(.horizontal) { ruler }
                    .frame(height: 44)
            }.frame(width: 600, height: 180, alignment: .topLeading))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 180))
        window.frame = CGRect(x: -2_000, y: 0, width: 600, height: 180)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        let surfaces = descendants(host.view).filter { view in
            view.gestureRecognizers?.contains(where: { $0.delegate is MusicTimelineInput.Coordinator }) == true
        }
        let surface = try XCTUnwrap(surfaces.first, "The real production ruler input must be in the hosted hierarchy")
        let point = CGPoint(x: 48, y: 22) // Same relative origin as the failing actual UI drag.
        let hit = host.view.hitTest(surface.convert(point, to: host.view), with: nil)
        let pan = try XCTUnwrap(surface.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        var ancestors: [String] = [], cursor = surface.superview
        while let view = cursor {
            if let scroll = view as? UIScrollView {
                let rule = pan.delegate?.gestureRecognizer?(pan, shouldBeRequiredToFailBy: scroll.panGestureRecognizer)
                ancestors.append("scroll frame=\(scroll.frame) content=\(scroll.contentSize) priority=\(String(describing: rule))")
            }
            cursor = view.superview
        }
        let details = "surfaceFrame=\(surface.frame) bounds=\(surface.bounds) root=\(host.view.bounds) hit=\(String(describing: hit.map { String(describing: type(of: $0)) })) interaction=\(surface.isUserInteractionEnabled) ancestors=\(ancestors)"
        let attachment = XCTAttachment(string: details); attachment.name = "Actual music ruler UIKit surface layout and arbitration"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(surface.bounds.width, 760, accuracy: 0.5)
        XCTAssertEqual(surface.bounds.height, 44, accuracy: 0.5)
        XCTAssertTrue(surface.bounds.contains(point))
        XCTAssertTrue(surface.isUserInteractionEnabled)
        XCTAssertTrue(hit === surface || hit?.isDescendant(of: surface) == true, details)
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
#endif

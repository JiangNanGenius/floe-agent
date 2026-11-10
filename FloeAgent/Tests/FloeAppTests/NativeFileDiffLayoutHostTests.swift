// SPDX-License-Identifier: MPL-2.0
// Actual App-host candidate; Root runs this through the canonical Simulator.
#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import FloeApp

@MainActor private final class DiffMeasuredHeight {
    var values: [Double] = []
}

@MainActor final class NativeFileDiffLayoutHostTests: XCTestCase {
    private struct Mounted {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        func close() { window.isHidden = true; window.rootViewController = nil }
    }
    private func mount(_ view: AnyView) throws -> Mounted {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        XCTAssertEqual(scenes.count, 1)
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        return Mounted(window: window, host: host)
    }
    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail(label)
        throw NSError(domain: "NativeDiffHost", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    func testCompactRowsReportTheirRealHeightAfterDynamicTypeChanges() async throws {
        let document = try NativeFileDiff(unifiedDiff: """
        --- a/answer-preview.txt
        +++ b/answer-preview.txt
        @@ -1,3 +1,4 @@
         kept
        -old
        -old2
        +new
        +new2
        +new3

        """)
        XCTAssertEqual(document.changedLineCount, 5)
        let normal = DiffMeasuredHeight(), large = DiffMeasuredHeight()
        let mounted = try mount(AnyView(
            DiffView(document: document, changesOnly: true, onContentHeightChange: { normal.values.append($0) })
                .dynamicTypeSize(.large).frame(width: 420, height: 320)))
        defer { mounted.close() }
        try await wait("The actual eager row stack must report its native layout") { !normal.values.isEmpty }
        let first = try XCTUnwrap(normal.values.last)
        XCTAssertTrue(first.isFinite && first > 0)
        mounted.host.rootView = AnyView(
            DiffView(document: document, changesOnly: true, onContentHeightChange: { large.values.append($0) })
                .dynamicTypeSize(.accessibility3).frame(width: 420, height: 320).id("larger-type"))
        mounted.host.view.setNeedsLayout(); mounted.host.view.layoutIfNeeded()
        try await wait("Actual changed text metrics must be remeasured") { !large.values.isEmpty }
        let second = try XCTUnwrap(large.values.last)
        XCTAssertGreaterThan(second, first, "Do not substitute a fixed per-row estimate for native text/selection layout")
        let evidence = XCTAttachment(string: "Five real rows: normal=\(first), accessibility3=\(second)")
        evidence.name = "Native compact diff measured content"; evidence.lifetime = .keepAlways; add(evidence)
    }

    func testLargeDiffRetainsAConstrainedRealScrollableViewport() async throws {
        let old = (1...80).map { "-old row \($0)" }.joined(separator: "\n")
        let new = (1...80).map { "+new row \($0)" }.joined(separator: "\n")
        let document = try NativeFileDiff(unifiedDiff: "--- a/file.txt\n+++ b/file.txt\n@@ -1,80 +1,80 @@\n" + old + "\n" + new + "\n")
        XCTAssertFalse(document.showsChangesByDefault)
        let mounted = try mount(AnyView(DiffView(document: document).frame(width: 420, height: 160)))
        defer { mounted.close() }
        func scrolls(in root: UIView) -> [UIScrollView] {
            ((root as? UIScrollView).map { [$0] } ?? []) + root.subviews.flatMap { scrolls(in: $0) }
        }
        func viewport() -> UIScrollView? {
            scrolls(in: mounted.host.view).first {
                $0.isScrollEnabled && !$0.isHidden && $0.bounds.height > 0
                    && $0.contentSize.height > $0.bounds.height
            }
        }
        try await wait("The production ScrollView must have actual overflowing content") { viewport() != nil }
        let scroll = try XCTUnwrap(viewport())
        XCTAssertLessThanOrEqual(scroll.bounds.height, 160.5)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        try await wait("The actual native viewport must be scrollable") { scroll.contentOffset.y > 0 }
        let evidence = XCTAttachment(string: "Native viewport=\(scroll.bounds.height), content=\(scroll.contentSize.height), offset=\(scroll.contentOffset.y)")
        evidence.name = "Bounded native large diff scroll"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
#endif

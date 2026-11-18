import XCTest
import AppKit
@testable import FloeMacMediaUI

@MainActor
final class MacMediaWindowTrackerTests: XCTestCase {
    func testOnlyContainingWindowIdentityMatches() {
        let owner = NSObject()
        let other = NSObject()
        XCTAssertTrue(MacMediaWindowReference.isSameWindow(owner, owner))
        XCTAssertFalse(MacMediaWindowReference.isSameWindow(owner, other))
        XCTAssertFalse(MacMediaWindowReference.isSameWindow(nil, owner))
        XCTAssertFalse(MacMediaWindowReference.isSameWindow(owner, nil))
    }

    func testOnlyOwnWindowCloseOrMinimizeStopsCapture() {
        let owner = NSObject(), other = NSObject()
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            XCTAssertTrue(MacMediaWindowReference.shouldStop(name: name, owner: owner, sender: owner))
            XCTAssertFalse(MacMediaWindowReference.shouldStop(name: name, owner: owner, sender: other))
            XCTAssertFalse(MacMediaWindowReference.shouldStop(name: name, owner: nil, sender: owner))
        }
        XCTAssertFalse(MacMediaWindowReference.shouldStop(name: NSWindow.didBecomeKeyNotification, owner: owner, sender: owner))
    }
}

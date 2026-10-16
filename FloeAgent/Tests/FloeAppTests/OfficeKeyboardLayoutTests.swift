#if canImport(UIKit)
import UIKit
import Testing
@testable import FloeApp

@MainActor private final class OfficeResponderProbe: UIView {
    var active = true
    private(set) var resignCount = 0
    override var isFirstResponder: Bool { active }
    override func resignFirstResponder() -> Bool { resignCount += 1; active = false; return true }
}

@Suite("Office keyboard handoff and geometry")
@MainActor struct OfficeKeyboardLayoutTests {
    private func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    private func mounted(claimsInput: Bool = true) -> (UIWindow, UIViewController, OfficeKeyboardLayoutHostController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let document = UIViewController()
        let host = OfficeKeyboardLayoutHostController(controller: document, claimsKeyboardOnEntry: claimsInput)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        window.addSubview(host.view)
        return (window, document, host)
    }

    @Test("Entry resigns only the old responder in its own window, exactly once")
    func externalKeyboardHandoff() {
        let (window, document, host) = mounted()
        let chat = OfficeResponderProbe(), office = OfficeResponderProbe()
        office.active = false
        window.insertSubview(chat, at: 0); document.view.addSubview(office)
        host.handOffExternalResponder(in: window)
        #expect(chat.resignCount == 1)
        office.active = true
        host.handOffExternalResponder(in: window)
        #expect(office.resignCount == 0)
        #expect(document.parent === host)
        host.detachOfficeController()
    }

    @Test("Office-owned input and passive previews keep their keyboard")
    func officeInputAndPreviewArePreserved() {
        let (window, document, host) = mounted()
        let office = OfficeResponderProbe(); document.view.addSubview(office)
        host.handOffExternalResponder(in: window)
        #expect(office.resignCount == 0)
        host.detachOfficeController()
        let (previewWindow, _, preview) = mounted(claimsInput: false)
        let unrelated = OfficeResponderProbe(); previewWindow.insertSubview(unrelated, at: 0)
        preview.handOffExternalResponder(in: previewWindow)
        #expect(unrelated.resignCount == 0)
        preview.detachOfficeController()
    }

    @Test("A different window cannot have its responder dismissed")
    func unrelatedWindowIsNotTouched() {
        let (window, _, host) = mounted()
        let other = UIWindow(frame: window.frame), responder = OfficeResponderProbe()
        other.addSubview(responder)
        host.handOffExternalResponder(in: other)
        #expect(responder.resignCount == 0)
        host.detachOfficeController()
    }

    @Test("Settled keyboard refreshes coalesce and follow actual allocation without clearing avoidance")
    func geometryRefreshKeepsInsetsAndController() async {
        let (window, document, host) = mounted()
        host.additionalSafeAreaInsets.bottom = 42
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        await nextTurn()
        let baseline = host.viewportRefreshCount
        for _ in 0..<10 { host.scheduleViewportRefresh() }
        await nextTurn()
        #expect(host.viewportRefreshCount == baseline + 1)
        #expect(document.parent === host)
        #expect(document.view.frame == host.view.bounds)
        #expect(host.additionalSafeAreaInsets.bottom == 42)
        host.view.frame.size.height = 320 // actual keyboard-reduced SwiftUI allocation
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        await nextTurn()
        #expect(document.view.bounds.height == 320)
        host.view.frame.size.height = 700 // keyboard dismissed without rotation
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        await nextTurn()
        #expect(document.view.bounds.height == 700)
        #expect(host.additionalSafeAreaInsets.bottom == 42)
        #expect(host.children.count == 1)
        #expect(window.subviews.contains(host.view))
        host.detachOfficeController()
        #expect(document.parent == nil)
    }

    @Test("A second surface cannot steal a controller from its current owner")
    func controllerOwnershipIsPreserved() {
        let (_, document, owner) = mounted()
        let other = OfficeKeyboardLayoutHostController(controller: document, claimsKeyboardOnEntry: true)
        other.loadViewIfNeeded()
        #expect(document.parent === owner)
        #expect(other.children.isEmpty)
        #expect(other.view.subviews.contains { $0.accessibilityIdentifier == "office.editor.alreadyMounted" })
        other.detachOfficeController()
        #expect(document.parent === owner)
        owner.detachOfficeController()
    }
}
#endif

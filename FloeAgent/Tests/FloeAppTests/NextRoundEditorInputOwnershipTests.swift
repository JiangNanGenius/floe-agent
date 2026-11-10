#if canImport(UIKit)
import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import FloeApp

@MainActor private final class EditorInputFacts {
    var values: [Bool] = []
}

// UIKit children live in this representable-owned native container. Never
// add subviews directly to SwiftUI's UIHostingController.view.
@MainActor private struct EditorInputNativeContainer: UIViewRepresentable {
    let nativeView: UIView
    func makeUIView(context: Context) -> UIView { nativeView }
    func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor private final class EditorInputFixture {
    let window: UIWindow
    let container = UIViewController()
    let content = UIView()
    let sourceContent = UIView()
    let host: UIHostingController<EditorInputNativeContainer>
    let source: UIHostingController<EditorInputNativeContainer>
    let probe = EditorInputOwnership.Probe(frame: .zero)
    let observer = EditorInputOwnership.Coordinator()
    let facts = EditorInputFacts()

    init() throws {
        host = UIHostingController(rootView: EditorInputNativeContainer(nativeView: content))
        source = UIHostingController(rootView: EditorInputNativeContainer(nativeView: sourceContent))
        // An App-host test requires its real active scene. Never borrow an
        // existing application window or silently pick among several scenes.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        XCTAssertEqual(scenes.count, 1, "Run this focused suite in the single App test-host scene")
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = container
        for (controller, x) in [(host, CGFloat(0)), (source, CGFloat(512))] {
            container.addChild(controller)
            controller.view.frame = CGRect(x: x, y: 0, width: 512, height: 768)
            container.view.addSubview(controller.view)
            controller.didMove(toParent: container)
        }
        content.addSubview(probe)
        window.makeKeyAndVisible()
        container.view.layoutIfNeeded(); host.view.layoutIfNeeded(); source.view.layoutIfNeeded()
    }

    func start() { observer.mount(probe, ownerID: UUID()) { [facts] in facts.values.append($0) } }
    func close() {
        observer.stop()
        window.isHidden = true
        window.rootViewController = nil
    }
    func field(in root: UIView? = nil) -> UITextField {
        let field = UITextField(frame: CGRect(x: 20, y: 40, width: 260, height: 44))
        field.borderStyle = .roundedRect
        (root ?? content).addSubview(field)
        return field
    }
}

@MainActor final class NextRoundEditorInputOwnershipTests: XCTestCase {
    private func settle() async {
        // Allow notification Tasks and their one-turn coalescing to drain.
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testOwnNativeFieldKeepsKeyboardAvoidanceUntilEditingEnds() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        fixture.start(); await settle()
        XCTAssertEqual(fixture.facts.values, [false])
        let field = fixture.field()
        XCTAssertTrue(field.becomeFirstResponder(), "Requires a real UIKit first responder")
        XCTAssertTrue(field.isFirstResponder)
        await settle()
        XCTAssertEqual(fixture.facts.values, [false, true])
        XCTAssertTrue(field.resignFirstResponder()); await settle()
        XCTAssertEqual(fixture.facts.values, [false, true, false])
    }

    func testInitialMountDetectsAlreadyEditingOwnTextView() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        let text = UITextView(frame: CGRect(x: 20, y: 40, width: 260, height: 140))
        fixture.content.addSubview(text)
        XCTAssertTrue(text.becomeFirstResponder()); XCTAssertTrue(text.isFirstResponder)
        fixture.start(); await settle()
        XCTAssertEqual(fixture.facts.values, [true])
    }

    func testSourceSearchInSiblingHostNeverClaimsEditorInput() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        let source = fixture.field(in: fixture.sourceContent)
        XCTAssertTrue(source.becomeFirstResponder()); XCTAssertTrue(source.isFirstResponder)
        fixture.start(); await settle()
        XCTAssertTrue(EditorInputOwnership.Coordinator.hostRoot(containing: fixture.probe) === fixture.host.view)
        XCTAssertEqual(fixture.facts.values, [false])
        XCTAssertTrue(source.isFirstResponder, "Observation must preserve the source user's input")
    }

    func testReadOnlyTextSelectionIsNotEditableInput() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        let text = UITextView(frame: CGRect(x: 20, y: 40, width: 260, height: 140))
        text.isEditable = false; text.isSelectable = true; text.text = "Selectable output"
        fixture.content.addSubview(text)
        XCTAssertTrue(text.becomeFirstResponder()); XCTAssertTrue(text.isFirstResponder)
        fixture.start(); await settle()
        XCTAssertEqual(fixture.facts.values, [false])
        XCTAssertTrue(text.isFirstResponder)
    }

    func testUnmountAndLateNotificationCannotChangeOldOwner() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        let field = fixture.field()
        XCTAssertTrue(field.becomeFirstResponder()); XCTAssertTrue(field.isFirstResponder)
        fixture.start() // Initial read is deliberately still queued.
        fixture.observer.stop()
        XCTAssertNil(fixture.probe.observer)
        let replacement = EditorInputOwnership.Coordinator(), replacementFacts = EditorInputFacts()
        replacement.mount(fixture.probe, ownerID: UUID()) { replacementFacts.values.append($0) }
        defer { replacement.stop() }
        NotificationCenter.default.post(name: UITextField.textDidBeginEditingNotification, object: field)
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        await settle()
        XCTAssertTrue(fixture.facts.values.isEmpty)
        XCTAssertEqual(replacementFacts.values, [true])
        XCTAssertTrue(fixture.probe.observer === replacement)
        XCTAssertTrue(field.isFirstResponder)
    }

    func testOwnerReplacementFencesPendingCallbackAndRechecksActualTree() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        fixture.start()
        let replacement = EditorInputFacts()
        fixture.observer.update(ownerID: UUID()) { replacement.values.append($0) }
        await settle()
        XCTAssertTrue(fixture.facts.values.isEmpty)
        XCTAssertEqual(replacement.values, [false])
        let field = fixture.field()
        XCTAssertTrue(field.becomeFirstResponder()); await settle()
        XCTAssertEqual(replacement.values, [false, true])
    }

    func testActualRepresentableMountsAndDismantlesObserver() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        let facts = EditorInputFacts()
        let native = UIView()
        let editor = EditorInputNativeContainer(nativeView: native)
            .background(EditorInputOwnership(ownerID: UUID()) { facts.values.append($0) })
        let host = UIHostingController(rootView: AnyView(editor))
        fixture.container.addChild(host); host.view.frame = CGRect(x: 0, y: 0, width: 480, height: 400)
        fixture.container.view.addSubview(host.view); host.didMove(toParent: fixture.container)
        host.view.layoutIfNeeded(); await settle()
        func find(_ view: UIView) -> EditorInputOwnership.Probe? {
            if let probe = view as? EditorInputOwnership.Probe { return probe }
            return view.subviews.lazy.compactMap(find).first
        }
        let probe = try XCTUnwrap(find(host.view), "The production representable must be mounted")
        XCTAssertNotNil(probe.observer)
        let field = fixture.field(in: native)
        XCTAssertTrue(field.becomeFirstResponder()); await settle()
        XCTAssertEqual(facts.values.last, true)
        // Replacing rootView tears down the actual representable, not a fake coordinator.
        host.rootView = AnyView(Color.clear)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded(); await settle()
        XCTAssertNil(probe.observer, "SwiftUI must call the production dismantle lifecycle")
        host.view.removeFromSuperview(); host.removeFromParent()
    }

    #if DEBUG
    func testGeometryContainsOnlyClassesAndFramesWithoutUserInput() async throws {
        let fixture = try EditorInputFixture(); defer { fixture.close() }
        let field = fixture.field(in: fixture.sourceContent)
        let sentinel = "PRIVATE-TEXT-PATH-AND-IDENTIFIER-" + UUID().uuidString
        field.text = sentinel; field.accessibilityLabel = sentinel; field.accessibilityIdentifier = sentinel
        XCTAssertTrue(field.becomeFirstResponder()); await settle()
        let row = EditorInputOwnership.Coordinator.geometrySnapshot(probe: fixture.probe, root: fixture.host.view)
        let encoded = try JSONEncoder().encode(row)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains(sentinel))
        XCTAssertEqual(row.firstTextInputInsideHost, false)
        XCTAssertEqual(row.firstTextInputClass, "UITextField")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["probeClass", "probeFrame", "hostClass", "hostFrame", "hostInsets", "windowClass", "windowBounds", "windowInsets", "keyboardGuide", "firstTextInputClass", "firstTextInputFrame", "firstTextInputInsideHost"]))
    }
    #endif
}
#endif

// FloeAppTests — engineering preview session reparenting.
//
// The same EngineeringWebSession must survive the embedded ↔ fullscreen
// transition: two attach calls (different view instances) keep the SAME
// WKWebView, generation and dirty state; only an explicit retry reloads.

#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
@testable import FloeApp
import FloeCore
import FloeWorkspace

@Suite("Engineering web session reparenting", .serialized)
@MainActor
struct EngineeringWebSessionReparentTests {
    private func samplePackage() throws -> EngineeringPreviewPackage {
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        return try EngineeringPreviewPackage.single(name: "plate.dxf", bytes: data)
    }

    @Test("second attach reuses the same web view and preserves dirty state")
    func reparentPreservesSession() throws {
        let package = try samplePackage()
        let session = EngineeringWebSession()
        let web1 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        let generation1 = session.generation
        #expect(generation1 != nil)

        // Dirty state as reported by the page's dirty bridge.
        session.coordinator?.dirty = true

        // Fullscreen (a different view instance) attaches the SAME session.
        let web2 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web1 === web2)
        #expect(session.generation == generation1)
        #expect(session.coordinator?.dirty == true)

        // A same-session retry is what reloads — not a new view appearing.
        session.retry()
        #expect(session.generation == nil)
        let web3 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web3 !== web1)
        #expect(session.generation != nil)
        #expect(session.generation != generation1)
        session.tearDown()
    }

    @Test("read-only embedded → editable fullscreen upgrades the live page without reload")
    func capabilityUpgradePreservesSession() throws {
        let package = try samplePackage()
        let session = EngineeringWebSession()
        // Embedded preview: read-only (no onSave).
        let web1 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: nil, onDirty: nil,
                                  dark: false, locale: "en")
        let generation1 = session.generation
        #expect(session.loadedCanEdit == false)
        // Fullscreen: editable. Same web view, same generation, canEdit flipped.
        let web2 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web1 === web2)
        #expect(session.generation == generation1)
        #expect(session.loadedCanEdit == true)
        // Back to embedded read-only: still the same live page.
        let web3 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: nil, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web3 === web1)
        session.tearDown()
    }

    @Test("attaching a different document rebuilds instead of mixing content")
    func differentDocumentRebuilds() throws {
        let package = try samplePackage()
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: nil, onDirty: nil, dark: false, locale: "en")
        let firstGeneration = session.generation
        let firstKey = session.loadedDocumentKey
        // A different document (same extension) must not reuse the page.
        let other = try EngineeringPreviewPackage.single(
            name: "other.dxf",
            bytes: Data(contentsOf: Bundle.main.url(forResource: "EngineeringViewers/sample-plate", withExtension: "dxf")!))
        _ = session.attach(package: other, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: nil, onDirty: nil, dark: false, locale: "en")
        #expect(session.generation != firstGeneration)
        #expect(session.loadedDocumentKey != firstKey)
        session.tearDown()
    }
}

/// Real two-container embedded ↔ fullscreen transition regression.
///
/// The hang fixed here (sample `cad-keep-session-hang.sample.txt`: 89/92 main
/// thread samples inside `EngineeringContainerView.layoutSubviews` line 484)
/// happened when the embedded and fullscreen containers coexisted during the
/// dismissal animation: each `layoutSubviews` saw the web view in the other
/// container, removed and re-added it, and every move invalidated the other
/// container's layout, looping forever. These tests use two real
/// `EngineeringContainerView`s holding one real `WKWebView` in a real
/// `UIWindow`, so a regression to mutual adoption cannot pass as a state flag.
@Suite("Engineering two-container transition arbitration", .serialized)
@MainActor
struct EngineeringTwoContainerTransitionTests {
    private func attachedSession() throws -> EngineeringWebSession {
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        let package = try EngineeringPreviewPackage.single(name: "plate.dxf", bytes: data)
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: nil, onDirty: nil, dark: false, locale: "en")
        return session
    }

    /// Waits for the real viewer page to load and acknowledge the package, so
    /// the transition runs against a live WKWebView with page state — not an
    /// empty view. The page reports `complete` through the same script bridge
    /// the fullscreen transition preserves.
    private func waitForPageLoad(_ session: EngineeringWebSession) async {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if session.coordinator?.completed == true { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func container(_ session: EngineeringWebSession) -> EngineeringWebView.EngineeringContainerView {
        let container = EngineeringWebView.EngineeringContainerView()
        container.session = session
        container.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        return container
    }

    @Test("two live containers settle on one host instead of ping-ponging")
    func twoContainerLayoutConverges() async throws {
        let session = try attachedSession()
        defer { session.tearDown() }
        guard let web = session.web else {
            Issue.record("session.attach must create a real WKWebView")
            return
        }
        await waitForPageLoad(session)
        #expect(session.coordinator?.completed == true, "the real viewer page must load in the simulator")
        let embedded = container(session)
        let fullscreen = container(session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        window.addSubview(embedded)
        embedded.layoutSubviews()
        #expect(web.superview === embedded)

        // The cover mounts while the embedded view is still in the window.
        window.addSubview(fullscreen)
        fullscreen.layoutSubviews()
        #expect(web.superview === fullscreen)
        #expect(session.presentationHost === fullscreen)

        // Dismissal animation: both containers are live and both lay out
        // repeatedly. The web view must move at most once more and then stay
        // put; the old host must never steal it back.
        var moves = 0
        var last: UIView? = web.superview
        for _ in 0..<40 {
            embedded.layoutSubviews()
            fullscreen.layoutSubviews()
            if web.superview !== last {
                moves += 1
                last = web.superview
            }
        }
        #expect(moves == 0, "a settled two-container transition must not move the web view again")
        #expect(web.superview === fullscreen)
    }

    @Test("leaving host releases only its own ownership; remaining host reclaims")
    func leavingHostReleasesOwnership() async throws {
        let session = try attachedSession()
        defer { session.tearDown() }
        guard let web = session.web else {
            Issue.record("session.attach must create a real WKWebView")
            return
        }
        await waitForPageLoad(session)
        let embedded = container(session)
        let fullscreen = container(session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.addSubview(embedded)
        embedded.layoutSubviews()
        window.addSubview(fullscreen)
        fullscreen.layoutSubviews()
        #expect(web.superview === fullscreen)

        // Dismissal: the fullscreen cover leaves and the surviving embedded
        // container is PROMOTED immediately — the editor must never stay
        // blank waiting for a layout pass that may never arrive.
        fullscreen.removeFromSuperview()
        #expect(session.presentationHost === embedded)
        embedded.layoutSubviews()
        #expect(web.superview === embedded)

        // A stale leaving host must not clear the newer owner either.
        window.addSubview(fullscreen)
        fullscreen.layoutSubviews()
        #expect(session.presentationHost === fullscreen)
        embedded.removeFromSuperview()
        #expect(session.presentationHost === fullscreen)
        fullscreen.layoutSubviews()
        #expect(web.superview === fullscreen)
    }

    @Test("releasing the only host promotes the surviving on-screen container without its own layout pass")
    func hostReleasePromotesSurvivorImmediately() async throws {
        let session = try attachedSession()
        defer { session.tearDown() }
        guard let web = session.web else {
            Issue.record("session.attach must create a real WKWebView")
            return
        }
        await waitForPageLoad(session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let embedded = container(session)
        window.addSubview(embedded)
        embedded.layoutSubviews()
        #expect(web.superview === embedded)

        // Fullscreen takes over, then dismisses. No layout pass runs on the
        // survivor between removal and the assertion — the arbitration must
        // restore the web view on its own (blank-return regression).
        let fullscreen = container(session)
        window.addSubview(fullscreen)
        fullscreen.layoutSubviews()
        #expect(session.presentationHost === fullscreen)
        fullscreen.removeFromSuperview()
        #expect(session.presentationHost === embedded)
        embedded.layoutIfNeeded()
        #expect(web.superview === embedded)
        #expect(session.presentationHost === embedded)
    }

    @Test("dismantling a non-host container leaves the active host untouched")
    func dismantleReleasesOnlyOwnHost() async throws {
        let session = try attachedSession()
        defer { session.tearDown() }
        guard let web = session.web else {
            Issue.record("session.attach must create a real WKWebView")
            return
        }
        await waitForPageLoad(session)
        let embedded = container(session)
        let fullscreen = container(session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.addSubview(embedded)
        embedded.layoutSubviews()
        window.addSubview(fullscreen)
        fullscreen.layoutSubviews()
        #expect(session.presentationHost === fullscreen)

        guard let coordinator = session.coordinator else {
            Issue.record("session.attach must install a coordinator")
            return
        }
        EngineeringWebView.dismantleUIView(embedded, coordinator: coordinator)
        #expect(session.presentationHost === fullscreen)
        #expect(web.superview === fullscreen)
        fullscreen.layoutSubviews()
        #expect(web.superview === fullscreen)
    }
}

/// Mutable box so tests can share a Binding target without inout captures.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
    var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif

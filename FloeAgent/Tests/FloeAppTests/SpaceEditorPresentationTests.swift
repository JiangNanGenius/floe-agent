// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import FloeApp

@Suite("Library editor input handoff")
@MainActor struct SpaceEditorPresentationTests {
    private func input() -> SpaceEditorInputReadiness {
        .init(activeWindow: true, searching: false, searchFirstResponder: false, keyboardTransition: false,
              windowBounds: CGRect(x: 0, y: 0, width: 1133, height: 744),
              keyboardFrame: CGRect(x: 0, y: 724, width: 1133, height: 20), bottomSafeArea: 20, pixel: 0.5,
              layoutCurrent: true, sourceFrame: CGRect(x: 280, y: 137.5, width: 853, height: 586.5),
              sourceSafeAreaBottom: 20, nativeContentBottom: 724, nativeHostBottom: 744, nativeSafeAreaBottom: 20)
    }
    @Test func focusLossAloneCannotPresentWhileSearchInteractionOrResponderIsActive() {
        var state = input(); state.searching = true
        #expect(!state.canPresent)
        state.searching = false; state.searchFirstResponder = true
        #expect(!state.canPresent)
        state.searchFirstResponder = false
        #expect(state.canPresent)
    }
    @Test func theObservedShortViewportWaitsForActualKeyboardGeometryAndItsCompletedTransition() {
        var state = input()
        state.keyboardFrame = CGRect(x: 0, y: 387.5, width: 1133, height: 356.5)
        #expect(!state.canPresent)
        state.keyboardFrame = CGRect(x: 0, y: 724, width: 1133, height: 20)
        state.keyboardTransition = true
        #expect(!state.canPresent)
        state.keyboardTransition = false
        #expect(state.canPresent)
    }
    @Test func hardwareKeyboardAndDifferentWindowSizesNeedNoFixedDelayOrHeight() {
        var state = input(); state.keyboardFrame = .zero
        #expect(state.canPresent)
        state.windowBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        state.bottomSafeArea = 34; state.keyboardFrame = CGRect(x: 0, y: 810, width: 390, height: 34)
        state.layoutCurrent = false
        #expect(!state.canPresent)
        state.sourceFrame = CGRect(x: 0, y: 140, width: 390, height: 670)
        state.sourceSafeAreaBottom = 34; state.nativeSafeAreaBottom = 34; state.nativeContentBottom = 810; state.nativeHostBottom = 844
        state.layoutCurrent = true
        #expect(state.canPresent)
        state.activeWindow = false
        #expect(!state.canPresent)
    }
    @Test func hiddenKeyboardNotificationAndZeroGuideCannotOverrideAStaleSwiftUIProposal() {
        var state = input(); state.keyboardFrame = .zero
        state.sourceSafeAreaBottom = 389
        state.sourceFrame.size.height = 269
        #expect(!state.canPresent)
        state.sourceSafeAreaBottom = 20
        #expect(!state.canPresent)
        state.sourceFrame = .zero
        #expect(!state.canPresent)
        state = input(); state.sourceSafeAreaBottom = .nan
        #expect(!state.canPresent)
        state = input(); state.layoutCurrent = false
        #expect(!state.canPresent)
        state = input(); state.sourceFrame.size.height = 606.5 // Extending through the native bottom inset is also valid.
        #expect(state.canPresent)
    }
    @Test func realWindowMeasurementsExpireOnResizeOrSourceHostReplacement() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIViewController(); window.rootViewController = host
        host.view.frame = window.bounds; window.addSubview(host.view)
        let probe = SpaceLibraryInputProbe.Probe(frame: window.bounds)
        host.view.addSubview(probe)
        defer { probe.stop(); probe.removeFromSuperview(); window.rootViewController = nil }
        probe.update(nil, searching: false, geometrySize: probe.bounds.size, safeAreaBottom: 0, onReady: { _ in })
        #expect(probe.input()?.layoutCurrent == false)
        probe.layoutIfNeeded()
        #expect(probe.input()?.layoutCurrent == true)
        window.bounds.size.width = 900
        #expect(probe.input()?.layoutCurrent == false)
        let replacement = UIViewController(); window.rootViewController = replacement
        replacement.view.frame = window.bounds; window.addSubview(replacement.view)
        replacement.view.addSubview(probe)
        #expect(probe.input()?.layoutCurrent == false)
        probe.frame = window.bounds
        probe.update(nil, searching: false, geometrySize: probe.bounds.size, safeAreaBottom: 0, onReady: { _ in })
        probe.layoutIfNeeded()
        #expect(probe.input()?.layoutCurrent == true)
    }
    @Test func anOldOrCancelledRequestCannotPresentAndAClaimIsDeliveredOnlyOnce() {
        let first = UUID(), next = UUID(); var state = SpaceEditorInputClaim()
        state.setRequest(first)
        #expect(state.claim(input()) == first)
        #expect(state.claim(input()) == nil)
        state.setRequest(next)
        #expect(!state.owns(first))
        #expect(state.claim(input()) == next)
        state.setRequest(nil)
        #expect(!state.owns(next) && state.claim(input()) == nil)
    }
}
#endif

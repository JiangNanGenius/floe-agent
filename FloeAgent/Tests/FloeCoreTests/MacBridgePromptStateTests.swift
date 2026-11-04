import Testing
@testable import FloeCore

@Suite("Mac Bridge presentation lifecycle")
struct MacBridgePromptStateTests {
    private func update(
        _ state: inout MacBridgePromptState,
        ready: Bool = true, handled: Bool = false, download: Bool = true,
        connected: Bool = false, verification: Bool = false, page: Bool = false,
        platform: LocalBridgePlatform = .iOSAppOnMac
    ) {
        state.reconcile(platform: platform, canPresent: ready,
                        recommendationHandled: handled, downloadAvailable: download,
                        connected: connected, awaitingVerification: verification,
                        connectionPageVisible: page)
    }

    @Test("Startup and setup defer the recommendation without consuming it")
    func waitsForLaunchAndSetup() {
        var state = MacBridgePromptState()
        update(&state, ready: false)
        #expect(state.presented == nil)
        update(&state)
        #expect(state.presented == .recommendation)
        // Another app becoming active does not erase the current decision.
        update(&state, ready: false)
        #expect(state.presented == .recommendation)
    }

    @Test("A system presentation interruption can retry; explicit Later cannot")
    func interruptionIsNotUserDismissal() {
        var state = MacBridgePromptState()
        update(&state)
        state.presentationEnded()
        update(&state, ready: false)
        #expect(state.presented == nil)
        update(&state)
        #expect(state.presented == .recommendation)
        state.presentationEnded()
        update(&state, handled: true)
        #expect(state.presented == nil)
    }

    @Test("Verification is available after recommendation handling and has one owner")
    func verificationOwnership() {
        var state = MacBridgePromptState()
        update(&state, handled: true, download: false, verification: true)
        #expect(state.presented == .verification)
        update(&state, handled: true, verification: true, page: true)
        #expect(state.presented == nil)
        update(&state, handled: true, verification: true)
        #expect(state.presented == .verification)
        update(&state, handled: true)
        #expect(state.presented == nil)
    }

    @Test("Connected hosts, missing downloads and non-Mac platforms never recommend")
    func availabilityAndPlatform() {
        for platform in LocalBridgePlatform.allCases where !platform.supportsMacBridge {
            var state = MacBridgePromptState()
            update(&state, verification: true, platform: platform)
            #expect(state.presented == nil)
        }
        var state = MacBridgePromptState()
        update(&state, download: false)
        #expect(state.presented == nil)
        update(&state, connected: true)
        #expect(state.presented == nil)
        update(&state)
        #expect(state.presented == .recommendation)
        update(&state, connected: true)
        #expect(state.presented == nil)
    }
}

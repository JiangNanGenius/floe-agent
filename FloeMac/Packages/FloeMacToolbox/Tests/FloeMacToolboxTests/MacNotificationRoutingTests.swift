import Foundation
import Testing
@testable import FloeMacToolbox

@MainActor
@Suite("Host notification routing contract")
struct MacNotificationRoutingTests {
    // A fake existing app handler; there is no access to UNUserNotificationCenter.
    private func route(_ identifier: String, fallback: (String) -> String) -> String {
        MacTimerPresentationPolicy.route(identifier: identifier, timer: { "timer" }, fallback: fallback)
    }

    @Test func validTimerAndLegacyIdentifiersUseTimerRoute() {
        let id = UUID().uuidString
        var fallbackCalls = 0
        let fallback: (String) -> String = { _ in fallbackCalls += 1; return "app" }
        #expect(route("floe.mac.toolbox.timer." + id + ".3", fallback: fallback) == "timer")
        #expect(route("floe.mac.toolbox.timer." + id, fallback: fallback) == "timer")
        #expect(fallbackCalls == 0)
    }

    @Test func foreignAndMalformedRequestsReachExistingAppUnchangedExactlyOnce() {
        let id = UUID().uuidString
        let identifiers = ["floe.chat.message.1", "", "floe.mac.toolbox.timer.",
                           "floe.mac.toolbox.timer.not-a-uuid.1",
                           "floe.mac.toolbox.timer." + id + ".1.more",
                           "floe.mac.toolbox.timer." + id + ".-1",
                           "floe.mac.toolbox.timer." + id + ".01",
                           "floe.mac.toolbox.timer." + id + ".18446744073709551616",
                           "floe.mac.toolbox.timer." + id + "."]
        var seen: [String] = []
        for value in identifiers {
            #expect(route(value) { seen.append($0); return "existing-app-result" } == "existing-app-result")
        }
        #expect(seen == identifiers)
    }

    @Test func boundariesMatchActualGenerator() {
        let id = UUID()
        #expect(MacTimerPresentationPolicy.owns(MacTimerNotificationController.identifier(for: id, generation: 0)))
        #expect(MacTimerPresentationPolicy.owns(MacTimerNotificationController.identifier(for: id, generation: UInt64.max)))
        #expect(MacTimerPresentationPolicy.owns(MacTimerNotificationController.identifier(for: id)))
    }
}

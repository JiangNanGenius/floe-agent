// FloeCoreTests — Linux service terminal events (H4).
//
// An observed managed-service end must reach the durable notification queue
// exactly once, scoped to the boot it belongs to:
//  * a repeat observation of the same service inside the same launch
//    generation replaces the queued alert instead of stacking a second one,
//  * a restart (new launch generation) is a new alert and never silently
//    merges into the previous boot's identifier,
//  * without a runtime generation the stable unsuffixed identifier is kept —
//    no generation is invented,
//  * the deep link routes to the exact environment.

import Foundation
import Testing
@testable import FloeCore
import FloeModels

@Suite("FloeCore.LinuxServiceTerminalEvents")
struct LinuxServiceTerminalEventTests {

    private func serviceEvent(
        environmentID: String = "env-1",
        title: String = "环境 · Node :8080",
        body: String,
        launchGeneration: UInt64?
    ) -> TaskTerminalEvent {
        TaskTerminalEvent.linuxSessionTerminal(
            environmentID: environmentID,
            environmentTitle: title,
            kind: .failed,
            body: body,
            launchGeneration: launchGeneration
        )
    }

    @Test("A repeated observation in one launch generation replaces the queued alert")
    func repeatedObservationSurfacesOnce() {
        var outbox = TaskNotificationOutbox()
        let first = serviceEvent(body: "失败 · 服务意外终止。", launchGeneration: 7)
        #expect(first.identifier == "linux.session.env-1.g7.terminal")
        #expect(outbox.enqueue(first, canPresent: false) == .queuedForAuthorization)

        let repeatEvent = serviceEvent(body: "失败 · 同一服务的再次观察。", launchGeneration: 7)
        #expect(outbox.enqueue(repeatEvent, canPresent: false) == .replacedQueuedEvent)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.pending.first?.body == repeatEvent.body)
    }

    @Test("A restart is a new alert, never merged into the previous boot's identifier")
    func nextLaunchGenerationIsANewAlert() {
        var outbox = TaskNotificationOutbox()
        let previousBoot = serviceEvent(body: "失败 · 上一启动。", launchGeneration: 7)
        let nextBoot = serviceEvent(body: "失败 · 新启动。", launchGeneration: 8)
        _ = outbox.enqueue(previousBoot, canPresent: false)
        #expect(outbox.enqueue(nextBoot, canPresent: false) == .queuedForAuthorization)
        #expect(outbox.pendingCount == 2)
        #expect(outbox.pending.map(\.identifier) == [
            "linux.session.env-1.g7.terminal",
            "linux.session.env-1.g8.terminal",
        ])
    }

    @Test("Without a runtime generation the stable identifier is kept, never invented")
    func unknownGenerationKeepsTheStableIdentifier() {
        let event = serviceEvent(environmentID: "env-2", body: "失败 · 环境已停止。", launchGeneration: nil)
        #expect(event.identifier == "linux.session.env-2.terminal")
    }

    @Test("The alert routes to the exact environment and carries the real title")
    func alertCarriesEnvironmentIdentity() {
        let event = serviceEvent(environmentID: "env-9", title: "构建环境 · Node :3000", body: "失败。", launchGeneration: 3)
        #expect(event.deepLink.kind == .linuxSession)
        #expect(event.deepLink.environmentID == "env-9")
        #expect(event.deepLink.userInfo["environmentID"] == "env-9")
        #expect(event.title.contains("Node :3000"))
    }
}

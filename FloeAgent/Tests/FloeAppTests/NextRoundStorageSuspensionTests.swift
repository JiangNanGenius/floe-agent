#if canImport(UIKit)
import Foundation
import UIKit
import Testing
@testable import FloeApp

@MainActor
private final class StorageLifecycleEvents {
    var values: [String] = []
}

@Suite("RQ26 process storage lifecycle", .serialized)
@MainActor
struct NextRoundStorageSuspensionTests {
    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func postOffMain(_ name: Notification.Name, center: NotificationCenter) {
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(name: name, object: nil)
            posted.signal()
        }
        // Keep the main actor occupied until its older callback has actually
        // been queued. The foreground post below then executes synchronously.
        #expect(posted.wait(timeout: .now() + 2) == .success)
    }

    @Test("Queued old background delivery cannot run after foreground resume")
    func oldBackgroundIsFencedByForeground() async {
        let center = NotificationCenter()
        let observer = StorageLifecycleObserver(center: center)
        let events = StorageLifecycleEvents()
        observer.observe(UIApplication.didEnterBackgroundNotification) { events.values.append("background") }
        observer.observe(UIApplication.willEnterForegroundNotification) { events.values.append("foreground") }
        defer { observer.stop() }
        postOffMain(UIApplication.didEnterBackgroundNotification, center: center)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(events.values == ["foreground"])
        await flushMainQueue()
        #expect(events.values == ["foreground"])
    }

    @Test("Stopping observers invalidates their already queued background action")
    func queuedDeliveryAfterStopIsFenced() async {
        let center = NotificationCenter()
        let observer = StorageLifecycleObserver(center: center)
        let events = StorageLifecycleEvents()
        observer.observe(UIApplication.didEnterBackgroundNotification) { events.values.append("background") }
        postOffMain(UIApplication.didEnterBackgroundNotification, center: center)
        observer.stop()
        await flushMainQueue()
        #expect(events.values.isEmpty)
    }

    @Test("Scene focus and temporary inactive overlays do not own process suspension")
    func scenesAndInactiveOverlaysDoNotSuspend() {
        let center = NotificationCenter()
        let observer = StorageLifecycleObserver(center: center)
        let events = StorageLifecycleEvents()
        observer.observe(UIApplication.didEnterBackgroundNotification) { events.values.append("background") }
        observer.observe(UIApplication.willEnterForegroundNotification) { events.values.append("foreground") }
        defer { observer.stop() }
        for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification,
                     UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            center.post(name: name, object: nil)
        }
        #expect(events.values.isEmpty)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(events.values == ["background", "foreground"])
    }
}
#endif

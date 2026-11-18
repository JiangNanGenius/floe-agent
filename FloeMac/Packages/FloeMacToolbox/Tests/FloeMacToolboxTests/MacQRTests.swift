import AVFoundation
import Foundation
import Observation
import Testing
import FloeToolboxCore
import FloeToolboxUtilities
import FloeMacMediaSystem
@testable import FloeMacToolbox

@MainActor
@Suite("Mac QR", .serialized)
struct MacQRTests {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < limit {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private func temporaryPNG(_ text: String) throws -> URL {
        let directory = try MacToolboxTestRoot.unique("qr")
        let url = directory.appendingPathComponent("code.png")
        try ToolboxQR.png(text: text, correction: .high).write(to: url)
        return url
    }

    @Test func generationUsesTheExistingPNGEncoderAndRejectsEmptyInput() {
        let model = MacQRModel(importImage: { nil })
        model.input = "https://example.test/工具箱"
        model.generate()
        let png = model.png
        #expect(png?.starts(with: [137, 80, 78, 71]) == true)
        #expect(!model.generationFailed)
        if let png {
            #expect(try! ToolboxQR.read(imageData: png).contains("https://example.test/工具箱"))
        }
        model.input = ""
        model.generate()
        #expect(model.png == nil)
        #expect(model.generationFailed)
    }

    @Test func readingARealGeneratedImageReturnsItsPayload() async throws {
        let url = try temporaryPNG("Floe Mac QR acceptance")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = MacQRModel(importImage: { url })
        model.readImage()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while model.reading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.reading)
        #expect(!model.readingFailed)
        #expect(model.didRead)
        #expect(model.result.contains("Floe Mac QR acceptance"))
        #expect(MacQRLink.destination(for: model.result.first ?? "") == nil)
    }

    @Test func invalidImageFailsWithoutClaimingAResult() async throws {
        let directory = try MacToolboxTestRoot.unique("qr-invalid")
        let url = directory.appendingPathComponent("invalid.png")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MacQRModel(importImage: { url })
        model.readImage()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while model.reading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.reading)
        #expect(model.readingFailed)
        #expect(!model.didRead)
        #expect(model.result.isEmpty)
    }

    @Test func rejectedQuitKeepsQRWorkModelValues() {
        let model = MacQRModel(importImage: { nil })
        model.input = "draft must survive"
        model.generate()
        model.acceptCameraResult("recognized must survive")
        let beforePNG = model.png
        #expect(beforePNG != nil)
        // This checks model value preservation only. The companion source
        // contract checks that SwiftUI does not replace this entire view on an
        // epoch change; AppKit identity still needs a real-host UI test.
        let registry = MacCameraRegistry()
        #expect(registry.beginTerminationPreparation())
        registry.cancelTerminationPreparation()
        #expect(model.input == "draft must survive")
        #expect(model.png == beforePNG)
        #expect(model.result == ["recognized must survive"])
        #expect(model.didRead)
    }

    @Test func cameraFailsClosedWhenTheHostHasNoUsageDescription() async {
        let model = MacQRCameraModel()
        #expect(!model.hasUsageDescription)
        await model.start()
        if case .unavailable = model.state {
        } else {
            Issue.record("Camera must not claim readiness without NSCameraUsageDescription")
        }
        model.stop()
    }

    @Test func lateCameraCallbacksCannotCrossStopOrRestart() async {
        var captures: [FakeQRCapture] = []
        let model = MacQRCameraModel(
            usageDescription: { true },
            authorize: { .authorized },
            makeController: { callback in
                let capture = FakeQRCapture(callback: callback)
                captures.append(capture)
                return capture
            }
        )

        await model.start()
        #expect(captures.count == 1)
        let old = captures[0]
        old.emit("queued-before-stop")
        model.stop()
        await Task.yield()
        #expect(old.stopCount == 1)
        #expect(model.latestCode == nil)

        await model.start()
        #expect(captures.count == 2)
        old.emit("late-from-old-session")
        await Task.yield()
        #expect(model.latestCode == nil)
        captures[1].emit("current-session")
        for _ in 0..<20 where model.latestCode == nil { await Task.yield() }
        #expect(model.latestCode == "current-session")
        model.stop()
        #expect(captures[1].stopCount == 1)
    }

    @Test func invalidAdmissionCannotRequestPermissionEvenBeforeQuitCompletes() async {
        var authorizations = 0
        var controllers = 0
        let model = MacQRCameraModel(usageDescription: { true },
            authorize: { authorizations += 1; return .authorized },
            admissionValid: { false },
            makeController: { callback in controllers += 1; return FakeQRCapture(callback: callback) })
        let scheduled = model.scheduleStart()
        await scheduled?.value
        #expect(authorizations == 0)
        #expect(controllers == 0)
        model.closePresentation()
    }

    @Test func cameraStartRechecksPresentationRegistryAndWindowAfterOldStopWait() async {
        for invalidation in 0..<3 {
            let registry = MacCameraRegistry()
            let presentation = MacQRPresentationGate()
            presentation.open()
            let presentationTicket = presentation.ticket
            guard let admissionTicket = registry.makeCameraAdmissionTicket() else {
                Issue.record("fresh registry must allow admission"); continue
            }
            let gate = FakeQRDispatchGate()
            var windowIsVisible = true
            var starts = 0
            let pending = Task { @MainActor in
                await MacQRCaptureAdmission.start(after: { await gate.wait(); return true },
                    whileCurrent: { presentation.isCurrent(presentationTicket) &&
                        registry.isCameraAdmissionCurrent(admissionTicket) && windowIsVisible },
                    operation: { starts += 1; return true })
            }
            guard await waitUntil({ gate.entered }) else {
                gate.release(); _ = await pending.value
                Issue.record("old camera stop gate was not reached"); continue
            }
            switch invalidation {
            case 0: presentation.close()
            case 1: _ = registry.beginTerminationPreparation()
            default: windowIsVisible = false
            }
            gate.release()
            let started = await pending.value
            #expect(!started)
            #expect(starts == 0)
        }
    }

    #if QR_CALLBACK_TESTING
    @Test func queuedRetryClosedBeforeDispatchNeverRequestsAuthorization() async {
        let dispatch = FakeQRDispatchGate()
        var authorizations = 0
        var controllers = 0
        let model = MacQRCameraModel(usageDescription: { true },
            authorize: { authorizations += 1; return .authorized },
            admissionValid: { true }, beforeScheduledStart: { await dispatch.wait() },
            makeController: { callback in controllers += 1; return FakeQRCapture(callback: callback) })
        let scheduled = model.scheduleStart()
        guard await waitUntil({ dispatch.entered }) else {
            model.closePresentation(); dispatch.release(); await scheduled?.value
            Issue.record("scheduled task never reached dispatch gate"); return
        }
        model.closePresentation()
        dispatch.release()
        await scheduled?.value
        #expect(authorizations == 0)
        #expect(controllers == 0)
    }

    #endif

    @Test func quitInvalidatesPendingAuthorizationForBothOutcomesAndPreservesQRWork() async {
        for rejected in [false, true] {
            let registry = MacCameraRegistry()
            guard let ticket = registry.makeCameraAdmissionTicket() else {
                Issue.record("fresh registry must admit"); continue
            }
            let auth = FakeQRAuthorizationGate()
            var controllers = 0
            let qrWork = MacQRModel(importImage: { nil })
            qrWork.input = "draft survives quit"
            qrWork.generate()
            let png = qrWork.png
            qrWork.acceptCameraResult("recognized payload")
            let old = MacQRCameraModel(usageDescription: { true }, authorize: { await auth.wait() },
                admissionValid: { registry.isCameraAdmissionCurrent(ticket) },
                makeController: { callback in controllers += 1; return FakeQRCapture(callback: callback) })
            let scheduled = old.scheduleStart()
            guard await waitUntil({ auth.entered }) else {
                old.closePresentation(); auth.finish(.authorized); await scheduled?.value
                Issue.record("authorization gate was not reached"); continue
            }
            #expect(registry.beginTerminationPreparation())
            if rejected { registry.cancelTerminationPreparation() }
            else { registry.commitTermination() }
            auth.finish(.authorized)
            await scheduled?.value
            #expect(controllers == 0)
            #expect(old.state != .ready)
            #expect(qrWork.input == "draft survives quit")
            #expect(qrWork.png == png && png != nil)
            #expect(qrWork.result == ["recognized payload"])
            #expect(qrWork.didRead)
            if rejected {
                #expect(!registry.isCameraAdmissionCurrent(ticket))
                #expect(registry.makeCameraAdmissionTicket() != nil)
            } else { #expect(registry.makeCameraAdmissionTicket() == nil) }
        }
    }

    @Test func windowReopenCannotReviveOldQueuedAuthorization() async {
        let auth = FakeQRAuthorizationGate()
        var oldControllers = 0
        var newControllers = 0
        let old = MacQRCameraModel(usageDescription: { true }, authorize: { await auth.wait() },
            admissionValid: { true }, makeController: { callback in
                oldControllers += 1; return FakeQRCapture(callback: callback)
            })
        let previous = old.scheduleStart()
        guard await waitUntil({ auth.entered }) else {
            old.closePresentation(); auth.finish(.authorized); await previous?.value
            Issue.record("authorization gate was not reached"); return
        }
        old.closePresentation()
        let fresh = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
            admissionValid: { true }, makeController: { callback in
                newControllers += 1; return FakeQRCapture(callback: callback)
            })
        let current = fresh.scheduleStart()
        await current?.value
        #expect(newControllers == 1)
        #expect(fresh.state == .ready)
        auth.finish(.authorized)
        await previous?.value
        #expect(oldControllers == 0)
        #expect(fresh.state == .ready)
        fresh.closePresentation()
    }

    #if QR_CALLBACK_TESTING
    @Test func queuedQRResultCannotPublishAfterQuitSucceedsOrIsRejected() async {
        for rejected in [false, true] {
            let registry = MacCameraRegistry()
            guard let ticket = registry.makeCameraAdmissionTicket() else {
                Issue.record("fresh admission ticket missing"); continue
            }
            let queue = FakeQRDispatchGate()
            var deliveryFinished = false
            var capture: FakeQRCapture?
            let work = MacQRModel(importImage: { nil })
            work.input = "keep this draft"; work.generate()
            let savedPNG = work.png
            work.acceptCameraResult("keep previous result")
            let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
                admissionValid: { registry.isCameraAdmissionCurrent(ticket) },
                beforeCodeDelivery: { await queue.wait() },
                afterCodeDelivery: { deliveryFinished = true },
                makeController: { callback in
                    let value = FakeQRCapture(callback: callback); capture = value; return value
                })
            await model.start()
            guard let capture else { Issue.record("capture not created"); continue }
            capture.emit("stale-result")
            guard await waitUntil({ queue.entered }) else {
                queue.release(); model.closePresentation()
                Issue.record("queued callback did not enter gate"); continue
            }
            #expect(registry.beginTerminationPreparation())
            if rejected { registry.cancelTerminationPreparation() } else { registry.commitTermination() }
            queue.release()
            guard await waitUntil({ deliveryFinished }) else {
                model.closePresentation(); Issue.record("callback did not finish"); continue
            }
            if let value = model.latestCode, model.mayDeliverCode(value) { work.acceptCameraResult(value) }
            #expect(model.latestCode == nil)
            #expect(work.input == "keep this draft")
            #expect(work.png == savedPNG && savedPNG != nil)
            #expect(work.result == ["keep previous result"])
            model.closePresentation()
        }
    }

    #endif

    @Test func pendingViewDeliveryIsRecheckedWhenQuitStarts() async {
        let registry = MacCameraRegistry()
        guard let ticket = registry.makeCameraAdmissionTicket() else {
            Issue.record("fresh admission ticket missing"); return
        }
        var capture: FakeQRCapture?
        let work = MacQRModel(importImage: { nil })
        work.acceptCameraResult("preserved")
        let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
            admissionValid: { registry.isCameraAdmissionCurrent(ticket) },
            makeController: { callback in
                let value = FakeQRCapture(callback: callback); capture = value; return value
            })
        await model.start()
        guard let capture else { Issue.record("capture not created"); return }
        capture.emit("previously-valid")
        guard await waitUntil({ model.latestCode == "previously-valid" }) else {
            model.closePresentation(); Issue.record("callback did not publish"); return
        }
        #expect(registry.beginTerminationPreparation())
        #expect(!model.mayDeliverCode("previously-valid"))
        if model.mayDeliverCode("previously-valid") { work.acceptCameraResult("previously-valid") }
        #expect(work.result == ["preserved"])
        registry.cancelTerminationPreparation()
        #expect(!model.mayDeliverCode("previously-valid"))
        model.closePresentation()
    }

    #if QR_CALLBACK_TESTING
    @Test func queuedOldWindowResultCannotReachReopenedQRWork() async {
        let queue = FakeQRDispatchGate()
        var deliveryFinished = false
        var oldCapture: FakeQRCapture?
        let old = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
            beforeCodeDelivery: { await queue.wait() }, afterCodeDelivery: { deliveryFinished = true },
            makeController: { callback in
                let value = FakeQRCapture(callback: callback); oldCapture = value; return value
            })
        await old.start()
        guard let oldCapture else { Issue.record("old capture not created"); return }
        oldCapture.emit("late-old-window")
        guard await waitUntil({ queue.entered }) else {
            queue.release(); old.closePresentation(); Issue.record("old callback not queued"); return
        }
        old.closePresentation()
        var currentCapture: FakeQRCapture?
        let fresh = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
            makeController: { callback in
                let value = FakeQRCapture(callback: callback); currentCapture = value; return value
            })
        await fresh.start()
        currentCapture?.emit("new-window")
        guard await waitUntil({ fresh.latestCode == "new-window" }) else {
            queue.release(); fresh.closePresentation(); Issue.record("new result did not arrive"); return
        }
        queue.release()
        guard await waitUntil({ deliveryFinished }) else {
            fresh.closePresentation(); Issue.record("old callback did not finish"); return
        }
        #expect(old.latestCode == nil)
        #expect(!old.mayDeliverCode("late-old-window"))
        #expect(fresh.mayDeliverCode("new-window"))
        #expect(fresh.latestCode == "new-window")
        fresh.closePresentation()
    }

    #endif

    @Test func equalPayloadFromNewRunCannotAuthorizeOldPublishedResult() async {
        var captures: [FakeQRCapture] = []
        let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
            makeController: { callback in
                let capture = FakeQRCapture(callback: callback); captures.append(capture); return capture
            })
        await model.start()
        guard captures.count == 1 else { Issue.record("first capture missing"); return }
        captures[0].emit("same-payload")
        guard await waitUntil({ model.latestResult != nil }), let old = model.latestResult else {
            model.closePresentation(); Issue.record("first result missing"); return
        }
        model.stop()
        await model.start()
        guard captures.count == 2 else { model.closePresentation(); Issue.record("second capture missing"); return }
        captures[1].emit("same-payload")
        guard await waitUntil({ model.latestResult != nil }), let current = model.latestResult else {
            model.closePresentation(); Issue.record("second result missing"); return
        }
        #expect(old.code == current.code)
        #expect(old.run != current.run)
        #expect(!model.mayDeliverResult(old))
        #expect(model.mayDeliverResult(current))
        model.closePresentation()
    }

    @Test func dismissalBeforeViewDeliveryFencesPublishedResult() async {
        let presentation = MacQRPresentationGate()
        presentation.open()
        let ticket = presentation.ticket
        var capture: FakeQRCapture?
        let work = MacQRModel(importImage: { nil })
        work.input = "preserve draft"; work.generate(); let png = work.png
        work.acceptCameraResult("preserve result")
        let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized },
            admissionValid: { presentation.isCurrent(ticket) }, makeController: { callback in
                let value = FakeQRCapture(callback: callback); capture = value; return value
            })
        await model.start()
        guard let capture else { Issue.record("capture missing"); return }
        capture.emit("delayed-result")
        guard await waitUntil({ model.latestResult != nil }), let result = model.latestResult else {
            model.closePresentation(); Issue.record("result missing"); return
        }
        presentation.close() // same synchronous operation as the binding setter
        #expect(!model.mayDeliverResult(result))
        presentation.open()
        let reopenedTicket = presentation.ticket
        presentation.close(ifCurrent: ticket) // old sheet teardown is too late
        #expect(presentation.isCurrent(reopenedTicket))
        #expect(!model.mayDeliverResult(result))
        if model.mayDeliverResult(result) { work.acceptCameraResult(result.code) }
        #expect(work.input == "preserve draft")
        #expect(work.png == png && png != nil)
        #expect(work.result == ["preserve result"])
        model.closePresentation()
    }

    @Test func latePermissionReplyCannotRestartAStoppedCamera() async {
        let gate = FakeQRAuthorizationGate()
        var created = 0
        let model = MacQRCameraModel(
            usageDescription: { true },
            authorize: { await gate.wait() },
            makeController: { callback in
                created += 1
                return FakeQRCapture(callback: callback)
            }
        )
        let start = Task { await model.start() }
        while !gate.entered { await Task.yield() }
        model.stop()
        gate.finish(.authorized)
        await start.value
        #expect(created == 0)
        #expect(model.latestCode == nil)
    }

    @Test func stoppedDuringStartupCannotPublishLateReadiness() async {
        let gate = FakeQRStartGate()
        var capture: FakeQRCapture?
        let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized }, makeController: { callback in
            let value = FakeQRCapture(callback: callback, startAction: { await gate.wait() })
            capture = value
            return value
        })
        let start = Task { await model.start() }
        while !gate.entered { await Task.yield() }
        model.stop()
        gate.finish(true)
        await start.value
        #expect(capture?.stopCount == 1)
        if case .unavailable = model.state {} else { Issue.record("Late start must not mark the camera ready") }
        #expect(model.latestCode == nil)
    }

    @Test func cameraFailureCanBeRetried() async {
        var attempts = 0
        let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized }, makeController: { callback in
            attempts += 1
            let succeeds = attempts > 1
            return FakeQRCapture(callback: callback, startAction: { succeeds })
        })
        await model.start()
        if case .failed = model.state {} else { Issue.record("A failed start must be visible") }
        model.stop()
        await model.start()
        #expect(model.state == .ready)
        #expect(attempts == 2)
        model.stop()
    }

    @Test func interruptionLeavesReadyAndCannotAffectTheNextRun() async {
        var captures: [FakeQRCapture] = []
        let model = MacQRCameraModel(usageDescription: { true }, authorize: { .authorized }, makeController: { callback in
            let capture = FakeQRCapture(callback: callback)
            captures.append(capture)
            return capture
        })
        await model.start()
        #expect(model.state == .ready)
        captures[0].interrupt()
        if case .failed = model.state {} else { Issue.record("An interrupted camera must leave ready state") }
        #expect(model.session == nil)
        #expect(captures[0].stopCount == 1)
        await model.start()
        #expect(model.state == .ready)
        captures[0].interrupt()
        captures[0].emit("stale")
        await Task.yield()
        #expect(model.state == .ready)
        #expect(model.latestCode == nil)
        model.stop()
    }

    @Test func cameraMonitorReportsInterruptionAndFencesOldObservation() async {
        let source = FakeCameraRunningState()
        let monitor = MacQRCameraMonitor(isRunning: { source.running })
        var failures = 0
        monitor.start { failures += 1 }
        source.running = false
        for _ in 0..<20 where failures == 0 { await Task.yield() }
        #expect(failures == 1)
        source.running = true
        monitor.start { failures += 1 }
        source.running = false
        monitor.stop()
        source.running = true
        monitor.start { failures += 10 }
        await Task.yield()
        #expect(failures == 1)
        source.running = false
        for _ in 0..<20 where failures == 1 { await Task.yield() }
        #expect(failures == 11)
        monitor.stop()
    }

    @Test func windowEventsAreScopedToTheirOwnWindowAndSheetParent() {
        let own = NSObject(), parent = NSObject(), other = NSObject()
        #expect(MacQRWindowReference.owns(own, parent: parent, sender: own))
        #expect(MacQRWindowReference.owns(own, parent: parent, sender: parent))
        #expect(!MacQRWindowReference.owns(own, parent: parent, sender: other))
        #expect(!MacQRWindowReference.owns(nil, parent: parent, sender: parent))
    }

    @Test func userCanReuseARecognizedPayloadForGeneration() {
        let model = MacQRModel(importImage: { nil })
        model.useResult("https://example.test/reuse")
        #expect(model.input == "https://example.test/reuse")
        #expect(model.png == nil)
    }
}

@MainActor
@Observable
private final class FakeCameraRunningState { var running = true }

@MainActor
private final class FakeQRCapture: MacQRCaptureControlling {
    let callback: @Sendable (String) -> Void
    let startAction: @MainActor () async -> Bool
    var onStopped: (@MainActor () -> Void)?
    var previewSession: AVCaptureSession? { nil }
    private(set) var stopCount = 0

    init(callback: @escaping @Sendable (String) -> Void, startAction: @escaping @MainActor () async -> Bool = { true }) {
        self.callback = callback
        self.startAction = startAction
    }
    func start() async -> Bool { await startAction() }
    func stop() { stopCount += 1 }
    func emit(_ code: String) { callback(code) }
    func interrupt() { onStopped?() }
}

@MainActor
private final class FakeQRStartGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private final class FakeQRAuthorizationGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<MacQRCameraAuthorization, Never>?

    func wait() async -> MacQRCameraAuthorization {
        entered = true
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func finish(_ value: MacQRCameraAuthorization) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private final class FakeQRDispatchGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiter = continuation }
        }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

// Test-only compatibility for the inherited assertions. Production delivery
// uses the complete result, including its run identity.
@MainActor
private extension MacQRCameraModel {
    func mayDeliverCode(_ code: String) -> Bool {
        guard let result = latestResult, result.code == code else { return false }
        return mayDeliverResult(result)
    }
}

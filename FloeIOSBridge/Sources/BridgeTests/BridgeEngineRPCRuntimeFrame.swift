import Foundation
import UIKit
import BridgeCore

/// Shared screen-frame producer. The host/media worker calls this; it never
/// starts a second XCTest session and never persists a frame.
extension BridgeEngineRPCRuntime {

    nonisolated var frameCaptureReady: Bool {
        // Readiness is lifecycle/lock/freshness, not momentary gate usage:
        // captureFrame still returns nil while an action owns the gate.
        captureLifecycleAllowed(generation: nil)
    }

    /// Darwin notify reads only: no XCTest SDK call belongs in this
    /// nonisolated readiness path. An unavailable or never-read lock state is
    /// not "unlocked".
    nonisolated private func captureLifecycleAllowed(generation: UInt64?) -> Bool {
        let snapshot = BridgeSharedState.shared.snapshot()
        return BridgeEngineCaptureAdmission.allows(
            entryAccepted: state.isEntryAccepted,
            engineRunning: snapshot.engineRunning,
            enginePidMatches: snapshot.enginePid == processIdentifier,
            serviceRunning: snapshot.serviceRunning,
            phaseReady: snapshot.phase == .ready,
            generationMatches: generation.map { snapshot.generation == $0 } ?? true,
            lockState: lockState(),
            heartbeatCurrent: engineHeartbeatCurrent()
        )
    }

    nonisolated func captureFrame() async -> BridgeScreenFrame? {
        guard frameCaptureReady else { return nil }
        guard gate.tryAcquire() else { return nil }
        defer { gate.release() }
        // Re-check after taking the slot: Stop/lock can land in between.
        let snapshot = BridgeSharedState.shared.snapshot()
        guard captureLifecycleAllowed(generation: snapshot.generation) else { return nil }
        return await captureFrameOnMain(generation: snapshot.generation)
    }

    @MainActor
    private func captureFrameOnMain(generation: UInt64) -> BridgeScreenFrame? {
        guard captureLifecycleAllowed(generation: generation) else { return nil }
        guard let capture = sdk.captureScreen() else { return nil }
        guard let data = sdk.jpegData(capture.image, quality: 0.6), !data.isEmpty else { return nil }
        let pixelWidth = capture.image.cgImage?.width
            ?? Int(capture.image.size.width * capture.image.scale)
        let pixelHeight = capture.image.cgImage?.height
            ?? Int(capture.image.size.height * capture.image.scale)
        guard pixelWidth > 1, pixelHeight > 1 else { return nil }
        // The screenshot and encoding may take long enough for Stop or lock to
        // land. Re-check the captured generation and live lock state before
        // returning, so a late frame can never look authorized.
        guard captureLifecycleAllowed(generation: generation) else { return nil }
        return BridgeScreenFrame(
            imageData: data,
            encoding: .jpeg,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointWidth: capture.metrics.pointWidth,
            pointHeight: capture.metrics.pointHeight,
            capturedAt: Date()
        )
    }
}

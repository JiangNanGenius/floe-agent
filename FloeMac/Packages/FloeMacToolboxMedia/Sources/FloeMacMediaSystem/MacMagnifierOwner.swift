import Foundation
import Observation

/// Owns one visible magnifier surface and fences queued starts across page,
/// window and orderly-termination transitions.
@MainActor @Observable
public final class MacMagnifierOwner {
    public private(set) var camera: MacCameraController
    private let registry: MacCameraRegistry
    private let makeCamera: @MainActor () -> MacCameraController
    private var visible = false
    private var epoch = UUID()
    private var windowAvailable: @MainActor () -> Bool = { false }

    public convenience init(environment: MacToolboxMediaEnvironment) {
        self.init(registry: environment.cameraRegistry, makeCamera: { environment.makeCameraController() })
    }

    init(registry: MacCameraRegistry, makeCamera: @escaping @MainActor () -> MacCameraController) {
        self.registry = registry
        self.makeCamera = makeCamera
        self.camera = makeCamera()
    }

    public func appear(windowAvailable: @escaping @MainActor () -> Bool) {
        visible = true
        self.windowAvailable = windowAvailable
        restoreIfClosed()
        installGate()
    }

    public func disappear() {
        visible = false
        epoch = UUID()
        camera.closeForWindow()
    }

    /// Window close/miniaturization closes this owner even if SwiftUI keeps
    /// the view mounted; reopening requires a fresh controller.
    public func windowClosed() { epoch = UUID(); camera.closeForWindow() }
    public func windowReopened() { guard visible else { return }; restoreIfClosed(); installGate() }
    public func terminationCancelled() { guard visible else { return }; restoreIfClosed(); installGate() }

    public func startTicket() -> UUID? {
        guard visible, windowAvailable(), !camera.isWindowClosed,
              registry.makeCameraAdmissionTicket() != nil else { return nil }
        return epoch
    }

    @discardableResult
    public func start(ticket: UUID, retry: Bool = false) async -> Bool {
        guard current(ticket) else { return false }
        guard await registry.retryRetiredStops(), current(ticket) else { return false }
        let selected = camera
        return retry ? await selected.restart() : await selected.start()
    }

    private func current(_ ticket: UUID) -> Bool {
        visible && epoch == ticket && windowAvailable() && !camera.isWindowClosed
            && registry.makeCameraAdmissionTicket() != nil
    }

    private func restoreIfClosed() {
        guard camera.isWindowClosed, registry.makeCameraAdmissionTicket() != nil else { return }
        epoch = UUID()
        camera = makeCamera()
    }

    private func installGate() {
        let ticket = epoch
        camera.setCaptureAvailability { [weak self] in self?.current(ticket) == true }
    }
}

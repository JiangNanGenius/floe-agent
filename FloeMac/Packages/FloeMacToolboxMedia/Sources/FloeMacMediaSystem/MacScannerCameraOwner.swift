import Foundation
import Observation
import FloeMacMediaCore

/// Scanner camera presentation fence. The draft remains app-owned across
/// surfaces; controllers retire through the existing process camera registry.
@MainActor @Observable
public final class MacScannerCameraOwner {
    public let draft: MacScannerDraftOwner
    public private(set) var camera: MacCameraController?
    private let registry: MacCameraRegistry
    private let makeCamera: @MainActor () -> MacCameraController
    private var presentationTicket: UUID?
    private var registryTicket: UUID?
    private var windowAvailable: @MainActor () -> Bool = { false }
    private var availabilityWaiters: [UUID: @MainActor () -> Void] = [:]

    public convenience init(environment: MacToolboxMediaEnvironment) {
        self.init(draft: environment.scannerDraft, registry: environment.cameraRegistry,
                  makeCamera: { environment.makeCameraController() })
    }

    init(draft: MacScannerDraftOwner, registry: MacCameraRegistry,
         makeCamera: @escaping @MainActor () -> MacCameraController) {
        self.draft = draft; self.registry = registry; self.makeCamera = makeCamera
    }

    /// Establishes a surface only; requesting camera permission requires start.
    @discardableResult
    public func appear(windowAvailable: @escaping @MainActor () -> Bool) -> UUID? {
        if let ticket = presentationTicket, let registryTicket,
           draft.isCurrentSurface(ticket), registry.isCameraAdmissionCurrent(registryTicket) { return nil }
        retirePresentation()
        // Retiring the old surface synchronously wakes waiters. A waiter may
        // already have acquired ownership before this invocation resumes.
        guard presentationTicket == nil, camera == nil else { return nil }
        guard let registryTicket = registry.makeCameraAdmissionTicket() else { return nil }
        let ticket = draft.appear()
        self.presentationTicket = ticket
        self.registryTicket = registryTicket
        self.windowAvailable = windowAvailable
        let camera = makeCamera()
        self.camera = camera
        camera.setCaptureAvailability { [weak self] in self?.current(ticket) == true }
        camera.onLiveCodes = { [weak self] codes in
            guard let self, self.current(ticket) else { return }
            try? self.draft.acceptLiveCodes(codes, ticket: ticket)
        }
        return ticket
    }

    public func disappear(ticket: UUID) {
        guard presentationTicket == ticket else { return }
        retirePresentation()
    }

    private func retirePresentation() {
        let hadPresentation = presentationTicket != nil
        presentationTicket = nil; registryTicket = nil
        if hadPresentation { draft.disappear() }
        camera?.onLiveCodes = nil
        camera?.closeForWindow()
        camera = nil
        if hadPresentation {
            let waiters = Array(availabilityWaiters.values)
            availabilityWaiters.removeAll()
            for waiter in waiters { waiter() }
        }
    }

    func waitForAvailability(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        availabilityWaiters[id] = callback
        return id
    }

    func cancelAvailabilityWait(_ id: UUID) { availabilityWaiters.removeValue(forKey: id) }

    func camera(for ticket: UUID) -> MacCameraController? {
        guard presentationTicket == ticket else { return nil }
        return camera
    }

    @discardableResult
    public func start(ticket: UUID, retry: Bool = false) async -> Bool {
        guard current(ticket), await registry.retryRetiredStops(), current(ticket), let camera else { return false }
        return retry ? await camera.restart() : await camera.start()
    }

    /// A delayed photo is admitted only into the same still-visible draft.
    public func capturePage(ticket: UUID) async throws {
        guard current(ticket), let camera else { throw MacScannerDraftError.unavailable }
        let data = try await camera.capturePage()
        guard current(ticket) else { throw MacScannerDraftError.unavailable }
        try draft.addImage(data, source: .camera, ticket: ticket)
    }

    private func current(_ ticket: UUID) -> Bool {
        guard ticket == presentationTicket, let registryTicket,
              registry.isCameraAdmissionCurrent(registryTicket), draft.isCurrentSurface(ticket),
              windowAvailable(), let camera, !camera.isWindowClosed else { return false }
        return true
    }
}

/// Per-view lease: a visible overlapping surface is notified when the previous
/// owner retires. Disappearing views remove their waiter before releasing.
@MainActor @Observable
public final class MacScannerSurfaceLease {
    public private(set) var ticket: UUID?
    public var camera: MacCameraController? { ticket.flatMap { owner.camera(for: $0) } }
    private let owner: MacScannerCameraOwner
    private var visible = false
    private var waiter: UUID?
    private var windowAvailable: @MainActor () -> Bool = { false }

    public init(owner: MacScannerCameraOwner) { self.owner = owner }

    public func appear(windowAvailable: @escaping @MainActor () -> Bool) {
        visible = true
        self.windowAvailable = windowAvailable
        acquireIfNeeded()
    }

    public func disappear() {
        visible = false
        if let waiter { owner.cancelAvailabilityWait(waiter); self.waiter = nil }
        if let ticket { self.ticket = nil; owner.disappear(ticket: ticket) }
    }

    private func acquireIfNeeded() {
        guard visible, ticket == nil, waiter == nil else { return }
        if let acquired = owner.appear(windowAvailable: windowAvailable) {
            ticket = acquired
        } else {
            waiter = owner.waitForAvailability { [weak self] in
                guard let self else { return }
                self.waiter = nil
                self.acquireIfNeeded()
            }
        }
    }
}

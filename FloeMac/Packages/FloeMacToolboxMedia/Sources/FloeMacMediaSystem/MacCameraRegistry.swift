import Combine
import Foundation

/// Process-owned authority for cameras created by this media environment.
/// Idle, unstarted controllers are weakly tracked to avoid retaining transient
/// SwiftUI view initializers; a started or retired controller is held strongly
/// until its own stopped-state confirmation. This never releases broker leases.
@MainActor
public final class MacCameraRegistry: ObservableObject {
    private struct Entry {
        weak var weakOwner: (any MacScannerCaptureOwning)?
        var retainedOwner: (any MacScannerCaptureOwning)?
        var retired = false
    }
    @Published public private(set) var cameraEpoch = UUID()
    /// Invalidated synchronously when orderly termination starts, including
    /// work that has not yet created a camera controller (e.g. permission).
    @Published public private(set) var cameraAdmissionEpoch = UUID()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var draining: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var preparing = false
    private var preparationID = UUID()
    private var terminal = false

    public init() {}

    public func makeCameraAdmissionTicket() -> UUID? {
        guard !preparing, !terminal else { return nil }
        return cameraAdmissionEpoch
    }

    public func isCameraAdmissionCurrent(_ ticket: UUID) -> Bool {
        !preparing && !terminal && ticket == cameraAdmissionEpoch
    }

    @discardableResult
    func register(_ camera: any MacScannerCaptureOwning) -> Bool {
        guard !preparing, !terminal else { camera.closeForWindow(); return false }
        purgeDead()
        let id = ObjectIdentifier(camera)
        guard entries[id] == nil else { return false }
        entries[id] = Entry(weakOwner: camera, retainedOwner: nil)
        return true
    }

    /// Called synchronously by the controller immediately before a start can
    /// request permission or acquire its lease.
    @discardableResult
    func admit(_ camera: any MacScannerCaptureOwning) -> Bool {
        let id = ObjectIdentifier(camera)
        guard !preparing, !terminal, var entry = entries[id], !entry.retired,
              entry.weakOwner === camera else { return false }
        entry.retainedOwner = camera
        entries[id] = entry
        return true
    }

    /// A controller may release the strong registry hold only after its own
    /// hardware stop and broker release have completed.
    func confirmedInactive(_ camera: any MacScannerCaptureOwning) {
        let id = ObjectIdentifier(camera)
        guard var entry = entries[id], entry.weakOwner === camera else { return }
        if entry.retired {
            entries.removeValue(forKey: id)
        } else {
            entry.retainedOwner = nil
            entries[id] = entry
        }
    }

    func retire(_ camera: any MacScannerCaptureOwning) {
        let id = ObjectIdentifier(camera)
        guard var entry = entries[id], entry.weakOwner === camera, !entry.retired else { return }
        entry.retired = true
        entry.retainedOwner = camera
        entries[id] = entry
        camera.closeForWindow()
        let task = Task { @MainActor [weak self] in
            let stopped = await camera.waitUntilStopped()
            if stopped { self?.confirmedInactive(camera) }
            _ = self?.draining.removeValue(forKey: id)
        }
        draining[id] = task
    }

    /// Admission closes before any await; every live tracked tool is retired.
    @discardableResult
    public func beginTerminationPreparation() -> Bool {
        guard !terminal, !preparing else { return false }
        preparing = true
        cameraAdmissionEpoch = UUID()
        preparationID = UUID()
        let cameras = entries.values.compactMap { $0.retainedOwner ?? $0.weakOwner }
        for camera in cameras { retire(camera) }
        return true
    }

    public func waitForAllStopped() async -> Bool {
        guard preparing, !terminal else { return false }
        let expected = preparationID
        let stopped = await retryRetiredStops()
        return stopped && preparing && !terminal && preparationID == expected
    }

    /// Explicit user retry also works after a rejected quit. Only the old owner
    /// can retry its own stop; never release its lease from this registry.
    @discardableResult
    public func retryRetiredStops() async -> Bool {
        while !draining.isEmpty {
            let pending = draining
            for (id, task) in pending {
                await task.value
                draining.removeValue(forKey: id)
            }
        }
        let pending = entries.values.filter(\.retired).compactMap { $0.retainedOwner }
        for camera in pending {
            if await camera.waitUntilStopped() { confirmedInactive(camera) }
        }
        purgeDead()
        return !entries.values.contains(where: \.retired)
    }

    public var retainedUnconfirmedCount: Int {
        entries.values.filter { $0.retired && $0.retainedOwner != nil }.count
    }

    public func cancelTerminationPreparation() {
        guard preparing, !terminal else { return }
        preparing = false
        preparationID = UUID()
        cameraEpoch = UUID()
    }

    public func commitTermination() {
        terminal = true
        cameraAdmissionEpoch = UUID()
        preparing = false
        preparationID = UUID()
        let cameras = entries.values.compactMap { $0.retainedOwner ?? $0.weakOwner }
        for camera in cameras { retire(camera) }
    }

    private func purgeDead() {
        entries = entries.filter { $0.value.weakOwner != nil || $0.value.retainedOwner != nil }
    }
}

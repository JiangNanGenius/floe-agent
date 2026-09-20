// FloeExecution — Linux guest lazy activation.
//
// Phase 2: Linux is the main execution path, so an execution request must not
// fail just because nobody pressed "start" in Settings. Every app-side entry
// point (shell routing, exec.localPython, exec.localService, package UI,
// apt/dpkg commands) funnels through `LinuxGuestActivator.ensureRunning`:
// an owned-but-stopped guest is started on demand, and a start failure keeps
// the engine's honest reason (image not installed, not qualified, busy).

import Foundation
import FloeCore
import FloeTools

public enum LinuxGuestActivator {
    /// Ensures the guest for an owned Linux environment is running, starting
    /// it on demand. Throws the engine's honest reason when it cannot start
    /// (component not installed, image not qualified, another guest busy).
    /// `onColdStart` runs only when this call actually started a stopped
    /// guest (the app uses it for legacy package seeding).
    public static func ensureRunning(
        environmentID: String,
        guests: any LinuxCommandRunning,
        controller: (any LinuxGuestControlling)?,
        onColdStart: (@Sendable (String) async -> Void)? = nil
    ) async throws {
        guard await guests.ownsLinuxEnvironment(environmentID: environmentID) else {
            throw LinuxGuestError.notOwned(environmentID: environmentID)
        }
        if await guests.supports(environmentID: environmentID) { return }
        guard let controller else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        let started = try await controller.startGuest(environmentID: environmentID, taskID: nil)
        guard started else {
            throw LinuxGuestError.notOwned(environmentID: environmentID)
        }
        if let onColdStart { await onColdStart(environmentID) }
    }
}

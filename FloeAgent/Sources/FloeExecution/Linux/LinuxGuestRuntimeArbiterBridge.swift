// FloeExecution — production bridge from the Linux guest service to the
// heavy-runtime arbiter.
//
// The arbiter owns the physical MLX/Linux boundary, but only the guest
// registry can answer which environments actually hold capacity and which of
// those are a logical run's own disposable tool guest. This bridge builds the
// arbiter's probe/stopper/releaser closures from the real service, so the
// app-side wiring and the integration tests exercise exactly the same facts:
//
//   * probe      — the registry's reservation set and per-guest ownership
//                  facts (owner run, commands, terminals, services, forwards,
//                  quarantine), unioned with the arbiter's admitted pending
//                  starts. Nothing is inferred from conversation or UI state.
//   * stopper    — the existing explicit `stopGuest` path, used only after a
//                  user confirmation (`stopGuestsAndProceed`).
//   * releaser   — the scoped `releaseTransientGuest` path: it revalidates
//                  inside the registry and refuses non-transient work instead
//                  of destroying it. Only `.released` is reported back for
//                  post-release bookkeeping.
//
// The auto-release decision itself lives in `HeavyRuntimeArbiter`: it only
// reaches the releaser when EVERY reported guest is owned by the requesting
// logical run and verified transient, and it still requires the release to
// settle (probe empty) before the model may proceed.

import Foundation
import FloeCore

public enum LinuxGuestRuntimeArbiterBridge {
    /// The arbiter's activity probe over the real guest service. Environment
    /// ids are opaque Floe ids; the reported facts are registry measurements.
    /// `arbiter` defaults to the process-wide instance; tests pass their own
    /// dedicated instance so the pending-start union is observed identically.
    public static func activityProbe(
        service: any LinuxGuestControlling & LinuxGuestLocalServiceControlling,
        arbiter: HeavyRuntimeArbiter = .shared
    ) -> HeavyRuntimeArbiter.ActivityProbe {
        {
            var guests: [HeavyRuntimeArbiter.LinuxGuestActivity] = []
            for detail in await service.guestActivityDetails() {
                guests.append(HeavyRuntimeArbiter.LinuxGuestActivity(
                    environmentID: detail.environmentID,
                    ownerRunID: detail.ownerRunID,
                    isTransientToolGuest: detail.isTransientToolGuest
                ))
            }
            let reservations = await service.environmentsWithGuestActivity()
            let known = Set(guests.map(\.environmentID))
            for environmentID in reservations where !known.contains(environmentID) {
                // A reservation without ownership facts (e.g. a start that has
                // not registered its session yet) is conflicting work.
                guests.append(HeavyRuntimeArbiter.LinuxGuestActivity(environmentID: environmentID))
            }
            // Admitted starts racing to publish their reservation: report them
            // exactly like a running guest so a stop confirmation can never
            // deadlock behind its own model. They carry no ownership facts and
            // are never auto-released.
            for environmentID in arbiter.pendingLinuxStartEnvironmentIDs
            where !known.contains(environmentID) {
                guests.append(HeavyRuntimeArbiter.LinuxGuestActivity(environmentID: environmentID))
            }
            guests.sort { $0.environmentID < $1.environmentID }
            var services: [String] = []
            for environmentID in reservations.sorted() {
                let count = await service.activeLocalServiceCount(environmentID: environmentID)
                if count > 0 { services.append("\(environmentID):\(count)") }
            }
            return HeavyRuntimeArbiter.LinuxActivity(
                guestEnvironmentIDs: guests.map(\.environmentID),
                localServices: services,
                guests: guests
            )
        }
    }

    /// The confirmation path: stops the reported guests only after the user
    /// answered `stopGuestsAndProceed` (the arbiter never calls this on its
    /// own for foreign or non-transient work).
    public static func guestStopper(
        service: any LinuxGuestControlling
    ) -> HeavyRuntimeArbiter.GuestStopper {
        { activity in
            for environmentID in activity.guestEnvironmentIDs {
                await service.stopGuest(environmentID: environmentID)
            }
        }
    }

    /// The scoped own-transient release path. Each guest is released only when
    /// it is still owned by the recorded run and still transient; a refusal
    /// leaves the guest untouched for the fallback decision.
    /// `onReleased` runs only for guests that actually reached `.released`
    /// (the app clears its applied-forward view there).
    public static func transientGuestReleaser(
        service: any LinuxGuestControlling,
        onReleased: (@Sendable (String) async -> Void)? = nil
    ) -> HeavyRuntimeArbiter.TransientGuestReleaser {
        { activity in
            for guest in activity.guests where guest.isTransientToolGuest {
                guard let ownerRunID = guest.ownerRunID else { continue }
                let outcome = await service.releaseTransientGuest(
                    environmentID: guest.environmentID,
                    expectedOwnerRunID: ownerRunID
                )
                if outcome.isReleased {
                    await onReleased?(guest.environmentID)
                } else {
                    FloeLogger(category: .tools).info(
                        "Linux guest transient release not applied environment=\(guest.environmentID) outcome=\(outcome.diagnosticSummary)"
                    )
                }
            }
        }
    }
}

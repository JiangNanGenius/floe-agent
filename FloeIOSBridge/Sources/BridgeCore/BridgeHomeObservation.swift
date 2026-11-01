import Foundation

/// One bounded observation around the Home button. The strings are the public
/// `XCUIApplication.state` names (or `unknown`) plus the host
/// `UIApplication.State` name; nothing here is guessed or derived from a
/// previous command.
public struct BridgeHomeObservation: Equatable, Sendable {
    public var sourceBundleIdentifier: String?
    public var sourceStateBefore: String
    public var sourceStateAfter: String
    public var springboardStateBefore: String
    public var springboardStateAfter: String
    public var hostStateBefore: String
    public var hostStateAfter: String
    public var pressReturned: Bool

    public init(sourceBundleIdentifier: String?,
                sourceStateBefore: String,
                sourceStateAfter: String,
                springboardStateBefore: String,
                springboardStateAfter: String,
                hostStateBefore: String,
                hostStateAfter: String,
                pressReturned: Bool) {
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceStateBefore = sourceStateBefore
        self.sourceStateAfter = sourceStateAfter
        self.springboardStateBefore = springboardStateBefore
        self.springboardStateAfter = springboardStateAfter
        self.hostStateBefore = hostStateBefore
        self.hostStateAfter = hostStateAfter
        self.pressReturned = pressReturned
    }
}

public struct BridgeHomeAssessment: Equatable, Sendable {
    public var dispatched: Bool
    public var sourceKnown: Bool
    public var sourceLeftForeground: Bool
    public var springboardForeground: Bool
    public var hostBackgrounded: Bool
    public var actualHomeObserved: Bool
    public var destinationVerified: Bool
    public var homeEvidence: String
    public var status: String

    public init(dispatched: Bool,
                sourceKnown: Bool,
                sourceLeftForeground: Bool,
                springboardForeground: Bool,
                hostBackgrounded: Bool,
                actualHomeObserved: Bool,
                destinationVerified: Bool,
                homeEvidence: String,
                status: String) {
        self.dispatched = dispatched
        self.sourceKnown = sourceKnown
        self.sourceLeftForeground = sourceLeftForeground
        self.springboardForeground = springboardForeground
        self.hostBackgrounded = hostBackgrounded
        self.actualHomeObserved = actualHomeObserved
        self.destinationVerified = destinationVerified
        self.homeEvidence = homeEvidence
        self.status = status
    }
}

/// Classifies Home evidence without claiming more than was observed.
///
/// `actualHomeObserved` requires SpringBoard itself to be reported in the
/// foreground after the press: a background-to-foreground transition, or
/// SpringBoard already foreground when the source was not. A known source
/// app's departure is reported separately as corroboration; it is not required
/// because iOS can keep reporting an app foreground after the home screen is
/// up. App departure alone is reported as `source-left-foreground-only` and is
/// not upgraded to a Home or lock-screen claim. This is still not proof that
/// the device is unlocked at Home.
public enum BridgeHomeEvidence {
    public static func assess(_ observation: BridgeHomeObservation) -> BridgeHomeAssessment {
        let springboardForeground = observation.springboardStateAfter == "runningForeground"
        let springboardTransition = observation.springboardStateBefore != "runningForeground" &&
            springboardForeground
        let sourceKnown = observation.sourceBundleIdentifier != nil
        let sourceWasForeground = observation.sourceStateBefore == "runningForeground"
        let sourceLeftForeground = sourceKnown && sourceWasForeground &&
            observation.sourceStateAfter != "runningForeground"
        let hostBackgrounded = observation.hostStateBefore != "background" &&
            observation.hostStateAfter == "background"

        let actualHomeObserved: Bool
        let evidence: String
        if !observation.pressReturned && !springboardForeground && !sourceLeftForeground {
            actualHomeObserved = false
            evidence = "press-not-returned"
        } else if springboardTransition {
            // SpringBoard moving from background to foreground is the actual
            // system-surface observation. The source app's public state can
            // lag for seconds on iOS 27; that lag does not invalidate this.
            actualHomeObserved = true
            evidence = sourceLeftForeground
                ? "springboard-foreground-after-source-departure"
                : "springboard-foreground-transition"
        } else if sourceLeftForeground && springboardForeground {
            actualHomeObserved = true
            evidence = "springboard-foreground-after-source-departure"
        } else if springboardForeground && (!sourceKnown || !sourceWasForeground) {
            // Already on SpringBoard (or the source was already background):
            // the destination is observed even though this press changed
            // nothing.
            actualHomeObserved = true
            evidence = sourceKnown
                ? "springboard-foreground-no-source-departure"
                : "springboard-foreground-unknown-source"
        } else if sourceLeftForeground {
            actualHomeObserved = false
            evidence = "source-left-foreground-only"
        } else if springboardForeground && sourceKnown && sourceWasForeground {
            // Both reports stayed foreground and SpringBoard did not
            // transition. The source may be stale, but nothing actually
            // distinguishes Home from the previous app; do not claim it.
            actualHomeObserved = false
            evidence = "source-still-foreground"
        } else if hostBackgrounded {
            actualHomeObserved = false
            evidence = "host-backgrounded-only"
        } else {
            actualHomeObserved = false
            evidence = "none"
        }

        let status: String
        if actualHomeObserved {
            status = "ok"
        } else if !observation.pressReturned && evidence == "press-not-returned" {
            status = "error"
        } else {
            status = "unverified"
        }
        return BridgeHomeAssessment(
            dispatched: observation.pressReturned,
            sourceKnown: sourceKnown,
            sourceLeftForeground: sourceLeftForeground,
            springboardForeground: springboardForeground,
            hostBackgrounded: hostBackgrounded,
            actualHomeObserved: actualHomeObserved,
            // SpringBoard frontmost after leaving the source is a real system
            // surface observation. It is not a lock-screen/unlock proof; the
            // driver reports that separately as unknown.
            destinationVerified: actualHomeObserved,
            homeEvidence: evidence,
            status: status
        )
    }
}

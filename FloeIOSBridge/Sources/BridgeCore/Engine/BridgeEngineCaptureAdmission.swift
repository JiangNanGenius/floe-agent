import Foundation

/// Pure admission rule shared by the initial and post-capture frame checks.
/// The provider calls it before taking a screenshot, after encoding and again
/// after the gate, so a Stop/lock/generation change cannot emit a late frame
/// that looks authorized.
public enum BridgeEngineCaptureAdmission {
    public static func allows(entryAccepted: Bool,
                              engineRunning: Bool,
                              enginePidMatches: Bool,
                              serviceRunning: Bool,
                              phaseReady: Bool,
                              generationMatches: Bool,
                              lockState: BridgeEngineLockState,
                              heartbeatCurrent: Bool) -> Bool {
        guard entryAccepted,
              engineRunning,
              enginePidMatches,
              serviceRunning,
              phaseReady,
              generationMatches,
              heartbeatCurrent else { return false }
        return lockState.permitsAutomation
    }
}

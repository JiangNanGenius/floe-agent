import Foundation

public enum MacScannerQuitChoice: Equatable { case review, discard, cancel }
public enum MacScannerQuitOutcome: Equatable { case ready, pending, review, cancelled }

/// Decision-only seam. The caller owns closing admissions, presenting the
/// prompt and restoring all services after any rejected termination.
@MainActor
public enum MacScannerQuitDecision {
    /// Button order used by the native alert. Closing the alert is cancel.
    public static func choice(forButtonIndex index: Int?) -> MacScannerQuitChoice {
        switch index { case 0: .review; case 1: .discard; default: .cancel }
    }

    public static func resolve(
        status: @MainActor () async -> MacScannerTerminationStatus,
        choose: @MainActor () async -> MacScannerQuitChoice,
        discard: @MainActor () async -> Bool
    ) async -> MacScannerQuitOutcome {
        switch await status() {
        case .ready: return .ready
        case .pending: return .pending
        case .draft:
            switch await choose() {
            case .review: return .review
            case .cancel: return .cancelled
            case .discard: return await discard() ? .ready : .pending
            }
        }
    }
}

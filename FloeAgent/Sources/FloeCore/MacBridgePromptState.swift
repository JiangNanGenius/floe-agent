/// A presentation interruption never counts as accepting or dismissing the
/// recommendation. Only an explicit user action updates the saved preference.
public struct MacBridgePromptState: Equatable, Sendable {
    public enum Prompt: String, Equatable, Sendable {
        case recommendation
        case verification
    }

    public private(set) var presented: Prompt?

    public init() {}

    public mutating func reconcile(
        platform: LocalBridgePlatform,
        canPresent: Bool,
        recommendationHandled: Bool,
        downloadAvailable: Bool,
        connected: Bool,
        awaitingVerification: Bool,
        connectionPageVisible: Bool
    ) {
        guard platform.supportsMacBridge else { presented = nil; return }
        if presented == .verification && (!awaitingVerification || connectionPageVisible) {
            presented = nil
        }
        if presented == .recommendation && (recommendationHandled || connected) {
            presented = nil
        }
        guard presented == nil, canPresent else { return }
        if awaitingVerification && !connectionPageVisible {
            presented = .verification
        } else if !recommendationHandled && !connected && downloadAvailable && !connectionPageVisible {
            presented = .recommendation
        }
    }

    public mutating func presentationEnded() { presented = nil }
}

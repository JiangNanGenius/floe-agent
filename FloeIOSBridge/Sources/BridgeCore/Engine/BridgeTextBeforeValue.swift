import Foundation

/// Classification of the observable value of a focused text field before an
/// append. UIKit's accessibility value can be the placeholder for an empty
/// field; placeholder equality is not evidence that the field is empty.
public struct BridgeTextBeforeValue: Equatable, Sendable {
    public enum Observation: String, Equatable, Sendable {
        /// The value is explicitly empty; a following append can be verified
        /// against an empty base.
        case emptyVerified
        /// A non-placeholder value was read and can be used as the append base.
        case valueVerified
        /// The raw value equals a non-empty placeholder. It is not a trusted
        /// base; without clear:true the append stays unverified.
        case placeholderAsValueUntrusted
        /// The value could not be read (or the field is secure).
        case inaccessible
    }

    public var observation: Observation
    public var value: String?
    public var trusted: Bool
    public var emptyVerified: Bool

    public init(observation: Observation,
                value: String?,
                trusted: Bool,
                emptyVerified: Bool) {
        self.observation = observation
        self.value = value
        self.trusted = trusted
        self.emptyVerified = emptyVerified
    }
}

public enum BridgeTextBeforeValueClassifier {
    /// Only an explicitly empty string establishes a known-empty base.
    /// Placeholder equality, an unreadable value and a secure field all remain
    /// untrusted. The caller must not synthesise an empty result or retry.
    public static func classify(rawValue: String?,
                                placeholderValue: String?,
                                secure: Bool) -> BridgeTextBeforeValue {
        guard !secure else {
            return BridgeTextBeforeValue(observation: .inaccessible,
                                         value: nil,
                                         trusted: false,
                                         emptyVerified: false)
        }
        guard let rawValue else {
            return BridgeTextBeforeValue(observation: .inaccessible,
                                         value: nil,
                                         trusted: false,
                                         emptyVerified: false)
        }
        if rawValue.isEmpty {
            return BridgeTextBeforeValue(observation: .emptyVerified,
                                         value: "",
                                         trusted: true,
                                         emptyVerified: true)
        }
        if let placeholderValue,
           !placeholderValue.isEmpty,
           rawValue == placeholderValue {
            return BridgeTextBeforeValue(observation: .placeholderAsValueUntrusted,
                                         value: rawValue,
                                         trusted: false,
                                         emptyVerified: false)
        }
        return BridgeTextBeforeValue(observation: .valueVerified,
                                     value: rawValue,
                                     trusted: true,
                                     emptyVerified: false)
    }
}

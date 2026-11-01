import Foundation

/// One text-input node collected from a single live accessibility snapshot.
/// `isEditable` covers text fields, search fields and text views;
/// `isSecure` is tracked separately so every selector can refuse a secure
/// target before any event is synthesized.
public struct BridgeUIEditableField: Equatable, Hashable, Sendable {
    public var identifier: String
    public var label: String
    public var placeholder: String
    public var elementType: String
    public var elementTypeRawValue: Int
    public var isSecure: Bool
    public var isEditable: Bool
    public var frame: BridgeUIRect

    public init(identifier: String,
                label: String,
                placeholder: String,
                elementType: String,
                elementTypeRawValue: Int,
                isSecure: Bool,
                isEditable: Bool,
                frame: BridgeUIRect) {
        self.identifier = identifier
        self.label = label
        self.placeholder = placeholder
        self.elementType = elementType
        self.elementTypeRawValue = elementTypeRawValue
        self.isSecure = isSecure
        self.isEditable = isEditable
        self.frame = frame
    }

    public var isTextInput: Bool { isEditable || isSecure }
}

/// The explicit field selector accepted by `type_text`. Exactly one case may
/// be supplied; a command without a selector is allowed only when the engine
/// can prove one focused non-secure editable field through the XCTest
/// `hasKeyboardFocus` query.
public enum BridgeUITextTarget: Equatable, Sendable {
    case identifier(String)
    case label(String)
    case placeholder(String)
    case point(normalizedX: Double, normalizedY: Double)

    public var strategy: String {
        switch self {
        case .identifier: return "identifier"
        case .label: return "label"
        case .placeholder: return "placeholder"
        case .point: return "point"
        }
    }
}

public struct BridgeUITextTargetError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let matchCount: Int?

    public init(code: String, message: String, matchCount: Int? = nil) {
        self.code = code
        self.message = message
        self.matchCount = matchCount
    }
}

public struct BridgeUITextTargetSelection: Equatable, Sendable {
    public var field: BridgeUIEditableField
    public var matchCount: Int
    public var strategy: String

    public init(field: BridgeUIEditableField, matchCount: Int, strategy: String) {
        self.field = field
        self.matchCount = matchCount
        self.strategy = strategy
    }
}

/// Resolves one explicit selector against a snapshot-derived candidate list.
/// Zero and multiple matches, secure fields, non-editable matches and
/// unusable frames are refusals; nothing is guessed.
public enum BridgeUITextTargetSelector {
    public static func select(
        target: BridgeUITextTarget,
        fields: [BridgeUIEditableField],
        appFrame: BridgeUIRect
    ) -> Result<BridgeUITextTargetSelection, BridgeUITextTargetError> {
        guard !appFrame.isEmpty,
              appFrame.width > 1,
              appFrame.height > 1 else {
            return .failure(BridgeUITextTargetError(
                code: "target_not_reachable",
                message: "The target app frame was not usable; no field was selected."
            ))
        }
        switch target {
        case .identifier(let identifier):
            return selectByAttribute(
                fields: fields,
                appFrame: appFrame,
                strategy: "identifier",
                matches: { $0.identifier == identifier },
                allowNonEditableMatch: true
            )
        case .label(let label):
            return selectByAttribute(
                fields: fields,
                appFrame: appFrame,
                strategy: "label",
                matches: { $0.isTextInput && $0.label == label },
                allowNonEditableMatch: false
            )
        case .placeholder(let placeholder):
            return selectByAttribute(
                fields: fields,
                appFrame: appFrame,
                strategy: "placeholder",
                matches: { $0.isTextInput && $0.placeholder == placeholder },
                allowNonEditableMatch: false
            )
        case .point(let normalizedX, let normalizedY):
            return selectAtPoint(
                x: appFrame.x + normalizedX * appFrame.width,
                y: appFrame.y + normalizedY * appFrame.height,
                fields: fields,
                appFrame: appFrame
            )
        }
    }

    private static func selectByAttribute(
        fields: [BridgeUIEditableField],
        appFrame: BridgeUIRect,
        strategy: String,
        matches: (BridgeUIEditableField) -> Bool,
        allowNonEditableMatch: Bool
    ) -> Result<BridgeUITextTargetSelection, BridgeUITextTargetError> {
        let candidates = fields.filter(matches)
        guard !candidates.isEmpty else {
            return .failure(BridgeUITextTargetError(
                code: "target_missing",
                message: "No element matched the \(strategy) selector; no text was typed.",
                matchCount: 0
            ))
        }
        guard candidates.count == 1 else {
            return .failure(BridgeUITextTargetError(
                code: "ambiguous_target",
                message: "More than one element matched the \(strategy) selector; no text was typed.",
                matchCount: candidates.count
            ))
        }
        let field = candidates[0]
        if field.isSecure {
            return .failure(BridgeUITextTargetError(
                code: "secure_input_refused",
                message: "Secure text fields are not automated; no text was typed.",
                matchCount: 1
            ))
        }
        guard field.isEditable else {
            if allowNonEditableMatch {
                return .failure(BridgeUITextTargetError(
                    code: "target_not_editable",
                    message: "The matched element is not an editable text field; no text was typed.",
                    matchCount: 1
                ))
            }
            return .failure(BridgeUITextTargetError(
                code: "target_missing",
                message: "No editable text field matched the \(strategy) selector; no text was typed.",
                matchCount: 0
            ))
        }
        guard isReachable(field.frame, appFrame: appFrame) else {
            return .failure(BridgeUITextTargetError(
                code: "target_not_reachable",
                message: "The matched field has no usable on-screen frame; no text was typed.",
                matchCount: 1
            ))
        }
        return .success(BridgeUITextTargetSelection(
            field: field,
            matchCount: 1,
            strategy: strategy
        ))
    }

    private static func selectAtPoint(
        x: Double,
        y: Double,
        fields: [BridgeUIEditableField],
        appFrame: BridgeUIRect
    ) -> Result<BridgeUITextTargetSelection, BridgeUITextTargetError> {
        let hits = fields.filter {
            $0.isTextInput && $0.frame.contains(x: x, y: y)
        }
        guard !hits.isEmpty else {
            return .failure(BridgeUITextTargetError(
                code: "target_missing",
                message: "No editable text field contains that point; no text was typed.",
                matchCount: 0
            ))
        }
        if hits.contains(where: \.isSecure) {
            return .failure(BridgeUITextTargetError(
                code: "secure_input_refused",
                message: "The point overlaps a secure text field; no text was typed.",
                matchCount: hits.count
            ))
        }
        let editable = hits.filter(\.isEditable)
        guard !editable.isEmpty else {
            return .failure(BridgeUITextTargetError(
                code: "target_not_editable",
                message: "The point does not land on an editable text field; no text was typed.",
                matchCount: hits.count
            ))
        }
        let sorted = editable.sorted { lhs, rhs in
            if abs(lhs.frame.area - rhs.frame.area) > 0.5 {
                return lhs.frame.area < rhs.frame.area
            }
            if typePriority(lhs) != typePriority(rhs) {
                return typePriority(lhs) < typePriority(rhs)
            }
            return lhs.identifier < rhs.identifier
        }
        let chosen = sorted[0]
        // Nested matches (a text field and its internal text view) describe the
        // same field. Two distinct overlapping fields at one point are
        // ambiguous and must not be guessed.
        for other in sorted.dropFirst() where !sameFieldArea(chosen.frame, other.frame) {
            return .failure(BridgeUITextTargetError(
                code: "ambiguous_target",
                message: "More than one editable field overlaps that point; no text was typed.",
                matchCount: sorted.count
            ))
        }
        guard isReachable(chosen.frame, appFrame: appFrame) else {
            return .failure(BridgeUITextTargetError(
                code: "target_not_reachable",
                message: "The field at that point has no usable on-screen frame; no text was typed.",
                matchCount: 1
            ))
        }
        return .success(BridgeUITextTargetSelection(
            field: chosen,
            matchCount: 1,
            strategy: "point"
        ))
    }

    private static func typePriority(_ field: BridgeUIEditableField) -> Int {
        switch field.elementType {
        case "TextField", "SearchField": return 0
        case "TextView": return 1
        default: return 2
        }
    }

    private static func sameFieldArea(_ lhs: BridgeUIRect,
                                      _ rhs: BridgeUIRect) -> Bool {
        lhs.approximatelyEquals(rhs) || lhs.contains(rhs) || rhs.contains(lhs)
    }

    private static func isReachable(_ frame: BridgeUIRect,
                                    appFrame: BridgeUIRect) -> Bool {
        guard !frame.isEmpty else { return false }
        return appFrame.contains(x: frame.midX, y: frame.midY)
    }
}

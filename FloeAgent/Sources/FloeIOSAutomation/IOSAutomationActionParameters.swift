// FloeIOSAutomation — concrete argument contract for the four App tools.
//
// These parameter names/types/requirements mirror the released Bridge v1
// schema. The primary-owned `ios.bridge.observe` and `ios.bridge.control`
// tools can use this as the source of truth instead of trusting downloaded
// Skill metadata or a remote schema tag.

import Foundation

public struct IOSAutomationParameter: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case string
        case number
        case integer
        case boolean
        case object
        case array
    }

    public let name: String
    public let kind: Kind
    public let required: Bool

    public init(name: String, kind: Kind, required: Bool) {
        self.name = name
        self.kind = kind
        self.required = required
    }
}

public extension IOSAutomationAction {
    /// Source-compatible arguments for this method. Administrative methods are
    /// absent from the model-facing tools and intentionally have no public
    /// argument contract here.
    var parameters: [IOSAutomationParameter] {
        switch self {
        case .deviceInfo, .isLocked, .home, .lock, .unlock:
            return []
        case .pageSource:
            return [
                .init(name: "bundle_id", kind: .string, required: false),
                .init(name: "filter", kind: .object, required: false),
                .init(name: "max_depth", kind: .number, required: false),
                .init(name: "max_elements", kind: .number, required: false),
                .init(name: "max_children", kind: .number, required: false),
                .init(name: "enhanced", kind: .boolean, required: false),
                .init(name: "visible_only", kind: .boolean, required: false),
            ]
        case .screenText:
            return [
                .init(name: "element_id", kind: .string, required: false),
                .init(name: "match", kind: .string, required: false),
                .init(name: "scale", kind: .number, required: false),
            ]
        case .screenshot:
            return [
                .init(name: "scale", kind: .number, required: false),
                .init(name: "bundle_id", kind: .string, required: false),
                .init(name: "format", kind: .string, required: false),
                .init(name: "quality", kind: .number, required: false),
            ]
        case .findElement:
            return [
                .init(name: "element_id", kind: .string, required: true),
                .init(name: "match", kind: .string, required: false),
                .init(name: "element_type", kind: .string, required: false),
                .init(name: "bundle_id", kind: .string, required: false),
            ]
        case .listApps:
            return [
                .init(name: "text", kind: .string, required: false),
                .init(name: "element_type", kind: .string, required: false),
            ]
        case .resolveApp:
            return [
                .init(name: "text", kind: .string, required: true),
                .init(name: "country", kind: .string, required: false),
                .init(name: "distance", kind: .number, required: false),
            ]
        case .wait:
            return [.init(name: "duration", kind: .number, required: false)]
        case .tap:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "ref", kind: .string, required: false),
                .init(name: "x", kind: .number, required: false),
                .init(name: "y", kind: .number, required: false),
                .init(name: "fast", kind: .boolean, required: false),
            ]
        case .doubleTap:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "ref", kind: .string, required: false),
                .init(name: "x", kind: .number, required: false),
                .init(name: "y", kind: .number, required: false),
            ]
        case .longPress:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "ref", kind: .string, required: false),
                .init(name: "x", kind: .number, required: false),
                .init(name: "y", kind: .number, required: false),
                .init(name: "duration", kind: .number, required: false),
            ]
        case .swipe:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "x", kind: .number, required: false),
                .init(name: "y", kind: .number, required: false),
                .init(name: "direction", kind: .string, required: false),
                .init(name: "distance", kind: .number, required: false),
                .init(name: "velocity", kind: .string, required: false),
                .init(name: "fast", kind: .boolean, required: false),
            ]
        case .page:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "direction", kind: .string, required: false),
                .init(name: "distance", kind: .number, required: false),
            ]
        case .collect:
            return [
                .init(name: "pages", kind: .integer, required: false),
                .init(name: "direction", kind: .string, required: false),
                .init(name: "min_length", kind: .integer, required: false),
                .init(name: "fresh", kind: .boolean, required: false),
                .init(name: "source", kind: .string, required: false),
            ]
        case .scrollToElement:
            return [
                .init(name: "element_id", kind: .string, required: true),
                .init(name: "match", kind: .string, required: false),
                .init(name: "element_type", kind: .string, required: false),
                .init(name: "direction", kind: .string, required: false),
                .init(name: "distance", kind: .number, required: false),
                .init(name: "bundle_id", kind: .string, required: false),
            ]
        case .scroll:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "direction", kind: .string, required: false),
            ]
        case .type:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "text", kind: .string, required: true),
                .init(name: "clear", kind: .boolean, required: false),
                .init(name: "submit", kind: .boolean, required: false),
                .init(name: "x", kind: .number, required: false),
                .init(name: "y", kind: .number, required: false),
                .init(name: "fast", kind: .boolean, required: false),
                .init(name: "via", kind: .string, required: false),
            ]
        case .clearText:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
            ]
        case .openURL:
            return [.init(name: "url", kind: .string, required: true)]
        case .launchApp, .activateApp, .terminateApp:
            return [.init(name: "bundle_id", kind: .string, required: true)]
        case .tapElement:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "element_id", kind: .string, required: true),
                .init(name: "match", kind: .string, required: false),
                .init(name: "element_type", kind: .string, required: false),
            ]
        case .findAndTap:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "element_id", kind: .string, required: true),
                .init(name: "match", kind: .string, required: false),
                .init(name: "element_type", kind: .string, required: false),
                .init(name: "bundle_id", kind: .string, required: false),
                .init(name: "fast", kind: .boolean, required: false),
            ]
        case .drag:
            return [
                .init(name: "settle", kind: .boolean, required: false),
                .init(name: "settle_timeout", kind: .number, required: false),
                .init(name: "points", kind: .array, required: false),
                .init(name: "from_ref", kind: .string, required: false),
                .init(name: "to_ref", kind: .string, required: false),
                .init(name: "from_x", kind: .number, required: false),
                .init(name: "from_y", kind: .number, required: false),
                .init(name: "to_x", kind: .number, required: false),
                .init(name: "to_y", kind: .number, required: false),
                .init(name: "duration", kind: .number, required: false),
            ]
        case .config, .streamTicket, .logs, .reset:
            return []
        }
    }
}

public extension IOSAutomationCatalog {
    static var observeParameterContract: [String: [IOSAutomationParameter]] {
        Dictionary(uniqueKeysWithValues: observeActions.map { ($0.wireMethod, $0.parameters) })
    }

    static var controlParameterContract: [String: [IOSAutomationParameter]] {
        Dictionary(uniqueKeysWithValues: controlActions.map { ($0.wireMethod, $0.parameters) })
    }

    static func requiredParameterNames(for action: IOSAutomationAction) -> [String] {
        action.parameters.filter(\.required).map(\.name)
    }
}

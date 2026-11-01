// FloeIOSAutomation — native effect allowlist.
//
// Capability and side effects come from this trusted native catalog, never
// from a downloaded Bridge schema or Skill read/control tag. In particular,
// `collect` and `scroll_to_element` are classified as mutating because both
// page/scroll the live UI even though the released schema tags them read.

import Foundation

public enum IOSAutomationEffect: String, Sendable, Codable, Equatable {
    case readOnly
    case mutating

    public var isAllowedInPlanMode: Bool { self == .readOnly }
}

public enum IOSAutomationAction: String, CaseIterable, Sendable, Codable, Equatable {
    case config
    case streamTicket = "stream_ticket"
    case deviceInfo = "device_info"
    case pageSource = "page_source"
    case screenText = "screen_text"
    case logs
    case reset
    case screenshot
    case tap
    case doubleTap = "double_tap"
    case longPress = "long_press"
    case swipe
    case page
    case collect
    case scrollToElement = "scroll_to_element"
    case scroll
    case type
    case clearText = "clear_text"
    case home
    case lock
    case unlock
    case isLocked = "is_locked"
    case listApps = "list_apps"
    case resolveApp = "resolve_app"
    case openURL = "open_url"
    case launchApp = "launch_app"
    case activateApp = "activate_app"
    case terminateApp = "terminate_app"
    case findElement = "find_element"
    case tapElement = "tap_element"
    case findAndTap = "find_and_tap"
    case drag
    case wait

    public var wireMethod: String { rawValue }

    public var effect: IOSAutomationEffect {
        switch self {
        // Observation and text reading never change app content.
        case .deviceInfo, .pageSource, .screenText, .screenshot, .isLocked,
             .listApps, .resolveApp, .findElement, .wait:
            return .readOnly
        // Service reads are not model-exposed, but remain non-mutating.
        case .config, .logs, .streamTicket:
            return .readOnly
        // Everything below changes app/system state or scrolls the live UI.
        case .reset, .tap, .doubleTap, .longPress, .swipe, .page, .collect,
             .scrollToElement, .scroll, .type, .clearText, .home, .lock, .unlock,
             .openURL, .launchApp, .activateApp, .terminateApp, .tapElement,
             .findAndTap, .drag:
            return .mutating
        }
    }

    public var requiresInputLease: Bool { effect == .mutating }

    /// Administrative/service methods are never model-callable through this
    /// module. Connection status uses an internal, read-only config call.
    public var isModelExposed: Bool {
        switch self {
        case .config, .streamTicket, .logs, .reset:
            return false
        default:
            return true
        }
    }

    /// Generic coordinate/input control must first verify the live foreground
    /// app. App-switch and URL actions carry their target explicitly instead.
    public var requiresForegroundVerification: Bool {
        switch self {
        case .tap, .doubleTap, .longPress, .swipe, .page, .collect,
             .scrollToElement, .scroll, .type, .clearText, .tapElement,
             .findAndTap, .drag, .home, .lock, .unlock:
            return true
        default:
            return false
        }
    }

    /// Methods whose target app/URL is carried in the arguments.
    public var carriesExplicitControlTarget: Bool {
        switch self {
        case .openURL, .launchApp, .activateApp, .terminateApp:
            return true
        default:
            return false
        }
    }

    public var isAdministrative: Bool {
        switch self {
        case .config, .streamTicket, .logs:
            return true
        default:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .config: return "Read Bridge configuration (internal status only)."
        case .streamTicket: return "Mint a short-lived media/log ticket (internal only)."
        case .deviceInfo: return "Read device dimensions, scale and Bridge capabilities."
        case .pageSource: return "Read the accessibility hierarchy as bounded text."
        case .screenText: return "OCR the screen into text boxes for coordinate taps."
        case .logs: return "Read redacted Bridge log lines (internal only)."
        case .reset: return "Clear cached element references and recover the automation channel (internal only)."
        case .screenshot: return "Capture a bounded screenshot as base64 JPEG or PNG."
        case .tap: return "Tap a stable ref or an x/y point."
        case .doubleTap: return "Double-tap a stable ref or an x/y point."
        case .longPress: return "Long-press a stable ref or an x/y point."
        case .swipe: return "Perform a low-level swipe gesture."
        case .page: return "Scroll by one screenful without momentum."
        case .collect: return "Read a long list by paging; this scrolls the live UI and is mutating."
        case .scrollToElement: return "Scroll until an element is visible; this scrolls the live UI and is mutating."
        case .scroll: return "Deprecated coarse full-screen scroll; use swipe or page."
        case .type: return "Type bounded text into the focused field."
        case .clearText: return "Empty the focused text field."
        case .home: return "Press Home and verify SpringBoard is frontmost."
        case .lock: return "Lock the screen."
        case .unlock: return "Wake the screen without entering a passcode."
        case .isLocked: return "Check whether the screen is locked."
        case .listApps: return "List installed apps or the opened-history fallback."
        case .resolveApp: return "Resolve an app name or keyword to a bundle id."
        case .openURL: return "Open an http(s) URL or third-party app deep link."
        case .launchApp: return "Open an installed app by bundle id."
        case .activateApp: return "Bring an installed app to the foreground."
        case .terminateApp: return "Terminate a running app."
        case .findElement: return "Find an element by label/identifier and return a stable ref."
        case .tapElement: return "Find an element and tap it in one call."
        case .findAndTap: return "Locate an element and tap it with a native fallback."
        case .drag: return "Perform one uninterrupted single-finger drag."
        case .wait: return "Pause for a bounded duration."
        }
    }
}

public struct IOSAutomationActionDescriptor: Sendable, Equatable {
    public let action: IOSAutomationAction
    public let effect: IOSAutomationEffect
    public let isModelExposed: Bool
    public let requiresInputLease: Bool
    public let requiresForegroundVerification: Bool
    public let isAdministrative: Bool
    public let summary: String
}

public enum IOSAutomationCatalog {
    public static func descriptor(for action: IOSAutomationAction) -> IOSAutomationActionDescriptor {
        IOSAutomationActionDescriptor(
            action: action,
            effect: action.effect,
            isModelExposed: action.isModelExposed,
            requiresInputLease: action.requiresInputLease,
            requiresForegroundVerification: action.requiresForegroundVerification,
            isAdministrative: action.isAdministrative,
            summary: action.summary
        )
    }

    public static var allDescriptors: [IOSAutomationActionDescriptor] {
        IOSAutomationAction.allCases.map(descriptor(for:))
    }

    public static var modelExposedDescriptors: [IOSAutomationActionDescriptor] {
        allDescriptors.filter(\.isModelExposed)
    }
}

/// Primary-owned App tool surfaces. These are registration names only; the
/// module does not create a second tool catalog or a second permission system.
public enum IOSAutomationToolSurface: String, Sendable, CaseIterable, Equatable {
    case status = "ios.bridge.status"
    case pair = "ios.bridge.pair"
    case observe = "ios.bridge.observe"
    case control = "ios.bridge.control"
}

public extension IOSAutomationAction {
    /// The single model-facing tool surface for this action, or nil when the
    /// method is internal (config/logs/stream_ticket/reset).
    var toolSurface: IOSAutomationToolSurface? {
        guard isModelExposed else { return nil }
        return effect == .readOnly ? .observe : .control
    }
}

public extension IOSAutomationCatalog {
    static var observeActions: [IOSAutomationAction] {
        IOSAutomationAction.allCases.filter { $0.toolSurface == .observe }
    }

    static var controlActions: [IOSAutomationAction] {
        IOSAutomationAction.allCases.filter { $0.toolSurface == .control }
    }

    static var observeActionNames: [String] {
        observeActions.map(\.wireMethod)
    }

    static var controlActionNames: [String] {
        controlActions.map(\.wireMethod)
    }
}

import Foundation

/// Pure geometry/root policy for the small Settings canary. XCTest supplies
/// only observed facts; this policy decides whether a unique General/通用 row
/// can be tapped, must be scrolled, or must be refused.
///
/// `isHittable` is not used as proof of visibility: the Settings search field
/// can float over the bottom of the window while an element still reports
/// itself hittable. The target therefore has to be fully inside an inset
/// window interior and must not intersect any observed overlay.
public enum BridgeSettingsCanaryPolicy {
    public static let allowedLabels = ["General", "通用"]
    public static let destinationLabels = ["About", "关于本机", "Software Update", "软件更新"]
    public static let maximumScrollAttempts = 3
    public static let minimumWindowWidth = 120.0
    public static let minimumWindowHeight = 240.0
    public static let minimumTargetHeight = 20.0
    public static let sideMargin = 16.0
    public static let topMargin = 44.0
    public static let minimumBottomReserve = 72.0
    public static let bottomReserveFraction = 0.12
}

public struct BridgeScreenRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ other: BridgeScreenRect) -> Bool {
        guard !other.isEmpty else { return false }
        return other.minX >= minX && other.maxX <= maxX &&
            other.minY >= minY && other.maxY <= maxY
    }

    public func intersects(_ other: BridgeScreenRect) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return other.minX < maxX && other.maxX > minX &&
            other.minY < maxY && other.maxY > minY
    }

    public func contains(pointX: Double, pointY: Double) -> Bool {
        pointX >= minX && pointX <= maxX && pointY >= minY && pointY <= maxY
    }
}

public struct BridgeSettingsRootFacts: Equatable, Sendable {
    public var isForeground: Bool
    public var hasRootNavigationTitle: Bool
    public var hasSettingsSearchField: Bool
    public var hasBackNavigationButton: Bool
    public var destinationVisible: Bool

    public init(
        isForeground: Bool,
        hasRootNavigationTitle: Bool,
        hasSettingsSearchField: Bool,
        hasBackNavigationButton: Bool,
        destinationVisible: Bool
    ) {
        self.isForeground = isForeground
        self.hasRootNavigationTitle = hasRootNavigationTitle
        self.hasSettingsSearchField = hasSettingsSearchField
        self.hasBackNavigationButton = hasBackNavigationButton
        self.destinationVisible = destinationVisible
    }
}

public struct BridgeSettingsCandidate: Equatable, Sendable {
    public var label: String
    public var frame: BridgeScreenRect
    public var strategy: String

    public init(label: String, frame: BridgeScreenRect, strategy: String) {
        self.label = label
        self.frame = frame
        self.strategy = strategy
    }
}

public enum BridgeSettingsScrollDirection: String, Equatable, Sendable {
    /// Content moves up, revealing rows that were below the interior.
    case up
    /// Content moves down, revealing rows that were above the interior.
    case down
}

public enum BridgeSettingsTapRefusal: String, Equatable, Sendable {
    case notForeground = "not-foreground"
    case rootUnconfirmed = "root-unconfirmed"
    case ambiguousTarget = "ambiguous-target"
    case missingTarget = "missing-target"
    case invalidWindow = "invalid-window"
    case targetNotReachable = "target-not-reachable"
}

public enum BridgeSettingsTapDecision: Equatable, Sendable {
    case tap(candidateIndex: Int)
    case scroll(direction: BridgeSettingsScrollDirection, attempt: Int)
    case alreadyAtDestination
    case refuse(BridgeSettingsTapRefusal)
}

public enum BridgeSettingsTapPolicy {
    /// The first two facts are strong root markers. A foreground Settings
    /// window with no back button is the bounded fallback; a pushed page
    /// exposes a back button and is refused instead of guessing.
    public static func rootEvidence(_ facts: BridgeSettingsRootFacts) -> String? {
        if facts.hasRootNavigationTitle { return "navigation-title" }
        if facts.hasBackNavigationButton { return nil }
        if facts.hasSettingsSearchField { return "search-field-no-back" }
        return "no-back-button"
    }

    public static func safeInterior(window: BridgeScreenRect) -> BridgeScreenRect {
        guard !window.isEmpty else { return BridgeScreenRect(x: 0, y: 0, width: 0, height: 0) }
        let side = min(BridgeSettingsCanaryPolicy.sideMargin, window.width / 4)
        let top = min(BridgeSettingsCanaryPolicy.topMargin, window.height / 4)
        let bottom = min(
            max(BridgeSettingsCanaryPolicy.minimumBottomReserve,
                window.height * BridgeSettingsCanaryPolicy.bottomReserveFraction),
            window.height / 2
        )
        let width = max(0, window.width - side * 2)
        let height = max(0, window.height - top - bottom)
        return BridgeScreenRect(
            x: window.minX + side,
            y: window.minY + top,
            width: width,
            height: height
        )
    }

    public static func evaluate(
        facts: BridgeSettingsRootFacts,
        candidates: [BridgeSettingsCandidate],
        window: BridgeScreenRect,
        overlays: [BridgeScreenRect],
        scrollAttemptsUsed: Int
    ) -> BridgeSettingsTapDecision {
        guard facts.isForeground else { return .refuse(.notForeground) }
        if facts.destinationVisible { return .alreadyAtDestination }
        guard window.width >= BridgeSettingsCanaryPolicy.minimumWindowWidth,
              window.height >= BridgeSettingsCanaryPolicy.minimumWindowHeight else {
            return .refuse(.invalidWindow)
        }
        guard rootEvidence(facts) != nil else { return .refuse(.rootUnconfirmed) }
        guard !candidates.isEmpty else { return .refuse(.missingTarget) }
        guard candidates.count == 1 else { return .refuse(.ambiguousTarget) }
        let target = candidates[0]
        guard target.frame.width > 0,
              target.frame.height >= BridgeSettingsCanaryPolicy.minimumTargetHeight else {
            return .refuse(.missingTarget)
        }

        let interior = safeInterior(window: window)
        let contained = interior.contains(target.frame)
        let obscured = overlays.contains {
            $0.intersects(target.frame) || $0.contains(pointX: target.frame.centerX, pointY: target.frame.centerY)
        }
        if contained && !obscured {
            return .tap(candidateIndex: 0)
        }
        guard scrollAttemptsUsed < BridgeSettingsCanaryPolicy.maximumScrollAttempts else {
            return .refuse(.targetNotReachable)
        }

        let direction: BridgeSettingsScrollDirection
        if target.frame.maxY > interior.maxY {
            direction = .up
        } else if target.frame.minY < interior.minY {
            direction = .down
        } else {
            // Inside the geometric interior but still covered by an overlay
            // (typically the bottom search field): move the row upward.
            direction = .up
        }
        return .scroll(direction: direction, attempt: scrollAttemptsUsed + 1)
    }
}

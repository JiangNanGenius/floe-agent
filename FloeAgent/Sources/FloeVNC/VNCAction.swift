// FloeVNC — Visual automation actions and budget (iOS-only target).
// See blazing-aurora-darwin.md §5.11. RoyalVNC integration lands in M3;
// M1 ships validated action types and the hard action/duration budget.

import Foundation
import FloeCore

/// One GUI action the agent may perform over VNC.
public enum VNCAction: Sendable, Codable, Hashable {
    case click(point: ScreenPoint, button: MouseButton)
    case doubleClick(point: ScreenPoint, button: MouseButton)
    case drag(from: ScreenPoint, to: ScreenPoint, duration: TimeInterval)
    case scroll(point: ScreenPoint, deltaX: Int, deltaY: Int)
    case keyPress(key: KeyCode, modifiers: Set<KeyModifier>)
    case typeText(String)
    case wait(seconds: TimeInterval)
    case finish(summary: String)

    public static let typeTextMaxBytes = 4096
    public static let waitMaxSeconds: TimeInterval = 30

    /// Framebuffer coordinate.
    public struct ScreenPoint: Sendable, Codable, Hashable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public enum MouseButton: String, Sendable, Codable, Hashable {
        case left, middle, right
    }

    /// Cross-platform key identifier (USB HID usage ID).
    public struct KeyCode: Sendable, Codable, Hashable {
        public var hidUsage: UInt32

        public init(hidUsage: UInt32) {
            self.hidUsage = hidUsage
        }
    }

    public enum KeyModifier: String, Sendable, Codable, Hashable {
        case shift, control, option, command
    }

    /// Validates parameters before dispatch to the framebuffer.
    public func validate() throws {
        switch self {
        case .click(let point, _), .doubleClick(let point, _):
            try Self.validate(point)
        case .drag(let from, let to, let duration):
            try Self.validate(from)
            try Self.validate(to)
            guard duration.isFinite, (0...10).contains(duration) else {
                throw FloeError.validationFailed("Drag duration must be 0-10s")
            }
        case .scroll(let point, let deltaX, let deltaY):
            try Self.validate(point)
            guard abs(deltaX) <= 1000, abs(deltaY) <= 1000 else {
                throw FloeError.validationFailed("Scroll deltas must be within ±1000")
            }
        case .keyPress(let key, _):
            guard key.hidUsage <= 0xFF else {
                throw FloeError.validationFailed("HID usage out of range")
            }
        case .typeText(let text):
            guard text.utf8.count <= Self.typeTextMaxBytes else {
                throw FloeError.validationFailed("typeText exceeds \(Self.typeTextMaxBytes) bytes")
            }
        case .wait(let seconds):
            guard seconds.isFinite, (0...Self.waitMaxSeconds).contains(seconds) else {
                throw FloeError.validationFailed("wait must be 0-\(Int(Self.waitMaxSeconds))s")
            }
        case .finish(let summary):
            guard summary.utf8.count <= 4096 else {
                throw FloeError.validationFailed("finish summary exceeds 4 KiB")
            }
        }
    }

    private static func validate(_ point: ScreenPoint) throws {
        guard point.x >= 0, point.y >= 0, point.x <= 16384, point.y <= 16384 else {
            throw FloeError.validationFailed("Screen point out of range")
        }
    }
}

/// Hard per-session budget for visual automation. The runtime refuses
/// actions beyond the budget; the user must re-authorize.
public struct VisualActionBudget: Sendable, Codable, Hashable {
    public var maxActions: Int
    public var maxDuration: TimeInterval

    public static let `default` = VisualActionBudget(maxActions: 50, maxDuration: 600)

    public init(maxActions: Int = 50, maxDuration: TimeInterval = 600) {
        self.maxActions = maxActions
        self.maxDuration = maxDuration
    }

    /// Tracks consumption within one VNC session.
    public struct Tracker: Sendable {
        public private(set) var actionsUsed: Int = 0
        public let startedAt: Date
        public let budget: VisualActionBudget

        public init(budget: VisualActionBudget = .default, startedAt: Date = Date()) {
            self.budget = budget
            self.startedAt = startedAt
        }

        public var isExhausted: Bool {
            actionsUsed >= budget.maxActions
                || Date().timeIntervalSince(startedAt) >= budget.maxDuration
        }

        /// Records one action; throws when the budget is exhausted.
        public mutating func consume(_ action: VNCAction) throws {
            guard !isExhausted else {
                throw FloeError.validationFailed("Visual action budget exhausted")
            }
            if case .finish = action {
                // finish terminates the session without consuming budget.
                return
            }
            actionsUsed += 1
        }
    }
}

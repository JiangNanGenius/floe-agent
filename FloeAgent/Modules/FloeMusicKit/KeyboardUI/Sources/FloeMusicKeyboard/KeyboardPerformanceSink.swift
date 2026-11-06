import Foundation

/// Host-injected destination for performance events.
///
/// The sink is bound to the controller, not to any single owner: events carry
/// their owner token, and the controller guarantees it never emits an event
/// for a replacement owner before the previous owner's notes and controllers
/// were released. The host implements this protocol (typically routing into
/// its instrument track / mixer / recorder on the main actor, then dispatching
/// to its audio engine on its own queue).
public protocol KeyboardPerformanceSink: AnyObject, Sendable {
    /// Called on the main actor for every performance event. This must stay
    /// cheap and must not block on audio work.
    @MainActor func receive(_ event: KeyboardPerformanceEvent)
}

/// Convenience sink wrapping a closure. Useful for lightweight hosts, previews
/// and qualification fixtures.
@MainActor
public final class ClosureKeyboardSink: KeyboardPerformanceSink {
    private let handler: @Sendable @MainActor (KeyboardPerformanceEvent) -> Void

    public init(_ handler: @escaping @Sendable @MainActor (KeyboardPerformanceEvent) -> Void) {
        self.handler = handler
    }

    public func receive(_ event: KeyboardPerformanceEvent) {
        handler(event)
    }
}

/// Silent recording sink used by SwiftUI previews, tests and host-side
/// diagnostics. It produces no sound and never leaves the process.
@MainActor
public final class RecordingKeyboardSink: KeyboardPerformanceSink {
    public private(set) var events: [KeyboardPerformanceEvent] = []

    public init() {}

    public func receive(_ event: KeyboardPerformanceEvent) {
        events.append(event)
    }

    public func reset() {
        events.removeAll()
    }
}

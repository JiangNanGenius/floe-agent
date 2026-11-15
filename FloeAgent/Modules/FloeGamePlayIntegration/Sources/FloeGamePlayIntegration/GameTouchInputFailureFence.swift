// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameTouch

public enum GameTouchInputDeliveryError: Error, Equatable, Sendable {
    case previousFailure, invalidated, sinkUnavailable
}

/// One captured run/connection. After its first failed delivery, compensation
/// fails promptly rather than repeatedly waiting on the same broken transport.
/// The higher-level owner stops/resets that runtime; this object never rearms
/// itself or resolves a different current player/display.
@MainActor public final class GameTouchInputFailureFence: GameTouchInputSink {
    private weak var sink: (any GameTouchInputSink)?
    public private(set) var failed = false
    public private(set) var invalidated = false

    public init(sink: any GameTouchInputSink) { self.sink = sink }

    public func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        guard !invalidated else { throw GameTouchInputDeliveryError.invalidated }
        guard !failed else { throw GameTouchInputDeliveryError.previousFailure }
        guard let sink else { failed = true; throw GameTouchInputDeliveryError.sinkUnavailable }
        do { try await sink.set(binding, pressed: pressed) }
        catch { failed = true; throw error }
        guard !invalidated else { throw GameTouchInputDeliveryError.invalidated }
    }

    public func invalidate() { invalidated = true; sink = nil }
}

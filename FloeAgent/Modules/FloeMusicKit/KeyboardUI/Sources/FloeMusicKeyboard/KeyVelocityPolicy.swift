import CoreGraphics
import Foundation

/// How the controller turns a touch into a MIDI velocity.
///
/// Touch surfaces report a position, not a true key velocity. The default
/// policy derives velocity from the vertical position inside the key rect
/// (upstream `Keyboard` passes a normalized point): striking toward the front
/// edge of the key (y → 1) maps to `maxVelocity`, the back edge (y → 0) maps
/// to `minVelocity`. Hosts that model their own velocity response can inject
/// `.fixed` or post-process `.noteOn` events.
public enum KeyVelocityPolicy: Hashable, Sendable {
    case fixed(UInt8)
    case touchVertical(minVelocity: UInt8 = 48, maxVelocity: UInt8 = 127)

    func velocity(for normalizedPoint: CGPoint) -> UInt8 {
        switch self {
        case let .fixed(velocity):
            return min(127, max(1, velocity))
        case let .touchVertical(minVelocity, maxVelocity):
            let position = Float(normalizedPoint.y)
            let t = position.isFinite ? min(1, max(0, position)) : 0.5
            let low = min(127, max(1, min(minVelocity, maxVelocity)))
            let high = min(127, max(1, max(minVelocity, maxVelocity)))
            let span = Float(high) - Float(low)
            return UInt8((Float(low) + span * t).rounded())
        }
    }
}

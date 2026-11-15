// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameWebKit

public enum GamePhysicalKeyboardSinkError: Error, Sendable, Equatable {
    case staleSession
    case physicalBindingRequired
}

/// Adapts the existing touch service to a captured guest keyboard transport.
/// The transport sends separate down/up phases to the same owned display.
/// It must never resolve "the current display" again when releasing old keys.
@MainActor public final class GamePhysicalKeyboardSink: GameTouchInputSink {
    public typealias Transport = @MainActor @Sendable (GameKeyboardKey, Bool) throws -> Void
    private let transport: Transport
    private let isCurrent: @MainActor @Sendable () -> Bool
    private var bindings: [GameTouchBinding: Set<GameKeyboardKey>] = [:]
    private var delivered: Set<GameKeyboardKey> = []
    private var invalidated = false

    public init(isCurrent: @escaping @MainActor @Sendable () -> Bool,
                transport: @escaping Transport) {
        self.isCurrent = isCurrent
        self.transport = transport
    }

    public func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        guard !invalidated, isCurrent() else {
            releaseCapturedKeys()
            invalidated = true
            throw GamePhysicalKeyboardSinkError.staleSession
        }
        let keys: Set<GameKeyboardKey>
        switch binding {
        case .key(let key): keys = [key]
        case .chord(let chord): keys = Set(chord.keys)
        case .action: throw GamePhysicalKeyboardSinkError.physicalBindingRequired
        }
        if pressed { bindings[binding] = keys } else { bindings.removeValue(forKey: binding) }
        let desired = Set(bindings.values.flatMap { $0 })
        do {
            for key in delivered.subtracting(desired).sorted(by: Self.releaseOrder) {
                try transport(key, false)
                delivered.remove(key)
            }
            for key in desired.subtracting(delivered).sorted(by: Self.pressOrder) {
                // A failed transport may already have written its packet.
                // Include the attempted key in compensation either way.
                delivered.insert(key)
                try transport(key, true)
            }
        } catch {
            releaseCapturedKeys()
            invalidated = true
            throw error
        }
    }

    /// Call before detaching/closing the captured display. Late UI events fail.
    public func invalidate() {
        invalidated = true
        releaseCapturedKeys()
    }

    private func releaseCapturedKeys() {
        for key in delivered.sorted(by: Self.releaseOrder) { try? transport(key, false) }
        delivered.removeAll()
        bindings.removeAll()
    }

    private static func pressOrder(_ lhs: GameKeyboardKey, _ rhs: GameKeyboardKey) -> Bool {
        lhs.modifierOrder == rhs.modifierOrder
            ? lhs.rawValue < rhs.rawValue : lhs.modifierOrder < rhs.modifierOrder
    }
    private static func releaseOrder(_ lhs: GameKeyboardKey, _ rhs: GameKeyboardKey) -> Bool {
        if lhs.isModifier != rhs.isModifier { return !lhs.isModifier }
        return lhs.rawValue < rhs.rawValue
    }
}

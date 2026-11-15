// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameTouch
import FloeGameWebKit

/// Capture one actual guest job after start(). Pair with GameTouchInputService
/// for key reference counts, custom keyboard chords, tap and toggle modes.
/// Background/covered views detach that service before releasing the display.
@MainActor
public final class RGSSGuestTouchInputSink: GameTouchInputSink {
    private weak var play: RGSSGuestPlaySession?
    private let jobID: UUID
    private let ownerToken: UUID
    private let input: RGSSGuestPhysicalInputSession
    private var invalidated = false

    public init(play: RGSSGuestPlaySession) throws {
        guard let session = play.session, play.phase == .running else {
            throw RGSSGuestRunError.sessionNotActive
        }
        self.play = play
        self.jobID = session.jobID
        self.ownerToken = session.ownerToken
        self.input = try play.touchInputSession()
    }

    public func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        guard !invalidated, let play,
              play.session?.jobID == jobID,
              play.session?.ownerToken == ownerToken else {
            throw RGSSGuestRunError.sessionNotActive
        }
        let keys: [GameKeyboardKey]
        switch binding {
        case .key(let key): keys = [key]
        case .chord(let chord): keys = chord.keys
        case .action:
            throw RGSSGuestRunError.inputUnavailable(
                "Choose a keyboard key or chord for this control, or restore the engine's default keyboard layout.")
        }
        let ordered = pressed ? RGSSGuestButtonBinding.ordered(keys)
            : Array(RGSSGuestButtonBinding.ordered(keys).reversed())
        var delivered: [GameKeyboardKey] = []
        do {
            for key in ordered {
                try await input.setPhysicalKey(key, pressed: pressed)
                delivered.append(key)
                guard !invalidated, play.session?.jobID == jobID,
                      play.session?.ownerToken == ownerToken else {
                    throw RGSSGuestRunError.sessionNotActive
                }
            }
        } catch {
            // Compensate against the captured input actor even if play now
            // owns a different job. Never resolve its newer current input.
            if pressed {
                for key in delivered.reversed() {
                    try? await input.setPhysicalKey(key, pressed: false)
                }
            }
            throw error
        }
    }

    /// Detach the Touch service first so its held inputs can drain.
    public func invalidate() { invalidated = true; play = nil }
}

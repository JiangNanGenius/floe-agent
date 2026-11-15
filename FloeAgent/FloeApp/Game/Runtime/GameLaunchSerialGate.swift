// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// Pure one-slot launch gate for a project. It makes overlapping launches fail
/// explicitly, gives each launch a generation token, and lets Stop/close make
/// a late completion stale before it can publish over the new request.
struct GameLaunchSerialGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var active = false

    mutating func begin() throws -> UInt64 {
        guard !active else { throw GameWorkspaceRegistryError.launchInProgress }
        active = true
        generation &+= 1
        return generation
    }

    func isCurrent(_ token: UInt64) -> Bool {
        active && generation == token
    }

    mutating func finish(_ token: UInt64) {
        guard active, generation == token else { return }
        active = false
    }

    mutating func cancel() {
        generation &+= 1
        active = false
    }
}
#endif

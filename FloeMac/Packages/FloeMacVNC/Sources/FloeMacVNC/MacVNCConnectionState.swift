// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Observable lifecycle of one toolbox-owned VNC session owner.
///
/// Transitions:
/// - `idle → connecting → connected → closing → closed` (manual open, then user close)
/// - `connecting/connected → failed` (terminal transport/auth failure)
/// - `closed/failed → idle` via `resume()` for a new manual connection
public enum MacVNCConnectionState: Sendable, Hashable {
    case idle
    case connecting
    case connected
    case closing
    case closed
    case failed(MacVNCConnectionFailure)

    public var isActive: Bool {
        switch self {
        case .connecting, .connected, .closing: true
        default: false
        }
    }
}

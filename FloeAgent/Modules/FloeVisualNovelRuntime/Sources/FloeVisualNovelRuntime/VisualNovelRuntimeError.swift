// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Errors surfaced by the visual-novel runtime host. Values stay free of
/// engine internals and never carry script content.
public enum VisualNovelRuntimeError: Error, Equatable, Sendable {
    /// The embedded ShioriKrkr framework could not be located or dlopen'd.
    case engineUnavailable(String)
    /// The framework loaded but an expected entry point is missing.
    case engineInterfaceMissing(String)
    /// The sandbox for the game could not be prepared.
    case sandboxUnavailable(String)
    /// `shiorikrkr_start` rejected the configuration or the game failed to boot.
    case engineStartFailed(Int32)
    /// A session call arrived before start or after stop.
    case invalidSessionState(String)
    /// Frame/audio access outside a running session.
    case notRunning
}

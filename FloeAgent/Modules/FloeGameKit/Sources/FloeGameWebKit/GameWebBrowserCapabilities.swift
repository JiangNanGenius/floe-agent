// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Browser API availability, not permission to execute an artifact or proof
/// that an engine works. Hosts still validate the source, adapter and policy.
public struct GameWebBrowserCapabilities: Codable, Equatable, Sendable {
    public let webAssembly: Bool
    public let suspending: Bool
    public let promising: Bool
    public var supportsJSPI: Bool { webAssembly && suspending && promising }
}

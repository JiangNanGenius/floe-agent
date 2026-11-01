import Foundation

/// Reflecting transport constants.
///
/// The route is deliberately a single /32 to the peer. Only packets whose
/// source and destination are exactly these two addresses are reflected; the
/// tunnel must never become a general Internet or DNS path.
public enum BridgeTransport {
    public static let interfaceAddress = "10.7.0.2"
    public static let peerAddress = "10.7.0.1"
    public static let routePrefixLength = 32
    public static let routeSubnetMask = "255.255.255.255"
    public static let remotePairingPort: UInt16 = 49152

    public static let interfaceAddressValue: UInt32 = 0x0A07_0002
    public static let peerAddressValue: UInt32 = 0x0A07_0001

    public static let tunnelDescription = "Floe Bridge Reflector"
}

/// DDI layouts on iOS. The probe reports the first readable XCTest runtime and
/// which layout supplied it.
///
/// `XCTest.framework` and `XCTestCore.framework` are directories. Readiness
/// must be decided from the executable image inside them, never from the
/// bundle directory itself. XCTestCore lives under `PrivateFrameworks`.
public enum BridgeDDILayout: String, CaseIterable, Codable, Sendable {
    case cryptex
    case system
    case legacy

    public var developerDirectory: String {
        switch self {
        case .cryptex:
            return "/private/preboot/Cryptexes/OS/System/Developer"
        case .system:
            return "/System/Developer"
        case .legacy:
            return "/Developer"
        }
    }

    public var frameworksDirectory: String {
        developerDirectory + "/Library/Frameworks"
    }

    public var privateFrameworksDirectory: String {
        developerDirectory + "/Library/PrivateFrameworks"
    }

    /// The bundle directory. Diagnostic only; it is a directory, not a runtime.
    public var frameworkBundlePath: String {
        frameworksDirectory + "/XCTest.framework"
    }

    /// The actual XCTest runtime image loaded by the bootstrap shim.
    public var executablePath: String {
        frameworkBundlePath + "/XCTest"
    }

    /// The actual XCTestCore fallback image. Private frameworks stay under
    /// `Library/PrivateFrameworks`, not `Library/Frameworks`.
    public var coreExecutablePath: String {
        privateFrameworksDirectory + "/XCTestCore.framework/XCTestCore"
    }
}

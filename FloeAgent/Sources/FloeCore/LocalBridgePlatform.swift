import Foundation

/// Runtime identity, independent of device size, CPU architecture or saved settings.
public enum LocalBridgePlatform: String, Sendable, CaseIterable {
    case nativeMac
    case macCatalyst
    case iOSAppOnMac
    case iOSDevice
    case iOSSimulator
    case unsupported

    public static var current: Self {
        #if os(macOS)
        return .nativeMac
        #elseif targetEnvironment(macCatalyst)
        return .macCatalyst
        #elseif os(iOS) && targetEnvironment(simulator)
        return .iOSSimulator
        #elseif os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac ? .iOSAppOnMac : .iOSDevice
        #else
        return .unsupported
        #endif
    }

    public var supportsMacBridge: Bool {
        switch self {
        case .nativeMac, .macCatalyst, .iOSAppOnMac: true
        case .iOSDevice, .iOSSimulator, .unsupported: false
        }
    }

    public var supportsIOSAutomation: Bool { self == .iOSDevice }
}

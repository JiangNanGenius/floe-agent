// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import FloeToolboxCore
import FloeToolboxUSBWire

/// A payload inspection is deliberately not a driver installation, entitlement
/// check, running-service discovery, device permission or connection receipt.
public enum USBDriverPackageInspection: Equatable, Sendable {
    case notIncluded
    case unconfigured
    case bundledUnverified(USBDriverPackageManifest)
    case invalid(String)
}

public struct USBDriverInterfaceMatch: Equatable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let configurationValue: UInt8
    public let interfaceNumber: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
}

public struct USBDriverPackageManifest: Equatable, Sendable {
    public let bundleIdentifier: String
    public let minimumDriverKitVersion: String
    public let wireVersion: Int
    public let matches: [USBDriverInterfaceMatch]
}

/// Native-code-only source seam for the host's USB status and later picker.
/// The App supplies Bundle.main.bundleURL, never a model-authored host path.
public enum USBDriverPackage {
    public static let bundleIdentifier = "org.floeagent.ios.FloeUSBSerialDriver"
    public static let serviceClass = "FloeUSBSerialDriver"
    public static let userClientClass = "FloeUSBSerialUserClient"
    public static let payloadRelativePath = "SystemExtensions/FloeUSBSerialDriver.dext"
    public static let minimumDriverKitVersion = "27.0"

    public static func inspect(in appBundleURL: URL) -> USBDriverPackageInspection {
        guard appBundleURL.isFileURL else { return .invalid("non-file App bundle") }
        let root = appBundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let payload = root.appendingPathComponent(payloadRelativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: payload.path) else { return .notIncluded }
        let infoURL = payload.appendingPathComponent("Info.plist")
        do {
            for url in [payload.deletingLastPathComponent(), payload, infoURL] {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true,
                      url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                    return .invalid("driver payload escapes App bundle")
                }
            }
            let infoValues = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard infoValues.isRegularFile == true, let size = infoValues.fileSize,
                  (1...262_144).contains(size) else { return .invalid("driver manifest size") }
            let bytes = try Data(contentsOf: infoURL)
            guard bytes.count <= 262_144,
                  let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == bundleIdentifier,
                  info["CFBundlePackageType"] as? String == "DEXT",
                  info["CFBundleExecutable"] as? String == serviceClass,
                  info["FloeUSBMinimumDriverKitVersion"] as? String == minimumDriverKitVersion,
                  integer(info["FloeUSBWireVersion"], in: 1...Int.max) == Int(FLOE_USB_VERSION),
                  let personalities = info["IOKitPersonalities"] as? [String: Any],
                  personalities.count <= 32 else { return .invalid("driver manifest identity") }
            guard !personalities.isEmpty else { return .unconfigured }
            var matches: [USBDriverInterfaceMatch] = []
            for key in personalities.keys.sorted() {
                guard let value = personalities[key] as? [String: Any],
                      value["CFBundleIdentifier"] as? String == bundleIdentifier,
                      value["CFBundleIdentifierKernel"] as? String == "com.apple.kpi.iokit",
                      value["IOProviderClass"] as? String == "IOUSBHostInterface",
                      value["IOClass"] as? String == "IOUserService",
                      value["IOUserClass"] as? String == serviceClass,
                      value["IOUserServerName"] as? String == bundleIdentifier,
                      let client = value["FloeUSBUserClientProperties"] as? [String: Any],
                      client["IOClass"] as? String == "IOUserUserClient",
                      client["IOUserClass"] as? String == userClientClass,
                      let match = match(value) else { return .invalid("driver personality " + key) }
                guard !matches.contains(match) else { return .invalid("duplicate USB interface match") }
                matches.append(match)
            }
            // This only observes that an executable file was embedded. It does
            // not substitute for Mach-O, signature/profile or device acceptance.
            let executable = payload.appendingPathComponent(serviceClass)
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { return .invalid("driver executable absent") }
            return .bundledUnverified(.init(bundleIdentifier: bundleIdentifier,
                minimumDriverKitVersion: minimumDriverKitVersion, wireVersion: Int(FLOE_USB_VERSION), matches: matches))
        } catch {
            return .invalid("driver payload cannot be read")
        }
    }

    private static func match(_ value: [String: Any]) -> USBDriverInterfaceMatch? {
        guard let vendor = integer(value["idVendor"], in: 1...65_535),
              let product = integer(value["idProduct"], in: 0...65_535),
              let configuration = integer(value["bConfigurationValue"], in: 1...255),
              let number = integer(value["bInterfaceNumber"], in: 0...255),
              let interfaceClass = integer(value["bInterfaceClass"], in: 0...255),
              let subclass = integer(value["bInterfaceSubClass"], in: 0...255),
              let interfaceProtocol = integer(value["bInterfaceProtocol"], in: 0...255),
              USBSerialChipPlans.candidate(vendor: UInt16(vendor), product: UInt16(product),
                  interfaceClass: UInt8(interfaceClass), subclass: UInt8(subclass)) != nil else { return nil }
        return .init(vendorID: UInt16(vendor), productID: UInt16(product),
            configurationValue: UInt8(configuration), interfaceNumber: UInt8(number),
            interfaceClass: UInt8(interfaceClass), interfaceSubclass: UInt8(subclass),
            interfaceProtocol: UInt8(interfaceProtocol))
    }

    private static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.intValue),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}

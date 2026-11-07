// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeToolboxCore
import FloeToolboxUSBWire
import FloeToolboxUSBIOKit

public enum USBRegistryError: Error, Equatable, Sendable {
    case packageNotIncluded, packageUnconfigured, invalidPackage
    case identityUnavailable, staleSelection, limit, unsupported
    case io(Int32)

    static func check(_ status: Int32) throws {
        switch status {
        case 0: return
        case Int32(FLOE_USB_HOST_INVALID_ARGUMENT), Int32(FLOE_USB_HOST_IDENTITY_UNAVAILABLE): throw Self.identityUnavailable
        case Int32(FLOE_USB_HOST_IDENTITY_CHANGED): throw Self.staleSelection
        case Int32(FLOE_USB_HOST_LIMIT): throw Self.limit
        case Int32(FLOE_USB_HOST_UNSUPPORTED): throw Self.unsupported
        default: throw Self.io(status)
        }
    }
}

/// These IDs identify only the currently observed registry objects. They are
/// neither persisted for reconnect nor supplied by model-authored arguments.
struct USBRegistryIdentity: Equatable, Sendable {
    let serviceID: UInt64, providerID: UInt64, deviceID: UInt64
    let vendor: UInt16, product: UInt16
    let configuration: UInt8, interfaceNumber: UInt8
    let interfaceClass: UInt8, interfaceSubclass: UInt8, interfaceProtocol: UInt8

    init(raw: FloeUSBRegistryIdentity) throws {
        guard raw.serviceID != 0, raw.providerID != 0, raw.deviceID != 0,
              raw.vendor != 0, raw.configuration != 0 else { throw USBRegistryError.identityUnavailable }
        serviceID = raw.serviceID; providerID = raw.providerID; deviceID = raw.deviceID
        vendor = raw.vendor; product = raw.product; configuration = raw.configuration
        interfaceNumber = raw.interfaceNumber; interfaceClass = raw.interfaceClass
        interfaceSubclass = raw.interfaceSubclass; interfaceProtocol = raw.interfaceProtocol
    }
    var raw: FloeUSBRegistryIdentity {
        var value = FloeUSBRegistryIdentity()
        value.serviceID = serviceID; value.providerID = providerID; value.deviceID = deviceID
        value.vendor = vendor; value.product = product; value.configuration = configuration
        value.interfaceNumber = interfaceNumber; value.interfaceClass = interfaceClass
        value.interfaceSubclass = interfaceSubclass; value.interfaceProtocol = interfaceProtocol
        return value
    }
    func matches(_ match: USBDriverInterfaceMatch) -> Bool {
        vendor == match.vendorID && product == match.productID && configuration == match.configurationValue &&
            interfaceNumber == match.interfaceNumber && interfaceClass == match.interfaceClass &&
            interfaceSubclass == match.interfaceSubclass && interfaceProtocol == match.interfaceProtocol
    }
    func matchesInformation(_ information: USBDeviceInformation) -> Bool {
        // INFO v1 does not contain configuration or interfaceProtocol. They are
        // revalidated on the actual provider before/after native open instead.
        vendor == information.vendor && product == information.product &&
            interfaceNumber == information.interfaceNumber && interfaceClass == information.interfaceClass &&
            interfaceSubclass == information.interfaceSubclass
    }
}

public struct USBRegistryDevice: Identifiable, Equatable, Sendable {
    let identity: USBRegistryIdentity
    public var id: UInt64 { identity.serviceID }
    public var vendorID: UInt16 { identity.vendor }
    public var productID: UInt16 { identity.product }
    public var configurationValue: UInt8 { identity.configuration }
    public var interfaceNumber: UInt8 { identity.interfaceNumber }
    public var interfaceClass: UInt8 { identity.interfaceClass }
    public var interfaceSubclass: UInt8 { identity.interfaceSubclass }
    public var interfaceProtocol: UInt8 { identity.interfaceProtocol }
}

/// Created only by selecting an exact device in this host's native discovery.
/// Deliberately no public initializer, Codable conformance or first-device API.
public struct USBRegistrySelection: Sendable {
    fileprivate let hostID: UUID
    fileprivate let identity: USBRegistryIdentity
    public var registryEntryID: UInt64 { identity.serviceID }
}
public struct USBRegistryDiscovery: Sendable {
    public let devices: [USBRegistryDevice]
    /// Own running services outside the currently embedded exact match set.
    /// A nonzero count is not silently reported as "no USB devices".
    public let unmatchedOwnServiceCount: Int
    fileprivate let hostID: UUID
    public func select(registryEntryID: UInt64) throws -> USBRegistrySelection {
        guard let device = devices.first(where: { $0.id == registryEntryID }) else { throw USBRegistryError.staleSelection }
        return .init(hostID: hostID, identity: device.identity)
    }
}

protocol USBRegistryBackend: Sendable {
    func discover() async throws -> [USBRegistryIdentity]
    func open(expected: USBRegistryIdentity) async throws -> any USBUserClientChannel
}

/// Native service boundary only. The App later supplies an inspection of its
/// own Bundle.main payload; inspection is not a grant, enabled state or access.
public struct USBRegistryHost: Sendable {
    private let id = UUID()
    private let matches: [USBDriverInterfaceMatch]
    private let backend: any USBRegistryBackend
    public init(package: USBDriverPackageInspection) throws {
        switch package {
        case .notIncluded: throw USBRegistryError.packageNotIncluded
        case .unconfigured: throw USBRegistryError.packageUnconfigured
        case .invalid: throw USBRegistryError.invalidPackage
        case .bundledUnverified(let manifest):
            guard manifest.bundleIdentifier == USBDriverPackage.bundleIdentifier,
                  manifest.wireVersion == Int(FLOE_USB_VERSION) else { throw USBRegistryError.invalidPackage }
            try self.init(matches: manifest.matches, backend: NativeUSBRegistryBackend())
        }
    }
    init(matches: [USBDriverInterfaceMatch], backend: any USBRegistryBackend) throws {
        guard !matches.isEmpty else { throw USBRegistryError.packageUnconfigured }
        guard matches.count <= Int(FLOE_USB_HOST_MAX_DEVICES) else { throw USBRegistryError.limit }
        for (index, match) in matches.enumerated() {
            guard match.vendorID != 0, match.configurationValue != 0,
                  USBSerialChipPlans.candidate(vendor: match.vendorID, product: match.productID,
                    interfaceClass: match.interfaceClass, subclass: match.interfaceSubclass) != nil,
                  !matches[..<index].contains(match) else { throw USBRegistryError.invalidPackage }
        }
        self.matches = matches; self.backend = backend
    }
    public func discover() async throws -> USBRegistryDiscovery {
        try Task.checkCancellation()
        let observed = try await backend.discover()
        try Task.checkCancellation()
        guard observed.count <= Int(FLOE_USB_HOST_MAX_DEVICES) else { throw USBRegistryError.limit }
        guard Set(observed.map(\.serviceID)).count == observed.count else { throw USBRegistryError.identityUnavailable }
        let devices = observed.filter { value in matches.contains(where: value.matches) }
            .sorted { $0.serviceID < $1.serviceID }.map { USBRegistryDevice(identity: $0) }
        return .init(devices: devices, unmatchedOwnServiceCount: observed.count - devices.count, hostID: id)
    }
    public func connect(selection: USBRegistrySelection, settings: USBSerialSettings) async throws -> USBSerialConnection {
        try Task.checkCancellation()
        guard selection.hostID == id, matches.contains(where: selection.identity.matches) else { throw USBRegistryError.staleSelection }
        let channel = try await backend.open(expected: selection.identity)
        do {
            try Task.checkCancellation()
            return try await USBSerialClient.connect(channel: channel, settings: settings, expectedIdentity: selection.identity)
        } catch { await channel.close(); throw error }
    }
}

private struct NativeUSBRegistryBackend: USBRegistryBackend {
    func discover() async throws -> [USBRegistryIdentity] {
        try Task.checkCancellation()
        let values: [USBRegistryIdentity] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    var records = [FloeUSBRegistryIdentity](repeating: .init(), count: Int(FLOE_USB_HOST_MAX_DEVICES))
                    var count = 0
                    let status = records.withUnsafeMutableBufferPointer { floe_usb_host_discover($0.baseAddress, $0.count, &count) }
                    try USBRegistryError.check(status)
                    guard (0...records.count).contains(count) else { throw USBRegistryError.limit }
                    return try records.prefix(count).map { try USBRegistryIdentity(raw: $0) }
                })
            }
        }
        try Task.checkCancellation()
        return values
    }
    func open(expected: USBRegistryIdentity) async throws -> any USBUserClientChannel {
        try await IOKitUSBUserClientChannel.open(expectedIdentity: expected)
    }
}

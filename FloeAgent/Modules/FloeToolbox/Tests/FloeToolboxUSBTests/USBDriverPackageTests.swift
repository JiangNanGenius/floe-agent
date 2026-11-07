// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeToolboxUSB

private struct USBPackageFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usb-package-" + UUID().uuidString)
    var payload: URL { root.appendingPathComponent(USBDriverPackage.payloadRelativePath, isDirectory: true) }

    func write(personalities: [String: Any]? = nil, wireVersion: Int = 1) throws {
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": USBDriverPackage.bundleIdentifier,
            "CFBundlePackageType": "DEXT", "CFBundleExecutable": USBDriverPackage.serviceClass,
            "FloeUSBMinimumDriverKitVersion": USBDriverPackage.minimumDriverKitVersion,
            "FloeUSBWireVersion": wireVersion,
        ]
        info["IOKitPersonalities"] = personalities ?? ["Synthetic": Self.personality]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: payload.appendingPathComponent("Info.plist"))
        // Deliberately not Mach-O: metadata inspection MUST report unverified,
        // never installed/entitled/ready or hardware-compatible.
        try Data("unqualified fixture bytes".utf8).write(to: payload.appendingPathComponent(USBDriverPackage.serviceClass))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    static var personality: [String: Any] {
        ["CFBundleIdentifier": USBDriverPackage.bundleIdentifier,
         "CFBundleIdentifierKernel": "com.apple.kpi.iokit",
         "IOProviderClass": "IOUSBHostInterface", "IOClass": "IOUserService",
         "IOUserClass": USBDriverPackage.serviceClass, "IOUserServerName": USBDriverPackage.bundleIdentifier,
         "FloeUSBUserClientProperties": ["IOClass": "IOUserUserClient", "IOUserClass": USBDriverPackage.userClientClass],
         "idVendor": 0x10C4, "idProduct": 0xEA60, "bConfigurationValue": 1,
         "bInterfaceNumber": 0, "bInterfaceClass": 255, "bInterfaceSubClass": 0, "bInterfaceProtocol": 0]
    }
}

@Test func missingUSBPayloadIsNotReportedAsDisabledOrReady() {
    let fixture = USBPackageFixture(); defer { fixture.remove() }
    #expect(USBDriverPackage.inspect(in: fixture.root) == .notIncluded)
}

@Test func embeddedUSBMetadataIsAlwaysUnverifiedAndRetainsExactInterfaceScope() throws {
    let fixture = USBPackageFixture(); defer { fixture.remove() }
    try fixture.write()
    guard case .bundledUnverified(let manifest) = USBDriverPackage.inspect(in: fixture.root) else {
        Issue.record("Expected unverified payload metadata, never a connection receipt"); return
    }
    #expect(manifest.bundleIdentifier == USBDriverPackage.bundleIdentifier)
    #expect(manifest.wireVersion == 1)
    #expect(manifest.matches.count == 1)
    #expect(manifest.matches.first?.vendorID == 0x10C4)
    #expect(manifest.matches.first?.productID == 0xEA60)
    #expect(manifest.matches.first?.configurationValue == 1)
    #expect(manifest.matches.first?.interfaceNumber == 0)
    #expect(manifest.minimumDriverKitVersion == "27.0")
}

@Test func emptyDriverReviewManifestDoesNotAdvertiseADevice() throws {
    let fixture = USBPackageFixture(); defer { fixture.remove() }
    try fixture.write(personalities: [:])
    #expect(USBDriverPackage.inspect(in: fixture.root) == .unconfigured)
}

@Test func USBManifestRejectsWildcardsBooleanIdentityWrongServerAndWireVersion() throws {
    let fixture = USBPackageFixture(); defer { fixture.remove() }
    for (key, value) in [("idVendor", "*" as Any), ("idVendor", true as Any),
                         ("idProduct", 0xFFFF as Any), ("bInterfaceNumber", 0.5 as Any),
                         ("IOUserServerName", "another.driver" as Any)] {
        var personality = USBPackageFixture.personality; personality[key] = value
        try fixture.write(personalities: ["Invalid": personality])
        guard case .invalid = USBDriverPackage.inspect(in: fixture.root) else {
            Issue.record("Unresolved or broad USB match was accepted: " + key); continue
        }
    }
    try fixture.write(wireVersion: 2)
    guard case .invalid = USBDriverPackage.inspect(in: fixture.root) else {
        Issue.record("An unknown wire ABI was accepted"); return
    }
}

@Test func USBPayloadCannotUseAnExecutableOutsideTheAppBundle() throws {
    let fixture = USBPackageFixture(); defer { fixture.remove() }
    try fixture.write()
    let executable = fixture.payload.appendingPathComponent(USBDriverPackage.serviceClass)
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/true"))
    guard case .invalid = USBDriverPackage.inspect(in: fixture.root) else {
        Issue.record("A symlink escaped the embedded payload"); return
    }
}

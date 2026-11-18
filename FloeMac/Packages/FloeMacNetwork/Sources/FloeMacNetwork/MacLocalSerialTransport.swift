// SPDX-License-Identifier: MPL-2.0
//
// Local serial transport factory used by the toolbox communication owner.
// USB serial is live; the BLE GATT candidate is kept outside the production
// target until its Swift 6 handoff is verified (see the job handoff
// evidence). Tests replace these closures with scripted connections.

import Foundation
import FloeToolboxCore
import FloeToolboxClients

public struct MacLocalSerialTransport: Sendable {
    public var openUSB: @Sendable (_ path: String, _ settings: USBSerialSettings) async throws -> any SerialConnection

    public init(openUSB: @escaping @Sendable (_ path: String, _ settings: USBSerialSettings) async throws -> any SerialConnection) {
        self.openUSB = openUSB
    }

    public static let live = MacLocalSerialTransport(
        openUSB: { path, settings in try MacUSBSerialConnection(path: path, settings: settings) })
}

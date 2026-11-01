// SPDX-License-Identifier: MPL-2.0
//
// C05 device communication focused tests (authored, NOT RUN in the source
// stage): profile projection/validation over the REAL RemoteHostProfile
// value, BLE address/UUID normalization, owner isolation and mailbox bounds.

import Foundation
import XCTest
import FloeCore
import FloePersistence
import FloeSSH
@testable import FloeAndroidCore

final class C05DeviceCommunicationDomainTests: XCTestCase {
    // MARK: - Address / UUID

    func testBLEAddressRoundTripAndValidation() {
        XCTAssertTrue(C05DeviceBLEAddress.isValid("aa:bb:cc:dd:ee:ff"))
        XCTAssertFalse(C05DeviceBLEAddress.isValid("aa:bb:cc:dd:ee"))
        let uuid = C05DeviceBLEAddress.uuid(from: "AA:BB:CC:DD:EE:FF")
        XCTAssertNotNil(uuid)
        XCTAssertEqual(C05DeviceBLEAddress.mac(from: uuid!), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(C05DeviceBLEAddress.normalized(" aa:bb:cc:dd:ee:ff "), "AA:BB:CC:DD:EE:FF")
    }

    func testGATTUUIDNormalization() {
        XCTAssertEqual(C05DeviceGATTUUID.normalize("180f"),
                       "0000180f-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(C05DeviceGATTUUID.normalize("12345678"),
                       "12345678-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(C05DeviceGATTUUID.normalize("12345678-1234-1234-1234-123456789ABC"),
                       "12345678-1234-1234-1234-123456789abc")
        XCTAssertNil(C05DeviceGATTUUID.normalize("not-a-uuid"))
        XCTAssertNil(C05DeviceGATTUUID.normalize("180g"))
    }

    // MARK: - Profile domain

    private actor TestDeviceStore: C05DeviceProfileStoring {
        private var rows: [UUID: RemoteHostStore.StoredHost] = [:]

        func seed(_ host: RemoteHostStore.StoredHost) {
            rows[host.id] = host
        }

        func hosts() async throws -> [RemoteHostStore.StoredHost] {
            Array(rows.values)
        }

        func host(id: UUID) async throws -> RemoteHostStore.StoredHost? {
            rows[id]
        }

        func saveHost(_ host: RemoteHostStore.StoredHost) async throws {
            rows[host.id] = host
        }

        func deleteHost(id: UUID) async throws {
            rows.removeValue(forKey: id)
        }

        func row(id: UUID) -> RemoteHostStore.StoredHost? { rows[id] }
    }

    private func domain(_ store: TestDeviceStore, epoch: UInt64 = 9) -> C05DeviceDomain {
        C05DeviceDomain(
            storeProvider: { _ in store },
            epochProvider: { epoch }
        )
    }

    private var owner: C05DeviceOwner {
        C05DeviceOwner(token: "ui.test", nativeEpoch: 9)
    }

    private func storedProfile(
        id: UUID = UUID(),
        withVNC: Bool = false,
        connections: [RemoteAuxiliaryConnection] = []
    ) throws -> RemoteHostStore.StoredHost {
        let profile = RemoteHostProfile(
            id: id,
            displayName: "Lab",
            address: "",
            port: 22,
            user: "",
            auth: .none,
            deviceKind: .appliance,
            isRemoteExecutionEnvironment: false,
            vncEndpoints: withVNC ? [VNCEndpoint(displayName: "Screen")] : [],
            auxiliaryConnections: connections
        )
        return try profile.storedHost()
    }

    func testSaveDeviceProfilePreservesVNCEndpointAndStoresMAC() async throws {
        let store = TestDeviceStore()
        let id = UUID()
        await store.seed(try storedProfile(id: id, withVNC: true))
        let sut = domain(store)

        let draft = C05DeviceProfileDraft(
            id: id,
            displayName: "Lab",
            connections: [
                C05DeviceConnectionDraft(
                    displayName: "Console",
                    kind: "telnet",
                    host: "192.168.1.2",
                    port: 23
                ),
                C05DeviceConnectionDraft(
                    displayName: "Sensor",
                    kind: "bluetoothSerial",
                    peripheralAddress: "aa:bb:cc:dd:ee:ff",
                    serviceUUID: "180f",
                    writeUUID: "2a19",
                    notifyUUID: "2a1a"
                ),
            ]
        )
        let saved = try await sut.saveProfile(draft, owner: owner)
        XCTAssertEqual(saved.connections.count, 2)
        let row = await store.row(id: id)
        XCTAssertNotNil(row)
        let profile = try RemoteHostProfile(stored: row!)
        XCTAssertEqual(profile.vncEndpoints.count, 1)
        XCTAssertEqual(profile.auxiliaryConnections.count, 2)
        let ble = profile.auxiliaryConnections.first { $0.kind == .bluetoothSerial }
        XCTAssertEqual(ble?.host, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(ble?.bluetoothPeripheralID, C05DeviceBLEAddress.uuid(from: "AA:BB:CC:DD:EE:FF"))
        XCTAssertEqual(ble?.bluetoothServiceUUID, "0000180f-0000-1000-8000-00805f9b34fb")
    }

    func testListAndResolveOnlyDeviceConnections() async throws {
        let store = TestDeviceStore()
        let id = UUID()
        let connectionID = UUID()
        await store.seed(try storedProfile(
            id: id,
            connections: [
                RemoteAuxiliaryConnection(
                    id: connectionID,
                    displayName: "Switch",
                    kind: .tcp,
                    host: "switch.local",
                    port: 9000
                ),
            ]
        ))
        await store.seed(try storedProfile()) // no device connections
        let sut = domain(store)
        let profiles = try await sut.listProfiles(owner: owner)
        XCTAssertEqual(profiles.count, 1)
        let resolved = try await sut.resolveConnection(
            hostID: id,
            connectionID: connectionID,
            owner: owner
        )
        XCTAssertEqual(resolved.kind, "tcp")
        XCTAssertEqual(resolved.host, "switch.local")
        XCTAssertEqual(resolved.port, 9000)
    }

    func testDeleteProfilePreservesHostWithOtherData() async throws {
        let store = TestDeviceStore()
        let id = UUID()
        await store.seed(try storedProfile(id: id, withVNC: true))
        let sut = domain(store)
        _ = try await sut.saveProfile(
            C05DeviceProfileDraft(
                id: id,
                displayName: "Lab",
                connections: [
                    C05DeviceConnectionDraft(displayName: "Console", kind: "tcp",
                                             host: "example.com", port: 9000),
                ]
            ),
            owner: owner
        )
        _ = try await sut.deleteProfile(id: id, owner: owner)
        let row = await store.row(id: id)
        XCTAssertNotNil(row)
        let profile = try RemoteHostProfile(stored: row!)
        XCTAssertTrue(profile.auxiliaryConnections.isEmpty)
        XCTAssertEqual(profile.vncEndpoints.count, 1)
    }

    func testDeletePlainDeviceProfileRemovesRow() async throws {
        let store = TestDeviceStore()
        let id = UUID()
        await store.seed(try storedProfile(id: id))
        let sut = domain(store)
        _ = try await sut.saveProfile(
            C05DeviceProfileDraft(
                id: id,
                displayName: "Lab",
                connections: [
                    C05DeviceConnectionDraft(displayName: "Console", kind: "tcp",
                                             host: "example.com", port: 9000),
                ]
            ),
            owner: owner
        )
        _ = try await sut.deleteProfile(id: id, owner: owner)
        let deletedRow = await store.row(id: id)
        XCTAssertNil(deletedRow)
    }

    func testInvalidDraftIsRejected() async throws {
        let store = TestDeviceStore()
        let sut = domain(store)
        do {
            _ = try await sut.saveProfile(
                C05DeviceProfileDraft(
                    id: nil,
                    displayName: "",
                    connections: [
                        C05DeviceConnectionDraft(displayName: "Bad", kind: "tcp",
                                                 host: "", port: 0),
                    ]
                ),
                owner: owner
            )
            XCTFail("empty profile name should fail")
        } catch let error as C05DeviceError {
            XCTAssertEqual(error.code, .invalidProfile)
        }
    }

    func testStaleOwnerCannotReadProfiles() async throws {
        let store = TestDeviceStore()
        let sut = domain(store, epoch: 10)
        do {
            _ = try await sut.listProfiles(owner: owner)
            XCTFail("stale epoch should fail")
        } catch let error as C05DeviceError {
            XCTAssertEqual(error.code, .staleEpoch)
        }
    }

    // MARK: - Mailbox

    func testMailboxRefusesUnboundWrongEpochAndMissingApproval() async {
        let mailbox = C05DeviceHostMailbox()
        let taskID = UUID()
        let baseOwner = C05DeviceOwner(
            token: "tool.test",
            nativeEpoch: 1,
            taskID: taskID,
            approvalGrantID: UUID()
        )
        do {
            _ = try await mailbox.submit(
                operation: "status",
                request: Data("{}".utf8),
                owner: baseOwner,
                requiresApproval: false,
                cancellation: CancellationToken()
            )
            XCTFail("unbound mailbox must fail")
        } catch let error as C05DeviceHostError {
            XCTAssertEqual(error, .hostUnbound)
        }

        XCTAssertTrue(mailbox.bind(epoch: 1))
        XCTAssertFalse(mailbox.bind(epoch: 1))
        let otherEpoch = C05DeviceOwner(
            token: "tool.test",
            nativeEpoch: 2,
            taskID: taskID,
            approvalGrantID: UUID()
        )
        do {
            _ = try await mailbox.submit(
                operation: "status",
                request: Data("{}".utf8),
                owner: otherEpoch,
                requiresApproval: false,
                cancellation: CancellationToken()
            )
            XCTFail("wrong epoch must fail")
        } catch let error as C05DeviceHostError {
            XCTAssertEqual(error, .hostFenced)
        }

        let noApproval = C05DeviceOwner(
            token: "tool.test",
            nativeEpoch: 1,
            taskID: taskID,
            approvalGrantID: nil
        )
        do {
            _ = try await mailbox.submit(
                operation: "open",
                request: Data("{}".utf8),
                owner: noApproval,
                requiresApproval: true,
                cancellation: CancellationToken()
            )
            XCTFail("approval is required")
        } catch let error as C05DeviceHostError {
            XCTAssertEqual(error, .approvalRequired)
        }
        mailbox.close(epoch: 1)
        XCTAssertFalse(mailbox.isBound)
    }
}

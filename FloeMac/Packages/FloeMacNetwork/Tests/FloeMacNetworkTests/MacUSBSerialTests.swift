// SPDX-License-Identifier: MPL-2.0
//
// Targeted checks for the explicitly selected USB serial transport. No
// hardware is required: catalog grammar runs against a fixture directory,
// termios mapping is pure, and the completion gate is exercised directly.

import Darwin
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxClients
@testable import FloeMacNetwork

@Suite("USB serial port catalog")
struct MacUSBSerialPortTests {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-usb-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["cu.usbserial-TEST1", "cu.wlan-debug", "tty.usbserial-TEST1"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        return root
    }

    @Test func catalogListsOnlyCalloutNodesSorted() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MacUSBSerialPortCatalog(deviceRoot: root)
        let ports = catalog.ports()
        #expect(ports.map(\.fileName) == ["cu.usbserial-TEST1", "cu.wlan-debug"])
        #expect(ports.allSatisfy { $0.path.hasPrefix(root.path + "/") })
    }

    @Test func validationAcceptsSelectedCalloutAndRejectsCraftedPaths() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MacUSBSerialPortCatalog(deviceRoot: root)
        #expect(try catalog.validate(path: root.path + "/cu.usbserial-TEST1") == root.path + "/cu.usbserial-TEST1")
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: "") }
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: "cu.usbserial-TEST1") }
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: root.path + "/tty.usbserial-TEST1") }
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: root.path + "/cu.") }
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: root.path + "/cu.a/../../cu.b") }
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: "/etc/cu.passwd") }
    }

    @Test func validationRejectsSymbolicLinks() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("cu.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let catalog = MacUSBSerialPortCatalog(deviceRoot: root)
        #expect(throws: MacUSBSerialPortError.self) { try catalog.validate(path: link.path) }
    }
}

@Suite("USB serial termios mapping")
struct MacUSBSerialTermiosTests {
    @Test func standardBaudsMapAndExoticBaudsStayUnsupported() {
        for baud: UInt32 in [9600, 19200, 38400, 57600, 115200, 230400] {
            #expect(MacUSBSerialTermios.baudConstant(baud) != nil)
        }
        #expect(MacUSBSerialTermios.baudConstant(460800) == nil)
        #expect(MacUSBSerialTermios.baudConstant(921600) == nil)
    }

    @Test func applySetsDataStopAndParityBits() throws {
        var t = termios()
        let settings = try USBSerialSettings(baud: 115200, dataBits: 8, stopBits: 2, parity: .even)
        try MacUSBSerialTermios.apply(settings: settings, to: &t)
        #expect(t.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS8))
        #expect(t.c_cflag & tcflag_t(CSTOPB) != 0)
        #expect(t.c_cflag & tcflag_t(PARENB) != 0)
        #expect(t.c_cflag & tcflag_t(PARODD) == 0)
        let odd = try USBSerialSettings(baud: 9600, dataBits: 7, stopBits: 1, parity: .odd)
        var oddT = termios()
        try MacUSBSerialTermios.apply(settings: odd, to: &oddT)
        #expect(oddT.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS7))
        #expect(oddT.c_cflag & tcflag_t(CSTOPB) == 0)
        #expect(oddT.c_cflag & tcflag_t(PARENB | PARODD) == tcflag_t(PARENB | PARODD))
    }

    @Test func markSpaceParityAndNonStandardBaudAreUnsupported() throws {
        var t = termios()
        let mark = try USBSerialSettings(parity: .mark)
        #expect(throws: ClientError.unsupported) { try MacUSBSerialTermios.apply(settings: mark, to: &t) }
        let fast = try USBSerialSettings(baud: 1_000_000)
        #expect(throws: ClientError.unsupported) { try MacUSBSerialTermios.apply(settings: fast, to: &t) }
    }
}

@Suite("Serial completion gate")
struct MacSerialCompletionTests {
    @Test func deliveredValueReachesWaiter() async throws {
        let gate = MacSerialCompletion<Data>()
        let waiter = Task { try await gate.wait(seconds: 5) }
        try await Task.sleep(for: .milliseconds(20))
        gate.finish(.success(Data([1, 2, 3])))
        let value = try await waiter.value
        #expect(value == Data([1, 2, 3]))
    }

    @Test func earlyFinishIsBufferedForLateWaiter() async throws {
        let gate = MacSerialCompletion<Data>()
        gate.finish(.success(Data([9])))
        let value = try await gate.wait(seconds: 5)
        #expect(value == Data([9]))
    }

    @Test func secondFinishIsIgnored() async throws {
        let gate = MacSerialCompletion<Data>()
        gate.finish(.success(Data([1])))
        gate.finish(.success(Data([2])))
        #expect(try await gate.wait(seconds: 5) == Data([1]))
    }
}

@Suite("USB serial connection admission")
struct MacUSBSerialConnectionTests {
    @Test func liveDescriptorReadsAreBoundedAndCloseReleasesWaiters() async throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            Issue.record("Could not open the local serial fixture")
            return
        }
        let owned = descriptors[0]
        let peer = descriptors[1]
        defer { Darwin.close(peer) }
        guard fcntl(owned, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(owned)
            Issue.record("Could not make the fixture descriptor nonblocking")
            return
        }
        let connection = MacUSBSerialConnection(ownedDescriptor: owned, path: "fixture")
        let bytes: [UInt8] = [7, 8, 9]
        #expect(bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == bytes.count)
        #expect(try await connection.receive(maximumBytes: 2) == Data([7, 8]))
        #expect(try await connection.receive(maximumBytes: 2) == Data([9]))

        let waiter = Task { try await connection.receive(maximumBytes: 2) }
        await Task.yield()
        await connection.close()
        await #expect(throws: ClientError.self) { _ = try await waiter.value }
        #expect(fcntl(owned, F_GETFD) == -1)
    }

    @Test func openOfMissingNodeFailsInsteadOfHanging() async {
        // Grammar-valid path with no hardware behind it must fail fast.
        await #expect(throws: ClientError.self) {
            _ = try MacUSBSerialConnection(path: "/dev/cu.floe-missing-fixture", settings: USBSerialSettings())
        }
    }

    @Test func openOfCraftedPathIsRejectedBeforeAnySyscall() async {
        await #expect(throws: MacUSBSerialPortError.self) {
            _ = try MacUSBSerialConnection(path: "/tmp/cu.fake", settings: USBSerialSettings())
        }
    }
}

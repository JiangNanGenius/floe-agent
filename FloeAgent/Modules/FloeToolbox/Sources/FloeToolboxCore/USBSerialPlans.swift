// Chip request algorithms adapted from mik3y/usb-serial-for-android, MIT.
// Pinned source: 4cb9e82cdcfa095eb2fe0b0bea9605f50bd8e2f2.
// Copyright 2011-2013 Google Inc.; 2013 Mike Wakerly; 2014 Andreas Butti.
// See ThirdParty/LICENSE.usb-serial-for-android.txt and ThirdParty/NOTICE.md.
import Foundation

public enum USBSerialFamily: String, Codable, Sendable, CaseIterable { case cdcACM, ftdi, cp210x, ch34x, pl2303 }
public enum PL2303Revision: String, Sendable, CaseIterable {
    case legacy01, hx, taTB, hxn
    /// A missing descriptor/probe remains unknown, rather than choosing a likely driver.
    public static func identify(deviceClass: UInt8, controlPacketSize: UInt8, usbVersion: UInt16,
                                deviceVersion: UInt16, hxProbeSucceeded: Bool? = nil) -> Self? {
        guard [8,16,32,64].contains(controlPacketSize) else { return nil }
        if deviceClass == 2 || controlPacketSize != 64 { return .legacy01 }
        if usbVersion == 0x0200 {
            if [0x0300,0x0500].contains(deviceVersion) {
                guard let hxProbeSucceeded else { return nil }
                return hxProbeSucceeded ? .taTB : .hxn
            }
            return .hxn
        }
        return .hx
    }
}
public struct USBSerialSettings: Sendable, Equatable {
    public enum Parity: UInt8, Sendable { case none = 0, odd = 1, even = 2, mark = 3, space = 4 }
    public let baud: UInt32
    public let dataBits: UInt8
    public let stopBits: UInt8
    public let parity: Parity
    public init(baud: UInt32 = 115200, dataBits: UInt8 = 8, stopBits: UInt8 = 1, parity: Parity = .none) throws {
        guard (50...3_500_000).contains(baud), (5...8).contains(dataBits), [1, 2].contains(stopBits) else { throw ToolboxError.invalid("serial settings") }
        self.baud = baud; self.dataBits = dataBits; self.stopBits = stopBits; self.parity = parity
    }
}
public struct USBControlRequest: Equatable, Sendable {
    public let requestType: UInt8
    public let request: UInt8
    public let value: UInt16
    public let index: UInt16
    public let payload: Data
    public let expectedReadBytes: UInt16
    public init(requestType: UInt8, request: UInt8, value: UInt16 = 0, index: UInt16 = 0,
                payload: Data = Data(), expectedReadBytes: UInt16 = 0) throws {
        guard payload.count <= 4096, expectedReadBytes <= 4096,
              requestType & 0x80 == 0 ? expectedReadBytes == 0 : payload.isEmpty else { throw ToolboxError.invalid("USB control request") }
        self.requestType = requestType; self.request = request; self.value = value; self.index = index
        self.payload = payload; self.expectedReadBytes = expectedReadBytes
    }
}
public enum USBSerialChipPlans {
    /// Candidate identification only. Matching never grants device access or declares hardware tested.
    public static func candidate(vendor: UInt16, product: UInt16, interfaceClass: UInt8, subclass: UInt8) -> USBSerialFamily? {
        if vendor == 0x0403, [0x6001, 0x6010, 0x6011, 0x6014, 0x6015].contains(product) { return .ftdi }
        if vendor == 0x10c4, [0xea60, 0xea70, 0xea71].contains(product) { return .cp210x }
        if vendor == 0x1a86, [0x7523, 0x5523].contains(product) { return .ch34x }
        if vendor == 0x067b, product == 0x2303 { return .pl2303 }
        if interfaceClass == 2, subclass == 2 { return .cdcACM }
        return nil
    }
    public static func configuration(family: USBSerialFamily, settings s: USBSerialSettings, interface: UInt8 = 0,
                                     ftdiPortIndexed: Bool = false, pl2303Revision: PL2303Revision? = nil) throws -> [USBControlRequest] {
        let i = UInt16(interface)
        let line = Data([UInt8(s.baud & 255), UInt8((s.baud >> 8) & 255), UInt8((s.baud >> 16) & 255), UInt8(s.baud >> 24), s.stopBits == 1 ? 0 : 2, s.parity.rawValue, s.dataBits])
        switch family {
        case .cdcACM:
            return [try USBControlRequest(requestType:0x21,request:0x20,index:i,payload:line),
                    try USBControlRequest(requestType:0x21,request:0x22,value:3,index:i)]
        case .pl2303:
            guard let revision = pl2303Revision, interface == 0 else {
                throw ToolboxError.unsupported("PL2303 requires a descriptor/probe-based revision and interface 0")
            }
            return try prolificConfiguration(revision: revision, settings: s)
        case .cp210x:
            let format = UInt16(s.dataBits) << 8 | UInt16(s.parity.rawValue) << 4 | (s.stopBits == 2 ? 2 : 0)
            return [try USBControlRequest(requestType:0x41,request:0,value:1,index:i),
                    try USBControlRequest(requestType:0x41,request:0x1e,index:i,payload:Data(line.prefix(4))),
                    try USBControlRequest(requestType:0x41,request:3,value:format,index:i),
                    try USBControlRequest(requestType:0x41,request:7,value:0x0303,index:i)]
        case .ch34x:
            var factor: UInt64, divisor: UInt64
            if s.baud == 921600 { factor = 0xf300; divisor = 7 }
            else if s.baud == 307200 { factor = 0xd900; divisor = 7 }
            else {
                factor = 1_532_620_800 / UInt64(s.baud); divisor = 3
                while factor > 0xfff0 && divisor > 0 { factor >>= 3; divisor -= 1 }
                guard factor > 0, factor <= 0xfff0 else { throw ToolboxError.unsupported("CH34x baud") }
                factor = 0x10000 - factor
            }
            divisor |= 0x80
            var lcr = UInt16(0xc0 | (s.dataBits-5))
            if s.stopBits == 2 { lcr |= 4 }
            switch s.parity {
            case .none: break
            case .odd: lcr |= 8
            case .even: lcr |= 0x18
            case .mark: lcr |= 0x28
            case .space: lcr |= 0x38
            }
            return [try USBControlRequest(requestType:0x40,request:0xa1),
                    try USBControlRequest(requestType:0x40,request:0x9a,value:0x1312,index:UInt16((factor & 0xff00)|divisor)),
                    try USBControlRequest(requestType:0x40,request:0x9a,value:0x0f2c,index:UInt16(factor & 255)),
                    try USBControlRequest(requestType:0x40,request:0x9a,value:0x2518,index:lcr),
                    try USBControlRequest(requestType:0x40,request:0xa4,value:0xff9f)]
        case .ftdi:
            guard s.dataBits >= 7 else { throw ToolboxError.unsupported("FTDI data bits") }
            var divisor: UInt32, subdivision: UInt32, effective: UInt32
            if s.baud >= 2_500_000 { divisor=0; subdivision=0; effective=3_000_000 }
            else if s.baud >= 1_750_000 { divisor=1; subdivision=0; effective=2_000_000 }
            else {
                var scaled = (48_000_000 / s.baud + 1) >> 1
                subdivision = scaled & 7; scaled >>= 3; divisor = scaled
                guard divisor <= 0x3fff else { throw ToolboxError.unsupported("FTDI baud") }
                let denominator = (divisor << 3) + subdivision
                guard denominator > 0 else { throw ToolboxError.invalid("FTDI divisor") }
                effective = (48_000_000 / denominator + 1) >> 1
            }
            guard abs(1-Double(effective)/Double(s.baud)) < 0.031 else { throw ToolboxError.unsupported("FTDI baud deviation") }
            let fraction: [UInt32] = [0,0xc000,0x8000,0,0x4000,0x4000,0x8000,0xc000]
            let value = UInt16(divisor | fraction[Int(subdivision)])
            var index: UInt16 = [3,5,6,7].contains(subdivision) ? 1 : 0
            if ftdiPortIndexed { index = (index << 8) | (i+1) }
            let format = UInt16(s.dataBits) | UInt16(s.parity.rawValue) << 8 | (s.stopBits == 2 ? 0x1000 : 0)
            return [try USBControlRequest(requestType:0x40,request:0,index:i+1),
                    try USBControlRequest(requestType:0x40,request:3,value:value,index:index),
                    try USBControlRequest(requestType:0x40,request:4,value:format,index:i+1)]
        }
    }
    private static func prolificConfiguration(revision: PL2303Revision, settings s: USBSerialSettings) throws -> [USBControlRequest] {
        let writeRequest: UInt8 = revision == .hxn ? 0x80 : 1
        func out(_ value: UInt16, _ index: UInt16 = 0) throws -> USBControlRequest {
            try USBControlRequest(requestType:0x40, request:writeRequest, value:value, index:index)
        }
        func input(_ value: UInt16) throws -> USBControlRequest {
            try USBControlRequest(requestType:0xc0, request:1, value:value, expectedReadBytes:1)
        }
        let reset = try revision == .hxn ? [out(7,3)] : [out(8),out(9)]
        var requests = reset
        if revision != .hxn {
            requests += try [input(0x8484),out(0x0404),input(0x8484),input(0x8383),input(0x8484),
                             out(0x0404,1),input(0x8484),input(0x8383),out(0,1),out(1),
                             out(2,revision == .legacy01 ? 0x24 : 0x44)]
        }
        requests.append(try USBControlRequest(requestType:0x21,request:0x22,value:3))
        requests.append(try revision == .hxn ? out(0x0a,0xff) : out(0))
        let baud = try prolificBaud(s.baud,revision:revision)
        let line = Data([UInt8(baud & 255),UInt8((baud >> 8) & 255),UInt8((baud >> 16) & 255),UInt8(baud >> 24),
                         s.stopBits == 1 ? 0 : 2,s.parity.rawValue,s.dataBits])
        requests.append(try USBControlRequest(requestType:0x21,request:0x20,payload:line))
        return requests + reset
    }
    private static func prolificBaud(_ baud: UInt32, revision: PL2303Revision) throws -> UInt32 {
        let standard: [UInt32] = [75,150,300,600,1200,1800,2400,3600,4800,7200,9600,14400,19200,28800,
                                  38400,57600,115200,230400,460800,614400,921600,1228800,2457600,3000000]
        if revision == .hxn || standard.contains(baud) { return baud }
        let baseline: UInt32 = 384_000_000
        var mantissa = baseline / baud, exponent: UInt32 = 0
        let t = revision == .taTB
        while mantissa >= (t ? 2048 : 512) {
            guard exponent < (t ? 15 : 7) else { throw ToolboxError.unsupported("PL2303 baud") }
            mantissa >>= t ? 1 : 2; exponent += 1
        }
        guard mantissa > 0 else { throw ToolboxError.unsupported("PL2303 baud") }
        let effective = (baseline / mantissa) >> (t ? exponent : exponent << 1)
        guard abs(1-Double(effective)/Double(baud)) < 0.031 else { throw ToolboxError.unsupported("PL2303 baud deviation") }
        return t ? mantissa | ((exponent & ~1) << 12) | ((exponent & 1) << 16) | 0x80000000
                 : mantissa | (exponent << 9) | 0x80000000
    }
    public static func stripFTDIStatus(_ data: Data, maximumPacketSize: Int) throws -> Data {
        guard (2...1024).contains(maximumPacketSize) else { throw ToolboxError.invalid("USB maximum packet size") }
        let bytes = Array(data); var output = Data(); var offset = 0
        while offset < bytes.count {
            let length = min(maximumPacketSize, bytes.count-offset)
            guard length >= 2 else { throw ToolboxError.truncated("FTDI status prefix") }
            output.append(contentsOf:bytes[offset+2..<offset+length]); offset += length
        }
        return output
    }
}

public protocol USBTransferExecutor: Sendable {
    func control(_ request: USBControlRequest) async throws -> Data
    func write(_ bytes: Data) async throws -> Int
    func read(maximumBytes: Int) async throws -> Data
    func close() async
}

/// A host-facing adapter. Unavailable/disconnected DriverKit user clients report errors, never traps.
public actor USBSerialConnection: SerialConnection {
    private let executor: any USBTransferExecutor
    private let family: USBSerialFamily
    private let packetSize: Int
    private let ftdiPortIndexed: Bool
    private let pl2303Revision: PL2303Revision?
    private var closed = false, configured = false, busy = false
    public init(executor: any USBTransferExecutor, family: USBSerialFamily, maximumPacketSize: Int = 64,
                ftdiPortIndexed: Bool = false, pl2303Revision: PL2303Revision? = nil) throws {
        guard (2...1024).contains(maximumPacketSize) else { throw ToolboxError.invalid("USB packet size") }
        self.executor = executor; self.family = family; self.packetSize = maximumPacketSize
        self.ftdiPortIndexed = ftdiPortIndexed; self.pl2303Revision = pl2303Revision
    }
    public func configure(_ settings: USBSerialSettings, interface: UInt8 = 0) async throws {
        guard !closed, !busy else { throw ToolboxError.staleSession }; busy = true; defer { busy = false }
        do {
            for request in try USBSerialChipPlans.configuration(family:family,settings:settings,interface:interface,
                ftdiPortIndexed:ftdiPortIndexed,pl2303Revision:pl2303Revision) {
                guard !closed, !Task.isCancelled else { throw ToolboxError.staleSession }
                let response = try await executor.control(request)
                guard response.count == Int(request.expectedReadBytes), !closed else { throw ToolboxError.invalid("USB control response or disconnected device") }
            }
            configured = true
        } catch { configured = false; closed = true; await executor.close(); throw error }
    }
    public func send(_ bytes: Data) async throws {
        guard configured, !closed, !busy else { throw ToolboxError.staleSession }
        guard bytes.count <= 65536 else { throw ToolboxError.limit("USB write") }
        busy = true; defer { busy = false }
        let count = try await executor.write(bytes)
        guard !closed, count == bytes.count else { throw ToolboxError.invalid("USB short write or disconnected device") }
    }
    public func receive(maximumBytes: Int) async throws -> Data {
        guard configured, !closed, !busy else { throw ToolboxError.staleSession }
        guard (1...65536).contains(maximumBytes) else { throw ToolboxError.limit("USB read") }
        busy = true; defer { busy = false }
        let bytes = try await executor.read(maximumBytes:maximumBytes)
        guard !closed, bytes.count <= maximumBytes else { throw ToolboxError.invalid("USB oversized read or disconnected device") }
        return family == .ftdi ? try USBSerialChipPlans.stripFTDIStatus(bytes,maximumPacketSize:packetSize) : bytes
    }
    public func close() async { guard !closed else { return }; closed = true; configured = false; await executor.close() }
}

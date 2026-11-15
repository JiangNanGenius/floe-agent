// SPDX-License-Identifier: MPL-2.0
import Foundation

/// RPG Maker `Table` binary payload (`Table#_dump`): five little-endian
/// uint32 values (dim, xsize, ysize, zsize, itemCount) followed by
/// itemCount little-endian int16 entries. Used by XP/VX/VX Ace map tile
/// data and animation frame data.
public struct RPGTable: Equatable, Sendable {
    public let dimensions: Int
    public let xSize: Int
    public let ySize: Int
    public let zSize: Int
    public private(set) var values: [Int16]

    public init(dimensions: Int, xSize: Int, ySize: Int, zSize: Int, values: [Int16]) throws {
        guard (1...3).contains(dimensions), xSize >= 0, ySize >= 0, zSize >= 0,
              values.count <= Int(Int32.max) else { throw RPGCodecError.invalidTable("bad dimensions") }
        let expected = xSize * ySize * zSize
        guard values.count == expected else { throw RPGCodecError.invalidTable("count \(values.count) != \(expected)") }
        self.dimensions = dimensions
        self.xSize = xSize
        self.ySize = ySize
        self.zSize = zSize
        self.values = values
    }

    /// Flat index for (x, y, z) in x-fastest order (Ruby's Table indexing).
    public func index(x: Int, y: Int, z: Int) -> Int? {
        guard x >= 0, y >= 0, z >= 0, x < xSize, y < ySize, z < zSize else { return nil }
        return (z * ySize + y) * xSize + x
    }

    public func value(x: Int, y: Int, z: Int) -> Int16? {
        guard let index = index(x: x, y: y, z: z) else { return nil }
        return values[index]
    }

    public mutating func setValue(_ value: Int16, x: Int, y: Int, z: Int) throws {
        guard let index = index(x: x, y: y, z: z) else { throw RPGCodecError.invalidTable("coordinates out of range") }
        values[index] = value
    }

    public var encoded: Data {
        var data = Data()
        for field in [dimensions, xSize, ySize, zSize, values.count] {
            var value = UInt32(field).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for entry in values {
            var value = entry.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> RPGTable {
        guard data.count >= 20 else { throw RPGCodecError.invalidTable("header too short") }
        var cursor = data.startIndex
        func u32() throws -> Int {
            guard data.distance(from: cursor, to: data.endIndex) >= 4 else { throw RPGCodecError.invalidTable("truncated") }
            defer { cursor = data.index(cursor, offsetBy: 4) }
            return Int(UInt32(littleEndian: data[cursor..<data.index(cursor, offsetBy: 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
        func i16() throws -> Int16 {
            guard data.distance(from: cursor, to: data.endIndex) >= 2 else { throw RPGCodecError.invalidTable("truncated") }
            defer { cursor = data.index(cursor, offsetBy: 2) }
            return Int16(littleEndian: data[cursor..<data.index(cursor, offsetBy: 2)].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        }
        let dimensions = try u32(), xSize = try u32(), ySize = try u32(), zSize = try u32(), count = try u32()
        guard (1...3).contains(dimensions), count == xSize * ySize * zSize,
              count <= data.count else { throw RPGCodecError.invalidTable("dimension/count mismatch") }
        var values: [Int16] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try i16()) }
        guard cursor == data.endIndex else { throw RPGCodecError.invalidTable("trailing bytes") }
        return try RPGTable(dimensions: dimensions, xSize: xSize, ySize: ySize, zSize: zSize, values: values)
    }
}

/// RPG Maker `Color` binary payload (`pack("D4")`): four little-endian
/// doubles (red, green, blue, alpha; 0..1).
public struct RPGColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public var encoded: Data {
        encodeDoubles([red, green, blue, alpha])
    }

    public static func decode(_ data: Data) throws -> RPGColor {
        let values = try decodeDoubles(data, count: 4)
        return RPGColor(red: values[0], green: values[1], blue: values[2], alpha: values[3])
    }
}

/// RPG Maker `Tone` binary payload (`pack("D3")` or `pack("D4")`):
/// three (XP/VX/VX Ace core) or four little-endian doubles
/// (red, green, blue, gray), each -255...255.
public struct RPGTone: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var gray: Double
    /// Original component count (3 or 4); preserved for byte-exact roundtrip.
    public let componentCount: Int

    public init(red: Double, green: Double, blue: Double, gray: Double = 0, componentCount: Int? = nil) {
        self.red = red; self.green = green; self.blue = blue; self.gray = gray
        self.componentCount = componentCount ?? 4
    }

    public var encoded: Data {
        encodeDoubles(Array([red, green, blue, gray].prefix(componentCount)))
    }

    public static func decode(_ data: Data) throws -> RPGTone {
        guard data.count == 24 || data.count == 32 else {
            throw RPGCodecError.invalidTable("tone has \(data.count / 8) components")
        }
        let values = try decodeDoubles(data, count: data.count / 8)
        return RPGTone(red: values[0], green: values[1], blue: values[2],
                       gray: values.count == 4 ? values[3] : 0, componentCount: values.count)
    }
}

private func encodeDoubles(_ values: [Double]) -> Data {
    var data = Data()
    data.reserveCapacity(values.count * 8)
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

private func decodeDoubles(_ data: Data, count: Int) throws -> [Double] {
    guard data.count == count * 8 else {
        throw RPGCodecError.invalidTable("expected \(count * 8) bytes, got \(data.count)")
    }
    return data.withUnsafeBytes { raw in
        (0..<count).map { index in
            Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)))
        }
    }
}

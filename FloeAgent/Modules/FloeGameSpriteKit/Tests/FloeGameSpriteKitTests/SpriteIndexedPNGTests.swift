// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameSpriteCore

struct SpriteIndexedPNGTests {
    @Test("Low-bit-depth game palettes expand to exact editable RGB", arguments: [1, 2, 4])
    func indexedPNG(bitDepth: Int) throws {
        let png = fixture(bitDepth: bitDepth)
        let image = try SpritePNG.decode(png)
        #expect(image.width == 4 && image.height == 1)
        let colors: [SpriteRGBA] = [
            .init(red: 255, green: 0, blue: 0, alpha: 255),
            .init(red: 0, green: 255, blue: 0, alpha: 255),
            .init(red: 0, green: 0, blue: 255, alpha: 255),
            .init(red: 255, green: 255, blue: 255, alpha: 255)]
        for x in 0..<4 { #expect(image.color(x: x, y: 0) == colors[x % (bitDepth == 1 ? 2 : 4)]) }
        let encoded = try SpritePNG.encode(image)
        #expect(try SpritePNG.decode(encoded) == image)
    }

    /// Original tiny indexed PNGs: uncompressed zlib blocks and PNG CRCs
    /// avoid a fixture/codec dependency and exercise ImageIO's real decoder.
    private func fixture(bitDepth: Int) -> Data {
        var header = big(4) + big(1)
        header += [UInt8(bitDepth), 3, 0, 0, 0]
        let palette: [UInt8] = bitDepth == 1
            ? [255, 0, 0, 0, 255, 0]
            : [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
        let raw: [UInt8] = bitDepth == 1 ? [0, 0x50] : bitDepth == 2 ? [0, 0x1B] : [0, 0x01, 0x23]
        let count = UInt16(raw.count)
        var zlib: [UInt8] = [0x78, 0x01, 0x01, UInt8(count & 255), UInt8(count >> 8),
                             UInt8((~count) & 255), UInt8((~count) >> 8)]
        zlib += raw
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        zlib += big((b << 16) | a)
        return Data(SpritePNGBytes.signature + chunk("IHDR", header) + chunk("PLTE", palette)
            + chunk("IDAT", zlib) + chunk("IEND", []))
    }

    private func chunk(_ name: String, _ bytes: [UInt8]) -> [UInt8] {
        let body = Array(name.utf8) + bytes
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return big(UInt32(bytes.count)) + body + big(~crc)
    }

    private func big(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
}

private enum SpritePNGBytes {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
}

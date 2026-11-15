// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A real standard GDevelop project starter, not an HTML mock. The JSON shape
/// was produced by official GDevelop Core (`gdcore-tools` 2.0.0-gd-v5.6.269)
/// and is exported by the official 5.6.287 SDK. All assets are generated
/// procedurally; the project references them through normal GDevelop resources.
public enum GameGDevelopTemplate {
    public static let projectFileName = "game.json"
    public static let inputFileName = "floe-inputs.json"
    public static let assetPath = "assets/floe_orb.png"
    public static let sceneName = "Main"
    public static let objectName = "Orb"

    public static func makeProject(title: String = "Floe GDevelop Project",
                                   projectUUID: UUID = UUID()) throws -> [GameRelativePath: Data] {
        guard GameGDevelopProjectDocument.validText(title) else {
            throw GameGDevelopError.invalidInput("title")
        }
        guard let url = Bundle.module.url(forResource: "floe-gdevelop-template", withExtension: "json"),
              let templateData = try? Data(contentsOf: url) else {
            throw GameGDevelopError.io("template resource")
        }
        let document = try GameGDevelopProjectDocument(data: templateData)
            .replacingProjectName(title)
            .replacingProjectUUID(projectUUID)
        let inputs = try GameGDevelopInputDeclaration.starter()
        var files: [GameRelativePath: Data] = [:]
        let projectPath = try GameRelativePath(projectFileName)
        let inputPath = try GameRelativePath(inputFileName)
        let asset = try GameRelativePath(assetPath)
        files[projectPath] = document.encoded()
        files[inputPath] = try inputs.jsonData()
        files[asset] = try PNG.orb(size: 64)
        return files
    }

    /// Minimal deterministic PNG writer. It avoids an image framework and is
    /// byte-stable across macOS/iOS SDK versions.
    enum PNG {
        static func orb(size: Int) throws -> Data {
            guard size >= 8, size <= 512 else { throw GameGDevelopError.invalidInput("pngSize") }
            var raw = Data()
            raw.reserveCapacity((size * 4 + 1) * size)
            let center = Double(size - 1) / 2.0
            let radius = Double(size) * 0.47
            for y in 0..<size {
                raw.append(0) // filter: none
                for x in 0..<size {
                    let dx = Double(x) - center
                    let dy = Double(y) - center
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance > radius {
                        raw.append(contentsOf: [0, 0, 0, 0])
                        continue
                    }
                    let falloff = max(0, 1 - distance / radius)
                    var r = 255 * (0.62 + 0.38 * falloff)
                    var g = 82 + 138 * falloff
                    var b = 36 + 94 * falloff
                    let highlight = ((dx + Double(size) * 0.16) * (dx + Double(size) * 0.16)
                        + (dy + Double(size) * 0.16) * (dy + Double(size) * 0.16)).squareRoot()
                    if highlight < Double(size) * 0.16 {
                        r = min(255, r + 55); g = min(255, g + 55); b = min(255, b + 45)
                    }
                    raw.append(contentsOf: [UInt8(r), UInt8(g), UInt8(b), 255])
                }
            }
            var output = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            var ihdr = Data()
            ihdr.append(contentsOf: bigEndian(UInt32(size)))
            ihdr.append(contentsOf: bigEndian(UInt32(size)))
            ihdr.append(contentsOf: [8, 6, 0, 0, 0])
            output.append(chunk(type: "IHDR", payload: ihdr))
            output.append(chunk(type: "IDAT", payload: zlibStored(raw)))
            output.append(chunk(type: "IEND", payload: Data()))
            return output
        }

        private static func zlibStored(_ data: Data) -> Data {
            var output = Data([0x78, 0x01])
            var offset = 0
            let bytes = [UInt8](data)
            repeat {
                let length = min(65_535, bytes.count - offset)
                let final: UInt8 = offset + length == bytes.count ? 1 : 0
                output.append(final) // BFINAL + BTYPE=00
                output.append(contentsOf: bigEndian(UInt16(length)))
                output.append(contentsOf: bigEndian(UInt16(~UInt16(length))))
                if length > 0 { output.append(contentsOf: bytes[offset..<(offset + length)]) }
                offset += length
            } while offset < bytes.count
            output.append(contentsOf: bigEndian(adler32(bytes)))
            return output
        }

        private static func chunk(type: String, payload: Data) -> Data {
            var output = Data()
            output.append(contentsOf: bigEndian(UInt32(payload.count)))
            let typeBytes = Data(type.utf8)
            output.append(typeBytes)
            output.append(payload)
            var crcInput = Data()
            crcInput.append(typeBytes)
            crcInput.append(payload)
            output.append(contentsOf: bigEndian(crc32([UInt8](crcInput))))
            return output
        }

        private static func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
                }
            }
            return crc ^ 0xFFFF_FFFF
        }

        private static func adler32(_ bytes: [UInt8]) -> UInt32 {
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in bytes {
                a = (a + UInt32(byte)) % 65_521
                b = (b + a) % 65_521
            }
            return (b << 16) | a
        }

        private static func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
             UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }

        private static func bigEndian(_ value: UInt16) -> [UInt8] {
            [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
    }
}

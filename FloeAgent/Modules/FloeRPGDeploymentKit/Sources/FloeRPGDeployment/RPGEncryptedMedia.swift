// SPDX-License-Identifier: MPL-2.0
// Standard first-block decoding adapted from RPGMakerDecrypter, MIT,
// Copyright (c) 2016 Mikko Uuksulainen. Full original MIT in Resources/.
import Foundation
import FloeGameCore

/// Only the ordinary key already stored in this project's System.json is used.
/// This API does not discover/recover keys or execute any imported code.
public enum RPGEncryptedMedia {
    private static let header = Data([0x52, 0x50, 0x47, 0x4d, 0x56, 0, 0, 0, 0, 3, 1, 0, 0, 0, 0, 0])
    private static let extensions = ["rpgmvp": "png", "rpgmvo": "ogg", "rpgmvm": "m4a",
                                     "png_": "png", "ogg_": "ogg", "m4a_": "m4a"]

    public static func plaintextPath(for path: GameRelativePath) throws -> GameRelativePath? {
        let url = URL(fileURLWithPath: path.value)
        guard let plain = extensions[url.pathExtension.lowercased()] else { return nil }
        return try DeploymentPath.validate(String(path.value.dropLast(url.pathExtension.count)) + plain)
    }

    /// The key is intentionally neither Codable nor included in any result.
    public static func decode(_ encrypted: Data, systemJSON: Data,
                              maximumBytes: Int = 64 * 1_024 * 1_024) throws -> Data {
        guard maximumBytes >= 32, encrypted.count <= maximumBytes else { throw RPGDeploymentError.limitExceeded("media bytes") }
        guard encrypted.count >= 32, encrypted.prefix(16) == header else { throw RPGDeploymentError.invalidMediaHeader }
        guard systemJSON.count <= 16 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: systemJSON) as? [String: Any],
              let text = object["encryptionKey"] as? String else { throw RPGDeploymentError.missingMediaKey }
        let chars = Array(text.utf8)
        guard chars.count == 32 else { throw RPGDeploymentError.invalidMediaKey }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        var key = [UInt8](); key.reserveCapacity(16)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let a = nibble(chars[i]), let b = nibble(chars[i + 1]) else { throw RPGDeploymentError.invalidMediaKey }
            key.append(a * 16 + b)
        }
        var output = Data(encrypted.dropFirst(16))
        for i in 0..<16 { output[i] ^= key[i] }
        return output
    }

    public static func validatePlaintext(_ bytes: Data, path: GameRelativePath) throws {
        let ext = URL(fileURLWithPath: path.value).pathExtension.lowercased()
        let valid: Bool
        switch ext {
        case "png": valid = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "ogg": valid = bytes.starts(with: Array("OggS".utf8))
        case "m4a": valid = bytes.count >= 12 && bytes.dropFirst(4).prefix(4) == Data("ftyp".utf8)
        default: valid = false
        }
        guard valid else { throw RPGDeploymentError.invalidMediaKey }
    }

    /// Preserve unknown fields; only flags for completely prepared categories
    /// are changed. The service also retains the exact original JSON bytes.
    static func plaintextSystem(_ source: Data, images: Bool, audio: Bool) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: source) as? [String: Any] else { throw RPGDeploymentError.missingMediaKey }
        if images { object["hasEncryptedImages"] = false }
        if audio { object["hasEncryptedAudio"] = false }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

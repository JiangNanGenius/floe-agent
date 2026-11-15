// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeGameCore
import FloeGameRGSS

/// Read-only preflight for the separately built Tapir engine already installed
/// in the environment write layer. It never downloads, builds, executes or
/// decrypts anything. Installation remains an explicit reviewed package/service
/// action; this type fails closed when the reviewed layout is absent.
public struct RGSSGuestEngineInstall: Sendable {
    public static let guestRoot = "/floe/env/opt/floe/rgss"
    public static let manifestName = "VERSION.json"
    public static let pinID = RGSSLinuxRuntimePins.tapir.id
    public static let sourceCommit = RGSSLinuxRuntimePins.tapir.sourceCommit

    public let engine: GameEngineID
    public let mapping: any RGSSGuestHostPathMapping

    public init(engine: GameEngineID, mapping: any RGSSGuestHostPathMapping) throws {
        guard RGSSEngineProfiles.isRGSS(engine) else {
            throw RGSSGuestRunError.invalidEngine(engine)
        }
        self.engine = engine
        self.mapping = mapping
    }

    public static func binaryName(for engine: GameEngineID) throws -> String {
        switch engine {
        case .rpgMakerXP: "tapir-x"
        case .rpgMakerVX: "tapir-v"
        case .rpgMakerVXAce: "tapir-a"
        default: throw RGSSGuestRunError.invalidEngine(engine)
        }
    }

    public static func rubyLicenseDirectory(for engine: GameEngineID) -> String {
        engine == .rpgMakerXP || engine == .rpgMakerVX ? "ruby181" : "ruby192"
    }

    public struct Receipt: Sendable, Equatable {
        public let engine: GameEngineID
        public let binaryGuestPath: String
        public let binarySHA256: String
        public let binaryBytes: Int
        public let sourceCommit: String
        public let licensePaths: [String]
    }

    /// Validates the exact reviewed install layout:
    /// - the versioned engine root is under `/floe/env/opt/floe/rgss`;
    /// - the aarch64 executable exists and is a real ELF64 little-endian file;
    /// - `VERSION.json` names the pinned Tapir source commit;
    /// - the Tapir and relevant Ruby license/source-offer notices exist;
    /// - an optional recorded binary hash matches the actual bytes.
    public func preflight() throws -> Receipt {
        let binaryName = try Self.binaryName(for: engine)
        let binaryGuest = Self.guestRoot + "/bin/" + binaryName
        let binaryURL: URL
        do {
            binaryURL = try mapping.hostURL(forGuestPath: binaryGuest)
        } catch {
            throw RGSSGuestRunError.engineInstallMissing(
                "\(binaryGuest) is not inside the environment layer")
        }
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw RGSSGuestRunError.engineInstallMissing(binaryGuest)
        }
        let header = try RGSSGuestAtomicFile.read(binaryURL, maximumBytes: 64)
        guard header.count >= 20,
              Array(header.prefix(4)) == [0x7F, 0x45, 0x4C, 0x46],
              header[4] == 2,       // ELFCLASS64
              header[5] == 1,       // ELFDATA2LSB
              header[18] == 0xB7, header[19] == 0x00 else {
            throw RGSSGuestRunError.engineInstallInvalid(
                "\(binaryName) is not an aarch64 little-endian ELF64 executable")
        }
        let manifestURL = try mapping.hostURL(forGuestPath: Self.guestRoot + "/" + Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RGSSGuestRunError.engineInstallMissing(Self.guestRoot + "/" + Self.manifestName)
        }
        let manifestData = try RGSSGuestAtomicFile.read(manifestURL, maximumBytes: 1 * 1_024 * 1_024)
        guard let raw = try? JSONSerialization.jsonObject(with: manifestData),
              let object = raw as? [String: Any] else {
            throw RGSSGuestRunError.engineInstallInvalid("VERSION.json is not a JSON object")
        }
        guard let pins = object["sourcePins"] as? [String: Any],
              let tapirCommit = pins["tapir"] as? String,
              tapirCommit == Self.sourceCommit else {
            throw RGSSGuestRunError.engineInstallInvalid(
                "VERSION.json does not pin Tapir \(Self.sourceCommit)")
        }
        if let engineID = object["engine"] as? String, engineID != Self.pinID {
            throw RGSSGuestRunError.engineInstallInvalid(
                "VERSION.json engine \(engineID) does not match \(Self.pinID)")
        }
        let licensePaths = [
            "licenses/tapir/LICENSE-APACHE",
            "licenses/tapir/COPYRIGHT",
            "licenses/\(Self.rubyLicenseDirectory(for: engine))/COPYING",
            "SOURCE-OFFER.md",
        ]
        for relative in licensePaths {
            let url = try mapping.hostURL(forGuestPath: Self.guestRoot + "/" + relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RGSSGuestRunError.engineInstallInvalid("missing notice \(relative)")
            }
        }
        let digest = try Self.sha256(url: binaryURL)
        if let binaries = object["binaries"] as? [String: Any],
           let record = binaries[Self.binaryKey(for: engine)] as? [String: Any],
           let recorded = record["sha256"] as? String {
            guard recorded == digest else {
                throw RGSSGuestRunError.engineInstallInvalid("\(binaryName) hash mismatch")
            }
        }
        return Receipt(
            engine: engine,
            binaryGuestPath: binaryGuest,
            binarySHA256: digest,
            binaryBytes: try Self.fileSize(binaryURL),
            sourceCommit: Self.sourceCommit,
            licensePaths: licensePaths)
    }

    static func binaryKey(for engine: GameEngineID) -> String {
        switch engine {
        case .rpgMakerXP: "xp"
        case .rpgMakerVX: "vx"
        case .rpgMakerVXAce: "vxace"
        default: "unknown"
        }
    }

    private static func sha256(url: URL) throws -> String {
        let data = try RGSSGuestAtomicFile.read(url, maximumBytes: 256 * 1_024 * 1_024)
        return GameDigest.sha256(data)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey,
                                                      .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RGSSGuestRunError.engineInstallInvalid("engine binary is not a regular file")
        }
        return values.fileSize ?? 0
    }
}

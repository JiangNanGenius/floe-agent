// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Semantic validation after the existing signed-content transport, archive,
/// version and template codec. These declarative files never authorize code.
public enum EDALibraryContent {
    public static let packagePrefix = "org.floe.electronics.common."
    public static let builtInVersions: [String: String] = Dictionary(uniqueKeysWithValues:
        ["passives", "diodes-leds", "transistors-mosfets", "power", "analog-opamps", "digital-logic", "microcontrollers", "connectors", "switches-relays", "crystals", "sensors", "modules"].map { (packagePrefix + $0, "1.0.0") })
    private struct Metadata: Decodable {
        let schemaVersion: Int
        let id: String
        let version: String
        let kind: String
        let template: String
        let domain: String
        let librarySHA256: String
    }
    public static func decode(packageID: String, version: String, files: [String: Data]) throws -> EDALibraryPackage {
        guard packageID.hasPrefix(packagePrefix), Set(files.keys) == ["content.json", "Library.json"],
              let metadata = files["content.json"], metadata.count <= 262_144,
              let bytes = files["Library.json"], bytes.count <= 1_048_576 else { throw EDAError.invalid("declarative electronics library content files") }
        let value = try JSONDecoder().decode(Metadata.self, from: metadata)
        guard value.schemaVersion == 1, value.id == packageID, value.version == version, value.kind == "templates",
              value.template == "Library.json", value.domain == "org.floe.electronics.library",
              value.librarySHA256 == EDALibraryDigest.sha256(bytes) else { throw EDAError.invalid("electronics library content identity or checksum") }
        let package = try EDALibraryPackage.decode(bytes)
        guard package.id == packageID, package.version == version else { throw EDAError.invalid("electronics library payload identity") }
        return package
    }
}

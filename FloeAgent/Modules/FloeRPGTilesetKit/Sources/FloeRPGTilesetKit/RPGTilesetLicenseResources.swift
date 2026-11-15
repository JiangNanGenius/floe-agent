// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Retained with the compiled module so an embedding host can include them
/// in its existing acknowledgements/export flow without fetching new terms.
public enum RPGTilesetLicenseResources {
    public static func text(named name: String) throws -> String {
        guard ["MPL-2.0", "RPGMakerMV-CoreScript-MIT", "Tapir-Tilemap-MIT"].contains(name),
              let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

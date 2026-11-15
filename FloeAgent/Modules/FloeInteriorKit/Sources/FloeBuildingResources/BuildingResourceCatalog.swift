// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One bundled, unmodified CC0 source package shared by user imports and the
/// native admission qualification. Missing resources are errors, never skips.
public enum BuildingResourceCatalog {
    public static func starterArmchairDirectory() throws -> URL {
        guard let directory=Bundle.module.url(forResource:"armchair",withExtension:nil,
            subdirectory:"Resources/StarterFurniture") else{throw CocoaError(.fileNoSuchFile)}
        return directory
    }
}

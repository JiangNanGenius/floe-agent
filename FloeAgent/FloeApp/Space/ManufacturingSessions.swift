// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeManufacturingUI

/// Calculation state outlives an individual editor presentation. Every
/// window opening this same project observes the same native service model.
@MainActor enum ManufacturingSessions {
    private static var models: [UUID: ManufacturingModel] = [:]
    static func open(id: UUID, directory: URL) -> ManufacturingModel {
        if let value = models[id] { return value }
        let value = ManufacturingModel(directory: directory)
        models[id] = value
        return value
    }
}
#endif

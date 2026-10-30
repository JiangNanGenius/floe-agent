// SPDX-License-Identifier: MPL-2.0
import Foundation

public extension FloeCADDocument {
    /// The writer's actual supported package format, not an App-side copy.
    static var supportedPackageSchemaVersion: Int { FileCADDocumentStore.currentSchemaVersion }
}

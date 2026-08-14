// FloeApp — Files coordinator (app-level seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns document/image working copies, security-scoped bookmarks and the
// local image pipeline; exposes recent files and Quick Look. T01 ships the
// compile-clean shell; T05 fills in picking, writeback and image editing.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels

/// Coordinates document and image workflows for the UI layer.
@MainActor
final class FilesCenter: ObservableObject {

    /// Recently opened attachments. Populated by T05.
    @Published private(set) var recentFiles: [AttachmentRef] = []

    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
import Foundation

nonisolated enum PersonalLibraryDeletionPreferences {
    static let trashEnabledKey = "space.personalFiles.trashEnabled"

    static func usesTrash(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: trashEnabledKey) as? Bool ?? true
    }
}

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// Scene-bound navigation only; opening grants no tool or file authority.
struct StudioOpenRequest: Identifiable {
    let id = UUID()
    let record: PersonalContentRecord
    let sceneID: String
}
#endif

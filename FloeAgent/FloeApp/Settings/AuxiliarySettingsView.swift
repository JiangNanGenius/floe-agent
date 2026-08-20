// FloeApp — Auxiliary (image generation/editing) models settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 3: reuses AuxiliaryModelsView
// (shared/separate routing, default generation/editing models, real
// capability state). Adapters without an implementation surface honestly
// inside the reused view — nothing here fabricates availability.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct AuxiliarySettingsView: View {
    let center: ConversationCenter

    var body: some View {
        AuxiliaryModelsView(center: center)
    }
}
#endif

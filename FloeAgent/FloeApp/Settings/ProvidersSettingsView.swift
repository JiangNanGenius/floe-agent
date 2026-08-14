// FloeApp — Models & providers settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 2: reuses the existing
// ProviderListView (list / edit / discovery / test-connection). This view
// is a thin embed — no logic is duplicated, and the multi-provider,
// multi-model, capability and default-model behavior is unchanged.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct ProvidersSettingsView: View {
    let center: ConversationCenter

    var body: some View {
        ProviderListView(center: center)
    }
}
#endif

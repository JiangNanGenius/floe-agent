// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// Durable originals and media entrances share one professional workbench.
struct MusicEditorView: View {
    @Bindable var session: MusicProjectSession
    // PersonalContentEditor owns the single navigation-bar assistant entry.
    var body: some View { MusicWorkbenchView(session: session) }
}
#endif

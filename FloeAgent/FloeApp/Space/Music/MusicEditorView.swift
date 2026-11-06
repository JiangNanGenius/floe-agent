// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// Durable originals and media entrances share one professional workbench.
struct MusicEditorView: View {
    @Bindable var session: MusicProjectSession
    var onAssistant: (() -> Void)? = nil
    var body: some View { MusicWorkbenchView(session: session, onAssistant: onAssistant) }
}
#endif
